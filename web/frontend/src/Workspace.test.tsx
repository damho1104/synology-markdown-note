// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { Workspace } from './Workspace'
import { DEFAULT_PREFERENCES, PREFERENCES_KEY, loadPreferences } from './preferences'

vi.mock('./mathExport', () => ({ exportMath: vi.fn(async () => []) }))

const note = { id: 'note1', title: '기존 제목', html: '<p>original</p>', notebook_id: 'book1', version: 'v1', attachments: [], locked: false, trashed: false, editable: true, read_only_reason: null }
const session = {username: 'alice', remember: false, csrf_token: 'csrf'}
const status = {configured: true, nas_url: 'https://nas.example', source: 'database' as const, read_only: false}
let writes: Record<string, unknown>[]
let resolveSave: (value: Response) => void
beforeEach(() => {
  localStorage.clear()
  sessionStorage.clear(); window.history.replaceState({}, '', '/?n=book1&note=note1'); writes = []
  vi.stubGlobal('fetch', vi.fn(async (path: string, init?: RequestInit) => {
    if (init?.method === 'PUT') { writes.push(JSON.parse(init.body as string)); return new Promise<Response>(resolve => {resolveSave = resolve}) }
    if (path === '/api/graph?summary=true') return new Response(JSON.stringify({nodes:[note],edges:[],failures:[],entries:[{id:note.id,links:[]}],pending:[]}))
    const body = path === '/api/notebooks' ? {notebooks: [{id: 'book1', name: '업무', stack: '프로젝트'}]} : path === '/api/notes' ? {notes: [note]} : path === '/api/writes' ? {operations: []} : note
    return new Response(JSON.stringify(body), {status: 200})
  }))
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals() })
function mount(onLogout = async () => {}) { return render(<Workspace session={session} status={status} onLogout={onLogout} onSessionExpired={() => {}} />) }
async function edit() { await screen.findByLabelText('노트 제목'); fireEvent.click(screen.getByRole('button', {name: '분할'})); fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '수정 제목'}}) }
it('autosaves without a Save button and keeps typing enabled while a request is pending', async () => {
  mount(); await edit()
  expect(screen.queryByRole('button', {name: 'NAS에 저장'})).toBeNull()
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).disabled).toBe(false)
  expect((screen.getByLabelText('HTML 본문') as HTMLTextAreaElement).disabled).toBe(false)
  const event = new Event('beforeunload', {cancelable: true}); window.dispatchEvent(event); expect(event.defaultPrevented).toBe(true)
  fireEvent.change(screen.getByLabelText('HTML 본문'), {target: {value: '<p>newer while saving</p>'}})
  resolveSave(new Response(JSON.stringify({...note, title: '수정 제목', version: 'v2'})))
  await waitFor(() => expect((screen.getByLabelText('HTML 본문') as HTMLTextAreaElement).value).toBe('<p>newer while saving</p>'))
  await waitFor(() => expect(writes).toHaveLength(2), {timeout: 2000})
  expect(writes[1]).toMatchObject({html: '<p>newer while saving</p>', version: 'v2'})
  resolveSave(new Response(JSON.stringify({...note, title: '수정 제목', html: '<p>newer while saving</p>', version: 'v3'})))
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect(sessionStorage.length).toBe(0)
})
it('reports uncertain writes and preserves drafts without automatic retransmission', async () => {
  mount(); await edit()
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  resolveSave(new Response(JSON.stringify({error: 'WRITE_UNCERTAIN'}), {status: 409}))
  await screen.findByText('자동 저장 중단 · 편집본 보관됨')
  expect(sessionStorage.length).toBe(1)
  fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '더 편집'}})
  await new Promise(resolve => setTimeout(resolve, 950))
  expect(writes).toHaveLength(1)
  fireEvent.click(screen.getByRole('button', {name:'새 노트'}))
  await new Promise(resolve => setTimeout(resolve, 50))
  expect(writes).toHaveLength(1)
  expect(window.location.search).toContain('note=note1')
})
it('retains the base version across draft restore to detect concurrent NAS edits', async () => {
  sessionStorage.setItem('synonote:web-draft:["https://nas.example","alice"]:note:note1', JSON.stringify({key: 'note:note1', notebook_id: 'book1', title: '임시 제목', html: '<p>draft</p>', version: 'old-version'}))
  mount(); await screen.findByLabelText('노트 제목')
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000}); expect(writes[0].version).toBe('old-version')
  resolveSave(new Response(JSON.stringify({error: 'REMOTE_CHANGED'}), {status: 409}))
  await screen.findByText('버전 충돌 · 로컬 편집본을 유지했습니다')
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('임시 제목')
})
it('coalesces consecutive edits into one automatic write', async () => {
  mount(); await edit()
  fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '최종 제목'}})
  fireEvent.change(screen.getByLabelText('HTML 본문'), {target: {value: '<p>latest</p>'}})
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  expect(writes[0]).toMatchObject({title: '최종 제목', html: '<p>latest</p>'})
  resolveSave(new Response(JSON.stringify({...note, title: '최종 제목', html: '<p>latest</p>', version: 'v2'})))
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('최종 제목')
})

