import httpx
import pytest
from synonote_web.nas import NasClient, NasLogin, NOTE
from synonote_web.compat.source_envelope import SourceEnvelope


def test_fetch_uses_verified_mac_source_and_preserves_markdown(monkeypatch):
    from urllib.parse import parse_qs
    markdown = '# hello\n\n```mermaid\nflowchart LR\n A-->B\n```\n'
    html = '<h1>hello</h1>\n<pre><code class="language-mermaid">flowchart LR\n A--&gt;B\n</code></pre>\n'
    source = SourceEnvelope.make(markdown, html).encode()
    def handler(request):
        form = {k:v[0] for k,v in parse_qs(request.content.decode()).items()}
        if form['api']=='SYNO.API.Info':
            data={NOTE:{'path':'entry.cgi','minVersion':1,'maxVersion':3}}
        elif form['method']=='download': return httpx.Response(200,content=source)
        else: data={'object_id':'n1','parent_id':'b1','title':'hello','ver':'v1','encrypt':False,'recycle':False,'content':html,'attachment':{'f1':{'name':'synology-note-source.md','ref':None}}}
        return httpx.Response(200,json={'success':True,'data':data})
    monkeypatch.setattr(NasClient,'_client',lambda self:httpx.Client(transport=httpx.MockTransport(handler)))
    detail=NasClient().fetch('https://nas.example',NasLogin('sid',None),'n1')
    assert detail['markdown']==markdown
    assert detail['editable'] is True
    assert detail['source_file_id']=='f1'


@pytest.mark.parametrize("lost_phase", [None, 1, 2, 3])
@pytest.mark.parametrize("existing", [False, True])
def test_markdown_stages_body_and_publishes_verified_source(monkeypatch, lost_phase, existing):
    import json
    from urllib.parse import parse_qs
    from email.parser import BytesParser
    from email.policy import default
    mutations=[];files={};row={};counter=0
    if existing:
        original='<h1>Old</h1>\n'
        source=SourceEnvelope.make('# Old\n',original).encode()
        files.update(f0=('synology-note-source-old.md',source), binary=('photo.png',b'original-photo'))
        row.update(object_id='new1',parent_id='book1',title='Old',content=original,ver='v0',encrypt=False,recycle=False,
                   attachment={'f0':{'name':'synology-note-source-old.md','ref':None},'binary':{'name':'photo.png','ref':None}})
    def handler(request):
        nonlocal counter
        form={k:v[0] for k,v in parse_qs(request.url.query.decode()).items()};parts={}
        if request.headers.get('content-type','').startswith('multipart/'):
            message=BytesParser(policy=default).parsebytes(b'Content-Type: '+request.headers['content-type'].encode()+b'\r\nMIME-Version: 1.0\r\n\r\n'+request.content)
            for part in message.iter_parts():
                name=part.get_param('name',header='content-disposition');content=part.get_payload(decode=True)
                if part.get_filename():parts[name]=(part.get_filename(),content)
                else:form[name]=content.decode()
        else:form.update({k:v[0] for k,v in parse_qs(request.content.decode()).items()})
        if form['api']=='SYNO.API.Info':data={NOTE:{'path':'entry.cgi','minVersion':1,'maxVersion':3}}
        elif form['method']=='get':data=row.copy()
        elif form['method']=='download':return httpx.Response(200,content=files[json.loads(form['file_id'])][1])
        else:
            method=form['method'];params={k:json.loads(v) for k,v in form.items() if k not in ('api','method','version','_sid')}
            if row:assert params['ver']==row['ver'] and params['check_conflict'] is True
            mutations.append(method);counter+=1
            if not row:row.update(object_id='new1',parent_id='book1',encrypt=False,recycle=False,attachment={})
            row.update({k:params[k] for k in ('title','content') if k in params});row['ver']=f'v{counter}'
            for entry in params.get('attachment',[]):
                if entry['action']=='delete':row['attachment'].pop(entry['file_id']);files.pop(entry['file_id'])
                else:
                    file_id=f'f{counter}';name,content=parts[entry['name']];files[file_id]=(name,content);row['attachment'][file_id]={'name':name,'ref':None}
            if counter==lost_phase:raise httpx.ReadError('receipt lost after commit')
            receipt={'object_id':'new1','ver':row['ver']};data=receipt if method=='create' else {'data':[receipt]}
        return httpx.Response(200,json={'success':True,'data':data})
    monkeypatch.setattr(NasClient,'_client',lambda self:httpx.Client(transport=httpx.MockTransport(handler)))
    markdown='# Web\n\n```mermaid\nflowchart LR\n A-->B\n```\n'
    if lost_phase:
        from synonote_web.nas import NasError
        with pytest.raises(NasError) as exc:
            NasClient().write_markdown('https://nas.example',NasLogin('sid',None),note_id='new1' if existing else None,notebook_id='book1',title='Web',markdown=markdown,version='v0' if existing else None)
        assert exc.value.code=='WRITE_UNCERTAIN'
        assert len(mutations)==lost_phase
        assert files  # recoverable original/staged/final source remains on the NAS
        return
    result=NasClient().write_markdown('https://nas.example',NasLogin('sid',None),note_id='new1' if existing else None,notebook_id='book1',title='Web',markdown=markdown,version='v0' if existing else None)
    assert mutations==(['set','set','set'] if existing else ['create','set','set'])
    assert result['html']=='<h1>Web</h1>\n<pre><code class="language-mermaid">flowchart LR\n A--&gt;B\n</code></pre>\n'
    assert result['markdown']==markdown and result['editable']
    assert len(files)==(2 if existing else 1)
    if existing: assert files['binary']==('photo.png',b'original-photo')
    final=SourceEnvelope.decode(next(value[1] for value in files.values() if value[0].endswith('.md')));assert not final.is_staging and final.matches(result['html'])


def test_web_uses_the_committed_mac_cli_contracts():
    import base64,json
    from pathlib import Path
    from synonote_web.compat.markdown import render
    fixtures=json.loads((Path(__file__).resolve().parents[3]/'contracts/source-envelope/fixtures.json').read_text())
    for value in fixtures['envelopes'].values():
        source=SourceEnvelope.decode(base64.b64decode(value['encoded_base64']))
        assert source.markdown==value['markdown']
        assert source.matches(value['html'])
        assert source.document_id==value['document_id']
    for value in fixtures['render']:
        assert render(value['markdown'])==value['html']
