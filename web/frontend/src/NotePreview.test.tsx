// @vitest-environment jsdom
import { afterEach, expect, it } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { NotePreview } from "./NotePreview";
afterEach(cleanup);
it("blocks untrusted scripts, events and external images without enabling iframe scripts", async () => {
  render(
    <NotePreview
      html={
        '<h2>Safe</h2><script>alert(1)</script><img src="https://evil.example/x" onerror="alert(1)"><iframe src="https://evil.example"></iframe>'
      }
    />,
  );
  await waitFor(() =>
    expect(
      screen.getByTitle("노트 HTML 미리보기").getAttribute("srcdoc"),
    ).toContain("<h2>Safe</h2>"),
  );
  const frame = screen.getByTitle("노트 HTML 미리보기");
  const source = frame.getAttribute("srcdoc")!;
  expect(source).not.toContain("https://evil.example");
  expect(source).not.toContain("onerror");
  expect(source).not.toContain("<script");
  expect(source).not.toContain("<iframe");
  expect(frame.getAttribute("sandbox")).toBe("");
  expect(source).toContain("script-src 'none'");
  expect(source).toContain("img-src data: blob:");
});
it("renders formulas while preserving code blocks as literal text", async () => {
  render(<NotePreview html="" markdown={"$E=mc^2$\n\n```text\n$x$\n```"} />);
  await waitFor(() =>
    expect(
      screen.getByTitle("노트 HTML 미리보기").getAttribute("srcdoc"),
    ).toContain('class="katex"'),
  );
  expect(
    screen.getByTitle("노트 HTML 미리보기").getAttribute("srcdoc"),
  ).toContain("$x$\n</code>");
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
    await waitFor(() =>
      expect(
        screen.getByTitle("노트 HTML 미리보기").getAttribute("srcdoc"),
      ).toContain("data:image/png;base64,"),
    );
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
    await waitFor(() =>
      expect(frame.getAttribute("srcdoc")).toContain(
        "synology-note://remote/note1",
      ),
    );
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts");
    expect(frame.getAttribute("srcdoc")).not.toContain("bad()");
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
    await waitFor(() =>
      expect(
        screen.getByTitle("노트 HTML 미리보기").getAttribute("srcdoc"),
      ).toContain(`href="${expected}"`),
    );
  },
);