it('opens a settings popup from the gear and applies local preferences without writing or losing a dirty draft', async () => {
  const { container, unmount } = mount()
  await edit()
  const storedDraft = sessionStorage.getItem(sessionStorage.key(0)!)
  const gear = screen.getByRole('button', { name: /^설정$/ })
  gear.focus(); fireEvent.click(gear)
  const dialog = screen.getByRole('dialog', { name: '설정' })
  expect(screen.queryByRole('complementary', { name: '노트 정보' })).toBeNull()
  fireEvent.change(within(dialog).getByLabelText('화면 모드'), { target: { value: 'dark' } })
  fireEvent.change(within(dialog).getByLabelText('글꼴 크기'), { target: { value: '20' } })
  fireEvent.click(within(dialog).getByLabelText('줄 번호 표시'))
  fireEvent.click(within(dialog).getByLabelText('자동 줄바꿈'))
  fireEvent.change(within(dialog).getByLabelText('그리기 스타일'), { target: { value: 'classic' } })
  fireEvent.change(within(dialog).getByLabelText('색상 테마'), { target: { value: 'forest' } })
  expect(container.querySelector('.native-app')!.classList.contains('native-dark')).toBe(true)
  expect((container.querySelector('.native-app') as HTMLElement).style.getPropertyValue('--editor-font-size')).toBe('20px')
  expect(loadPreferences()).toEqual({ appearance: 'dark', editorFontSize: 20, lineNumbers: true,
    lineWrapping: true, mermaidStyle: 'classic', mermaidTheme: 'forest' })
  expect(sessionStorage.getItem(sessionStorage.key(0)!)).toBe(storedDraft)
  expect(writes).toHaveLength(0)
  expect(vi.mocked(fetch).mock.calls.some(([, init]) => init?.method && !['GET', 'HEAD'].includes(init.method))).toBe(false)
  fireEvent.keyDown(dialog, { key: 'Escape' })
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.activeElement).toBe(gear)
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('수정 제목')
  unmount(); mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button', { name: /^설정$/ }))
  expect((screen.getByLabelText('글꼴 크기') as HTMLInputElement).value).toBe('20')
  expect((screen.getByLabelText('화면 모드') as HTMLSelectElement).value).toBe('dark')
})

it('follows system theme changes live while keeping an explicit appearance override across reloads', async () => {
  let listener: () => void = () => {}
  const media = { matches: false, addEventListener: vi.fn((_event: string, fn: () => void) => { listener = fn }),
    removeEventListener: vi.fn() }
  vi.stubGlobal('matchMedia', () => media)
  const { container } = mount()
  await screen.findByLabelText('노트 제목')
  const app = container.querySelector('.native-app')!
  const { act } = await import('@testing-library/react')
  act(() => { media.matches = true; listener() })
  expect(app.classList.contains('native-dark')).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: /^설정$/ }))
  fireEvent.change(screen.getByLabelText('화면 모드'), { target: { value: 'light' } })
  expect(app.classList.contains('native-dark')).toBe(false)
  act(() => { media.matches = false; listener(); media.matches = true; listener() })
  expect(app.classList.contains('native-dark')).toBe(false)
  expect(loadPreferences().appearance).toBe('light')
  fireEvent.change(screen.getByLabelText('화면 모드'), { target: { value: 'system' } })
  expect(app.classList.contains('native-dark')).toBe(true)
})

it('traps focus, ignores clicks inside the dialog and closes from the backdrop or Done', async () => {
  mount(); await screen.findByLabelText('노트 제목')
  const gear = screen.getByRole('button', { name: /^설정$/ })
  gear.focus(); fireEvent.click(gear)
  let dialog = screen.getByRole('dialog', { name: '설정' })
  const first = within(dialog).getByRole('button', { name: '설정 닫기' })
  const last = within(dialog).getByRole('button', { name: '완료' })
  expect(document.activeElement).toBe(first)
  gear.focus()
  expect(document.activeElement).toBe(first)
  last.focus(); fireEvent.keyDown(last, { key: 'Tab' })
  expect(document.activeElement).toBe(first)
  fireEvent.keyDown(first, { key: 'Tab', shiftKey: true })
  expect(document.activeElement).toBe(last)
  fireEvent.click(screen.getByLabelText('화면 모드'))
  expect(screen.getByRole('dialog')).toBe(dialog)
  vi.spyOn(dialog, 'getBoundingClientRect').mockReturnValue({ x: 100, y: 100,
    left: 100, top: 100, right: 600, bottom: 600, width: 500, height: 500, toJSON() {} })
  // Native dialog borders/padding can be the event target while still inside.
  fireEvent.click(dialog, { clientX: 110, clientY: 110 })
  expect(screen.getByRole('dialog')).toBe(dialog)
  fireEvent.click(dialog, { clientX: 50, clientY: 50 })
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.activeElement).toBe(gear)
  fireEvent.click(gear); dialog = screen.getByRole('dialog')
  fireEvent.click(within(dialog).getByRole('button', { name: '완료' }))
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('applies line numbers and wrapping to the real Markdown editor', async () => {
  localStorage.setItem(PREFERENCES_KEY, JSON.stringify({ version: 1,
    preferences: { ...DEFAULT_PREFERENCES, lineWrapping: true, lineNumbers: true, editorFontSize: 18 } }))
  const markdownNote = { ...note, markdown: '# Markdown\n\nA paragraph.' }
  vi.stubGlobal('fetch', vi.fn(async (path: string) => new Response(JSON.stringify(
    path === '/api/notebooks' ? { notebooks: [{ id: 'book1', name: '업무', stack: '' }] } :
    path === '/api/notes' ? { notes: [markdownNote] } : path === '/api/writes' ? { operations: [] } : markdownNote))))
  const { container } = mount()
  await screen.findByLabelText('노트 제목'); fireEvent.click(screen.getByRole('button', {name: '분할'}))
  await waitFor(() => expect(container.querySelector('.cm-lineNumbers')).toBeTruthy())
  expect(container.querySelector('.cm-content.cm-lineWrapping')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: /^설정$/ }))
  fireEvent.click(screen.getByLabelText('자동 줄바꿈'))
  fireEvent.click(screen.getByLabelText('줄 번호 표시'))
  await waitFor(() => expect(container.querySelector('.cm-lineNumbers')).toBeNull())
  expect(container.querySelector('.cm-content.cm-lineWrapping')).toBeNull()
  expect(writes).toHaveLength(0)
})

it('does not autosave partially composed Korean text', async () => {
  mount(); await screen.findByLabelText('노트 제목')
  fireEvent.compositionStart(screen.getByLabelText('노트 제목'))
  fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '한글 조합'}})
  await new Promise(resolve => setTimeout(resolve, 950))
  expect(writes).toHaveLength(0)
  fireEvent.compositionEnd(screen.getByLabelText('노트 제목'))
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
})

