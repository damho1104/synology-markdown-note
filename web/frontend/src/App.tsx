import { t } from './i18n'
import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { AlertTriangle, ArrowRight, KeyRound, RefreshCw, ServerCog } from 'lucide-react'
import { AppIcon } from './AppIcon'
import { Button } from './components/ui/button'
import { ApiFailure, errorText, request, jsonRequest, type Session, type Status, SESSION_EXPIRED_EVENT } from './api'
import { Workspace } from './Workspace'
import { NasConnectionStatus } from './NasConnectionStatus'

function InsecureNasWarning() {
  return (
    <div className="flex items-start gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-950" role="alert">
      <AlertTriangle className="mt-0.5 shrink-0 text-amber-700" size={19} aria-hidden="true" />
      <p><strong>{t("auth.httpConnectionNotEncrypted")}</strong>{" "}{t("auth.credentialsPasswordsVerificationCodesAndTransferredDataMay")}</p>
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
      setError(errorText(err))
    } finally { setLoading(false) }
  }, [])

  useEffect(() => { void load() }, [load])

  async function submitSetup(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setBusy(true); setError('')
    try {
      const result = await request<Status>('/api/setup', jsonRequest({ code: setupCode, nas_url: nasUrl }))
      setStatus(result); setSetupCode('')
    } catch (err) { setError(errorText(err)) }
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
      if (err instanceof ApiFailure && err.code === 'OTP_REQUIRED') setOtpVisible(true)
      setError(errorText(err))
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
    setSession(null); setError(t("errors.yourSessionHasExpiredSignAgain"))
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
        <div className="auth-brand"><AppIcon /><h1>Synology Markdown Note</h1></div>
        <section className="card auth-card" aria-live="polite">
          {loading ? (
            <div className="flex items-center gap-3 py-14 text-sm text-slate-600"><RefreshCw className="animate-spin" size={18} />{" "}{t("auth.checkingServerStatus")}</div>
          ) : !status ? (
            <div><h3 className="text-xl font-bold">{t("auth.checkServerConnection")}</h3><p className="mb-5 mt-3 text-sm text-slate-600">{t("auth.couldNotLoadConfiguration")}</p><Button onClick={() => void load()} variant="outline"><RefreshCw size={16} />{" "}{t("common.tryAgain")}</Button></div>
          ) : !status.configured ? (
            <>
              <div className="mb-6 flex items-center gap-3"><div className="rounded-xl bg-mist p-3 text-marine"><ServerCog size={24} /></div><div><h3 className="text-xl font-bold">{t("auth.initialNasSetup")}</h3></div></div>
              <p className="mb-7 text-sm leading-6 text-slate-600">{t("auth.onlyAdministratorCanConfigureNasAddressDuringInitial")}</p>
              <form className="space-y-5" onSubmit={e => void submitSetup(e)}>
                <div><label htmlFor="nas-url" className="field-label">{t("auth.nasAddressHttpsHttp")}</label><input className="field" id="nas-url" type="url" required autoComplete="url" placeholder="https://nas.example.com:5001" value={nasUrl} onChange={e => setNasUrl(e.target.value)} /></div>
                {nasUrl.trim().toLowerCase().startsWith('http://') && <InsecureNasWarning />}
                <div><label htmlFor="setup-code" className="field-label">{t("auth.setupCode")}</label><input className="field" id="setup-code" type="password" required autoComplete="off" value={setupCode} onChange={e => setSetupCode(e.target.value)} /></div>
                <div className="rounded-xl border border-sky-200 bg-sky-50/70 px-4 py-3 text-xs leading-5 text-slate-700">
                  <p className="font-semibold text-ink">{t("auth.whereCanIFindSetupCode")}</p>
                  <p className="mt-2">{t("auth.onServerRunningDockerComposeRunCommandBelow", "docker-compose.yaml")}</p>
                  <code className="mt-2 block select-all overflow-x-auto rounded-lg bg-ink px-3 py-2 font-mono text-xs text-white">docker compose exec web cat /data/setup-code</code>
                  <p className="mt-2">{t("auth.synologyContainerManagerYouCanAlsoRunWeb", "cat /data/setup-code")}</p>
                  <p className="mt-2 text-slate-500">{t("auth.enterDisplayedCodeAboveCodeFileDeletedAfter")}</p>
                </div>
                <Button className="w-full" disabled={busy} type="submit">{busy ? t("auth.checkingNasConnection") : t("auth.verifyConnectionAndSaveSettings")} <ArrowRight size={17} /></Button>
              </form>
              <p className="mt-5 text-xs leading-5 text-slate-500">{t("auth.forSelfSignedCertificatesConfigureTrustedCaWith")}</p>
            </>
          ) : (
            <>
              <div className="mb-6 flex items-center gap-3"><div className="rounded-xl bg-mist p-3 text-marine"><KeyRound size={24} /></div><div><p className="text-xs font-semibold text-marine">NOTE STATION</p><h3 className="text-xl font-bold">{t("auth.signInTitle")}</h3></div></div>
              <div className="mb-7 rounded-xl border border-slate-200 bg-slate-50 px-4 py-3"><p className="text-[11px] font-semibold text-slate-500">{t("auth.currentNasLabel")}{" "}{status.read_only ? t("auth.environmentConfiguration") : t("auth.configurationSavedOnWeb")}</p><p className="mt-1 break-all text-sm font-medium">{status.nas_url}</p></div>
              {status.nas_url?.toLowerCase().startsWith('http://') && <div className="mb-5"><InsecureNasWarning /></div>}
              <form className="space-y-5" onSubmit={e => void submitLogin(e)}>
                <div><label className="field-label" htmlFor="username">{t("auth.username")}</label><input className="field" id="username" required autoComplete="username" value={username} onChange={e => setUsername(e.target.value)} /></div>
                <div><label className="field-label" htmlFor="password">{t("auth.password")}</label><input className="field" id="password" type="password" required autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} /></div>
                {otpVisible && <div><label className="field-label" htmlFor="otp">{t("auth.twoFactorAuthenticationCode")}</label><input className="field" id="otp" inputMode="numeric" autoComplete="one-time-code" value={otp} onChange={e => setOtp(e.target.value)} /></div>}
                <label className="flex cursor-pointer items-center gap-3 text-sm"><input className="h-4 w-4 accent-ink" type="checkbox" checked={remember} onChange={e => { setRemember(e.target.checked); if (!e.target.checked) setTrustDevice(false) }} />{" "}{t("auth.keepMeSigned30Days")}</label>
                {remember && <div className="rounded-xl bg-mist p-4 text-xs leading-5 text-slate-700"><p>{t("auth.keepYouSignedServerStoresYourPasswordEncrypted")}</p><label className="mt-3 flex cursor-pointer items-center gap-2"><input className="accent-ink" type="checkbox" checked={trustDevice} onChange={e => setTrustDevice(e.target.checked)} />{" "}{t("auth.registerThisNasAsTrustedDeviceOptional")}</label></div>}
                <Button className="w-full" disabled={busy} type="submit">{busy ? t("auth.signing") : t("auth.signIn")} <ArrowRight size={17} /></Button>
              </form>
            </>
          )}
          {error && <div className="mt-5 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm leading-6 text-rose-700" role="alert">{error}</div>}
        </section>
      </main>
      <NasConnectionStatus connected={false} />
    </div>
  )
}

export default App
