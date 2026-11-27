import { supportedLanguages } from './catalogs'

export type PreviewPreferences = {
  appearance: 'system' | 'light' | 'dark'
  editorFontSize: number
  language: string
  lineNumbers: boolean
  lineWrapping: boolean
  listRefreshMinutes: number
  mermaidStyle: 'classic' | 'handDrawn'
  mermaidTheme: 'system' | 'default' | 'dark' | 'neutral' | 'forest'
}

// '' follows the server default, 'auto' follows the browser language.
const LANGUAGE_PREFERENCES: readonly string[] = ['', 'auto', ...supportedLanguages]

export const DEFAULT_PREFERENCES: PreviewPreferences = Object.freeze({
  appearance: 'system',
  editorFontSize: 14,
  language: '',
  lineNumbers: false,
  lineWrapping: false,
  listRefreshMinutes: 5,
  mermaidStyle: 'handDrawn',
  mermaidTheme: 'system',
})
export const PREFERENCES_KEY = 'synonote:web-preferences'
export const MIN_LIST_REFRESH_MINUTES = 1

export function normalizeListRefreshMinutes(value: number, fallback = DEFAULT_PREFERENCES.listRefreshMinutes): number {
  const rounded = Math.round(value)
  return Number.isSafeInteger(rounded) ? Math.max(MIN_LIST_REFRESH_MINUTES, rounded) : fallback
}

export function validatePreferences(value: unknown): PreviewPreferences {
  const defaults = { ...DEFAULT_PREFERENCES }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return defaults
  const input = value as Record<string, unknown>
  return {
    appearance: input.appearance === 'light' || input.appearance === 'dark' ? input.appearance : 'system',
    editorFontSize: typeof input.editorFontSize === 'number' && Number.isFinite(input.editorFontSize)
      ? Math.min(22, Math.max(11, Math.round(input.editorFontSize))) : defaults.editorFontSize,
    language: typeof input.language === 'string' && LANGUAGE_PREFERENCES.includes(input.language) ? input.language : '',
    lineNumbers: typeof input.lineNumbers === 'boolean' ? input.lineNumbers : defaults.lineNumbers,
    lineWrapping: typeof input.lineWrapping === 'boolean' ? input.lineWrapping : defaults.lineWrapping,
    listRefreshMinutes: typeof input.listRefreshMinutes === 'number'
      ? normalizeListRefreshMinutes(input.listRefreshMinutes) : defaults.listRefreshMinutes,
    mermaidStyle: input.mermaidStyle === 'classic' ? 'classic' : defaults.mermaidStyle,
    mermaidTheme: input.mermaidTheme === 'default' || input.mermaidTheme === 'dark' ||
      input.mermaidTheme === 'neutral' || input.mermaidTheme === 'forest' ? input.mermaidTheme : 'system',
  }
}

export function loadPreferences(): PreviewPreferences {
  try {
    const stored: unknown = JSON.parse(localStorage.getItem(PREFERENCES_KEY) ?? 'null')
    if (stored && typeof stored === 'object' && 'version' in stored && stored.version === 1 && 'preferences' in stored)
      return validatePreferences(stored.preferences)
  } catch {
    // Malformed records and blocked storage both fall back to native defaults.
  }
  return { ...DEFAULT_PREFERENCES }
}

export function savePreferences(preferences: PreviewPreferences): void {
  try {
    localStorage.setItem(PREFERENCES_KEY, JSON.stringify({ version: 1, preferences: validatePreferences(preferences) }))
  } catch {
    // Keep applying the in-memory settings if browser storage is unavailable.
  }
}
