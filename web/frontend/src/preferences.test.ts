// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { DEFAULT_PREFERENCES, loadPreferences, savePreferences, PREFERENCES_KEY, validatePreferences } from './preferences'

beforeEach(() => localStorage.clear())
afterEach(() => vi.restoreAllMocks())

it('uses native defaults for missing, malformed and unsupported stored versions', () => {
  expect(loadPreferences()).toEqual({ appearance: 'system', editorFontSize: 14, lineNumbers: false,
    lineWrapping: false, mermaidStyle: 'handDrawn', mermaidTheme: 'system' })
  for (const value of ['{bad', 'null', '[]', '{"version":2,"preferences":{"appearance":"dark"}}']) {
    localStorage.setItem(PREFERENCES_KEY, value)
    expect(loadPreferences()).toEqual(DEFAULT_PREFERENCES)
  }
})

it('validates each field and restricts font sizes to integer values from 11 through 22', () => {
  expect(validatePreferences({ appearance: 'unknown', editorFontSize: '18', lineNumbers: 1,
    lineWrapping: 'true', mermaidStyle: 'script', mermaidTheme: 'unknown' })).toEqual(DEFAULT_PREFERENCES)
  expect(validatePreferences({ editorFontSize: 80 }).editorFontSize).toBe(22)
  expect(validatePreferences({ editorFontSize: 1 }).editorFontSize).toBe(11)
  expect(validatePreferences({ editorFontSize: 15.6 }).editorFontSize).toBe(16)
  expect(validatePreferences({ editorFontSize: NaN }).editorFontSize).toBe(14)
  expect(validatePreferences({ editorFontSize: Infinity }).editorFontSize).toBe(14)
})

it('persists and restores validated settings in a versioned browser-local record', () => {
  const preferences = { ...DEFAULT_PREFERENCES, appearance: 'dark' as const, editorFontSize: 19,
    lineWrapping: true, lineNumbers: true, mermaidStyle: 'classic' as const, mermaidTheme: 'forest' as const }
  savePreferences(preferences)
  expect(JSON.parse(localStorage.getItem(PREFERENCES_KEY)!)).toEqual({ version: 1, preferences })
  expect(loadPreferences()).toEqual(preferences)
})

it('keeps working when browser storage is blocked', () => {
  vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('blocked') })
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('full') })
  expect(loadPreferences()).toEqual(DEFAULT_PREFERENCES)
  expect(() => savePreferences(DEFAULT_PREFERENCES)).not.toThrow()
})
