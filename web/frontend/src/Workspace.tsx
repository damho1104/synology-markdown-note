import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import {
  AlertTriangle, ArrowLeft, ArrowRight, Book, BookOpenText, ChevronRight,
  FilePlus2, FileText, FolderOpen, LogOut, Menu, Paperclip, Pencil,
  RefreshCw, Save, Search, ShieldAlert, Trash2, X,
} from 'lucide-react'
import { ApiFailure, jsonRequest, request, type Session, type Status } from './api'
import { Button } from './components/ui/button'

type Notebook = { id: string; name: string; stack: string }
type NoteSummary = {
  id: string; title: string; notebook_id: string; version: string
  locked: boolean; trashed: boolean
}
type Attachment = { id: string; name: string; ref: string | null }
type NoteDetail = NoteSummary & {
  html: string; attachments: Attachment[]; editable: boolean; read_only_reason: string | null
}
type WriteOperation = {
  operation_id: string; target: string; note_id: string | null
  title: string; status: string; created: number
}
type Route = { shelf: string | null; notebook: string | null; note: string | null; compose: boolean }
type Draft = { key: string; title: string; html: string; notebook_id: string; version?: string }

const BLANK_HTML = '<p></p>'
const readOnlyReasons: Record<string, string> = {
  LOCKED: '암호화된 노트는 이 웹 버전에서 편집할 수 없습니다.',
  TRASHED: '휴지통에 있는 노트는 편집할 수 없습니다.',
  ATTACHMENTS: '첨부파일 또는 Markdown 원문 메타데이터가 포함된 노트입니다. 손상을 막기 위해 읽기 전용으로 엽니다.',
  COMPLEX_HTML: '복합 HTML·서식·내부 링크가 포함된 문서입니다. 안전한 왕복 편집이 검증될 때까지 읽기 전용입니다.',
}

function readRoute(): Route {
  const q = new URLSearchParams(window.location.search)
  return { shelf: q.get('s'), notebook: q.get('n'), note: q.get('note'), compose: q.get('new') === '1' }
}

function writeRoute(route: Route, index: number, replace = false): void {
  const url = new URL(window.location.href)
  for (const key of ['s', 'n', 'note', 'new']) url.searchParams.delete(key)
  if (route.shelf) url.searchParams.set('s', route.shelf)
  if (route.notebook) url.searchParams.set('n', route.notebook)
  if (route.note) url.searchParams.set('note', route.note)
  if (route.compose) url.searchParams.set('new', '1')
  window.history[replace ? 'replaceState' : 'pushState'](
    { ...window.history.state, __synonote_index: index }, '', url)
}

function draftRead(key: string): Draft | null {
  try {
    const raw = sessionStorage.getItem(key)
    const value = raw && JSON.parse(raw) as Draft
    if (value && typeof value.title === 'string' && typeof value.html === 'string' &&
        typeof value.notebook_id === 'string') return value
  } catch { /* Storage can be unavailable in private browsing. */ }
  return null
}

function draftStore(key: string, draft: Draft): void {
  try { sessionStorage.setItem(key, JSON.stringify(draft)) } catch { /* Keep the in-memory edit. */ }
}

function draftDelete(key: string): void {
  try { sessionStorage.removeItem(key) } catch { /* Storage can be unavailable. */ }
}

function previewDocument(html: string): string {
  // srcDoc runs in an opaque sandboxed origin, with all network and script loads blocked.
  const csp = "default-src 'none'; script-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'; img-src data:; style-src 'unsafe-inline'"
  return `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}"><style>body{font:15px/1.8 system-ui,sans-serif;overflow-wrap:anywhere;color:#20344c;padding:10px;margin:0}pre{overflow:auto;white-space:pre-wrap}img{max-width:100%}a{color:#216f8c}</style></head><body>${html}</body></html>`
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : '요청 처리 중 오류가 발생했습니다.'
}

