"""Apply allowlisted formatting commands to the original HTML source."""
from dataclasses import dataclass, field
from html import escape
from html.parser import HTMLParser


FORMATS = {"bold": "strong", "italic": "em", "underline": "u", "strike": "s"}


@dataclass
class _Element:
    tag: str
    start: int
    opened: int
    end: int | None = None
    children: list["_Element"] = field(default_factory=list)
    simple: bool = True


class _Tables(HTMLParser):
    def __init__(self, source: str):
        super().__init__()
        self.source = source
        self.lines = [0] + [i + 1 for i, char in enumerate(source) if char == "\n"]
        self.tables: list[_Element] = []
        self.stack: list[_Element] = []
        self.body_end: int | None = None

    def position(self):
        line, column = self.getpos()
        return self.lines[line - 1] + column

    def handle_starttag(self, tag, attrs):
        if tag not in {"table", "tr", "td", "th"}:
            return
        start = self.position()
        item = _Element(tag, start, start + len(self.get_starttag_text()))
        parent = self.stack[-1] if self.stack else None
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
        if self.stack and self.stack[-1].tag == tag:
            item = self.stack.pop()
            item.end = self.source.index(">", self.position()) + 1

    def handle_startendtag(self, tag, attrs):
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
        markers.append((table.opened - 1, f' data-structure-token="{token}" data-table-index="{index}"'))
        for row, cells in enumerate(table.children):
            for column, cell in enumerate(cells.children):
                markers.append((cell.opened - 1, f' data-structure-token="{token}" data-table-row="{row}" data-table-column="{column}"'))
    return markers


def _cells(row: _Element) -> str:
    return "".join(f"<{cell.tag}></{cell.tag}>" for cell in row.children)


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
    prefix, value, suffix = (escape(part.decode("utf-16-le"), quote=False)
                             for part in (text[:2 * start], text[2 * start:2 * end], text[2 * end:]))
    tag = FORMATS[edit["kind"]]
    opening, closing = f"<{tag}>", f"</{tag}>"
    if (not prefix and not suffix and source[:block.start].endswith(opening)
            and source[block.end:].startswith(closing)):
        return replace_ranges(source, [(block.start - len(opening), block.end + len(closing), value)])
    return replace_ranges(source, [(block.start, block.end, f"{prefix}{opening}{value}{closing}{suffix}")])


def apply_structure(source: str, edit: dict) -> str:
    kind = edit["kind"]
    if kind in FORMATS:
        return _format(source, edit)
    parser = _tables(source)
    if kind == "insert_table":
        position = parser.body_end if parser.body_end is not None else len(source)
        table = "<table><tbody>" + "<tr><td></td><td></td></tr>" * 2 + "</tbody></table>"
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
        return replace_ranges(source, [(cell.start, cell.end, "") for cell in cells])
    if kind in {"column_before", "column_after"}:
        ranges = []
        for cell in cells:
            position = cell.start if kind == "column_before" else cell.end
            ranges.append((position, position, f"<{cell.tag}></{cell.tag}>"))
        return replace_ranges(source, ranges)
    raise ValueError("Unsupported table edit")
