import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { AlertTriangle, ArrowRight, BookOpenText, CheckCircle2, Cloud, KeyRound, LockKeyhole, LogOut, RefreshCw, ServerCog, ShieldCheck } from 'lucide-react'
import { Button } from './components/ui/button'

type Status = { configured: boolean; nas_url: string | null; source: 'environment' | 'database' | 'setup'; read_only: boolean }
type Session = { username: string; remember: boolean; csrf_token: string }
type ApiError = { error?: string; detail?: string }

const messages: Record<string, string> = {
  INVALID_NAS_URL: 'NAS 주소는 사용자 정보·쿼리 없이 HTTP 또는 HTTPS 주소로 입력하세요.',
  NAS_ADDRESS_BLOCKED: '해당 NAS 주소의 네트워크 연결이 차단되었습니다. 사설망 NAS라면 관리자가 NAS_ALLOW_PRIVATE 설정을 확인해야 합니다.',
  NAS_UNAVAILABLE: 'NAS와 통신하지 못했습니다. 주소·포트·인증서(HTTPS)·방화벽을 확인하세요.',
  NAS_API_ERROR: 'NAS가 예상한 Note Station API 응답을 반환하지 않았습니다.',
  INVALID_SETUP_CODE: '초기 설정 코드가 일치하지 않습니다.',
  ALREADY_CONFIGURED: '이 설치의 NAS 주소는 이미 설정되어 있습니다.',
  AUTH_FAILED: '사용자 이름이나 비밀번호, 인증 정보를 확인하세요.',
  OTP_REQUIRED: 'NAS의 2단계 인증 코드를 입력하세요.',
  TOO_MANY_ATTEMPTS: '인증 시도가 너무 많습니다. 잠시 후 다시 시도하세요.',
  RELOGIN_REQUIRED: 'NAS 재인증이 필요합니다. 다시 로그인하세요.',
  INVALID_NAS_CONFIGURATION: 'NAS_URL 환경변수의 주소가 올바르지 않습니다.',
  LOCAL_STORE_ERROR: '서버의 암호화 저장소를 열 수 없습니다. 관리자에게 문의하세요.',
  ORIGIN_REQUIRED: '보안 확인에 실패했습니다. 웹 주소와 WEB_PUBLIC_ORIGIN 설정을 확인하세요.',
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  let response: Response
  try {
    response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...init })
  } catch {
    throw new Error('웹 서버에 연결할 수 없습니다. 네트워크를 확인하세요.')
  }
  if (!response.ok) {
    const data = await response.json().catch(() => ({})) as ApiError
    throw new Error(messages[data.error ?? data.detail ?? ''] ?? '요청을 처리하지 못했습니다.')
  }
  return response.json() as Promise<T>
}

