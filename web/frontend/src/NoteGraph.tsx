import { useEffect, useId, useMemo, useRef, useState } from 'react'
import type { CSSProperties } from 'react'
import { request } from './api'

type Node = { id: string; title: string; notebook_id: string }
type Edge = { source: string; target: string }
type Graph = { nodes: Node[]; edges: Edge[]; failures: { id: string; error: string }[] }
export type NoteGraphProps = { onOpenNote: (id: string) => void; focusId?: string }
const empty: Graph = { nodes: [], edges: [], failures: [] }
const button: CSSProperties = { padding: '4px 8px', border: '1px solid var(--line)', borderRadius: 5,
  background: 'var(--toolbar)', color: 'var(--text)', cursor: 'pointer', font: 'inherit' }
const label = (node: Node) => node.title || '제목 없음'

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

export function NoteGraph({ onOpenNote, focusId }: NoteGraphProps) {
  const [graph, setGraph] = useState<Graph>(empty)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)
  const [query, setQuery] = useState('')
  const [selectedId, setSelectedId] = useState<string | undefined>(focusId)
  const [localId, setLocalId] = useState<string | undefined>(focusId)
  const [includeIsolated, setIncludeIsolated] = useState(false)
  const [zoom, setZoom] = useState(1)
  const [pan, setPan] = useState({ x: 0, y: 0 })
  const drag = useRef<{ x: number; y: number } | null>(null)
  const markerId = useId()

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setError('')
    request<Graph>('/api/graph', { signal: controller.signal }).then(data => {
      if (!controller.signal.aborted) setGraph(data)
    }).catch((failure: unknown) => {
      if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : '그래프를 불러오지 못했습니다.')
    }).finally(() => { if (!controller.signal.aborted) setLoading(false) })
    return () => controller.abort()
  }, [attempt])

  useEffect(() => {
    setSelectedId(focusId)
    setLocalId(focusId)
    setZoom(1)
    setPan({ x: 0, y: 0 })
  }, [focusId])

  const index = useMemo(() => {
    const byId = new Map(graph.nodes.map(node => [node.id, node]))
    const adjacency = new Map<string, Set<string>>()
    const incoming = new Map<string, Set<string>>()
    const outgoing = new Map<string, Set<string>>()
    const add = (map: Map<string, Set<string>>, source: string, target: string) => {
      if (!map.has(source)) map.set(source, new Set())
      map.get(source)!.add(target)
    }
    for (const edge of graph.edges) {
      if (!byId.has(edge.source) || !byId.has(edge.target)) continue
      add(adjacency, edge.source, edge.target); add(adjacency, edge.target, edge.source)
      add(incoming, edge.target, edge.source); add(outgoing, edge.source, edge.target)
    }
    return { byId, adjacency, incoming, outgoing }
  }, [graph])

  const visible = useMemo(() => {
    const local = localId ? new Set([localId, ...index.adjacency.get(localId) ?? []]) : null
    const nodes = graph.nodes.filter(node => local ? local.has(node.id) : includeIsolated || index.adjacency.has(node.id))
    const ids = new Set(nodes.map(node => node.id))
    const edges = graph.edges.filter(edge => ids.has(edge.source) && ids.has(edge.target))
    const adjacency = new Map([...index.adjacency].filter(([id]) => ids.has(id))
      .map(([id, neighbors]) => [id, new Set([...neighbors].filter(next => ids.has(next)))]))
    return { nodes, edges, ...layout(nodes, adjacency) }
  }, [graph, index, localId, includeIsolated])

  const matches = useMemo(() => {
    const search = query.trim().toLocaleLowerCase()
    return search ? visible.nodes.filter(node => label(node).toLocaleLowerCase().includes(search)) : []
  }, [query, visible])
  const matchIds = useMemo(() => new Set(matches.map(node => node.id)), [matches])
  const selected = graph.nodes.find(node => node.id === selectedId && visible.points.has(node.id))
  const connections = (map: Map<string, Set<string>>) => [...map.get(selected?.id ?? '') ?? []]
    .map(id => index.byId.get(id)!).sort((a, b) => label(a).localeCompare(label(b)))
  const zoomTo = (value: number) => setZoom(Math.min(3, Math.max(0.25, value)))
  const reset = () => { setZoom(1); setPan({ x: 0, y: 0 }); setQuery('') }
  const focus = () => { if (selected) { setLocalId(selected.id); reset() } }
  const viewWidth = visible.width / zoom
  const viewHeight = visible.height / zoom

  return <section aria-label="노트 그래프" style={{ display: 'flex', flexDirection: 'column', flex: 1,
    minWidth: 0, minHeight: 0, height: '100%', padding: 16, gap: 12, overflow: 'auto',
    boxSizing: 'border-box', background: 'var(--surface)', color: 'var(--text)' }}>
    <header style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
      <strong>{localId ? '로컬 그래프' : '전체 그래프'}</strong>
      <input type="search" aria-label="그래프 노트 검색" placeholder="노트 제목 검색" value={query}
        onChange={event => setQuery(event.target.value)} style={{ flex: '1 1 160px', minWidth: 100,
          color: 'var(--text)', background: 'var(--surface)', border: '1px solid var(--line)', borderRadius: 5, padding: 6 }} />
      {localId ? <button style={button} onClick={() => { setLocalId(undefined); reset() }}>전체 그래프</button> :
        <label style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 12 }}>
          <input type="checkbox" checked={includeIsolated} onChange={e => setIncludeIsolated(e.target.checked)} />연결 없는 노트
        </label>}
      <span style={{ fontSize: 12, color: 'var(--muted)' }}>노트 {visible.nodes.length} · 연결 {visible.edges.length}</span>
    </header>
    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
      <button style={button} aria-label="축소" onClick={() => zoomTo(zoom - 0.25)} disabled={zoom <= 0.25}>−</button>
      <output aria-label="확대 비율" style={{ minWidth: 48, textAlign: 'center', fontSize: 12 }}>{Math.round(zoom * 100)}%</output>
      <button style={button} aria-label="확대" onClick={() => zoomTo(zoom + 0.25)} disabled={zoom >= 3}>+</button>
      <button style={button} onClick={reset}>초기화</button>
    </div>
    {loading ? <p role="status">노트 관계를 불러오는 중…</p> : error ? <div role="alert">
      <p>{error}</p><button style={button} onClick={() => setAttempt(value => value + 1)}>다시 시도</button>
    </div> : <>
      {graph.failures.length > 0 ? <div role="alert" style={{ padding: 8, border: '1px solid var(--line)', borderRadius: 5 }}>
        <strong>일부 노트의 연결을 확인하지 못했습니다 ({graph.failures.length}개)</strong>
        <ul style={{ margin: '6px 0', maxHeight: 120, overflow: 'auto' }}>{graph.failures.map((failure, i) =>
          <li key={`${failure.id}:${i}`}>{index.byId.get(failure.id)?.title || failure.id} ({failure.id}) · {failure.error}</li>)}</ul>
      </div> : null}
      {query.trim() ? <section aria-label="검색 결과" style={{ maxHeight: 120, overflow: 'auto' }}>
        {matches.length ? matches.map(node => <button style={{ ...button, margin: 3 }} key={node.id}
          onClick={() => setSelectedId(node.id)}>{label(node)}</button>) : <span>검색 결과가 없습니다</span>}
      </section> : null}
      {visible.nodes.length === 0 ? <div style={{ padding: 32, textAlign: 'center', color: 'var(--muted)' }}>
        <p>표시할 노트가 없습니다</p><p>연결 없는 노트를 표시하거나 노트 간 링크를 추가해 보세요.</p>
      </div> : <svg role="group" aria-label="노트 관계 그래프" viewBox={`${(visible.width - viewWidth) / 2 + pan.x} ${(visible.height - viewHeight) / 2 + pan.y} ${viewWidth} ${viewHeight}`}
        style={{ width: '100%', flex: '1 0 300px', minHeight: 300, maxHeight: 650, borderRadius: 9,
          border: '1px solid var(--line)', background: 'var(--sidebar)', touchAction: 'none' }}
        onPointerDown={event => {
          if (event.button !== 0 || (event.target as Element).closest('[role="button"]')) return
          drag.current = { x: event.clientX, y: event.clientY }
          event.currentTarget.setPointerCapture(event.pointerId)
        }}
        onPointerMove={event => {
          if (!drag.current) return
          const rect = event.currentTarget.getBoundingClientRect()
          const scale = Math.max(viewWidth / rect.width, viewHeight / rect.height)
          const dx = (event.clientX - drag.current.x) * scale
          const dy = (event.clientY - drag.current.y) * scale
          drag.current = { x: event.clientX, y: event.clientY }
          setPan(previous => ({ x: previous.x - dx, y: previous.y - dy }))
        }} onPointerUp={() => { drag.current = null }} onPointerCancel={() => { drag.current = null }}>
        <defs><marker id={markerId} viewBox="0 0 10 10" refX="20" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--muted)" />
        </marker></defs>
        {visible.edges.map(edge => {
          const from = visible.points.get(edge.source)!, to = visible.points.get(edge.target)!
          const active = selected?.id === edge.source || selected?.id === edge.target
          return <line key={JSON.stringify([edge.source, edge.target])} x1={from.x} y1={from.y} x2={to.x} y2={to.y}
            stroke={active ? 'var(--accent)' : 'var(--muted)'} strokeWidth={active ? 2 : 1} opacity={active ? 0.9 : 0.35}
            markerEnd={`url(#${markerId})`} />
        })}
        {visible.nodes.map(node => {
          const point = visible.points.get(node.id)!
          const active = selected?.id === node.id
          const connected = selected ? index.adjacency.get(selected.id)?.has(node.id) : false
          const dim = query.trim() ? !matchIds.has(node.id) : selected ? !active && !connected : false
          return <g key={node.id} role="button" tabIndex={0} aria-label={label(node)} aria-pressed={active}
            transform={`translate(${point.x} ${point.y})`} style={{ cursor: 'pointer', opacity: dim ? 0.35 : 1 }}
            onClick={() => setSelectedId(node.id)} onDoubleClick={() => onOpenNote(node.id)}
            onKeyDown={event => {
              if (event.key === 'Enter') { event.preventDefault(); setSelectedId(node.id); onOpenNote(node.id) }
              if (event.key === ' ') { event.preventDefault(); setSelectedId(node.id) }
            }}>
            <title>{label(node)}</title>
            <circle r="18" fill="transparent" />
            <circle r={active ? 9 : 6} fill={active || connected || matchIds.has(node.id) ? 'var(--accent)' : 'var(--muted)'}
              stroke={active ? 'var(--text)' : 'var(--surface)'} strokeWidth="1.5" />
            {visible.nodes.length <= 80 || active || matchIds.has(node.id) ? <text y="25" textAnchor="middle"
              fill="var(--text)" style={{ fontSize: 12, pointerEvents: 'none' }}>{label(node).length > 28 ? `${label(node).slice(0, 28)}…` : label(node)}</text> : null}
          </g>
        })}
      </svg>}
      {selected ? <aside aria-label="선택한 노트 연결" style={{ padding: 10, borderTop: '1px solid var(--line)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <strong style={{ flex: 1, overflowWrap: 'anywhere' }}>{label(selected)}</strong>
          <button style={button} onClick={() => onOpenNote(selected.id)}>노트 열기</button>
          <button style={button} onClick={focus}>연결만 보기</button>
        </div>
        <div style={{ display: 'flex', gap: 20, flexWrap: 'wrap', marginTop: 10 }}>
          {([['백링크', connections(index.incoming)], ['나가는 링크', connections(index.outgoing)]] as const).map(([heading, nodes]) =>
            <section aria-label={heading} key={heading} style={{ flex: '1 1 180px', minWidth: 0 }}>
              <h3 style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 6px' }}>{heading} ({nodes.length})</h3>
              {nodes.length ? nodes.map(node => <button key={node.id} style={{ ...button, display: 'block', marginBottom: 4,
                maxWidth: '100%', overflowWrap: 'anywhere', textAlign: 'left' }} onClick={() => onOpenNote(node.id)}>{label(node)}</button>) :
                <span style={{ fontSize: 12, color: 'var(--muted)' }}>연결 없음</span>}
            </section>)}
        </div>
      </aside> : <p style={{ margin: 0, color: 'var(--muted)', fontSize: 12 }}>노드 선택 · 두 번 클릭해 노트 열기 · 드래그로 이동 · +/−로 확대</p>}
    </>}
  </section>
}
