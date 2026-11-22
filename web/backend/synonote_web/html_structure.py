"""Apply allowlisted formatting commands to the original HTML source."""
from dataclasses import dataclass, field
from html import escape, unescape
from html.parser import HTMLParser
import re
from urllib.parse import urlsplit


FORMATS = {"bold": "strong", "italic": "em", "underline": "u", "strike": "s",
           "subscript": "sub", "superscript": "sup"}
FONTS = {"system-ui", "Arial", "Georgia", "Times New Roman", "Helvetica", "Apple SD Gothic Neo", "AppleMyungjo", "Menlo"}
STYLES = {"font_family": "font-family", "font_size": "font-size",
          "text_color": "color", "highlight_color": "background-color"}


def _inline_tags(kind: str, value: str | None) -> tuple[str, str]:
    if kind in FORMATS:
        tag = FORMATS[kind]
        return f"<{tag}>", f"</{tag}>"
    if isinstance(value, str):
        if kind == "link" and not re.search(r"[\x00-\x20\x7f\\]", value):
            try:
                url = urlsplit(value)
            except ValueError:
                url = None
            if url and (value.startswith("#") or (url.scheme == "mailto" and url.path)
                        or (url.scheme in {"http", "https"} and url.hostname)):
                return f'<a href="{escape(value, quote=True)}">', "</a>"
        if (kind == "font_family" and value in FONTS
                or kind == "font_size" and re.fullmatch(r"[0-9]{1,2}", value) and 8 <= int(value) <= 72
                or kind in {"text_color", "highlight_color"} and re.fullmatch(r"#[0-9a-fA-F]{6}", value)):
            css_value = f"{value}px" if kind == "font_size" else value
            return f'<span style="{STYLES[kind]}:{css_value}">', "</span>"
    raise ValueError("Invalid formatting value")


@dataclass
class _Element:
    tag: str
    start: int
    opened: int
    end: int | None = None
    children: list["_Element"] = field(default_factory=list)
    columns: list["_Element"] = field(default_factory=list)
    simple: bool = True


class _Tables(HTMLParser):
    def __init__(self, source: str):
        super().__init__()
        self.source = source
        self.lines = [0] + [i + 1 for i, char in enumerate(source) if char == "\n"]
        self.tables: list[_Element] = []
        self.stack: list[_Element] = []
        self.column_group: _Element | None = None
        self.body_end: int | None = None

    def position(self):
        line, column = self.getpos()
        return self.lines[line - 1] + column

    def handle_starttag(self, tag, attrs):
        parent = self.stack[-1] if self.stack else None
        if tag in {"colgroup", "col"} and parent and parent.tag == "table":
            start = self.position()
            item = _Element(tag, start, start + len(self.get_starttag_text()),
                            simple=all(name != "span" or value == "1" for name, value in attrs))
            if tag == "colgroup":
                parent.columns.append(item)
                self.column_group = item
            else:
                item.end = item.opened
                if self.column_group:
                    self.column_group.children.append(item)
                else:
                    parent.columns.append(item)
            return
        if tag not in {"table", "tr", "td", "th"}:
            return
        start = self.position()
        item = _Element(tag, start, start + len(self.get_starttag_text()))
        self.column_group = None
        if tag == "table":
            if parent:
                item.simple = False
                self.stack[0].simple = False
            self.tables.append(item)
        elif parent is None:
            return
        elif tag == "tr" and parent.tag == "table" or tag in {"td", "th"} and parent.tag == "tr":
            item.simple = all(name not in {"colspan", "rowspan"} or value == "1" for name, value in attrs)
            parent.children.append(item)
        else:
            self.stack[0].simple = False
        self.stack.append(item)

    def handle_endtag(self, tag):
        if tag == "body":
            self.body_end = self.position()
        if tag == "colgroup" and self.column_group:
            self.column_group.end = self.source.index(">", self.position()) + 1
            self.column_group = None
        if self.stack and self.stack[-1].tag == tag:
            item = self.stack.pop()
            item.end = self.source.index(">", self.position()) + 1

    def handle_startendtag(self, tag, attrs):
        if tag == "col":
            self.handle_starttag(tag, attrs)
        if tag in {"table", "tr", "td", "th"} and self.stack:
            self.stack[0].simple = False


def _tables(source: str) -> _Tables:
    parser = _Tables(source)
    parser.feed(source)
    parser.close()
    return parser


