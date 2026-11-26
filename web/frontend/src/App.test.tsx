// @vitest-environment jsdom
import {afterEach, expect, it, vi} from 'vitest'
import {cleanup, fireEvent, render, screen} from '@testing-library/react'
import App from './App'
import { setLanguage } from './i18n'
afterEach(()=>{cleanup();vi.unstubAllGlobals();setLanguage('ko')})

it('shows the first-run form, setup instructions, and HTTP warning in English', async () => {
 setLanguage('en')
 vi.stubGlobal('fetch', vi.fn(async () => Response.json({configured: false, nas_url: null, source: 'setup', read_only: false})))
 const {container} = render(<App />)
 expect(await screen.findByRole('heading', {name: 'Initial NAS setup'})).toBeTruthy()
 fireEvent.change(screen.getByLabelText('NAS address (HTTPS / HTTP)'), {target: {value: 'http://nas.example'}})
 expect(screen.getByLabelText('Setup code')).toBeTruthy()
 expect(screen.getByText('Where can I find the setup code?')).toBeTruthy()
 expect(screen.getByRole('alert').textContent).toContain('The HTTP connection is not encrypted.')
 expect(container.textContent).not.toMatch(/[가-힣]/)
})
it('does not enter the workspace when the browser fails to retain the login cookie', async()=>{
 const paths:string[]=[]
 vi.stubGlobal('fetch',vi.fn(async(path:string)=>{
  paths.push(path)
  const body=path==='/api/status'?{configured:true,nas_url:'https://nas.example',source:'database',read_only:false}:path==='/api/auth/login'?{username:'alice',remember:false,csrf_token:'csrf'}:{detail:'LOGIN_REQUIRED'}
  return new Response(JSON.stringify(body),{status:['/api/status','/api/auth/login'].includes(path)?200:401})
 }))
 render(<App/>);await screen.findByLabelText('사용자 이름');fireEvent.change(screen.getByLabelText('사용자 이름'),{target:{value:'alice'}});fireEvent.change(screen.getByLabelText('비밀번호'),{target:{value:'test'}});fireEvent.click(screen.getByRole('button',{name:'로그인'}))
 expect((await screen.findByRole('alert')).textContent).toContain('로그인 쿠키')
 expect(paths).not.toContain('/api/notebooks');expect(paths).not.toContain('/api/notes')
})

it('shows the English OTP field when the NAS requires it', async () => {
 setLanguage('en')
 vi.stubGlobal('fetch', vi.fn(async (path: string) => {
  if (path === '/api/status') return Response.json({configured: true, nas_url: 'https://nas.example', source: 'database', read_only: false})
  if (path === '/api/auth/login') return Response.json({error: 'OTP_REQUIRED'}, {status: 401})
  return Response.json({detail: 'LOGIN_REQUIRED'}, {status: 401})
 }))
 render(<App />)
 fireEvent.change(await screen.findByLabelText('Username'), {target: {value: 'alice'}})
 fireEvent.change(screen.getByLabelText('Password'), {target: {value: 'test'}})
 fireEvent.click(screen.getByRole('button', {name: 'Sign in'}))
 expect(await screen.findByLabelText('Two-factor authentication code')).toBeTruthy()
 expect(screen.getByRole('alert').textContent).toContain('Enter the NAS two-factor authentication code.')
})

it('returns to login when a protected NAS request requires relogin', async()=>{
 vi.stubGlobal('fetch',vi.fn(async(path:string)=>{
  const body=path==='/api/status'?{configured:true,nas_url:'https://nas.example',source:'database',read_only:false}:path==='/api/auth/me'?{username:'alice',remember:true,csrf_token:'csrf'}:path==='/api/notebooks'?{detail:'RELOGIN_REQUIRED'}:path==='/api/notes'?{notes:[]}:path==='/api/graph?summary=true'?{nodes:[],edges:[],failures:[],entries:[],pending:[]}:{operations:[]}
  return new Response(JSON.stringify(body),{status:path==='/api/notebooks'?401:200})
 }))
 render(<App/>);
 await screen.findByRole('heading',{name:'NAS 계정 로그인'});
 expect(screen.getByRole('img', {name: 'NAS 연결 안 됨'})).toBeTruthy();
 expect((await screen.findByRole('alert')).textContent).toContain('다시 로그인');
 expect(screen.queryByRole('complementary',{name:'책장 및 메모장'})).toBeNull();
})

it('logs out when a graph request fails authentication inside its own error handler', async()=>{
 window.history.replaceState({},'', '/');
 vi.stubGlobal('fetch',vi.fn(async(path:string)=>{
  const body=path==='/api/status'?{configured:true,nas_url:'https://nas.example',source:'database',read_only:false}:path==='/api/auth/me'?{username:'alice',remember:true,csrf_token:'csrf'}:path.startsWith('/api/graph')?{detail:'RELOGIN_REQUIRED'}:path==='/api/notebooks'?{notebooks:[]}:path==='/api/notes'?{notes:[]}:path==='/api/graph?summary=true'?{nodes:[],edges:[],failures:[],entries:[],pending:[]}:{operations:[]}
  return new Response(JSON.stringify(body),{status:path.startsWith('/api/graph')?401:200})
 }))
 render(<App/>);
 fireEvent.click(await screen.findByRole('button',{name:'전체 그래프'}));
 await screen.findByRole('heading',{name:'NAS 계정 로그인'});
 expect((await screen.findByRole('alert')).textContent).toContain('다시 로그인');
})

it('treats an already-expired logout as complete and clears explicitly discarded drafts', async()=>{
 window.history.replaceState({},'', '/');
 const key='synonote:web-draft:["https://nas.example","alice"]:note:note1';
 sessionStorage.setItem(key,'draft');
 vi.stubGlobal('fetch',vi.fn(async(path:string)=>{
  const body=path==='/api/status'?{configured:true,nas_url:'https://nas.example',source:'database',read_only:false}:path==='/api/auth/me'?{username:'alice',remember:true,csrf_token:'csrf'}:path==='/api/auth/logout'?{detail:'RELOGIN_REQUIRED'}:path==='/api/notebooks'?{notebooks:[]}:path==='/api/notes'?{notes:[]}:path==='/api/graph?summary=true'?{nodes:[],edges:[],failures:[],entries:[],pending:[]}:{operations:[]}
  return new Response(JSON.stringify(body),{status:path==='/api/auth/logout'?401:200})
 }))
 render(<App/>);
 fireEvent.click(await screen.findByRole('button',{name:'로그아웃'}));
 await screen.findByRole('heading',{name:'NAS 계정 로그인'});
 expect(sessionStorage.getItem(key)).toBeNull();
})
