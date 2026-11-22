import pytest
from synonote_web.html_text import annotate,patch,text_blocks


def test_patch_retains_every_original_attribute_attachment_and_opaque_payload():
    original='<div class="nas-custom" data-x="1"><p lang="ko">앞 &amp; <b>강조</b> 뒤</p><!-- keep --><img ref="original"><script>doNotEdit()</script><svg><text>opaque</text></svg></div>'
    blocks=text_blocks(original)
    assert [b.text for b in blocks if b.text]==['앞 & ','강조',' 뒤']
    emphasis=next(i for i,b in enumerate(blocks) if b.text=='강조')
    prefix=next(i for i,b in enumerate(blocks) if b.text=='앞 & ')
    assert patch(original,[{'index':emphasis,'text':'바꾼 <텍스트>'}])==original.replace('강조','바꾼 &lt;텍스트&gt;')
    assert patch(original,[{'index':prefix,'text':'앞 & '}])==original
    info=annotate(original)
    assert info['html_text_preview'].count('data-edit-token=')==len(blocks)
    assert 'doNotEdit()' in info['html_text_preview']


@pytest.mark.parametrize('changes',[[{'index':99,'text':'x'}],[{'index':0,'text':'a'},{'index':0,'text':'b'}]])
def test_bad_block_ids_are_rejected(changes):
    with pytest.raises(ValueError):patch('<p>original</p>',changes)


@pytest.mark.parametrize('lost', [False, True])
def test_nas_text_update_preserves_opaque_html_and_does_not_retry(monkeypatch, lost):
    import json,httpx
    from urllib.parse import parse_qs
    from synonote_web.nas import NasClient,NasLogin,NasError,NOTE
    original='<p class="nas">original &amp; text</p><img ref="image1">'
    row={'object_id':'n1','parent_id':'b1','title':'Title','content':original,'ver':'v1','encrypt':False,'recycle':False,'attachment':{'image1':{'name':'photo.png'}}}
    writes=[]
    def handler(request):
        fields={k:v[0] for k,v in parse_qs(request.content.decode()).items()}
        if fields['api']=='SYNO.API.Info':data={NOTE:{'path':'entry.cgi','minVersion':1,'maxVersion':3}}
        elif fields['method']=='get':data=row.copy()
        else:
            assert json.loads(fields['ver'])=='v1' and fields['check_conflict']=='true'
            writes.append(1);row['content']=json.loads(fields['content']);row['ver']='v2'
            if lost:raise httpx.ReadError('lost after commit')
            data={'data':[{'object_id':'n1','ver':'v2'}]}
        return httpx.Response(200,json={'success':True,'data':data})
    monkeypatch.setattr(NasClient,'_client',lambda self:httpx.Client(transport=httpx.MockTransport(handler)))
    index=next(i for i,b in enumerate(text_blocks(original)) if b.text=='original & text')
    kwargs=dict(note_id='n1',notebook_id='b1',title='Title',version='v1',
                text_layout=annotate(original)['html_text_layout'],changes=[{'index':index,'text':'new <text>'}])
    if lost:
        with pytest.raises(NasError) as exc:NasClient().write_html_text('https://nas.example',NasLogin('sid',None),**kwargs)
        assert exc.value.code=='WRITE_UNCERTAIN'
    else:
        result=NasClient().write_html_text('https://nas.example',NasLogin('sid',None),**kwargs)
        assert result['html']=='<p class="nas">new &lt;text&gt;</p><img ref="image1">'
        assert result['attachments'][0]['id']=='image1'
    assert len(writes)==1


def test_empty_paragraph_remains_editable_after_text_is_deleted():
    index=next(i for i,b in enumerate(text_blocks('<p>old</p>')) if b.text=='old')
    assert patch('<p></p>',[{'index':index,'text':'new'}])=='<p>new</p>'
    assert patch('<p>old</p>',[{'index':index,'text':''}])=='<p></p>'
    assert len(annotate('<p></p>')['html_text_blocks'])==len(annotate('<p>old</p>')['html_text_blocks'])


