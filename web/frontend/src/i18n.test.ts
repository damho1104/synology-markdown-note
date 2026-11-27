import { afterEach, expect, it, vi } from "vitest";
import { loadLanguage } from "./i18n";

afterEach(() => vi.unstubAllGlobals());

it.each([
  ["auto", ["fr-FR", "ko-KR", "en-US"], "ko"],
  ["auto", ["fr-FR", "EN-GB", "ko-KR"], "en"],
  ["auto", ["ja-JP", "fr-FR"], "en"],
  ["auto", [], "en"],
  ["ko", ["en-US"], "ko"],
])("resolves %s with preferences %j to %s", async (default_language, preferences, expected) => {
  vi.stubGlobal("fetch", vi.fn(async () => Response.json({default_language})));
  await expect(loadLanguage(preferences)).resolves.toBe(expected);
});

it.each([
  ["a missing language", () => Response.json({})],
  ["an unsupported language", () => Response.json({default_language: "ja"})],
  ["invalid JSON", () => new Response("<html>")],
  ["a missing endpoint", () => Response.json({}, {status: 404})],
  ["a server error", () => Response.json({default_language: "auto"}, {status: 503})],
  ["a network failure", () => { throw new TypeError("Network unavailable"); }],
])("keeps the language unresolved after %s", async (_failure, respond) => {
  vi.stubGlobal("fetch", vi.fn(async () => respond()));
  await expect(loadLanguage(["ja-JP", "ko-KR"])).rejects.toThrow();
});