function jsonRequest(body: unknown, headers: Record<string, string> = {}): RequestInit {
  return { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }
}

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
      setSession(await request<Session>('/api/auth/login', jsonRequest({
        username, password, otp: otp || null, remember, trust_device: remember && trustDevice,
      })))
      setPassword(''); setOtp('')
    } catch (err) {
      const message = (err as Error).message
      if (message === messages.OTP_REQUIRED) setOtpVisible(true)
      setError(message)
    } finally { setBusy(false) }
  }

  async function logout() {
    if (!session) return
    setBusy(true); setError('')
    try {
      await request('/api/auth/logout', jsonRequest({}, { 'X-CSRF-Token': session.csrf_token }))
      setSession(null); setPassword(''); setOtp(''); setOtpVisible(false)
    } catch (err) { setError((err as Error).message) }
    finally { setBusy(false) }
  }

  return (
    <div className="min-h-screen bg-paper">
      <header className="border-b border-slate-200 bg-white/90">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
          <div className="flex items-center gap-3"><div className="rounded-xl bg-ink p-2.5 text-white"><BookOpenText size={22} /></div><div><h1 className="text-base font-bold tracking-tight">Synology Markdown Note</h1><p className="text-xs text-slate-500">Web Client · 초기 버전</p></div></div>
          <span className="hidden items-center gap-2 rounded-full border border-slate-200 px-3 py-1.5 text-xs font-semibold text-slate-500 sm:flex"><Cloud size={15} /> Self-hosted</span>
        </div>
      </header>
      <main className="mx-auto grid max-w-6xl items-center gap-12 px-6 py-12 lg:min-h-[calc(100vh-185px)] lg:grid-cols-[1fr_470px] lg:py-16">
        <section className="max-w-xl">
          <div className="mb-7 inline-flex items-center gap-2 rounded-full border border-[#c6dce5] bg-[#eaf4f7] px-3 py-1.5 text-xs font-semibold text-[#1c6784]"><ShieldCheck size={15} /> 내 NAS에 안전하게 연결</div>
          <h2 className="text-4xl font-bold leading-[1.25] tracking-[-0.04em] sm:text-5xl">당신의 노트를,<br /><span className="text-marine">어디서든 이어서.</span></h2>
          <p className="mt-6 max-w-lg text-[15px] leading-8 text-slate-600">기존 Synology Note Station 데이터를 사용하는 독립 웹 클라이언트입니다. NAS 계정으로 로그인하고, 한곳에서 관리하세요.</p>
          <div className="mt-10 grid max-w-lg gap-4 sm:grid-cols-2">
            <div className="rounded-2xl border border-slate-200 bg-white p-5"><ServerCog className="mb-3 text-marine" size={24} /><p className="text-sm font-semibold">설치당 NAS 한 대</p><p className="mt-2 text-xs leading-5 text-slate-500">설정한 NAS로만 접속합니다.</p></div>
            <div className="rounded-2xl border border-slate-200 bg-white p-5"><LockKeyhole className="mb-3 text-marine" size={24} /><p className="text-sm font-semibold">계정별 보안 세션</p><p className="mt-2 text-xs leading-5 text-slate-500">비밀번호와 NAS 세션을 브라우저에 저장하지 않습니다.</p></div>
          </div>
          <p className="mt-8 text-xs leading-6 text-slate-500">이 개발 단계에서는 초기 설정과 인증만 제공됩니다. 노트 탐색·편집·오프라인 동기화는 후속 단계에 추가됩니다.</p>
        </section>
        <section className="card w-full" aria-live="polite">
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
              <p className="mt-5 text-xs leading-5 text-slate-500">자체 서명 인증서는 NAS_CA_FILE로 신뢰 CA를 설정하세요. 사설 IP는 NAS_ALLOW_PRIVATE 설정이 필요합니다.</p>
            </>
          ) : session ? (
            <>
              <div className="mb-6 flex items-center gap-3"><div className="rounded-xl bg-emerald-50 p-3 text-emerald-700"><CheckCircle2 size={24} /></div><div><p className="text-xs font-semibold text-emerald-700">CONNECTED</p><h3 className="text-xl font-bold">로그인되었습니다</h3></div></div>
              <p className="text-sm text-slate-600"><b className="text-ink">{session.username}</b> 계정으로 접속했습니다.</p>
              <div className="mt-6 rounded-xl border border-slate-200 bg-slate-50 p-4 text-sm"><p className="text-xs font-semibold text-slate-500">연결된 NAS</p><p className="mt-2 break-all font-medium">{status.nas_url}</p><p className="mt-2 text-xs text-slate-500">{session.remember ? '로그인 유지 사용 중' : '브라우저 세션에서만 로그인 유지'}</p></div>
              {status.nas_url?.toLowerCase().startsWith('http://') && <div className="mt-4"><InsecureNasWarning /></div>}
              <div className="mt-5 rounded-xl border border-dashed border-slate-300 p-5 text-sm leading-6 text-slate-600">노트 목록·편집 UI는 다음 구현 단계에서 연결됩니다.</div>
              <Button className="mt-6 w-full" variant="outline" onClick={() => void logout()} disabled={busy}><LogOut size={16} /> 로그아웃</Button>
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
      <footer className="mx-auto flex max-w-6xl flex-wrap justify-between gap-3 px-6 pb-8 text-xs text-slate-500"><p>Synology Markdown Note · Web Client</p><p>안전한 연결을 위해 HTTPS를 사용하세요.</p></footer>
    </div>
  )
}

export default App