it('creates a new note once and saves edits made during creation with the returned version', async () => {
  window.history.replaceState({}, '', '/?n=book1&new=1')
  const create = vi.fn()
  vi.stubGlobal('fetch', vi.fn(async (path: string, init?: RequestInit) => {
    if (init?.method === 'POST' && path === '/api/notes') {
      create(JSON.parse(init.body as string)); return new Promise<Response>(resolve => {resolveSave = resolve})
    }
    if (init?.method === 'PUT') {writes.push(JSON.parse(init.body as string)); return new Promise<Response>(resolve => {resolveSave = resolve})}
    return new Response(JSON.stringify(path === '/api/notebooks' ? {notebooks: [{id: 'book1', name: '업무', stack: ''}]} : path === '/api/notes' ? {notes: []} : path === '/api/writes' ? {operations: []} : note))
  }))
  mount(); fireEvent.change(await screen.findByLabelText('노트 제목'), {target: {value: '새 제목'}})
  await waitFor(() => expect(create).toHaveBeenCalledOnce(), {timeout: 2000})
  fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '입력 계속'}})
  const created = {...note, id: 'new1', title: '새 제목', markdown: '', version: 'created-v1'}
  resolveSave(new Response(JSON.stringify(created)))
  await waitFor(() => expect(window.location.search).toContain('note=new1'))
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('입력 계속')
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  expect(writes[0]).toMatchObject({title: '입력 계속', version: 'created-v1'})
  resolveSave(new Response(JSON.stringify({...created, title: '입력 계속', version: 'created-v2'})))
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect(create).toHaveBeenCalledOnce()
})

it('rebases later HTML text edits onto the confirmed source without replacing the live node', async () => {
  const original = {...note, html_text_preview: '<p><span data-edit-token="token" data-text-index="0">original</span></p>', html_text_token: 'token', html_text_blocks: [{index:0,text:'original'}]}
  vi.stubGlobal('fetch', vi.fn(async (path: string, init?: RequestInit) => {
    if (init?.method === 'PUT') {writes.push(JSON.parse(init.body as string)); return new Promise<Response>(resolve => {resolveSave = resolve})}
    return new Response(JSON.stringify(path === '/api/notebooks' ? {notebooks:[{id:'book1',name:'업무',stack:''}]} : path === '/api/notes' ? {notes:[original]} : path === '/api/writes' ? {operations:[]} : original))
  }))
  mount(); await edit()
  const editor = screen.getByRole('textbox', {name:'원본 HTML 편집기'})
  const span = editor.querySelector('[data-text-index="0"]')!
  span.textContent = 'sent text'; fireEvent.input(span)
  await waitFor(() => expect(writes).toHaveLength(1), {timeout:2000})
  expect(writes[0].text_changes).toEqual([{index:0,text:'sent text'}])
  span.textContent = 'newer text'; fireEvent.input(span)
  const confirmed = {...original,title:'수정 제목',html:'<p>sent text</p>',version:'v2',html_text_preview:'<p><span data-edit-token="second" data-text-index="0">sent text</span></p>',html_text_token:'second',html_text_blocks:[{index:0,text:'sent text'}]}
  resolveSave(new Response(JSON.stringify(confirmed)))
  await waitFor(() => expect(writes).toHaveLength(2), {timeout:2000})
  expect(writes[1]).toMatchObject({text_changes:[{index:0,text:'newer text'}],version:'v2'})
  expect(editor.querySelector('[data-text-index="0"]')).toBe(span)
  expect(span.textContent).toBe('newer text')
  resolveSave(new Response(JSON.stringify({...confirmed,version:'v3',html:'<p>newer text</p>',html_text_preview:'<p><span data-edit-token="third" data-text-index="0">newer text</span></p>',html_text_token:'third',html_text_blocks:[{index:0,text:'newer text'}]})))
  await screen.findByText('✓ NAS에 자동 저장됨')
})

it('saves before navigating away without a manual confirmation', async () => {
  mount(); await edit()
  fireEvent.click(screen.getByRole('button', {name: '새 노트'}))
  await waitFor(() => expect(writes).toHaveLength(1))
  expect(window.location.search).toContain('note=note1')
  resolveSave(new Response(JSON.stringify({...note,title:'수정 제목',version:'v2'})))
  await waitFor(() => expect(window.location.search).toContain('new=1'))
  expect(window.confirm).not.toHaveBeenCalled()
})

it('folds both navigation panels independently and remembers visibility without changing the draft', async () => {
  const view = mount(); await edit()
  fireEvent.click(screen.getByRole('button',{name:'책장 패널 접기'}))
  fireEvent.click(screen.getByRole('button',{name:'노트 목록 접기'}))
  expect(screen.getByRole('button',{name:'책장 패널 펼치기'}).getAttribute('aria-expanded')).toBe('false')
  expect(screen.getByRole('button',{name:'노트 목록 펼치기'}).getAttribute('aria-expanded')).toBe('false')
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('수정 제목')
  expect(writes).toHaveLength(0)
  view.unmount(); mount(); await screen.findByLabelText('노트 제목')
  expect(screen.getByRole('button',{name:'책장 패널 펼치기'})).toBeTruthy()
  expect(screen.getByRole('button',{name:'노트 목록 펼치기'})).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'책장 패널 펼치기'}))
  fireEvent.click(screen.getByRole('button',{name:'노트 목록 펼치기'}))
  expect(screen.getByRole('button',{name:'책장 패널 접기'}).getAttribute('aria-expanded')).toBe('true')
  expect(screen.getByRole('button',{name:'노트 목록 접기'}).getAttribute('aria-expanded')).toBe('true')
})

