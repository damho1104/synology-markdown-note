import {afterEach,expect,it,vi} from 'vitest'
import {backgroundRead, request} from './api'
afterEach(()=>vi.unstubAllGlobals())
it('settles one shared cookie refresh before concurrent protected reads',async()=>{
 let refreshed=false;let checks=0
 vi.stubGlobal('fetch',vi.fn(async(path:string)=>{
  if(path==='/api/auth/me'){checks++;await Promise.resolve();refreshed=true;return new Response(JSON.stringify({username:'test',csrf_token:'test',remember:true}))}
  return new Response(JSON.stringify(refreshed?{ok:true}:{detail:'LOGIN_REQUIRED'}),{status:refreshed?200:401})
 }))
 const results=await Promise.all([request('/api/notes'),request('/api/notebooks')])
 expect(results).toEqual([{ok:true},{ok:true}]);expect(checks).toBe(1)
})

it('retries a passive read with the current cookie after a stale session response', async () => {
  const fetcher = vi.fn()
    .mockResolvedValueOnce(Response.json({detail: 'LOGIN_REQUIRED'}, {status: 401}))
    .mockResolvedValueOnce(Response.json({notes: []}))
  vi.stubGlobal('fetch', fetcher)
  await expect(backgroundRead('/api/notes', new AbortController().signal)).resolves.toEqual({notes: []})
  expect(fetcher.mock.calls.map(([path]) => path)).toEqual(['/api/notes', '/api/notes'])
})
