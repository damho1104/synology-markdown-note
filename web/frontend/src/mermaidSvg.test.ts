// @vitest-environment jsdom
import { expect, it } from "vitest";
import { safeSvgDeclarations, sanitizeMermaidSvg } from "./mermaidSvg";

it("keeps label alignment, fonts and readable colors while dropping resource and page layout styles", () => {
  const node = document.createElement("div");
  node.style.cssText = 'text-anchor:middle;font-family:Arial,sans-serif;font-size:16px;fill:#eee;stroke:#abc;position:fixed;opacity:0.7;cursor:url(https://evil.example/a),auto;filter:url(https://evil.example/a);background-image:url(https://evil.example/a)';
  const css = safeSvgDeclarations(node.style);
  expect(css).toContain("text-anchor:middle;");
  expect(css).toContain("font-size:16px;");
  expect(css).toContain("opacity:0.7;");
  expect(css).toContain("fill:");
  expect(css).not.toMatch(/evil|position|cursor|filter|background-image/);
});

it("keeps local marker references and rejects external or escaped SVG paint URLs", () => {
  const node = document.createElement("div");
  node.style.cssText = 'marker-end:url(#arrow);fill:url(https://evil.example/a);stroke:url("data:image/svg+xml,evil")';
  const css = safeSvgDeclarations(node.style);
  expect(css).toContain("marker-end:url(#arrow);");
  expect(css).not.toMatch(/fill|stroke|evil/);
});

it("removes active content and external SVG resource attributes", () => {
  const svg = sanitizeMermaidSvg(`<svg xmlns="http://www.w3.org/2000/svg" id="synonote-test"><script>bad()</script><foreignObject>bad</foreignObject><image href="https://evil.example/img"/><use href="https://evil.example/icon"/><rect onclick="bad()" fill="url(https://evil.example/paint)" filter="url(https://evil.example/filter)"/><path marker-end="url(#arrow)"/></svg>`);
  expect(svg).not.toMatch(/evil|onclick|foreignObject|<script|<image|<use/);
  expect(svg).toContain('marker-end="url(#arrow)"');
});
