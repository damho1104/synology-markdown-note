// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { OriginalEditor, changedHtmlPreview } from "./OriginalEditor";
afterEach(cleanup);

it("uses accessible icon buttons and lets a compact toolbar reveal its secondary commands", () => {
  render(<OriginalEditor html="<p>Sample</p>" token="token" blocks={[]} changes={[]} editable
    dark={false} onChange={vi.fn()} onStructureEdit={vi.fn()} onAttach={vi.fn()} />);
  const bold = screen.getByRole("button", {name:"굵게"});
  expect(bold.textContent).toBe("");
  expect(bold.querySelector("svg[aria-hidden=true]")).toBeTruthy();
  const more = screen.getByRole("button", {name:"편집 도구 더보기"});
  const secondary = document.getElementById(more.getAttribute("aria-controls")!);
  expect(secondary?.contains(screen.getByRole("button", {name:"가운데 정렬"}))).toBe(true);
  expect(more.getAttribute("aria-expanded")).toBe("false");
  fireEvent.click(more);
  expect(more.getAttribute("aria-expanded")).toBe("true");
  fireEvent.click(more);
  expect(more.getAttribute("aria-expanded")).toBe("false");
});

it("preserves formatting in preview and escapes edited text", () => {
  expect(
    changedHtmlPreview(
      '<p class="nas"><span data-edit-token="token" data-text-index="0">old</span></p>',
      "token",
      [{ index: 0, text: "new <safe>" }],
    ),
  ).toContain(
    '<p class="nas"><span data-edit-token="token" data-text-index="0">new &lt;safe&gt;</span></p>',
  );
});
it("accepts text changes synchronously only for known source blocks and strips original executable markup", () => {
  const change = vi.fn();
  const { container } = render(
    <OriginalEditor
      html={
        '<p><span data-edit-token="token" data-text-index="0">old</span><span data-edit-token="token" data-text-index="99">fake</span></p><script>bad()</script>'
      }
      token="token"
      blocks={[{ index: 0, text: "old" }]}
      changes={[]}
      editable
      dark={false}
      onChange={change}
    />,
  );
  expect(container.querySelector("script")).toBeNull();
  const editor = screen.getByRole("textbox", { name: "본문 편집기" });
  const fake = editor.querySelector('[data-text-index="99"]')!;
  fireEvent.input(fake);
  expect(change).not.toHaveBeenCalled();
  const allowed = editor.querySelector('[data-text-index="0"]')!;
  allowed.textContent = "new";
  fireEvent.input(allowed);
  expect(change).toHaveBeenCalledWith({ index: 0, text: "new" });
});

it.each(["first<div>last</div>", "first<br>last"])(
  "retains DOM line breaks instead of joining words: %s",
  (html) => {
    const change = vi.fn();
    render(
      <OriginalEditor
        html={'<span data-edit-token="token" data-text-index="0">old</span>'}
        token="token"
        blocks={[{ index: 0, text: "old" }]}
        changes={[]}
        editable
        dark={false}
        onChange={change}
      />,
    );
    const node = screen
      .getByRole("textbox", { name: "본문 편집기" })
      .querySelector('[data-text-index="0"]')!;
    node.innerHTML = html;
    fireEvent.input(node);
    expect(change).toHaveBeenCalledWith({ index: 0, text: "first\nlast" });
  },
);


