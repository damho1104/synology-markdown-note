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
