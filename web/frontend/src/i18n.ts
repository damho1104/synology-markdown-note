import { createInstance } from "i18next";
import {
  fallbackLanguage, isSupportedLanguage, resources, supportedLanguages, type Message,
} from "./catalogs";

export type { Message } from "./catalogs";
export type Language = string;

const translator = createInstance();
void translator.init({
  resources,
  lng: fallbackLanguage,
  fallbackLng: fallbackLanguage,
  supportedLngs: supportedLanguages,
  load: "currentOnly",
  lowerCaseLng: true,
  initAsync: false,
  interpolation: { escapeValue: false, skipOnVariables: true },
});

let language = fallbackLanguage;

export function setLanguage(value: Language): void {
  language = value;
  document.documentElement.lang = value;
}

export function currentLanguage(): Language {
  return language;
}

const formats = new Map<string, Intl.NumberFormat>();

function formatForLanguage(value: number, locale: Language): string {
  let formatter = formats.get(locale);
  if (!formatter) {
    formatter = new Intl.NumberFormat(locale);
    formats.set(locale, formatter);
  }
  return formatter.format(value);
}

export function formatNumber(value: number): string {
  return formatForLanguage(value, language);
}

export function translate(locale: Language, message: Message, ...values: (string | number)[]): string {
  const replace = Object.fromEntries(values.map((value, index) => [
    index, typeof value === "number" ? formatForLanguage(value, locale) : value,
  ]));
  const count = typeof values[0] === "number" ? values[0] : undefined;
  return translator.t(message, { lng: locale, count, replace, nest: false });
}

export function t(message: Message, ...values: (string | number)[]): string {
  return translate(language, message, ...values);
}

export class UiError extends Error {
  constructor(message: Message) {
    super(t(message));
  }
}

// Existing drafts persist rendered errors, so recognize strings from every shipped catalog.
const previousMessages = new Map<string, Message>();
const requestFailureTemplates: [string, string][] = [];
for (const { translation } of Object.values(resources)) {
  const [prefix, suffix] = translation.errors.requestFailed.split("{{0}}");
  requestFailureTemplates.push([prefix, suffix]);
  for (const [feature, values] of Object.entries(translation)) {
    for (const [key, text] of Object.entries(values)) {
      if (!previousMessages.has(text)) previousMessages.set(text, `${feature}.${key}` as Message);
    }
  }
}

export function storedErrorText(previous: string): string {
  const message = previousMessages.get(previous);
  if (message) return t(message);
  for (const [prefix, suffix] of requestFailureTemplates) {
    if (!previous.startsWith(prefix) || !previous.endsWith(suffix)) continue;
    const status = previous.slice(prefix.length, previous.length - suffix.length);
    if (/^\d{3}$/.test(status)) return t("errors.requestFailed", status);
  }
  return t("errors.unexpected");
}

export function browserLanguage(preferred: readonly string[]): Language {
  for (const tag of preferred) {
    let candidate = tag.toLowerCase();
    while (candidate) {
      if (isSupportedLanguage(candidate)) return candidate;
      const separator = candidate.lastIndexOf("-");
      if (separator === -1) break;
      candidate = candidate.slice(0, separator);
    }
  }
  return fallbackLanguage;
}

export async function loadLanguage(preferred: readonly string[]): Promise<Language> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch("/api/public-config", {
      credentials: "omit",
      cache: "no-store",
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`Public config request failed (${response.status}).`);

    const config = await response.json();
    const mode: unknown = config?.default_language;
    if (mode === "auto") return browserLanguage(preferred);
    if (typeof mode === "string" && isSupportedLanguage(mode)) return mode;
    throw new Error("Invalid default language in public config.");
  } finally {
    clearTimeout(timeout);
  }
}
