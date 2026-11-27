import registry from "../../backend/synonote_web/locales.json";
import attachments from "./locales/en/attachments.json";
import auth from "./locales/en/auth.json";
import common from "./locales/en/common.json";
import editor from "./locales/en/editor.json";
import errors from "./locales/en/errors.json";
import graph from "./locales/en/graph.json";
import library from "./locales/en/library.json";
import search from "./locales/en/search.json";
import settings from "./locales/en/settings.json";
import startup from "./locales/en/startup.json";
import workspace from "./locales/en/workspace.json";

const reference = { attachments, auth, common, editor, errors, graph, library, search, settings, startup, workspace };
type Feature = keyof typeof reference;
export type Message = {
  [F in Feature]: `${F}.${Extract<keyof (typeof reference)[F], string>}`
}[Feature];

export const supportedLanguages = registry.languages;
export const fallbackLanguage = registry.fallback;
export const isSupportedLanguage = (value: string): boolean => supportedLanguages.includes(value);

const files = import.meta.glob<Record<string, string>>("./locales/*/*.json", { eager: true, import: "default" });
export type Catalog = Record<string, Record<string, string>>;

export const catalogs = Object.fromEntries(supportedLanguages.map(language => {
  const prefix = `./locales/${language}/`;
  const entries = Object.entries(files)
    .filter(([path]) => path.startsWith(prefix))
    .map(([path, messages]) => [path.slice(prefix.length, -".json".length), messages] as const);
  return [language, Object.fromEntries(entries) as Catalog];
}));

export const resources = Object.fromEntries(Object.entries(catalogs).map(([language, catalog]) => {
  const { codeMirror: _codeMirror, ...translation } = catalog;
  return [language, { translation }];
}));

export function codeMirrorMessages(language: string): Record<string, string> {
  return catalogs[language]?.codeMirror ?? catalogs[fallbackLanguage].codeMirror;
}
