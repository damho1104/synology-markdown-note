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
