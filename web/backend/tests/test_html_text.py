import pytest
from synonote_web.html_text import annotate,patch,text_blocks


def test_patch_retains_every_original_attribute_attachment_and_opaque_payload():
    original='<div class="nas-custom" data-x="1"><p lang="ko">앞 &amp; <b>강조</b> 뒤</p><!-- keep --><img ref="original"><script>doNotEdit()</script><svg><text>opaque</text></svg></div>'
    blocks=text_blocks(original)
    assert [b.text for b in blocks]==['앞 & ','강조',' 뒤']
    assert patch(original,[{'index':1,'text':'바꾼 <텍스트>'}])==original.replace('강조','바꾼 &lt;텍스트&gt;')
    assert patch(original,[{'index':0,'text':'앞 & '}])==original
    info=annotate(original)
    assert info['html_text_preview'].count('data-edit-token=')==3
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
    kwargs=dict(note_id='n1',notebook_id='b1',title='Title',version='v1',changes=[{'index':0,'text':'new <text>'}])
    if lost:
        with pytest.raises(NasError) as exc:NasClient().write_html_text('https://nas.example',NasLogin('sid',None),**kwargs)
        assert exc.value.code=='WRITE_UNCERTAIN'
    else:
        result=NasClient().write_html_text('https://nas.example',NasLogin('sid',None),**kwargs)
        assert result['html']=='<p class="nas">new &lt;text&gt;</p><img ref="image1">'
        assert result['attachments'][0]['id']=='image1'
    assert len(writes)==1


def test_empty_paragraph_remains_editable_after_text_is_deleted():
    assert patch('<p></p>',[{'index':0,'text':'new'}])=='<p>new</p>'
    assert patch('<p>old</p>',[{'index':0,'text':''}])=='<p></p>'
    assert len(annotate('<p></p>')['html_text_blocks'])==1
