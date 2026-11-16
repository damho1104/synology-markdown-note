import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { AlertTriangle, ArrowRight, BookOpenText, KeyRound, RefreshCw, ServerCog } from 'lucide-react'
import { Button } from './components/ui/button'
import { ApiFailure, request, jsonRequest, type Session, type Status, SESSION_EXPIRED_EVENT } from './api'
import { Workspace } from './Workspace'

function InsecureNasWarning() {
  return (
    <div className="flex items-start gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-950" role="alert">
      <AlertTriangle className="mt-0.5 shrink-0 text-amber-700" size={19} aria-hidden="true" />
      <p><strong>HTTP 연결은 암호화되지 않습니다.</strong> 웹 서버와 NAS 사이에서 계정 정보·비밀번호·OTP 및 전송 데이터가 노출될 수 있습니다. 신뢰할 수 있는 내부망에서만 사용하고 가능하면 HTTPS를 사용하세요.</p>
    </div>
  )
}

function App() {
  const [status, setStatus] = useState<Status | null>(null)
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [setupCode, setSetupCode] = useState('')
  const [nasUrl, setNasUrl] = useState('https://')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [otp, setOtp] = useState('')
  const [otpVisible, setOtpVisible] = useState(false)
  const [remember, setRemember] = useState(false)
  const [trustDevice, setTrustDevice] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const next = await request<Status>('/api/status')
      setStatus(next)
      if (next.configured) {
        try { setSession(await request<Session>('/api/auth/me')) }
        catch { setSession(null) }
      }
      setError('')
    } catch (err) {
      setError((err as Error).message)
    } finally { setLoading(false) }
  }, [])

  useEffect(() => { void load() }, [load])

  async function submitSetup(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true); setError('')
    try {
      const result = await request<Status>('/api/setup', jsonRequest({ code: setupCode, nas_url: nasUrl }))
      setStatus(result); setSetupCode('')
    } catch (err) { setError((err as Error).message) }
    finally { setBusy(false) }
  }

  async function submitLogin(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true); setError('')
    try {
      await request<Session>('/api/auth/login', jsonRequest({
        username, password, otp: otp || null, remember, trust_device: remember && trustDevice,
      }))
      try {
        setSession(await request<Session>('/api/auth/me'))
      } catch (error) {
        if (error instanceof ApiFailure && error.code === 'LOGIN_REQUIRED') {
          throw new ApiFailure('LOGIN_COOKIE_MISSING', 401)
        }
        throw error
      }
      setPassword(''); setOtp('')
    } catch (err) {
      const message = (err as Error).message
      if (message === 'NAS의 2단계 인증 코드를 입력하세요.') setOtpVisible(true)
      setError(message)
    } finally { setBusy(false) }
  }

  async function logout() {
    if (!session) return
    setBusy(true); setError('')
    try {
      try {
        await request('/api/auth/logout', jsonRequest({}, { 'X-CSRF-Token': session.csrf_token }))
      } catch (error) {
        if (!(error instanceof ApiFailure) || error.status !== 401) throw error
        // The server already discarded this session; finish local logout too.
      }
      setSession(null); setPassword(''); setOtp(''); setOtpVisible(false)
    } finally { setBusy(false) }
  }

  const sessionExpired = useCallback(() => {
    setSession(null); setError('로그인 세션이 만료되었습니다. 다시 로그인하세요.')
  }, [])

  useEffect(() => {
    if (!session) return
    window.addEventListener(SESSION_EXPIRED_EVENT, sessionExpired)
    return () => window.removeEventListener(SESSION_EXPIRED_EVENT, sessionExpired)
  }, [session, sessionExpired])

  if (!loading && session && status?.configured) {
    return <Workspace session={session} status={status} onLogout={logout}
      onSessionExpired={sessionExpired} />
  }

  return (
    <div className="auth-shell">
      <main className="auth-main">
        <div className="auth-brand"><BookOpenText size={28}/><h1>Synology Markdown Note</h1></div>
        <section className="card auth-card" aria-live="polite">
          {loading ? (
            <div className="flex items-center gap-3 py-14 text-sm text-slate-600"><RefreshCw className="animate-spin" size={18} /> 서버 상태를 확인하고 있습니다…</div>
          ) : !status ? (
            <div><h3 className="text-xl font-bold">서버 연결 확인</h3><p className="mb-5 mt-3 text-sm text-slate-600">설정을 불러올 수 없습니다.</p><Button onClick={() => void load()} variant="outline"><RefreshCw size={16} /> 다시 시도</Button></div>
          ) : !status.configured ? (
            <>
              <div className="mb-6 flex items-center gap-3"><div className="rounded-xl bg-mist p-3 text-marine"><ServerCog size={24} /></div><div><p className="text-xs font-semibold text-marine">STEP 01</p><h3 className="text-xl font-bold">NAS 최초 설정</h3></div></div>
              <p className="mb-7 text-sm leading-6 text-slate-600">설치 관리자만 NAS 주소를 한 번 설정할 수 있습니다. 아래에서 초기 설정 코드를 확인한 후 입력하세요.</p>
              <form className="space-y-5" onSubmit={e => void submitSetup(e)}>
                <div><label htmlFor="nas-url" className="field-label">NAS 주소 (HTTPS / HTTP)</label><input className="field" id="nas-url" type="url" required autoComplete="url" placeholder="https://nas.example.com:5001" value={nasUrl} onChange={e => setNasUrl(e.target.value)} /></div>
                {nasUrl.trim().toLowerCase().startsWith('http://') && <InsecureNasWarning />}
                <div><label htmlFor="setup-code" className="field-label">초기 설정 코드</label><input className="field" id="setup-code" type="password" required autoComplete="off" value={setupCode} onChange={e => setSetupCode(e.target.value)} /></div>
                <div className="rounded-xl border border-sky-200 bg-sky-50/70 px-4 py-3 text-xs leading-5 text-slate-700">
                  <p className="font-semibold text-ink">초기 설정 코드는 어떻게 확인하나요?</p>
                  <p className="mt-2">Docker Compose를 실행한 서버에 접속해 <code>docker-compose.yaml</code> 파일이 있는 폴더에서 실행하세요.</p>
                  <code className="mt-2 block select-all overflow-x-auto rounded-lg bg-ink px-3 py-2 font-mono text-xs text-white">docker compose exec web cat /data/setup-code</code>
                  <p className="mt-2">Synology Container Manager에서는 해당 웹 컨테이너의 터미널에서 <code className="font-semibold">cat /data/setup-code</code>를 실행할 수도 있습니다.</p>
                  <p className="mt-2 text-slate-500">출력된 코드를 위에 입력하세요. 초기 설정이 완료되면 코드 파일은 삭제됩니다. 코드를 타인과 공유하지 마세요.</p>
                </div>
                <Button className="w-full" disabled={busy} type="submit">{busy ? 'NAS 연결 확인 중…' : '연결 확인 및 설정 저장'} <ArrowRight size={17} /></Button>
              </form>
              <p className="mt-5 text-xs leading-5 text-slate-500">자체 서명 인증서는 NAS_CA_FILE로 신뢰 CA를 설정하세요. HTTP 연결과 사설 IP는 NAS_ALLOW_PRIVATE=true 설정이 필요합니다.</p>
            </>
          ) : (
            <>
              <div className="mb-6 flex items-center gap-3"><div className="rounded-xl bg-mist p-3 text-marine"><KeyRound size={24} /></div><div><p className="text-xs font-semibold text-marine">NOTE STATION</p><h3 className="text-xl font-bold">NAS 계정 로그인</h3></div></div>
              <div className="mb-7 rounded-xl border border-slate-200 bg-slate-50 px-4 py-3"><p className="text-[11px] font-semibold text-slate-500">연결된 NAS · {status.read_only ? '환경변수 설정' : '웹에서 저장한 설정'}</p><p className="mt-1 break-all text-sm font-medium">{status.nas_url}</p></div>
              {status.nas_url?.toLowerCase().startsWith('http://') && <div className="mb-5"><InsecureNasWarning /></div>}
              <form className="space-y-5" onSubmit={e => void submitLogin(e)}>
                <div><label className="field-label" htmlFor="username">사용자 이름</label><input className="field" id="username" required autoComplete="username" value={username} onChange={e => setUsername(e.target.value)} /></div>
                <div><label className="field-label" htmlFor="password">비밀번호</label><input className="field" id="password" type="password" required autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} /></div>
                {otpVisible && <div><label className="field-label" htmlFor="otp">2단계 인증 코드</label><input className="field" id="otp" inputMode="numeric" autoComplete="one-time-code" value={otp} onChange={e => setOtp(e.target.value)} /></div>}
                <label className="flex cursor-pointer items-center gap-3 text-sm"><input className="h-4 w-4 accent-ink" type="checkbox" checked={remember} onChange={e => { setRemember(e.target.checked); if (!e.target.checked) setTrustDevice(false) }} /> 로그인 유지 (30일)</label>
                {remember && <div className="rounded-xl bg-mist p-4 text-xs leading-5 text-slate-700"><p>로그인 유지를 위해 비밀번호를 서버에 암호화하여 보관합니다. 로그아웃하면 폐기합니다.</p><label className="mt-3 flex cursor-pointer items-center gap-2"><input className="accent-ink" type="checkbox" checked={trustDevice} onChange={e => setTrustDevice(e.target.checked)} /> 이 NAS를 신뢰 기기로 등록 (선택)</label></div>}
                <Button className="w-full" disabled={busy} type="submit">{busy ? '로그인 확인 중…' : '로그인'} <ArrowRight size={17} /></Button>
              </form>
            </>
          )}
          {error && <div className="mt-5 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm leading-6 text-rose-700" role="alert">{error}</div>}
        </section>
      </main>

    </div>
  )
}

export default App
