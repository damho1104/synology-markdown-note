import { formatNumber, t } from "./i18n";
import { useId, useLayoutEffect, useRef, useState } from 'react'
import { SlidersHorizontal, X } from 'lucide-react'
import { supportedLanguages } from './catalogs'
import { DEFAULT_PREFERENCES, MIN_LIST_REFRESH_MINUTES, normalizeListRefreshMinutes, type PreviewPreferences } from './preferences'

const languageNames = new Map<string, string>()
function languageName(language: string): string {
  let name = languageNames.get(language)
  if (!name) {
    name = new Intl.DisplayNames([language], { type: 'language' }).of(language) ?? language
    languageNames.set(language, name)
  }
  return name
}

export function SettingsDialog({ preferences, onChange, onClose }: {
  preferences: PreviewPreferences
  onChange: (changes: Partial<PreviewPreferences>) => void
  onClose: () => void
}) {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const titleId = useId()
  const descriptionId = useId()
  const [refreshInput, setRefreshInput] = useState(() => String(preferences.listRefreshMinutes))

  useLayoutEffect(() => {
    const dialog = dialogRef.current!
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const focusables = () => Array.from(dialog.querySelectorAll<HTMLElement>(
      'button:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex="0"]'))
    if (typeof dialog.showModal === 'function') dialog.showModal()
    else dialog.setAttribute('open', '')
    focusables()[0]?.focus()
    const containFocus = (event: FocusEvent) => {
      if (event.target instanceof Node && !dialog.contains(event.target)) focusables()[0]?.focus()
    }
    document.addEventListener('focusin', containFocus)
    return () => {
      document.removeEventListener('focusin', containFocus)
      if (typeof dialog.close === 'function' && dialog.open) dialog.close()
      else dialog.removeAttribute('open')
      if (previous?.isConnected) previous.focus()
    }
  }, [])

  function update<Key extends keyof PreviewPreferences>(key: Key, value: PreviewPreferences[Key]) {
    onChange({ [key]: value })
  }

  return <dialog ref={dialogRef} className="native-settings-dialog" aria-modal="true"
    aria-labelledby={titleId} aria-describedby={descriptionId}
    onCancel={event => { event.preventDefault(); onClose() }}
    onClick={event => {
      if (event.target !== event.currentTarget) return
      const bounds = event.currentTarget.getBoundingClientRect()
      if (event.clientX < bounds.left || event.clientX >= bounds.right ||
          event.clientY < bounds.top || event.clientY >= bounds.bottom) onClose()
    }}
    onKeyDown={event => {
      if (event.key === 'Escape') { event.preventDefault(); onClose(); return }
      if (event.key !== 'Tab') return
      const controls = Array.from(event.currentTarget.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex="0"]'))
      const first = controls[0], last = controls.at(-1)
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
    }}>
    <div className="settings-window">
      <header className="settings-titlebar">
        <button type="button" className="settings-close" aria-label={t("settings.closeSettings")} onClick={onClose}><X size={11} /></button>
        <h2 id={titleId}>{t("common.settings")}</h2>
        <span className="settings-tab"><SlidersHorizontal size={18} />{t("settings.general")}</span>
      </header>
      <div className="settings-content">
        <p id={descriptionId} className="settings-description">{t("settings.changesTakeEffectImmediatelyAndSavedThisBrowser")}</p>
        <section aria-labelledby={`${titleId}-sync`}>
          <h3 id={`${titleId}-sync`}>{t("settings.sync")}</h3>
          <div className="settings-group">
            <label className="settings-row">{t("settings.listRefreshIntervalMinutes")}
              <input type="number" min={MIN_LIST_REFRESH_MINUTES} step="1" value={refreshInput}
                onChange={({ currentTarget: input }) => {
                  setRefreshInput(input.value)
                  if (input.validity.valid && Number.isSafeInteger(input.valueAsNumber)) {
                    update('listRefreshMinutes', input.valueAsNumber)
                  }
                }}
                onBlur={({ currentTarget: input }) => {
                  const minutes = normalizeListRefreshMinutes(input.valueAsNumber, preferences.listRefreshMinutes)
                  setRefreshInput(String(minutes))
                  if (minutes !== preferences.listRefreshMinutes) update('listRefreshMinutes', minutes)
                }} />
            </label>
          </div>
          <p className="settings-help">{t("settings.automaticallyChecksNasForChangesNotebooksAndNotes")}</p>
        </section>
        <section aria-labelledby={`${titleId}-editor`}>
          <h3 id={`${titleId}-editor`}>{t("settings.editor")}</h3>
          <div className="settings-group">
            <label className="settings-row">{t("settings.fontSize")}
              <span className="settings-size-control"><input aria-label={t("settings.fontSize")} type="range" min="11" max="22" step="1"
                value={preferences.editorFontSize} onChange={event => update('editorFontSize', Number(event.target.value))} />
                <output>{formatNumber(preferences.editorFontSize)}px</output></span>
            </label>
            <label className="settings-row">{t("settings.appearance")}<select aria-label={t("settings.appearance")} value={preferences.appearance}
              onChange={event => update('appearance', event.target.value as PreviewPreferences['appearance'])}>
              <option value="system">{t("settings.systemSetting")}</option><option value="light">{t("settings.light")}</option><option value="dark">{t("settings.dark")}</option>
            </select></label>
            <label className="settings-row">{t("settings.displayLanguage")}<select aria-label={t("settings.displayLanguage")} value={preferences.language}
              onChange={event => update('language', event.target.value)}>
              <option value="">{t("settings.serverDefaultLanguage")}</option>
              <option value="auto">{t("settings.browserLanguage")}</option>
              {supportedLanguages.map(language => <option key={language} value={language}>{languageName(language)}</option>)}
            </select></label>
            <label className="settings-row settings-toggle">{t("settings.showLineNumbers")}<input type="checkbox" checked={preferences.lineNumbers}
              onChange={event => update('lineNumbers', event.target.checked)} /></label>
            <label className="settings-row settings-toggle">{t("settings.wrapLines")}<input type="checkbox" checked={preferences.lineWrapping}
              onChange={event => update('lineWrapping', event.target.checked)} /></label>
          </div>
          <p className="settings-help">{t("settings.fontSizeAppliesBodyEditorsLineNumbersAnd")}</p>
        </section>
        <section aria-labelledby={`${titleId}-mermaid`}>
          <h3 id={`${titleId}-mermaid`}>{t("settings.mermaidDiagrams")}</h3>
          <div className="settings-group">
            <label className="settings-row">{t("settings.drawingStyle")}<select aria-label={t("settings.drawingStyle")} value={preferences.mermaidStyle}
              onChange={event => update('mermaidStyle', event.target.value as PreviewPreferences['mermaidStyle'])}>
              <option value="classic">{t("settings.classic")}</option><option value="handDrawn">{t("settings.handDrawn")}</option>
            </select></label>
            <label className="settings-row">{t("settings.colorTheme")}<select aria-label={t("settings.colorTheme")} value={preferences.mermaidTheme}
              onChange={event => update('mermaidTheme', event.target.value as PreviewPreferences['mermaidTheme'])}>
              <option value="system">{t("settings.matchAppearance")}</option><option value="default">{t("settings.light")}</option><option value="dark">{t("settings.dark")}</option>
              <option value="neutral">{t("settings.neutral")}</option><option value="forest">{t("settings.forest")}</option>
            </select></label>
          </div>
          <p className="settings-help">{t("settings.handDrawnStyleChangesShapesAndLinesSupported")}</p>
        </section>
        <section aria-labelledby={`${titleId}-about`}>
          <h3 id={`${titleId}-about`}>{t("settings.about")}</h3>
          <div className="settings-group">
            <div className="settings-row"><span>{t("settings.version")}</span><span>{__APP_VERSION__}</span></div>
          </div>
        </section>
      </div>
      <footer className="settings-footer">
        <button type="button" className="native-button" onClick={() => {
          setRefreshInput(String(DEFAULT_PREFERENCES.listRefreshMinutes))
          onChange({ ...DEFAULT_PREFERENCES })
        }}>{t("settings.restoreDefaults")}</button>
        <button type="button" className="native-button primary" onClick={onClose}>{t("settings.done")}</button>
      </footer>
    </div>
  </dialog>
}
