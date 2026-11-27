"""Translate local attachment URLs through verified source bindings for the NAS."""
from html import escape, unescape
from html.parser import HTMLParser
import json
import re
import uuid
from urllib.parse import parse_qs, unquote, urlsplit

from .compat.errors import CLIError


_ATTR = re.compile(r'''\s+([\w:-]+)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?''')


def references_file(source: str, identities: set[str], filename: str) -> bool:
    decoded = unquote(unescape(source)).casefold()
    if any(value in decoded for value in identities):
        return True

    class Names(HTMLParser):
        found = False

        def handle_starttag(self, tag, attrs):
            for name, raw in attrs:
                if not raw or name not in {"ref", "content_id", "href", "src", "data", "poster"}:
                    continue
                if name in {"ref", "content_id"} and unquote(raw) == filename:
                    self.found = True
                    return
                try:
                    query = parse_qs(urlsplit(raw).query)
                except ValueError:
                    continue
                for key in ("file_id", "ref", "content_id"):
                    for candidate in query.get(key, []):
                        if candidate == filename:
                            self.found = True
                            return
                        if candidate.startswith('"'):
                            try:
                                candidate = json.loads(candidate)
                            except ValueError:
                                continue
                        if candidate == filename:
                            self.found = True
                            return

    parser = Names()
    parser.feed(source)
    parser.close()
    return parser.found


def bind_html(source: str, bindings: dict, files: list[dict], download_url) -> str:
    replacements = []
    lines = [0] + [i + 1 for i, char in enumerate(source) if char == '\n']
    normalized = {}
    for key, value in bindings.items():
        uid = str(uuid.UUID(key))
        if uid in normalized:
            raise CLIError('INVALID_SOURCE', 'The attachment binding is duplicated.')
        normalized[uid] = value

    class Tags(HTMLParser):
        def handle_starttag(self, tag, attrs):
            attr = 'src' if tag == 'img' else 'href' if tag == 'a' else None
            values = [value for key, value in attrs if key == attr]
            if not values or not (values[0] or '').lower().startswith('attachment:'):
                return
            try:
                if len(values) != 1 or not values[0].lower().startswith('attachment://'):
                    raise ValueError()
                uid = str(uuid.UUID(values[0][len('attachment://'):]))
                matches = [f for f in files if f['id'] == normalized.get(uid)]
                if len(matches) != 1:
                    raise ValueError()
            except ValueError as exc:
                raise CLIError('INVALID_SOURCE', 'Could not verify the attachment binding.') from exc
            file = matches[0]
            raw = self.get_starttag_text()
            changes = []
            for match in _ATTR.finditer(raw):
                key = match.group(1).lower()
                if key == attr or key == 'ref':
                    changes.append((match.start(), match.end(), ''))
            for start, end, value in reversed(changes):
                raw = raw[:start] + value + raw[end:]
            attributes = f' ref="{escape(file.get("ref") or file["id"], quote=True)}"'
            if tag == 'a':
                attributes += f' href="{escape(download_url(file["id"]), quote=True)}"'
            closing = raw.rfind('/>') if raw.endswith('/>') else len(raw) - 1
            raw = raw[:closing] + attributes + raw[closing:]
            line, column = self.getpos()
            start = lines[line - 1] + column
            replacements.append((start, start + len(self.get_starttag_text()), raw))

        def handle_startendtag(self, tag, attrs):
            self.handle_starttag(tag, attrs)

    parser = Tags(convert_charrefs=True)
    parser.feed(source)
    parser.close()
    for start, end, value in reversed(replacements):
        source = source[:start] + value + source[end:]
    return source
