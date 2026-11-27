"""Swift ServerHTMLRenderer-compatible output for the supported CommonMark subset.

Fail closed on syntax whose byte-level server rendering is not cross-tested.
"""
from __future__ import annotations

from html import escape
import re

from markdown_it import MarkdownIt

from .errors import CLIError
from .source_envelope import TOKEN, validate_blocks


def escaped(value: str | int) -> str:
    return escape(str(value), quote=True).replace("&#x27;", "&#39;")


PARSER = MarkdownIt("commonmark", {"html": True, "breaks": False, "typographer": False}).enable("table").enable("strikethrough")


def _plain(children) -> str:
    return "".join(t.content if t.type in ("text", "code_inline") else _plain(t.children or []) for t in children)


def _inline(children) -> str:
    result = ""
    for t in children:
        typ = t.type
        if typ == "text":
            result += escaped(t.content)
        elif typ == "code_inline":
            result += "<code>" + escaped(t.content) + "</code>"
        elif typ == "softbreak":
            result += "\n"
        elif typ == "hardbreak":
            result += "<br>\n"
        elif typ in ("em_open", "strong_open", "s_open"):
            result += {"em_open": "<em>", "strong_open": "<strong>", "s_open": "<del>"}[typ]
        elif typ in ("em_close", "strong_close", "s_close"):
            result += {"em_close": "</em>", "strong_close": "</strong>", "s_close": "</del>"}[typ]
        elif typ == "link_open":
            href = t.attrGet("href")
            title = t.attrGet("title")
            result += "<a" + (f' href="{escaped(href)}"' if href is not None else "") + (f' title="{escaped(title)}"' if title is not None else "") + ">"
        elif typ == "link_close":
            result += "</a>"
        elif typ == "image":
            src = t.attrGet("src")
            title = t.attrGet("title")
            result += "<img" + (f' src="{escaped(src)}"' if src is not None else "") + f' alt="{escaped(_plain(t.children or []))}"' + (f' title="{escaped(title)}"' if title is not None else "") + ">"
        elif typ == "html_inline":
            result += t.content
        else:
            raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", f"Unsupported Markdown inline token: {typ}")
    return result


def render(markdown: str, blocks: list[dict] | None = None) -> str:
    blocks = blocks or []
    if not validate_blocks(markdown, blocks):
        raise CLIError("INVALID_SOURCE", "The preserved blocks do not match the Markdown tokens.")
    preserved = {block["id"]: block["html"] for block in blocks}
    # MathExport needs cross-platform PNG assets. Prevent silent downgrade to text.
    if re.search(r"(?<!\\)(?<!\$)\$\$|(?<!\\)(?<!\$)\$(?!\s|\$)[^\n$]+?\$(?!\$)", markdown):
        raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "TeX formulas cannot be uploaded until PNG equivalence has been verified.")
    tokens = PARSER.parse(markdown)
    chunks: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        typ = token.type
        if typ == "paragraph_open" and index + 2 < len(tokens) and tokens[index + 1].type == "inline":
            match = TOKEN.fullmatch(tokens[index + 1].content.strip())
            if match and match.group(1) in preserved and tokens[index + 2].type == "paragraph_close":
                chunks.append(preserved[match.group(1)] + "\n")
                index += 3
                continue
        if typ == "inline":
            chunks.append(_inline(token.children or []))
        elif typ == "heading_open":
            chunks.append("<" + token.tag + ">")
        elif typ == "heading_close":
            chunks.append("</" + token.tag + ">\n")
        elif typ == "paragraph_open":
            chunks.append("<p>")
        elif typ == "paragraph_close":
            chunks.append("</p>\n")
        elif typ == "blockquote_open":
            chunks.append("<blockquote>")
        elif typ == "blockquote_close":
            chunks.append("</blockquote>\n")
        elif typ in ("bullet_list_open", "ordered_list_open"):
            if typ == "bullet_list_open":
                chunks.append("<ul>")
            else:
                start = token.attrGet("start")
                chunks.append("<ol" + (f' start="{escaped(start)}"' if start and start != "1" else "") + ">")
        elif typ in ("bullet_list_close", "ordered_list_close"):
            chunks.append("</ul>\n" if typ == "bullet_list_close" else "</ol>\n")
        elif typ == "list_item_open":
            # GFM task marker appears as first text token in the list item's inline content.
            item = tokens[index + 2] if index + 2 < len(tokens) else None
            checkbox = ""
            if item is not None and item.type == "inline" and item.children:
                first = item.children[0]
                match = re.match(r"^\[([ xX])\]([ \t]+)", first.content) if first.type == "text" else None
                if match:
                    first.content = first.content[match.end():]
                    line = token.map[0] + 1 if token.map else 1
                    checkbox = f'<input type="checkbox" data-md-task="{line}" disabled' + (" checked" if match.group(1).lower() == "x" else "") + "> "
            chunks.append("<li>" + checkbox)
        elif typ == "list_item_close":
            chunks.append("</li>\n")
        elif typ == "hr":
            chunks.append("<hr>\n")
        elif typ in ("fence", "code_block"):
            language = token.info.split()[0] if typ == "fence" and token.info.strip() else None
            attr = f' class="language-{escaped(language)}"' if language else ""
            chunks.append(f"<pre><code{attr}>{escaped(token.content)}</code></pre>\n")
        elif typ == "html_block":
            chunks.append(token.content)
        elif typ in ("table_open", "thead_open", "tbody_open", "tr_open", "th_open", "td_open"):
            if typ == "table_open":
                chunks.append("<table>")
            else:
                align = token.attrGet("style")
                position = re.search(r"text-align:(left|right|center)", align or "")
                chunks.append("<" + token.tag + (f' align="{position.group(1)}"' if position else "") + ">")
        elif typ in ("table_close", "thead_close", "tbody_close", "tr_close", "th_close", "td_close"):
            chunks.append("</" + token.tag + ">" + ("\n" if typ == "table_close" else ""))
        else:
            raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", f"Unsupported Markdown block token: {typ}")
        index += 1
    return "".join(chunks)