export function Workspace({ session, status, onLogout, onSessionExpired }: {
  session: Session; status: Status; onLogout: () => Promise<void>; onSessionExpired: () => void
}) {
  const [route, setRoute] = useState<Route>(readRoute)
  const [notebooks, setNotebooks] = useState<Notebook[]>([])
  const [notes, setNotes] = useState<NoteSummary[]>([])
  const [listLoading, setListLoading] = useState(true)
  const [listError, setListError] = useState('')
  const [noteError, setNoteError] = useState('')
  const [detail, setDetail] = useState<NoteDetail | null>(null)
  const [noteLoading, setNoteLoading] = useState(false)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [editing, setEditing] = useState(false)
  const [saving, setSaving] = useState(false)
  const [query, setQuery] = useState('')
  const [pending, setPending] = useState<WriteOperation[]>([])
  const [pendingError, setPendingError] = useState('')
  const [compare, setCompare] = useState<NoteDetail | null>(null)
  const [message, setMessage] = useState('')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [revision, setRevision] = useState(0)
  const historyIndex = useRef<number>(typeof window.history.state?.__synonote_index === 'number'
    ? window.history.state.__synonote_index : 0)
  const navigating = useRef({ route, draft, activeKey: null as string | null,
    draftKey: null as string | null, dirty: false, saving: false })

  // No NAS credential, cookie token or SID is stored in browser storage.
  const draftPrefix = `synonote:web-draft:${JSON.stringify([status.nas_url, session.username])}:`
  const activeKey = route.compose && route.notebook ? `new:${route.notebook}` :
    route.note ? `note:${route.note}` : null
  const activeDraftKey = activeKey ? draftPrefix + activeKey : null
  const original = detail && !route.compose ? detail : null
  const dirty = !!(draft && activeKey === draft.key && (route.compose
    ? draft.title.trim().length > 0 || draft.html !== BLANK_HTML
    : original && (original.title !== draft.title || original.html !== draft.html)))
  navigating.current = { route, draft, activeKey, draftKey: activeDraftKey, dirty, saving }

  function commitRoute(next: Route, replace = false) {
    const index = historyIndex.current + (replace ? 0 : 1)
    writeRoute(next, index, replace)
    historyIndex.current = index
    setRoute(next)
    setSidebarOpen(false)
    setCompare(null)
  }

  const handleError = useCallback((error: unknown, setter: (text: string) => void) => {
    setter(errorText(error))
    if (error instanceof ApiFailure && error.status === 401) onSessionExpired()
  }, [onSessionExpired])

  const loadLists = useCallback(async () => {
    setListLoading(true)
    try {
      const [books, all] = await Promise.all([
        request<{ notebooks: Notebook[] }>('/api/notebooks'),
        request<{ notes: NoteSummary[] }>('/api/notes'),
      ])
      setNotebooks(books.notebooks)
      setNotes(all.notes)
      setListError('')
    } catch (error) { handleError(error, setListError) }
    finally { setListLoading(false) }
  }, [handleError])

  const loadPending = useCallback(async () => {
    try {
      const data = await request<{ operations: WriteOperation[] }>('/api/writes')
      setPending(data.operations)
      setPendingError('')
    } catch (error) { handleError(error, setPendingError) }
  }, [handleError])

  useEffect(() => { void loadLists(); void loadPending() }, [loadLists, loadPending])
  useEffect(() => {
    writeRoute(readRoute(), historyIndex.current, true)
    const pop = (event: PopStateEvent) => {
      const next = readRoute()
      const current = navigating.current
      const destination = next.compose && next.notebook ? `new:${next.notebook}` : next.note ? `note:${next.note}` : null
      const nextIndex = typeof event.state?.__synonote_index === 'number'
        ? event.state.__synonote_index : null
      const restore = () => {
        if (nextIndex !== null && nextIndex !== historyIndex.current) {
          window.history.go(historyIndex.current - nextIndex)
        } else {
          writeRoute(current.route, historyIndex.current, true)
        }
      }
      if (current.saving) { restore(); return }
      if (current.activeKey !== destination && current.dirty) {
        if (!window.confirm('편집 내용은 이 탭에 임시 보관됩니다. 이동할까요?')) {
          restore()
          return
        }
        if (current.draft && current.draftKey) draftStore(current.draftKey, current.draft)
      }
      if (nextIndex !== null) historyIndex.current = nextIndex
      setRoute(next)
      setCompare(null)
      setMessage('')
    }
    window.addEventListener('popstate', pop)
    return () => window.removeEventListener('popstate', pop)
  }, [])
  useEffect(() => {
    if (!dirty && !saving) return
    const beforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', beforeUnload)
    return () => window.removeEventListener('beforeunload', beforeUnload)
  }, [dirty, saving])

  useEffect(() => {
    let active = true
    setDetail(null)
    setNoteError('')
    setCompare(null)
    if (!activeKey || !activeDraftKey) {
      setNoteLoading(false)
      setDraft(null)
      setEditing(false)
      return
    }
    if (route.compose) {
      setNoteLoading(false)
      setDraft(draftRead(activeDraftKey) ?? { key: activeKey, title: '', html: BLANK_HTML, notebook_id: route.notebook! })
      setEditing(true)
      return
    }
    setNoteLoading(true)
    setDraft(null)
    setEditing(false)
    void request<NoteDetail>(`/api/notes/${encodeURIComponent(route.note!)}`).then((note) => {
      if (!active) return
      setDetail(note)
      const saved = draftRead(activeDraftKey)
      if (saved && saved.key === activeKey && saved.notebook_id === note.notebook_id && note.editable) {
        setDraft(saved)
        setEditing(true)
        setMessage('이 탭에 남아 있던 편집 내용을 복원했습니다.')
      } else {
        setDraft({ key: activeKey, title: note.title, html: note.html, notebook_id: note.notebook_id, version: note.version })
      }
    }).catch(error => { if (active) handleError(error, setNoteError) })
      .finally(() => { if (active) setNoteLoading(false) })
    return () => { active = false }
  }, [activeKey, activeDraftKey, route.compose, route.note, route.notebook, revision, handleError])

  useEffect(() => {
    if (draft && activeDraftKey && draft.key === activeKey && editing && dirty) {
      draftStore(activeDraftKey, draft)
    }
  }, [activeKey, activeDraftKey, draft, dirty, editing])

  const shelves = useMemo(() => Array.from(new Set(notebooks.map(book => book.stack || '')))
    .sort((a, b) => a.localeCompare(b, 'ko')), [notebooks])
  const notebookById = useMemo(() => new Map(notebooks.map(book => [book.id, book])), [notebooks])
  const selectedNotebook = route.notebook ? notebookById.get(route.notebook) : undefined
  const selectedShelf = route.shelf
  const visibleNotes = useMemo(() => notes.filter(note => {
    const book = notebookById.get(note.notebook_id)
    if (!book) return false
    if (route.notebook && note.notebook_id !== route.notebook) return false
    if (!route.notebook && selectedShelf !== null && (book.stack || '') !== selectedShelf) return false
    return note.title.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())
  }).sort((a, b) => a.title.localeCompare(b.title, 'ko')), [notes, notebookById, route.notebook, selectedShelf, query])

  function navigate(next: Route, replace = false) {
    if (saving) return
    if (activeKey !== (next.compose && next.notebook ? `new:${next.notebook}` : next.note ? `note:${next.note}` : null)
      && dirty && !window.confirm('편집 내용은 이 탭에 임시 보관됩니다. 다른 노트로 이동할까요?')) return
    if (dirty && draft && activeDraftKey) draftStore(activeDraftKey, draft)
    commitRoute(next, replace)
    setMessage('')
  }

  function startEdit() {
    if (!detail || !detail.editable || !activeKey) return
    setDraft({ key: activeKey, title: detail.title, html: detail.html, notebook_id: detail.notebook_id, version: detail.version })
    setEditing(true)
    setMessage('HTML 원문을 직접 편집합니다. 복합 서식 문서는 읽기 전용입니다.')
  }

  function discard() {
    if (saving) return
    if (dirty && !window.confirm('이 탭의 임시 편집 내용도 삭제할까요?')) return
    if (activeDraftKey) draftDelete(activeDraftKey)
    if (route.compose) {
      setDraft(null)
      setEditing(false)
      commitRoute({ ...route, compose: false }, true)
      setMessage('새 노트 작성을 취소했습니다.')
    } else {
      if (detail && activeKey) setDraft({ key: activeKey, title: detail.title, html: detail.html, notebook_id: detail.notebook_id, version: detail.version })
      setEditing(false)
      setMessage('편집을 취소했습니다.')
    }
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!draft || !activeDraftKey || saving || !draft.title.trim()) return
    if (!route.compose && (!detail?.editable || !dirty)) return
    const isNew = route.compose
    setSaving(true)
    setNoteError('')
    setCompare(null)
    if (dirty) draftStore(activeDraftKey, draft)
    try {
      const url = isNew ? '/api/notes' : `/api/notes/${encodeURIComponent(route.note!)}`
      const next = await request<NoteDetail>(url, jsonRequest({
        title: draft.title.trim(), html: draft.html, notebook_id: draft.notebook_id,
        ...(!isNew ? { version: draft.version ?? "unknown-draft-base" } : {}),
      }, { 'X-CSRF-Token': session.csrf_token }, isNew ? 'POST' : 'PUT'))
      draftDelete(activeDraftKey)
      setEditing(false)
      setMessage('NAS에 저장하고 최신 버전을 확인했습니다.')
      if (isNew) {
        setDraft(null)
        commitRoute({ shelf: route.shelf, notebook: next.notebook_id, note: next.id, compose: false }, true)
      } else {
        setDetail(next)
        setDraft({ key: activeKey!, title: next.title, html: next.html, notebook_id: next.notebook_id, version: next.version })
      }
      await Promise.all([loadLists(), loadPending()])
    } catch (error) {
      handleError(error, setNoteError)
      if (error instanceof ApiFailure && error.code === 'REMOTE_CHANGED' && route.note) {
        try { setCompare(await request<NoteDetail>(`/api/notes/${encodeURIComponent(route.note)}`)) }
        catch { /* Keep the local draft even if the comparison fetch fails. */ }
      }
      if (error instanceof ApiFailure && ['WRITE_UNCERTAIN', 'WRITE_REVIEW_REQUIRED'].includes(error.code)) {
        void loadPending()
      }
    } finally { setSaving(false) }
  }

  async function acknowledge(operation: WriteOperation) {
    if (!window.confirm(`NAS에서 '${operation.title}'의 저장 결과를 직접 확인했나요? 확인한 경우에만 작업 보류를 해제합니다.`)) return
    try {
      await request(`/api/writes/${encodeURIComponent(operation.operation_id)}/ack`,
        jsonRequest({}, { 'X-CSRF-Token': session.csrf_token }))
      setMessage('보류된 쓰기 기록을 확인 처리했습니다.')
      await loadPending()
    } catch (error) { handleError(error, setPendingError) }
  }

  function logout() {
    if (saving) return
    if (dirty && !window.confirm('임시 편집 내용을 삭제하고 로그아웃할까요?')) return
    void onLogout().then(() => {
      // Logout also clears local drafts for this NAS account.
      try {
        for (let i = sessionStorage.length - 1; i >= 0; i--) {
          const key = sessionStorage.key(i)
          if (key?.startsWith(draftPrefix)) sessionStorage.removeItem(key)
        }
      } catch { /* Session may be disabled. */ }
    }).catch(error => handleError(error, setNoteError))
  }

  return (
    <div className="min-h-screen bg-paper text-ink">
      <header className="sticky top-0 z-20 border-b border-slate-200 bg-white/95 backdrop-blur">
        <div className="flex min-h-[74px] flex-wrap items-center justify-between gap-3 px-4 py-3 sm:px-6">
          <div className="flex items-center gap-3">
            <Button variant="outline" className="md:hidden" size="icon" aria-label="책장 메뉴" onClick={() => setSidebarOpen(!sidebarOpen)}><Menu size={18} /></Button>
            <div className="rounded-xl bg-ink p-2 text-white"><BookOpenText size={21} /></div>
            <div><h1 className="text-sm font-bold sm:text-base">Synology Markdown Note</h1><p className="text-xs text-slate-500">{session.username} · Note Station</p></div>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="icon" disabled={saving} onClick={() => window.history.back()} aria-label="이전 화면"><ArrowLeft size={17} /></Button>
            <Button variant="outline" size="icon" disabled={saving} onClick={() => window.history.forward()} aria-label="다음 화면"><ArrowRight size={17} /></Button>
            <Button variant="outline" size="icon" onClick={() => { void loadLists(); void loadPending(); setRevision(n => n + 1) }} aria-label="새로고침" disabled={saving}><RefreshCw size={17} /></Button>
            <Button variant="outline" disabled={saving} onClick={logout} title="로그아웃"><LogOut size={16} /><span className="hidden sm:inline">로그아웃</span></Button>
          </div>
        </div>
      </header>
      {status.nas_url?.startsWith('http://') && <div className="border-b border-amber-200 bg-amber-50 px-5 py-2 text-xs leading-5 text-amber-900"><AlertTriangle size={14} className="mr-2 inline" />NAS 연결이 HTTP입니다. 계정 정보와 노트가 내부망에서도 암호화되지 않습니다.</div>}
      {!!pending.length && <section className="border-b border-amber-200 bg-amber-50 px-5 py-3 text-sm" aria-label="저장 확인 대기 작업">
        <p className="font-semibold text-amber-950"><ShieldAlert size={17} className="mr-1 inline" /> NAS 저장 결과 확인 필요 · {pending.length}건</p>
        <p className="mt-1 text-xs leading-5 text-amber-900">응답이 유실된 저장은 자동 재시도하지 않습니다. Note Station에서 직접 확인한 뒤 보류를 해제하세요.</p>
        <div className="mt-2 flex flex-wrap gap-2">{pending.map(op => <Button key={op.operation_id} variant="outline" className="h-auto py-1.5 text-xs" disabled={op.status === 'pending' && Date.now() - op.created * 1000 < 3600_000} onClick={() => void acknowledge(op)}>{op.title} · {op.status === 'pending' && Date.now() - op.created * 1000 < 3600_000 ? '전송 중 / 결과 확인 대기' : 'NAS 확인 후 보류 해제'}</Button>)}</div>
      </section>}
      {pendingError && <p className="border-b border-rose-200 bg-rose-50 px-5 py-2 text-xs text-rose-800" role="alert">저장 작업 조회: {pendingError}</p>}
      {message && <div className="border-b border-sky-100 bg-sky-50 px-5 py-2 text-sm text-sky-900" role="status">{message}</div>}
      <div className="grid min-h-[calc(100vh-74px)] md:grid-cols-[220px_minmax(240px,300px)_minmax(0,1fr)] xl:grid-cols-[260px_330px_minmax(0,1fr)]">
        <aside className={`${sidebarOpen ? 'block' : 'hidden'} border-b border-slate-200 bg-slate-50/80 px-3 py-5 md:block md:border-b-0 md:border-r`} aria-label="책장 및 메모장">
          <p className="px-3 text-[11px] font-bold uppercase tracking-widest text-slate-500">라이브러리</p>
          <button className={`nav-row mt-3 ${selectedShelf === null && !route.notebook ? 'nav-selected' : ''}`} onClick={() => navigate({ shelf: null, notebook: null, note: null, compose: false })}><FolderOpen size={16} /> 모든 노트 <span className="ml-auto text-xs text-slate-500">{notes.length}</span></button>
          <div className="mt-6 flex items-center justify-between px-3"><p className="text-xs font-bold text-slate-500">책장</p><span className="text-xs text-slate-400">{shelves.length}</span></div>
          {shelves.map(stack => <button key={stack} className={`nav-row mt-1 ${!route.notebook && selectedShelf === stack ? 'nav-selected' : ''}`} onClick={() => navigate({ shelf: stack, notebook: null, note: null, compose: false })}><Book size={16} /><span className="min-w-0 flex-1 truncate text-left">{stack || '기본 책장'}</span><ChevronRight size={13} /></button>)}
          <div className="mt-6 px-3 text-xs font-bold text-slate-500">메모장</div>
          {notebooks.filter(book => selectedShelf === null || (book.stack || '') === selectedShelf).map(book => <button key={book.id} className={`nav-row mt-1 ${route.notebook === book.id ? 'nav-selected' : ''}`} onClick={() => navigate({ shelf: book.stack || '', notebook: book.id, note: null, compose: false })}><BookOpenText size={16} /><span className="min-w-0 flex-1 truncate text-left">{book.name}</span><span className="text-xs text-slate-400">{notes.filter(n => n.notebook_id === book.id).length}</span></button>)}
          {listLoading && <p className="px-3 py-4 text-xs text-slate-500"><RefreshCw size={14} className="mr-1 inline animate-spin" /> 메모장 불러오는 중…</p>}
        </aside>

        <section className="min-w-0 border-b border-slate-200 bg-white md:border-b-0 md:border-r" aria-label="노트 목록">
          <div className="border-b border-slate-100 px-4 py-5">
            <div className="mb-4 flex items-start justify-between gap-3"><div className="min-w-0"><p className="text-xs font-semibold text-marine">NOTE LIST</p><h2 className="mt-1 truncate text-xl font-bold">{selectedNotebook?.name ?? (selectedShelf === null ? '모든 노트' : selectedShelf || '기본 책장')}</h2></div><Button size="icon" aria-label="새 노트" title={selectedNotebook ? '새 노트' : '메모장을 선택하세요'} disabled={!selectedNotebook} onClick={() => selectedNotebook && navigate({ shelf: route.shelf, notebook: selectedNotebook.id, note: null, compose: true })}><FilePlus2 size={18} /></Button></div>
            <label className="relative block"><Search size={17} className="pointer-events-none absolute left-3 top-3 text-slate-400" /><span className="sr-only">노트 제목 검색</span><input className="field py-2.5 pl-10 text-sm" placeholder="노트 제목 검색" value={query} onChange={e => setQuery(e.target.value)} /></label>
            <p className="mt-3 text-xs text-slate-500">{visibleNotes.length}개 노트 · NAS에서 불러옴</p>
          </div>
          {listError && <div role="alert" className="m-4 rounded-xl bg-rose-50 p-4 text-sm text-rose-800">{listError}<Button variant="outline" className="mt-3" onClick={() => void loadLists()}>재시도</Button></div>}
          {listLoading ? <p className="p-6 text-sm text-slate-500"><RefreshCw size={16} className="mr-2 inline animate-spin" />노트를 불러오는 중…</p> : !visibleNotes.length ? <p className="p-6 text-sm leading-7 text-slate-500">표시할 노트가 없습니다. 메모장을 선택하거나 검색 조건을 변경하세요.</p> :
            <div className="max-h-[48vh] overflow-auto md:max-h-[calc(100vh-245px)]">{visibleNotes.map(note => <button key={note.id} onClick={() => navigate({ shelf: route.shelf, notebook: route.notebook, note: note.id, compose: false })} className={`w-full border-b border-slate-100 px-5 py-4 text-left transition hover:bg-mist/60 ${route.note === note.id ? 'bg-mist/70' : ''}`}><p className="flex items-center gap-2 text-sm font-semibold"><FileText size={15} className="shrink-0 text-marine" /><span className="min-w-0 truncate">{note.title}</span></p><p className="mt-1.5 truncate pl-6 text-xs text-slate-500">{notebookById.get(note.notebook_id)?.name ?? '메모장'} {note.locked ? '· 암호화' : ''}{note.trashed ? '· 휴지통' : ''}</p></button>)}</div>}
        </section>

        <main className="min-w-0 p-4 sm:p-6 lg:p-9" aria-label="노트 본문">
          {!activeKey ? <div className="flex min-h-80 flex-col items-center justify-center rounded-2xl border border-dashed border-slate-200 bg-white px-5 py-12 text-center"><BookOpenText size={42} className="text-marine" /><h2 className="mt-5 text-xl font-bold">노트를 선택하세요</h2><p className="mt-3 max-w-md text-sm leading-7 text-slate-500">왼쪽에서 책장과 메모장을 탐색하고 노트를 여세요. 새 노트는 메모장을 선택한 뒤 + 버튼으로 작성할 수 있습니다.</p></div> : noteLoading ? <p className="flex items-center gap-2 py-12 text-sm text-slate-500"><RefreshCw size={17} className="animate-spin" /> 노트 내용 불러오는 중…</p> : noteError && !editing ? <div className="rounded-xl bg-rose-50 p-5 text-sm text-rose-800" role="alert">{noteError}<Button className="ml-2" variant="outline" onClick={() => setRevision(n => n + 1)}>재시도</Button></div> : (route.compose || detail) ? <>
            <div className="mb-6 flex flex-wrap items-center justify-between gap-3"><div className="min-w-0"><p className="mb-1 text-xs font-semibold text-marine">{route.compose ? '새 노트 작성' : `버전 ${detail?.version ?? ''}`}</p><h2 className="break-words text-2xl font-bold tracking-tight">{editing ? (draft?.title || '제목 없는 노트') : detail?.title}</h2></div>{!editing && detail?.editable && <Button onClick={startEdit}><Pencil size={16} /> 편집</Button>}</div>
            {!route.compose && detail && !detail.editable && <div className="mb-5 flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-950"><ShieldAlert className="mt-1 shrink-0" size={17} /><p>{readOnlyReasons[detail.read_only_reason ?? ''] ?? '이 문서는 읽기 전용입니다.'}</p></div>}
            {noteError && <p className="mb-4 rounded-xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800" role="alert">{noteError}</p>}
            {editing && draft ? <form onSubmit={e => void save(e)} className="space-y-5">
              <div><label className="field-label" htmlFor="note-title">노트 제목</label><input className="field" id="note-title" maxLength={256} required disabled={saving} value={draft.title} onChange={e => setDraft({ ...draft, title: e.target.value })} /></div>
              <div><label className="field-label" htmlFor="note-html">HTML 본문</label><p className="mb-2 text-xs leading-6 text-slate-500">현재는 단순 HTML을 직접 편집할 수 있습니다. 지원 태그: 문단, 제목, 목록, 강조, 코드 등. 이미지·첨부·복합 HTML은 읽기 전용입니다.</p><textarea id="note-html" className="field min-h-[240px] resize-y font-mono text-[13px] leading-6" spellCheck={false} disabled={saving} value={draft.html} onChange={e => setDraft({ ...draft, html: e.target.value })} /></div>
              <div className="flex flex-wrap items-center gap-3"><Button type="submit" disabled={saving || !draft.title.trim() || (!route.compose && !dirty)}><Save size={16} />{saving ? 'NAS 저장 중…' : 'NAS에 저장'}</Button><Button type="button" variant="outline" disabled={saving} onClick={discard}><X size={15} /> 취소</Button>{dirty && <span className="text-xs text-amber-800">변경 사항 · 이 탭에 임시 보관</span>}</div>
            </form> : null}
            {compare && draft && <div className="mb-6 rounded-xl border border-amber-200 bg-amber-50 p-4"><h3 className="font-semibold text-amber-950">버전 충돌 · 로컬 편집본을 유지했습니다</h3><p className="mt-2 text-xs leading-6">NAS 버전 {compare.version}과 현재 편집 내용을 비교하세요. 다른 사용자의 변경을 자동으로 덮어쓰지 않습니다.</p><div className="mt-3 grid gap-3 lg:grid-cols-2"><div><p className="text-xs font-bold">NAS 최신 내용</p><pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-white p-3 text-xs">{compare.html}</pre></div><div><p className="text-xs font-bold">내 편집 내용</p><pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-white p-3 text-xs">{draft.html}</pre></div></div><Button variant="outline" className="mt-3" onClick={() => { if (window.confirm('로컬 편집 내용을 삭제하고 NAS의 최신 버전을 열까요?')) { if (activeDraftKey) draftDelete(activeDraftKey); setDraft(null); setEditing(false); setCompare(null); setRevision(n => n + 1) } }}>로컬 편집 포기하고 NAS 최신 버전 열기</Button></div>}
            {(!detail?.locked || route.compose) && <section className="mt-7"><h3 className="mb-3 text-sm font-bold">{editing ? '미리보기' : '내용'}</h3><iframe title="노트 HTML 미리보기" sandbox="" referrerPolicy="no-referrer" className="note-preview w-full rounded-xl border border-slate-200 bg-white" srcDoc={previewDocument(editing && draft ? draft.html : detail?.html ?? '')} /></section>}
            {detail?.attachments.length ? <section className="mt-7"><h3 className="mb-3 text-sm font-bold">첨부파일 · {detail.attachments.length}개</h3><div className="divide-y divide-slate-100 overflow-hidden rounded-xl border border-slate-200 bg-white">{detail.attachments.map(file => <a key={file.id} href={`/api/notes/${encodeURIComponent(detail.id)}/attachments/${encodeURIComponent(file.id)}`} download={file.name} className="flex items-center gap-3 px-4 py-3 text-sm text-marine hover:bg-mist"><Paperclip size={16} /> <span className="break-all">{file.name}</span></a>)}</div></section> : null}
            {!route.compose && detail?.locked && <p className="rounded-xl border border-slate-200 bg-white p-5 text-sm text-slate-500">암호화된 본문은 표시하지 않습니다.</p>}
            {route.compose && <p className="mt-7 text-xs leading-6 text-slate-500"><Trash2 size={13} className="mr-1 inline" /> 새 노트 저장 전에는 NAS에 문서가 생성되지 않습니다. 통신이 끊겨 결과가 불확실하면 자동으로 다시 보내지 않습니다.</p>}
          </> : null}
        </main>
      </div>
    </div>
  )
}
