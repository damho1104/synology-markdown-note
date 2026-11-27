// @vitest-environment jsdom
import { readFileSync } from 'node:fs'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { Workspace } from './Workspace'
import { setLanguage, translate } from './i18n'
import { supportedLanguages } from './catalogs'
import type { Status } from './api'
import { exportMath } from './mathExport'
import { DEFAULT_PREFERENCES, PREFERENCES_KEY, loadPreferences } from './preferences'

const styles = readFileSync('src/style.css', 'utf8')

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
    if (path === '/api/search/body') return Response.json({matches:[], indexed:1, total:1})
    if (path === '/api/graph?summary=true') return new Response(JSON.stringify({nodes:[note],edges:[],failures:[],entries:[{id:note.id,links:[]}],pending:[]}))
    const body = path === '/api/notebooks' ? {notebooks: [{id: 'book1', name: '업무', stack: '프로젝트'}]} : path === '/api/notes' ? {notes: [note]} : path === '/api/writes' ? {operations: []} : note
    return new Response(JSON.stringify(body), {status: 200})
  }))
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); setLanguage('ko') })
function mount(onLogout = async () => {}, workspaceStatus: Status = status) { return render(<Workspace session={session} status={workspaceStatus} onLogout={onLogout} onSessionExpired={() => {}} />) }
async function edit() { await screen.findByLabelText('노트 제목'); const split = screen.queryByRole('button', {name: '분할'}); if (split) fireEvent.click(split); fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '수정 제목'}}) }

it('updates the NAS indicator after a failed list refresh and successful retry', async () => {
  let unavailable = false
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation((path, init) =>
    path === '/api/notes' && unavailable
      ? Promise.resolve(Response.json({error: 'NAS_UNAVAILABLE'}, {status: 503}))
      : fetcher(path, init))
  mount()
  const connected = await screen.findByRole('img', {name: 'NAS 연결됨'})
  expect(connected.querySelector('svg')).toBeTruthy()
  expect(connected.querySelector('.nas-connection-dot')).toBeTruthy()
  expect(styles).toMatch(/\.nas-connection-status\s*\{[^}]*position:\s*relative/s)
  expect(styles).toMatch(/\.nas-connection-dot\s*\{[^}]*position:\s*absolute[^}]*right:\s*-2px[^}]*bottom:\s*-2px/s)
  expect(styles).toMatch(/\.nas-connection-status\[data-connected="true"\]\s+\.nas-connection-dot\s*\{[^}]*var\(--nas-connected/s)
  expect(styles).toMatch(/\.nas-connection-dot\s*\{[^}]*var\(--nas-disconnected/s)
  expect(connected.getAttribute('data-connected')).toBe('true')
  expect(connected.closest('.account-footer')?.textContent).toContain('NAS 연결 · 조회 가능')
  const refresh = screen.getByRole('button', {name: '새로고침'})
  unavailable = true
  fireEvent.click(refresh)
  const disconnected = await screen.findByRole('img', {name: 'NAS 연결 안 됨'})
  expect(disconnected.querySelector('svg')).toBeTruthy()
  expect(disconnected.getAttribute('data-connected')).toBe('false')
  unavailable = false
  fireEvent.click(refresh)
  await screen.findByRole('img', {name: 'NAS 연결됨'})
})

it('shows a failed note connection even when the NAS list had already loaded', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let rejectDetail!: (response: Response) => void
  vi.mocked(fetch).mockImplementation((path, init) => path === '/api/notes/note1'
    ? new Promise(resolve => { rejectDetail = resolve })
    : fetcher(path, init))
  mount()
  await screen.findByRole('img', {name: 'NAS 연결됨'})
  rejectDetail(Response.json({error: 'NAS_UNAVAILABLE'}, {status: 503}))
  await screen.findByRole('img', {name: 'NAS 연결 안 됨'})
})

it('does not let an older successful list request hide a newer connection failure', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let finishList!: (response: Response) => void
  vi.mocked(fetch).mockImplementation((path, init) => {
    if (path === '/api/notes') return new Promise(resolve => { finishList = resolve })
    if (path === '/api/notes/note1') return Promise.resolve(Response.json({error: 'NAS_UNAVAILABLE'}, {status: 503}))
    return fetcher(path, init)
  })
  mount()
  await screen.findByText('NAS와 통신하지 못했습니다. 주소·포트·인증서·방화벽을 확인하세요.')
  await act(async () => finishList(Response.json({notes: [note]})))
  expect(screen.getByRole('img', {name: 'NAS 연결 안 됨'})).toBeTruthy()
})

it('keeps a title cleared while a formatted title save is in flight', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  const formatted = {...note, html_text_preview: '<p>original</p>', html_text_token: 'token',
    html_text_blocks: [{index: 0, text: 'original', start: 3, end: 11}]}
  vi.mocked(fetch).mockImplementation((path, init) => path === '/api/notes/note1' && !init?.method
    ? Promise.resolve(Response.json(formatted))
    : fetcher(path, init))
  mount()
  const input = await screen.findByRole<HTMLInputElement>('textbox', {name: '노트 제목'})
  fireEvent.change(input, {target: {value: 'Untitled'}})
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  fireEvent.change(input, {target: {value: ''}})
  await act(async () => resolveSave(Response.json({...formatted, title: 'Untitled', version: 'v2'})))
  expect(input.value).toBe('')
})

it.each(supportedLanguages)('retains the saved %s default title when restoring a blank formatted draft', async language => {
  setLanguage('en')
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  const formatted = {...note, title: translate(language, 'common.untitled'),
    html_text_preview: '<p>original</p>', html_text_token: 'token',
    html_text_blocks: [{index: 0, text: 'original', start: 3, end: 11}]}
  vi.mocked(fetch).mockImplementation((path, init) => path === '/api/notes/note1' && !init?.method
    ? Promise.resolve(Response.json(formatted))
    : fetcher(path, init))
  sessionStorage.setItem('synonote:web-draft:["https://nas.example","alice"]:note:note1',
    JSON.stringify({key: 'note:note1', title: '', html: note.html, text_changes: [],
      notebook_id: note.notebook_id, version: note.version}))
  mount()
  expect((await screen.findByRole<HTMLInputElement>('textbox', {name: 'Note title'})).value).toBe('')
  await act(async () => new Promise(resolve => setTimeout(resolve, 900)))
  expect(writes).toHaveLength(0)
})

it('formats the editor footer in English and preserves the NAS title', async () => {
  setLanguage('en')
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  const markdown = 'x'.repeat(1234)
  vi.mocked(fetch).mockImplementation((path, init) => path === '/api/notes/note1'
    ? Promise.resolve(Response.json({...note, markdown}))
    : fetcher(path, init))
  mount()
  expect((await screen.findByRole('textbox', {name: 'Note title'}) as HTMLInputElement).value).toBe('기존 제목')
  expect(screen.getByText('Characters: 1,234 · Version v1')).toBeTruthy()
  expect(writes).toHaveLength(0)
})

it.each([
  ['en', 'New Note', 'Note title', 'Markdown body'],
  ['ko', '새 노트', '노트 제목', 'Markdown 본문'],
] as const)(
  'prefills the %s default title and saves it when the new note is edited',
  async (language, expectedTitle, titleLabel, bodyLabel) => {
    setLanguage(language)
    window.history.replaceState({}, '', '/?n=book1&new=1')
    const fetcher = vi.mocked(fetch).getMockImplementation()!
    const create = vi.fn()
    vi.mocked(fetch).mockImplementation((path, init) => {
      if (path !== '/api/notes' || init?.method !== 'POST') return fetcher(path, init)
      const payload = JSON.parse(init.body as string)
      create(payload)
      return Promise.resolve(Response.json({...note, id: 'new1', title: payload.title, markdown: payload.markdown}))
    })
    mount()
    expect((await screen.findByRole<HTMLInputElement>('textbox', {name: titleLabel})).value).toBe(expectedTitle)
    await act(async () => new Promise(resolve => setTimeout(resolve, 900)))
    expect(create).not.toHaveBeenCalled()
    const editor = await screen.findByRole('textbox', {name: bodyLabel})
    const {EditorView} = await import('@codemirror/view')
    const view = EditorView.findFromDOM(editor.closest('.cm-editor') as HTMLElement)!
    act(() => view.dispatch({changes: {from: 0, insert: 'New body'}}))
    await waitFor(() => expect(create).toHaveBeenCalledOnce(), {timeout: 2000})
    expect(create).toHaveBeenCalledWith(expect.objectContaining({title: expectedTitle, markdown: 'New body'}))
  },
)

it('keeps the previously saved Korean default title when editing the body in English', async () => {
  setLanguage('en')
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  const saved = {...note, title: '제목 없음'}
  vi.mocked(fetch).mockImplementation((path, init) => path === '/api/notes/note1' && !init?.method
    ? Promise.resolve(Response.json(saved))
    : fetcher(path, init))
  mount()
  const title = await screen.findByRole<HTMLInputElement>('textbox', {name: 'Note title'})
  expect(title.value).toBe('제목 없음')
  fireEvent.click(screen.getByRole('button', {name: 'Split'}))
  fireEvent.change(screen.getByLabelText('HTML body'), {target: {value: '<p>edited body</p>'}})
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  expect(writes[0]).toMatchObject({title: '제목 없음', html: '<p>edited body</p>'})
})

it('opens the Markdown search panel with Korean field and button labels', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation((path, init) => path === '/api/notes/note1'
    ? Promise.resolve(Response.json({...note, markdown: '# 본문'}))
    : fetcher(path, init))
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button', {name: '분할'}))
  const editor = await screen.findByRole('textbox', {name: 'Markdown 본문'})
  editor.focus()
  const isMac = /Mac/.test(navigator.platform)
  fireEvent.keyDown(editor, {key: 'f', metaKey: isMac, ctrlKey: !isMac})
  expect(await screen.findByRole('textbox', {name: /^찾기$/})).toBeTruthy()
  expect(screen.getByRole('button', {name: '모두 바꾸기'})).toBeTruthy()
})

it('refreshes once when returning to a hidden tab after the interval', async () => {
  const hidden = vi.spyOn(document, 'hidden', 'get').mockReturnValue(false)
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    const listRequests = () => vi.mocked(fetch).mock.calls.filter(([path]) => path === '/api/notes').length
    act(() => { hidden.mockReturnValue(true); document.dispatchEvent(new Event('visibilitychange')) })
    await act(() => vi.advanceTimersByTimeAsync(900_000))
    expect(listRequests()).toBe(1)
    hidden.mockReturnValue(false)
    await act(async () => { document.dispatchEvent(new Event('visibilitychange')); await vi.advanceTimersByTimeAsync(1) })
    expect(listRequests()).toBe(2)
  } finally {
    vi.useRealTimers()
  }
})

