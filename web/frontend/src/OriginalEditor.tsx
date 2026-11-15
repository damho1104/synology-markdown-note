import { useLayoutEffect, useRef } from "react";
import DOMPurify from "dompurify";
export type TextChange = { index: number; text: string };
const safeHtml = (html: string) =>
  DOMPurify.sanitize(html, {
    FORBID_TAGS: ["script", "style", "iframe", "form", "object", "embed"],
    FORBID_ATTR: ["contenteditable", "src", "srcset", "style"],
  });
function editableText(node: Node): string {
  let value = "";
  Array.from(node.childNodes).forEach((child, index) => {
    if (child.nodeType === Node.TEXT_NODE) {
      value += child.textContent ?? "";
      return;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) return;
    const tag = (child as Element).tagName;
    if (tag === "BR") {
      value += "\n";
      return;
    }
    if (["DIV", "P"].includes(tag) && index > 0 && !value.endsWith("\n"))
      value += "\n";
    const emptyBlock =
      ["DIV", "P"].includes(tag) &&
      child.childNodes.length === 1 &&
      (child.firstChild as Element)?.nodeName === "BR";
    if (!emptyBlock) value += editableText(child);
  });
  return value;
}
export function OriginalEditor({
  html,
  token,
  blocks,
  changes,
  editable,
  onChange,
}: {
  html: string;
  token: string;
  blocks: TextChange[];
  changes: TextChange[];
  editable: boolean;
  dark: boolean;
  onChange: (change: TextChange) => void;
}) {
  const root = useRef<HTMLDivElement>(null);
  const latest = useRef({ changes, blocks, onChange });
  latest.current = { changes, blocks, onChange };
  useLayoutEffect(() => {
    const container = root.current!;
    container.innerHTML = safeHtml(html);
    const allowed = Array.from(
      container.querySelectorAll<HTMLElement>(`[data-edit-token="${token}"]`),
    );
    for (const node of allowed) {
      const index = Number(node.dataset.textIndex);
      if (!latest.current.blocks.some((b) => b.index === index)) continue;
      node.contentEditable = editable ? "plaintext-only" : "false";
      const changed = latest.current.changes.find((v) => v.index === index);
      if (changed) node.textContent = changed.text;
    }
    // Native input runs synchronously in the same document as Save/navigation.
    // No iframe messages or debounced copy can drop the last typed character.
    const input = (event: Event) => {
      const node = (event.target as HTMLElement).closest<HTMLElement>(
        `[data-edit-token="${token}"]`,
      );
      if (!editable || !node || !container.contains(node)) return;
      const index = Number(node.dataset.textIndex);
      if (latest.current.blocks.some((b) => b.index === index))
        latest.current.onChange({ index, text: editableText(node) });
    };
    container.addEventListener("input", input);
    return () => container.removeEventListener("input", input);
  }, [html, token, editable]);
  return (
    <div
      ref={root}
      role="textbox"
      aria-label="원본 HTML 편집기"
      aria-multiline="true"
      aria-readonly={!editable}
      className="original-text-editor"
      onPaste={(event) => {
        event.preventDefault();
        if (!editable) return;
        const node = (event.target as HTMLElement).closest<HTMLElement>(
          `[data-edit-token="${token}"]`,
        );
        const selection = window.getSelection();
        if (!node || !selection?.rangeCount) return;
        const range = selection.getRangeAt(0);
        if (
          !node.contains(range.startContainer) ||
          !node.contains(range.endContainer)
        )
          return;
        const text = event.clipboardData.getData("text/plain");
        if (
          typeof document.execCommand === "function" &&
          document.execCommand("insertText", false, text)
        )
          return;
        range.deleteContents();
        const inserted = document.createTextNode(text);
        range.insertNode(inserted);
        range.setStartAfter(inserted);
        range.collapse(true);
        selection.removeAllRanges();
        selection.addRange(range);
        node.dispatchEvent(new Event("input", { bubbles: true }));
      }}
      onDrop={(event) => event.preventDefault()}
      onClick={(event) => {
        if ((event.target as HTMLElement).closest("a")) event.preventDefault();
      }}
    />
  );
}
export function changedHtmlPreview(
  html: string,
  token: string,
  changes: TextChange[],
): string {
  const container = document.createElement("div");
  container.innerHTML = safeHtml(html);
  for (const change of changes) {
    const node = container.querySelector(
      `[data-edit-token="${token}"][data-text-index="${change.index}"]`,
    );
    if (node) node.textContent = change.text;
  }
  return container.innerHTML;
}
