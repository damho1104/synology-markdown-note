// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { Workspace } from './Workspace'

const note = { id: 'note1', title: '기존 제목', html: '<p>original</p>', notebook_id: 'book1', version: 'v1', attachments: [], locked: false, trashed: false, editable: true, read_only_reason: null }
const session = {username: 'alice', remember: false, csrf_token: 'csrf'}
const status = {configured: true, nas_url: 'https://nas.example', source: 'database' as const, read_only: false}
let writes: Record<string, unknown>[]
let resolveSave: (value: Response) => void
beforeEach(() => {
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
