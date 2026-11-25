import { useId, useLayoutEffect, useRef, useState } from 'react'
import { SlidersHorizontal, X } from 'lucide-react'
import { DEFAULT_PREFERENCES, MIN_LIST_REFRESH_MINUTES, normalizeListRefreshMinutes, type PreviewPreferences } from './preferences'

export function SettingsDialog({ preferences, onChange, onClose }: {
  preferences: PreviewPreferences
  onChange: (preferences: PreviewPreferences) => void
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
    onChange({ ...preferences, [key]: value })
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
        <button type="button" className="settings-close" aria-label="설정 닫기" onClick={onClose}><X size={11} /></button>
        <h2 id={titleId}>설정</h2>
        <span className="settings-tab"><SlidersHorizontal size={18} />일반</span>
      </header>
      <div className="settings-content">
        <p id={descriptionId} className="settings-description">변경한 설정은 바로 적용되며 이 브라우저에 저장됩니다.</p>
        <section aria-labelledby={`${titleId}-sync`}>
          <h3 id={`${titleId}-sync`}>동기화</h3>
          <div className="settings-group">
            <label className="settings-row">목록 갱신 주기 (분)
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
          <p className="settings-help">메모장과 메모 목록의 NAS 변경을 자동으로 확인합니다. 기본 5분, 최소 1분입니다.</p>
        </section>
        <section aria-labelledby={`${titleId}-editor`}>
          <h3 id={`${titleId}-editor`}>편집기</h3>
          <div className="settings-group">
            <label className="settings-row">글꼴 크기
              <span className="settings-size-control"><input aria-label="글꼴 크기" type="range" min="11" max="22" step="1"
                value={preferences.editorFontSize} onChange={event => update('editorFontSize', Number(event.target.value))} />
                <output>{preferences.editorFontSize}px</output></span>
            </label>
            <label className="settings-row">화면 모드<select aria-label="화면 모드" value={preferences.appearance}
              onChange={event => update('appearance', event.target.value as PreviewPreferences['appearance'])}>
              <option value="system">시스템 설정</option><option value="light">라이트</option><option value="dark">다크</option>
            </select></label>
            <label className="settings-row settings-toggle">줄 번호 표시<input type="checkbox" checked={preferences.lineNumbers}
              onChange={event => update('lineNumbers', event.target.checked)} /></label>
            <label className="settings-row settings-toggle">자동 줄바꿈<input type="checkbox" checked={preferences.lineWrapping}
              onChange={event => update('lineWrapping', event.target.checked)} /></label>
          </div>
          <p className="settings-help">글꼴 크기는 본문 편집기에, 줄 번호와 자동 줄바꿈은 Markdown 편집기에 적용됩니다.</p>
        </section>
        <section aria-labelledby={`${titleId}-mermaid`}>
          <h3 id={`${titleId}-mermaid`}>Mermaid 다이어그램</h3>
          <div className="settings-group">
            <label className="settings-row">그리기 스타일<select aria-label="그리기 스타일" value={preferences.mermaidStyle}
              onChange={event => update('mermaidStyle', event.target.value as PreviewPreferences['mermaidStyle'])}>
              <option value="classic">기본</option><option value="handDrawn">스케치</option>
            </select></label>
            <label className="settings-row">색상 테마<select aria-label="색상 테마" value={preferences.mermaidTheme}
              onChange={event => update('mermaidTheme', event.target.value as PreviewPreferences['mermaidTheme'])}>
              <option value="system">화면 모드에 맞춤</option><option value="default">라이트</option><option value="dark">다크</option>
              <option value="neutral">무채색</option><option value="forest">포레스트</option>
            </select></label>
          </div>
          <p className="settings-help">스케치는 지원되는 다이어그램의 도형과 선을 손으로 그린 듯 표시합니다.</p>
        </section>
        <section aria-labelledby={`${titleId}-about`}>
          <h3 id={`${titleId}-about`}>앱 정보</h3>
          <div className="settings-group">
            <div className="settings-row"><span>버전</span><span>{__APP_VERSION__}</span></div>
          </div>
        </section>
      </div>
      <footer className="settings-footer">
        <button type="button" className="native-button" onClick={() => {
          setRefreshInput(String(DEFAULT_PREFERENCES.listRefreshMinutes))
          onChange({ ...DEFAULT_PREFERENCES })
        }}>기본값 복원</button>
        <button type="button" className="native-button primary" onClick={onClose}>완료</button>
      </footer>
    </div>
  </dialog>
}
