import { english } from "./messages";

export type Language = "en" | "ko";
export type Message = keyof typeof english;

let language: Language = "en";

export function setLanguage(value: Language): void {
  language = value;
  document.documentElement.lang = value;
}

export function currentLanguage(): Language {
  return language;
}

const numberFormat = {en: new Intl.NumberFormat("en"), ko: new Intl.NumberFormat("ko")};

export function formatNumber(value: number): string {
  return numberFormat[language].format(value);
}

export function t(message: Message, ...values: (string | number)[]): string {
  const pattern = language === "ko" ? message : english[message];
  return pattern.replace(/\{(\d+)\}/g, (slot, index) => {
    const value = values[Number(index)];
    return typeof value === "number" ? formatNumber(value) : value ?? slot;
  });
}

export class UiError extends Error {
  constructor(message: Message) {
    super(t(message));
  }
}

// Attachment drafts can survive a reload after the deployment language changes.
export function storedErrorText(previous: string): string {
  if (Object.hasOwn(english, previous)) return t(previous as Message);
  const match = (Object.keys(english) as Message[]).find(message => english[message] === previous);
  if (match) return t(match);
  const status = previous.match(/^(?:Request failed|요청에 실패했습니다) \((\d{3})\)\.$/);
  return status ? t("요청에 실패했습니다 ({0}).", status[1]) : t("요청 처리 중 오류가 발생했습니다.");
}

export function browserLanguage(preferred: readonly string[]): Language {
  for (const tag of preferred) {
    const language = tag.toLowerCase().split("-")[0];
    if (language === "en" || language === "ko") return language;
  }
  return "en";
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
    if (mode === "en" || mode === "ko") return mode;
    if (mode !== "auto") throw new Error("Invalid default language in public config.");

    return browserLanguage(preferred);
  } finally {
    clearTimeout(timeout);
  }
}
