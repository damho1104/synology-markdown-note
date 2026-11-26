import { UiError } from "./i18n";
import type { StructureEdit, TextChange } from "./OriginalEditor";

type Block = TextChange & {start:number; end:number};
type RangePatch = [start:number, end:number, replacement:string];
type ElementSpan = {
  tag:string; start:number; openEnd:number; closeStart?:number; end?:number;
  parent?:ElementSpan; children:ElementSpan[];
};

const voidTags = new Set("area base br col embed hr img input link meta param source track wbr".split(" "));
const opaqueTags = new Set("script style svg math textarea title head".split(" "));
const structuralTags = new Set("table thead tbody tfoot tr colgroup ul ol dl select optgroup".split(" "));
const paragraphs = new Set("p h1 h2 h3 h4 pre blockquote".split(" "));
const inlineTags = {
  bold:"strong", italic:"em", underline:"u", strike:"s", subscript:"sub", superscript:"sup",
} as const;
const inlineStyles = {
  font_family:"font-family", font_size:"font-size", text_color:"color", highlight_color:"background-color",
} as const;
const formatting = new Set([...Object.values(inlineTags),"b","i","strike","font","span","mark"]);
const phrasing = new Set([...formatting, ..."a abbr bdi bdo br cite code del dfn img input ins kbd label q rp rt ruby samp small time var wbr".split(" ")]);
const attribute = /[^\s=<>/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/g;
const checkbox = String.raw`<input\s+type\s*=\s*(?:"checkbox"|'checkbox'|checkbox)(?<checked>\s+checked(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)?(?<close>\s*/?>)`;

export const escapeText = (text: string) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function decode(raw: string, decoder: HTMLTextAreaElement) {
  if (!raw.includes("&")) return raw;
  decoder.innerHTML = raw.replace(/</g, "&lt;").replace(/\r/g, "&#13;");
  return decoder.textContent ?? "";
}

function applyPatches(source: string, patches: RangePatch[]) {
  let cursor = 0;
  const pieces: string[] = [];
  for (const [start,end,value] of patches.sort((a,b) => a[0]-b[0] || a[1]-b[1])) {
    pieces.push(source.slice(cursor,start),value);
    cursor = end;
  }
  pieces.push(source.slice(cursor));
  return pieces.join("");
}

// Scan source offsets, including empty slots. DOM parsing would normalize the
// original markup and number implied table/list elements differently from the NAS.
function scan(source: string) {
  const elements: ElementSpan[] = [];
  const stack: ElementSpan[] = [];
  const blocks: Block[] = [];
  const decoder = document.createElement("textarea");
  const tokens = /<!--[\s\S]*?(?:--\s*>|$)|<!(?:--|\[)[\s\S]*?\]>|<[!?][^>]*>|<\/[a-zA-Z][^>]*>|<[a-zA-Z](?:"[^"]*"|'[^']*'|[^'">])*>/g;
  let cursor = 0;
  let bodyEnd = source.length;
  const pushBlock = (end: number) => blocks.push({
    index:blocks.length, start:cursor, end, text:decode(source.slice(cursor,end),decoder),
  });
  for (let match = tokens.exec(source); match; match = tokens.exec(source)) {
    const raw = match[0];
    const start = match.index;
    const end = tokens.lastIndex;
    const tag = /^<\/?([a-z][^\s/>]*)/i.exec(raw)?.[1].toLowerCase();
    const parent = stack.at(-1);
    if ((parent?.tag === "script" || parent?.tag === "style") && !(tag === parent.tag && raw.startsWith("</"))) {
      // Raw-text contents may contain quotes and tags. Resume at the real closing tag.
      const closing = new RegExp(`</\\s*${parent.tag}\\s*>`, "gi");
      closing.lastIndex = start;
      const next = closing.exec(source);
      if (!next) break;
      tokens.lastIndex = next.index;
      continue;
    }
    if (!stack.some(item => opaqueTags.has(item.tag)) && (!parent || !structuralTags.has(parent.tag))) pushBlock(start);
    cursor = end;
    if (!tag) continue;
    if (raw.startsWith("</")) {
      if (tag === "body") bodyEnd = start;
      let index = stack.length - 1;
      while (index >= 0 && stack[index].tag !== tag) index--;
      if (index >= 0) {
        const element = stack[index];
        element.closeStart = start;
        element.end = end;
        stack.length = index;
      }
    } else {
      const element: ElementSpan = {tag,start,openEnd:end,parent,children:[]};
      elements.push(element);
      parent?.children.push(element);
      if (voidTags.has(tag) || raw.endsWith("/>")) element.end = end;
      else stack.push(element);
    }
  }
  if (!stack.some(item => opaqueTags.has(item.tag))) pushBlock(source.length);
  return {blocks,elements,bodyEnd};
}