it('cancels an in-flight automatic refresh when the tab is hidden', async () => {
  const hidden = vi.spyOn(document, 'hidden', 'get').mockReturnValue(false)
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let delayedSignal: AbortSignal | undefined
  vi.mocked(fetch).mockImplementation((path, init) => {
    if (path === '/api/notes' && new Headers(init?.headers).has('X-Synonote-Background')) {
      return new Promise((_, reject) => {
        delayedSignal = init?.signal ?? undefined
        delayedSignal?.addEventListener('abort', () => reject(delayedSignal?.reason))
      })
    }
    return fetcher(path, init)
  })
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    await act(() => vi.advanceTimersByTimeAsync(300_000))
    expect(delayedSignal?.aborted).toBe(false)
    await act(async () => { hidden.mockReturnValue(true); document.dispatchEvent(new Event('visibilitychange')) })
    expect(delayedSignal?.aborted).toBe(true)
  } finally {
    vi.useRealTimers()
  }
})

it('refreshes the full library after five minutes without reloading the open editor', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let remoteChanged = false
  vi.mocked(fetch).mockImplementation((path, init) => {
    if (remoteChanged && path === '/api/notebooks') return Promise.resolve(Response.json({notebooks: [
      {id: 'book1', name: '업무', stack: '프로젝트'}, {id: 'book2', name: '다른 기기의 메모장', stack: ''},
    ]}))
    if (remoteChanged && path === '/api/notes') return Promise.resolve(Response.json({notes: [
      note, {...note, id: 'note2', title: '다른 기기의 메모'},
    ]}))
    return fetcher(path, init)
  })
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    const title = screen.getByLabelText('노트 제목')
    remoteChanged = true
    await act(() => vi.advanceTimersByTimeAsync(299_999))
    expect(screen.queryByText('다른 기기의 메모')).toBeNull()
    await act(() => vi.advanceTimersByTimeAsync(1))
    expect(screen.getByText('다른 기기의 메모')).toBeTruthy()
    expect(screen.getByRole('button', {name: '다른 기기의 메모장'})).toBeTruthy()
    expect(screen.getByLabelText('노트 제목')).toBe(title)
  } finally {
    vi.useRealTimers()
  }
})

it('keeps a saved change when an earlier background list request finishes late', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let delayNotes = false
  let resolveNotes: (response: Response) => void = () => {}
  vi.mocked(fetch).mockImplementation((path, init) => delayNotes && path === '/api/notes'
    ? new Promise(resolve => { resolveNotes = resolve }) : fetcher(path, init))
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    delayNotes = true
    await act(() => vi.advanceTimersByTimeAsync(300_000))
    expect(vi.mocked(fetch).mock.calls.filter(([path]) => path === '/api/notes')).toHaveLength(2)
    expect(screen.getByText('기존 제목')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '수정 제목'}})
    await act(() => vi.advanceTimersByTimeAsync(1_000))
    expect(writes).toHaveLength(1)
    await act(async () => {
      resolveSave(Response.json({...note, title: '수정 제목', version: 'v2'}))
    })
    expect(screen.getByText('✓ NAS에 자동 저장됨')).toBeTruthy()
    await act(async () => { resolveNotes(Response.json({notes: [note]})) })
    expect(screen.getByText('수정 제목')).toBeTruthy()
    expect(screen.queryByText('기존 제목')).toBeNull()
  } finally {
    vi.useRealTimers()
  }
})

it.each([true, false])('resumes automatic refresh after an unresponsive list request (initial: %s)', async (initial) => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let hangNextRequest = initial
  let remoteChanged = false
  let releaseRequest = () => {}
  vi.mocked(fetch).mockImplementation((path, init) => {
    if (path === '/api/notes' && hangNextRequest) {
      hangNextRequest = false
      return new Promise((_, reject) => {
        releaseRequest = () => reject(new Error('test connection closed'))
        init?.signal?.addEventListener('abort', releaseRequest)
      })
    }
    if (path === '/api/notes' && remoteChanged) return Promise.resolve(Response.json({notes: [
      note, {...note, id: 'note2', title: '응답 복구 후 메모'},
    ]}))
    return fetcher(path, init)
  })
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    hangNextRequest = !initial
    remoteChanged = true
    await act(() => vi.advanceTimersByTimeAsync(initial ? 60_000 : 300_000))
    expect(screen.queryByText('응답 복구 후 메모')).toBeNull()
    await act(() => vi.advanceTimersByTimeAsync(initial ? 240_000 : 360_000))
    expect(screen.getByText('응답 복구 후 메모')).toBeTruthy()
  } finally {
    await act(async () => { releaseRequest() })
    vi.useRealTimers()
  }
})

it('aborts the other list request when one fails', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let aborted = false
  vi.mocked(fetch).mockImplementation((path, init) => {
    if (path === '/api/notebooks') return Promise.resolve(Response.json({error: 'NAS_UNAVAILABLE'}, {status: 503}))
    if (path === '/api/notes') return new Promise((_, reject) => {
      init?.signal?.addEventListener('abort', () => { aborted = true; reject(init.signal?.reason) })
    })
    return fetcher(path, init)
  })
  await act(async () => { mount() })
  expect(aborted).toBe(true)
  expect(screen.getByRole('button', {name: '재시도'})).toBeTruthy()
})

it('keeps a draft retryable when authentication times out before the save is sent', async () => {
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let hangAuth = false
  vi.mocked(fetch).mockImplementation((path, init) => {
    if (path === '/api/auth/me' && hangAuth) return new Promise((_, reject) => {
      init?.signal?.addEventListener('abort', () => reject(init.signal?.reason))
    })
    return fetcher(path, init)
  })
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    hangAuth = true
    fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '재시도할 제목'}})
    await act(() => vi.advanceTimersByTimeAsync(61_000))
    expect(writes).toHaveLength(0)
    expect(screen.queryByRole('button', {name: 'NAS 확인본 다시 불러오기'})).toBeNull()
    expect(JSON.parse(sessionStorage.getItem(sessionStorage.key(0)!)!).review_required).toBeFalsy()
    hangAuth = false
    await act(async () => { fireEvent.click(screen.getByRole('button', {name: '자동 저장 다시 시도'})) })
    await act(() => vi.advanceTimersByTimeAsync(1_000))
    expect(writes[0]).toMatchObject({title: '재시도할 제목', version: 'v1'})
    await act(async () => { resolveSave(Response.json({...note, title: '재시도할 제목', version: 'v2'})) })
  } finally {
    vi.useRealTimers()
  }
})

it('uses the saved refresh interval immediately and enforces a one minute minimum', async () => {
  vi.useFakeTimers()
  try {
    await act(async () => { mount() })
    const listRequests = () => vi.mocked(fetch).mock.calls.filter(([path]) => path === '/api/notes').length
    fireEvent.click(screen.getByRole('button', {name: /^설정$/}))
    const interval = screen.getByRole('spinbutton', {name: /목록 갱신 주기/}) as HTMLInputElement
    expect(interval.value).toBe('5')
    fireEvent.change(interval, {target: {value: '0'}})
    expect(loadPreferences().listRefreshMinutes).toBe(5)
    fireEvent.blur(interval)
    expect(interval.value).toBe('1')
    expect(loadPreferences().listRefreshMinutes).toBe(1)
    await act(() => vi.advanceTimersByTimeAsync(59_999))
    expect(listRequests()).toBe(1)
    await act(() => vi.advanceTimersByTimeAsync(1))
    expect(listRequests()).toBe(2)
    cleanup()
    await act(() => vi.advanceTimersByTimeAsync(60_000))
    expect(listRequests()).toBe(2)
  } finally {
    vi.useRealTimers()
  }
})

it('follows the mobile bookshelf, notebook, note and editor hierarchy through browser history', async () => {
  window.history.replaceState({}, '', '/')
  const {container} = mount()
  const expectPage = (page: string) => expect(container.querySelector('.native-columns')?.getAttribute('data-mobile-page')).toBe(page)
  expectPage('shelves')
  fireEvent.click(await screen.findByRole('button',{name:'프로젝트'}))
  expectPage('notebooks')
  expect(new URLSearchParams(location.search).get('s')).toBe('프로젝트')
  fireEvent.click(screen.getByRole('button',{name:'업무'}))
  expectPage('notes')
  fireEvent.click(await screen.findByRole('button',{name:/기존 제목/}))
  await screen.findByLabelText('노트 제목')
  expectPage('editor')
  fireEvent.change(screen.getByLabelText('노트 제목'),{target:{value:'모바일 수정'}})
  fireEvent.click(screen.getByRole('button',{name:'메모 목록으로 돌아가기'}))
  await waitFor(()=>expect(writes).toHaveLength(1))
  expectPage('editor')
  resolveSave(Response.json({...note,title:'모바일 수정',version:'v2'}))
  await waitFor(()=>expectPage('notes'))
  fireEvent.click(screen.getByRole('button',{name:'메모장 목록으로 돌아가기'}))
  await waitFor(()=>expectPage('notebooks'))
  fireEvent.click(screen.getByRole('button',{name:'책장 목록으로 돌아가기'}))
  await waitFor(()=>expectPage('shelves'))
  fireEvent.click(screen.getByRole('button',{name:'다음 화면'}))
  await waitFor(()=>expectPage('notebooks'))
})

it('goes up from a deep-linked mobile note to its unfiled notebook and retains the empty shelf in the URL', async () => {
  window.history.replaceState({}, '', '/?note=note1')
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation((url,init) => url === '/api/notebooks'
    ? Promise.resolve(Response.json({notebooks:[{id:'book1',name:'업무',stack:''}]})) : fetcher(url,init))
  const {container} = mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'메모 목록으로 돌아가기'}))
  await waitFor(()=>expect(new URLSearchParams(location.search).get('n')).toBe('book1'))
  fireEvent.click(screen.getByRole('button',{name:'메모장 목록으로 돌아가기'}))
  await waitFor(()=>expect(new URLSearchParams(location.search).get('s')).toBe(''))
  expect(container.querySelector('.native-columns')?.getAttribute('data-mobile-page')).toBe('notebooks')
  expect(writes).toHaveLength(0)
})

