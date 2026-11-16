// @vitest-environment jsdom
import {beforeEach, afterEach, expect, it, vi} from 'vitest'
import {render, screen, waitFor, cleanup, fireEvent, act} from '@testing-library/react'
import {GraphIndexProvider, GraphIndexStatus, useGraphIndex} from './GraphIndex'
const nodes = Array.from({length:10}, (_,i) => ({id:String(i),title:`Note ${i}`,notebook_id:'b',version:'1'}))
const reply = (data:unknown) => new Response(JSON.stringify(data))
let batches: {ids:string[]; signal:AbortSignal; finish:(value:Response)=>void}[]
beforeEach(() => {
  batches=[]
  vi.stubGlobal('fetch',vi.fn(async (url:string,init:RequestInit) => {
    if (url === '/api/auth/me') return reply({username:'test'})
    if (url === '/api/graph?summary=true') return reply({nodes,edges:[],failures:[],entries:[],pending:nodes.map(n=>n.id)})
    if (url.startsWith('/api/graph/entries')) return new Promise<Response>(finish => batches.push({ids:JSON.parse(new URL(url,'http://localhost').searchParams.get('ids')!),signal:init.signal as AbortSignal,finish}))
    throw new Error(url)
  }))
})
afterEach(() => {cleanup();vi.unstubAllGlobals()})
function Consumer() {const {graph}=useGraphIndex();return <div data-testid="nodes">{graph.nodes.length}</div>}
async function finish(index:number) {await act(async () => batches[index].finish(reply({entries:batches[index].ids.map(id=>({id,links:[]}))}))) }
it('starts without a graph page and continues after graph consumers unmount without duplicate requests',async () => {
  const {rerender,unmount}=render(<GraphIndexProvider><GraphIndexStatus /></GraphIndexProvider>)
  await waitFor(()=>expect(batches).toHaveLength(1))
  expect(screen.getByRole('status').textContent).toContain('0/10')
  rerender(<GraphIndexProvider><GraphIndexStatus /><Consumer /><Consumer /></GraphIndexProvider>)
  expect(screen.getAllByTestId('nodes')).toHaveLength(2)
  expect(batches).toHaveLength(1)
  rerender(<GraphIndexProvider><GraphIndexStatus /></GraphIndexProvider>)
  expect(batches[0].signal.aborted).toBe(false)
  await finish(0)
  await waitFor(()=>expect(batches).toHaveLength(2))
  expect(batches[1].ids).toEqual(['8','9'])
  expect(screen.getByRole('status').textContent).toContain('8/10')
  unmount()
  expect(batches[1].signal.aborted).toBe(true)
})
it('queues a version refresh until the current scan finishes rather than aborting it',async () => {
  const {rerender}=render(<GraphIndexProvider revision="v1"><Consumer /></GraphIndexProvider>)
  await waitFor(()=>expect(batches).toHaveLength(1))
  rerender(<GraphIndexProvider revision="v2"><Consumer /></GraphIndexProvider>)
  expect(batches[0].signal.aborted).toBe(false)
  expect(batches).toHaveLength(1)
  await finish(0);await waitFor(()=>expect(batches).toHaveLength(2));await finish(1)
  await waitFor(()=>expect(batches).toHaveLength(3))
  expect(vi.mocked(fetch).mock.calls.filter(([url])=>url === '/api/graph?summary=true')).toHaveLength(2)
})
it('shows a background error and only retries when requested',async () => {
  vi.stubGlobal('fetch',vi.fn(async (url:string)=> url === '/api/auth/me' ? reply({username:'test'}) : new Response(JSON.stringify({error:'NAS_UNAVAILABLE'}),{status:502})))
  render(<GraphIndexProvider><GraphIndexStatus /></GraphIndexProvider>)
  await screen.findByText('링크 인덱싱 중단')
  expect(vi.mocked(fetch)).toHaveBeenCalledTimes(2)
  fireEvent.click(screen.getByRole('button',{name:'다시 시도'}))
  await waitFor(()=>expect(vi.mocked(fetch)).toHaveBeenCalledTimes(4))
})

it('waits for the library and starts one scan when its first version arrives',async () => {
  const {rerender}=render(<GraphIndexProvider enabled={false} revision="[]"><GraphIndexStatus /></GraphIndexProvider>)
  expect(vi.mocked(fetch)).not.toHaveBeenCalled()
  rerender(<GraphIndexProvider enabled revision="first"><GraphIndexStatus /></GraphIndexProvider>)
  await waitFor(()=>expect(batches).toHaveLength(1))
  expect(vi.mocked(fetch).mock.calls.filter(([url])=>url === '/api/graph?summary=true')).toHaveLength(1)
  expect(batches[0].signal.aborted).toBe(false)
})

it('isolates a malformed index response from the rest of the workspace',async () => {
  vi.stubGlobal('fetch',vi.fn(async () => reply({unexpected:true})))
  render(<GraphIndexProvider><GraphIndexStatus /><div>편집 중인 노트</div></GraphIndexProvider>)
  await screen.findByText('링크 인덱싱 중단')
  expect(screen.getByText('편집 중인 노트')).toBeTruthy()
})
