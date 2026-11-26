import { afterEach, expect, it, vi } from "vitest";
import { loadLanguage } from "./i18n";

afterEach(() => vi.unstubAllGlobals());

it.each([
  ["auto", ["fr-FR", "ko-KR", "en-US"], "ko"],
  ["auto", ["fr-FR", "EN-GB", "ko-KR"], "en"],
  ["auto", ["ja-JP", "fr-FR"], "en"],
  ["auto", [], "en"],
  ["ko", ["en-US"], "ko"],
  ["unsupported", ["ko-KR"], "ko"],
])("resolves %s with preferences %j to %s", async (default_language, preferences, expected) => {
  vi.stubGlobal("fetch", vi.fn(async () => Response.json({default_language})));
  await expect(loadLanguage(preferences)).resolves.toBe(expected);
});

it("uses the normal auto policy when public config cannot be fetched", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("Network unavailable"); }));
  await expect(loadLanguage(["ja-JP", "ko-KR"])).resolves.toBe("ko");
});
