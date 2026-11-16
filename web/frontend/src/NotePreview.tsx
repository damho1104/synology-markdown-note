import { useEffect, useRef, useState } from "react";
import { notifySessionExpired } from "./api";
import { previewNonce, canonicalNoteLink } from "./previewSecurity";
import DOMPurify from "dompurify";
import { sanitizeMermaidSvg } from "./mermaidSvg";
import { marked } from "marked";
import katex from "katex";
import katexCss from "katex/dist/katex.min.css?inline";
const EMPTY_BLOCKS: Block[] = [];
// Mermaid has global configuration and a shared render queue. Keep initialize
// and render together so a stale effect cannot render with newer preferences.
let diagramQueue: Promise<unknown> = Promise.resolve();
function queueDiagram<T>(render: () => Promise<T>): Promise<T> {
  const next = diagramQueue.then(render, render);
  diagramQueue = next.catch(() => {});
  return next;
}
// Strip resource URLs before assigning sanitized HTML to even a detached DOM.
DOMPurify.addHook("uponSanitizeAttribute", (node, data) => {
  const tag = node.nodeName.toLowerCase();
  if (tag === "a" && data.attrName === "href") {
    const canonical = canonicalNoteLink(data.attrValue);
    if (canonical) {
      node.setAttribute("href", canonical);
      data.attrValue = canonical;
      data.forceKeepAttr = true;
    }
  }
  if (
    tag === "img" &&
    data.attrName === "src" &&
    data.attrValue.startsWith("attachment://")
  )
    node.setAttribute("data-attachment-ref", data.attrValue.slice(13));
  if (
    data.attrName === "src" &&
    !/^data:image\/(png|jpeg|gif|webp);base64,/i.test(data.attrValue)
  )
    data.keepAttr = false;
  if (
    ["image", "use"].includes(tag) &&
    ["href", "xlink:href"].includes(data.attrName) &&
    !data.attrValue.startsWith("#")
  )
    data.keepAttr = false;
  if (
    data.attrName === "style" &&
    (/url|expression|@/i.test(data.attrValue) ||
      /[^a-zA-Z0-9 #.,%():;_\-]/.test(data.attrValue))
  )
    data.keepAttr = false;
});

type Block = { id: string; html: string; label: string };
export function NotePreview({
  html,
  markdown,
  blocks = EMPTY_BLOCKS,
  dark = false,
  mermaidStyle = "handDrawn",
  mermaidTheme = "system",
  noteId,
  version,
  attachments,
  bindings,
  onOpenLink,
}: {
  onOpenLink?: (destination: string) => void;
  html: string;
  markdown?: string;
  blocks?: Block[];
  dark?: boolean;
  mermaidStyle?: "classic" | "handDrawn";
  mermaidTheme?: "system" | "default" | "dark" | "neutral" | "forest";
  noteId?: string;
  version?: string;
  attachments?: { id: string; ref: string | null; name: string }[];
  bindings?: Record<string, string>;
}) {
  const [page, setPage] = useState("");
  const serial = useRef(0);
  const frame = useRef<HTMLIFrameElement>(null);
  const linkNonce = useRef("");
  const linkEnabled = !!onOpenLink;
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (
        event.source === frame.current?.contentWindow &&
        event.data?.kind === "synonote:link" &&
        event.data.nonce === linkNonce.current &&
        typeof event.data.href === "string" &&
        canonicalNoteLink(event.data.href)
      )
        onOpenLink?.(canonicalNoteLink(event.data.href)!);
    };
    window.addEventListener("message", receive);
    return () => window.removeEventListener("message", receive);
  }, [onOpenLink]);
  const images = useRef(new Map<string, string>());
  useEffect(() => {
    let active = true;
    const id = ++serial.current;
    const nonce = previewNonce();
    linkNonce.current = nonce;
    async function render() {
      let source = markdown === undefined ? html : await marked.parse(markdown);
      if (markdown !== undefined)
        for (const block of blocks)
          source = source.replace(
            `<p>:::synology-block ${block.id} :::</p>`,
            block.html,
          );
      const body = document.createElement("div");
      body.innerHTML = DOMPurify.sanitize(source, {
        FORBID_TAGS: ["style", "form", "iframe", "object", "embed", "script"],
        FORBID_ATTR: ["style", "srcset"],
        ADD_ATTR: ["ref"],
      });
      if (noteId && attachments)
        for (const img of body.querySelectorAll("img")) {
          const reference =
            img.getAttribute("ref") ?? img.getAttribute("data-attachment-ref");
          if (!reference) continue;
          const key = reference.toLowerCase();
          const bound = Object.entries(bindings ?? {}).find(
            ([id]) => id.toLowerCase() === key,
          )?.[1];
          const matches = attachments.filter((f) =>
            bound
              ? f.id === bound
              : f.id.toLowerCase() === key || f.ref?.toLowerCase() === key,
          );
          if (matches.length !== 1) continue;
          const file = matches[0];
          const cacheKey = `${noteId}:${version}:${file.id}`;
          try {
            let dataUrl = images.current.get(cacheKey);
            if (!dataUrl) {
              const response = await fetch(
                `/api/notes/${encodeURIComponent(noteId)}/attachments/${encodeURIComponent(file.id)}`,
                { credentials: "same-origin", cache: "no-store" },
              );
              if (response.status === 401) notifySessionExpired();
              if (!response.ok) continue;
              const bytes = await response.arrayBuffer();
              const head = new Uint8Array(
                bytes,
                0,
                Math.min(bytes.byteLength, 12),
              );
              const header = String.fromCharCode(...head);
              const mime =
                head[0] === 137 && header.slice(1, 4) === "PNG"
                  ? "image/png"
                  : head[0] === 255 && head[1] === 216
                    ? "image/jpeg"
                    : header.startsWith("GIF8")
                      ? "image/gif"
                      : header.startsWith("RIFF") && header.slice(8) === "WEBP"
                        ? "image/webp"
                        : null;
              if (!mime) continue;
              dataUrl = await new Promise<string>((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result as string);
                reader.onerror = reject;
                reader.readAsDataURL(new Blob([bytes], { type: mime }));
              });
              images.current.set(cacheKey, dataUrl);
            }
            img.setAttribute("src", dataUrl);
          } catch {
            /* Keep alternate text when an attachment cannot be read. */
          }
        }
      // Render diagrams outside the iframe, then keep only safe SVG presentation.
      const diagrams = Array.from(
        body.querySelectorAll("pre > code.language-mermaid"),
      );
      if (diagrams.length) {
        const { default: mermaid } = await import("mermaid");
        for (const [index, code] of diagrams.entries()) {
          try {
            const svg = await queueDiagram(async () => {
              if (!active) return null;
              mermaid.initialize({
                startOnLoad: false,
                securityLevel: "strict",
                htmlLabels: false,
                look: mermaidStyle,
                handDrawnSeed: 42,
                theme: mermaidTheme === "system" ? (dark ? "dark" : "default") : mermaidTheme,
                fontFamily: "Arial, sans-serif",
                fontSize: 16,
                suppressErrorRendering: true,
              });
              const result = await mermaid.render(
                `synonote-${id}-${index}-${previewNonce()}`,
                code.textContent ?? "",
              );
              return sanitizeMermaidSvg(result.svg);
            });
            if (!active || svg === null) return;
            const container = document.createElement("div");
            container.className = "mermaid";
            container.innerHTML = svg;
            code.parentElement?.replaceWith(container);
          } catch {
            const error = document.createElement("p");
            error.textContent = "Mermaid 문법을 확인하세요.";
            error.className = "diagram-error";
            code.parentElement?.before(error);
          }
        }
      }
      // Do not interpret formulas inside code blocks, links or preformatted HTML.
      const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
      const textNodes: Text[] = [];
      while (walker.nextNode()) {
        const node = walker.currentNode as Text;
        if (!node.parentElement?.closest("pre,code,svg,a"))
          textNodes.push(node);
      }
      for (const node of textNodes) {
        const text = node.textContent ?? "";
        const re = /\$\$([\s\S]+?)\$\$|(?<!\\)\$([^\n$]+?)\$/g;
        let last = 0;
        let match: RegExpExecArray | null;
        const fragment = document.createDocumentFragment();
        let changed = false;
        while ((match = re.exec(text))) {
          changed = true;
          fragment.append(text.slice(last, match.index));
          const span = document.createElement("span");
          span.innerHTML = katex.renderToString(match[1] ?? match[2], {
            displayMode: !!match[1],
            throwOnError: false,
            trust: false,
            output: "html",
          });
          fragment.append(span);
          last = re.lastIndex;
        }
        if (changed) {
          fragment.append(text.slice(last));
          node.replaceWith(fragment);
        }
      }
      for (const a of body.querySelectorAll("a")) {
        a.removeAttribute("target");
        a.setAttribute("rel", "noreferrer noopener");
      }
      const csp = `default-src 'none'; script-src ${linkEnabled ? `'nonce-${nonce}'` : "'none'"}; connect-src 'none'; form-action 'none'; base-uri 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src ${window.location.origin} data:`;
      const css = `:root{color-scheme:${dark ? "dark" : "light"}}body{margin:24px;font:15px/1.75 -apple-system,BlinkMacSystemFont,sans-serif;color:${dark ? "#eee" : "#222"};overflow-wrap:anywhere}pre,code{font-family:ui-monospace,monospace}pre{padding:14px;background:${dark ? "#292929" : "#f4f5f7"};border-radius:6px;white-space:pre-wrap}img,svg{max-width:100%;height:auto}.mermaid{text-align:center;overflow:auto}table{border-collapse:collapse}td,th{border:1px solid #888;padding:6px 10px}blockquote{border-left:3px solid #888;margin-left:0;padding-left:16px}a{color:#3989e8}.diagram-error{color:#c75c49}`;
      const fonts = `<style>${katexCss}</style>`;
      const linkScript = linkEnabled
        ? `<script nonce="${nonce}">document.addEventListener('click',event=>{const link=event.target.closest?.('a');const href=link?.getAttribute('href');if(href?.startsWith('synology-note://')){event.preventDefault();parent.postMessage({kind:'synonote:link',nonce:'${nonce}',href},${JSON.stringify(window.location.origin)})}})</script>`
        : "";
      if (active)
        setPage(
          `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}">${fonts}<style>${css}</style></head><body>${body.innerHTML}${linkScript}</body></html>`,
        );
    }
    void render();
    return () => {
      active = false;
    };
  }, [
    html,
    markdown,
    blocks,
    dark,
    mermaidStyle,
    mermaidTheme,
    noteId,
    version,
    attachments,
    bindings,
    linkEnabled,
  ]);
  return (
    <iframe
      ref={frame}
      title="노트 HTML 미리보기"
      sandbox={linkEnabled ? "allow-scripts" : ""}
      referrerPolicy="no-referrer"
      className="note-preview"
      srcDoc={page}
    />
  );
}
