import DOMPurify from "dompurify";

// SVG presentation only. In particular, no resource-loading or page-layout CSS.
const PRESENTATION = new Set([
  "font-family", "font-size", "font-weight", "font-style", "line-height",
  "text-anchor", "text-align", "dominant-baseline", "alignment-baseline",
  "fill", "fill-opacity", "fill-rule", "color", "background-color",
  "stroke", "stroke-width", "stroke-opacity", "stroke-dasharray",
  "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
  "opacity", "paint-order", "shape-rendering", "vector-effect",
  "marker-start", "marker-mid", "marker-end", "rx", "ry",
  "display", "visibility", "width", "height", "max-width",
]);

export function safeSvgDeclarations(style: CSSStyleDeclaration): string {
  let result = "";
  for (let i = 0; i < style.length; i++) {
    const property = style.item(i);
    if (!PRESENTATION.has(property)) continue;
    const value = style.getPropertyValue(property).trim();
    if (!value || /[<>\\@]/.test(value) || /expression|var\s*\(/i.test(value)) continue;
    // Only fragment paints/markers may reference another SVG element.
    if (/url/i.test(value) && !/^url\(["']?#[a-zA-Z0-9_-]+["']?\)$/.test(value)) continue;
    result += `${property}:${value}${style.getPropertyPriority(property) === "important" ? "!important" : ""};`;
  }
  return result;
}

export function sanitizeMermaidSvg(source: string): string {
  // Parse inertly; never insert the generated stylesheet into the live page.
  const original = new DOMParser().parseFromString(source, "image/svg+xml");
  const container = document.createElement("div");
  container.innerHTML = DOMPurify.sanitize(source, {
    USE_PROFILES: { svg: true, svgFilters: true },
    FORBID_TAGS: ["style", "foreignObject", "image", "use"],
  });
  const svg = container.querySelector("svg");
  if (!svg || !/^synonote-[a-zA-Z0-9-]+$/.test(svg.id)) throw new Error("Invalid diagram SVG");
  for (const element of [svg, ...svg.querySelectorAll("*")]) {
    for (const attribute of Array.from(element.attributes)) {
      const externalLink = ["href", "xlink:href"].includes(attribute.name) && !attribute.value.startsWith("#");
      const resource = ["fill", "stroke", "filter", "clip-path", "mask", "marker-start", "marker-mid", "marker-end", "cursor"].includes(attribute.name);
      const externalPaint = resource && /url\s*\(/i.test(attribute.value) && !/^url\(["']?#[a-zA-Z0-9_-]+["']?\)$/.test(attribute.value);
      if (externalLink || externalPaint)
        element.removeAttribute(attribute.name);
    }
  }
  for (const element of [svg, ...svg.querySelectorAll<SVGElement>("[style]")]) {
    const css = safeSvgDeclarations(element.style);
    if (css) element.setAttribute("style", css);
    else element.removeAttribute("style");
  }
  let css = "";
  for (const style of original.querySelectorAll("style")) {
    // Constructable sheets parse CSS without executing @import or font loads.
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(style.textContent ?? "");
    for (const rule of sheet.cssRules) {
      if (rule.type !== CSSRule.STYLE_RULE) continue; // discard all at-rules
      const current = rule as CSSStyleRule;
      if (/[<>{}\\@]/.test(current.selectorText)) continue;
      const declarations = safeSvgDeclarations(current.style);
      if (!declarations) continue;
      // Scope even user classDef selectors to this SVG, including its root.
      css += `#${svg.id}:is(${current.selectorText}),#${svg.id} :is(${current.selectorText}){${declarations}}`;
    }
  }
  const style = document.createElementNS("http://www.w3.org/2000/svg", "style");
  style.textContent = css;
  svg.prepend(style);
  return container.innerHTML;
}
