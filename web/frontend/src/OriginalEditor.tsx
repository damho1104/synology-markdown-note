import { useLayoutEffect, useRef, useState } from "react";
import DOMPurify from "dompurify";
export type TextChange = { index: number; text: string };
const formats = {bold:"굵게", italic:"기울임", underline:"밑줄", strike:"취소선",
  subscript:"아래 첨자", superscript:"위 첨자"} as const;
const tableCommands = {
  row_before:"위에 행 추가", row_after:"아래에 행 추가",
  column_before:"왼쪽에 열 추가", column_after:"오른쪽에 열 추가",
  delete_row:"행 삭제", delete_column:"열 삭제", delete_table:"표 삭제",
} as const;
type FormatKind = keyof typeof formats;
type ValueKind = "font_family" | "font_size" | "text_color" | "highlight_color" | "link";
type BlockKind = "paragraph" | "align" | "list" | "indent" | "outdent" | "check_item";
type TableKind = keyof typeof tableCommands;
type Selection = {index:number; start:number; end:number};
type TableCell = {index:number; row:number; column:number};
export type StructureEdit = ({kind:FormatKind} & Selection) | ({kind:TableKind} & TableCell)
  | ({kind:ValueKind; value:string} & Selection) | ({kind:"unlink" | "clear_format"} & Selection)
  | {kind:BlockKind; index:number; value?:string} | {kind:"insert_table"; rows?:number; columns?:number};
