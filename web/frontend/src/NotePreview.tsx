import { useEffect, useMemo, useRef, useState } from "react";
import { notifySessionExpired } from "./api";
import { previewNonce, canonicalNoteLink } from "./previewSecurity";
import DOMPurify from "dompurify";
import { sanitizeMermaidSvg } from "./mermaidSvg";
import { Marked, type TokensList } from "marked";
const marked = new Marked({ extensions: [{
  name: "mathSource", level: "inline",
  start: (source: string) => source.search(/\$|\\[([]/),
  tokenizer(source: string) {
    const match = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([^\n]*?)\\\)|\$(?![\s$])([^\n$]+?)(?<!\s)\$(?![\d$]))/.exec(source);
    if (!match) return;
    return { type: "mathSource", raw: match[0], tex: match.slice(1).find(v => v !== undefined)!, display: match[1] !== undefined || match[2] !== undefined };
  },
  renderer(token) {
    return `<span data-math-source="${encodeURIComponent(String(token.tex))}" data-math-display="${Boolean(token.display)}"></span>`;
  },
}] });
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
  sourceLine,
}: {
  onOpenLink?: (destination: string) => void;
  sourceLine?: number;
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
  const linkNonce = useRef(previewNonce());
  const linkEnabled = !!onOpenLink;
  const frameDocument = useMemo(() => {
    const nonce = linkNonce.current;
    return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; img-src data: blob:; font-src ${window.location.origin} data:; connect-src 'none'; form-action 'none'; base-uri 'none'"></head><body><script nonce="${nonce}">
      (() => {
        const nonce = '${nonce}';
        let revision = 0;
        const follow = line => {
          if (!Number.isFinite(line)) return;
          const nodes = [...document.querySelectorAll('[data-source-line]')];
          const target = nodes.reverse().find(node => Number(node.dataset.sourceLine) <= line);
          if (!target) return;
          const rect = target.getBoundingClientRect();
          if (rect.top < 24 || rect.top > innerHeight * 0.7)
            scrollTo({top: scrollY + rect.top - innerHeight * 0.3, behavior:'instant'});
        };
        window.addEventListener('message', async event => {
          if (event.source !== parent || event.data?.nonce !== nonce) return;
          if (event.data.kind === 'synonote:follow') { follow(event.data.line); return; }
          if (event.data.kind !== 'synonote:render' || typeof event.data.page !== 'string') return;
          const current = ++revision;
          const next = new DOMParser().parseFromString(event.data.page, 'text/html');
          // Keep fonts, scroll container and unchanged blocks mounted.
          const styles = [...next.head.querySelectorAll('style')].map(s => s.textContent).join('');
          let style = document.getElementById('preview-style');
          if (!style) { style = document.createElement('style'); style.id = 'preview-style'; document.head.append(style); }
          if (style.textContent !== styles) style.textContent = styles;
          await document.fonts.ready;
          await Promise.all([...next.images].map(img => img.decode().catch(() => {})));
          if (current !== revision) return;
          const offset = scrollY;
          const old = [...document.body.childNodes];
          const fresh = [...next.body.childNodes];
          let start = 0, end = 0;
          while (start < old.length && start < fresh.length && old[start].isEqualNode(fresh[start])) start++;
          while (end < old.length-start && end < fresh.length-start && old[old.length-1-end].isEqualNode(fresh[fresh.length-1-end])) end++;
          for (let i=start;i<old.length-end;i++) old[i].remove();
          const fragment = document.createDocumentFragment();
          fresh.slice(start, fresh.length-end).forEach(node => fragment.append(node));
          document.body.insertBefore(fragment, end ? old[old.length-end] : null);
          scrollTo(0, offset);
          follow(event.data.line);
        });
        document.addEventListener('click', event => {
          const link = event.target.closest?.('a');
          if (!link) return;
          const href = link.getAttribute('href') || '';
          if (link.hasAttribute('data-note-link')) {
            event.preventDefault();
            parent.postMessage({kind:'synonote:link', nonce, href}, '*');
          } else if (!href || href.startsWith('#')) {
            event.preventDefault();
            try { document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView(); } catch {}
          }
        }, true);
      })();
    </script></body></html>`;
  }, []);
  const latestLine = useRef(sourceLine);
  latestLine.current = sourceLine;
  useEffect(() => {
    if (frameReady.current) frame.current?.contentWindow?.postMessage({kind: "synonote:follow", nonce: linkNonce.current, line: sourceLine}, "*");
  }, [sourceLine]);
  const latestPage = useRef(page);
  latestPage.current = page;
  const frameReady = useRef(false);
  useEffect(() => {
    if (!page || !frameReady.current) return;
    frame.current?.contentWindow?.postMessage({ kind: "synonote:render", nonce: linkNonce.current, page, line: latestLine.current }, "*");
  }, [page]);
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
    const nonce = linkNonce.current;
    async function render() {
      let source = html;
      if (markdown !== undefined) {
        const tokens = marked.lexer(markdown);
        let line = 1;
        source = tokens.map(token => {
          const start = line;
          line += (token.raw.match(/\n/g) ?? []).length;
          const list = [token] as TokensList; list.links = tokens.links;
          return `<div data-source-line="${start}">${marked.parser(list)}</div>`;
        }).join("");
      }
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
              const scratch = document.createElement("div");
              scratch.style.cssText = "position:fixed;left:-100000px;top:0;width:800px;visibility:hidden;pointer-events:none";
              document.body.append(scratch);
              try {
                const result = await mermaid.render(`synonote-${id}-${index}-${previewNonce()}`, code.textContent ?? "", scratch);
                return sanitizeMermaidSvg(result.svg);
              } finally { scratch.remove(); }
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
      for (const span of body.querySelectorAll<HTMLElement>("span[data-math-source]")) {
        let tex: string;
        try { tex = decodeURIComponent(span.dataset.mathSource!); } catch { continue; }
        span.innerHTML = katex.renderToString(tex, {
          displayMode: span.dataset.mathDisplay === "true", throwOnError: false, trust: false, output: "html",
        });
        span.removeAttribute("data-math-source");
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
        const href = a.getAttribute("href") ?? "";
        const internal = canonicalNoteLink(href);
        if (internal) a.setAttribute("data-note-link", "true");
        else a.removeAttribute("data-note-link");
        if (internal || !href || href.startsWith('#')) a.removeAttribute("target");
        else a.setAttribute("target", "_blank");
        a.setAttribute("rel", "noreferrer noopener");
      }
      const csp = `default-src 'none'; script-src ${linkEnabled ? `'nonce-${nonce}'` : "'none'"}; connect-src 'none'; form-action 'none'; base-uri 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src ${window.location.origin} data:`;
      const css = `html{overflow-y:scroll;scrollbar-gutter:stable;overflow-anchor:none} :root{color-scheme:${dark ? "dark" : "light"}}body{margin:24px;font:15px/1.75 -apple-system,BlinkMacSystemFont,sans-serif;color:${dark ? "#eee" : "#222"};overflow-wrap:anywhere}pre,code{font-family:ui-monospace,monospace}pre{padding:14px;background:${dark ? "#292929" : "#f4f5f7"};border-radius:6px;white-space:pre-wrap}img,svg{max-width:100%;height:auto}.mermaid{text-align:center;overflow:auto}table{border-collapse:collapse}td,th{border:1px solid #888;padding:6px 10px}blockquote{border-left:3px solid #888;margin-left:0;padding-left:16px}a{color:#3989e8}.diagram-error{color:#c75c49}`;
      const fonts = `<style>${katexCss}</style>`;
      if (active)
        setPage(
          `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}">${fonts}<style>${css}</style></head><body>${body.innerHTML}</body></html>`,
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
      sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox"
      referrerPolicy="no-referrer"
      className="note-preview"
      srcDoc={frameDocument}
      onLoad={() => {
        frameReady.current = true;
        if (latestPage.current)
          frame.current?.contentWindow?.postMessage({ kind: "synonote:render", nonce: linkNonce.current, page: latestPage.current, line: latestLine.current }, "*");
      }}
    />
  );
}