def test_inline_deletion_keeps_structural_slots_for_inflight_edit():
    source = '<p><strong>A</strong> B <em>C</em></p>'
    initial = annotate(source)
    a = next(b['index'] for b in initial['html_text_blocks'] if b['text'] == 'A')
    b = next(b['index'] for b in initial['html_text_blocks'] if b['text'] == ' B ')
    first = patch(source, [{'index': a, 'text': ''}])
    acknowledged = annotate(first)
    assert len(acknowledged['html_text_blocks']) == len(initial['html_text_blocks'])
    assert acknowledged['html_text_blocks'][a]['text'] == ''
    assert acknowledged['html_text_blocks'][b]['text'] == ' B '
    assert patch(first, [{'index': a, 'text': ''}, {'index': b, 'text': ' D '}]) == '<p><strong></strong> D <em>C</em></p>'
    assert patch(first, [{'index': a, 'text': 'again'}]) == '<p><strong>again</strong> B <em>C</em></p>'


def test_whitespace_slots_and_utf16_source_offsets_survive_roundtrip():
    source = '<div data-x="💡"><span>😀 &amp; X</span> <b>Y</b></div>'
    info = annotate(source)
    raw = source.encode('utf-16-le')
    for block in info['html_text_blocks']:
        fragment = raw[block['start'] * 2:block['end'] * 2].decode('utf-16-le')
        from html import unescape
        assert unescape(fragment) == block['text']
    whitespace = next(b for b in info['html_text_blocks'] if b['text'] == ' ')
    changed = patch(source, [{'index': whitespace['index'], 'text': ''}])
    assert annotate(changed)['html_text_blocks'][whitespace['index']]['text'] == ''
    assert patch(changed, [{'index': whitespace['index'], 'text': '  '}]) == source.replace('</span> ', '</span>  ')


@pytest.mark.parametrize('layout', [None, 'html-text-v1:stale'])
def test_indexed_patch_rejects_missing_or_old_layout_before_mutation(monkeypatch, layout):
    from synonote_web.nas import NasClient, NasLogin, NasError
    source = '<p><strong>A</strong> B <em>C</em></p>'
    detail = dict(id='n1', notebook_id='b1', title='Title', version='v1', html=source,
                  locked=False, trashed=False, attachments=[], **annotate(source))
    monkeypatch.setattr(NasClient, 'fetch', lambda *args: detail)
    with pytest.raises(NasError) as error:
        NasClient().write_html_text('https://nas.example', NasLogin('sid', None),
            note_id='n1', notebook_id='b1', title='Title', version='v1',
            text_layout=layout, changes=[dict(index=0, text='changed')])
    assert error.value.code == 'HTML_PATCH_INVALID'


def test_empty_slots_do_not_create_invalid_table_or_list_children_in_preview():
    from html.parser import HTMLParser
    class Parents(HTMLParser):
        def __init__(self):
            super().__init__(); self.stack=[]
        def handle_starttag(self,tag,attrs):
            if tag=='span':
                assert not self.stack or self.stack[-1] not in {'table','tbody','tr','ul'}
            self.stack.append(tag)
        def handle_endtag(self,tag):
            assert self.stack.pop()==tag
    source='<table><tbody><tr><td><strong>A</strong></td></tr></tbody></table><ul><li>B</li></ul>'
    info=annotate(source)
    Parents().feed(info['html_text_preview'])
    a=next(b['index'] for b in info['html_text_blocks'] if b['text']=='A')
    b=next(b['index'] for b in info['html_text_blocks'] if b['text']=='B')
    cleared=patch(source,[{'index':a,'text':''}])
    assert annotate(cleared)['html_text_blocks'][b]['text']=='B'


