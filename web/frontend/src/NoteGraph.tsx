import { useId, useMemo, useRef, useState } from 'react'
import { useGraphIndex, type Node } from './GraphIndex'
import { useGraphNavigation, useGraphModel, graphNotebookColor, graphTitle as label, GraphNavigationContent } from './GraphNavigation'
import './graph.css'
export { mergeGraph } from './GraphIndex'

export type NoteGraphProps = { onOpenNote: (id: string) => void; focusId?: string; notebooks?: {id: string; name: string}[]; compact?: boolean }

// Linear-time component discovery with deterministic clusters, rather than an
// unbounded force simulation on the UI thread. Fit every component in the SVG.
function layout(nodes: Node[], adjacency: Map<string, Set<string>>) {
  const seen = new Set<string>()
  const components: string[][] = []
  for (const node of nodes) {
    if (seen.has(node.id)) continue
    const component = [node.id]
    seen.add(node.id)
    for (let cursor = 0; cursor < component.length; cursor++) {
      for (const next of adjacency.get(component[cursor]) ?? []) {
        if (!seen.has(next)) { seen.add(next); component.push(next) }
      }
    }
    components.push(component)
  }
  const columns = Math.max(1, Math.ceil(Math.sqrt(components.length)))
  const cell = components.reduce((size, component) => Math.max(size, Math.sqrt(component.length) * 85 + 120), 320)
  const width = columns * cell
  const height = Math.max(cell, Math.ceil(components.length / columns) * cell)
  const points = new Map<string, { x: number; y: number }>()
  components.forEach((component, index) => {
    const cx = (index % columns + 0.5) * cell
    const cy = (Math.floor(index / columns) + 0.5) * cell
    component.forEach((id, i) => {
      // Small clusters stay circular. Large clusters fill a golden-angle
      // spiral, keeping the 36-unit hit targets apart as the library grows.
      const angle = component.length <= 12 ? i * Math.PI * 2 / component.length - Math.PI / 2 : i * Math.PI * (3 - Math.sqrt(5))
      const radius = component.length <= 12 ? (component.length > 1 ? cell * 0.33 : 0) : Math.sqrt(i) * 40
      points.set(id, { x: cx + Math.cos(angle) * radius, y: cy + Math.sin(angle) * radius })
    })
  })
  return { points, width, height }
}