def _valid_grid(table: _Element) -> bool:
    rows = table.children
    return bool(table.simple and table.end is not None and rows and rows[0].children
                and all(row.end is not None and len(row.children) == len(rows[0].children)
                        and all(cell.end is not None and cell.simple for cell in row.children)
                        for row in rows))


def table_markers(source: str, token: str) -> list[tuple[int, str]]:
    markers = []
    for index, table in enumerate(_tables(source).tables):
        if not _valid_grid(table):
            continue
        # HTML keeps the first value of a duplicated attribute. Only the
        # preview receives these attributes, before any original attributes.
        markers.append((table.start + len("<table"), f' data-structure-token="{token}" data-table-index="{index}"'))
        for row, cells in enumerate(table.children):
            for column, cell in enumerate(cells.children):
                markers.append((cell.start + 1 + len(cell.tag), f' data-structure-token="{token}" data-table-row="{row}" data-table-column="{column}"'))
    return markers


def _cells(row: _Element) -> str:
    return "".join(f"<{cell.tag}></{cell.tag}>" for cell in row.children)


def _column_definition_edit(table: _Element, column: int, kind: str) -> list[tuple[int, int, str]]:
    definitions = [(group, definition) for group in table.columns
                   for definition in group.children or [group]]
    if any(not group.simple or not definition.simple or group.end is None or definition.end is None
           for group, definition in definitions):
        raise ValueError("Unsupported column definitions")
    if len(definitions) > len(table.children[0].children):
        raise ValueError("Column definitions differ from table grid")
    if column >= len(definitions):
        return []
    group, definition = definitions[column]
    if kind == "delete_column":
        target = group if len(group.children) == 1 else definition
        return [(target.start, target.end, "")]
    position = definition.start if kind == "column_before" else definition.end
    markup = "<colgroup></colgroup>" if definition.tag == "colgroup" else "<col>"
    return [(position, position, markup)]


def replace_ranges(source: str, ranges: list[tuple[int, int, str]]) -> str:
    pieces = []
    cursor = 0
    for start, end, value in sorted(ranges):
        pieces.extend((source[cursor:start], value))
        cursor = end
    pieces.append(source[cursor:])
    return "".join(pieces)


def _format(source: str, edit: dict) -> str:
    from .html_text import text_blocks

    blocks = text_blocks(source)
    index, start, end = (edit.get(name) for name in ("index", "start", "end"))
    if any(type(value) is not int for value in (index, start, end)) or not 0 <= index < len(blocks):
        raise ValueError("Missing or invalid text selection")
    block = blocks[index]
    text = block.text.encode("utf-16-le")
    if not 0 <= start < end <= len(text) // 2:
        raise ValueError("Invalid text selection")
    raw = source[block.start:block.end]
    boundaries = {0: 0}
    units = 0
    for token in re.finditer(r"&#(?:[0-9]+|[xX][0-9a-fA-F]+);?|&[a-zA-Z][a-zA-Z0-9]*;?|[\s\S]", raw):
        units += len(unescape(token.group()).encode("utf-16-le")) // 2
        boundaries[units] = token.end()
    if unescape(raw) != block.text or start not in boundaries or end not in boundaries:
        raise ValueError("Invalid text boundary")
    left, right = boundaries[start], boundaries[end]
    prefix, value, suffix = raw[:left], raw[left:right], raw[right:]
    if edit["kind"] == "link":
        parser = _Containers(source)
        parser.feed(source)
        parser.close()
        if any(node.tag == "a" and node.opened <= block.start <= block.end <= end
               for node, end in parser.closed):
            raise ValueError("Selection is already inside an existing link")
    opening, closing = _inline_tags(edit["kind"], edit.get("value"))
    if (edit["kind"] in FORMATS and not prefix and not suffix and source[:block.start].endswith(opening)
            and source[block.end:].startswith(closing)):
        return replace_ranges(source, [(block.start - len(opening), block.end + len(closing), value)])
    return replace_ranges(source, [(block.start, block.end, f"{prefix}{opening}{value}{closing}{suffix}")])