def test_format_and_table_operations_patch_only_their_source_ranges():
    from synonote_web.html_structure import apply_structure
    source = '<div CLASS="nas"><p>😀 &amp; 문장</p><table data-x="keep"><tr><td>A</td><td>B</td></tr></table><!--opaque--></div>'
    block = next(i for i, b in enumerate(text_blocks(source)) if b.text == "😀 & 문장")
    formatted = apply_structure(source, {"kind":"bold", "index":block, "start":3, "end":4})
    assert formatted == source.replace("&amp;", "<strong>&amp;</strong>")
    with_column = apply_structure(source, {"kind":"column_after","index":0,"row":0,"column":0})
    assert with_column == source.replace("<td>A</td>", "<td>A</td><td></td>")
    assert apply_structure(source, {"kind":"row_after","index":0,"row":0,"column":0}) == source.replace(
        "</tr>", "</tr><tr><td></td><td></td></tr>")
    assert apply_structure(source, {"kind":"delete_table","index":0}) == (
        '<div CLASS="nas"><p>😀 &amp; 문장</p><!--opaque--></div>')
    merged = source.replace("<td>A", "<td colspan='2'>A")
    with pytest.raises(ValueError):
        apply_structure(merged, {"kind":"delete_column","index":0,"row":0,"column":0})
    with pytest.raises(ValueError):
        apply_structure(source, {"kind":"bold","index":block,"start":1,"end":2})


def test_preview_table_coordinates_take_precedence_over_original_attributes():
    from html.parser import HTMLParser

    class Markers(HTMLParser):
        table = None
        cell = None

        def handle_starttag(self, tag, attrs):
            if tag == "table":
                self.table = dict(reversed(attrs))
            if tag == "td":
                self.cell = dict(reversed(attrs))

    source = '<table data-table-index="42" data-structure-token="original"><tr><td data-table-row="7" data-table-column="9">A</td></tr></table>'
    preview = annotate(source)
    parser = Markers()
    parser.feed(preview["html_text_preview"])
    assert parser.table["data-structure-token"] == preview["html_text_token"]
    assert parser.table["data-table-index"] == "0"
    assert parser.cell["data-table-row"] == parser.cell["data-table-column"] == "0"


def test_deleting_a_column_removes_its_width_and_keeps_other_definitions():
    from synonote_web.html_structure import apply_structure

    source = ('<table><colgroup class="sizes"><col style="width:30px"><col style="width:90px"></colgroup>'
              '<tr><td>A</td><td>B</td></tr></table>')
    assert apply_structure(source, dict(kind="delete_column", index=0, row=0, column=0)) == source.replace(
        '<col style="width:30px">', '').replace('<td>A</td>', '')


def test_large_existing_html_note_still_accepts_title_only_edit(monkeypatch):
    from synonote_web.nas import NasClient, NasLogin

    html = "<p>" + "x" * 2_000_000 + "</p>"
    remote = dict(id="n1", notebook_id="b1", version="v1", title="old",
                  html=html, html_text_preview="preview", attachments=[], locked=False, trashed=False)
    monkeypatch.setattr(NasClient, "fetch", lambda *args: remote.copy())

    def mutate(self, base, login, **kwargs):
        remote.update(title=kwargs["title"], version="v2")
        return "n1", "v2"

    monkeypatch.setattr(NasClient, "_mutate_markdown", mutate)
    result = NasClient().write_html_text("https://nas.example", NasLogin("sid", None), note_id="n1",
        notebook_id="b1", title="new", version="v1", changes=[], text_layout=annotate(html)["html_text_layout"])
    assert result["title"] == "new" and result["html"] == html


