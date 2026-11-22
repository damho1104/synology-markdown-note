import httpx
import pytest
from synonote_web.nas import NasClient, NasLogin, NOTE
from synonote_web.compat.source_envelope import SourceEnvelope


@pytest.mark.parametrize("ambiguous", [False, True])
def test_fetch_uses_verified_mac_source_and_preserves_markdown(monkeypatch, ambiguous):
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
        if ambiguous and form['method']=='get':data['attachment']['f2']={'name':'another-source.md','ref':None}
        return httpx.Response(200,json={'success':True,'data':data})
    monkeypatch.setattr(NasClient,'_client',lambda self:httpx.Client(transport=httpx.MockTransport(handler)))
    detail=NasClient().fetch('https://nas.example',NasLogin('sid',None),'n1')
    if ambiguous:
        assert detail['editable'] is False
        assert detail['read_only_reason']=='AMBIGUOUS_SOURCE'
        assert 'html_text_preview' not in detail
        return
    assert detail['markdown']==markdown
    assert detail['editable'] is True
    assert detail['source_file_id']=='f1'


@pytest.mark.parametrize("with_math", [False, True])
@pytest.mark.parametrize("lost_phase", [None, 1, 2, 3])
@pytest.mark.parametrize("existing", [False, True, 'referenced'])
def test_markdown_stages_body_and_publishes_verified_source(monkeypatch, lost_phase, existing, with_math):
    import json
    from urllib.parse import parse_qs
    from email.parser import BytesParser
    from email.policy import default
    mutations=[];files={};row={};counter=0
    listable = []
    if existing:
        original='<h1>Old</h1>\n'
        uid='11111111-1111-4111-8111-111111111111'
        references=f'\n\n![photo](attachment://{uid})\n\n[file](attachment://{uid})\n' if existing=='referenced' else ''
        if references: original += '<p><img ref="photo-ref"></p><p><a ref="photo-ref" href="old-download">file</a></p>'
        source=SourceEnvelope.make('# Old\n'+references,original,attachment_bindings={uid:'binary'} if references else {}).encode()
        files.update(f0=('synology-note-source-old.md',source), binary=('photo.png',b'original-photo'))
        row.update(object_id='new1',parent_id='book1',title='Old',content=original,ver='v0',encrypt=False,recycle=False,
                   attachment={'f0':{'name':'synology-note-source-old.md','ref':None},'binary':{'name':'photo.png','ref':'photo-ref'}})
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
            listable.append(params["commit_msg"]["listable"])
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
    if existing=='referenced': markdown += references
    images = []
    if with_math:
        import base64
        from synonote_web.compat.markdown import math_plan
        markdown += "\n인라인 $x^2$\n\n$$y=2$$\n"
        _, formulas = math_plan(markdown)
        png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQzrvzH4QZYAwAUT4JsSqASqYAAAAASUVORK5CYII="
        images = [dict(key=f['key'], width=1, height=1, png=png) for f in formulas]
    if lost_phase:
        from synonote_web.nas import NasError
        with pytest.raises(NasError) as exc:
            NasClient().write_markdown('https://nas.example',NasLogin('sid',None),note_id='new1' if existing else None,notebook_id='book1',title='Web',markdown=markdown,version='v0' if existing else None, math_images=images)
        assert exc.value.code=='WRITE_UNCERTAIN'
        assert len(mutations)==lost_phase
        assert files  # recoverable original/staged/final source remains on the NAS
        return
    result=NasClient().write_markdown('https://nas.example',NasLogin('sid',None),note_id='new1' if existing else None,notebook_id='book1',title='Web',markdown=markdown,version='v0' if existing else None, math_images=images)
    assert len(mutations) == 3 + len(images)
    assert listable == [False] * (len(mutations) - 1) + [True]
    assert result['html'].startswith('<h1>Web</h1>\n<pre><code class="language-mermaid">flowchart LR\n A--&gt;B\n</code></pre>\n')
    if with_math: assert result['html'].count('<img ref=') == len(images)
    if existing=='referenced':
        from html.parser import HTMLParser
        from urllib.parse import urlsplit,parse_qs
        class Tags(HTMLParser):
            def handle_starttag(self,tag,attrs):
                if tag in ('img','a'): found.append((tag,dict(attrs)))
        found=[];Tags().feed(result['html'])
        photo=next(attrs for tag,attrs in found if tag=='img' and attrs.get('alt')=='photo')
        link=next(attrs for tag,attrs in found if tag=='a' and attrs.get('ref')=='photo-ref')
        assert photo['ref']=='photo-ref' and 'src' not in photo
        query=parse_qs(urlsplit(link['href']).query)
        assert urlsplit(link['href']).hostname=='nas.example'
        assert json.loads(query['file_id'][0])=='binary'
        assert json.loads(query['object_id'][0])=='new1'
        assert '_sid' not in query
    assert result['markdown']==markdown and result['editable']
    assert len(files)==(2 if existing else 1) + len(images)
    if existing: assert files['binary']==('photo.png',b'original-photo')
    final=SourceEnvelope.decode(next(value[1] for value in files.values() if value[0].endswith('.md')));assert not final.is_staging and final.matches(result['html'])
    if with_math:
        png_ids = {fid for fid, (name, _) in files.items() if name.endswith('.png') and fid != 'binary'}
        again = NasClient().write_markdown('https://nas.example', NasLogin('sid', None), note_id='new1', notebook_id='book1', title='Web', markdown=markdown, version=result['version'], math_images=images)
        assert png_ids.issubset(files) and len(files) == (2 if existing else 1) + len(images)
        clean = NasClient().write_markdown('https://nas.example', NasLogin('sid', None), note_id='new1', notebook_id='book1', title='Web', markdown='No math', version=again['version'])
        assert not clean['math_attachments'] and png_ids.isdisjoint(files)
        if existing: assert files['binary'] == ('photo.png', b'original-photo')


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


def test_math_delimiters_keep_code_html_and_destinations_literal():
    from synonote_web.compat.markdown import math_plan
    source = r"inline $x_1$ and \(\frac{a}{b}\)" + '\n\n$$x+y$$\n\n```tex\n$x$\n```\n\n    $code$\n\n' + '`$literal$` <code>$html$</code> [link](https://example.com/$path$)'
    masked, formulas = math_plan(source)
    assert [f['tex'] for f in formulas] == ['x_1', r'\frac{a}{b}', 'x+y']
    assert '$code$' in masked and '$path$' in masked and '$literal$' in masked


@pytest.mark.parametrize('bindings,files', [({}, [{'id':'binary','ref':'ref'}]),
    ({'11111111-1111-4111-8111-111111111111':'missing'}, [{'id':'binary','ref':'ref'}])])
def test_referenced_attachment_requires_authoritative_stored_binding_before_staging(monkeypatch,bindings,files):
    from synonote_web.nas import NasError
    uid='11111111-1111-4111-8111-111111111111'
    markdown=f'![image](attachment://{uid})'
    source=SourceEnvelope.make(markdown,'old',attachment_bindings=bindings)
    old=dict(id='n1',title='Title',notebook_id='b1',version='v1',html='old',editable=True,
        markdown=markdown,source_file_id='source',attachments=files)
    monkeypatch.setattr(NasClient,'fetch',lambda *args:old)
    monkeypatch.setattr(NasClient,'download',lambda *args:source.encode())
    with pytest.raises(NasError) as error:
        NasClient().write_markdown('https://nas.example',NasLogin('sid',None),
            note_id='n1',notebook_id='b1',title='Title',markdown=markdown,version='v1')
    assert error.value.code=='MARKDOWN_UNSUPPORTED'