it('starts background indexing on a note page and shares it with the full graph page',async () => {
  const originalFetch=vi.mocked(fetch).getMockImplementation()!
  let finish:(value:Response)=>void = () => {}
  let batchSignal:AbortSignal|undefined
  const fetcher=vi.fn(async (url:string,init?:RequestInit) => {
    if (url === '/api/graph?summary=true') return new Response(JSON.stringify({nodes:[note],edges:[],failures:[],entries:[],pending:[note.id]}))
    if (url.startsWith('/api/graph/entries')) {batchSignal=init?.signal as AbortSignal;return new Promise<Response>(resolve=>{finish=resolve})}
    return originalFetch(url,init)
  })
  vi.stubGlobal('fetch',fetcher)
  mount();await screen.findByLabelText('노트 제목')
  await waitFor(()=>expect(batchSignal).toBeDefined())
  expect(window.location.search).not.toContain('f=graph')
  expect(screen.getByRole('status',{name:'백그라운드 인덱싱 상태'}).textContent).toContain('0/1')
  fireEvent.click(screen.getByRole('button',{name:'전체 그래프'}))
  await screen.findByRole('navigation',{name:'그래프 탐색'})
  expect(batchSignal?.aborted).toBe(false)
  expect(fetcher.mock.calls.filter(([url])=>url === '/api/graph?summary=true')).toHaveLength(1)
  const {act}=await import('@testing-library/react')
  await act(async()=>finish(new Response(JSON.stringify({entries:[{id:note.id,links:[]}]}))))
  await waitFor(()=>expect(screen.queryByRole('status',{name:'백그라운드 인덱싱 상태'})).toBeNull())
})

it('uses common history for graph selection, scope, depth and notes while replacing typing and zoom',async () => {
  const other={...note,id:'note2',title:'두 번째 노트'}
  const originalFetch=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn(async (url:string,init?:RequestInit) => {
    if(url === '/api/graph?summary=true') return new Response(JSON.stringify({nodes:[note,other],edges:[{source:note.id,target:other.id}],failures:[]}))
    return originalFetch(url,init)
  }))
  mount();await screen.findByLabelText('노트 제목')
  expect((screen.getByRole('button',{name:'이전 화면'}) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('button',{name:'전체 그래프'}))
  const nav=await screen.findByRole('navigation',{name:'그래프 탐색'})
  await within(nav).findByRole('button',{name:note.title})
  fireEvent.change(screen.getByRole('searchbox',{name:'그래프 노트 검색'}),{target:{value:note.title}})
  const before=window.history.length
  fireEvent.click(within(nav).getByRole('button',{name:note.title}))
  await within(nav).findByRole('region',{name:'선택한 노트 연결'})
  fireEvent.click(within(nav).getByRole('button',{name:'주변만 보기'}))
  fireEvent.change(screen.getByRole('combobox',{name:'연결 깊이'}),{target:{value:'2'}})
  fireEvent.click(screen.getByRole('button',{name:'확대'}))
  expect(window.history.length).toBe(before+3)
  fireEvent.click(screen.getByRole('button',{name:'이전 화면'}))
  await waitFor(()=>expect((screen.getByRole('combobox',{name:'연결 깊이'}) as HTMLSelectElement).value).toBe('1'))
  expect(screen.getByLabelText('확대 비율').textContent).toBe('100%')
  fireEvent.click(screen.getByRole('button',{name:'다음 화면'}))
  await waitFor(()=>expect((screen.getByRole('combobox',{name:'연결 깊이'}) as HTMLSelectElement).value).toBe('2'))
  expect(screen.getByLabelText('확대 비율').textContent).toBe('125%')
  fireEvent.click(within(nav).getByRole('button',{name:'노트 열기'}))
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'이전 화면'}))
  await screen.findByRole('navigation',{name:'그래프 탐색'})
  expect((screen.getByRole('combobox',{name:'연결 깊이'}) as HTMLSelectElement).value).toBe('2')
  fireEvent.click(screen.getByRole('button',{name:'이전 화면'}))
  await waitFor(()=>expect((screen.getByRole('combobox',{name:'연결 깊이'}) as HTMLSelectElement).value).toBe('1'))
  fireEvent.click(within(screen.getByRole('region',{name:'노트 그래프'})).getByRole('button',{name:'전체 그래프'}))
  expect((screen.getByRole('button',{name:'다음 화면'}) as HTMLButtonElement).disabled).toBe(true)
})

it('waits for confirmed autosave before moving through shared history',async () => {
  mount();await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'전체 노트'}))
  await screen.findByText('노트를 선택하세요')
  fireEvent.click(within(screen.getByRole('region',{name:'노트 목록'})).getByRole('button',{name:/기존 제목/}))
  await edit()
  fireEvent.click(screen.getByRole('button',{name:'이전 화면'}))
  await waitFor(()=>expect(writes).toHaveLength(1))
  expect(window.location.search).toContain('note=note1')
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('수정 제목')
  resolveSave(new Response(JSON.stringify({...note,title:'수정 제목',version:'v2'})))
  await screen.findByText('노트를 선택하세요')
  expect(window.location.search).not.toContain('note=')
})