def test_html_patch_endpoint_acks_stable_slots_and_checks_layout_migration(tmp_path):
    from fastapi.testclient import TestClient
    from synonote_web.nas import NasClient,NasLogin
    from test_api import app_at,post
    class Station(NasClient):
        source='<p><strong>A</strong> B <em>C</em></p>'
        version='v1'
        mutations=0
        def login(self,*args):return NasLogin('sid',None)
        def fetch(self,base,login,note_id):
            return dict(id=note_id,notebook_id='b1',title='Title',version=self.version,
                html=self.source,attachments=[],locked=False,trashed=False,editable=True,
                read_only_reason=None,**annotate(self.source))
        def _mutate_markdown(self,base,login,**kwargs):
            assert kwargs['version']==self.version
            self.mutations+=1
            self.source=kwargs['html'];self.version=f'v{self.mutations+1}'
            return 'n1',self.version
    nas=Station();client=TestClient(app_at(tmp_path,nas,nas_url='https://nas.example'))
    csrf=post(client,'/api/auth/login',dict(username='alice',password='correct')).json()['csrf_token']
    headers={'Origin':'http://testserver','X-CSRF-Token':csrf}
    first=client.get('/api/notes/n1').json()
    a=next(b['index'] for b in first['html_text_blocks'] if b['text']=='A')
    b=next(b['index'] for b in first['html_text_blocks'] if b['text']==' B ')
    body=dict(title='Title',notebook_id='b1',version='v1',text_changes=[dict(index=a,text='')])
    legacy=client.put('/api/notes/n1',json=body,headers=headers)
    assert legacy.status_code==422 and legacy.json()['error']=='HTML_PATCH_INVALID'
    assert nas.mutations==0
    response=client.put('/api/notes/n1',json={**body,'text_layout':first['html_text_layout']},headers=headers)
    assert response.status_code==200,response.text
    ack=response.json()
    assert ack['html_text_blocks'][a]['text']==''
    assert ack['html_text_blocks'][b]['text']==' B '
    next_body={**body,'version':ack['version'],'text_layout':ack['html_text_layout'],
               'text_changes':[dict(index=a,text=''),dict(index=b,text=' D ')]}
    stale=client.put('/api/notes/n1',json={**next_body,'text_layout':first['html_text_layout']},headers=headers)
    assert stale.status_code==422 and nas.mutations==1
    saved=client.put('/api/notes/n1',json=next_body,headers=headers)
    assert saved.status_code==200 and saved.json()['html']=='<p><strong></strong> D <em>C</em></p>'
    assert nas.mutations==2
    current = saved.json()
    with_table = client.put('/api/notes/n1', json={**next_body, 'version':current['version'],
        'text_layout':current['html_text_layout'], 'text_changes':[],
        'structure_edit':{'kind':'insert_table'}}, headers=headers)
    assert with_table.status_code == 200
    assert '<table>' in with_table.json()['html'] and 'data-table-index="0"' in with_table.json()['html_text_preview']
    assert nas.mutations == 3
def test_subscript_and_superscript_preserve_surrounding_source():
    from synonote_web.html_structure import apply_structure
    from synonote_web.main import StructureEdit

    source = "<p data-custom='keep'>a💡2z</p><!--keep-->"
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "a💡2z")
    for kind, tag in [("subscript", "sub"), ("superscript", "sup")]:
        edit = StructureEdit(kind=kind, index=index, start=3, end=4)
        assert apply_structure(source, edit.model_dump()) == (
            f"<p data-custom='keep'>a💡<{tag}>2</{tag}>z</p><!--keep-->"
        )


@pytest.mark.parametrize(("kind", "value", "replacement"), [
    ("font_family", "Georgia", '<span style="font-family:Georgia">A</span>'),
    ("font_size", "24", '<span style="font-size:24px">A</span>'),
    ("text_color", "#112233", '<span style="color:#112233">A</span>'),
    ("highlight_color", "#112233", '<span style="background-color:#112233">A</span>'),
    ("link", "https://example.com/?a=1&b=2", '<a href="https://example.com/?a=1&amp;b=2">A</a>'),
])
def test_inline_toolbar_values_patch_only_selected_text(kind, value, replacement):
    from synonote_web.html_structure import apply_structure
    from synonote_web.main import StructureEdit

    source = "<p data-test='unchanged'>AB</p><!--keep-->"
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "AB")
    edit = StructureEdit(kind=kind, value=value, index=index, start=0, end=1)
    assert apply_structure(source, edit.model_dump()) == source.replace("AB", replacement + "B")


@pytest.mark.parametrize(("kind", "value"), [
    ("font_family", "unknown"), ("font_size", "500"),
    ("text_color", "red"), ("link", "not a link"),
])
def test_inline_toolbar_values_reject_unsupported_input(kind, value):
    from synonote_web.html_structure import apply_structure

    source = "<p>AB</p>"
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "AB")
    with pytest.raises(ValueError, match="Invalid formatting value"):
        apply_structure(source, dict(kind=kind, value=value, index=index, start=0, end=1))


