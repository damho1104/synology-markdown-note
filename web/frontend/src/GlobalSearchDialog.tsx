import { t } from "./i18n";
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Search, X } from 'lucide-react'
import { sortNotes, type DatedNote } from './library'
import { useIndexedNoteCount } from './GraphIndex'

type SearchNote = DatedNote & {notebook_id:string; trashed:boolean; excerpt?:string; tags?:string[]; version?:string}
export type BodySearchResult = {matches: SearchNote[]; indexed:number; total:number}
export function GlobalSearchDialog({notes, notebooks, loading, searchBody, onSelect, onClose}: {
  notes:SearchNote[]; notebooks:{id:string;name:string}[]; loading:boolean
  searchBody?:(query:string, signal:AbortSignal)=>Promise<BodySearchResult>
  onSelect:(id:string)=>Promise<boolean>; onClose:()=>void
}) {
  const dialogRef=useRef<HTMLDialogElement>(null)
  const inputRef=useRef<HTMLInputElement>(null)
  const titleId=useId(), helpId=useId()
  const [query,setQuery]=useState('')
  const [busy,setBusy]=useState(false)
  const [composing,setComposing]=useState(false)
  const [error,setError]=useState('')
  const [body,setBody]=useState<{query:string; result?:BodySearchResult} | null>(null)
  const indexedCount = useIndexedNoteCount()
  const term = query.trim()
  const result = term === body?.query ? body.result : undefined
  const searchingBody = !!(searchBody && term && term !== body?.query)
  useEffect(() => {
    if (!searchBody || !term || composing) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void searchBody(term, controller.signal).then(value => {
        if (!controller.signal.aborted) {
          setBody(Array.isArray(value?.matches) ? {query:term, result:value} : {query:term})
        }
      }).catch(() => {
        if (!controller.signal.aborted) setBody({query:term})
      })
    }, 250)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [searchBody, term, indexedCount, composing])
  const books=useMemo(()=>new Map(notebooks.map(book=>[book.id,book.name])),[notebooks])
  const rows=useMemo(()=>{
    const needle=term.toLocaleLowerCase()
    const matching = new Map(notes.filter(note=>!note.trashed &&
      `${note.title} ${note.excerpt ?? ''} ${(note.tags ?? []).join(' ')}`.toLocaleLowerCase().includes(needle))
      .map(note => [note.id, note]))
    for (const note of result?.matches ?? []) matching.set(note.id, note)
    return sortNotes([...matching.values()], 'modifiedAt', 'descending')
  },[notes,term,result])
  useLayoutEffect(()=>{
    const dialog=dialogRef.current!
    const previous=document.activeElement instanceof HTMLElement ? document.activeElement : null
    if(typeof dialog.showModal === 'function') dialog.showModal()
    else dialog.setAttribute('open','')
    inputRef.current?.focus()
    const contain=(event:FocusEvent)=>{
      if(event.target instanceof Node && !dialog.contains(event.target)) inputRef.current?.focus()
    }
    document.addEventListener('focusin',contain)
    return ()=>{
      document.removeEventListener('focusin',contain)
      if(typeof dialog.close === 'function' && dialog.open) dialog.close()
      else dialog.removeAttribute('open')
      if(previous?.isConnected) previous.focus()
    }
  },[])
  async function open(id:string) {
    if(busy) return
    setBusy(true);setError('')
    try {
      if(await onSelect(id)) onClose()
      else setError(t("search.confirmThatCurrentNoteWasSavedThenTry"))
    } catch { setError(t("search.couldNotOpenNoteSelectItAgainRetry")) }
    finally { setBusy(false) }
  }
  return <dialog ref={dialogRef} className="native-settings-dialog native-search-dialog" aria-modal="true" aria-labelledby={titleId} aria-describedby={helpId}
    onCompositionStart={event=>{event.stopPropagation();setComposing(true)}}
    onCompositionEnd={event=>{event.stopPropagation();setComposing(false)}}
    onCancel={event=>{event.preventDefault();onClose()}}
    onClick={event=>{
      if(event.target!==event.currentTarget) return
      const r=event.currentTarget.getBoundingClientRect()
      if(event.clientX<r.left || event.clientX>=r.right || event.clientY<r.top || event.clientY>=r.bottom) onClose()
    }}
    onKeyDown={event=>{
      if(event.key==='Escape') {event.preventDefault();onClose();return}
      if(event.key!=='Tab') return
      const controls=Array.from(event.currentTarget.querySelectorAll<HTMLElement>('button:not([disabled]), input:not([disabled])'))
      if(event.shiftKey && document.activeElement===controls[0]) {event.preventDefault();controls.at(-1)?.focus()}
      else if(!event.shiftKey && document.activeElement===controls.at(-1)) {event.preventDefault();controls[0]?.focus()}
    }}>
    <header className="global-search-header"><Search size={18}/><h2 id={titleId}>{t("common.searchAllNotes")}</h2>
      <button className="icon-button" aria-label={t("search.closeSearch")} onClick={onClose}><X size={17}/></button></header>
    <form className="global-search-field" onSubmit={event=>{event.preventDefault();if(rows[0]) void open(rows[0].id)}}>
      <input ref={inputRef} type="search" aria-label={t("search.searchQueryForAllNotes")} placeholder={t("search.searchNoteTitlesBodiesAndTags")} value={query} maxLength={256}
        onChange={event=>setQuery(event.target.value)}
        onKeyDown={event=>{if(event.key==='Enter' && (event.nativeEvent.isComposing || event.keyCode===229)) event.preventDefault()}} />
    </form>
    <p id={helpId} className="global-search-help">{t("search.searchesTitlesBodiesAndTagsAllNotesOutside")}</p>
    <p className="global-search-count" role="status" aria-live="polite">{loading ? t("common.loadingNotes") : t("search.results", rows.length, rows.length > 100 ? " · " + t("common.showingFirst100") : "")}
      {searchingBody && " " + t("search.searchingNoteBodies")}
      {result && result.indexed < result.total && " " + t("search.bodyIndex", result.indexed, result.total)}
      {searchBody && term && term === body?.query && !result && " " + t("search.couldNotSearchNoteBodies")}
    </p>
    {error && <p className="global-search-error" role="alert">{error}</p>}
    <div className="global-search-results" aria-label={t("search.allSearchResults")} aria-busy={busy}>
      {rows.slice(0,100).map(note=><button className="global-search-result" key={note.id} disabled={busy} onClick={()=>void open(note.id)}>
        <strong>{note.title || t("common.untitled")}</strong><small>{books.get(note.notebook_id) ?? note.notebook_id}{note.tags?.length ? ` · ${note.tags.map(tag=>`#${tag}`).join(' ')}` : ''}</small>
        {note.excerpt && <span>{note.excerpt}</span>}
      </button>)}
      {!loading && !searchingBody && !rows.length && <p className="global-search-empty">{t("search.noResultsFound")}</p>}
    </div>
  </dialog>
}