def apply_structure(source: str, edit: dict) -> str:
    kind = edit["kind"]
    if kind in {"paragraph", "align", "list", "indent", "outdent", "unlink", "clear_format", "check_item"}:
        return _edit_container(source, edit)
    if kind in FORMATS or kind in STYLES or kind == "link":
        return _format(source, edit)
    parser = _tables(source)
    if kind == "insert_table":
        position = parser.body_end if parser.body_end is not None else len(source)
        rows = edit.get("rows")
        columns = edit.get("columns")
        rows = 2 if rows is None else rows
        columns = 2 if columns is None else columns
        if type(rows) is not int or type(columns) is not int or not 1 <= rows <= 30 or not 1 <= columns <= 20:
            raise ValueError("Invalid table size")
        table = "<table><tbody>" + ("<tr>" + "<td></td>" * columns + "</tr>") * rows + "</tbody></table>"
        return replace_ranges(source, [(position, position, table)])
    index = edit.get("index")
    if type(index) is not int or not 0 <= index < len(parser.tables):
        raise ValueError("Unknown table")
    table = parser.tables[index]
    if not _valid_grid(table):
        raise ValueError("Unsupported table")
    if kind == "delete_table":
        return replace_ranges(source, [(table.start, table.end, "")])

    rows = table.children
    row, column = edit.get("row"), edit.get("column")
    if type(row) is not int or type(column) is not int or not 0 <= row < len(rows) or not 0 <= column < len(rows[row].children):
        raise ValueError("Unknown cell")
    selected = rows[row]
    if kind in {"row_before", "row_after"}:
        position = selected.start if kind == "row_before" else selected.end
        return replace_ranges(source, [(position, position, f"<tr>{_cells(selected)}</tr>")])
    if kind == "delete_row" and len(rows) > 1:
        return replace_ranges(source, [(selected.start, selected.end, "")])
    cells = [entry.children[column] for entry in rows]
    if kind == "delete_column" and len(selected.children) > 1:
        ranges = _column_definition_edit(table, column, kind)
        return replace_ranges(source, ranges + [(cell.start, cell.end, "") for cell in cells])
    if kind in {"column_before", "column_after"}:
        ranges = _column_definition_edit(table, column, kind)
        for cell in cells:
            position = cell.start if kind == "column_before" else cell.end
            ranges.append((position, position, f"<{cell.tag}></{cell.tag}>"))
        return replace_ranges(source, ranges)
    raise ValueError("Unsupported table edit")


class _Containers(_Tables):
    def __init__(self, source: str):
        super().__init__(source)
        self.closed: list[tuple[_Element, int]] = []

    def handle_starttag(self, tag, attrs):
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                       "param", "source", "track", "wbr"}:
            start = self.position()
            self.stack.append(_Element(tag, start, start + len(self.get_starttag_text())))

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index].tag == tag:
                element = self.stack[index]
                del self.stack[index:]
                end = self.position()
                element.end = self.source.index(">", end) + 1
                self.closed.append((element, end))
                break

    def handle_startendtag(self, tag, attrs):
        pass


_PARAGRAPHS = {"p", "h1", "h2", "h3", "h4", "pre", "blockquote"}
_INLINE_FORMATTING = set(FORMATS.values()) | {"b", "i", "strike", "font", "span", "mark"}