@pytest.mark.parametrize(("kind", "value", "expected"), [
    ("paragraph", "h2", "<h2>A</h2>"),
    ("align", "center", '<p style="text-align:center">A</p>'),
    ("list", "bullet", "<ul><li>A</li></ul>"),
    ("list", "number", "<ol><li>A</li></ol>"),
    ("list", "check", '<ul><li><label><input type="checkbox"> A</label></li></ul>'),
    ("indent", None, '<p style="margin-left:24px">A</p>'),
])
def test_paragraph_toolbar_keeps_other_paragraphs(kind, value, expected):
    from synonote_web.html_structure import apply_structure
    source = "<p>A</p><!--keep--><p data-extra='yes'>B</p>"
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "A")
    assert apply_structure(source, dict(kind=kind, value=value, index=index)) == expected + source[8:]


@pytest.mark.parametrize(("source", "expected"), [
    ("<div id='outer'>First<p>Second</p><p>Third</p></div>",
     "<div id='outer'><p>First</p><p>Second</p><p>Third</p></div>"),
    ("<div><strong>First</strong> &amp; next<p>Second</p></div>",
     "<div><p><strong>First</strong> &amp; next</p><p>Second</p></div>"),
])
def test_paragraph_style_keeps_nested_blocks_and_container_attributes(source, expected):
    from synonote_web.html_structure import apply_structure

    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "First")
    assert apply_structure(source, dict(kind="paragraph", value="p", index=index)) == expected


def test_alignment_preserves_quoted_css_values_comments_and_function_arguments():
    from synonote_web.html_structure import apply_structure

    source = '<p STYLE="font-family: &quot;A; text-align: B; C&quot; ;/* ; */ --paint: fn(a;b); text-align: right">A</p>'
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "A")
    assert apply_structure(source, dict(kind="align", value="center", index=index)) == source.replace(
        "text-align: right", "text-align:center"
    )


@pytest.mark.parametrize(("source", "value", "expected"), [
    ("<ol><li>A</li><li data-x='y'>B</li><li>C</li></ol>", "bullet",
     "<ol><li>A</li></ol><ul><li data-x='y'>B</li></ul><ol start=\"3\"><li>C</li></ol>"),
    ("<ol><li>A</li><li>B</li></ol>", "number", "<ol><li>A</li></ol><p>B</p>"),
    ("<ol start='5'><li><div>B</div></li><li>C</li></ol>", "number",
     '<div><div>B</div></div><ol start="6"><li>C</li></ol>'),
    ('<ul><li><label><input type="checkbox" checked> B</label></li></ul>', "check", "<p>B</p>"),
    ('<ul><li><label><input type="checkbox" checked=""> B</label></li></ul>', "check", "<p>B</p>"),
    ("<ul><li>B</li></ul>", "check", '<ul><li><label><input type="checkbox"> B</label></li></ul>'),
])
def test_existing_list_converts_or_toggles_the_selected_item(source, value, expected):
    from synonote_web.html_structure import apply_structure

    index = next(i for i, block in enumerate(text_blocks(source)) if block.text.strip() == "B")
    assert apply_structure(source, dict(kind="list", value=value, index=index)) == expected


@pytest.mark.parametrize(("kind", "source", "expected"), [
    ("unlink", '<p><a href="#x">A</a> B</p>', '<p>A B</p>'),
    ("clear_format", '<p><strong><em>A</em></strong> B</p>', '<p>A B</p>'),
    ("outdent", '<p style="margin-left:24px">A</p>', '<p>A</p>'),
])
def test_remove_toolbar_format(kind, source, expected):
    from synonote_web.html_structure import apply_structure
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "A")
    assert apply_structure(source, dict(kind=kind, index=index, start=0, end=1)) == expected


def test_insert_table_size_is_checked():
    from synonote_web.html_structure import apply_structure
    assert apply_structure("<p>A</p>", dict(kind="insert_table", rows=1, columns=3)) == (
        "<p>A</p><table><tbody><tr><td></td><td></td><td></td></tr></tbody></table>"
    )
    with pytest.raises(ValueError):
        apply_structure("", dict(kind="insert_table", rows=31, columns=3))


def test_checklist_toggles_only_the_selected_item():
    from synonote_web.html_structure import apply_structure
    source = '<ul><li><label><input type="checkbox"> One</label></li><li><label><input type="checkbox" checked> Two</label></li></ul>'
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == " One")
    edit = dict(kind="check_item", index=index)
    checked = apply_structure(source, edit)
    assert checked == source.replace('<input type="checkbox">', '<input type="checkbox" checked>', 1)
    assert apply_structure(checked, edit) == source


