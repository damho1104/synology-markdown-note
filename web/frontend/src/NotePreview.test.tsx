// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { NotePreview } from "./NotePreview";
afterEach(cleanup);
async function renderedPage(frame: HTMLIFrameElement): Promise<string> {
  const send = vi.fn();
  Object.defineProperty(frame.contentWindow, "postMessage", { configurable: true, value: send });
  fireEvent.load(frame);
  await waitFor(() => expect(send).toHaveBeenCalled());
  return send.mock.calls.at(-1)![0].page as string;
}
it.each([
  ["---\nname: '<img src=x onerror=alert(1)>'\nformula: $x$\n---\n\n# 본문\n\n문단", 6, 8],
  ["\uFEFF---\r\nname: BOM\r\n...\r\n\r\n# 본문\r\n\r\n문단", 5, 7],
  ["---\rname: CR\r---\r\r# 본문\r\r문단", 5, 7],
])("folds leading metadata like the Mac preview: %s", async (markdown, headingLine, paragraphLine) => {
  render(<NotePreview html="" markdown={markdown} />);
  const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
  const doc = new DOMParser().parseFromString(source, "text/html");
  const details = doc.querySelector("details.note-frontmatter");
  expect(details).not.toBeNull();
  expect(details!.hasAttribute("open")).toBe(false);
  expect(details!.querySelector("summary")?.textContent).toBe("문서 정보");
  expect(details!.querySelector("code")?.textContent).toContain("name:");
  expect(details!.querySelector("img, .katex")).toBeNull();
  if (markdown.includes("formula:")) {
    expect(details!.querySelector("code")?.textContent).toContain("<img src=x onerror=alert(1)>");
    expect(details!.querySelector("code")?.textContent).toContain("formula: $x$");
  }
  expect(doc.querySelector("h1")?.textContent).toBe("본문");
  expect(doc.querySelector("h1")?.parentElement?.getAttribute("data-source-line")).toBe(String(headingLine));
  expect(doc.querySelector("p")?.parentElement?.getAttribute("data-source-line")).toBe(String(paragraphLine));
  expect(doc.querySelector("hr")).toBeNull();
});

it.each([
  "---\ntype: daily\n# 종료 없는 문서",
  "# 본문\n\n---\ntype: daily\n---",
  "```yaml\n---\ntype: daily\n---\n```",
  "\n---\ntype: daily\n---",
])("does not fold incomplete or non-leading metadata: %s", async markdown => {
  render(<NotePreview html="" markdown={markdown} />);
  const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
  const doc = new DOMParser().parseFromString(source, "text/html");
  expect(doc.querySelector("details.note-frontmatter")).toBeNull();
  expect(doc.body.textContent).toContain("type: daily");
});

it("blocks untrusted scripts, events and external images without enabling iframe scripts", async () => {
  render(
    <NotePreview
      html={
        '<h2>Safe</h2><script>alert(1)</script><img src="https://evil.example/x" onerror="alert(1)"><iframe src="https://evil.example"></iframe>'
      }
    />,
  );
  const frame = screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement;
  const source = await renderedPage(frame);
  expect(source).not.toContain("https://evil.example");
  expect(source).not.toContain("onerror");
  expect(source).not.toContain("<script");
  expect(source).not.toContain("<iframe");
  expect(frame.getAttribute("sandbox")).toBe("allow-scripts allow-popups allow-popups-to-escape-sandbox");
  expect(source).toContain("script-src 'none'");
  expect(source).toContain("img-src data: blob:");
});
it("renders formulas while preserving code blocks as literal text", async () => {
  render(<NotePreview html="" markdown={"$E=mc^2$\n\n```text\n$x$\n```"} />);
  const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
  expect(source).toContain('class="katex"');
  expect(source).toContain("$x$\n</code>");
});

it("loads bound attachment images only through the authenticated local API", async () => {
  const { vi } = await import("vitest");
  const fetcher = vi.fn(
    async (_path: string, _init?: RequestInit) =>
      new Response(new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])),
  );
  vi.stubGlobal("fetch", fetcher);
  try {
    render(
      <NotePreview
        html={'<img ref="uuid1"><img src="https://evil.example/image">'}
        noteId="note1"
        version="v1"
        attachments={[{ id: "file1", ref: "uuid1", name: "photo.png" }]}
      />,
    );
    const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
    expect(source).toContain("data:image/png;base64,");
    expect(fetcher).toHaveBeenCalledOnce();
    expect(fetcher.mock.calls[0][0]).toBe("/api/notes/note1/attachments/file1");
  } finally {
    vi.unstubAllGlobals();
  }
});