it('opens real global search from folded panels and graph without fetching note bodies for typing',async () => {
  const other={...note,id:'note2',title:'다른 메모장 문서',notebook_id:'book2',excerpt:'중요한 일정',tags:['업무']}
  const originalFetch=vi.mocked(fetch).getMockImplementation()!
  const fetcher=vi.fn(async (url:string,init?:RequestInit) => {
    if(url === '/api/notes') return new Response(JSON.stringify({notes:[note,other]}))
    if(url === '/api/graph?summary=true') return new Response(JSON.stringify({nodes:[note,other],edges:[{source:note.id,target:other.id}],failures:[]}))
    if(url === '/api/notes/note2') return new Response(JSON.stringify(other))
    return originalFetch(url,init)
  })
  vi.stubGlobal('fetch',fetcher)
  mount();await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'노트 목록 접기'}))
  const opener=screen.getByRole('button',{name:'전체 검색'})
  opener.focus();fireEvent.click(opener)
  const dialog=screen.getByRole('dialog',{name:'전체 노트 검색'})
  const input=within(dialog).getByRole('searchbox',{name:'전체 노트 검색어'})
  expect(document.activeElement).toBe(input)
  const before=fetcher.mock.calls.length
  fireEvent.change(input,{target:{value:'일정'}})
  expect(within(dialog).getByRole('button',{name:/다른 메모장 문서/})).toBeTruthy()
  expect(fetcher.mock.calls.length).toBe(before)
  fireEvent.click(within(dialog).getByRole('button',{name:/다른 메모장 문서/}))
  await waitFor(()=>expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe(other.title))
  expect(screen.queryByRole('dialog')).toBeNull()
  fireEvent.click(screen.getByRole('button',{name:'전체 그래프'}))
  await screen.findByRole('region',{name:'노트 그래프'})
  fireEvent.click(screen.getByRole('button',{name:'전체 검색'}))
  fireEvent.keyDown(screen.getByRole('dialog',{name:'전체 노트 검색'}),{key:'Escape'})
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(document.activeElement).toBe(opener)
  expect(writes).toHaveLength(0)
})

it('keeps note autosave independent from Korean composition inside global search',async()=>{
  mount();await edit()
  fireEvent.click(screen.getByRole('button',{name:'전체 검색'}))
  const input=screen.getByRole('searchbox',{name:'전체 노트 검색어'})
  fireEvent.compositionStart(input)
  fireEvent.change(input,{target:{value:'검색'}})
  await waitFor(()=>expect(writes).toHaveLength(1),{timeout:2000})
  fireEvent.keyDown(screen.getByRole('dialog',{name:'전체 노트 검색'}),{key:'Escape'})
  resolveSave(new Response(JSON.stringify({...note,title:'수정 제목',version:'v2'})))
  await screen.findByText('✓ NAS에 자동 저장됨')
})


const draftKey = 'synonote:web-draft:["https://nas.example","alice"]:note:note1'
it('deletes a reverted draft and does not revive it on reload', async () => {
  const view=mount(); await edit()
  expect(sessionStorage.getItem(draftKey)).toContain('수정 제목')
  fireEvent.change(screen.getByLabelText('노트 제목'),{target:{value:note.title}})
  expect(sessionStorage.getItem(draftKey)).toBeNull()
  view.unmount(); mount()
  expect((await screen.findByLabelText('노트 제목') as HTMLInputElement).value).toBe(note.title)
  expect(writes).toHaveLength(0)
})
it('retains a dirty restored draft while its NAS baseline is still loading', async () => {
  const stored={key:'note:note1',title:'복원할 내용',html:note.html,notebook_id:'book1',version:'v1'}
  sessionStorage.setItem(draftKey,JSON.stringify(stored))
  const original=vi.mocked(fetch).getMockImplementation()!
  let finish!: (response:Response)=>void
  vi.stubGlobal('fetch',vi.fn((url:string,init?:RequestInit)=> url==='/api/notes/note1' ? new Promise<Response>(resolve=>{finish=resolve}) : original(url,init)))
  mount(); await screen.findByText('NAS에서 본문 가져오는 중…')
  expect(JSON.parse(sessionStorage.getItem(draftKey)!)).toEqual(stored)
  finish(new Response(JSON.stringify(note)))
  expect((await screen.findByLabelText('노트 제목') as HTMLInputElement).value).toBe(stored.title)
})
it('exports pending original HTML text changes without changing source markup', async () => {
  const html=`<!DOCTYPE html><p STYLE='color:red' data-x="a>b">old &amp; text</p><!--keep--><img ref='image' src='attachment://image'>`
  const original={...note,html,html_text_preview:`<!DOCTYPE html><p STYLE='color:red' data-x="a>b"><span data-edit-token="token" data-text-index="0">old &amp; text</span></p><!--keep--><img ref='image' src='attachment://image'>`,html_text_token:'token',html_text_blocks:[{index:0,text:'old & text',start:html.indexOf('old'),end:html.indexOf('</p>')}]}
  const fetcher=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn((url:string,init?:RequestInit)=>url==='/api/notes/note1' ? Promise.resolve(new Response(JSON.stringify(original))) : fetcher(url,init)))
  let blob!:Blob
  Object.defineProperty(URL,'createObjectURL',{configurable:true,value:vi.fn((value:Blob)=>{blob=value;return 'blob:test'})})
  Object.defineProperty(URL,'revokeObjectURL',{configurable:true,value:vi.fn()})
  vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(()=>{})
  mount(); await screen.findByLabelText('노트 제목'); fireEvent.click(screen.getByRole('button',{name:'분할'}))
  const span=screen.getByRole('textbox',{name:'원본 HTML 편집기'}).querySelector('span')!
  span.textContent='new < & >';fireEvent.input(span)
  fireEvent.click(screen.getByText('내보내기…'))
  const exported=await new Promise<string>(resolve=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result));reader.readAsText(blob)})
  expect(exported).toBe(html.replace('old &amp; text','new &lt; &amp; &gt;'))
  expect(writes).toHaveLength(0)
})
it('remaps a renamed shelf, expansion and prior history without adding a visit',async()=>{
  let stack='프로젝트'
  const original=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn(async(url:string,init?:RequestInit)=>{
    if(url==='/api/notebooks') return new Response(JSON.stringify({notebooks:[{id:'book1',name:'업무',stack}]}))
    if(url==='/api/library/action'){stack='새 책장';return new Response('{}')}
    return original(url,init)
  }))
  mount();await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'프로젝트'}))
  const before=window.history.length
  fireEvent.contextMenu(screen.getByRole('button',{name:'프로젝트'}))
  fireEvent.click(screen.getByText('이름 변경…'))
  fireEvent.change(screen.getByLabelText('이름'),{target:{value:'새 책장'}})
  fireEvent.click(screen.getByRole('button',{name:'확인'}))
  await screen.findByRole('button',{name:'새 책장'})
  expect(new URLSearchParams(window.location.search).get('s')).toBe('새 책장')
  expect(screen.getByRole('button',{name:'새 책장 책장 접기'})).toBeTruthy()
  expect(window.history.length).toBe(before)
  expect(within(screen.getByRole('region',{name:'노트 목록'})).getByRole('button',{name:/기존 제목/})).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'전체 노트'}))
  fireEvent.click(screen.getByRole('button',{name:'이전 화면'}))
  await waitFor(()=>expect(new URLSearchParams(window.location.search).get('s')).toBe('새 책장'))
  fireEvent.click(screen.getByRole('button',{name:'이전 화면'}))
  await screen.findByLabelText('노트 제목')
  expect(new URLSearchParams(window.location.search).get('s')).not.toBe('프로젝트')
})
it('reviews acknowledged uncertain results without replay and preserves review across navigation and reload',async()=>{
  let pending=false,confirmed=false,reads=0
  const original=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn(async(url:string,init?:RequestInit)=>{
    if(url==='/api/writes') return new Response(JSON.stringify({operations:pending?[{operation_id:'op',note_id:'note1',target:'note1',title:note.title,status:'uncertain',created:0}]:[]}))
    if(url==='/api/writes/op/ack'){pending=false;confirmed=true;return new Response('{}')}
    if(url==='/api/notes/note1' && !init?.method){reads++;return new Response(JSON.stringify(confirmed?{...note,title:'NAS 확인 결과',version:'v2'}:note))}
    return original(url,init)
  }))
  const view=mount();await edit()
  await waitFor(()=>expect(writes).toHaveLength(1),{timeout:2000})
  pending=true;resolveSave(new Response(JSON.stringify({error:'WRITE_UNCERTAIN'}),{status:409}))
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  await screen.findByText('확인한 NAS 결과와 보관한 편집본을 검토하세요')
  expect(reads).toBe(2)
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('수정 제목')
  expect(screen.getByText('NAS 확인 결과',{selector:'strong'})).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'전체 노트'}))
  await screen.findByText('노트를 선택하세요')
  expect(writes).toHaveLength(1)
  fireEvent.click(within(screen.getByRole('region',{name:'노트 목록'})).getByRole('button',{name:/기존 제목/}))
  await screen.findByText('확인한 NAS 결과와 보관한 편집본을 검토하세요')
  view.unmount();const logout=vi.fn(async()=>{});mount(logout)
  await screen.findByText('확인한 NAS 결과와 보관한 편집본을 검토하세요')
  await new Promise(resolve=>setTimeout(resolve,950));expect(writes).toHaveLength(1)
  fireEvent.click(screen.getByRole('button',{name:'로그아웃'}))
  await waitFor(()=>expect(logout).toHaveBeenCalledOnce())
  expect(sessionStorage.getItem(draftKey)).toContain('수정 제목')
})