def test_checklist_toggles_checked_attribute_saved_by_dom():
    from synonote_web.html_structure import apply_structure

    source = '<ul><li><label><input type="checkbox" checked=""> One</label></li></ul>'
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == " One")
    assert apply_structure(source, dict(kind="check_item", index=index)) == source.replace(' checked=""', '')


@pytest.mark.parametrize("confirmed", [True, False])
def test_standalone_upload_preserves_note_and_stops_after_unconfirmed_write(monkeypatch, confirmed):
    from synonote_web.nas import NasClient, NasError, NasLogin, _attachment_filename
    source = "<p data-original='yes'>Document</p>"
    prior = {"id":"existing", "name":"existing.txt"}
    operation = "11111111-1111-4111-8111-111111111111"
    upload = "22222222-2222-4222-8222-222222222222"
    added = {"id":"added", "name":_attachment_filename(operation, upload, "new.txt", False)}
    baseline = dict(title="Title", html=source, notebook_id="b1", locked=False, trashed=False,
                    attachments=[prior], version="v1", **annotate(source))
    snapshots = iter([baseline, {**baseline, "version":"v2", "attachments":[prior, added]}])
    monkeypatch.setattr(NasClient, "fetch", lambda *_: next(snapshots))
    writes = []
    verify = []
    def mutate(self, base, login, **kwargs):
        writes.append(kwargs)
        return "n1", "v2"
    def verify_upload(self, base, login, note_id, file_id, upload):
        verify.append(file_id)
        if not confirmed:
            raise NasError("WRITE_UNCERTAIN")
    monkeypatch.setattr(NasClient, "_mutate_markdown", mutate)
    monkeypatch.setattr(NasClient, "_verify_upload", verify_upload)
    def write():
        return NasClient().write_html_text("https://nas.example", NasLogin("sid",None), note_id="n1",
            notebook_id="b1", title="Title", version="v1", changes=[], text_layout=baseline["html_text_layout"],
            operation_id=operation, uploads=[dict(name="new.txt", image=False, upload_id=upload)])
    if confirmed:
        assert write()["attachments"] == [prior, added]
    else:
        with pytest.raises(NasError) as failure:
            write()
        assert failure.value.code == "WRITE_UNCERTAIN"
    assert len(writes) == 1 and writes[0]["html"] == source and writes[0]["version"] == "v1"
    assert writes[0]["streamed_upload"]["filename"] == added["name"]
    assert verify == ["added"]


def test_formatting_keeps_original_entity_spelling_outside_selection():
    from synonote_web.html_structure import apply_structure
    source = "<p>&#65;B&#67;</p>"
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "ABC")
    assert apply_structure(source, dict(kind="bold", index=index, start=1, end=2)) == (
        "<p>&#65;<strong>B</strong>&#67;</p>"
    )


def test_clearing_format_preserves_bookmarks_and_rejects_nested_links():
    from synonote_web.html_structure import apply_structure
    source = '<p><a href="#one"><strong id="bookmark">ABC</strong></a></p>'
    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "ABC")
    assert apply_structure(source, dict(kind="clear_format", index=index, start=0, end=3)) == (
        '<p><a href="#one"><span id="bookmark">ABC</span></a></p>'
    )
    with pytest.raises(ValueError, match="existing link"):
        apply_structure(source, dict(kind="link", index=index, start=0, end=1, value="#two"))


@pytest.mark.parametrize("source", [
    '<p><a href="#one">AB</p>',
    '<p><a href="#one"/>AB</p>',
    '<p><a href="#one"><em>A</em></p><p>AB</p>',
])
def test_link_toolbar_rejects_selections_inside_unclosed_anchors(source):
    from synonote_web.html_structure import apply_structure

    index = next(i for i, block in enumerate(text_blocks(source)) if block.text == "AB")
    with pytest.raises(ValueError, match="existing link"):
        apply_structure(source, dict(kind="link", index=index, start=0, end=1, value="#two"))