function grid(table: ElementSpan) {
  const rows = table.children.flatMap(child => ["thead","tbody","tfoot"].includes(child.tag)
    ? child.children.filter(entry => entry.tag === "tr") : child.tag === "tr" ? [child] : []);
  const cells = rows.map(row => row.children.filter(child => child.tag === "td" || child.tag === "th"));
  return {rows,cells};
}

function simpleTable(source: string, table: ElementSpan, elements: ElementSpan[]) {
  const {rows,cells} = grid(table);
  return table.closeStart !== undefined && rows.length > 0 && !!cells[0].length &&
    !elements.some(node => node !== table && node.tag === "table" && node.start > table.start && node.start < table.closeStart!) &&
    rows.every((row,i) => row.closeStart !== undefined && cells[i].length === cells[0].length &&
      cells[i].every(cell => cell.closeStart !== undefined &&
        !Array.from(source.slice(cell.start,cell.openEnd).matchAll(attribute)).some(match =>
          /^(colspan|rowspan)\s*=/i.test(match[0]) && !/=\s*(?:"1"|'1'|1)$/.test(match[0]))));
}

export function annotateFormattedDraft(source: string, token: string) {
  const {blocks,elements} = scan(source);
  const patches: RangePatch[] = blocks.map(({index,start,end,text}) => [start,end,
    `<span data-edit-token="${token}" data-text-index="${index}">${escapeText(text)}</span>`]);
  elements.filter(element => element.tag === "table").forEach((table,index) => {
    if (!simpleTable(source,table,elements)) return;
    const marker = ` data-structure-token="${token}"`;
    const tableMark = table.start + 6;
    patches.push([tableMark,tableMark,`${marker} data-table-index="${index}"`]);
    grid(table).cells.forEach((row,r) => row.forEach((cell,c) => {
      const offset = cell.start + 1 + cell.tag.length;
      patches.push([offset,offset,`${marker} data-table-row="${r}" data-table-column="${c}"`]);
    }));
  });
  return {blocks, html:applyPatches(source,patches), token};
}

function unsupported(): never {
  throw new UiError("이 위치에는 선택한 편집 명령을 적용할 수 없습니다.");
}