it('echoes real server structural slots and layout after inline deletion with another edit queued',async()=>{
  // Captured from backend html_text.annotate: root, empty and whitespace slots
  // are part of the interface. Text identities are never positional guesses.
  const original={...note,"html_text_preview": "<span data-edit-token=\"fixture-token\" data-text-index=\"0\"></span><p><span data-edit-token=\"fixture-token\" data-text-index=\"1\"></span><strong><span data-edit-token=\"fixture-token\" data-text-index=\"2\">A</span></strong><span data-edit-token=\"fixture-token\" data-text-index=\"3\"> B </span><em><span data-edit-token=\"fixture-token\" data-text-index=\"4\">C</span></em><span data-edit-token=\"fixture-token\" data-text-index=\"5\"></span></p><span data-edit-token=\"fixture-token\" data-text-index=\"6\"></span>", "html_text_token": "fixture-token", "html_text_layout": "html-text-v2:329fe7890a3cb1aa4796f6f62ad9af15d42206c62822f9662840711b83798077", "html_text_blocks": [{"index": 0, "text": "", "start": 0, "end": 0}, {"index": 1, "text": "", "start": 3, "end": 3}, {"index": 2, "text": "A", "start": 11, "end": 12}, {"index": 3, "text": " B ", "start": 21, "end": 24}, {"index": 4, "text": "C", "start": 28, "end": 29}, {"index": 5, "text": "", "start": 34, "end": 34}, {"index": 6, "text": "", "start": 38, "end": 38}], "html": "<p><strong>A</strong> B <em>C</em></p>"}
  const confirmed={...note,"html_text_preview": "<span data-edit-token=\"fixture-token\" data-text-index=\"0\"></span><p><span data-edit-token=\"fixture-token\" data-text-index=\"1\"></span><strong><span data-edit-token=\"fixture-token\" data-text-index=\"2\"></span></strong><span data-edit-token=\"fixture-token\" data-text-index=\"3\"> B </span><em><span data-edit-token=\"fixture-token\" data-text-index=\"4\">C</span></em><span data-edit-token=\"fixture-token\" data-text-index=\"5\"></span></p><span data-edit-token=\"fixture-token\" data-text-index=\"6\"></span>", "html_text_token": "fixture-token", "html_text_layout": "html-text-v2:613040eef5fdc52321b8d3e108bcd1b46ec7bfd0e83d6868748ac324f321b97d", "html_text_blocks": [{"index": 0, "text": "", "start": 0, "end": 0}, {"index": 1, "text": "", "start": 3, "end": 3}, {"index": 2, "text": "", "start": 11, "end": 11}, {"index": 3, "text": " B ", "start": 20, "end": 23}, {"index": 4, "text": "C", "start": 27, "end": 28}, {"index": 5, "text": "", "start": 33, "end": 33}, {"index": 6, "text": "", "start": 37, "end": 37}], "html": "<p><strong></strong> B <em>C</em></p>",version:'v2'}
  const a=original.html_text_blocks.find(block=>block.text==='A')!
  const b=original.html_text_blocks.find(block=>block.text===' B ')!
  expect(a.index).not.toBe(0)
  expect(original.html_text_blocks.filter(block=>block.text==='')).toHaveLength(4)
  const base=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn((url:string,init?:RequestInit)=>url==='/api/notes/note1' && !init?.method ? Promise.resolve(new Response(JSON.stringify(original))) : base(url,init)))
  mount();await screen.findByLabelText('노트 제목');fireEvent.click(screen.getByRole('button',{name:'분할'}))
  const editor=screen.getByRole('textbox',{name:'원본 HTML 편집기'})
  const first=editor.querySelector(`[data-text-index="${a.index}"]`)!,second=editor.querySelector(`[data-text-index="${b.index}"]`)!
  first.textContent='';fireEvent.input(first)
  await waitFor(()=>expect(writes).toHaveLength(1),{timeout:2000})
  expect(writes[0]).toMatchObject({text_layout:original.html_text_layout,text_changes:[{index:a.index,text:''}]})
  second.textContent=' D ';fireEvent.input(second)
  resolveSave(new Response(JSON.stringify(confirmed)))
  await waitFor(()=>expect(writes).toHaveLength(2),{timeout:2000})
  expect(writes[1]).toMatchObject({version:'v2',text_layout:confirmed.html_text_layout,text_changes:[{index:b.index,text:' D '}]})
  expect(editor.querySelector(`[data-text-index="${b.index}"]`)).toBe(second)
  expect(second.textContent).toBe(' D ')
})
it('persists a create key before POST and reconciles a lost response via receipt without a second POST',async()=>{
  window.history.replaceState({},'', '/?n=book1&new=1')
  const key='synonote:web-draft:["https://nas.example","alice"]:new:book1'
  let receipt=false,createCalls=0,requestId=''
  const created={...note,id:'created-receipt',title:'새 제목',markdown:'',version:'v2'}
  const base=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn(async(url:string,init?:RequestInit)=>{
    if(url==='/api/notes' && init?.method==='POST'){
      createCalls++; const body=JSON.parse(init.body as string);requestId=body.client_request_id
      expect(requestId).toMatch(/^[0-9a-f-]{36}$/)
      const persisted=JSON.parse(sessionStorage.getItem(key)!)
      expect(persisted.client_request_id).toBe(requestId);expect(persisted.review_required).toBe(true)
      receipt=true;throw new TypeError('response lost')
    }
    if(url.startsWith('/api/creates/'))return new Response(JSON.stringify(receipt?{status:'completed',note:created}:{status:'absent'}))
    if(url==='/api/notes/created-receipt')return new Response(JSON.stringify(created))
    return base(url,init)
  }))
  const view=mount();fireEvent.change(await screen.findByLabelText('노트 제목'),{target:{value:'새 제목'}})
  await screen.findByText('자동 저장 중단 · 편집본 보관됨',{}, {timeout:2000})
  expect(createCalls).toBe(1)
  view.unmount();mount()
  await waitFor(()=>expect(window.location.search).toContain('note=created-receipt'))
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect(createCalls).toBe(1);expect(writes).toHaveLength(0)
})
it.each(['pending','uncertain','reviewed'])('never replays a restored %s create receipt',async(status)=>{
  window.history.replaceState({},'', '/?n=book1&new=1')
  sessionStorage.setItem('synonote:web-draft:["https://nas.example","alice"]:new:book1',JSON.stringify({key:'new:book1',title:'보관 제목',markdown:'본문',html:'<p></p>',notebook_id:'book1',client_request_id:'12345678-1234-4234-8234-123456789abc',review_required:true}))
  const base=vi.mocked(fetch).getMockImplementation()!
  const fetcher=vi.fn(async(url:string,init?:RequestInit)=>url.startsWith('/api/creates/')?new Response(JSON.stringify({status})):base(url,init))
  vi.stubGlobal('fetch',fetcher);mount()
  await screen.findByText('새 노트 저장 결과 확인 필요')
  await new Promise(resolve=>setTimeout(resolve,950))
  expect(fetcher.mock.calls.filter(([,init])=>init?.method==='POST' || init?.method==='PUT')).toHaveLength(0)
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('보관 제목')
})