it("forwards internal note links only from its own nonce-protected preview", async () => {
  const { vi } = await import("vitest");
  vi.stubGlobal("crypto", {
    getRandomValues: (bytes: Uint8Array) => bytes.fill(1),
  });
  const open = vi.fn();
  try {
    render(
      <NotePreview
        html={
          '<a href="synology-note://remote/note1">linked</a><script>bad()</script>'
        }
        onOpenLink={open}
      />,
    );
    const frame = screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement;
    const source = await renderedPage(frame);
    expect(source).toContain("synology-note://remote/note1");
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts allow-popups allow-popups-to-escape-sandbox");
    expect(source).not.toContain("bad()");
    const data = {
      kind: "synonote:link",
      nonce: "01".repeat(16),
      href: "synology-note://remote/note1",
    };
    window.dispatchEvent(new MessageEvent("message", { source: window, data }));
    expect(open).not.toHaveBeenCalled();
    window.dispatchEvent(
      new MessageEvent("message", {
        source: frame.contentWindow,
        data: { ...data, href: "https://evil.example" },
      }),
    );
    expect(open).not.toHaveBeenCalled();
    window.dispatchEvent(
      new MessageEvent("message", { source: frame.contentWindow, data }),
    );
    expect(open).toHaveBeenCalledWith("synology-note://remote/note1");
  } finally {
    vi.unstubAllGlobals();
  }
});

it.each([
  ["SYNOLOGY-NOTE://REMOTE/note1", "synology-note://remote/note1"],
  [
    encodeURIComponent(
      "synology-note://note/12345678-1234-4321-ABCD-123456789ABC",
    ),
    "synology-note://note/12345678-1234-4321-abcd-123456789abc",
  ],
])(
  "retains and normalizes supported note links in sanitized output: %s",
  async (input, expected) => {
    render(<NotePreview html={`<a href="${input}">linked</a>`} />);
    const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
    expect(source).toContain(`href="${expected}"`);
  },
);

it("keeps the iframe document mounted while sending edited preview content", async () => {
  const view = render(<NotePreview html="" markdown="first" />);
  const frame = screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement;
  const initialDocument = frame.getAttribute("srcdoc");
  const send = vi.fn();
  Object.defineProperty(frame.contentWindow, "postMessage", { configurable: true, value: send });
  fireEvent.load(frame);
  await waitFor(() => expect(send).toHaveBeenCalled());
  send.mockClear();
  view.rerender(<NotePreview html="" markdown="edited" />);
  await waitFor(() => expect(send).toHaveBeenCalled());
  expect(frame.getAttribute("srcdoc")).toBe(initialDocument);
  expect(send.mock.calls.at(-1)![0].page).toContain("edited");
});


it("preserves TeX escapes and subscripts before Markdown parsing", async () => {
  render(<NotePreview html="" markdown={String.raw`분수 \(\frac{a_1}{b_2}\) 그리고 $x_i^2$`} />);
  const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
  expect(source).toContain('class="mfrac"');
  expect(source).toContain('class="msupsub"');
  expect(source).not.toContain('data-math-source');
});


it("maps preview blocks to source lines and follows selection without rerendering content", async () => {
  const view = render(<NotePreview html="" markdown={"# First\n\nParagraph\n\n```text\nliteral\n```\n"} sourceLine={1} />);
  const frame = screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement;
  const source = await renderedPage(frame);
  expect(source).toContain('data-source-line="3"');
  expect(source).toContain('data-source-line="5"');
  const initial = frame.getAttribute("srcdoc");
  const send = vi.fn();
  Object.defineProperty(frame.contentWindow, "postMessage", {configurable: true, value: send});
  view.rerender(<NotePreview html="" markdown={"# First\n\nParagraph\n\n```text\nliteral\n```\n"} sourceLine={5} />);
  await waitFor(() => expect(send).toHaveBeenCalledWith(expect.objectContaining({kind: "synonote:follow", line: 5}), "*"));
  expect(frame.getAttribute("srcdoc")).toBe(initial);
  expect(send.mock.calls.every(([message]) => message.kind === "synonote:follow")).toBe(true);
});