it('shows Markdown badges before opening notes and ignores code fences in HTML note excerpts', async () => {
  window.history.replaceState({}, '', '/?n=book1')
  const cached = {...note, id: 'cached', title: '저장된 마크다운', is_markdown: true}
  const unknown = {...note, id: 'unknown', title: '미확인 마크다운'}
  const html = {...note, id: 'html', title: '원본 HTML', excerpt: '```example', is_markdown: false}
  const locked = {...note, id: 'locked', title: '잠긴 노트', locked: true}
  let refreshed = false
  const fetchMock = vi.mocked(fetch)
  const original = fetchMock.getMockImplementation()!
  fetchMock.mockImplementation((path, init) => {
    if (path === '/api/notes') return Promise.resolve(Response.json({notes: refreshed
      ? [cached, {...unknown, version: 'v2'}, {...html, version: 'v2', is_markdown: undefined}, locked]
      : [cached, unknown, html, locked]}))
    if (String(path).startsWith('/api/note-formats?')) {
      const pairs = JSON.parse(new URL(String(path), location.origin).searchParams.get('notes')!)
      expect(pairs).toEqual(refreshed ? [['unknown', 'v2'], ['html', 'v2']] : [['unknown', 'v1']])
      return Promise.resolve(Response.json({formats: refreshed
        ? [{id: 'unknown', version: 'v2', is_markdown: false}, {id: 'html', version: 'v2', is_markdown: true}]
        : [{id: 'unknown', version: 'v1', is_markdown: true}]}))
    }
    return original(path, init)
  })
  mount()
  expect(await screen.findByRole('button', {name: /저장된 마크다운 MD/})).toBeTruthy()
  expect(await screen.findByRole('button', {name: /미확인 마크다운 MD/})).toBeTruthy()
  expect(within(screen.getByRole('button', {name: /원본 HTML/})).queryByText('MD')).toBeNull()
  refreshed = true
  fireEvent.click(screen.getByRole('button', {name: '새로고침'}))
  expect(await screen.findByRole('button', {name: /원본 HTML MD/})).toBeTruthy()
  expect(within(screen.getByRole('button', {name: /미확인 마크다운/})).queryByText('MD')).toBeNull()
  expect(within(screen.getByRole('button', {name: /잠긴 노트/})).queryByText('MD')).toBeNull()
  expect(fetchMock.mock.calls.some(([path]) => String(path).startsWith('/api/notes/'))).toBe(false)
})

it('autosaves without a Save button and keeps typing enabled while a request is pending', async () => {
  mount(); await edit()
  expect(screen.queryByRole('button', {name: 'NAS에 저장'})).toBeNull()
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  expect(screen.getByText('NAS에 자동 저장 중…')).toBeTruthy()
  expect(screen.queryByRole('button', {name: 'NAS 확인본 다시 불러오기'})).toBeNull()
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
  await screen.findByRole('button', {name: 'NAS 확인본 다시 불러오기'})
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
  expect(writes[0]).not.toHaveProperty('draft_id')
  expect(writes[0]).not.toHaveProperty('uploads')
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
  expect(loadPreferences()).toEqual({ appearance: 'dark', editorFontSize: 20, language: '',
    lineNumbers: true, lineWrapping: true, mermaidStyle: 'classic', mermaidTheme: 'forest', listRefreshMinutes: 5 })
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

it('applies a browser language override immediately and restores the server default without losing the open draft', async () => {
  mount()
  await edit()
  const openTitle = screen.getByLabelText<HTMLInputElement>('노트 제목')
  fireEvent.click(screen.getByRole('button', {name: /^설정$/}))
  const selector = screen.getByLabelText<HTMLSelectElement>('표시 언어')
  expect(selector.value).toBe('')
  fireEvent.change(selector, {target: {value: 'en'}})
  expect(screen.getByLabelText('Display language')).toBe(selector)
  expect(document.documentElement.lang).toBe('en')
  expect(screen.getByLabelText('Note title')).toBe(openTitle)
  expect(openTitle.value).toBe('수정 제목')
  expect(loadPreferences()).toMatchObject({language: 'en'})
  expect(writes).toHaveLength(0)
  fireEvent.change(selector, {target: {value: ''}})
  expect(screen.getByLabelText('표시 언어')).toBe(selector)
  expect(document.documentElement.lang).toBe('ko')
  expect(loadPreferences()).toMatchObject({language: ''})
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
  expect(screen.getByText('NAS에 자동 저장 중…')).toBeTruthy()
  expect(screen.queryByRole('button', {name: '생성 결과 다시 조회'})).toBeNull()
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
  const original = {...note, html_text_preview: '<p><span data-edit-token="token" data-text-index="0">original</span></p>', html_text_token: 'token', html_text_blocks: [{index:0,text:'original',start:3,end:11}]}
  vi.stubGlobal('fetch', vi.fn(async (path: string, init?: RequestInit) => {
    if (init?.method === 'PUT') {writes.push(JSON.parse(init.body as string)); return new Promise<Response>(resolve => {resolveSave = resolve})}
    return new Response(JSON.stringify(path === '/api/notebooks' ? {notebooks:[{id:'book1',name:'업무',stack:''}]} : path === '/api/notes' ? {notes:[original]} : path === '/api/writes' ? {operations:[]} : original))
  }))
  mount(); await edit()
  const editor = screen.getByRole('textbox', {name:'본문 편집기'})
  const span = editor.querySelector('[data-text-index="0"]')!
  span.textContent = 'sent text'; fireEvent.input(span)
  await waitFor(() => expect(writes).toHaveLength(1), {timeout:2000})
  expect(writes[0].text_changes).toEqual([{index:0,text:'sent text'}])
  span.textContent = 'newer text'; fireEvent.input(span)
  const confirmed = {...original,title:'수정 제목',html:'<p>sent text</p>',version:'v2',html_text_preview:'<p><span data-edit-token="second" data-text-index="0">sent text</span></p>',html_text_token:'second',html_text_blocks:[{index:0,text:'sent text',start:3,end:12}]}
  resolveSave(new Response(JSON.stringify(confirmed)))
  await waitFor(() => expect(writes).toHaveLength(2), {timeout:2000})
  expect(writes[1]).toMatchObject({text_changes:[{index:0,text:'newer text'}],version:'v2'})
  expect(editor.querySelector('[data-text-index="0"]')).toBe(span)
  expect(span.textContent).toBe('newer text')
  resolveSave(new Response(JSON.stringify({...confirmed,version:'v3',html:'<p>newer text</p>',html_text_preview:'<p><span data-edit-token="third" data-text-index="0">newer text</span></p>',html_text_token:'third',html_text_blocks:[{index:0,text:'newer text',start:3,end:13}]})))
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
  const initialLists = fetcher.mock.calls.filter(([url]) => url === '/api/notes').length
  opener.focus();fireEvent.click(opener)
  const dialog=screen.getByRole('dialog',{name:'전체 노트 검색'})
  const input=within(dialog).getByRole('searchbox',{name:'전체 노트 검색어'})
  expect(document.activeElement).toBe(input)
  const before=fetcher.mock.calls.length
  fireEvent.change(input,{target:{value:'일정'}})
  expect(within(dialog).getByRole('button',{name:/다른 메모장 문서/})).toBeTruthy()
  expect(fetcher.mock.calls.length).toBe(before)
  await waitFor(() => expect(fetcher.mock.calls.filter(([url]) => url === '/api/notes').length)
    .toBeGreaterThan(initialLists))
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
it('opens a formatted note directly even when the previous view preference is reading', async () => {
  const formatted = {...note, editable:false, html_text_preview:'<p><span data-edit-token="token" data-text-index="0">original</span></p>',
    html_text_token:'token', html_text_blocks:[{index:0,text:'original',start:3,end:11}]}
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation((url, init) => url === '/api/notes/note1'
    ? Promise.resolve(Response.json(formatted)) : fetcher(url, init))
  mount()
  await screen.findByLabelText('노트 제목')
  for (const name of ['원문','분할','읽기']) expect(screen.queryByRole('button',{name})).toBeNull()
  expect(screen.queryByText('HTML 원문')).toBeNull()
  expect(screen.getByRole('textbox',{name:'본문 편집기'})).toBeTruthy()
  expect(writes).toEqual([])
})

const tableMarkup = '<table><tbody><tr><td></td><td></td></tr><tr><td></td><td></td></tr></tbody></table>'

it('shows table, undo and redo immediately and persists each in order', async () => {
  const {button,reply,saved} = holdFormattedSaves()
  vi.spyOn(window, 'prompt').mockReturnValue('2x2')
  mount()
  const editor = await screen.findByRole('textbox',{name:'본문 편집기'})
  fireEvent.click(button('본문 끝에 표 추가'))
  expect(editor.querySelectorAll('td')).toHaveLength(4)
  await saved(1)
  fireEvent.click(button('실행 취소'))
  expect(editor.querySelector('table')).toBeNull()
  fireEvent.click(button('다시 실행'))
  expect(editor.querySelectorAll('td')).toHaveLength(4)
  expect(writes).toHaveLength(1)
  replyMarkup('v2','<p>AB</p>'+tableMarkup)
  await saved(2)
  reply('v3')
  await saved(3)
  replyMarkup('v4','<p>AB</p>'+tableMarkup)
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect(writes[0]).toMatchObject({version:'v1',structure_edit:{kind:'insert_table',rows:2,columns:2}})
  expect(writes[1]).toMatchObject({version:'v2',restore_version:'v1'})
  expect(writes[2]).toMatchObject({version:'v3',restore_version:'v2'})
})

it('undoes a still-dirty text edit by saving it first instead of locking the toolbar', async () => {
  const formatted = (version: string, text: string) => ({...note, editable:false, version,
    html:`<p>${text}</p>`,
    html_text_preview:`<p><span data-edit-token="${version}" data-text-index="0">${text}</span></p>`,
    html_text_token:version, html_text_blocks:[{index:0,text,start:3,end:3+text.length}], html_text_layout:'layout'})
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes/note1' && init?.method === 'PUT') {
      writes.push(JSON.parse(init.body as string))
      const body = writes[writes.length - 1]
      if (body.restore_version) return Response.json(formatted(`v${writes.length + 1}`, 'original'))
      return Response.json(formatted(`v${writes.length + 1}`, 'typed'))
    }
    return url === '/api/notes/note1' ? Response.json(formatted('v1', 'original')) : fetcher(url, init)
  })
  mount()
  const editor = await screen.findByRole('textbox', {name:'본문 편집기'})
  const span = editor.querySelector('[data-text-index="0"]')!
  span.textContent = 'typed'; fireEvent.input(span)
  const undo = screen.getByRole('button', {name:'실행 취소'}) as HTMLButtonElement
  expect(undo.disabled).toBe(false)
  fireEvent.click(undo)
  await waitFor(() => expect(writes).toHaveLength(2), {timeout: 2000})
  expect(writes[0]).toMatchObject({version:'v1', text_changes:[{index:0,text:'typed'}]})
  expect(writes[1]).toMatchObject({version:'v2', restore_version:'v1'})
  await waitFor(() => expect(editor.querySelector('[data-text-index="0"]')!.textContent).toBe('original'))
})

it('queues an undo clicked while a save is in flight and runs it after the ack', async () => {
  const formatted = (version: string, text: string) => ({...note, editable:false, version,
    html:`<p>${text}</p>`,
    html_text_preview:`<p><span data-edit-token="${version}" data-text-index="0">${text}</span></p>`,
    html_text_token:version, html_text_blocks:[{index:0,text,start:3,end:3+text.length}], html_text_layout:'layout'})
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  let resolvePut!: (response: Response) => void
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes/note1' && init?.method === 'PUT') {
      writes.push(JSON.parse(init.body as string))
      return new Promise<Response>(resolve => { resolvePut = resolve })
    }
    return url === '/api/notes/note1' ? Response.json(formatted('v1', 'original')) : fetcher(url, init)
  })
  mount()
  const editor = await screen.findByRole('textbox', {name:'본문 편집기'})
  const span = editor.querySelector('[data-text-index="0"]')!
  span.textContent = 'typed'; fireEvent.input(span)
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  const undo = screen.getByRole('button', {name:'실행 취소'}) as HTMLButtonElement
  expect(undo.disabled).toBe(false)
  fireEvent.click(undo)
  resolvePut(Response.json(formatted('v2', 'typed')))
  await waitFor(() => expect(writes).toHaveLength(2), {timeout: 2000})
  expect(writes[1]).toMatchObject({version:'v2', restore_version:'v1'})
  resolvePut(Response.json(formatted('v3', 'original')))
  await waitFor(() => expect(editor.querySelector('[data-text-index="0"]')!.textContent).toBe('original'))
})

