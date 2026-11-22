import { useLayoutEffect, useRef, useState } from "react";
import DOMPurify from "dompurify";
export type TextChange = { index: number; text: string };
const formats = {bold:"굵게", italic:"기울임", underline:"밑줄", strike:"취소선"} as const;
const tableCommands = {
  row_before:"위에 행 추가", row_after:"아래에 행 추가",
  column_before:"왼쪽에 열 추가", column_after:"오른쪽에 열 추가",
  delete_row:"행 삭제", delete_column:"열 삭제", delete_table:"표 삭제",
} as const;
type FormatKind = keyof typeof formats;
type TableKind = keyof typeof tableCommands;
type Selection = {index:number; start:number; end:number};
type TableCell = {index:number; row:number; column:number};
export type StructureEdit = ({kind:FormatKind} & Selection) | ({kind:TableKind} & TableCell)
  | {kind:"insert_table"};
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
  onStructureEdit,
  structureDisabled = false,
}: {
  html: string;
  token: string;
  blocks: TextChange[];
  changes: TextChange[];
  editable: boolean;
  dark: boolean;
  onChange: (change: TextChange) => void;
  onStructureEdit?: (edit: StructureEdit) => void;
  structureDisabled?: boolean;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [selection,setSelection] = useState<(Selection & {token:string}) | null>(null);
  const [cell,setCell] = useState<(TableCell & {token:string}) | null>(null);
  const selected = selection?.token === token ? selection : null;
  const selectedCell = cell?.token === token ? cell : null;
  const latest = useRef({ changes, blocks, onChange });
  latest.current = { changes, blocks, onChange };
  useLayoutEffect(() => {
    const container = root.current!;
    const next = document.createElement("div");
    next.innerHTML = safeHtml(html);
    const structure = (value: HTMLElement) => {
      const clone = value.cloneNode(true) as HTMLElement;
      for (const node of clone.querySelectorAll<HTMLElement>("[data-edit-token]")) {
        node.setAttribute("data-edit-token", "");
        node.removeAttribute("contenteditable");
        node.textContent = "";
      }
      clone.querySelectorAll("[data-structure-token]").forEach(node => node.setAttribute("data-structure-token", ""));
      return clone.innerHTML;
    };
    // Own-save acknowledgements update the baseline/token, not the live editor
    // DOM: retaining the spans keeps caret, native undo and IME composition.
    const reusable = container.childNodes.length > 0 && structure(container) === structure(next);
    if (reusable) {
      const existing = container.querySelectorAll<HTMLElement>("[data-edit-token]");
      const fresh = next.querySelectorAll<HTMLElement>("[data-edit-token]");
      existing.forEach((node, i) => {
        node.dataset.editToken = fresh[i].dataset.editToken;
      });
      const freshMarkers = next.querySelectorAll<HTMLElement>("[data-structure-token]");
      container.querySelectorAll<HTMLElement>("[data-structure-token]").forEach((node, i) => {
        node.dataset.structureToken = freshMarkers[i].dataset.structureToken;
      });
    } else container.replaceChildren(...Array.from(next.childNodes));
    const allowed = Array.from(
      container.querySelectorAll<HTMLElement>(`[data-edit-token="${token}"]`),
    );
    for (const node of allowed) {
      const index = Number(node.dataset.textIndex);
      if (!latest.current.blocks.some((b) => b.index === index)) continue;
      node.contentEditable = editable ? "plaintext-only" : "false";
      const changed = latest.current.changes.find((v) => v.index === index);
      const desired = changed?.text ?? latest.current.blocks.find(b => b.index === index)?.text;
      if (desired !== undefined && editableText(node) !== desired) node.textContent = desired;
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
  function selectCell(node: Element | null) {
    const table = node?.closest<HTMLElement>("table");
    const target = node?.closest<HTMLElement>("td[data-table-row], th[data-table-row]");
    setCell(table?.dataset.structureToken === token && target?.dataset.structureToken === token &&
      target.closest("table") === table && root.current?.contains(target) ? {token, index:Number(table.dataset.tableIndex),
        row:Number(target.dataset.tableRow), column:Number(target.dataset.tableColumn)} : null);
  }
  useLayoutEffect(() => {
    if (!onStructureEdit || !editable) return;
    const select = () => {
      const current = window.getSelection();
      const range = current?.rangeCount ? current.getRangeAt(0) : null;
      const start = range?.startContainer;
      const element = start instanceof Element ? start : start?.parentElement ?? null;
      const block = element?.closest<HTMLElement>("[data-edit-token]");
      if (!range || range.collapsed || !block || block.dataset.editToken !== token ||
          !root.current?.contains(block) || !block.contains(range.endContainer)) {
        setSelection(null);
        if (element && root.current?.contains(element)) selectCell(element);
        return;
      }
      const leading = range.cloneRange();
      leading.selectNodeContents(block);
      leading.setEnd(range.startContainer, range.startOffset);
      const offset = leading.toString().length;
      setSelection({token, index:Number(block.dataset.textIndex), start:offset, end:offset+range.toString().length});
      selectCell(element);
    };
    document.addEventListener("selectionchange", select);
    return () => document.removeEventListener("selectionchange", select);
  }, [editable, onStructureEdit, token]);
  return (
    <>
    {editable && onStructureEdit && <div role="group" aria-label="원본 HTML 서식과 표"
      className="original-structure-toolbar" onMouseDown={event=>event.preventDefault()}>
      {(Object.keys(formats) as FormatKind[]).map(kind =>
        <button key={kind} type="button" className="native-button" disabled={structureDisabled || !selected}
          onClick={() => selected && onStructureEdit({kind, index:selected.index, start:selected.start, end:selected.end})}>
          {formats[kind]}
        </button>)}
      <button type="button" className="native-button" disabled={structureDisabled}
        onClick={() => onStructureEdit({kind:"insert_table"})}>본문 끝에 표 추가</button>
      {selectedCell && (Object.keys(tableCommands) as TableKind[]).map(kind =>
        <button key={kind} type="button" className="native-button" disabled={structureDisabled}
          onClick={() => {
            if (kind.startsWith("delete_") && !window.confirm(`선택한 ${tableCommands[kind]} 작업을 적용할까요?`)) return;
            onStructureEdit({kind, index:selectedCell.index, row:selectedCell.row, column:selectedCell.column});
          }}>{tableCommands[kind]}</button>)}
    </div>}
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
        const target = event.target as HTMLElement;
        if (target.closest("a")) event.preventDefault();
        if (onStructureEdit) selectCell(target);
      }}
    />
    </>
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
