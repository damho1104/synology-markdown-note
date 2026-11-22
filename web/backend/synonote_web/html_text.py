"""Edit HTML text by source offsets; never reserialize the original document."""
from dataclasses import dataclass
from html import escape, unescape
from html.parser import HTMLParser
import secrets
import hashlib
from .html_structure import replace_ranges, table_markers


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
        self.events: list[tuple[int, int, bool]] = []
        self.stack: list[str] = []
    def mark(self, length):
        line, column = self.getpos()
        start = self.lines[line-1]+column
        opaque = any(v in self.stack for v in ('script','style','svg','math','textarea','title','head'))
        structural = bool(self.stack and self.stack[-1] in
                          {'table','thead','tbody','tfoot','tr','colgroup','ul','ol','dl','select','optgroup'})
        self.events.append((start, start+length, opaque or structural))
    def markup_length(self):
        line, column = self.getpos()
        start = self.lines[line-1]+column
        return self.source.find('>', start) + 1 - start
    def handle_starttag(self, tag, attrs):
        self.mark(len(self.get_starttag_text()))
        if tag not in {'br','hr','img','input','meta','link','source','wbr','area','base','embed','param','track','col'}: self.stack.append(tag)
    def handle_startendtag(self, tag, attrs): self.mark(len(self.get_starttag_text()))
    def handle_endtag(self, tag):
        self.mark(self.markup_length())
        if tag in self.stack:
            self.stack = self.stack[:len(self.stack)-1-self.stack[::-1].index(tag)]
    def handle_comment(self, data): self.mark(len(data) + 7)
    def handle_decl(self, decl): self.mark(self.markup_length())
    def handle_pi(self, data): self.mark(self.markup_length())
    def unknown_decl(self, data): self.mark(self.markup_length())


def text_blocks(source: str) -> list[TextBlock]:
    parser = _Spans(source)
    parser.feed(source); parser.close()
    # Reserve every gap in the immutable markup skeleton, including zero-length
    # and whitespace gaps. Deleting text can never renumber a following slot.
    blocks=[]; cursor=0
    for start, end, excluded in parser.events:
        if not excluded:
            blocks.append(TextBlock(cursor, start, unescape(source[cursor:start])))
        cursor=end
    if not any(v in parser.stack for v in ('script','style','svg','math','textarea','title','head')):
        blocks.append(TextBlock(cursor, len(source), unescape(source[cursor:])))
    return blocks


def layout_identity(source: str) -> str:
    return 'html-text-v2:' + hashlib.sha256(source.encode('utf-8')).hexdigest()


def annotate(source: str) -> dict:
    blocks=text_blocks(source); token=secrets.token_hex(16)
    patches = [(offset, offset, marker) for offset, marker in table_markers(source, token)]
    patches.extend((block.start, block.end,
                    f'<span data-edit-token="{token}" data-text-index="{index}">'+escape(block.text,quote=False)+'</span>')
                   for index, block in enumerate(blocks))
    preview = replace_ranges(source, patches)
    offsets=[0]
    for char in source: offsets.append(offsets[-1]+(2 if ord(char)>0xffff else 1))
    return {'html_text_preview':preview,'html_text_token':token,
            'html_text_layout':layout_identity(source),
            'html_text_blocks':[{'index':i,'text':b.text,'start':offsets[b.start],'end':offsets[b.end]} for i,b in enumerate(blocks)]}


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