function holdFormattedSaves() {
  const formatted = (version: string, text = 'AB', title = note.title) => ({...note, title, editable:false, version,
    html:`<p>${text}</p>`,
    html_text_preview:`<p><span data-edit-token="${version}" data-text-index="1">${text}</span></p>`,
    html_text_token:version, html_text_blocks:[{index:1,text,start:3,end:3+text.length}], html_text_layout:`layout-${text}`})
  let remote = formatted('v1')
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes/note1' && init?.method === 'PUT') {
      writes.push(JSON.parse(init.body as string))
      return new Promise<Response>(resolve => { resolveSave = resolve })
    }
    return url === '/api/notes/note1' ? Response.json(remote) : fetcher(url, init)
  })
  const span = () => screen.getByRole('textbox',{name:'본문 편집기'}).querySelector('[data-text-index="1"]')!
  const type = (text: string) => { span().textContent = text; fireEvent.input(span()) }
  const button = (name: string) => screen.getByRole<HTMLButtonElement>('button',{name})
  const reply = (version: string, text?: string, title?: string) => resolveSave(Response.json(formatted(version,text,title)))
  const saved = (count: number) => waitFor(() => expect(writes).toHaveLength(count),{timeout:2200})
  const select = (start: number, end: number) => {
    const range = document.createRange()
    range.setStart(span().firstChild!, start)
    range.setEnd(span().firstChild!, end)
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    fireEvent(document, new Event('selectionchange'))
  }
  return {span, type, button, reply, saved, select,
    remoteWasSaved: (version:string,text:string) => { remote = formatted(version,text) }}
}

it('sends two queued undo requests in order against the versions returned by the NAS', async () => {
  const {span,type,button,reply,saved} = holdFormattedSaves()
  mount(); await screen.findByRole('textbox',{name:'본문 편집기'})
  type('First'); await saved(1); reply('v2','First')
  await waitFor(() => expect(button('실행 취소').disabled).toBe(false))
  type('Second'); await saved(2)
  fireEvent.click(button('실행 취소'))
  fireEvent.click(button('실행 취소'))
  reply('v3','Second')
  await saved(3)
  expect(writes[2]).toMatchObject({version:'v3',restore_version:'v2'})
  reply('v4','First')
  await saved(4)
  expect(writes[3]).toMatchObject({version:'v4',restore_version:'v1'})
  reply('v5')
  await waitFor(() => expect(span().textContent).toBe('AB'))
})

it('invalidates redo as soon as a new edit begins and keeps undo available', async () => {
  const {type,button,reply,saved} = holdFormattedSaves()
  mount(); await screen.findByRole('textbox',{name:'본문 편집기'})
  type('Prior'); await saved(1); reply('v2','Prior')
  await waitFor(() => expect(button('실행 취소').disabled).toBe(false))
  fireEvent.click(button('실행 취소')); await saved(2); reply('v3')
  await waitFor(() => expect(button('다시 실행').disabled).toBe(false))
  type('Next')
  expect(button('다시 실행').disabled).toBe(true)
  fireEvent.click(button('다시 실행'))
  fireEvent.click(button('실행 취소'))
  await saved(3)
  expect(writes[2]).toMatchObject({version:'v3',text_changes:[{index:1,text:'Next'}]})
  reply('v4','Next')
  await saved(4)
  expect(writes[3]).toMatchObject({version:'v4',restore_version:'v3'})
  reply('v5')
  await screen.findByText('✓ NAS에 자동 저장됨')
})

it('shows formatting immediately and saves later typing after it with the new layout', async () => {
  const {type,button,reply,saved,select} = holdFormattedSaves()
  mount()
  const editor = await screen.findByRole('textbox',{name:'본문 편집기'})
  type('XAB'); await saved(1)
  select(2,3)
  fireEvent.click(button('굵게'))
  expect(editor.querySelector('strong')?.textContent).toBe('B')
  expect(button('굵게').getAttribute('aria-pressed')).toBe('true')
  expect(window.getSelection()?.toString()).toBe('B')
  expect(writes).toHaveLength(1)
  const prefix = Array.from(editor.querySelectorAll('[data-text-index]')).find(span => span.textContent === 'XA')!
  prefix.textContent = 'YXA'; fireEvent.input(prefix)
  expect(editor.textContent).toBe('YXAB')
  reply('v2','XAB')
  await saved(2)
  expect(writes[1]).toMatchObject({version:'v2',text_layout:'layout-XAB',
    structure_edit:{kind:'bold',index:1,start:2,end:3}})
  expect(editor.textContent).toBe('YXAB')
  replyMarkup('v3','<p>XA<strong>B</strong></p>')
  await saved(3)
  expect(writes[2]).toMatchObject({version:'v3',text_layout:'layout-v3',
    text_changes:[{index:1,text:'YXA'}]})
  replyMarkup('v4','<p>YXA<strong>B</strong></p>')
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect(editor.querySelector('strong')?.textContent).toBe('B')
})

function replyMarkup(version: string, html: string) {
  const blocks: {index:number;text:string;start:number;end:number}[] = []
  let cursor = 0
  const annotate = (start:number,end:number) => {
    const index = blocks.length
    const text = html.slice(start,end)
    blocks.push({index,text,start,end})
    return `<span data-edit-token="${version}" data-text-index="${index}">${text}</span>`
  }
  let preview = ''
  for (const tag of html.matchAll(/<[^>]+>/g)) {
    preview += annotate(cursor,tag.index) + tag[0]
    cursor = tag.index + tag[0].length
  }
  preview += annotate(cursor,html.length)
  resolveSave(Response.json({...note,editable:false,html,version,html_text_preview:preview,
    html_text_token:version,html_text_blocks:blocks,html_text_layout:`layout-${version}`}))
}

it('keeps projected edits on a safe failure and resumes the same writes after an explicit retry', async () => {
  const {type,button,reply,saved,select} = holdFormattedSaves()
  mount()
  const editor = await screen.findByRole('textbox',{name:'본문 편집기'})
  type('Fresh'); await saved(1)
  select(0,5); fireEvent.click(button('굵게'))
  expect(editor.querySelector('strong')?.textContent).toBe('Fresh')
  resolveSave(Response.json({error:'HTML_PATCH_INVALID'},{status:422}))
  const retry = await screen.findByRole('button',{name:'자동 저장 다시 시도'})
  expect(button('실행 취소').disabled).toBe(true)
  expect(editor.querySelector('strong')?.textContent).toBe('Fresh')
  expect(writes).toHaveLength(1)
  fireEvent.click(retry)
  await saved(2); reply('v2','Fresh')
  await saved(3)
  expect(writes[2]).toMatchObject({version:'v2',structure_edit:{kind:'bold',index:1,start:0,end:5}})
  replyMarkup('v3','<p><strong>Fresh</strong></p>')
  await screen.findByText('✓ NAS에 자동 저장됨')
  expect(writes).toHaveLength(3)
})

it('resumes after an uncertain response without repeating the confirmed write', async () => {
  const {type,button,saved,select,remoteWasSaved} = holdFormattedSaves()
  mount()
  const editor = await screen.findByRole('textbox',{name:'본문 편집기'})
  type('XAB'); await saved(1)
  select(2,3); fireEvent.click(button('굵게'))
  remoteWasSaved('v2','XAB')
  resolveSave(Response.json({error:'WRITE_UNCERTAIN'},{status:409}))
  fireEvent.click(await screen.findByRole('button',{name:'NAS 확인본 다시 불러오기'}))
  fireEvent.click(await screen.findByRole('button',{name:'NAS 결과 확인하고 편집본 보관'}))
  fireEvent.click(await screen.findByRole('button',{name:'보관한 편집본으로 계속'}))
  expect(editor.querySelector('strong')?.textContent).toBe('B')
  expect(writes).toHaveLength(1)
  fireEvent.click(await screen.findByRole('button',{name:'편집본 저장하고 자동 저장 재개'}))
  await saved(2)
  expect(writes[1]).toMatchObject({version:'v2',structure_edit:{kind:'bold',index:1,start:2,end:3}})
  replyMarkup('v3','<p>XA<strong>B</strong></p>')
  await screen.findByText('✓ NAS에 자동 저장됨')
})