it('does not retransmit an existing note when reloaded while its write response is unresolved',async()=>{
  const view=mount();await edit()
  await waitFor(()=>expect(writes).toHaveLength(1),{timeout:2000})
  expect(JSON.parse(sessionStorage.getItem(draftKey)!)).toMatchObject({review_required:true})
  view.unmount();mount();await screen.findByLabelText('노트 제목')
  await new Promise(resolve=>setTimeout(resolve,950))
  expect(writes).toHaveLength(1)
  expect(screen.getByText('자동 저장 중단 · 편집본 보관됨')).toBeTruthy()
})
it('keeps an acknowledged draft stopped when detail reload fails and only discards on explicit review',async()=>{
  let pending=false,acked=false,failRead=true
  const base=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn(async(url:string,init?:RequestInit)=>{
    if(url==='/api/writes') return new Response(JSON.stringify({operations:pending?[{operation_id:'op',note_id:'note1',target:'note1',title:note.title,status:'uncertain',created:0}]:[]}))
    if(url==='/api/writes/op/ack'){pending=false;acked=true;return new Response('{}')}
    if(url==='/api/notes/note1' && !init?.method && acked) return failRead ? new Response(JSON.stringify({error:'NAS_UNAVAILABLE'}),{status:502}) : new Response(JSON.stringify({...note,version:'v2'}))
    return base(url,init)
  }))
  mount();await edit();await waitFor(()=>expect(writes).toHaveLength(1),{timeout:2000})
  pending=true;resolveSave(new Response(JSON.stringify({error:'WRITE_UNCERTAIN'}),{status:409}))
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  await screen.findByRole('button',{name:'NAS 확인본 다시 불러오기'})
  await screen.findByText('NAS와 통신하지 못했습니다. 주소·포트·인증서·방화벽을 확인하세요.')
  expect(JSON.parse(sessionStorage.getItem(draftKey)!)).toMatchObject({review_required:true,recovery_acknowledged:true,title:'수정 제목'})
  failRead=false;fireEvent.click(screen.getByRole('button',{name:'NAS 확인본 다시 불러오기'}))
  await screen.findByText('확인한 NAS 결과와 보관한 편집본을 검토하세요')
  expect(writes).toHaveLength(1)
  fireEvent.click(screen.getByRole('button',{name:'편집본 버리고 NAS 확인본 사용'}))
  await waitFor(()=>expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe(note.title))
  expect(sessionStorage.getItem(draftKey)).toBeNull();expect(writes).toHaveLength(1)
})
it('archives a reviewed create before explicitly starting a different UUID',async()=>{
  window.history.replaceState({},'', '/?n=book1&new=1')
  const key='synonote:web-draft:["https://nas.example","alice"]:new:book1'
  const oldId='12345678-1234-4234-8234-123456789abc'
  sessionStorage.setItem(key,JSON.stringify({key:'new:book1',title:'보관 제목',markdown:'',html:'<p></p>',notebook_id:'book1',client_request_id:oldId,review_required:true}))
  const base=vi.mocked(fetch).getMockImplementation()!
  let posted:Record<string,unknown>|undefined
  vi.stubGlobal('fetch',vi.fn(async(url:string,init?:RequestInit)=>{
    if(url.startsWith('/api/creates/'))return new Response(JSON.stringify({status:'reviewed',operation_id:'op'}))
    if(url==='/api/notes' && init?.method==='POST'){posted=JSON.parse(init.body as string);return new Promise<Response>(()=>{})}
    return base(url,init)
  }))
  mount();const restart=await screen.findByRole('button',{name:'초안 보관하고 별도 노트 생성'})
  expect(posted).toBeUndefined()
  fireEvent.click(restart)
  await waitFor(()=>expect(posted).toBeTruthy(),{timeout:2000})
  expect(posted!.client_request_id).not.toBe(oldId)
  expect(sessionStorage.getItem(`${key}:held:${oldId}`)).toContain('보관 제목')
})
it('exports UTF16 offsets and an empty structural slot without normalizing untouched HTML',async()=>{
  const html="<p>😀</p><strong></strong><em data-X='A &amp; B'>C</em>"
  const offset=html.indexOf('</strong>')
  const original={...note,html,html_text_layout:'utf16-layout',html_text_preview:'<p>😀</p><strong><span data-edit-token="token" data-text-index="7"></span></strong><em>C</em>',html_text_token:'token',html_text_blocks:[{index:7,text:'',start:offset,end:offset}]}
  const base=vi.mocked(fetch).getMockImplementation()!
  vi.stubGlobal('fetch',vi.fn((url:string,init?:RequestInit)=>url==='/api/notes/note1' && !init?.method ? Promise.resolve(new Response(JSON.stringify(original))) : base(url,init)))
  let blob!:Blob
  Object.defineProperty(URL,'createObjectURL',{configurable:true,value:(value:Blob)=>{blob=value;return 'blob:test'}})
  Object.defineProperty(URL,'revokeObjectURL',{configurable:true,value:vi.fn()});vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(()=>{})
  mount();await screen.findByLabelText('노트 제목');fireEvent.click(screen.getByRole('button',{name:'분할'}))
  const span=screen.getByRole('textbox',{name:'원본 HTML 편집기'}).querySelector('span')!;span.textContent='D & E';fireEvent.input(span)
  fireEvent.click(screen.getByText('내보내기…'))
  const exported=await new Promise<string>(resolve=>{const r=new FileReader();r.onload=()=>resolve(String(r.result));r.readAsText(blob)})
  expect(exported).toBe(html.slice(0,offset)+'D &amp; E'+html.slice(offset))
})

