"""Edit HTML text by source offsets; never reserialize the original document."""
from dataclasses import dataclass
from html import escape, unescape
from html.parser import HTMLParser
import secrets
import re


@dataclass(frozen=True)
class TextBlock:
    start: int
    end: int
    text: str


class _Spans(HTMLParser):
    def __init__(self, source: str):
        super().__init__(convert_charrefs=True)
        self.source = source
        self.lines = [0] + [i + 1 for i, char in enumerate(source) if char == '\n']
        self.events: list[tuple[int, str, bool]] = []
        self.stack: list[str] = []
    def mark(self, kind):
        line, column = self.getpos()
        self.events.append((self.lines[line-1]+column, kind, any(v in self.stack for v in ('script','style','svg','math','textarea','title','head'))))
    def handle_starttag(self, tag, attrs):
        self.mark('tag')
        if tag not in {'br','hr','img','input','meta','link','source','wbr','area','base','embed','param','track','col'}: self.stack.append(tag)
    def handle_startendtag(self, tag, attrs): self.mark('tag')
    def handle_endtag(self, tag):
        self.mark('tag')
        if tag in self.stack:
            self.stack = self.stack[:len(self.stack)-1-self.stack[::-1].index(tag)]
    def handle_data(self, data): self.mark('text')
    def handle_comment(self, data): self.mark('tag')
    def handle_decl(self, decl): self.mark('tag')
    def handle_pi(self, data): self.mark('tag')
    def unknown_decl(self, data): self.mark('tag')


def text_blocks(source: str) -> list[TextBlock]:
    parser = _Spans(source)
    parser.feed(source); parser.close()
    blocks=[]
    for i,(start, kind, excluded) in enumerate(parser.events):
        end = parser.events[i+1][0] if i+1 < len(parser.events) else len(source)
        if kind == 'text' and not excluded:
            raw=source[start:end]
            text=unescape(raw)
            previous = parser.events[i-1][0] if i else start
            text_parent = re.fullmatch(r"<(p|div|h[1-6]|li|blockquote|pre|code)\b[^>]*>",source[previous:start],re.I)
            if text.strip() or text_parent: blocks.append(TextBlock(start,end,text))
        elif kind == 'tag' and not excluded:
            opening = re.fullmatch(r"<(p|div|h[1-6]|li|blockquote|pre|code)\b[^>]*>", source[start:end], re.I)
            if opening and re.match(r"</\s*"+opening.group(1)+r"\s*>",source[end:],re.I):
                blocks.append(TextBlock(end,end,''))
    return sorted(blocks,key=lambda block:block.start)


def annotate(source: str) -> dict:
    blocks=text_blocks(source); token=secrets.token_hex(16); preview=source
    for index,block in reversed(list(enumerate(blocks))):
        preview=(preview[:block.start]+f'<span data-edit-token="{token}" data-text-index="{index}">'+escape(block.text,quote=False)+'</span>'+preview[block.end:])
    return {'html_text_preview':preview,'html_text_token':token,
            'html_text_blocks':[{'index':i,'text':b.text} for i,b in enumerate(blocks)]}


def patch(source: str, changes: list[dict]) -> str:
    blocks=text_blocks(source); ids=[v['index'] for v in changes]
    if len(ids)!=len(set(ids)) or any(type(i) is not int or i<0 or i>=len(blocks) for i in ids):
        raise ValueError('Invalid or duplicate text block')
    result=source
    for change in sorted(changes,key=lambda v:blocks[v['index']].start,reverse=True):
        block=blocks[change['index']]
        if change['text']!=block.text:
            result=result[:block.start]+escape(change['text'],quote=False)+result[block.end:]
    return result
