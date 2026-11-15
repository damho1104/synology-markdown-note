import { afterEach, expect, it, vi } from "vitest";
import { previewNonce, canonicalNoteLink } from "./previewSecurity";
afterEach(() => vi.unstubAllGlobals());
it("creates a nonce on HTTP where randomUUID does not exist", () => {
  vi.stubGlobal("crypto", {
    getRandomValues: (bytes: Uint8Array) => bytes.fill(7),
  });
  expect(previewNonce()).toBe("07".repeat(16));
});
it.each([
  ["SYNOLOGY-NOTE://REMOTE/note1", "synology-note://remote/note1"],
  ["synology-note://remote/한글", "synology-note://remote/%ED%95%9C%EA%B8%80"],
  [
    encodeURIComponent(
      "synology-note://note/12345678-1234-4321-ABCD-123456789ABC",
    ),
    "synology-note://note/12345678-1234-4321-abcd-123456789abc",
  ],
  [encodeURIComponent("synology-note://remote/note1"), null],
  ["synology-note://remote/n1?x=1", null],
  ["synology-note://remote/%QQ", null],
  ["javascript:alert(1)", null],
])("normalizes the same link forms as the backend: %s", (input, expected) => {
  expect(canonicalNoteLink(input)).toBe(expected);
});
