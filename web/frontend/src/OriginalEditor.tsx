import { formatNumber, t } from "./i18n";
import { useId, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import DOMPurify from "dompurify";
import {
  AlignCenter, AlignJustify, AlignLeft, AlignRight, Baseline, Bold, CaseSensitive, ChevronDown,
  Ellipsis, Highlighter, IndentDecrease, IndentIncrease, Italic, Link2, List, ListChecks, ListOrdered,
  PanelBottomOpen, PanelLeftClose, PanelLeftOpen, PanelRightOpen, PanelTopClose, PanelTopOpen,
  Paperclip, Pilcrow, Redo2, RemoveFormatting, Strikethrough, Subscript, Superscript, Table2, Trash2,
  Type, Underline, Undo2, Unlink2, type LucideIcon,
} from "lucide-react";
export type TextChange = { index: number; text: string };
const formats = {
  bold:["editor.bold", Bold], italic:["editor.italic", Italic], underline:["editor.underline", Underline],
  strike:["editor.strikethrough", Strikethrough], subscript:["editor.subscript", Subscript], superscript:["editor.superscript", Superscript],
} as const;
const tableCommands = {
  row_before:["editor.insertRowAbove", PanelTopOpen], row_after:["editor.insertRowBelow", PanelBottomOpen],
  column_before:["editor.insertColumnLeft", PanelLeftOpen], column_after:["editor.insertColumnRight", PanelRightOpen],
  delete_row:["editor.deleteRow", PanelTopClose], delete_column:["editor.deleteColumn", PanelLeftClose], delete_table:["editor.deleteTable", Trash2],
} as const;
const alignmentCommands = [
  ["editor.alignLeft", AlignLeft, "left"], ["editor.center", AlignCenter, "center"],
  ["editor.alignRight", AlignRight, "right"], ["editor.justify", AlignJustify, "justify"],
] as const;
const layoutCommands = [
  ["editor.bulletedList", List, "list", "bullet"], ["editor.numberedList", ListOrdered, "list", "number"],
  ["editor.checklist", ListChecks, "list", "check"], ["editor.increaseIndent", IndentIncrease, "indent", undefined],
  ["editor.decreaseIndent", IndentDecrease, "outdent", undefined],
] as const;
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
type ImageLoad = { controller: AbortController; images: HTMLImageElement[]; url?: string };

function ToolbarButton({label, icon:Icon, disabled, pressed, onClick}: {
  label:string; icon:LucideIcon; disabled?:boolean; pressed?:boolean; onClick:() => void;
}) {
  return <button type="button" className="original-toolbar-button" aria-label={label} title={label}
    disabled={disabled} aria-pressed={pressed} onClick={onClick}>
    <Icon size={17} strokeWidth={1.75} aria-hidden="true" />
  </button>;
}

function ToolbarSelect({label, icon:Icon, disabled, onChange, children}: {
  label:string; icon:LucideIcon; disabled:boolean; onChange:(value:string)=>void; children:ReactNode;
}) {
  return <label className="original-toolbar-select" title={label}>
    <Icon size={17} strokeWidth={1.75} aria-hidden="true" />
    <ChevronDown size={11} aria-hidden="true" />
    <select aria-label={label} value="" disabled={disabled} onChange={event=>onChange(event.target.value)}>
      <option value="" disabled>{label}</option>
      {children}
    </select>
  </label>;
}

function releaseImage(load: ImageLoad) {
  load.controller.abort();
  if (load.url) URL.revokeObjectURL(load.url);
}

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
  onAttach, onUndo, onRedo, canUndo, canRedo, restoreSelection,
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
  restoreSelection?: Selection;
}) {
  const root = useRef<HTMLDivElement>(null);
  const restoredSelection = useRef<Selection>(undefined);
  const imageLoads = useRef(new Map<string, ImageLoad>());
  const [showMore, setShowMore] = useState(false);
  const moreId = useId();
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
      // The live editor adds blob URLs after sanitizing the saved markup.
      clone.querySelectorAll("img[src]").forEach(image => image.removeAttribute("src"));
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
    const loads = imageLoads.current;
    const desired = new Map<string, HTMLImageElement[]>();
    for (const image of root.current!.querySelectorAll("img")) {
      const ref = image.getAttribute("ref") ?? image.getAttribute("data-attachment-ref");
      const path = ref && attachmentPath?.(ref);
      const url = path ? loads.get(path)?.url : undefined;
      if (url && image.getAttribute("src") !== url) image.src = url;
      if (!url && image.hasAttribute("src")) image.removeAttribute("src");
      if (!path) continue;
      const images = desired.get(path);
      if (images) images.push(image);
      else desired.set(path, [image]);
    }
    for (const [path, load] of loads) {
      if (desired.has(path)) continue;
      releaseImage(load);
      loads.delete(path);
    }
    for (const [path, images] of desired) {
      const cached = loads.get(path);
      if (cached) {
        cached.images = images;
        continue;
      }
      const load: ImageLoad = {controller:new AbortController(), images};
      loads.set(path, load);
      const {signal} = load.controller;
      void fetch(path, {credentials:"same-origin", signal}).then(async response => {
        if (!response.ok) return;
        const blob = await response.blob();
        const bytes = new Uint8Array(await blob.slice(0,12).arrayBuffer());
        const signature = String.fromCharCode(...bytes);
        const mime = signature.startsWith("\x89PNG") ? "image/png"
          : bytes[0] === 255 && bytes[1] === 216 ? "image/jpeg"
          : signature.startsWith("GIF8") ? "image/gif"
          : signature.startsWith("RIFF") && signature.slice(8) === "WEBP" ? "image/webp" : undefined;
        if (!mime || signal.aborted) return;
        load.url = URL.createObjectURL(new Blob([blob], {type:mime}));
        for (const image of load.images) image.src = load.url;
      }).catch(() => {}).finally(() => {
        if (!load.url && loads.get(path) === load) loads.delete(path);
      });
    }
  }, [html, token, editable, attachmentPath]);
  useLayoutEffect(() => {
    const loads = imageLoads.current;
    return () => {
      loads.forEach(releaseImage);
      loads.clear();
    };
  }, []);
  useLayoutEffect(() => {
    if (!editable || !restoreSelection || restoredSelection.current === restoreSelection) return;
    const {index,start,end} = restoreSelection;
    const span = root.current?.querySelector<HTMLElement>(`[data-edit-token="${token}"][data-text-index="${index}"]`);
    const text = span?.firstChild;
    const selection = window.getSelection();
    if (!span || !text || text.nodeType !== Node.TEXT_NODE || !selection || end > (text.textContent?.length ?? 0)) return;
    restoredSelection.current = restoreSelection;
    span.focus({preventScroll:true});
    const range = document.createRange();
    range.setStart(text,start);
    range.setEnd(text,end);
    selection.removeAllRanges();
    selection.addRange(range);
    setBlock({token,index});
    setSelection(start === end ? null : {token,index,start,end});
  }, [editable,restoreSelection,token]);
  function selectCell(node: Element | null) {
    const table = node?.closest<HTMLElement>("table");
    const target = node?.closest<HTMLElement>("td[data-table-row], th[data-table-row]");
    setCell(table?.dataset.structureToken === token && target?.dataset.structureToken === token &&
      target.closest("table") === table && root.current?.contains(target) ? {token, index:Number(table.dataset.tableIndex),
        row:Number(target.dataset.tableRow), column:Number(target.dataset.tableColumn)} : null);
  }
  const structuralEditing = !!onStructureEdit && editable;
  useLayoutEffect(() => {
    if (!structuralEditing) return;
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
    if (root.current?.contains(window.getSelection()?.anchorNode ?? null)) select();
    document.addEventListener("selectionchange", select);
    return () => document.removeEventListener("selectionchange", select);
  }, [structuralEditing, token]);
  const selectionDisabled = structureDisabled || !selected;
  const blockDisabled = structureDisabled || activeBlock === undefined;
  const formatTags: Record<FormatKind,string> = {
    bold:"strong,b", italic:"em,i", underline:"u", strike:"s,strike,del", subscript:"sub", superscript:"sup",
  };
  function formatButton(kind: FormatKind) {
    const [label,icon] = formats[kind];
    const block = activeBlock === undefined ? undefined
      : root.current?.querySelector(`[data-edit-token="${token}"][data-text-index="${activeBlock}"]`);
    const formatted = block?.parentElement?.closest(formatTags[kind]);
    return <ToolbarButton key={kind} label={t(label)} icon={icon} disabled={selectionDisabled}
      pressed={!!formatted && !!root.current?.contains(formatted)} onClick={()=>selected && onStructureEdit?.({kind,index:selected.index,start:selected.start,end:selected.end})} />;
  }
  return (
    <>
    {editable && onStructureEdit && <div role="group" aria-label={t("editor.bodyFormattingAndTables")}
      className="original-structure-toolbar" data-expanded={showMore} onMouseDown={event=>{
        if ((event.target as Element).closest("button")) event.preventDefault();
      }}>
      <div className="original-toolbar-group">
        <ToolbarSelect label={t("editor.paragraph")} icon={Pilcrow} disabled={blockDisabled}
          onChange={value=>activeBlock !== undefined && onStructureEdit({kind:"paragraph",index:activeBlock,value})}>
          {Object.entries({p:t("editor.body"),h1:t("editor.heading1"),h2:t("editor.heading2"),h3:t("editor.heading3"),blockquote:t("editor.quote"),pre:t("editor.code")})
            .map(([value,label])=><option key={value} value={value}>{label}</option>)}
        </ToolbarSelect>
        {(["bold","italic","underline"] as const).map(formatButton)}
      </div>
      <div className="original-toolbar-group">
        <ToolbarButton label={t("editor.link")} icon={Link2} disabled={selectionDisabled} onClick={()=>{
          if (!selected) return;
          const value = window.prompt(t("editor.linkUrl"), "https://");
          if (value && value !== "https://") onStructureEdit({kind:"link",value,index:selected.index,start:selected.start,end:selected.end});
        }}/>
        {onAttach && <ToolbarButton label={t("editor.attach")} icon={Paperclip} onClick={onAttach}/>}
        {onUndo && <ToolbarButton label={t("editor.undo")} icon={Undo2} disabled={structureDisabled || !canUndo} onClick={onUndo}/>}
        {onRedo && <ToolbarButton label={t("editor.redo")} icon={Redo2} disabled={structureDisabled || !canRedo} onClick={onRedo}/>}
      </div>
      <button className="original-toolbar-button original-toolbar-more" type="button"
        aria-label={t("editor.moreEditingTools")} title={t("editor.moreEditingTools")} aria-controls={moreId}
        aria-expanded={showMore} onClick={()=>setShowMore(current=>!current)}>
        <Ellipsis size={19} aria-hidden="true"/>
      </button>
      <div className="original-toolbar-secondary" id={moreId}>
        <div className="original-toolbar-group">
          <ToolbarSelect label={t("editor.font")} icon={Type} disabled={selectionDisabled}
            onChange={value=>selected && onStructureEdit({kind:"font_family",value,index:selected.index,start:selected.start,end:selected.end})}>
            {fonts.map(font=><option key={font} value={font}>{font === "system-ui" ? t("editor.system") : font}</option>)}
          </ToolbarSelect>
          <ToolbarSelect label={t("editor.textSize")} icon={CaseSensitive} disabled={selectionDisabled}
            onChange={value=>selected && onStructureEdit({kind:"font_size",value,index:selected.index,start:selected.start,end:selected.end})}>
            {[10,12,14,16,18,24,32,48,72].map(size=><option key={size} value={size}>{formatNumber(size)} px</option>)}
          </ToolbarSelect>
          {(["strike","subscript","superscript"] as const).map(formatButton)}
          {([["text_color",t("editor.textColor"),Baseline,"#000000"],["highlight_color",t("editor.highlightColor"),Highlighter,"#ffff00"]] as const)
            .map(([kind,label,Icon,color])=><label key={kind} className="original-toolbar-color" title={label}>
              <Icon size={17} strokeWidth={1.75} aria-hidden="true"/>
              <input type="color" aria-label={label} defaultValue={color} disabled={selectionDisabled}
                onChange={event=>selected && onStructureEdit({kind,value:event.target.value,index:selected.index,start:selected.start,end:selected.end})}/>
            </label>)}
          <ToolbarButton label={t("editor.clearFormatting")} icon={RemoveFormatting} disabled={selectionDisabled}
            onClick={()=>selected && onStructureEdit({kind:"clear_format",index:selected.index,start:selected.start,end:selected.end})}/>
        </div>
        <div className="original-toolbar-group">
          {alignmentCommands.map(([label,icon,value])=><ToolbarButton key={value} label={t(label)} icon={icon}
            disabled={blockDisabled} onClick={()=>activeBlock !== undefined && onStructureEdit({kind:"align",index:activeBlock,value})}/>)}
        </div>
        <div className="original-toolbar-group">
          {layoutCommands.map(([label,icon,kind,value])=><ToolbarButton key={label} label={t(label)} icon={icon}
            disabled={blockDisabled} onClick={()=>activeBlock !== undefined && onStructureEdit({kind,index:activeBlock,value})}/>)}
        </div>
        <div className="original-toolbar-group">
          <ToolbarButton label={t("editor.removeLink")} icon={Unlink2} disabled={selectionDisabled}
            onClick={()=>selected && onStructureEdit({kind:"unlink",index:selected.index,start:selected.start,end:selected.end})}/>
          <ToolbarButton label={t("editor.insertTableEnd")} icon={Table2} disabled={structureDisabled} onClick={()=>{
            const input = window.prompt(t("editor.tableSizeHint"), "2x2");
            const size = input?.match(/^\s*(\d+)\s*[x×]\s*(\d+)\s*$/i);
            if (!size) return;
            const rows = Number(size[1]), columns = Number(size[2]);
            if (rows >= 1 && rows <= 30 && columns >= 1 && columns <= 20)
              onStructureEdit({kind:"insert_table",rows,columns});
          }}/>
        </div>
        {selectedCell && <div className="original-toolbar-group">
          {(Object.keys(tableCommands) as TableKind[]).map(kind => {
            const [label,icon] = tableCommands[kind];
            return <ToolbarButton key={kind} label={t(label)} icon={icon} disabled={structureDisabled} onClick={()=>{
              if (kind.startsWith("delete_") && !window.confirm(t("editor.applySelectedAction", t(label)))) return;
              onStructureEdit({kind,index:selectedCell.index,row:selectedCell.row,column:selectedCell.column});
            }}/>;
          })}
        </div>}
      </div>
    </div>}
    <div
      ref={root}
      role="textbox"
      aria-label={t("editor.noteBodyEditor")}
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
