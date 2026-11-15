// @vitest-environment jsdom
import {afterEach, expect, it, vi} from 'vitest'
import {cleanup, fireEvent, render, screen} from '@testing-library/react'
import App from './App'
afterEach(()=>{cleanup();vi.unstubAllGlobals()})
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
