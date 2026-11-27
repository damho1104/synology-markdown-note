import { UiError } from "./i18n";
import katex from "katex";
import css from "katex/dist/katex.min.css?inline";
import { toPng } from "html-to-image";
import { request, jsonRequest } from "./api";

type Formula = { key: string; tex: string; display: boolean };
export async function exportMath(markdown: string, csrf: string) {
  const plan = await request<{ formulas: Formula[] }>("/api/math/plan", jsonRequest(
    { markdown, title: "math", notebook_id: "math" }, { "X-CSRF-Token": csrf }, "POST"));
  const result = [];
  for (const formula of new Map(plan.formulas.map(f => [f.key, f])).values()) {
    const host = document.createElement("div");
    const root = host.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = css;
    const node = document.createElement("div");
    node.style.cssText = "display:inline-block;padding:6px;background:white;color:#111;font-size:16px;width:max-content";
    katex.render(formula.tex, node, { displayMode: formula.display, throwOnError: false, trust: false });
    root.append(style, node);
    host.style.cssText = "position:fixed;left:-10000px;top:0;pointer-events:none";
    document.body.append(host);
    try {
      await document.fonts.ready;
      const width = Math.ceil(node.getBoundingClientRect().width);
      const height = Math.ceil(node.getBoundingClientRect().height);
      if (!width || !height || width > 2048 || height > 2048) throw new UiError("errors.equationImageTooLarge");
      // Embed KaTeX font files in the SVG before canvas conversion.
      const urls = [...new Set([...css.matchAll(/url\(["']?([^"')]+)["']?\)/g)].map(m => m[1]))];
      let fontEmbedCSS = css;
      for (const url of urls) {
        const response = await fetch(url);
        if (!response.ok) throw new UiError("errors.couldNotLoadEquationFonts");
        const blob = await response.blob();
        const data = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader(); reader.onload = () => resolve(String(reader.result)); reader.onerror = reject; reader.readAsDataURL(blob);
        });
        fontEmbedCSS = fontEmbedCSS.split(url).join(data);
      }
      const png = await toPng(node, { width, height, pixelRatio: 2, backgroundColor: "white", fontEmbedCSS });
      result.push({ key: formula.key, width, height, png: png.split(",")[1] });
    } finally { host.remove(); }
  }
  return result;
}
