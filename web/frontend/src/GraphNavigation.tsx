import { currentLanguage, formatNumber, t } from "./i18n";
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode, type SetStateAction } from 'react'
import { useGraphIndex, type Graph, type Node } from './GraphIndex'
import './graph.css'

export type GraphNotebook = {id: string; name: string}
export const graphTitle = (node: Node) => node.title || t("제목 없음")
const compare = (a: Node, b: Node) => graphTitle(a).localeCompare(graphTitle(b), currentLanguage(), {numeric: true}) || a.id.localeCompare(b.id)

export type NavigationState = {
  query: string; notebook: string; tag: string; depth: number; selectedId?: string;
  localId?: string; includeIsolated: boolean; zoom: number; pan: {x: number; y: number}
}
export function initialState(focusId?: string): NavigationState {
  return {query:'', notebook:'', tag:'', depth:1, selectedId:focusId, localId:focusId,
    includeIsolated:false, zoom:1, pan:{x:0,y:0}}
}
function useLocalNavigation(focusId?: string) {
  const [state, setState] = useState(() => initialState(focusId))
  useEffect(() => { setState(initialState(focusId)) }, [focusId])
  return useNavigation(state, setState)
}
export type NavigationChange = (action:SetStateAction<NavigationState>, transient?:boolean) => void
function useNavigation(state: NavigationState, setState: NavigationChange) {
  return useMemo(() => ({state, setState,
    update: (patch: Partial<NavigationState>, transient = false) => setState(previous => ({...previous, ...patch}), transient),
    select: (id?: string) => setState(previous => ({...previous, selectedId:id, query:''})),
    focus: (id?: string) => setState(previous => ({...previous, localId:id,
      selectedId:id ?? previous.selectedId, zoom:1, pan:{x:0,y:0}})),
    reset: () => setState(previous => ({...previous, zoom:1, pan:{x:0,y:0}, query:''})),
  }), [state, setState])
}
type Navigation = ReturnType<typeof useLocalNavigation>
const NavigationContext = createContext<Navigation | null>(null)
export function GraphNavigationProvider({children, state, onChange}: {children: ReactNode; state?:NavigationState; onChange?:NavigationChange}) {
  const fallback = useLocalNavigation()
  const navigation = useNavigation(state ?? fallback.state, onChange ?? fallback.setState)
  return <NavigationContext.Provider value={navigation}>{children}</NavigationContext.Provider>
}
export function useGraphNavigation(focusId?: string) {
  const shared = useContext(NavigationContext)
  const local = useLocalNavigation(focusId)
  return {navigation: focusId === undefined && shared ? shared : local, shared: focusId === undefined && !!shared}
}

// Match the Mac UInt64 FNV1a hash and HSV palette, including UTF-8 identifiers.
export function graphNotebookColor(id: string) {
  let hash = 14695981039346656037n
  for (const byte of new TextEncoder().encode(id)) hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * 1099511628211n)
  const hue = Number(hash % 360n) / 60
  const chroma = 0.84 * 0.64, low = 0.84 - chroma
  const x = chroma * (1 - Math.abs(hue % 2 - 1))
  const [r,g,b] = [[chroma,x,0],[x,chroma,0],[0,chroma,x],[0,x,chroma],[x,0,chroma],[chroma,0,x]][Math.floor(hue)]
  return `rgb(${Math.round((r+low)*255)}, ${Math.round((g+low)*255)}, ${Math.round((b+low)*255)})`
}