it("sends a formatting range and table coordinates for the original HTML", () => {
  const edit = vi.fn();
  render(<OriginalEditor html={'<table data-structure-token="token" data-table-index="1"><tr><td data-table-index="99" data-structure-token="token" data-table-row="0" data-table-column="0"><span data-edit-token="token" data-text-index="3">A &amp; B</span></td></tr></table>'}
    token="token" blocks={[{index:3,text:"A & B"}]} changes={[]} editable dark={false}
    onChange={vi.fn()} onStructureEdit={edit} />);
  const span = screen.getByRole("textbox").querySelector("span")!;
  const range = document.createRange();
  range.setStart(span.firstChild!, 2); range.setEnd(span.firstChild!, 3);
  const selection = window.getSelection()!;
  selection.removeAllRanges(); selection.addRange(range);
  fireEvent(document, new Event("selectionchange"));
  fireEvent.click(screen.getByRole("button", {name:"굵게"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"bold", index:3, start:2, end:3});
  fireEvent.click(screen.getByRole("button", {name:"아래 첨자"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"subscript", index:3, start:2, end:3});
  fireEvent.click(screen.getByRole("button", {name:"위 첨자"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"superscript", index:3, start:2, end:3});
  fireEvent.change(screen.getByRole("combobox", {name:"글꼴"}), {target:{value:"Georgia"}});
  expect(edit).toHaveBeenLastCalledWith({kind:"font_family", value:"Georgia", index:3, start:2, end:3});
  fireEvent.change(screen.getByRole("combobox", {name:"글자 크기"}), {target:{value:"24"}});
  expect(edit).toHaveBeenLastCalledWith({kind:"font_size", value:"24", index:3, start:2, end:3});
  fireEvent.change(screen.getByLabelText("글자 색"), {target:{value:"#112233"}});
  expect(edit).toHaveBeenLastCalledWith({kind:"text_color", value:"#112233", index:3, start:2, end:3});
  fireEvent.change(screen.getByRole("combobox", {name:"문단"}), {target:{value:"h2"}});
  expect(edit).toHaveBeenLastCalledWith({kind:"paragraph", value:"h2", index:3});
  fireEvent.click(screen.getByRole("button", {name:"가운데 정렬"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"align", value:"center", index:3});
  fireEvent.click(screen.getByRole("button", {name:"체크리스트"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"list", value:"check", index:3});
  fireEvent.click(screen.getByRole("button", {name:"들여쓰기"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"indent", index:3});
  fireEvent.click(span);
  fireEvent.click(screen.getByRole("button", {name:"아래에 행 추가"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"row_after", index:1, row:0, column:0});
  vi.spyOn(window, "prompt").mockReturnValueOnce("3x4");
  fireEvent.click(screen.getByRole("button", {name:"본문 끝에 표 추가"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"insert_table", rows:3, columns:4});
  vi.restoreAllMocks();
});

it("renders supported inline styles without restoring unrelated styles", () => {
  render(<OriginalEditor html={'<p style="color:#112233; background-image:url(https://example.com/a); font-size:24px">Sample</p>'}
    token="token" blocks={[]} changes={[]} editable dark={false} onChange={vi.fn()} />);
  const p = screen.getByRole("textbox").querySelector("p")!;
  expect(p.style.color).toBe("rgb(17, 34, 51)");
  expect(p.style.fontSize).toBe("24px");
  expect(p.style.backgroundImage).toBe("");
});

it("offers attachment selection and invokes only available history commands", () => {
  const attach = vi.fn(), undo = vi.fn(), redo = vi.fn();
  render(<OriginalEditor html="<p>Sample</p>" token="token" blocks={[]} changes={[]} editable
    dark={false} onChange={vi.fn()} onStructureEdit={vi.fn()} onAttach={attach} onUndo={undo} onRedo={redo} canUndo />);
  fireEvent.click(screen.getByRole("button", {name:"첨부"}));
  fireEvent.click(screen.getByRole("button", {name:"실행 취소"}));
  fireEvent.click(screen.getByRole("button", {name:"다시 실행"}));
  expect(attach).toHaveBeenCalledTimes(1);
  expect(undo).toHaveBeenCalledTimes(1);
  expect(redo).not.toHaveBeenCalled();
});

it("opens a web link on a modified click without interrupting ordinary text selection", () => {
  const open = vi.spyOn(window, "open").mockImplementation(() => null);
  try {
    render(<OriginalEditor html={'<p><a href="https://example.com/">Sample</a></p>'}
      token="token" blocks={[]} changes={[]} editable dark={false} onChange={vi.fn()} />);
    const link = screen.getByRole("link", {name:"Sample"});
    fireEvent.click(link);
    expect(open).not.toHaveBeenCalled();
    fireEvent.click(link, {ctrlKey:true});
    expect(open).toHaveBeenCalledWith("https://example.com/", "_blank", "noopener,noreferrer");
  } finally {
    open.mockRestore();
  }
});

it("looks up an existing image by its saved attachment reference", () => {
  const resolve = vi.fn(() => undefined);
  render(<OriginalEditor html={'<p><img ref="saved-photo" src="https://example.com/a.png" alt="Photo"></p>'}
    token="token" blocks={[]} changes={[]} editable dark={false} onChange={vi.fn()} attachmentPath={resolve} />);
  expect(resolve).toHaveBeenCalledWith("saved-photo");
  expect(screen.getByRole("img", {name:"Photo"}).getAttribute("src")).toBeNull();
});

it("keeps the live text node and caret when an autosave updates its baseline token", () => {
  const props = {blocks:[{index:0,text:"old"}],changes:[],editable:true,dark:false,onChange:vi.fn()};
  const view = render(<OriginalEditor {...props} html={'<p><span data-edit-token="one" data-text-index="0">old</span></p>'} token="one" />);
  const node = screen.getByRole('textbox').querySelector('[data-text-index="0"]')!;
  node.textContent = 'typed';
  const text = node.firstChild!;
  const range = document.createRange(); range.setStart(text,3); range.collapse(true);
  window.getSelection()!.removeAllRanges(); window.getSelection()!.addRange(range);
  view.rerender(<OriginalEditor {...props} blocks={[{index:0,text:"typed"}]} html={'<p><span data-edit-token="two" data-text-index="0">typed</span></p>'} token="two" />);
  expect(screen.getByRole('textbox').querySelector('[data-text-index="0"]')).toBe(node);
  expect(node.firstChild).toBe(text);
  expect(window.getSelection()!.anchorNode).toBe(text);
  expect(window.getSelection()!.anchorOffset).toBe(3);
  expect(node.getAttribute('data-edit-token')).toBe('two');
});

it("keeps the caret and loaded attachment on autosave and releases its URL on unmount", async () => {
  const originalUrl = globalThis.URL;
  const create = vi.fn(() => "blob:photo");
  const revoke = vi.fn();
  const png = Uint8Array.from([137, 80, 78, 71]).buffer;
  const fetchImage = vi.fn(async () => ({
    ok:true, blob:async () => ({slice:() => ({arrayBuffer:async () => png})}),
  }));
  vi.stubGlobal("URL", Object.assign(class extends originalUrl {}, {createObjectURL:create,revokeObjectURL:revoke}));
  vi.stubGlobal("fetch", fetchImage);
  try {
    const props = {changes:[],editable:true,dark:false,onChange:vi.fn()};
    const preview = (token: string, text: string) =>
      `<p><span data-edit-token="${token}" data-text-index="0">${text}</span><img ref="photo" alt="Photo"></p>`;
    const view = render(<OriginalEditor {...props} blocks={[{index:0,text:"old"}]}
      html={preview("one","old")} token="one" attachmentPath={() => "/photo"}/>);
    const image = screen.getByRole("img", {name:"Photo"});
    await waitFor(() => expect(image.getAttribute("src")).toBe("blob:photo"));
    const node = screen.getByRole("textbox").querySelector("[data-text-index='0']")!;
    node.textContent = "typed";
    const text = node.firstChild!;
    window.getSelection()!.collapse(text, 3);

    view.rerender(<OriginalEditor {...props} blocks={[{index:0,text:"typed"}]}
      html={preview("two","typed")} token="two" attachmentPath={() => "/photo"}/>);

    expect(screen.getByRole("img", {name:"Photo"})).toBe(image);
    expect(image.getAttribute("src")).toBe("blob:photo");
    expect(window.getSelection()!.anchorNode).toBe(text);
    expect(window.getSelection()!.anchorOffset).toBe(3);

    view.rerender(<OriginalEditor {...props} blocks={[{index:0,text:"typed"}]}
      html={preview("three","typed").replace("<p>","<h2>").replace("</p>","</h2>")}
      token="three" attachmentPath={() => "/photo"}/>);
    const replaced = screen.getByRole("img", {name:"Photo"});
    expect(replaced).not.toBe(image);
    expect(replaced.getAttribute("src")).toBe("blob:photo");
    expect(fetchImage).toHaveBeenCalledTimes(1);
    expect(revoke).not.toHaveBeenCalled();
    view.unmount();
    expect(revoke).toHaveBeenCalledExactlyOnceWith("blob:photo");
  } finally {
    cleanup();
    vi.unstubAllGlobals();
  }
});