function inlinePatch(source: string, edit: StructureEdit & {start:number;end:number}, block: Block, elements: ElementSpan[]) {
  const raw = source.slice(block.start,block.end);
  const decoder = document.createElement("textarea");
  const boundaries = new Map([[0,0]]);
  let offset = 0;
  for (const token of raw.matchAll(/&#(?:[0-9]+|[xX][0-9a-fA-F]+);?|&[a-zA-Z][a-zA-Z0-9]*;?|[\s\S]/gu)) {
    offset += decode(token[0],decoder).length;
    boundaries.set(offset,token.index + token[0].length);
  }
  const start = boundaries.get(edit.start), end = boundaries.get(edit.end);
  if (start === undefined || end === undefined || start >= end) return unsupported();
  const tag = inlineTags[edit.kind as keyof typeof inlineTags];
  let opening = tag ? `<${tag}>` : "", closing = tag ? `</${tag}>` : "";
  if ("value" in edit && typeof edit.value === "string") {
    if (edit.kind === "link") {
      const href = edit.value;
      const valid = href.startsWith("#") || /^mailto:.+/i.test(href) ||
        (/^https?:\/\//i.test(href) && URL.canParse(href));
      if (!valid || /[\x00-\x20\x7f\\]/.test(href) || elements.some(node =>
        node.tag === "a" && node.openEnd <= block.start + start && (node.end ?? source.length) > block.start + start))
        return unsupported();
      opening = `<a href="${escapeText(href).replace(/"/g,"&quot;").replace(/'/g,"&#x27;")}">`;
      closing = "</a>";
    } else {
      const property = inlineStyles[edit.kind as keyof typeof inlineStyles];
      if (!property || !(edit.kind === "font_family" ? /^[\w -]+$/.test(edit.value)
        : edit.kind === "font_size" ? /^\d{1,2}$/.test(edit.value) && +edit.value >= 8 && +edit.value <= 72
        : /^#[a-f\d]{6}$/i.test(edit.value))) return unsupported();
      opening = `<span style="${property}:${edit.value}${edit.kind === "font_size" ? "px" : ""}">`;
      closing = "</span>";
    }
  }
  if (!opening) return unsupported();
  if (tag && start === 0 && end === raw.length && source.slice(0,block.start).endsWith(opening) &&
      source.startsWith(closing,block.end))
    return {patches:[[block.start-opening.length,block.end+closing.length,raw]] as RangePatch[],
      focus:[block.start-opening.length,block.end-opening.length] as const};
  return {patches:[[block.start,block.end,raw.slice(0,start)+opening+raw.slice(start,end)+closing+raw.slice(end)]] as RangePatch[],
    focus:[block.start+start+opening.length,block.start+end+opening.length] as const};
}

function tablePatches(source: string, edit: Extract<StructureEdit,{row:number}>, elements: ElementSpan[]) {
  const table = elements.filter(node => node.tag === "table")[edit.index];
  if (!table || !simpleTable(source,table,elements)) return unsupported();
  const {rows,cells} = grid(table);
  const row = rows[edit.row], cell = cells[edit.row]?.[edit.column];
  if (edit.kind === "delete_table") return [[table.start,table.end!,""]] as RangePatch[];
  if (!row || !cell) return unsupported();
  const blank = (node: ElementSpan) => `<${node.tag}></${node.tag}>`;
  if (edit.kind === "row_before" || edit.kind === "row_after") {
    const at = edit.kind === "row_before" ? row.start : row.end!;
    return [[at,at,`<tr>${cells[edit.row].map(blank).join("")}</tr>`]] as RangePatch[];
  }
  if (edit.kind === "delete_row") {
    if (rows.length < 2) return unsupported();
    return [[row.start,row.end!,""]] as RangePatch[];
  }
  if (edit.kind === "delete_column" && cells[edit.row].length < 2) return unsupported();
  const definitions = table.children.filter(node => node.tag === "colgroup" || node.tag === "col")
    .flatMap(group => (group.children.length ? group.children : [group]).map(node => ({group,node})));
  if (definitions.length > cells[0].length || definitions.some(({group,node}) =>
    group.end === undefined || node.end === undefined || [group,node].some(entry =>
      /\sspan\s*=\s*(?!"1"|'1'|1[\s/>])/i.test(source.slice(entry.start,entry.openEnd)))))
    return unsupported();
  const patches: RangePatch[] = cells.map(rowCells => {
    const target = rowCells[edit.column];
    if (edit.kind === "delete_column") return [target.start,target.end!,""];
    const at = edit.kind === "column_before" ? target.start : target.end!;
    return [at,at,blank(target)];
  });
  const definition = definitions[edit.column];
  if (definition) {
    const {node,group} = definition;
    if (edit.kind === "delete_column") {
      const target = group.children.length === 1 ? group : node;
      patches.push([target.start,target.end!,""]);
    } else {
      const at = edit.kind === "column_before" ? node.start : node.end!;
      patches.push([at,at,node.tag === "colgroup" ? "<colgroup></colgroup>" : "<col>"]);
    }
  }
  return patches;
}

function isPhrasing(node: ElementSpan): boolean {
  return phrasing.has(node.tag) && node.children.every(isPhrasing);
}

function listItem(value: string, attrs: string, body: string) {
  const tag = value === "number" ? "ol" : "ul";
  if (value === "check") {
    if (/<(?:label|input)\b/i.test(body)) return unsupported();
    body = `<label><input type="checkbox"> ${body}</label>`;
  }
  return `<${tag}><li${attrs}>${body}</li></${tag}>`;
}

function replaceListItem(source: string, item: ElementSpan, value: string) {
  const parent = item.parent;
  if (!parent || !["ol","ul"].includes(parent.tag) || parent.closeStart === undefined ||
      parent.children.some(child => child.tag !== "li" || child.end === undefined ||
        /\svalue\s*=/i.test(source.slice(child.start,child.openEnd)))) return unsupported();
  for (let ancestor = parent.parent; ancestor; ancestor = ancestor.parent) {
    if (ancestor.tag === "li") return unsupported();
  }
  const opening = source.slice(parent.start,parent.openEnd);
  const allowed = parent.tag === "ol" ? /^<ol(?:\s+start\s*=\s*(?:"(-?\d{1,9})"|'(-?\d{1,9})'|(-?\d{1,9})))?\s*>$/i : /^<ul\s*>$/i;
  const match = allowed.exec(opening);
  if (!match) return unsupported();
  const attrs = source.slice(item.start+3,item.openEnd-1);
  let body = source.slice(item.openEnd,item.closeStart);
  const check = new RegExp(`^<label>${checkbox} ([\\s\\S]*)</label>$`,"i").exec(body);
  const current = parent.tag === "ol" ? "number" : check ? "check" : "bullet";
  if (check) body = check.at(-1)!;
  const onlyInline = item.children.every(isPhrasing);
  if (value === "check" && current !== "check" && !onlyInline) return unsupported();
  const tag = onlyInline ? "p" : "div";
  const replacement = value === current ? `<${tag}${attrs}>${body}</${tag}>` : listItem(value,attrs,body);
  const index = parent.children.indexOf(item);
  const ending = source.slice(parent.closeStart,parent.end);
  let before = source.slice(parent.openEnd,item.start), after = source.slice(item.end,parent.closeStart);
  if (index) before = opening + before + ending;
  if (index + 1 < parent.children.length) {
    const start = Number(match[1] ?? match[2] ?? match[3] ?? "1");
    after = (parent.tag === "ol" ? `<ol start="${start+index+1}">` : opening) + after + ending;
  }
  return [[parent.start,parent.end!,before+replacement+after]] as RangePatch[];
}

function styleOpening(opening: string, property: string, value: string, step: number) {
  const tagEnd = /^<[\w:-]+/.exec(opening)![0].length;
  const attributes = Array.from(opening.slice(tagEnd,-1).matchAll(attribute));
  const styles = attributes.filter(match => /^style(?:\s*=|$)/i.test(match[0]));
  if (styles.length > 1) return unsupported();
  if (!styles.length) {
    if (step > 0) value = `${step}px`;
    return value ? opening.slice(0,-1) + ` style="${property}:${value}">` : opening;
  }
  const attr = styles[0];
  const attrStart = tagEnd + attr.index;
  const assignment = /^([^=]*=\s*)(?:"([^"]*)"|'([^']*)'|(.*))$/s.exec(attr[0]);
  const raw = assignment?.[2] ?? assignment?.[3] ?? assignment?.[4] ?? "";
  const decoder = document.createElement("textarea");
  const shifts: {position:number; delta:number}[] = [];
  let delta = 0;
  const css = raw.replace(/&#(?:[0-9]+|[xX][0-9a-fA-F]+);?|&[a-zA-Z][a-zA-Z0-9]*(?:;|(?![a-zA-Z0-9=]))/g,
    (entity:string, index:number) => {
      const decoded = decode(entity,decoder);
      delta += entity.length-decoded.length;
      shifts.push({position:index+entity.length-delta,delta});
      return decoded;
    });
  function rawOffset(offset: number) {
    for (let i = shifts.length-1; i >= 0; i--)
      if (shifts[i].position <= offset) return offset + shifts[i].delta;
    return offset;
  }
  const declarations: [start:number,end:number][] = [];
  const pairs = {"(":")","[":"]","{":"}"} as const;
  const closing: string[] = [];
  let start = 0;
  for (const match of css.matchAll(/\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|\\[\s\S]|\/\*|[\\"'()[\]{};]/g)) {
    const token = match[0];
    if (token in pairs) closing.push(pairs[token as keyof typeof pairs]);
    else if ([")","]","}"].includes(token)) {
      if (closing.pop() !== token) return unsupported();
    } else if (['"',"'","/*","\\"].includes(token)) return unsupported();
    else if (token === ";" && !closing.length) {
      declarations.push([start,match.index]);
      start = match.index+1;
    }
  }
  if (closing.length) return unsupported();
  declarations.push([start,css.length]);
  const trivia = String.raw`(?:\s|/\*[\s\S]*?\*/)*`;
  const target = new RegExp(`^(${trivia})${property}${trivia}:([\\s\\S]*)$`,"i");
  const important = new RegExp(`!${trivia}important${trivia}$`,"i");
  const matches = declarations.flatMap(([start,end]) => {
    const match = target.exec(css.slice(start,end));
    return match ? [{start:start+match[1].length,end,content:match[2]}] : [];
  });
  if (step) {
    const prior = (matches.slice().reverse().find(match => important.test(match.content)) ?? matches.at(-1))?.content
      .replace(important,"").trim() ?? "";
    if (prior && !/^\d{1,3}px$/.test(prior)) return unsupported();
    const amount = Math.min(240,Math.max(0,Number.parseInt(prior || "0",10)+step));
    value = amount ? `${amount}px` : "";
  }
  let updated = raw;
  if (matches.length) updated = applyPatches(raw,matches.map(({start,end,content}) => [
    rawOffset(start),rawOffset(end),!value ? "" : `${property}:${value}` +
      (important.test(content) ? " !important" : "") + (content.match(/\s*$/)?.[0] ?? ""),
  ]));
  else if (value) updated = raw + (new RegExp(`^${trivia}$`).test(css.slice(declarations.at(-1)![0])) ? "" : ";") +
    `${property}:${value}`;
  if (updated === raw) return opening;
  if (!updated.replace(/[ ;\t\r\n\f]/g,""))
    return opening.slice(0,attrStart).trimEnd() + opening.slice(attrStart+attr[0].length);
  const quote = assignment?.[2] !== undefined ? '"' : assignment?.[3] !== undefined ? "'" : /[\s"'=`<>]/.test(updated) || !assignment ? '"' : "";
  return opening.slice(0,attrStart) + (assignment?.[1] ?? attr[0]+"=") + quote + updated + quote +
    opening.slice(attrStart+attr[0].length);
}

function containerPatches(source: string, edit: StructureEdit & {index:number}, block: Block, elements: ElementSpan[], blocks: Block[]) {
  const ancestors = elements.filter(node => node.openEnd <= block.start && node.closeStart !== undefined &&
    node.closeStart >= block.end).reverse();
  if (edit.kind === "check_item") {
    for (const node of ancestors) {
      if (node.tag !== "label") continue;
      const control = new RegExp(`^${checkbox}`,"i").exec(source.slice(node.openEnd));
      if (!control?.groups) continue;
      const end = node.openEnd + control[0].length - control.groups.close.length;
      const checked = control.groups.checked;
      return [[end-(checked?.length ?? 0),end,checked ? "" : " checked"]] as RangePatch[];
    }
    return unsupported();
  }
  if (edit.kind === "unlink" || edit.kind === "clear_format") {
    if (edit.kind === "clear_format" && (edit.start !== 0 || edit.end !== block.text.length)) return unsupported();
    const patches: RangePatch[] = [];
    for (const node of ancestors) {
      const opening = source.slice(node.start,node.openEnd);
      if (edit.kind === "unlink" ? node.tag !== "a" : !formatting.has(node.tag)) continue;
      if (edit.kind === "clear_format" &&
        (["span","font"].includes(node.tag) && !/^<(span|font)\s+style\s*=\s*(['"])[^'"]*\2\s*>$/i.test(opening) ||
          blocks.some(other => other.index !== block.index && other.text && other.start >= node.openEnd && other.end <= node.closeStart!)))
        continue;
      const drop = edit.kind === "unlink" ? ["href","target","rel","download"] : ["style"];
      const attrs = [...opening.slice(1+node.tag.length,-1).matchAll(attribute)]
        .filter(match => !drop.includes(match[0].split("=")[0].trim().toLowerCase())).map(match => " "+match[0]).join("");
      patches.push([node.start,node.openEnd,attrs ? `<span${attrs}>` : ""],[node.closeStart!,node.end!,attrs ? "</span>" : ""]);
      if (edit.kind === "unlink") break;
    }
    return patches;
  }
  const node = ancestors.find(entry => paragraphs.has(entry.tag) || entry.tag === "li" || entry.tag === "div");
  if (!node) return unsupported();
  const opening = source.slice(node.start,node.openEnd);
  if (edit.kind === "paragraph" && edit.value && paragraphs.has(edit.value) && node.tag !== "li") {
    if (node.tag === edit.value) return [];
    if (node.children.every(isPhrasing)) return [
      [node.start+1,node.start+1+node.tag.length,edit.value],
      [node.closeStart!+2,node.closeStart!+2+node.tag.length,edit.value],
    ] as RangePatch[];
    if (!["div","blockquote"].includes(node.tag) || !block.text.trim()) return unsupported();
    let start = node.openEnd, end = node.closeStart!;
    for (const child of node.children) {
      if (isPhrasing(child)) continue;
      if (child.end === undefined || child.start < block.end && block.start < child.end) return unsupported();
      if (child.end <= block.start) start = child.end;
      else if (child.start >= block.end) { end = child.start; break; }
    }
    return [[start,end,`<${edit.value}>${source.slice(start,end)}</${edit.value}>`]] as RangePatch[];
  }
  if (edit.kind === "list" && edit.value && ["bullet","number","check"].includes(edit.value)) {
    const item = ancestors.find(entry => entry.tag === "li");
    if (item) return replaceListItem(source,item,edit.value);
    if (!node.children.every(isPhrasing)) return unsupported();
    return [[node.start,node.end!,listItem(edit.value,opening.slice(1+node.tag.length,-1),
      source.slice(node.openEnd,node.closeStart))]] as RangePatch[];
  }
  if (edit.kind === "align" && edit.value && ["left","center","right","justify"].includes(edit.value))
    return [[node.start,node.openEnd,styleOpening(opening,"text-align",edit.value,0)]] as RangePatch[];
  if (edit.kind === "indent" || edit.kind === "outdent")
    return [[node.start,node.openEnd,styleOpening(opening,"margin-left","",edit.kind === "indent" ? 24 : -24)]] as RangePatch[];
  return unsupported();
}

export function editFormattedDraft(source: string, edit: StructureEdit, suppliedBlocks?: Block[]) {
  const {blocks:parsed,elements,bodyEnd} = scan(source);
  const blocks = suppliedBlocks ?? parsed;
  if (edit.kind === "insert_table") {
    const table = "<table><tbody>" + ("<tr>"+"<td></td>".repeat(edit.columns ?? 2)+"</tr>").repeat(edit.rows ?? 2) + "</tbody></table>";
    return {html:applyPatches(source,[[bodyEnd,bodyEnd,table]])};
  }
  if ("row" in edit) return {html:applyPatches(source,tablePatches(source,edit,elements))};
  const block = blocks.find(entry => entry.index === edit.index);
  if (!block) return unsupported();
  if ("start" in edit && edit.kind !== "unlink" && edit.kind !== "clear_format") {
    const {patches,focus} = inlinePatch(source,edit,block,elements);
    return {html:applyPatches(source,patches),focus};
  }
  const patches = containerPatches(source,edit,block,elements,blocks);
  const raw = source.slice(block.start,block.end);
  let offset = block.start;
  let found = true;
  for (const [start,end,replacement] of patches.sort((a,b) => a[0]-b[0])) {
    if (end <= block.start) offset += replacement.length-(end-start);
    else if (start <= block.start && end >= block.end) {
      const index = replacement.indexOf(raw);
      found = !!raw && index >= 0 && replacement.lastIndexOf(raw) === index;
      offset += start + index - block.start;
    }
  }
  const selection = found ? [offset,offset+raw.length] as const : undefined;
  return {html:applyPatches(source,patches),focus:selection};
}

export function formattedSelection(blocks: Block[], source: string, range: readonly [number,number]) {
  const [start,end] = range;
  const block = blocks.find(entry => start >= entry.start && end <= entry.end && entry.text.length);
  if (!block) return undefined;
  const decoder = document.createElement("textarea");
  return {index:block.index,start:decode(source.slice(block.start,start),decoder).length,
    end:decode(source.slice(block.start,end),decoder).length};
}
