import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from test_api import app_at, post


def rotated_clients(tmp_path):
    app = app_at(tmp_path, nas_url='https://nas.example')
    current = TestClient(app)
    csrf = post(current, '/api/auth/login', dict(username='alice', password='correct', remember=True)).json()['csrf_token']
    old = current.cookies.get('synonote_session')
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:
        db.execute('UPDATE sessions SET rotated=0')
    assert current.get('/api/auth/me').status_code == 200
    stale = TestClient(app)
    stale.cookies.set('synonote_session', old, domain='testserver.local')
    return app, current, stale, old, csrf


def test_parallel_old_cookie_requests_share_short_grace_and_current_cookie(tmp_path):
    app, current, stale, old, csrf = rotated_clients(tmp_path)
    clients = [TestClient(app) for _ in range(8)]
    for client in clients: client.cookies.set('synonote_session', old, domain='testserver.local')
    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda client: client.get('/api/auth/me'), clients))
    assert [r.status_code for r in responses] == [200] * 8
    new = current.cookies.get('synonote_session')
    assert all(r.cookies.get('synonote_session') == new for r in responses)
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:
        expires = db.execute('SELECT expires FROM session_aliases').fetchone()[0]
    assert time.time() < expires <= time.time() + 30
    assert stale.get('/api/auth/me').status_code == 200
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:
        assert db.execute('SELECT expires FROM session_aliases').fetchone()[0] == expires


@pytest.mark.parametrize('logout_old', [False, True])
def test_logout_revokes_alias_and_current_session(logout_old, tmp_path):
    app, current, stale, old, csrf = rotated_clients(tmp_path)
    client = stale if logout_old else current
    assert post(client, '/api/auth/logout', {}, csrf=csrf).status_code == 200
    for token in (old, current.cookies.get('synonote_session')):
        replay = TestClient(app)
        if token: replay.cookies.set('synonote_session', token)
        assert replay.get('/api/auth/me').status_code == 401
    assert not app.state.live_nas
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:
        assert db.execute('SELECT COUNT(*) FROM session_aliases').fetchone()[0] == 0


@pytest.mark.parametrize('expiry', ['alias', 'absolute', 'idle'])
def test_alias_never_resurrects_expired_session_or_extends_grace(expiry, tmp_path):
    app, current, stale, old, csrf = rotated_clients(tmp_path)
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:
        if expiry == 'alias': db.execute('UPDATE session_aliases SET expires=0')
        elif expiry == 'absolute': db.execute('UPDATE sessions SET expires=0')
        else: db.execute('UPDATE sessions SET last_seen=0')
    assert stale.get('/api/auth/me').status_code == 401
    assert current.get('/api/auth/me').status_code == (200 if expiry == 'alias' else 401)


def test_grace_alias_survives_restart_but_not_failed_reauthentication(tmp_path):
    app, current, stale, old, csrf = rotated_clients(tmp_path)
    restarted_app = app_at(tmp_path, nas_url='https://nas.example')
    restarted = TestClient(restarted_app)
    restarted.cookies.set('synonote_session', old, domain='testserver.local')
    assert restarted.get('/api/auth/me').status_code == 200
    assert restarted.cookies.get('synonote_session') == current.cookies.get('synonote_session')
    # A new process must authenticate with NAS; failure revokes the alias family.
    failed_app = app_at(tmp_path, nas_url='https://nas.example')
    failed_app.state.nas.error = 'NAS_UNAVAILABLE'
    failed = TestClient(failed_app)
    failed.cookies.set('synonote_session', old)
    assert failed.get('/api/auth/me').status_code == 401
    failed_app.state.nas.error = None
    replay = TestClient(failed_app)
    replay.cookies.set('synonote_session', current.cookies.get('synonote_session'))
    assert replay.get('/api/auth/me').status_code == 401


def test_repeated_rotation_keeps_aliases_bounded_without_extending_first_deadline(tmp_path):
    from synonote_web.store import Store
    store=Store(tmp_path)
    now=time.time()
    store.save_session('token0','alice','https://nas.example',store.encrypt_credential('password',None,False),
                       'csrf',now+1000,now)
    assert store.rotate_session('token0','token1',now)
    assert store.rotate_session('token1','token2',now+1)
    assert store.resolve_session_alias('token0','https://nas.example',now+2,100)=='token2'
    assert store.resolve_session_alias('token0','https://nas.example',now+30,100) is None
    for i in range(2,12): assert store.rotate_session(f'token{i}',f'token{i+1}',now+i)
    with store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM session_aliases').fetchone()[0]<=8
    assert store.resolve_session_alias('token11','https://nas.example',now+12,100)=='token12'
    store.revoke('token11')
    assert store.session('token12','https://nas.example',now+12,100) is None
    assert store.resolve_session_alias('token10','https://nas.example',now+12,100) is None
