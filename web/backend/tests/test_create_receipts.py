"""Recover browser-lost create responses without repeating a NAS mutation."""
import threading
from concurrent.futures import ThreadPoolExecutor
import uuid

import pytest
from fastapi.testclient import TestClient
from test_api import NotesNas, app_at, post


@pytest.fixture
def create_client(tmp_path):
    nas = NotesNas()
    app = app_at(tmp_path, nas, nas_url='https://nas.example')
    client = TestClient(app)
    csrf = post(client, '/api/auth/login', dict(username='alice', password='correct', remember=True)).json()['csrf_token']
    body = dict(title='created', html='<p>new</p>', notebook_id='book1', client_request_id=str(uuid.uuid4()))
    return nas, app, client, csrf, body


def test_completed_receipt_survives_browser_response_loss_and_server_restart(create_client, tmp_path):
    nas, app, client, csrf, body = create_client
    key = body['client_request_id']
    assert client.get(f'/api/creates/{key}').json() == {'status': 'absent'}
    # Deliberately ignore the POST response, as if it was lost downstream.
    post(client, '/api/notes', body, csrf=csrf)
    restarted = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    restarted.cookies.update(client.cookies)
    receipt = restarted.get(f'/api/creates/{key}').json()
    assert receipt['status'] == 'completed'
    assert receipt['note']['id'] == 'created'
    assert post(restarted, '/api/notes', body, csrf=csrf).json() == receipt['note']
    assert nas.write_calls == 1
    assert restarted.get('/api/writes').json() == {'operations': []}
    assert b'<p>new</p>' not in (tmp_path/'web.sqlite3').read_bytes()


def test_completed_key_cannot_be_reused_for_another_payload_or_account(create_client):
    nas, app, client, csrf, body = create_client
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 200
    response = post(client, '/api/notes', {**body, 'title': 'different'}, csrf=csrf)
    assert response.status_code == 409 and response.json()['detail'] == 'CREATE_KEY_REUSED'
    bob = TestClient(app)
    post(bob, '/api/auth/login', dict(username='bob', password='correct'))
    assert bob.get('/api/creates/' + body['client_request_id']).json() == {'status': 'absent'}
    assert nas.write_calls == 1


def test_unknown_outcome_and_ack_keep_old_key_tombstoned(create_client):
    nas, app, client, csrf, body = create_client
    key = body['client_request_id']
    nas.write_error = 'WRITE_UNCERTAIN'
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 409
    receipt = client.get(f'/api/creates/{key}').json()
    assert receipt['status'] == 'uncertain'
    assert receipt['operation_id'] == client.get('/api/writes').json()['operations'][0]['operation_id']
    nas.write_error = None
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 409
    assert post(client, f"/api/writes/{receipt['operation_id']}/ack", {}, csrf=csrf).status_code == 200
    assert client.get(f'/api/creates/{key}').json()['status'] == 'reviewed'
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 409
    assert nas.write_calls == 1
    assert post(client, '/api/notes', {**body, 'client_request_id': str(uuid.uuid4())}, csrf=csrf).status_code == 200


def test_inflight_duplicate_key_is_blocked_before_second_nas_write(create_client):
    nas, app, client, csrf, body = create_client
    started, release = threading.Event(), threading.Event()
    original = nas.write
    def blocked(*args, **kwargs):
        started.set()
        assert release.wait(5)
        return original(*args, **kwargs)
    nas.write = blocked
    other = TestClient(app)
    other.cookies.update(client.cookies)
    with ThreadPoolExecutor(max_workers=1) as pool:
        first = pool.submit(post, client, '/api/notes', body, csrf=csrf)
        try:
            assert started.wait(5)
            assert other.get('/api/creates/' + body['client_request_id']).json()['status'] == 'pending'
            assert post(other, '/api/notes', body, csrf=csrf).status_code == 409
        finally:
            release.set()
        assert first.result().status_code == 200
    assert nas.write_calls == 1


def test_safely_rejected_preflight_can_use_same_key_without_uncertain_replay(create_client):
    nas, app, client, csrf, body = create_client
    nas.write_error = 'DOCUMENT_READ_ONLY'
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 403
    assert client.get('/api/creates/' + body['client_request_id']).json() == {'status': 'absent'}
    nas.write_error = None
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 200


def test_create_requires_durable_uuid_but_update_does_not(create_client):
    nas, app, client, csrf, body = create_client
    del body['client_request_id']
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 422
    assert nas.write_calls == 0
    assert client.put('/api/notes/note1', json={**body, 'version': 'v1'},
        headers={'Origin': 'http://testserver', 'X-CSRF-Token': csrf}).status_code == 200


def test_receipt_persistence_failure_leaves_pending_barrier_after_restart(create_client, tmp_path, monkeypatch):
    nas, app, client, csrf, body = create_client
    from synonote_web.store import StoreError
    def unavailable(*args, **kwargs): raise StoreError('storage failed after NAS commit')
    monkeypatch.setattr(app.state.store, 'finish_write', unavailable)
    lost = TestClient(app, raise_server_exceptions=False)
    lost.cookies.update(client.cookies)
    assert post(lost, '/api/notes', body, csrf=csrf).status_code == 503
    restarted = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    restarted.cookies.update(client.cookies)
    assert restarted.get('/api/creates/' + body['client_request_id']).json()['status'] == 'pending'
    assert post(restarted, '/api/notes', body, csrf=csrf).status_code == 409
    assert nas.write_calls == 1


def test_full_receipt_ledger_refuses_new_create_without_dropping_old_receipt(create_client):
    import hashlib
    nas,app,client,csrf,body=create_client
    assert post(client,'/api/notes',body,csrf=csrf).status_code==200
    owner=hashlib.sha256(('https://nas.example\x00alice').encode()).hexdigest()
    with app.state.store.connect() as db:
        db.executemany('INSERT INTO create_receipts VALUES(?,?,?,?,?,NULL)',
            [(owner,str(uuid.uuid4()),'hash',str(uuid.uuid4()),'reviewed') for _ in range(9999)])
    fresh={**body,'client_request_id':str(uuid.uuid4())}
    response=post(client,'/api/notes',fresh,csrf=csrf)
    assert response.status_code==503 and response.json()['error']=='LOCAL_STORE_ERROR'
    assert client.get('/api/creates/'+body['client_request_id']).json()['status']=='completed'
    assert nas.write_calls==1