it('keeps earlier undo history and records a body edit saved with an attachment', async () => {
  const formatted = (version: string, text = 'original', attachments: {id:string;name:string}[] = [], table = false) => ({
    ...note, editable:false, version, attachments, html:`<p>${text}</p>`+(table ? tableMarkup : ""),
    html_text_preview:`<p><span data-edit-token="${version}" data-text-index="0">${text}</span></p>`,
    html_text_token:version, html_text_blocks:[{index:0,text,start:3,end:3+text.length}], html_text_layout:`layout-${text}`,
  })
  const file = {id:'stored',name:'report.pdf'}
  const fetcher = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (typeof url === 'string' && url.includes('/uploads/') && init?.method === 'PUT')
      return Response.json({upload_id:url.split('?')[0].split('/').at(-1),name:file.name,size:3,
        sha256:'a'.repeat(64),mime:'application/pdf',image:false,status:'ready'})
    if (url === '/api/notes/note1' && init?.method === 'PUT') {
      const body = JSON.parse(init.body as string)
      writes.push(body)
      return Response.json(formatted(`v${writes.length + 1}`, body.text_changes?.[0]?.text,
        writes.length === 1 ? [] : [file], body.restore_version !== 'v1'))
    }
    return url === '/api/notes/note1' ? Response.json(formatted('v1')) : fetcher(url, init)
  })
  vi.spyOn(window, 'prompt').mockReturnValue('2x2')
  mount()
  fireEvent.click(await screen.findByRole('button', {name:'본문 끝에 표 추가'}))
  const undo = () => screen.getByRole<HTMLButtonElement>('button', {name:'실행 취소'})
  await waitFor(() => expect(undo().disabled).toBe(false))
  await screen.findByText('✓ NAS에 자동 저장됨')
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files:[new File(['pdf'],file.name)]}})
  const span = screen.getByRole('textbox',{name:'본문 편집기'}).querySelector('[data-text-index="0"]')!
  span.textContent = 'edited'
  fireEvent.input(span)
  await waitFor(() => expect(writes).toHaveLength(2))
  expect(writes[1]).toMatchObject({version:'v2',text_changes:[{index:0,text:'edited'}],
    uploads:[{upload_id:expect.any(String),sha256:'a'.repeat(64)}]})

  await waitFor(() => expect(undo().disabled).toBe(false))
  fireEvent.click(undo())
  await waitFor(() => expect(writes[2]).toMatchObject({version:'v3',restore_version:'v2'}))
  await waitFor(() => expect(undo().disabled).toBe(false))
  fireEvent.click(undo())
  await waitFor(() => expect(writes[3]).toMatchObject({version:'v4',restore_version:'v1'}))
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
  mount(); await screen.findByLabelText('노트 제목')
  const span=screen.getByRole('textbox',{name:'본문 편집기'}).querySelector('span')!
  span.textContent='new < & >';fireEvent.input(span)
  fireEvent.click(screen.getByText('내보내기…'))
  const exported=await new Promise<string>(resolve=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result));reader.readAsText(blob)})
  expect(exported).toBe(html.replace('old &amp; text','new &lt; &amp; &gt;'))
  expect(writes).toHaveLength(0)
})
it('previews a NAS revision and restores it against the currently opened version', async () => {
  const original = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes/note1/revisions')
      return Response.json({revisions:[{version:'v0',modified_at:1700000000}]})
    if (url === '/api/notes/note1/revisions?version=v0')
      return Response.json({version:'v0',title:'이전 제목',html:'<p>이전 본문</p>'})
    if (url === '/api/notes/note1' && init?.method === 'PUT') {
      writes.push(JSON.parse(init.body as string))
      return Response.json({...note,version:'v2',title:'이전 제목',html:'<p>이전 본문</p>'})
    }
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'노트 정보'}))
  fireEvent.click(screen.getByRole('button',{name:'수정 이력 조회'}))
  const revision = await screen.findByRole('button',{name:/버전 v0/})
  fireEvent.click(revision)
  await screen.findByText('이전 제목')
  fireEvent.click(screen.getByRole('button',{name:'이 버전으로 복원'}))
  expect(writes).toEqual([])
  fireEvent.click(screen.getByRole('button',{name:'복원 확인'}))
  await waitFor(() => expect(screen.queryByRole('dialog',{name:'노트 수정 이력'})).toBeNull())
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('이전 제목')
  expect(writes).toEqual([{version:'v1',title:note.title,notebook_id:'book1',restore_version:'v0'}])
})

it('removes a confirmed general attachment from the inspector and protects source data', async () => {
  const document = {...note, attachments:[{id:'file1',name:'문서.pdf',ref:null},
    {id:'source',name:'synology-note-source.md',ref:null}], source_file_id:'source'}
  const original = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes/note1' && init?.method === 'PUT') {
      writes.push(JSON.parse(init.body as string))
      return Response.json({...document,version:'v2',attachments:[document.attachments[1]]})
    }
    if (url === '/api/notes/note1') return Response.json(document)
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button',{name:'노트 정보'}))
  expect(screen.queryByRole('button',{name:'synology-note-source.md 제거'})).toBeNull()
  const remove = screen.getByRole('button',{name:'문서.pdf 제거'})
  vi.mocked(window.confirm).mockReturnValueOnce(false)
  fireEvent.click(remove)
  expect(writes).toEqual([])
  fireEvent.click(remove)
  await waitFor(() => expect(screen.queryByRole('link',{name:'문서.pdf'})).toBeNull())
  expect(writes).toEqual([{version:'v1', title:note.title, notebook_id:'book1', remove_attachment_id:'file1'}])
})

it('imports selected Markdown files through the confirmed NAS create workflow', async () => {
  const requests: Record<string, unknown>[] = []
  const original = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes' && init?.method === 'POST') {
      const input = JSON.parse(init.body as string)
      requests.push(input)
      return Response.json({...note, id:`imported-${requests.length}`, ...input})
    }
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.change(screen.getByLabelText('가져올 Markdown 파일 선택'), {target:{files:[
    new File(['# 한글\r\n'], '첫 노트.md'),
    new File(['두 번째 본문'], '두 번째.markdown'),
  ]}})
  await screen.findByText('Markdown 노트 2개를 가져왔습니다.')
  expect(requests).toMatchObject([
    {title:'첫 노트', markdown:'# 한글\r\n', notebook_id:'book1'},
    {title:'두 번째', markdown:'두 번째 본문', notebook_id:'book1'},
  ])
  expect(requests[0].client_request_id).not.toBe(requests[1].client_request_id)
  expect(window.location.search).toContain('note=imported-2')
})

it('stops a Markdown import batch after an uncertain request and keeps its draft', async () => {
  const requests: Record<string, unknown>[] = []
  const original = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes' && init?.method === 'POST') {
      requests.push(JSON.parse(init.body as string))
      return Response.json({error:'WRITE_UNCERTAIN'}, {status:409})
    }
    if (String(url).startsWith('/api/creates/')) return Response.json({status:'uncertain'})
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.change(screen.getByLabelText('가져올 Markdown 파일 선택'), {target:{files:[
    new File(['검토할 본문'], '내 초안.md'),
    new File(['보내지 않을 본문'], '다음.md'),
  ]}})
  await screen.findByText('새 노트 저장 결과 확인 필요')
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('내 초안')
  expect(requests).toHaveLength(1)
})

it('does not open recovery for a rejected Markdown import', async () => {
  const original = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes' && init?.method === 'POST')
      return Response.json({error:'MARKDOWN_UNSUPPORTED'}, {status:422})
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.change(screen.getByLabelText('가져올 Markdown 파일 선택'), {target:{files:[
    new File(['거절된 본문'], '검증.md'),
  ]}})
  await screen.findByText(/검증.md · 0\/1개 가져옴/)
  expect(screen.queryByText('새 노트 저장 결과 확인 필요')).toBeNull()
  expect(window.location.search).toContain('note=note1')
})

it('reports successful import when the NAS create receipt proves the response was lost', async () => {
  let writes = 0
  const original = vi.mocked(fetch).getMockImplementation()!
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/notes' && init?.method === 'POST') {
      writes++
      return Response.json({error:'WRITE_UNCERTAIN'}, {status:409})
    }
    if (String(url).startsWith('/api/creates/')) return Response.json({status:'completed',
      note:{...note,id:'created-import',title:'복구한 파일',markdown:'되찾은 본문'}})
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.change(screen.getByLabelText('가져올 Markdown 파일 선택'), {target:{files:[
    new File(['되찾은 본문'], '복구한 파일.md'), new File(['보류한 본문'], '다음 파일.md'),
  ]}})
  await screen.findByText('복구한 파일.md · 1/2개 가져옴 · 나머지 1개 파일을 선택해 계속할 수 있습니다.')
  expect(window.location.search).toContain('note=created-import')
  expect(writes).toBe(1)
})

it('confirms notebook deletion, then clears the removed notebook and note', async () => {
  const original = vi.mocked(fetch).getMockImplementation()!
  const actions = [] as unknown[]
  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (url === '/api/library/action') {
      actions.push(JSON.parse(init?.body as string))
      return Response.json({})
    }
    if (actions.length && url === '/api/notebooks') return Response.json({notebooks: []})
    if (actions.length && url === '/api/notes') return Response.json({notes: [{...note, trashed: true}]})
    return original(url, init)
  })
  mount()
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button', {name: '프로젝트 책장 펼치기'}))
  fireEvent.contextMenu(screen.getByRole('button', {name: '업무'}))
  fireEvent.click(screen.getByRole('button', {name: '메모장 삭제…'}))
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', {name: '취소'}))
  expect(actions).toEqual([])
  fireEvent.contextMenu(screen.getByRole('button', {name: '업무'}))
  fireEvent.click(screen.getByRole('button', {name: '메모장 삭제…'}))
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', {name: '삭제'}))
  await waitFor(() => expect(screen.queryByRole('button', {name: '업무'})).toBeNull())
  expect(actions).toEqual([{kind: 'notebook', action: 'delete', id: 'book1'}])
  expect(window.location.search).not.toMatch(/[?&](n|note)=/)
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
  mount();await screen.findByLabelText('노트 제목')
  const editor=screen.getByRole('textbox',{name:'본문 편집기'})
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

