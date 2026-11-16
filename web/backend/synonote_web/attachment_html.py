"""Translate local attachment URLs through verified source bindings for the NAS."""
from html import escape
from html.parser import HTMLParser
import re
import uuid

from .compat.errors import CLIError


_ATTR = re.compile(r'''\s+([\w:-]+)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?''')


def bind_html(source: str, bindings: dict, files: list[dict], download_url) -> str:
    replacements = []
    lines = [0] + [i + 1 for i, char in enumerate(source) if char == '\n']
    normalized = {}
    for key, value in bindings.items():
        uid = str(uuid.UUID(key))
        if uid in normalized:
            raise CLIError('INVALID_SOURCE', '중복 첨부 바인딩입니다.')
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
                raise CLIError('INVALID_SOURCE', '첨부 바인딩을 확인할 수 없습니다.') from exc
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