it("marks readable Markdown filenames as internal note links without accepting paths", async () => {
  render(<NotePreview html={'<a href="한글%20노트.md">internal</a><a href="folder/note.md">path</a>'} onOpenLink={() => {}} />);
  const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
  const doc = new DOMParser().parseFromString(source, 'text/html');
  expect(doc.querySelector('[data-note-link]')!.getAttribute('href')).toBe(encodeURIComponent('한글 노트.md'));
  expect(doc.querySelectorAll('[data-note-link]')).toHaveLength(1);
});

it('opens external links outside the preview and keeps internal/fragment links in its own bridge',async()=>{
  render(<NotePreview html='<a href="https://example.com">outside</a><a href="#section">section</a><h2 id="section">Heading</h2><a href="synology-note://remote/n1">note</a>' onOpenLink={()=>{}} />)
  const frame=screen.getByTitle('노트 HTML 미리보기') as HTMLIFrameElement
  const source=await renderedPage(frame)
  const doc=new DOMParser().parseFromString(source,'text/html')
  expect(doc.querySelector('a[href="https://example.com"]')?.getAttribute('target')).toBe('_blank')
  expect(doc.querySelector('a[href="#section"]')?.hasAttribute('target')).toBe(false)
  expect(doc.querySelector('[data-note-link]')?.hasAttribute('target')).toBe(false)
  expect(frame.getAttribute('sandbox')).toContain('allow-popups-to-escape-sandbox')
})

it("renders staged images and resolves staged and saved download links from verified attachments", async () => {
  const stage = "/api/drafts/d/uploads/i/content";
  const download = "/api/drafts/d/uploads/p/content";
  const fetcher = vi.fn(async () => new Response(new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])));
  vi.stubGlobal("fetch", fetcher);
  vi.stubGlobal("crypto", {getRandomValues: (bytes: Uint8Array) => bytes.fill(1)});
  const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  try {
    render(<NotePreview html="" markdown={
      "![image](attachment://image) [staged](attachment://pdf) [saved](attachment://saved) [unbound](attachment://unknown)"
    } noteId="note1" stagedImages={{image:stage}} stagedDownloads={{pdf:download}}
      attachments={[{id:"file1", name:"saved.pdf", ref:null}]} bindings={{saved:"file1"}} />);
    const frame = screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement;
    const source = await renderedPage(frame);
    expect(source).toContain("data:image/png;base64,");
    expect(fetcher).toHaveBeenCalledWith(stage, {credentials:"same-origin", cache:"no-store"});
    const links = [...new DOMParser().parseFromString(source, "text/html").querySelectorAll("a")];
    expect(links.map(link => link.getAttribute("href"))).toEqual([download, "/api/notes/note1/attachments/file1", null]);
    const send = (href: string) => window.dispatchEvent(new MessageEvent("message", {
      source: frame.contentWindow,
      data: {kind:"synonote:attachment", nonce:"01".repeat(16), href},
    }));
    send("/api/notes/other/attachments/file1");
    expect(click).not.toHaveBeenCalled();
    send(download);
    expect(click).toHaveBeenCalledOnce();
    expect((click.mock.contexts[0] as HTMLAnchorElement).getAttribute("href")).toBe(download);
  } finally {
    click.mockRestore();
    vi.unstubAllGlobals();
  }
});

it("keeps a saved download-only attachment out of inline image recognition", async () => {
  const fetcher = vi.fn(async () => new Response(new Uint8Array([137, 80, 78, 71])));
  vi.stubGlobal("fetch", fetcher);
  try {
    render(<NotePreview html="" markdown="![forced image](attachment://file) [download](attachment://file)"
      noteId="note1" attachments={[{id:"file1", name:"synology-note-attachment-file-fixture.png", ref:"file"}]} />);
    const source = await renderedPage(screen.getByTitle("노트 HTML 미리보기") as HTMLIFrameElement);
    expect(fetcher).not.toHaveBeenCalled();
    expect(source).not.toContain("data:image/png");
    expect(source).toContain('href="/api/notes/note1/attachments/file1"');
  } finally {
    vi.unstubAllGlobals();
  }
});