it('keeps the unresolved save warning visible during a favorite request', async () => {
  sessionStorage.setItem(draftKey, JSON.stringify({
    key: 'note:note1', title: note.title, html: note.html, notebook_id: note.notebook_id,
    version: note.version, review_required: true,
  }))
  const base = vi.mocked(fetch).getMockImplementation()!
  let resolveFavorite!: (response: Response) => void
  const favoriteResponse = new Promise<Response>(resolve => { resolveFavorite = resolve })
  const favoriteRequest = vi.fn(() => favoriteResponse)
  vi.stubGlobal('fetch', vi.fn((path: string, init?: RequestInit) =>
    path === '/api/library/action' ? favoriteRequest() : base(path, init)))

  mount()
  const review = await screen.findByRole('button', {name: 'NAS 확인본 다시 불러오기'})
  const favorite = screen.getByLabelText<HTMLButtonElement>('즐겨찾기', {selector: 'button'})
  expect(favorite.disabled).toBe(false)
  fireEvent.click(favorite)
  await waitFor(() => expect(favoriteRequest).toHaveBeenCalledOnce())
  expect(favorite.disabled).toBe(true)
  expect(screen.getByRole('button', {name: 'NAS 확인본 다시 불러오기'})).toBe(review)
  resolveFavorite(Response.json({}))
  await waitFor(() => expect(screen.getByLabelText<HTMLButtonElement>('즐겨찾기', {selector: 'button'}).disabled).toBe(false))
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
  mount();await screen.findByLabelText('노트 제목')
  const span=screen.getByRole('textbox',{name:'본문 편집기'}).querySelector('span')!;span.textContent='D & E';fireEvent.input(span)
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

function attachmentHarness(markdown = 'base') {
  const markdownNote = {...note, markdown}
  const transfers: {path: string; init: RequestInit; resolve: (response: Response) => void; reject: (error: Error) => void}[] = []
  const metadata = (index: number, image = false) => ({
    upload_id: transfers[index].path.split('?')[0].split('/').at(-1)!,
    name: (transfers[index].init.body as File).name,
    size: (transfers[index].init.body as File).size, sha256: String(index + 1).repeat(64),
    mime: image ? 'image/png' : 'application/pdf', image, status: 'ready',
  })
  const lookup = new Map<string, Response>()
  const fetchMock = vi.fn(async (path: string, init: RequestInit = {}) => {
    if (path.includes('/uploads/')) {
      if (init.method === 'PUT') return new Promise<Response>((resolve, reject) => transfers.push({path, init, resolve, reject}))
      return init.method === 'DELETE' ? Response.json({deleted:true}) : lookup.get(path) ?? new Response(null, {status: 404})
    }
    if (init.method === 'PUT' || init.method === 'POST' && path === '/api/notes') {
      writes.push(JSON.parse(init.body as string))
      return new Promise<Response>(resolve => {resolveSave = resolve})
    }
    return new Response(JSON.stringify(path === '/api/notebooks' ? {notebooks:[{id:'book1', name:'업무', stack:''}]} :
      path === '/api/notes' ? {notes:[markdownNote]} : path === '/api/writes' ? {operations:[]} : markdownNote))
  })
  vi.stubGlobal('fetch', fetchMock)
  return {markdownNote, transfers, metadata, lookup, fetchMock}
}

async function attachmentEditor(workspaceStatus?: Parameters<typeof mount>[1]) {
  if (!Range.prototype.getClientRects) {
    Range.prototype.getClientRects = () => Object.assign([], {item: () => null});
    Range.prototype.getBoundingClientRect = () => new DOMRect();
  }
  const {container} = mount(undefined, workspaceStatus)
  await screen.findByLabelText('노트 제목')
  fireEvent.click(screen.getByRole('button', {name:'분할'}))
  return container.querySelector<HTMLElement>('.cm-content')!
}

it('sends raw files with bounded concurrency and inserts in selection order using server image metadata', async () => {
  const {transfers, metadata} = attachmentHarness()
  const editor = await attachmentEditor({...status, source:'environment', read_only:true})
  const files = [new File(['1'], '한글[1].pdf', {type:'image/png'}), new File(['2'], 'photo.bin'), new File(['3'], 'third.pdf')]
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files}})
  await waitFor(() => expect(transfers).toHaveLength(2))
  expect(transfers[0].path).toMatch(/^\/api\/drafts\/[a-f0-9-]+\/uploads\/[a-f0-9-]+\?notebook_id=book1&note_id=note1$/)
  expect(transfers[0].init).toMatchObject({method:'PUT', body:files[0], headers:{
    'Content-Type':'application/octet-stream', 'X-CSRF-Token':'csrf',
    'X-Upload-Name':encodeURIComponent(files[0].name), 'X-Upload-Size':'1',
  }})
  transfers[1].resolve(Response.json(metadata(1, true)))
  await waitFor(() => expect(transfers).toHaveLength(3))
  expect(editor.textContent).toBe('base')
  transfers[0].resolve(Response.json(metadata(0)))
  transfers[2].resolve(Response.json(metadata(2)))
  await waitFor(() => expect(writes).toHaveLength(1), {timeout: 2000})
  expect(writes[0]).toMatchObject({draft_id:transfers[0].path.split('/')[3],
    uploads: [0,1,2].map(index => {const {upload_id, sha256} = metadata(index); return {upload_id, sha256}})})
  expect(writes[0].markdown).toBe(`[한글\\[1\\].pdf](attachment://${metadata(0).upload_id})![photo.bin](attachment://${metadata(1).upload_id})[third.pdf](attachment://${metadata(2).upload_id})base`)
})

it('recovers a lost upload response by GET and waits for composition before inserting at the mapped bookmark', async () => {
  const { EditorView } = await import('@uiw/react-codemirror')
  const {transfers, metadata, lookup, fetchMock} = attachmentHarness()
  const editor = await attachmentEditor()
  const view = EditorView.findFromDOM(editor.closest(".cm-editor") as HTMLElement)!
  view.dispatch({selection:{anchor:2}})
  fireEvent.paste(editor, {clipboardData:{files:[new File(['file'], 'photo.png')], types:['Files', 'text/plain'], getData:() => 'also text'}})
  await waitFor(() => expect(transfers).toHaveLength(1))
  fireEvent.compositionStart(editor)
  view.dispatch({changes:{from:0, insert:'앞'}})
  lookup.set(transfers[0].path, Response.json(metadata(0, true)))
  transfers[0].reject(new Error('connection lost'))
  await waitFor(() => expect(fetchMock.mock.calls.some(([path, init]) => path === transfers[0].path && (init?.method ?? 'GET') === 'GET')).toBe(true))
  expect(view.state.doc.toString()).toBe('앞base')
  expect(writes).toHaveLength(0)
  fireEvent.compositionEnd(editor)
  await waitFor(() => expect(view.state.doc.toString()).toBe(`앞ba![photo.png](attachment://${metadata(0).upload_id})se`))
  expect(transfers).toHaveLength(1)
})

it('suppresses the late response of a canceled drop and sends the authenticated JSON DELETE', async () => {
  const { EditorView } = await import('@uiw/react-codemirror')
  const {transfers, metadata, fetchMock} = attachmentHarness()
  const editor = await attachmentEditor()
  const view = EditorView.findFromDOM(editor.closest('.cm-editor') as HTMLElement)!
  vi.spyOn(view, 'posAtCoords').mockReturnValue(2)
  fireEvent.drop(editor, {dataTransfer:{files:[new File(['example'], 'cancel.pdf')], types:['Files']}})
  await waitFor(() => expect(transfers).toHaveLength(1))
  fireEvent.click(screen.getByRole('button', {name:'새 노트'}))
  expect(window.location.search).toContain('note=note1')
  fireEvent.click(screen.getByRole('button', {name:/^취소$/}))
  expect(transfers[0].init.signal?.aborted).toBe(true)
  transfers[0].resolve(Response.json(metadata(0)))
  await waitFor(() => expect(fetchMock).toHaveBeenCalledWith(transfers[0].path, expect.objectContaining({
    method:'DELETE', headers:{'Content-Type':'application/json', 'X-CSRF-Token':'csrf'},
  })))
  await waitFor(() => expect(screen.queryByLabelText('첨부파일 업로드')).toBeNull())
  expect(view.state.doc.toString()).toBe('base')
  expect(writes).toHaveLength(0)
})

it('restores an upload bookmark with a status lookup after reload without serializing the file', async () => {
  const {transfers, metadata, lookup, fetchMock} = attachmentHarness()
  await attachmentEditor()
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files:[new File(['private binary'], 'resume.pdf')]}})
  await waitFor(() => expect(transfers).toHaveLength(1))
  const stored = JSON.parse(sessionStorage.getItem(sessionStorage.key(0)!)!)
  expect(stored.attachments.items[0]).toMatchObject({id:metadata(0).upload_id, position:0, phase:'uploading'})
  expect(JSON.stringify(stored)).not.toContain('private binary')
  cleanup()
  lookup.set(transfers[0].path, Response.json(metadata(0)))
  mount()
  await waitFor(() => expect(writes).toHaveLength(1), {timeout:2000})
  expect(fetchMock).toHaveBeenCalledWith(transfers[0].path, expect.objectContaining({signal:expect.any(AbortSignal)}))
  expect(transfers).toHaveLength(1)
  expect(writes[0]).toMatchObject({uploads:[{upload_id:metadata(0).upload_id, sha256:metadata(0).sha256}]})
})

it('checks an upload before retrying the same id and validates the inclusive size limit', async () => {
  const {transfers, fetchMock} = attachmentHarness()
  await attachmentEditor()
  const exact = new File(['size stub'], 'exact.pdf')
  Object.defineProperty(exact, 'size', {value:50_000_000})
  const large = new File(['size stub'], 'large.pdf')
  Object.defineProperty(large, 'size', {value:50_000_001})
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {
    target:{files:[large, new File([], 'empty.pdf'), exact]},
  })
  await waitFor(() => expect(transfers).toHaveLength(1))
  expect(screen.getByRole('alert').textContent).toContain('large.pdf')
  expect(screen.getByRole('alert').textContent).toContain('empty.pdf')
  expect(transfers[0].init.headers).toMatchObject({'X-Upload-Size':'50000000'})
  transfers[0].resolve(Response.json({error:'UPLOAD_SIZE_MISMATCH'}, {status:422}))
  fireEvent.click(await within(screen.getByLabelText('첨부파일 업로드')).findByRole('button', {name:/^다시 시도$/}))
  await waitFor(() => expect(transfers).toHaveLength(2))
  expect(transfers[1].path).toBe(transfers[0].path)
  const calls = fetchMock.mock.calls.filter(([path]) => path === transfers[0].path)
  expect(calls.map(([, init]) => init?.method ?? 'GET')).toEqual(['PUT', 'GET', 'PUT'])
})