it('recovers newer typing after a completed create receipt using PUT with the receipt version',async()=>{
  window.history.replaceState({},'', '/?n=book1&new=1')
  const key='synonote:web-draft:["https://nas.example","alice"]:new:book1'
  const receipt={...note,id:'created-note',title:'전송 제목',html:'<p>sent</p>',markdown:'',version:'receipt-v1'}
  sessionStorage.setItem(key,JSON.stringify({key:'new:book1',title:'더 입력한 제목',markdown:'',html:'<p></p>',notebook_id:'book1',client_request_id:'12345678-1234-4234-8234-123456789abc',review_required:true,create_sent:{title:'전송 제목',markdown:'',html:'<p></p>'}}))
  const base=vi.mocked(fetch).getMockImplementation()!
  const fetcher=vi.fn(async(url:string,init?:RequestInit)=>url.startsWith('/api/creates/')?new Response(JSON.stringify({status:'completed',note:receipt})):base(url,init))
  vi.stubGlobal('fetch',fetcher);mount()
  await waitFor(()=>expect(window.location.search).toContain('note=created-note'))
  await waitFor(()=>expect(writes).toHaveLength(1),{timeout:2000})
  expect(writes[0]).toMatchObject({title:'더 입력한 제목',version:'receipt-v1'})
  expect(fetcher.mock.calls.filter(([url,init])=>url==='/api/notes' && init?.method==='POST')).toHaveLength(0)
})
it('does not mutate the NAS when unresolved-write state cannot be persisted',async()=>{
  mount();await screen.findByLabelText('노트 제목')
  vi.spyOn(Storage.prototype,'setItem').mockImplementation(()=>{throw new Error('storage unavailable')})
  await edit()
  await screen.findByText('편집본을 이 탭에 보관할 수 없어 저장을 중단했습니다. 브라우저 저장소 설정을 확인하세요.',{}, {timeout:2000})
  expect(writes).toHaveLength(0)
})