const fonts = ["system-ui", "Arial", "Georgia", "Times New Roman", "Helvetica", "Apple SD Gothic Neo", "AppleMyungjo", "Menlo"];
function safeHtml(html: string): string {
  const root = DOMPurify.sanitize(html, {
    FORBID_TAGS: ["script", "style", "iframe", "form", "object", "embed"],
    FORBID_ATTR: ["contenteditable", "src", "srcset"],
    ADD_ATTR: ["ref"],
    RETURN_DOM_FRAGMENT: true,
  });
  const container = document.createElement("div");
  container.append(root);
  for (const node of container.querySelectorAll<HTMLElement>("[style]")) {
    const allowed = new Map<string,string>();
    for (const key of ["color", "background-color", "font-size", "font-family", "text-align", "margin-left"]) {
      const value = node.style?.getPropertyValue(key);
      if (!value) continue;
      if (key === "font-family" ? fonts.includes(value.replace(/["']/g, ""))
          : key === "font-size" ? /^\d{1,2}px$/.test(value)
          : key === "text-align" ? /^(left|center|right|justify)$/.test(value)
          : key === "margin-left" ? /^\d{1,3}px$/.test(value)
          : /^(#[0-9a-f]{3,8}|rgba?\([\d., %]+\)|[a-z]+)$/i.test(value)) allowed.set(key,value);
    }
    node.removeAttribute("style");
    for (const [key,value] of allowed) node.style.setProperty(key,value);
  }
  return container.innerHTML;
}
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
  onAttach, onUndo, onRedo, canUndo, canRedo,
  attachmentPath,
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
  onAttach?: () => void;
  onUndo?: () => void;
  onRedo?: () => void;
  canUndo?: boolean;
  canRedo?: boolean;
  attachmentPath?: (reference: string) => string | undefined;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [selection,setSelection] = useState<(Selection & {token:string}) | null>(null);
  const [cell,setCell] = useState<(TableCell & {token:string}) | null>(null);
  const selected = selection?.token === token ? selection : null;
  const selectedCell = cell?.token === token ? cell : null;
  const [block, setBlock] = useState<{token:string; index:number} | null>(null);
  const activeBlock = block?.token === token ? block.index : undefined;
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
  useLayoutEffect(() => {
    if (!attachmentPath || !root.current) return;
    const urls: string[] = [];
    const cancel = new AbortController();
    for (const image of root.current.querySelectorAll("img")) {
      const ref = image.getAttribute("ref") ?? image.getAttribute("data-attachment-ref");
      const path = ref && attachmentPath(ref);
      if (!path) continue;
      void fetch(path, {credentials:"same-origin", signal:cancel.signal}).then(async response => {
        if (!response.ok) return;
        const blob = await response.blob();
        const bytes = new Uint8Array(await blob.slice(0,12).arrayBuffer());
        const signature = String.fromCharCode(...bytes);
        const mime = signature.startsWith("\x89PNG") ? "image/png"
          : bytes[0] === 255 && bytes[1] === 216 ? "image/jpeg"
          : signature.startsWith("GIF8") ? "image/gif"
          : signature.startsWith("RIFF") && signature.slice(8) === "WEBP" ? "image/webp" : undefined;
        if (!mime || cancel.signal.aborted) return;
        const url = URL.createObjectURL(new Blob([blob], {type:mime}));
        urls.push(url);
        image.src = url;
      }).catch(() => {});
    }
    return () => {
      cancel.abort();
      urls.forEach(url => URL.revokeObjectURL(url));
    };
  }, [html, token, attachmentPath]);
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
      if (!root.current?.contains(element) && element?.closest(".original-structure-toolbar")) return;
      setBlock(block?.dataset.editToken === token && root.current?.contains(block)
        ? {token, index:Number(block.dataset.textIndex)} : null);
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
    {editable && onStructureEdit && <div role="group" aria-label="본문 서식과 표"
      className="original-structure-toolbar" onMouseDown={event=>{
        if ((event.target as Element).closest("button")) event.preventDefault();
      }}>
      <select aria-label="문단" value="" disabled={structureDisabled || activeBlock === undefined}
        onChange={event=>activeBlock !== undefined && event.target.value &&
          onStructureEdit({kind:"paragraph",index:activeBlock,value:event.target.value})}>
        <option value="">본문</option>
        {Object.entries({p:"본문",h1:"제목 1",h2:"제목 2",h3:"제목 3",blockquote:"인용",pre:"코드"})
          .map(([value,label])=><option key={value} value={value}>{label}</option>)}
      </select>
      <select aria-label="글꼴" value="" disabled={structureDisabled || !selected} onChange={event=>{
        if (selected && event.target.value) onStructureEdit({kind:"font_family",value:event.target.value,index:selected.index,start:selected.start,end:selected.end});
      }}>
        <option value="">글꼴</option>
        {fonts.map(font=><option key={font} value={font}>{font === "system-ui" ? "시스템" : font}</option>)}
      </select>
      <select aria-label="글자 크기" value="" disabled={structureDisabled || !selected} onChange={event=>{
        if (selected && event.target.value) onStructureEdit({kind:"font_size",value:event.target.value,index:selected.index,start:selected.start,end:selected.end});
      }}>
        <option value="">크기</option>
        {[10,12,14,16,18,24,32,48,72].map(size=><option key={size} value={size}>{size} px</option>)}
      </select>
      {(Object.keys(formats) as FormatKind[]).map(kind =>
        <button key={kind} type="button" className="native-button" disabled={structureDisabled || !selected}
          onClick={() => selected && onStructureEdit({kind, index:selected.index, start:selected.start, end:selected.end})}>
          {formats[kind]}
        </button>)}
      {(["text_color","highlight_color"] as const).map(kind=>
        <input key={kind} type="color" aria-label={kind === "text_color" ? "글자 색" : "강조 색"}
          defaultValue={kind === "text_color" ? "#000000" : "#ffff00"} disabled={structureDisabled || !selected}
          onChange={event=>selected && onStructureEdit({kind,value:event.target.value,index:selected.index,start:selected.start,end:selected.end})}/>)}
      {([
        ["왼쪽 정렬","align","left"], ["가운데 정렬","align","center"],
        ["오른쪽 정렬","align","right"], ["양쪽 정렬","align","justify"],
        ["글머리 목록","list","bullet"], ["번호 목록","list","number"], ["체크리스트","list","check"],
        ["들여쓰기","indent"], ["내어쓰기","outdent"],
      ] as const).map(([label,kind,value])=>
        <button key={label} type="button" className="native-button" disabled={structureDisabled || activeBlock === undefined}
          onClick={()=>activeBlock !== undefined && onStructureEdit({kind,index:activeBlock,...(value ? {value} : {})})}>{label}</button>)}
      {([["서식 지우기","clear_format"],["링크 해제","unlink"]] as const).map(([label,kind])=>
        <button key={kind} type="button" className="native-button" disabled={structureDisabled || !selected}
          onClick={()=>selected && onStructureEdit({kind,index:selected.index,start:selected.start,end:selected.end})}>{label}</button>)}
      <button type="button" className="native-button" disabled={structureDisabled || !selected} onClick={()=>{
        if (!selected) return;
        const value = window.prompt("링크 주소", "https://");
        if (value && value !== "https://") onStructureEdit({kind:"link",value,index:selected.index,start:selected.start,end:selected.end});
      }}>링크</button>
      <button type="button" className="native-button" disabled={structureDisabled}
        onClick={() => {
          const input = window.prompt("행 × 열 (최대 30 × 20)", "2x2");
          const size = input?.match(/^\s*(\d+)\s*[x×]\s*(\d+)\s*$/i);
          if (!size) return;
          const rows = Number(size[1]), columns = Number(size[2]);
          if (rows >= 1 && rows <= 30 && columns >= 1 && columns <= 20)
            onStructureEdit({kind:"insert_table",rows,columns});
        }}>본문 끝에 표 추가</button>
      {selectedCell && (Object.keys(tableCommands) as TableKind[]).map(kind =>
        <button key={kind} type="button" className="native-button" disabled={structureDisabled}
          onClick={() => {
            if (kind.startsWith("delete_") && !window.confirm(`선택한 ${tableCommands[kind]} 작업을 적용할까요?`)) return;
            onStructureEdit({kind, index:selectedCell.index, row:selectedCell.row, column:selectedCell.column});
          }}>{tableCommands[kind]}</button>)}
      {onAttach && <button type="button" className="native-button" onClick={onAttach}>첨부</button>}
      {onUndo && <button type="button" className="native-button" disabled={structureDisabled || !canUndo} onClick={onUndo}>실행 취소</button>}
      {onRedo && <button type="button" className="native-button" disabled={structureDisabled || !canRedo} onClick={onRedo}>다시 실행</button>}
    </div>}
    <div
      ref={root}
      role="textbox"
      aria-label="본문 편집기"
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
        const link = target.closest("a");
        if (link) {
          event.preventDefault();
          const href = link.getAttribute("href") ?? "";
          if (event.metaKey || event.ctrlKey || !editable) {
            if (/^https?:\/\//i.test(href)) window.open(href, "_blank", "noopener,noreferrer");
            else if (/^mailto:/i.test(href)) window.location.href = href;
            else if (href.startsWith("#")) {
              const anchor = Array.from(root.current?.querySelectorAll<HTMLElement>("[id], [name]") ?? [])
                .find(node => (node.id || node.getAttribute("name")) === href.slice(1));
              anchor?.scrollIntoView();
            }
          }
        }
        if (target.matches('input[type="checkbox"]')) {
          event.preventDefault();
          const marker = target.parentElement?.querySelector<HTMLElement>("[data-edit-token]");
          if (editable && !structureDisabled && marker?.dataset.editToken === token)
            onStructureEdit?.({kind:"check_item",index:Number(marker.dataset.textIndex)});
        }
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