export function NoteGraph({ onOpenNote, focusId, notebooks = [], compact = false }: NoteGraphProps) {
  const {graph,loading,error,progress,retry} = useGraphIndex()
  const {navigation,shared} = useGraphNavigation(focusId)
  const {state,update,select,focus,reset,setState} = navigation
  const {query,notebook,tag,depth,selectedId,includeIsolated,zoom,pan} = state
  const model = useGraphModel(graph,loading,navigation)
  const {visible,selected,matches,connections} = model
  const positions = useMemo(() => layout(visible.nodes,visible.adjacency), [visible.nodes,visible.adjacency])
  const matchIds = useMemo(() => new Set(matches.map(n => n.id)), [matches])
  const colors = useMemo(() => new Map([...new Set(graph.nodes.map(n => n.notebook_id))]
    .map(id => [id,graphNotebookColor(id)])), [graph.nodes])
  const notebookNames = new Map(notebooks.map(n => [n.id,n.name]))
  const allNodes = useMemo(() => new Map(graph.nodes.map(n => [n.id,n])), [graph.nodes])
  const rankedLabels = useMemo(() => [...visible.nodes].sort((a,b) =>
    (visible.degree.get(b.id) ?? 0)-(visible.degree.get(a.id) ?? 0) || a.id.localeCompare(b.id))
    .slice(0,visible.nodes.length <= 40 ? 40 : 12), [visible.nodes,visible.degree])
  const [hoverId,setHoverId] = useState<string>()
  const drag = useRef<{x:number;y:number;moved:boolean} | null>(null)
  const dragged = useRef(false)
  const markerId = useId()
  const zoomTo = (value: number) => update({zoom:Math.min(3,Math.max(0.25,value))})
  const viewWidth = positions.width / zoom, viewHeight = positions.height / zoom
  // Fixed spatial buckets bound label collision checks. Highlighted labels get
  // priority; large libraries show only a small ranked set at rest.
  const labels = useMemo(() => {
    const candidates = new Map<string,Node>()
    for (const id of [hoverId,selectedId,...matches.slice(0,20).map(n => n.id)]) {
      const n = visible.byId.get(id ?? ''); if (n && positions.points.has(n.id)) candidates.set(n.id,n)
    }
    for (const n of rankedLabels) candidates.set(n.id,n)
    const occupied = new Set<string>(), result = new Set<string>()
    for (const n of candidates.values()) {
      const p = positions.points.get(n.id)!
      const half = Math.min(label(n).length,24)*3.5+6
      const left = Math.floor((p.x-half)/30), right = Math.floor((p.x+half)/30)
      const top = Math.floor((p.y+19)/18), bottom = Math.floor((p.y+35)/18)
      const cells: string[] = []
      for (let x=left; x<=right; x++) for (let y=top; y<=bottom; y++) cells.push(`${x}:${y}`)
      if (cells.some(c => occupied.has(c))) continue
      cells.forEach(c => occupied.add(c)); result.add(n.id)
    }
    return result
  }, [visible,positions,hoverId,selectedId,matches,rankedLabels])
  const radius = (id: string) => Math.min(14,5+Math.sqrt(visible.degree.get(id) ?? 0)*1.8)
  const fullDetails = !shared && !compact

  return <section aria-label="노트 그래프" className={`note-graph${compact ? ' note-graph-compact' : ''}`}>
    {!compact && <div className="graph-filters">
      <input type="search" aria-label="그래프 노트 검색" placeholder="노트 제목 검색" value={query}
        onChange={e => update({query:e.target.value})} />
      <select aria-label="그래프 메모장 필터" value={notebook} onChange={e => update({notebook:e.target.value})}>
        <option value="">모든 메모장</option>
        {[...new Set([...notebooks.map(n => n.id),...graph.nodes.map(n => n.notebook_id)])].map(id =>
          <option key={id} value={id}>{notebookNames.get(id) ?? id}</option>)}
      </select>
      <select aria-label="그래프 태그 필터" value={tag} onChange={e => update({tag:e.target.value})}>
        <option value="">모든 태그</option>
        {[...new Set(graph.nodes.flatMap(n => n.tags ?? []))].sort().map(t => <option key={t} value={t}>#{t}</option>)}
      </select>
    </div>}
    <header className="graph-summary">
      <strong>{visible.focus ? '로컬 그래프' : '전체 그래프'}</strong>
      {visible.focus && <>
        <select aria-label="연결 깊이" value={depth} onChange={e => update({depth:Number(e.target.value)})}>
          {[1,2,3].map(n => <option key={n} value={n}>{n}단계</option>)}
        </select>
        {!compact && <button onClick={() => focus()}>전체 그래프</button>}
      </>}
      {!compact && !visible.focus && <label className="graph-isolates"><input type="checkbox" checked={includeIsolated}
        onChange={e => update({includeIsolated:e.target.checked})} />연결 없는 노트</label>}
      <span className="graph-muted">노트 {visible.nodes.length} · 연결 {visible.edges.length}</span>
      {visible.hiddenCount > 0 && <small className="graph-muted">(미연결 {visible.hiddenCount}개 숨김)</small>}
    </header>
    {loading && <div role="status" aria-label="그래프 인덱싱 상태" className="graph-muted">
      {progress.total ? `노트 링크 인덱싱 중… ${progress.done}/${progress.total}` : '노트 관계를 불러오는 중…'}
      {progress.total > 0 && <progress aria-label="그래프 조회 진행률" max={progress.total} value={progress.done} />}
    </div>}
    {error && <div role="alert" className="graph-warning"><p>{error}</p><button onClick={retry}>다시 시도</button></div>}
    {graph.failures.length > 0 && <div role="alert" className="graph-warning">
      <strong>일부 노트의 연결을 확인하지 못했습니다 ({graph.failures.length}개)</strong>
      <details><summary>연결 확인 실패 내역</summary><ul>{graph.failures.map((failure,i) =>
        <li key={`${failure.id}:${i}`}>{allNodes.get(failure.id)?.title || failure.id} ({failure.id}) · {failure.error}</li>)}</ul></details>
      <button onClick={retry}>다시 시도</button>
    </div>}
    {(!loading || graph.nodes.length > 0) && <>
      <div className="graph-stage">
        {visible.nodes.length === 0 ? <div className="graph-empty"><p>표시할 노트가 없습니다</p>
          <p>필터를 변경하거나 노트 간 링크를 추가해 보세요.</p>
          {!includeIsolated && !visible.focus && graph.nodes.length > 0 && <button onClick={() => update({includeIsolated:true})}>
            연결 없는 노트 보기 ({visible.hiddenCount}개)</button>}
        </div> : <svg role="group" aria-label="노트 관계 그래프"
          viewBox={`${(positions.width-viewWidth)/2+pan.x} ${(positions.height-viewHeight)/2+pan.y} ${viewWidth} ${viewHeight}`}
          onClick={event => {
            if (!(event.target as Element).closest('[role="button"]') && !dragged.current) select()
            dragged.current = false
          }}
          onPointerDown={event => {
            if (event.button !== 0 || (event.target as Element).closest('[role="button"]')) return
            drag.current = {x:event.clientX,y:event.clientY,moved:false}; dragged.current = false
            event.currentTarget.setPointerCapture?.(event.pointerId)
          }}
          onPointerMove={event => {
            if (!drag.current) return
            const rect = event.currentTarget.getBoundingClientRect()
            if (!rect.width || !rect.height) return
            const scale = Math.max(viewWidth/rect.width,viewHeight/rect.height)
            const dx = event.clientX-drag.current.x, dy = event.clientY-drag.current.y
            if (!drag.current.moved && Math.hypot(dx,dy)<3) return
            drag.current = {x:event.clientX,y:event.clientY,moved:true}
            setState(previous => ({...previous,pan:{x:previous.pan.x-dx*scale,y:previous.pan.y-dy*scale}}))
          }}
          onPointerUp={() => { dragged.current = !!drag.current?.moved; drag.current = null }}
          onPointerCancel={() => { drag.current = null; dragged.current = false }}
          onLostPointerCapture={() => { if (drag.current) dragged.current = drag.current.moved; drag.current = null }}>
          <defs>{(['normal','outgoing','incoming'] as const).map(direction => <marker key={direction}
            id={`${markerId}-${direction}`} viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto">
            <path d="M 0 0 L 10 5 L 0 10 z" fill={direction === 'normal' ? 'var(--muted)' : `var(--graph-${direction})`} />
          </marker>)}</defs>
          {visible.edges.map(edge => {
            const from = positions.points.get(edge.source)!, to = positions.points.get(edge.target)!
            const direction = selected?.id === edge.source ? 'outgoing' : selected?.id === edge.target ? 'incoming' : 'normal'
            const active = direction !== 'normal'
            const distance = Math.hypot(to.x-from.x,to.y-from.y) || 1
            const offset = radius(edge.target)+4
            return <line key={JSON.stringify([edge.source,edge.target])} data-direction={direction}
              x1={from.x} y1={from.y} x2={to.x-(to.x-from.x)/distance*offset} y2={to.y-(to.y-from.y)/distance*offset}
              stroke={active ? `var(--graph-${direction})` : 'var(--muted)'} strokeWidth={active ? 2.2 : 1}
              opacity={active ? 0.95 : selected ? 0.12 : 0.25} markerEnd={`url(#${markerId}-${direction})`} />
          })}
          {visible.nodes.map(node => {
            const point = positions.points.get(node.id)!
            const active = selected?.id === node.id
            const connected = selected ? visible.adjacency.get(selected.id)?.has(node.id) : false
            const dim = query.trim() ? !matchIds.has(node.id) : selected ? !active && !connected : false
            const direction = selected && visible.outgoing.get(selected.id)?.has(node.id) ? 'outgoing'
              : selected && visible.incoming.get(selected.id)?.has(node.id) ? 'incoming' : undefined
            return <g key={node.id} role="button" tabIndex={0} aria-label={label(node)} aria-pressed={active}
              className="graph-node" transform={`translate(${point.x} ${point.y})`} opacity={dim ? 0.3 : 1}
              onClick={() => select(node.id)} onDoubleClick={() => onOpenNote(node.id)}
              onMouseEnter={() => setHoverId(node.id)} onMouseLeave={() => setHoverId(undefined)}
              onFocus={() => setHoverId(node.id)} onBlur={() => setHoverId(undefined)}
              onKeyDown={event => {
                if (event.key === 'Enter') { event.preventDefault(); select(node.id); onOpenNote(node.id) }
                if (event.key === ' ') { event.preventDefault(); select(node.id) }
                if (event.key === 'Escape') { event.preventDefault(); select() }
              }}>
              <title>{label(node)}</title><circle r="18" fill="transparent" />
              <circle r={radius(node.id)} fill={colors.get(node.notebook_id)}
                stroke={active ? 'var(--text)' : direction ? `var(--graph-${direction})` : matchIds.has(node.id) ? 'var(--accent)' : 'var(--surface)'}
                strokeWidth={active || direction || matchIds.has(node.id) ? 3 : 1.5} />
              {labels.has(node.id) && <text y="29" textAnchor="middle" className="graph-node-label">
                {label(node).length > 24 ? `${label(node).slice(0,24)}…` : label(node)}</text>}
            </g>
          })}
        </svg>}
        <div className="graph-zoom" role="group" aria-label="그래프 확대 도구">
          <button aria-label="축소" onClick={() => zoomTo(zoom-0.25)} disabled={zoom <= 0.25}>−</button>
          <output aria-label="확대 비율">{Math.round(zoom*100)}%</output>
          <button aria-label="확대" onClick={() => zoomTo(zoom+0.25)} disabled={zoom >= 3}>+</button>
          <button onClick={reset}>초기화</button>
        </div>
      </div>
      {selected ? <div className="graph-selection"><strong>{label(selected)}</strong>
        <button onClick={() => onOpenNote(selected.id)}>노트 열기</button>
        {!compact && <button onClick={() => focus(selected.id)}>연결만 보기</button>}
      </div> : !compact && <p className="graph-hint">노드 선택 · 두 번 클릭해 노트 열기 · 드래그로 이동 · +/−로 확대</p>}
      {fullDetails && <div className="graph-standalone-details">
        {query.trim() ? <section aria-label="검색 결과">{matches.length ? matches.slice(0,100).map(node =>
          <button key={node.id} onClick={() => select(node.id)}>{label(node)}</button>) : <p>검색 결과가 없습니다</p>}</section>
          : selected && <div className="graph-connections">{(['incoming','outgoing'] as const).map(direction => <section
            key={direction} aria-label={direction === 'incoming' ? '백링크' : '나가는 링크'}>
            <h3 className={`graph-${direction}`}>{direction === 'incoming' ? '백링크' : '나가는 링크'} ({connections(direction).length})</h3>
            {connections(direction).map(node => <button key={node.id} onClick={() => onOpenNote(node.id)}>{label(node)}</button>)}
          </section>)}</div>}
      </div>}
      {shared && !compact && <details className="graph-mobile-navigation"><summary>그래프 탐색</summary>
        <GraphNavigationContent notebooks={notebooks} onOpenNote={onOpenNote} navigation={navigation} model={model} />
      </details>}
    </>}
  </section>
}
