import { t, UiError } from "./i18n";
import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { backgroundRead, errorText, request } from './api'
export type Node = { id: string; title: string; notebook_id: string; tags?: string[]; version?: string }
export type Edge = { source: string; target: string }
export type Graph = { nodes: Node[]; edges: Edge[]; failures: { id: string; error: string }[] }
export type Entry = {id: string; title?: string; notebook_id?: string; version?: string; document_id?: string; hidden?: boolean; error?: string; links?: {kind: string; target: string}[]};

export function mergeGraph(nodes: Node[], entries: Entry[]): Graph {
  const hidden = new Set(entries.filter(e => e.hidden).map(e => e.id));
  const known = new Map(entries.map(e => [e.id, e]));
  const visible = nodes.filter(n => !hidden.has(n.id)).map(n => {
    const entry = known.get(n.id);
    return entry?.title !== undefined ? {...n, title:entry.title, notebook_id:entry.notebook_id ?? n.notebook_id, version:entry.version} : n;
  });
  const ids = new Set(visible.map(n => n.id));
  const documents = new Map<string,string[]>(), titles = new Map<string,string[]>();
  for (const n of visible) titles.set(n.title, [...titles.get(n.title) ?? [], n.id]);
  for (const entry of entries) {
    if (ids.has(entry.id) && entry.document_id) {
      const key = entry.document_id.toLowerCase();
      documents.set(key, [...documents.get(key) ?? [], entry.id]);
    }
  }
  const failures = entries.filter(e => e.error).map(e => ({id:e.id,error:e.error!}));
  for (const group of documents.values()) if (group.length > 1)
    failures.push(...group.map(id => ({id,error:'AMBIGUOUS_DOCUMENT_ID'})));
  const edges = new Map<string,Edge>();
  for (const e of entries) for (const link of e.links ?? []) {
    const group = link.kind === 'document' ? documents.get(link.target.toLowerCase()) : link.kind === 'title' ? titles.get(link.target) : [link.target];
    const target = group?.length === 1 ? group[0] : undefined;
    if (target && ids.has(target) && ids.has(e.id) && target !== e.id) edges.set(JSON.stringify([e.id,target]), {source:e.id,target});
  }
  return {nodes:visible,edges:[...edges.values()],failures};
}
const empty: Graph = { nodes: [], edges: [], failures: [] }
export type GraphIndexState = {graph: Graph; loading: boolean; error: string; progress: {done:number; total:number}; retry: () => void}
const GraphIndexContext = createContext<GraphIndexState | null>(null)
function useGraphLoader(enabled: boolean, revision = ''): GraphIndexState {
  const [graph,setGraph] = useState<Graph>(empty)
  const [loading,setLoading] = useState(enabled)
  const [error,setError] = useState('')
  const [progress,setProgress] = useState({done:0,total:0})
  const [attempt,setAttempt] = useState(0)
  const latestRevision = useRef(revision)
  const running = useRef(false)
  const started = useRef(false)
  const userRetry = useRef(false)
  useEffect(() => {
    if (latestRevision.current === revision) return
    latestRevision.current = revision
    if (started.current && !running.current) setAttempt(value => value + 1)
  }, [revision])
  useEffect(() => {
    if (!enabled) { started.current = false; return; }
    started.current = true;
    running.current = true;
    const controller = new AbortController()
    let activeRead = userRetry.current
    userRetry.current = false
    setLoading(true)
    setError('')
    setProgress({done:0,total:0});
    const read = async <T,>(url: string): Promise<T> => {
      const page = new AbortController();
      const abort = () => page.abort();
      controller.signal.addEventListener('abort', abort);
      const timer = setTimeout(abort, 60000);
      const active = activeRead;
      activeRead = false;
      try { return await (active ? request<T>(url, {signal: page.signal}) : backgroundRead<T>(url, page.signal)); }
      catch (failure) {
        if (page.signal.aborted && !controller.signal.aborted) throw new UiError("errors.nasGraphRequestTimedOutVerifiedNotesStill");
        throw failure;
      } finally { clearTimeout(timer); controller.signal.removeEventListener('abort', abort); }
    };
    void (async () => {
      let scannedRevision: string;
      do {
        scannedRevision = latestRevision.current;
        const first = await read<Graph & {pending?: string[]; entries?: Entry[]}>('/api/graph?summary=true');
        if (controller.signal.aborted) return;
        if (!Array.isArray(first.nodes) || !Array.isArray(first.edges) || !Array.isArray(first.failures)) throw new UiError("errors.couldNotVerifyLinkIndexResponse");
        setGraph(first.pending ? mergeGraph(first.nodes, first.entries ?? []) : first);
        if (!first.pending) break;
        const entries: Entry[] = [...first.entries ?? []];
        const total = first.nodes.length;
        const cached = total - first.pending.length;
        setProgress({done:cached,total});
        for (let offset=0; offset<first.pending.length; offset+=8) {
          if (controller.signal.aborted) return;
          const ids = first.pending.slice(offset,offset+8);
          const batch = await read<{entries:Entry[]}>(`/api/graph/entries?ids=${encodeURIComponent(JSON.stringify(ids))}`);
          if (controller.signal.aborted) return;
          entries.push(...batch.entries);
          setGraph(mergeGraph(first.nodes,entries));
          setProgress({done:Math.min(cached+offset+ids.length,total),total});
        }
      } while (!controller.signal.aborted && scannedRevision !== latestRevision.current);
    })().catch((failure: unknown) => {
      if (!controller.signal.aborted) setError(errorText(failure, "graph.couldNotLoadGraph"));
    }).finally(() => { if (!controller.signal.aborted) { running.current = false; setLoading(false) } });
    return () => { running.current = false; controller.abort() }
  }, [attempt, enabled])

  return useMemo(() => ({graph,loading,error,progress,retry: () => {
    userRetry.current = true;
    setAttempt(value => value + 1);
  }}), [graph,loading,error,progress])
}
export function GraphIndexProvider({children, enabled = true, revision = ''}: {children: ReactNode; enabled?: boolean; revision?: string}) {
  const index = useGraphLoader(enabled, revision)
  return <GraphIndexContext.Provider value={index}>{children}</GraphIndexContext.Provider>
}
export function useGraphIndex() {
  const shared = useContext(GraphIndexContext)
  const standalone = useGraphLoader(!shared)
  return shared ?? standalone
}
export function useIndexedNoteCount() {
  return useContext(GraphIndexContext)?.progress.done ?? 0;
}
export function GraphIndexStatus() {
  const index = useContext(GraphIndexContext)
  if (!index || (!index.loading && !index.error && !index.graph.failures.length)) return null
  return <span role="status" className="graph-index-status" aria-label={t("graph.backgroundIndexingStatus")} title={index.error || t("graph.linkIndexingContinuesAsYouNavigate")}>
    {index.error ? <>{t("graph.linkIndexingStopped")}{" "}<button onClick={index.retry}>{t("common.tryAgain")}</button></> : !index.loading && index.graph.failures.length ? <>{t("graph.someLinksCouldNotBeIndexed", index.graph.failures.length)}{" "}<button onClick={index.retry}>{t("common.tryAgain")}</button></> : t("graph.indexingLinks", index.progress.done, index.progress.total)}
  </span>
}