it('rebases the queued attachment added during creation onto the returned note and saves only its manifest', async () => {
  window.history.replaceState({}, '', '/?n=book1&new=1')
  const {transfers, metadata, markdownNote} = attachmentHarness()
  await attachmentEditor()
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files:[new File(['first'], 'first.pdf')]}})
  await waitFor(() => expect(transfers).toHaveLength(1))
  transfers[0].resolve(Response.json(metadata(0)))
  await waitFor(() => expect(writes).toHaveLength(1), {timeout:2000})
  expect(transfers[0].path).toContain(`&client_request_id=${writes[0].client_request_id}`)
  expect(writes[0]).toMatchObject({uploads:[{upload_id:metadata(0).upload_id, sha256:metadata(0).sha256}]})
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files:[new File(['second'], 'second.pdf')]}})
  fireEvent.change(screen.getByLabelText('노트 제목'), {target:{value:'저장 중 변경'}})
  expect(transfers).toHaveLength(1)
  resolveSave(Response.json({...markdownNote, id:'created', version:'created-v1', title:'제목 없음',
    markdown:writes[0].markdown, attachment_bindings:{[metadata(0).upload_id]:'file1'}}))
  await waitFor(() => expect(transfers).toHaveLength(2))
  expect(transfers[1].path).toContain('&note_id=created')
  expect(screen.getByText('NAS에 저장됨', {exact:true})).toBeTruthy()
  transfers[1].resolve(Response.json(metadata(1)))
  await waitFor(() => expect(writes).toHaveLength(2), {timeout:2000})
  expect(writes[1]).toMatchObject({version:'created-v1', title:'저장 중 변경', draft_id:writes[0].draft_id,
    uploads:[{upload_id:metadata(1).upload_id, sha256:metadata(1).sha256}]})
  expect(writes[1].markdown).toContain(metadata(0).upload_id)
  expect(writes[1].markdown).toContain(metadata(1).upload_id)
})

it('keeps the local draft and upload ids read-only when reload finds a staged NAS write', async () => {
  const staged = {...note, editable:false, read_only_reason:'WRITE_IN_PROGRESS', write_in_progress:true}
  const key = 'synonote:web-draft:["https://nas.example","alice"]:note:note1'
  const id = '0090cd10-a2a8-4ef9-98fc-aebba857dcc7'
  const draftId = '0090cd10-a2a8-4ef9-98fc-aebba857dcc8'
  const markdown = `로컬 편집 [영수증](attachment://${id})`
  const metadata = {upload_id:id, name:'영수증.pdf', size:5, sha256:'a'.repeat(64), mime:'application/pdf', image:false, status:'pinned'}
  const attachments = {id:draftId, items:[{id, name:metadata.name, phase:'ready',
    position:6, inserted:true, target:{notebook_id:'book1', note_id:'note1'}, metadata}]}
  sessionStorage.setItem(key, JSON.stringify({key:'note:note1', notebook_id:'book1', title:'보관한 제목',
    html:'<p>local</p>', version:'v1', markdown, attachments}))
  const fetchMock = vi.fn(async (path: string) => Response.json(
    path === '/api/notebooks' ? {notebooks:[{id:'book1',name:'업무',stack:''}]} :
    path === '/api/notes' ? {notes:[staged]} :
    path === '/api/writes' ? {operations:[]} :
    path.includes('/uploads/') ? metadata : staged))
  vi.stubGlobal('fetch', fetchMock)
  const {container} = mount()
  const review = await screen.findByRole('button', {name:'NAS 확인본 다시 불러오기'})
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).readOnly).toBe(true)
  expect(container.querySelector('.cm-content')?.getAttribute('contenteditable')).toBe('false')
  expect(container.querySelector('.cm-content')?.textContent).toBe(markdown)
  await screen.findByText(/NAS 저장 결과를 확인해야 합니다/)
  fireEvent.click(review)
  await screen.findByText(/확인한 NAS 결과와 보관한 편집본/)
  expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({
    review_required:true, version:'v1', markdown, attachments:{id:draftId, items:[{id, metadata}]},
  })
  expect(writes).toHaveLength(0)
})

it('keeps a heading at the caret as a heading when files are inserted before it', async () => {
  const {transfers, metadata} = attachmentHarness('# 제목\n\n문단')
  const editor = await attachmentEditor()
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files:[new File(['contents'], 'report.pdf')]}})
  await waitFor(() => expect(transfers).toHaveLength(1))
  transfers[0].resolve(Response.json(metadata(0)))
  await waitFor(() => expect(editor.textContent).toContain(metadata(0).upload_id))
  const { EditorView } = await import('@uiw/react-codemirror')
  const view = EditorView.findFromDOM(editor.closest('.cm-editor') as HTMLElement)!
  expect(view.state.doc.toString()).toBe(`[report.pdf](attachment://${metadata(0).upload_id})\n\n# 제목\n\n문단`)
})

const unresolvedUpload = '0090cd10-a2a8-4ef9-98fc-aebba857dcc7'
const committedUpload = '0090cd10-a2a8-4ef9-98fc-aebba857dcc8'
const recoveryDraftId = '0090cd10-a2a8-4ef9-98fc-aebba857dcc9'
const recoveryCreateId = '0090cd10-a2a8-4ef9-98fc-aebba857dcca'
const heldMarkdown = `로컬 [영수증](attachment://${unresolvedUpload}) · [NAS 파일](attachment://${committedUpload})`

function attachmentRecovery({compose = false, staged = false, gone = false, deleteGone = false,
  markdown = heldMarkdown} = {}) {
  if (compose) window.history.replaceState({}, '', '/?n=book1&new=1')
  const key = compose ? draftKey.replace('note:note1', 'new:book1') : draftKey
  const target = compose ? {notebook_id:'book1',client_request_id:recoveryCreateId} : {notebook_id:'book1',note_id:'note1'}
  const metadata = {upload_id:unresolvedUpload, name:'영수증.pdf', size:5, sha256:'a'.repeat(64),
    mime:'application/pdf', image:false, status:'pinned'}
  const held = {key:compose?'new:book1':'note:note1', notebook_id:'book1', title:'보관 제목', html:'<p>local</p>',
    markdown, version:'v1', review_required:true, pending_upload_ids:[unresolvedUpload],
    ...(compose ? {client_request_id:recoveryCreateId} : {}),
    attachments:{id:recoveryDraftId,items:[{id:unresolvedUpload,name:metadata.name,phase:'uncertain',inserted:true,
      position:3,target,metadata} ]}}
  sessionStorage.setItem(key,JSON.stringify(held))
  const currentNote = {...note, markdown:`NAS [파일](attachment://${committedUpload})`, version:'v2',
    attachment_bindings:{[committedUpload]:'file1'}, editable:!staged, write_in_progress:staged}
  let acked = false
  const base = vi.mocked(fetch).getMockImplementation()!
  const fetcher = vi.fn(async (path:string, init:RequestInit = {}) => {
    if (path === '/api/writes') return Response.json({operations:acked?[]:[{operation_id:'op',
      note_id:compose?null:'note1',target:'book1',title:'보관 제목',status:'uncertain',created:0}]})
    if (path === '/api/writes/op/ack') { acked = true; return Response.json({}) }
    if (path.startsWith('/api/creates/')) return Response.json({status:acked?'reviewed':'uncertain',operation_id:'op'})
    if (path === '/api/notes/note1' && !init.method) return Response.json(currentNote)
    if (path.includes('/uploads/')) {
      if (init.method === 'PUT') return Response.json({...metadata,status:'ready',
        upload_id:path.split('?')[0].split('/').at(-1)})
      if (gone && acked) return Response.json({}, {status:404})
      if (init.method === 'DELETE') return deleteGone ? Response.json({}, {status:404}) : Response.json({deleted:true})
      return Response.json({...metadata,status:acked?'reviewed':'pinned'})
    }
    if (path === '/api/notes' && init.method === 'POST') {
      writes.push(JSON.parse(init.body as string))
      return new Promise<Response>(() => {})
    }
    return base(path, init)
  })
  vi.stubGlobal('fetch', fetcher)
  return {key, held, fetcher}
}

it('acknowledges a pinned create without replay and explicitly creates from preserved text with fresh IDs', async () => {
  const {key,fetcher} = attachmentRecovery({compose:true})
  await attachmentEditor()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  const restart = await screen.findByRole('button',{name:'초안 보관하고 별도 노트 생성'})
  const queue = screen.getByLabelText('첨부파일 업로드')
  expect((await within(queue).findByRole('link',{name:'영수증.pdf'})).getAttribute('href')).toContain(recoveryCreateId)
  expect(within(queue).queryByRole('button',{name:'다시 시도'})).toBeNull()
  await new Promise(resolve => setTimeout(resolve, 900))
  expect(fetcher.mock.calls.filter(([,init])=>['PUT','DELETE'].includes(init?.method ?? ''))).toHaveLength(0)
  expect(writes).toHaveLength(0)
  fireEvent.click(restart)
  const save = await screen.findByRole('button',{name:'편집본 저장하고 자동 저장 재개'})
  cleanup(); mount()
  await screen.findByRole('button',{name:save.textContent!})
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'),{target:{files:[new File(['new'],'영수증.pdf')]}})
  await waitFor(() => expect(fetcher.mock.calls.some(([path,init])=>path.includes('/uploads/') && init?.method==='PUT')).toBe(true))
  const freshPath = fetcher.mock.calls.find(([path,init])=>path.includes('/uploads/') && init?.method==='PUT')![0]
  expect(freshPath).not.toContain(unresolvedUpload)
  expect(freshPath).not.toContain(recoveryCreateId)
  expect(freshPath).not.toContain(recoveryDraftId)
  await waitFor(() => expect(JSON.parse(sessionStorage.getItem(key)!).markdown).toContain('로컬 영수증 · NAS 파일'))
  expect(JSON.parse(sessionStorage.getItem(`${key}:held:${recoveryCreateId}`)!)).toMatchObject({markdown:heldMarkdown})
  await new Promise(resolve => setTimeout(resolve, 900))
  expect(writes).toHaveLength(0)
  fireEvent.click(screen.getByRole('button',{name:'편집본 저장하고 자동 저장 재개'}))
  await waitFor(() => expect(writes).toHaveLength(1))
  expect(writes[0].client_request_id).not.toBe(recoveryCreateId)
  expect(writes[0].markdown).not.toContain(unresolvedUpload)
  expect(writes[0].uploads).toEqual([{upload_id:freshPath.split('?')[0].split('/').at(-1),sha256:'a'.repeat(64)}])
})