export function useGraphModel(graph: Graph, loading: boolean, navigation: Navigation) {
  const {state, update} = navigation
  const {notebook, tag, localId, depth, includeIsolated, selectedId, query} = state
  const visible = useMemo(() => {
    const eligible = graph.nodes.filter(n => (!notebook || n.notebook_id === notebook) && (!tag || n.tags?.includes(tag)))
    const byId = new Map(eligible.map(n => [n.id,n]))
    const filteredEdges = graph.edges.filter(e => byId.has(e.source) && byId.has(e.target))
    const adjacency = new Map<string, Set<string>>()
    const add = (from: string, to: string) => {
      if (!adjacency.has(from)) adjacency.set(from,new Set())
      adjacency.get(from)!.add(to)
    }
    for (const edge of filteredEdges) { add(edge.source,edge.target); add(edge.target,edge.source) }
    // A filter excluding the focus returns to the full filtered graph.
    const focus = localId && byId.has(localId) ? localId : undefined
    const neighborhood = focus ? new Set([focus]) : null
    if (neighborhood) {
      let frontier = [focus!]
      for (let level=0; level<depth && frontier.length; level++) {
        const next: string[] = []
        for (const id of frontier) for (const neighbor of adjacency.get(id) ?? []) {
          if (!neighborhood.has(neighbor)) { neighborhood.add(neighbor); next.push(neighbor) }
        }
        frontier = next
      }
    }
    const nodes = eligible.filter(n => neighborhood ? neighborhood.has(n.id) : includeIsolated || loading || adjacency.has(n.id))
    const ids = new Set(nodes.map(n => n.id))
    const edges = filteredEdges.filter(e => ids.has(e.source) && ids.has(e.target))
    const degree = new Map<string,number>(), incoming = new Map<string,Set<string>>(), outgoing = new Map<string,Set<string>>()
    for (const edge of edges) {
      degree.set(edge.source,(degree.get(edge.source) ?? 0)+1)
      degree.set(edge.target,(degree.get(edge.target) ?? 0)+1)
      if (!outgoing.has(edge.source)) outgoing.set(edge.source,new Set())
      if (!incoming.has(edge.target)) incoming.set(edge.target,new Set())
      outgoing.get(edge.source)!.add(edge.target); incoming.get(edge.target)!.add(edge.source)
    }
    const visibleAdjacency = new Map<string,Set<string>>()
    for (const n of nodes) visibleAdjacency.set(n.id,new Set([...adjacency.get(n.id) ?? []].filter(id => ids.has(id))))
    return {nodes,edges,byId,degree,incoming,outgoing,adjacency:visibleAdjacency,focus,
      hiddenCount: !focus && !includeIsolated ? eligible.length-nodes.length : 0}
  }, [graph,notebook,tag,localId,depth,includeIsolated,loading])
  const selected = visible.nodes.find(n => n.id === selectedId)
  const matches = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase()
    return needle ? visible.nodes.filter(n => graphTitle(n).toLocaleLowerCase().includes(needle)).sort(compare) : []
  }, [visible.nodes,query])
  useEffect(() => {
    if (loading) return
    if (selectedId && !visible.byId.has(selectedId)) update({selectedId:undefined}, true)
    else if (selectedId && !selected) update({selectedId:undefined}, true)
    if (localId && !visible.focus) update({localId:undefined,zoom:1,pan:{x:0,y:0}}, true)
  }, [loading,selectedId,selected,localId,visible.byId,visible.focus,update])
  const connections = (direction: 'incoming' | 'outgoing') => [...visible[direction].get(selected?.id ?? '') ?? []]
    .map(id => visible.byId.get(id)!).sort(compare)
  return {visible,selected,matches,connections}
}

