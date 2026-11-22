// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { OriginalEditor, changedHtmlPreview } from "./OriginalEditor";
afterEach(cleanup);
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
  const editor = screen.getByRole("textbox", { name: "원본 HTML 편집기" });
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
      .getByRole("textbox", { name: "원본 HTML 편집기" })
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
  fireEvent.click(span);
  fireEvent.click(screen.getByRole("button", {name:"아래에 행 추가"}));
  expect(edit).toHaveBeenLastCalledWith({kind:"row_after", index:1, row:0, column:0});
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
