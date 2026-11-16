"""Swift ServerHTMLRenderer-compatible output for the supported CommonMark subset.

Fail closed on syntax whose byte-level server rendering is not cross-tested.
"""
from __future__ import annotations

from html import escape
import re
import hashlib
import uuid

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
            raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", f"지원하지 않는 Markdown 인라인 형식: {typ}")
    return result


def render(markdown: str, blocks: list[dict] | None = None, math_images: dict | None = None) -> str:
    blocks = blocks or []
    if not validate_blocks(markdown, blocks):
        raise CLIError("INVALID_SOURCE", "보존 블록과 Markdown 토큰이 일치하지 않습니다.")
    preserved = {block["id"]: block["html"] for block in blocks}
    masked, formulas = math_plan(markdown)
    if formulas and math_images is None:
        raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "수식 이미지를 준비하세요.")
    tokens = PARSER.parse(masked)
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
            raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", f"지원하지 않는 Markdown 블록 형식: {typ}")
        index += 1
    result = "".join(chunks)
    for formula in formulas:
        asset = (math_images or {}).get(formula['key'])
        if not asset:
            raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "수식 이미지가 없습니다.")
        delimiter = '$$' if formula['display'] else '$'
        image = f'<img ref="{escaped(asset["ref"])}" alt="{escaped(delimiter + formula["tex"] + delimiter)}" width="{int(asset["width"])}" height="{int(asset["height"])}" style="{"display:block;" if formula["display"] else ""}max-width:100%;vertical-align:middle">'
        result = result.replace(formula['token'], image)
    return result


def math_plan(markdown: str) -> tuple[str, list[dict]]:
    # Mask literal code, HTML and destinations before looking for TeX delimiters.
    protected = re.compile(r"(?ms)^```[^\n]*\n.*?^```[^\n]*$|^~~~[^\n]*\n.*?^~~~[^\n]*$|`+[^`]*`+|<(?:pre|code|script|style)\b.*?</(?:pre|code|script|style)>|<[^>]+>|!\[[^\]]*\]\([^)]*\)|\]\([^)]*\)")
    ranges = [m.span() for m in protected.finditer(markdown)]
    starts = [0]
    for line in markdown.splitlines(keepends=True): starts.append(starts[-1] + len(line))
    for token in PARSER.parse(markdown):
        if token.type in ('fence', 'code_block', 'html_block') and token.map:
            ranges.append((starts[token.map[0]], starts[token.map[1]]))
    pattern = re.compile(r"(?<![\\$])\$\$([\s\S]+?)\$\$|(?<!\\)\\\[([\s\S]+?)\\\]|(?<!\\)\\\(([^\n]*?)\\\)|(?<![\\$])\$(?![\s$])([^\n$]+?)(?<!\s)\$(?![\d$])")
    formulas = []
    prefix = 'SynologyMath' + uuid.uuid4().hex
    def replace(match):
        if any(match.start() < end and match.end() > start for start, end in ranges):
            return match.group()
        tex = next(v for v in match.groups() if v is not None)
        display = match.group(1) is not None or match.group(2) is not None
        key = hashlib.sha256(('math-png-v1\n' + str(display).lower() + '\n' + tex).encode()).hexdigest()
        token = prefix + str(len(formulas)) + 'End'
        formulas.append(dict(key=key, tex=tex, display=display, token=token))
        return token + '\n' * match.group().count('\n')
    return pattern.sub(replace, markdown), formulas
