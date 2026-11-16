import json
from urllib.parse import parse_qs

import httpx
import pytest

from synonote_web.nas import NasClient, NasError, NasLogin, NOTE


@pytest.mark.parametrize('path,format', [('entry.cgi', ''), ('note.cgi', 'JSON'), ('note.cgi', '')])
@pytest.mark.parametrize('create', [True, False])
def test_write_contract_readback_and_serialization(monkeypatch, path, format, create):
    mutations = []
    row = {'object_id': 'note1', 'title': 'old', 'content': '<p>old</p>', 'parent_id': 'book1', 'encrypt': False, 'recycle': False, 'ver': 'v1', 'attachment': None}
    def handler(request):
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        if form['api'] == 'SYNO.API.Info':
            data = {NOTE: {'path': path, 'requestFormat': format, 'minVersion': 1, 'maxVersion': 3}}
        elif form['method'] == 'get':
            data = row
        else:
            mutations.append(form)
            params = {k: json.loads(v) if path == 'entry.cgi' or format == 'JSON' else v for k, v in form.items() if k in ('title','content','parent_id','object_id')}
            assert params['title'] == '새 제목 & test'
            assert params['content'] == '<p>updated</p>'
            if not create:
                assert form['check_conflict'] == 'true'
            row.update(title=params['title'], content=params['content'], ver='v2')
            data = {'object_id': 'note1', 'ver': 'v2'} if create else {'data': [{'object_id': 'note1', 'ver': 'v2'}]}
        return httpx.Response(200, json={'success': True, 'data': data})
    monkeypatch.setattr(NasClient, '_client', lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    result = NasClient().write('https://nas.example', NasLogin('sid', None), note_id=None if create else 'note1', notebook_id='book1', title='새 제목 & test', html='<p>updated</p>', version=None if create else 'v1')
    assert result['version'] == 'v2' and result['editable']
    assert len(mutations) == 1


def test_pagination_and_raw_download_v1(monkeypatch):
    offsets = []
    def handler(request):
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        if form['api'] == 'SYNO.API.Info':
            data = {NOTE: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 3}}
        elif form['method'] == 'download':
            assert form['version'] == '1'
            assert json.loads(form['format']) == 'raw'
            assert json.loads(form['mode']) == 'download'
            return httpx.Response(200, content=b'original-file')
        else:
            offset = int(form['offset']); offsets.append(offset)
            data = {'offset': offset, 'total': 2, 'notes': [{'object_id': f'n{offset}', 'title': 'title', 'ver': '1', 'parent_id': 'book', 'encrypt': False, 'recycle': False}]}
        return httpx.Response(200, json={'success': True, 'data': data})
    monkeypatch.setattr(NasClient, '_client', lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    nas = NasClient(); login = NasLogin('sid', None)
    assert len(nas.notes('https://nas.example', login)) == 2
    assert offsets == [0, 1]
    assert nas.download('https://nas.example', login, 'n0', 'f1') == b'original-file'


def test_write_lost_response_is_uncertain_without_retry(monkeypatch):
    calls = []
    def handler(request):
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        if form['api'] == 'SYNO.API.Info':
            return httpx.Response(200, json={'success': True, 'data': {NOTE: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 3}}})
        calls.append(form['method'])
        raise httpx.ReadError('response lost')
    monkeypatch.setattr(NasClient, '_client', lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    with pytest.raises(NasError) as exc:
        NasClient().write('https://nas.example', NasLogin('sid', None), note_id=None, notebook_id='book', title='title', html='<p>body</p>', version=None)
    assert exc.value.code == 'WRITE_UNCERTAIN'
    assert calls == ['create']