it('resumes an editable NAS note with confirmed bindings and stays paused over reload until explicitly saved', async () => {
  const {key} = attachmentRecovery()
  const editor = await attachmentEditor()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  fireEvent.click(await screen.findByRole('button',{name:'보관한 편집본으로 계속'}))
  await waitFor(() => expect(editor.textContent).toBe(`로컬 영수증 · [NAS 파일](attachment://${committedUpload})`))
  expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({version:'v2'})
  cleanup(); mount()
  const save = await screen.findByRole('button',{name:'편집본 저장하고 자동 저장 재개'})
  await new Promise(resolve => setTimeout(resolve, 900))
  expect(writes).toHaveLength(0)
  fireEvent.click(save)
  await waitFor(() => expect(writes).toHaveLength(1))
  expect(writes[0]).toMatchObject({version:'v2',markdown:`로컬 영수증 · [NAS 파일](attachment://${committedUpload})`})
  expect(writes[0]).not.toHaveProperty('uploads')
})

it.each(['unchanged', 'already saved', 'changed layout'])(
  'recovers a formatted draft safely when the NAS body is %s',
  async outcome => {
    const {key, held, fetcher} = attachmentRecovery()
    sessionStorage.setItem(key, JSON.stringify({...held, markdown:undefined, html:note.html,
      text_layout:'original-layout', text_blocks:[{index:0,text:'original',start:3,end:11}],
      text_changes:[{index:0,text:'edited'}]}))
    const body = outcome === 'unchanged' ? 'original' : outcome === 'already saved' ? 'edited' : 'elsewhere'
    const fresh = {...note, title:held.title, editable:false, version:'v2', html:`<p>${body}</p>`,
      html_text_layout:outcome === 'unchanged' ? 'original-layout' : 'new-layout',
      html_text_preview:`<p><span data-edit-token="token" data-text-index="0">${body}</span></p>`,
      html_text_token:'token', html_text_blocks:[{index:0,text:body,start:3,end:3+body.length}]}
    const respond = fetcher.getMockImplementation()!
    fetcher.mockImplementation((path, init) => path === '/api/notes/note1' && !init?.method
      ? Promise.resolve(Response.json(fresh)) : respond(path, init))
    mount()
    fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
    if (outcome === 'changed layout') {
      expect(await screen.findByText(/본문이 바뀌어 보관한 편집 위치를/)).toBeTruthy()
      expect(screen.queryByRole('button',{name:'보관한 편집본으로 계속'})).toBeNull()
      expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({review_required:true,text_changes:[{index:0,text:'edited'}]})
      expect(writes).toHaveLength(0)
      return
    }
    fireEvent.click(await screen.findByRole('button',{name:'보관한 편집본으로 계속'}))
    const save = await screen.findByRole('button',{name:'편집본 저장하고 자동 저장 재개'})
    expect(screen.getByRole('textbox',{name:'본문 편집기'}).textContent).toBe('edited')
    expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({version:'v2', resume_paused:true,
      text_changes:outcome === 'unchanged' ? [{index:0,text:'edited'}] : [],
      attachments:{items:[{id:unresolvedUpload,recoveryOnly:true}]}})
    expect(writes).toHaveLength(0)
    fireEvent.click(save)
    if (outcome === 'unchanged') {
      await waitFor(() => expect(writes).toHaveLength(1))
      expect(writes[0]).toMatchObject({version:'v2',text_layout:'original-layout',text_changes:[{index:0,text:'edited'}]})
      expect(writes[0]).not.toHaveProperty('uploads')
    } else {
      await waitFor(() => expect(screen.queryByRole('button',{name:'편집본 저장하고 자동 저장 재개'})).toBeNull())
      expect(writes).toHaveLength(0)
    }
  },
)

it('opens a separate draft from preserved text when the NAS note remains staged', async () => {
  const {key} = attachmentRecovery({staged:true})
  await attachmentEditor()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  const copy = await screen.findByRole('button',{name:'보관한 본문으로 별도 노트 작성'})
  expect(screen.queryByRole('button',{name:'보관한 편집본으로 계속'})).toBeNull()
  fireEvent.click(copy)
  await screen.findByRole('button',{name:'편집본 저장하고 자동 저장 재개'})
  expect(window.location.search).toContain('new=1')
  expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({markdown:heldMarkdown,review_required:true})
  expect(JSON.parse(sessionStorage.getItem(key.replace('note:note1','new:book1'))!)).toMatchObject({markdown:'로컬 영수증 · NAS 파일'})
  expect(writes).toHaveLength(0)
  fireEvent.click(screen.getByRole('button',{name:'전체 그래프'}))
  await waitFor(() => expect(window.location.search).not.toContain('new=1'))
  expect(writes).toHaveLength(0)
})

it('preserves an existing compose draft when the separate recovery destination is occupied', async () => {
  const {key} = attachmentRecovery({staged:true})
  const composeKey = key.replace('note:note1','new:book1')
  const saved = JSON.stringify({key:'new:book1',notebook_id:'book1',title:'기존 초안',html:'<p></p>',markdown:'별개 본문'})
  sessionStorage.setItem(composeKey,saved)
  await attachmentEditor()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  fireEvent.click(await screen.findByRole('button',{name:'보관한 본문으로 별도 노트 작성'}))
  await screen.findByText(/이 메모장에 작성 중인 새 노트가 있습니다/)
  expect(sessionStorage.getItem(composeKey)).toBe(saved)
  expect(window.location.search).toContain('note=note1')
  expect(writes).toHaveLength(0)
})

it('removes a CRLF reference-style attachment without changing an approved NAS link', async () => {
  attachmentRecovery({markdown:`로컬 [영수증][첨부]\r\n\r\n[첨부]: <attachment://${unresolvedUpload}>\r\n\r\n[NAS 파일](attachment://${committedUpload})`})
  const editor = await attachmentEditor()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  fireEvent.click(await screen.findByRole('button',{name:'보관한 편집본으로 계속'}))
  await screen.findByRole('button',{name:'편집본 저장하고 자동 저장 재개'})
  expect(editor.textContent).toContain('로컬 영수증')
  expect(editor.textContent).toContain(`[NAS 파일](attachment://${committedUpload})`)
  expect(editor.textContent).not.toContain(unresolvedUpload)
  expect(writes).toHaveLength(0)
})

it.each([
  ['multiline Markdown', `> [영수증](\n> attachment://${unresolvedUpload})`],
  ['raw HTML', `<a href="attachment://${unresolvedUpload}">영수증</a>`],
])('leaves recovery paused when a live %s attachment link cannot be safely rewritten', async (_, markdown) => {
  const {key} = attachmentRecovery({markdown})
  await attachmentEditor()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  fireEvent.click(await screen.findByRole('button',{name:'보관한 편집본으로 계속'}))
  await screen.findByText(/해결되지 않은 첨부 링크가 남아 있습니다/)
  expect(screen.queryByRole('button',{name:'편집본 저장하고 자동 저장 재개'})).toBeNull()
  expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({markdown,review_required:true,recovery_acknowledged:true})
  expect(writes).toHaveLength(0)
})

it.each(['reviewed','expired','expired during delete'])('clears a %s upload with an explicit discard', async state => {
  const gone = state === 'expired'
  const {key,fetcher} = attachmentRecovery({staged:true,gone,deleteGone:state === 'expired during delete'})
  await attachmentEditor()
  expect(screen.queryByRole('button',{name:'임시 파일 버리기'})).toBeNull()
  fireEvent.click(await screen.findByRole('button',{name:/NAS 확인 후 보류 해제/}))
  const discard = await screen.findByRole('button',{name:gone?'만료된 첨부 표시 지우기':'임시 파일 버리기'})
  expect(fetcher.mock.calls.some(([,init])=>init?.method==='DELETE')).toBe(false)
  vi.mocked(window.confirm).mockReturnValueOnce(false)
  fireEvent.click(discard)
  expect(window.confirm).toHaveBeenLastCalledWith(expect.stringContaining('본문의 첨부 링크는 이름만 남습니다.'))
  expect(fetcher.mock.calls.some(([,init])=>init?.method==='DELETE')).toBe(false)
  fireEvent.click(discard)
  await waitFor(() => expect(screen.queryByLabelText('첨부파일 업로드')).toBeNull())
  expect(fetcher.mock.calls.filter(([,init])=>init?.method==='DELETE')).toEqual(gone?[]:[
    [`/api/drafts/${recoveryDraftId}/uploads/${unresolvedUpload}?notebook_id=book1&note_id=note1`,
      expect.objectContaining({headers:{'Content-Type':'application/json','X-CSRF-Token':'csrf'}})],
  ])
  expect(JSON.parse(sessionStorage.getItem(key)!)).toMatchObject({review_required:true,pending_upload_ids:[],
    markdown:`로컬 영수증 · [NAS 파일](attachment://${committedUpload})`})
  expect(writes).toHaveLength(0)
})

it('preserves edits made during attachment save preparation before the network write starts', async () => {
  const {transfers, metadata, markdownNote} = attachmentHarness()
  let resumeMath!: (value: Awaited<ReturnType<typeof exportMath>>) => void
  vi.mocked(exportMath).mockImplementationOnce(() => new Promise(resolve => {resumeMath = resolve}))
  await attachmentEditor()
  fireEvent.change(screen.getByLabelText('첨부할 파일 선택'), {target:{files:[new File(['doc'], 'snapshot.pdf')]}})
  await waitFor(() => expect(transfers).toHaveLength(1))
  transfers[0].resolve(Response.json(metadata(0)))
  await waitFor(() => expect(resumeMath).toBeTypeOf('function'), {timeout:2000})
  fireEvent.change(screen.getByLabelText('노트 제목'), {target:{value:'준비 중 수정'}})
  resumeMath([])
  await waitFor(() => expect(writes).toHaveLength(1))
  resolveSave(Response.json({...markdownNote, version:'v2', markdown:writes[0].markdown,
    attachment_bindings:{[metadata(0).upload_id]:'file1'}}))
  await waitFor(() => expect(writes).toHaveLength(2), {timeout:2000})
  expect(writes[1]).toMatchObject({version:'v2', title:'준비 중 수정'})
  expect(writes[1]).not.toHaveProperty('draft_id')
  expect(writes[1]).not.toHaveProperty('uploads')
})
