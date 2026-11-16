import {afterEach,expect,it,vi} from 'vitest'
import {requestId} from './ids'
afterEach(()=>vi.unstubAllGlobals())
it('creates a UUIDv4 on HTTP origins where randomUUID is unavailable',()=>{
  vi.stubGlobal('crypto',{getRandomValues:(bytes:Uint8Array)=>{bytes.fill(255);return bytes}})
  expect(requestId()).toBe('ffffffff-ffff-4fff-bfff-ffffffffffff')
})