def _edit_container(source: str, edit: dict) -> str:
    from .html_text import text_blocks

    blocks = text_blocks(source)
    index = edit.get("index")
    if type(index) is not int or not 0 <= index < len(blocks):
        raise ValueError("Invalid text selection")
    block = blocks[index]
    parser = _Containers(source)
    parser.feed(source)
    parser.close()
    ancestors = [(node, end) for node, end in parser.closed if node.opened <= block.start <= block.end <= end]
    kind, value = edit["kind"], edit.get("value")
    if kind == "check_item":
        for node, _ in ancestors:
            if node.tag != "label":
                continue
            control = re.match(r"""<input\s+type=(["'])checkbox\1(?P<checked> checked)?>""",
                               source[node.opened:], re.I)
            if control:
                end = node.opened + control.end() - 1
                return replace_ranges(source, [(end - 8, end, "")] if control["checked"] else
                                      [(end, end, " checked")])
        raise ValueError("Unsupported checklist item")
    if kind in {"unlink", "clear_format"}:
        tags = {"a"} if kind == "unlink" else _INLINE_FORMATTING
        first, last = edit.get("start"), edit.get("end")
        if kind == "clear_format" and (first != 0 or last != len(block.text.encode("utf-16-le")) // 2):
            raise ValueError("Select the complete formatted run")
        ranges = []
        for node, closing in ancestors:
            if node.tag not in tags:
                continue
            if kind == "clear_format" and (node.tag in {"span", "font"} and
                                           not re.fullmatch(r"""<(?:span|font)\s+style\s*=\s*(['"])[^'"]*\1\s*>""",
                                                            source[node.start:node.opened], re.I)):
                continue
            if kind == "clear_format" and any(
                other.start >= node.opened and other.end <= closing and other.text
                and (other.start, other.end) != (block.start, block.end) for other in blocks
            ):
                continue
            attrs = source[node.start + 1 + len(node.tag):node.opened - 1]
            attrs = "".join(" " + m.group() for m in _ATTRIBUTES.finditer(attrs)
                            if m.group().split("=", 1)[0].strip().lower()
                            not in ({"href", "target", "rel", "download"} if kind == "unlink" else {"style"}))
            ranges.extend([(node.start, node.opened, f"<span{attrs}>" if attrs else ""),
                           (closing, node.end, "</span>" if attrs else "")])
            if kind == "unlink":
                break
        return replace_ranges(source, ranges)
    target = next(((node, closing) for node, closing in ancestors if node.tag in _PARAGRAPHS | {"li", "div"}), None)
    if target is None:
        raise ValueError("Unsupported paragraph")
    node, closing = target
    opening = source[node.start:node.opened]
    if kind == "paragraph" and value in _PARAGRAPHS and node.tag != "li":
        return replace_ranges(source, [(node.start + 1, node.start + 1 + len(node.tag), value),
                                       (closing + 2, closing + 2 + len(node.tag), value)])
    if kind == "list" and value in {"bullet", "number", "check"} and node.tag in _PARAGRAPHS:
        if any(parent.tag == "li" for parent, _ in ancestors):
            raise ValueError("Unsupported nested list")
        tag = "ol" if value == "number" else "ul"
        attrs = opening[1 + len(node.tag):-1]
        checked = value == "check"
        prefix = '<label><input type="checkbox"> ' if checked else ""
        suffix = "</label>" if checked else ""
        return replace_ranges(source, [(node.start, node.opened, f"<{tag}><li{attrs}>{prefix}"),
                                       (closing, node.end, f"{suffix}</li></{tag}>")])
    if kind == "align" and value in {"left", "center", "right", "justify"}:
        updated = _style_opening(opening, "text-align", value)
    elif kind in {"indent", "outdent"}:
        updated = _style_opening(opening, "margin-left", step=24 if kind == "indent" else -24)
    else:
        raise ValueError("Invalid paragraph command")
    return replace_ranges(source, [(node.start, node.opened, updated)])


_ATTRIBUTES = re.compile(r"""[^\s=<>/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?""")


def _style_opening(opening: str, name: str, value: str = "", *, step: int = 0) -> str:
    tag_end = re.match(r"<[\w:-]+", opening).end()
    attrs = [(m, m.group().split("=", 1)[0].strip().lower())
             for m in _ATTRIBUTES.finditer(opening, tag_end, len(opening) - 1)]
    styles = [m for m, key in attrs if key == "style"]
    if len(styles) > 1:
        raise ValueError("Ambiguous style")
    prior = ""
    remaining = []
    if styles:
        match = styles[0]
        raw = match.group().partition("=")[2].strip()
        if raw.startswith(("'", '"')):
            raw = raw[1:-1]
        for declaration in raw.split(";"):
            key, _, content = declaration.partition(":")
            if key.strip().lower() == name:
                prior = content.strip()
            elif declaration.strip():
                remaining.append(declaration.strip())
    if step:
        if prior and not re.fullmatch(r"[0-9]{1,3}px", prior):
            raise ValueError("Unsupported indentation")
        amount = min(240, max(0, (int(prior[:-2]) if prior else 0) + step))
        value = f"{amount}px" if amount else ""
    replacement = ";".join([*remaining, *([f"{name}:{value}"] if value else [])])
    if styles:
        start = match.start()
        if not replacement:
            while start > tag_end and opening[start - 1].isspace():
                start -= 1
        return opening[:start] + (f'style="{replacement.replace(chr(34), "&quot;")}"' if replacement else "") + opening[match.end():]
    return opening[:-1] + (f' style="{replacement}"' if replacement else "") + ">"
