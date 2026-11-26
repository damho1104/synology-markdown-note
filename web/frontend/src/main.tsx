import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import { loadLanguage, setLanguage } from './i18n'
import './style.css'

async function start() {
  setLanguage(await loadLanguage(navigator.languages))
  ReactDOM.createRoot(document.getElementById('root')!).render(
    <React.StrictMode><App /></React.StrictMode>,
  )
}

void start()
