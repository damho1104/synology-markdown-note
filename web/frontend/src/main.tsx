import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import { Button } from './components/ui/button'
import { browserLanguage, languageForPreference, loadLanguage, setDefaultLanguage, setLanguage, translate, type Language } from './i18n'
import { loadPreferences } from './preferences'
import './style.css'

const root = ReactDOM.createRoot(document.getElementById('root')!)
let starting = false

function StartupStatus({ state }: { state: 'loading' | 'retrying' | 'failed' }) {
  const preferred = navigator.languages
  const language = languageForPreference(loadPreferences().language, preferred, browserLanguage(preferred))
  const failed = state === 'failed'
  return (
    <div className="auth-shell">
      <main className="auth-main" lang={language}>
        <section className="card auth-card">
          <p role="status">{translate(language, failed ? 'startup.failed' : 'startup.loading')}</p>
          {state !== 'loading' && (
            <Button className="mt-4" variant="outline" type="button" aria-disabled={!failed}
              onClick={() => void start(true)}>
              {translate(language, 'startup.retry')}
            </Button>
          )}
        </section>
      </main>
    </div>
  )
}

async function start(retrying = false) {
  if (starting) return
  starting = true
  root.render(<StartupStatus state={retrying ? 'retrying' : 'loading'} />)

  try {
    let serverLanguage: Language
    try {
      serverLanguage = await loadLanguage(navigator.languages)
    } catch {
      // Give a transient startup failure one automatic retry in this document.
      await new Promise(resolve => setTimeout(resolve, 1000))
      serverLanguage = await loadLanguage(navigator.languages)
    }

    setDefaultLanguage(serverLanguage)
    setLanguage(languageForPreference(loadPreferences().language, navigator.languages))
    root.render(<React.StrictMode><App /></React.StrictMode>)
  } catch {
    root.render(<StartupStatus state="failed" />)
  } finally {
    starting = false
  }
}

void start()
