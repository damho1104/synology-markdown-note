// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { Workspace } from './Workspace'
import { DEFAULT_PREFERENCES, PREFERENCES_KEY, loadPreferences } from './preferences'

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
    const body = path === '/api/notebooks' ? {notebooks: [{id: 'book1', name: '업무', stack: '프로젝트'}]} : path === '/api/notes' ? {notes: [note]} : path === '/api/writes' ? {operations: []} : note
    return new Response(JSON.stringify(body), {status: 200})
  }))
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals() })
function mount(onLogout = async () => {}) { return render(<Workspace session={session} status={status} onLogout={onLogout} onSessionExpired={() => {}} />) }
async function edit() { await screen.findByRole('button', {name: '편집'}); fireEvent.click(screen.getByRole('button', {name: '편집'})); fireEvent.change(screen.getByLabelText('노트 제목'), {target: {value: '수정 제목'}}) }
it('guards refresh and freezes inputs until saving completes', async () => {
  mount(); await edit(); fireEvent.click(screen.getByRole('button', {name: 'NAS에 저장'}))
  await waitFor(() => expect(writes).toHaveLength(1))
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).disabled).toBe(true)
  expect((screen.getByLabelText('HTML 본문') as HTMLTextAreaElement).disabled).toBe(true)
  const event = new Event('beforeunload', {cancelable: true}); window.dispatchEvent(event); expect(event.defaultPrevented).toBe(true)
  resolveSave(new Response(JSON.stringify({...note, title: '수정 제목', version: 'v2'})))
  await screen.findByRole('button', {name: '편집'})
  expect(sessionStorage.length).toBe(0)
})
it('keeps drafts and reports logout failure', async () => {
  mount(async () => {throw new Error('logout unavailable')}); await edit()
  await waitFor(() => expect(sessionStorage.length).toBe(1))
  fireEvent.click(screen.getByTitle('로그아웃'))
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'logout unavailable')
  expect(sessionStorage.length).toBe(1)
})
it('retains the base version across draft restore to detect concurrent NAS edits', async () => {
  sessionStorage.setItem('synonote:web-draft:["https://nas.example","alice"]:note:note1', JSON.stringify({key: 'note:note1', notebook_id: 'book1', title: '임시 제목', html: '<p>draft</p>', version: 'old-version'}))
  mount(); await screen.findByLabelText('노트 제목'); fireEvent.click(screen.getByRole('button', {name: 'NAS에 저장'}))
  await waitFor(() => expect(writes).toHaveLength(1)); expect(writes[0].version).toBe('old-version')
  resolveSave(new Response(JSON.stringify({error: 'REMOTE_CHANGED'}), {status: 409}))
  await screen.findByText('버전 충돌 · 로컬 편집본을 유지했습니다')
  expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('임시 제목')
})
it('discard removes temporary edits and stays in sync with the current route', async () => {
  mount(); await edit(); fireEvent.click(screen.getByRole('button', {name: '취소'}))
  await screen.findByRole('button', {name: '편집'}); expect(sessionStorage.length).toBe(0)
  expect(window.location.search).toContain('note=note1')
  fireEvent.click(screen.getByRole('button', {name: '편집'})); expect((screen.getByLabelText('노트 제목') as HTMLInputElement).value).toBe('기존 제목')
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
  await screen.findByRole('button', { name: '편집' })
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
  mount(); await screen.findByRole('button', { name: '편집' })
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
  fireEvent.click(await screen.findByRole('button', { name: '편집' }))
  await waitFor(() => expect(container.querySelector('.cm-lineNumbers')).toBeTruthy())
  expect(container.querySelector('.cm-content.cm-lineWrapping')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: /^설정$/ }))
  fireEvent.click(screen.getByLabelText('자동 줄바꿈'))
  fireEvent.click(screen.getByLabelText('줄 번호 표시'))
  await waitFor(() => expect(container.querySelector('.cm-lineNumbers')).toBeNull())
  expect(container.querySelector('.cm-content.cm-lineWrapping')).toBeNull()
  expect(writes).toHaveLength(0)
})
