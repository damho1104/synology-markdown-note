import { afterEach, expect, it, vi } from "vitest";
import ts from "typescript";
import { catalogs, fallbackLanguage, supportedLanguages } from "./catalogs";
import { loadLanguage, storedErrorText, translate, t } from "./i18n";

afterEach(() => vi.unstubAllGlobals());

it("looks up a stable message key and reads an existing stored Korean error", () => {
  expect(t("auth.signInTitle")).toBe("Sign in to NAS");
  expect(storedErrorText("웹 서버에 연결할 수 없습니다. 네트워크를 확인하세요.")).toBe(
    "Could not connect to the web server. Check your network connection.",
  );
});

it("formats arguments in the selected locale and leaves argument text literal", () => {
  expect(translate("en", "workspace.charactersVersion", 1234, "{{0}} $t(auth.signInTitle)")).toBe(
    "Characters: 1,234 · Version {{0}} $t(auth.signInTitle)",
  );
  expect(translate("ko", "workspace.charactersVersion", 1234, "v2")).toBe("1,234자 · 버전 v2");
  expect(storedErrorText("요청에 실패했습니다 (503).")).toBe("Request failed (503).");
});

it.each(supportedLanguages)("restores a stored HTTP error originally displayed in %s", language => {
  const previous = translate(language, "errors.requestFailed", "503");
  expect(storedErrorText(previous)).toBe("Request failed (503).");
});

it("ships complete catalogs with matching message arguments and unique JSON keys", () => {
  const files = import.meta.glob<string>("./locales/*/*.json", { eager: true, query: "?raw", import: "default" });
  const reference = catalogs[fallbackLanguage];
  expect(reference).toBeDefined();
  expect(new Set(supportedLanguages).size).toBe(supportedLanguages.length);
  expect(Object.keys(reference)).toContain("startup");
  expect(Object.keys(reference)).toContain("codeMirror");

  const pluralSuffix = /^(.+)_(zero|one|two|few|many|other)$/;
  for (const language of supportedLanguages) {
    expect(Intl.getCanonicalLocales(language)[0].toLowerCase()).toBe(language);
    const catalog = catalogs[language];
    expect(Object.keys(catalog).sort()).toEqual(Object.keys(reference).sort());
    for (const [feature, messages] of Object.entries(catalog)) {
      const file = `./locales/${language}/${feature}.json`;
      const source = ts.parseJsonText(file, files[file]);
      const declaration = source.statements[0];
      if (!ts.isExpressionStatement(declaration) || !ts.isObjectLiteralExpression(declaration.expression))
        throw new Error(`Expected a flat message object in ${file}`);
      const entries = declaration.expression.properties.map(property => {
        if (!property.name || !ts.isStringLiteral(property.name))
          throw new Error(`Expected a quoted message key in ${file}`);
        return property.name.text;
      });
      expect(new Set(entries).size, file).toBe(entries.length);
      const referenceGroup = Object.fromEntries(Object.entries(reference[feature])
        .filter(([key]) => feature === "codeMirror" || !pluralSuffix.test(key)));
      const pluralCategories = new Set<string>(new Intl.PluralRules(language).resolvedOptions().pluralCategories);
      for (const key of Object.keys(referenceGroup)) expect(Object.hasOwn(messages, key), file).toBe(true);
      const slots = feature === "codeMirror" ? /\$/g : /\{\{\d+\}\}/g;
      for (const [key, text] of Object.entries(messages)) {
        let base = referenceGroup[key];
        if (!Object.hasOwn(referenceGroup, key) && feature !== "codeMirror") {
          const variant = key.match(pluralSuffix);
          if (variant && (variant[2] === "zero" || pluralCategories.has(variant[2]))) {
            const candidate = referenceGroup[variant[1]];
            if (typeof candidate === "string" && candidate.includes("{{0}}")) base = candidate;
          }
        }
        expect(typeof base, `${file}:${key}`).toBe("string");
        expect(typeof text, `${file}:${key}`).toBe("string");
        expect(text.trim().length, `${file}:${key}`).toBeGreaterThan(0);
        expect((text.match(slots) ?? []).sort(), `${file}:${key}`).toEqual(
          (base.match(slots) ?? []).sort(),
        );
      }
    }
  }
});

it.each([
  ["auto", ["qaa-x-test", "ko-KR", "en-US"], "ko"],
  ["auto", ["qaa-x-test", "EN-GB", "ko-KR"], "en"],
  ["auto", ["qaa-x-test"], "en"],
  ["auto", [], "en"],
  ["ko", ["en-US"], "ko"],
])("resolves %s with preferences %j to %s", async (default_language, preferences, expected) => {
  vi.stubGlobal("fetch", vi.fn(async () => Response.json({default_language})));
  await expect(loadLanguage(preferences)).resolves.toBe(expected);
});

it.each([
  ["a missing language", () => Response.json({})],
  ["an unsupported language", () => Response.json({default_language: "invalid_locale"})],
  ["invalid JSON", () => new Response("<html>")],
  ["a missing endpoint", () => Response.json({}, {status: 404})],
  ["a server error", () => Response.json({default_language: "auto"}, {status: 503})],
  ["a network failure", () => { throw new TypeError("Network unavailable"); }],
])("keeps the language unresolved after %s", async (_failure, respond) => {
  vi.stubGlobal("fetch", vi.fn(async () => respond()));
  await expect(loadLanguage(["qaa-x-test", "ko-KR"])).rejects.toThrow();
});