export function GraphNavigationContent({notebooks = [], onOpenNote, navigation, model}: {
  notebooks?: GraphNotebook[]; onOpenNote: (id:string) => void; navigation: Navigation;
  model: ReturnType<typeof useGraphModel>
}) {
  const {visible, selected, matches, connections} = model
  const {state,select,focus} = navigation
  const books = new Map(notebooks.map(b => [b.id,b.name]))
  const counts = useMemo(() => {
    const counts = new Map<string,number>()
    for (const n of visible.nodes) counts.set(n.notebook_id,(counts.get(n.notebook_id) ?? 0)+1)
    return counts
  }, [visible.nodes])
  const ranked = useMemo(() => [...visible.nodes].sort((a,b) =>
    (visible.degree.get(b.id) ?? 0)-(visible.degree.get(a.id) ?? 0) || compare(a,b)).slice(0,16), [visible])
  const row = (node: Node, ranked = false) => <button className="graph-note-row" key={node.id}
    aria-label={graphTitle(node)} aria-pressed={state.selectedId === node.id}
    onClick={() => select(node.id)} onDoubleClick={() => onOpenNote(node.id)}>
    <span className="graph-swatch" style={{background:graphNotebookColor(node.notebook_id)}} aria-hidden="true" />
    <span>{graphTitle(node)}</span>{ranked && <small aria-label={t("연결 수")}>{formatNumber(visible.degree.get(node.id) ?? 0)}</small>}
  </button>
  return <>
    <header><h2>{t("노트 연결 지도")}</h2><p className="graph-muted">{t("노트 {0}개 · 연결 {1}개", visible.nodes.length, visible.edges.length)}</p></header>
    {state.query.trim() ? <section aria-label={t("검색 결과")}>
      <h3>{t("검색 결과 · {0}개", matches.length)}</h3>
      {matches.slice(0,100).map(n => row(n))}
      {!matches.length && <p className="graph-muted">{t("검색 결과가 없습니다")}</p>}
      {matches.length > 100 && <p className="graph-muted">{t("처음 100개 표시")}</p>}
    </section> : selected ? <>
      <section aria-label={t("선택한 노트 연결")}>
        <h3>{graphTitle(selected)}</h3><p className="graph-muted">{books.get(selected.notebook_id) ?? selected.notebook_id}</p>
        {!!selected.tags?.length && <p className="graph-muted">{selected.tags.map(t => `#${t}`).join(' ')}</p>}
        <div className="graph-actions"><button onClick={() => onOpenNote(selected.id)}>{t("노트 열기")}</button>
          <button onClick={() => focus(selected.id)}>{t("주변만 보기")}</button></div>
      </section>
      {(['outgoing','incoming'] as const).map(direction => {
        const nodes = connections(direction)
        return <section key={direction} aria-label={direction === 'outgoing' ? t("나가는 링크") : t("백링크")}>
          <h3 className={`graph-${direction}`}>{direction === 'outgoing' ? t("나가는 연결 → · {0}개", nodes.length) : t("← 들어오는 연결 · {0}개", nodes.length)}</h3>
          {nodes.length ? nodes.map(n => row(n)) : <p className="graph-muted">{t("연결 없음")}</p>}
        </section>
      })}
    </> : <section aria-label={t("주요 노트")}><h3>{t("주요 노트")}</h3><p className="graph-muted">{t("연결 수가 많은 순서")}</p>
      {ranked.map(n => row(n,true))}
      {!ranked.length && <p className="graph-muted">{t("표시할 노트가 없습니다")}</p>}
    </section>}
    <section aria-label={t("메모장 색상")}><h3>{t("메모장 색상")}</h3>
      {[...counts].map(([id,count]) => <div className="graph-legend-row" key={id}>
        <span className="graph-swatch" style={{background:graphNotebookColor(id)}} aria-hidden="true" />
        <span>{books.get(id) ?? id}</span><small>{formatNumber(count)}</small>
      </div>)}
    </section>
  </>
}
export function GraphNavigationPanel({notebooks = [], onOpenNote}: {notebooks?: GraphNotebook[]; onOpenNote: (id:string) => void}) {
  const {graph,loading} = useGraphIndex()
  const {navigation} = useGraphNavigation()
  const model = useGraphModel(graph,loading,navigation)
  return <nav aria-label={t("그래프 탐색")} className="graph-navigation"><GraphNavigationContent
    notebooks={notebooks} onOpenNote={onOpenNote} navigation={navigation} model={model} /></nav>
}
