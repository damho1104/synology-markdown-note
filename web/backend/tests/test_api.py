from __future__ import annotations

import sqlite3
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from fastapi.testclient import TestClient

from synonote_web.main import create_app
from synonote_web.nas import NasClient, NasError, NasLogin
from synonote_web.settings import Settings
from synonote_web.store import token_hash


class FakeNas:
    def __init__(self):
        self.probed = []
        self.login_calls = []
        self.error = None

    def probe(self, url):
        self.probed.append(url)

    def login(self, url, username, password, otp, trust_device, device_id=None):
        self.login_calls.append((url, username, password, otp, trust_device, device_id))
        if self.error:
            raise NasError(self.error)
        if password != "correct":
            raise NasError("AUTH_FAILED")
        if username == "2fa" and otp is None and not device_id:
            raise NasError("OTP_REQUIRED")
        return NasLogin(sid="sid-secret", device_id="trusted-id" if trust_device else None)


def app_at(tmp_path, nas=None, **kwargs):
    return create_app(Settings(data_dir=tmp_path, secure_cookies=False, **kwargs), nas or FakeNas())


def post(client, path, body, *, origin="http://testserver", csrf=None):
    headers = {"Origin": origin}
    if csrf:
        headers["X-CSRF-Token"] = csrf
    return client.post(path, json=body, headers=headers)


def test_setup_code_is_private_and_single_use(tmp_path):
    nas = FakeNas()
    app = app_at(tmp_path, nas)
    client = TestClient(app)
    assert tmp_path.joinpath("setup-code").stat().st_mode & 0o077 == 0
    code = tmp_path.joinpath("setup-code").read_text().strip()
    assert code
    assert client.get("/api/status").json() == {
        "configured": False, "nas_url": None, "source": "setup", "read_only": False,
    }
    assert post(client, "/api/setup", {"code": "wrong", "nas_url": "https://nas.example"}).status_code == 403
    assert not nas.probed
    assert post(client, "/api/setup", {"code": code, "nas_url": "ftp://nas.example"}).status_code == 422
    assert not nas.probed
    response = post(client, "/api/setup", {"code": code, "nas_url": "https://nas.example"})
    assert response.status_code == 200
    assert nas.probed == ["https://nas.example"]
    assert not tmp_path.joinpath("setup-code").exists()
    assert post(client, "/api/setup", {"code": code, "nas_url": "https://evil.example"}).status_code == 409
    assert client.get("/api/status").json()["nas_url"] == "https://nas.example"
    # Restart uses the persisted SQLite address and never recreates setup code.
    restarted = TestClient(app_at(tmp_path, nas))
    assert restarted.get("/api/status").json()["source"] == "database"
    assert not tmp_path.joinpath("setup-code").exists()


def test_environment_url_wins_without_overwriting_saved_address(tmp_path):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas))
    code = tmp_path.joinpath("setup-code").read_text().strip()
    assert post(first, "/api/setup", {"code": code, "nas_url": "https://saved.example"}).status_code == 200
    env = TestClient(app_at(tmp_path, nas, nas_url="https://from-env.example"))
    assert env.get("/api/status").json() == {
        "configured": True, "nas_url": "https://from-env.example",
        "source": "environment", "read_only": True,
    }
    assert post(env, "/api/setup", {"code": code, "nas_url": "https://hijack.example"}).status_code == 409
    assert TestClient(app_at(tmp_path, nas)).get("/api/status").json()["nas_url"] == "https://saved.example"


def test_http_nas_setup_and_login(tmp_path):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas, allow_private_nas=True))
    code = tmp_path.joinpath("setup-code").read_text().strip()
    response = post(first, "/api/setup", {
        "code": code, "nas_url": "http://NAS.EXAMPLE:5000/nas/",
    })
    assert response.status_code == 200
    assert response.json()["nas_url"] == "http://nas.example:5000/nas"
    assert nas.probed == ["http://nas.example:5000/nas"]
    resumed = TestClient(app_at(tmp_path, nas, allow_private_nas=True))
    login = post(resumed, "/api/auth/login", {
        "username": "alice", "password": "correct",
    })
    assert login.status_code == 200
    assert nas.login_calls[0][0] == "http://nas.example:5000/nas"
    from_env = TestClient(app_at(tmp_path, nas, nas_url="http://nas.internal:5000", allow_private_nas=True))
    assert from_env.get("/api/status").json()["nas_url"] == "http://nas.internal:5000"


def test_malformed_nonempty_environment_url_is_not_ignored(tmp_path):
    client = TestClient(app_at(tmp_path, nas_url="ftp://nas.example"))
    assert client.get("/api/status").status_code == 503
    assert client.get("/api/ready").status_code == 503
    assert client.get("/api/health").status_code == 200


def test_mutations_require_origin_and_json(tmp_path):
    client = TestClient(app_at(tmp_path, nas_url="https://nas.example"))
    assert client.post("/api/auth/login", json={"username": "u", "password": "p"}).status_code == 403
    assert post(client, "/api/auth/login", {"username": "u", "password": "p"},
                origin="https://attacker.example").status_code == 403
    assert client.post("/api/auth/login", content=b"username=u", headers={
        "Origin": "http://testserver", "Content-Type": "application/x-www-form-urlencoded",
    }).status_code == 415
    assert client.post("/api/auth/login", content=b"not-json", headers={
        "Content-Type": "application/json",
    }).status_code == 403


def test_normal_login_session_logout_and_cookie_scope(tmp_path):
    nas = FakeNas()
    client = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    login = post(client, "/api/auth/login", {"username": "alice", "password": "correct"})
    assert login.status_code == 200
    assert "Max-Age" not in login.headers["set-cookie"]
    assert "HttpOnly" in login.headers["set-cookie"]
    assert "SameSite=strict" in login.headers["set-cookie"]
    assert login.json()["username"] == "alice"
    assert login.json()["remember"] is False
    assert client.get("/api/auth/me").json()["username"] == "alice"
    assert post(client, "/api/auth/logout", {}).status_code == 403
    csrf = login.json()["csrf_token"]
    assert post(client, "/api/auth/logout", {}, csrf=csrf).status_code == 200
    assert client.get("/api/auth/me").status_code == 401
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0
    # A transient session never survives server restart.
    assert post(client, "/api/auth/login", {"username": "alice", "password": "correct"}).status_code == 200
    restarted = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    restarted.cookies.update(client.cookies)
    assert restarted.get("/api/auth/me").status_code == 401


def test_persistent_login_encrypted_and_restored_after_restart(tmp_path):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    login = post(first, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True, "trust_device": True,
    })
    assert login.status_code == 200
    assert "Max-Age=" in login.headers["set-cookie"]
    assert "correct" not in (tmp_path / "web.sqlite3").read_bytes().decode("utf-8", errors="ignore")
    assert "sid-secret" not in (tmp_path / "web.sqlite3").read_bytes().decode("utf-8", errors="ignore")
    assert "master.key" in [p.name for p in tmp_path.iterdir()]
    assert (tmp_path / "master.key").stat().st_mode & 0o077 == 0
    next_client = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    next_client.cookies.update(first.cookies)
    response = next_client.get("/api/auth/me")
    assert response.status_code == 200
    assert response.json()["username"] == "alice"
    assert nas.login_calls[-1][-1] == "trusted-id"
    assert nas.login_calls[-1][-2] is True
    assert post(next_client, "/api/auth/logout", {}, csrf=response.json()["csrf_token"]).status_code == 200
    final_client = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    final_client.cookies.update(first.cookies)
    assert final_client.get("/api/auth/me").status_code == 401


def test_otp_step_and_failure_do_not_create_session(tmp_path):
    nas = FakeNas()
    client = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    first = post(client, "/api/auth/login", {"username": "2fa", "password": "correct", "remember": True})
    assert first.status_code == 401 and first.json() == {"error": "OTP_REQUIRED"}
    assert client.get("/api/auth/me").status_code == 401
    second = post(client, "/api/auth/login", {"username": "2fa", "password": "correct", "otp": "123456"})
    assert second.status_code == 200
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0


def test_automatic_relogin_otp_failure_revokes_only_current_token(tmp_path):
    nas = FakeNas()
    a = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    b = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    for client in (a, b):
        assert post(client, "/api/auth/login", {"username": "alice", "password": "correct", "remember": True}).status_code == 200
    nas.error = "OTP_REQUIRED"
    restarted = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    restarted.cookies.update(a.cookies)
    assert restarted.get("/api/auth/me").status_code == 401
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 1
    nas.error = None
    remaining = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    remaining.cookies.update(b.cookies)
    assert remaining.get("/api/auth/me").status_code == 200


def test_login_rate_limit_does_not_leak_credentials(tmp_path):
    nas = FakeNas()
    client = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    for _ in range(6):
        assert post(client, "/api/auth/login", {"username": "bob", "password": "wrong"}).status_code == 401
    assert post(client, "/api/auth/login", {"username": "bob", "password": "correct"}).status_code == 429
    assert len(nas.login_calls) == 6


def test_successful_login_cannot_reset_peer_failure_limit(tmp_path):
    nas = FakeNas()
    client = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    for _ in range(5):
        assert post(client, "/api/auth/login", {
            "username": "target", "password": "wrong",
        }).status_code == 401
    assert post(client, "/api/auth/login", {
        "username": "known", "password": "correct",
    }).status_code == 200
    assert post(client, "/api/auth/login", {
        "username": "target", "password": "wrong",
    }).status_code == 401
    assert post(client, "/api/auth/login", {
        "username": "target", "password": "wrong",
    }).status_code == 429
    assert len(nas.login_calls) == 7


def test_sqlite_runtime_errors_are_reported_as_store_errors(tmp_path):
    client = TestClient(app_at(tmp_path, nas_url="https://nas.example"))
    assert post(client, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    }).status_code == 200
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        db.execute("DROP TABLE sessions")
    response = client.get("/api/auth/me")
    assert response.status_code == 503
    assert response.json() == {"error": "LOCAL_STORE_ERROR"}


def test_saved_login_is_invalidated_by_effective_nas_change(tmp_path):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas, nas_url="https://original.example"))
    assert post(first, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    }).status_code == 200
    original_cookie = first.cookies.get("synonote_session")
    assert original_cookie

    # Startup with another NAS must discard old credentials before any request.
    other = TestClient(app_at(tmp_path, nas, nas_url="https://another.example"))
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0
    other.cookies.set("synonote_session", original_cookie)
    assert other.get("/api/auth/me").status_code == 401
    assert len(nas.login_calls) == 1

    back = TestClient(app_at(tmp_path, nas, nas_url="https://original.example"))
    back.cookies.set("synonote_session", original_cookie)
    assert back.get("/api/auth/me").status_code == 401


@pytest.mark.parametrize("deadline", ["idle", "absolute"])
def test_persistent_login_has_idle_and_absolute_expiration(tmp_path, deadline):
    settings = Settings(data_dir=tmp_path, nas_url="https://nas.example",
                        secure_cookies=False, remember_idle_seconds=5)
    client = TestClient(create_app(settings, FakeNas()))
    assert post(client, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    }).status_code == 200
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        if deadline == "idle":
            db.execute("UPDATE sessions SET last_seen=?", (time.time() - 6,))
        else:
            db.execute("UPDATE sessions SET expires=?", (time.time() - 1,))
    assert client.get("/api/auth/me").status_code == 401
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0


@pytest.mark.parametrize("deadline", ["idle", "absolute"])
def test_transient_login_respects_both_timeouts(tmp_path, deadline):
    settings = Settings(data_dir=tmp_path, nas_url="https://nas.example",
                        secure_cookies=False, idle_seconds=10, session_seconds=20)
    app = create_app(settings, FakeNas())
    client = TestClient(app)
    assert post(client, "/api/auth/login", {
        "username": "alice", "password": "correct",
    }).status_code == 200
    digest = token_hash(client.cookies.get("synonote_session"))
    session = app.state.transient[digest]
    if deadline == "idle":
        session.touched -= 11
    else:
        session.created -= 21
    assert client.get("/api/auth/me").status_code == 401
    assert digest not in app.state.transient


def test_persistent_token_rotates_and_old_token_expires_after_short_grace(tmp_path):
    app = app_at(tmp_path, nas_url="https://nas.example")
    client = TestClient(app)
    login = post(client, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    })
    old_token = client.cookies.get("synonote_session")
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        db.execute("UPDATE sessions SET rotated=0")
    response = client.get("/api/auth/me")
    assert response.status_code == 200
    assert client.cookies.get("synonote_session") != old_token
    replay = TestClient(app)
    replay.cookies.set("synonote_session", old_token)
    assert replay.get("/api/auth/me").status_code == 200
    with sqlite3.connect(tmp_path / 'web.sqlite3') as db:
        db.execute('UPDATE session_aliases SET expires=0')
    replay.cookies.clear()
    replay.cookies.set('synonote_session', old_token)
    assert replay.get('/api/auth/me').status_code == 401
    assert post(client, "/api/auth/logout", {}, csrf=login.json()["csrf_token"]).status_code == 200


def test_concurrent_session_reads_are_consistent(tmp_path):
    app = app_at(tmp_path, nas_url="https://nas.example")
    client = TestClient(app)
    assert post(client, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    }).status_code == 200
    with ThreadPoolExecutor(max_workers=8) as executor:
        responses = list(executor.map(lambda _: client.get("/api/auth/me").status_code, range(16)))
    assert responses == [200] * 16


def test_production_cookie_uses_secure_host_prefix(tmp_path):
    app = create_app(Settings(data_dir=tmp_path, nas_url="https://nas.example",
                              secure_cookies=True), FakeNas())
    client = TestClient(app, base_url="https://testserver")
    response = post(client, "/api/auth/login", {
        "username": "alice", "password": "correct",
    }, origin="https://testserver")
    assert response.status_code == 200
    cookie = response.headers["set-cookie"]
    assert cookie.startswith("__Host-synonote_session=")
    assert "Secure" in cookie and "HttpOnly" in cookie and "SameSite=strict" in cookie


def test_different_accounts_have_independent_saved_sessions(tmp_path):
    app = app_at(tmp_path, nas_url="https://nas.example")
    alice, bob = TestClient(app), TestClient(app)
    first = post(alice, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    })
    second = post(bob, "/api/auth/login", {
        "username": "bob", "password": "correct", "remember": True,
    })
    assert first.status_code == 200 and second.status_code == 200
    assert alice.get("/api/auth/me").json()["username"] == "alice"
    assert bob.get("/api/auth/me").json()["username"] == "bob"
    assert post(alice, "/api/auth/logout", {}, csrf=first.json()["csrf_token"]).status_code == 200
    assert alice.get("/api/auth/me").status_code == 401
    assert bob.get("/api/auth/me").json()["username"] == "bob"


def test_network_error_during_auto_relogin_requires_manual_login_after_recovery(tmp_path):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    assert post(first, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    }).status_code == 200
    nas.error = "NAS_UNAVAILABLE"
    restarted = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    restarted.cookies.update(first.cookies)
    assert restarted.get("/api/auth/me").status_code == 401
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0
    nas.error = None
    assert restarted.get("/api/auth/me").status_code == 401


def test_http_policy_applies_before_probe_and_to_saved_configuration(tmp_path):
    nas = FakeNas()
    client = TestClient(app_at(tmp_path, nas))
    code = (tmp_path / "setup-code").read_text().strip()
    assert post(client, "/api/setup", {"code": code, "nas_url": "http://nas.example"}).status_code == 403
    assert nas.probed == []
    enabled = TestClient(app_at(tmp_path, nas, allow_private_nas=True))
    assert post(enabled, "/api/setup", {"code": code, "nas_url": "http://nas.example"}).status_code == 200
    disabled = TestClient(app_at(tmp_path, nas))
    assert disabled.get("/api/status").status_code == 503
    assert post(disabled, "/api/auth/login", {"username": "alice", "password": "correct"}).status_code == 403
    assert not nas.login_calls

class NotesNas(FakeNas):
    def __init__(self):
        super().__init__()
        self.write_calls = 0
        self.write_error = None
    def notebooks(self, base, login):
        return [{'id': 'book1', 'name': '업무', 'stack': '프로젝트'}]
    def notes(self, base, login):
        return [self.fetch(base, login, 'note1')]
    def fetch(self, base, login, note_id):
        return {'id': note_id, 'title': 'title', 'notebook_id': 'book1', 'version': 'v1', 'html': '<p>body</p>', 'attachments': [{'id': 'file1', 'name': '문서.txt', 'ref': None}], 'locked': False, 'trashed': False, 'editable': False, 'read_only_reason': 'ATTACHMENTS'}
    def download(self, base, login, note_id, file_id):
        return b'file-content'
    def write(self, base, login, **kwargs):
        self.write_calls += 1
        if self.write_error:
            raise NasError(self.write_error)
        return {**self.fetch(base, login, 'created'), 'title': kwargs['title']}


def test_note_formats_are_cached_across_restarts_until_note_version_changes(tmp_path):
    from synonote_web.compat.source_envelope import SourceEnvelope

    original_html = '<p>body</p>'
    source = SourceEnvelope.make('', original_html).encode()

    class FormatNas(NotesNas, NasClient):
        version = 'v1'

        def __init__(self):
            NotesNas.__init__(self)
            NasClient.__init__(self)

        def notes(self, base, login):
            return [dict(id=note_id, version=self.version, locked=note_id == 'locked')
                    for note_id in ('md', 'html', 'locked')]

        def fetch(self, base, login, note_id):
            return NasClient.fetch(self, base, login, note_id)

        def _fetch(self, client, base, login, note_id):
            calls.append(note_id)
            html = '<p>edited in Note Station</p>' if note_id == 'md' and self.version == 'v2' else original_html
            return {**super().fetch(base, login, note_id), 'version': self.version,
                    'html': html, 'attachments': [{'id': 'file1', 'name': 'legacy-name.md', 'ref': None}]}

        def download(self, base, login, note_id, file_id):
            return b'# ordinary attachment' if note_id == 'html' and self.version == 'v1' else source

    calls = []
    nas = FormatNas()
    client = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    lookup = '/api/note-formats'
    params = {'notes': '[["md","v1"],["html","v1"]]'}
    assert client.get(lookup, params=params).status_code == 401
    assert post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct'}).status_code == 200
    assert all('is_markdown' not in note for note in client.get('/api/notes').json()['notes'])
    assert calls == []
    result = {'formats': [{'id': 'md', 'version': 'v1', 'is_markdown': True},
                          {'id': 'html', 'version': 'v1', 'is_markdown': False}]}
    assert client.get(lookup, params=params).json() == result
    assert calls == ['md', 'html']

    client = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    assert post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct'}).status_code == 200
    assert [row.get('is_markdown') for row in client.get('/api/notes').json()['notes']] == [True, False, None]
    assert client.get(lookup, params=params).json() == result
    assert calls == ['md', 'html']
    other = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    assert post(other, '/api/auth/login', {'username': 'bob', 'password': 'correct'}).status_code == 200
    assert all('is_markdown' not in note for note in other.get('/api/notes').json()['notes'])

    nas.version = 'v2'
    assert all('is_markdown' not in note for note in client.get('/api/notes').json()['notes'])
    updated = client.get(lookup, params={'notes': '[["md","v2"],["html","v2"]]'}).json()
    assert updated == {'formats': [{'id': 'md', 'version': 'v2', 'is_markdown': False},
                                   {'id': 'html', 'version': 'v2', 'is_markdown': True}]}
    assert calls == ['md', 'html', 'md', 'html']


def test_notes_require_session_and_writes_require_csrf(tmp_path):
    nas = NotesNas(); client = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    assert client.get('/api/notes').status_code == 401
    csrf = post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct'}).json()['csrf_token']
    assert client.get('/api/notebooks').json()['notebooks'][0]['name'] == '업무'
    assert client.get('/api/notes/note1').json()['html'] == '<p>body</p>'
    assert client.get('/api/notes/note1/attachments/missing').status_code == 404
    downloaded = client.get('/api/notes/note1/attachments/file1')
    assert downloaded.content == b'file-content'
    assert downloaded.headers['content-type'] == 'application/octet-stream'
    body = {'title': 'created', 'html': '<p>new</p>', 'notebook_id': 'book1', 'client_request_id': str(uuid.uuid4())}
    assert post(client, '/api/notes', body).status_code == 403
    assert nas.write_calls == 0
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 200
    assert client.get('/api/writes').json() == {'operations': []}


def test_uncertain_write_survives_restart_and_blocks_retransmission(tmp_path):
    nas = NotesNas(); nas.write_error = 'WRITE_UNCERTAIN'
    app = app_at(tmp_path, nas, nas_url='https://nas.example'); client = TestClient(app)
    csrf = post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct', 'remember': True}).json()['csrf_token']
    body = {'title': 'created', 'html': '<p>new</p>', 'notebook_id': 'book1', 'client_request_id': str(uuid.uuid4())}
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 409
    restarted = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example')); restarted.cookies.update(client.cookies)
    assert post(restarted, '/api/notes', body, csrf=csrf).json()['detail'] == 'WRITE_REVIEW_REQUIRED'
    assert nas.write_calls == 1
    operation = restarted.get('/api/writes').json()['operations'][0]
    assert operation['status'] == 'uncertain' and 'intent' not in operation
    bob = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    bob_csrf = post(bob, '/api/auth/login', {'username': 'bob', 'password': 'correct'}).json()['csrf_token']
    assert post(bob, f"/api/writes/{operation['operation_id']}/ack", {}, csrf=bob_csrf).status_code == 404
    assert post(restarted, f"/api/writes/{operation['operation_id']}/ack", {}, csrf=csrf).status_code == 200
    nas.write_error = None
    assert post(restarted, '/api/notes', body, csrf=csrf).status_code == 409
    body['client_request_id'] = str(uuid.uuid4())
    assert post(restarted, '/api/notes', body, csrf=csrf).status_code == 200


def test_version_conflict_releases_reservation_without_replaying(tmp_path):
    nas = NotesNas(); nas.write_error = 'REMOTE_CHANGED'
    client = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    csrf = post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct'}).json()['csrf_token']
    body = {'title': 'title', 'html': '<p>new</p>', 'notebook_id': 'book1', 'version': 'v1'}
    result = client.put('/api/notes/note1', json=body, headers={'Origin': 'http://testserver', 'X-CSRF-Token': csrf})
    assert result.status_code == 409
    assert nas.write_calls == 1
    assert client.get('/api/writes').json() == {'operations': []}


def test_attachment_download_preserves_rotated_login_cookie(tmp_path):
    nas = NotesNas(); client = TestClient(app_at(tmp_path, nas, nas_url='https://nas.example'))
    post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct', 'remember': True})
    with sqlite3.connect(tmp_path / 'web.sqlite3') as db:
        db.execute('UPDATE sessions SET rotated=0')
    result = client.get('/api/notes/note1/attachments/file1')
    assert result.content == b'file-content'
    assert 'set-cookie' in result.headers
    assert client.get('/api/auth/me').status_code == 200


def test_http_login_reports_secure_cookie_mismatch_before_nas_auth(tmp_path):
    nas = FakeNas()
    app = create_app(Settings(data_dir=tmp_path, nas_url='https://nas.example', secure_cookies=True), nas)
    client = TestClient(app)
    response = post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct'})
    assert response.status_code == 503
    assert response.json() == {'detail': 'SECURE_COOKIE_REQUIRES_HTTPS'}
    assert not nas.login_calls
    assert not app.state.transient


def test_https_proxy_origin_keeps_secure_cookie_even_on_internal_http(tmp_path):
    nas = FakeNas()
    app = create_app(Settings(data_dir=tmp_path, nas_url='https://nas.example', secure_cookies=True, public_origin='https://notes.example'), nas)
    client = TestClient(app, base_url='http://backend')
    response = post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct'}, origin='https://notes.example')
    assert response.status_code == 200
    assert response.headers['set-cookie'].startswith('__Host-synonote_session=')
    assert 'Secure' in response.headers['set-cookie'].split('; ')


@pytest.mark.parametrize('scheme', ['http', 'https'])
def test_auto_transport_needs_no_cookie_or_origin_settings(tmp_path, scheme):
    app = create_app(Settings(data_dir=tmp_path, nas_url='https://nas.example'), NotesNas())
    client = TestClient(app, base_url=f'{scheme}://notes.example.com')
    response = post(client, '/api/auth/login', {'username':'alice','password':'correct'}, origin=f'{scheme}://notes.example.com')
    assert response.status_code == 200
    secure = scheme == 'https'
    assert response.headers['set-cookie'].startswith('__Host-synonote_session=' if secure else 'synonote_session=')
    assert ('Secure' in response.headers['set-cookie'].split('; ')) is secure
    assert client.get('/api/notebooks').status_code == 200
    assert post(client, '/api/auth/logout', {}, csrf=response.json()['csrf_token'], origin=f'{scheme}://notes.example.com').status_code == 200
    assert client.get('/api/auth/me').status_code == 401


def test_auto_origin_accepts_https_proxy_same_host_without_forwarded_headers(tmp_path):
    client = TestClient(create_app(Settings(data_dir=tmp_path, nas_url='https://nas.example'), NotesNas()), base_url='http://notes.example')
    response = post(client, '/api/auth/login', {'username':'alice','password':'correct'}, origin='https://notes.example')
    assert response.status_code == 200
    assert 'Secure' in response.headers['set-cookie'].split('; ')
    assert post(client, '/api/auth/login', {'username':'alice','password':'correct'}, origin='https://evil.example').status_code == 403


@pytest.mark.parametrize('origin', ['https://[bad', 'https://attacker.example', 'null', 'https://testserver@attacker.example'])
def test_auto_origin_rejects_malformed_and_cross_site_origins(tmp_path, origin):
    nas=FakeNas()
    client=TestClient(create_app(Settings(data_dir=tmp_path,nas_url='https://nas.example'),nas))
    assert post(client,'/api/auth/login',{'username':'alice','password':'correct'},origin=origin).status_code==403
    assert not nas.login_calls


def test_library_repeated_session_checks_use_the_rotated_token(tmp_path):
    from types import SimpleNamespace
    class LibraryNas(NotesNas):
        def preflight_library_action(self,base,login,command):return SimpleNamespace(base=base)
        def apply_library_action(self,base,login,plan):self.write_calls+=1
    nas=LibraryNas();app=app_at(tmp_path,nas,nas_url='https://nas.example');client=TestClient(app)
    csrf=post(client,'/api/auth/login',{'username':'alice','password':'correct','remember':True}).json()['csrf_token']
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:db.execute('UPDATE sessions SET rotated=0')
    response=post(client,'/api/library/action',{'kind':'note','action':'tags','id':'note1','version':'v1','value':[]},csrf=csrf)
    assert response.status_code==200,response.text
    assert nas.write_calls==1
    assert client.get('/api/auth/me').status_code==200


def test_failed_nas_read_still_delivers_the_rotated_cookie(tmp_path):
    class UnavailableNas(NotesNas):
        def notes(self,*args):raise NasError('NAS_UNAVAILABLE')
    client=TestClient(app_at(tmp_path,UnavailableNas(),nas_url='https://nas.example'))
    post(client,'/api/auth/login',{'username':'alice','password':'correct','remember':True})
    with sqlite3.connect(tmp_path/'web.sqlite3') as db:db.execute('UPDATE sessions SET rotated=0')
    response=client.get('/api/notes')
    assert response.status_code==503
    assert 'set-cookie' in response.headers
    assert client.get('/api/auth/me').status_code==200


def test_nas_failure_returns_sanitized_diagnostic_for_failed_notebook_request(tmp_path, caplog):
    class RejectedNas(FakeNas):
        def notebooks(self, *_args):
            raise NasError("NAS_API_ERROR", diagnostic={"api": "SYNO.NoteStation.Notebook", "method": "list", "reason": "API_REJECTED", "nas_code": 105})
    client = TestClient(app_at(tmp_path, RejectedNas(), nas_url="https://nas.example"))
    assert post(client, "/api/auth/login", {"username": "alice", "password": "correct"}).status_code == 200
    response = client.get("/api/notebooks")
    assert response.status_code == 503
    assert response.json() == {"error": "NAS_API_ERROR", "diagnostic": {"api": "SYNO.NoteStation.Notebook", "method": "list", "reason": "API_REJECTED", "nas_code": 105}}
    assert "API_REJECTED" in caplog.text and "105" in caplog.text
    assert "sid-secret" not in caplog.text and "correct" not in caplog.text


@pytest.mark.parametrize("remember", [False, True])
def test_nas_expiration_clears_web_session_and_cookie_even_after_one_read_retry(tmp_path, remember):
    class ExpiredNas(FakeNas):
        expired = False
        def notebooks(self, *_args):
            if self.expired:
                raise NasError("NAS_SESSION_EXPIRED")
            return []
    nas = ExpiredNas()
    app = app_at(tmp_path, nas, nas_url="https://nas.example")
    client = TestClient(app)
    assert post(client, "/api/auth/login", {"username": "alice", "password": "correct", "remember": remember}).status_code == 200
    original = client.cookies.get("synonote_session")
    nas.expired = True
    response = client.get("/api/notebooks")
    assert response.status_code == 401
    assert response.json() == {"detail": "RELOGIN_REQUIRED"}
    assert 'Max-Age=0' in response.headers['set-cookie']
    assert client.cookies.get("synonote_session") is None
    assert not app.state.transient and not app.state.live_nas
    replay = TestClient(app)
    replay.cookies.set("synonote_session", original)
    assert replay.get("/api/auth/me").status_code == 401
    assert len(nas.login_calls) == (2 if remember else 1)


@pytest.mark.parametrize("code", ["AUTH_FAILED", "OTP_REQUIRED", "NAS_API_ERROR", "NAS_UNAVAILABLE"])
def test_failed_persistent_nas_login_revokes_web_session_for_any_login_failure(tmp_path, code, caplog):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    assert post(first, "/api/auth/login", {"username": "alice", "password": "correct", "remember": True}).status_code == 200
    old = first.cookies.get("synonote_session")
    nas.error = code
    restarted = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    restarted.cookies.update(first.cookies)
    response = restarted.get("/api/auth/me")
    assert response.status_code == 401
    assert response.json() == {"detail": "RELOGIN_REQUIRED"}
    assert restarted.cookies.get("synonote_session") is None
    assert 'Max-Age=0' in response.headers['set-cookie']
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0
    assert code in caplog.text and "session_invalidated" in caplog.text
    assert "correct" not in caplog.text and "sid-secret" not in caplog.text and old not in caplog.text


def test_request_logs_have_correlation_timing_and_no_query_or_credentials(tmp_path, caplog):
    import logging
    caplog.set_level(logging.INFO, logger="uvicorn.error")
    client = TestClient(app_at(tmp_path, nas_url="https://nas.example"))
    response = client.get("/api/health?password=never-log-this", headers={"X-Request-ID": "untrusted-value"})
    assert response.status_code == 200
    assert len(response.headers["X-Request-ID"]) == 16
    assert response.headers["X-Request-ID"] in caplog.text
    assert "request_completed" in caplog.text and '"status": 200' in caplog.text and '"duration_ms":' in caplog.text
    assert "never-log-this" not in caplog.text and "untrusted-value" not in caplog.text


def test_nas_logs_share_web_request_id_without_logging_form_data(tmp_path, monkeypatch, caplog):
    import json
    import logging
    import httpx
    from urllib.parse import parse_qs
    from synonote_web.nas import NasClient, NOTE, NOTEBOOK, AUTH
    caplog.set_level(logging.INFO, logger="uvicorn.error")
    def handler(request):
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        if form["api"] == "SYNO.API.Info":
            data = {AUTH: {"path": "auth.cgi", "minVersion": 3, "maxVersion": 6}, NOTE: {"path": "entry.cgi", "minVersion": 1, "maxVersion": 3}, NOTEBOOK: {"path": "entry.cgi", "minVersion": 2, "maxVersion": 2}}
        elif form["api"] == AUTH:
            data = {"sid": "private-nas-sid"}
        else:
            data = {"total": 0, "offset": 0, "notebooks": []}
        return httpx.Response(200, json={"success": True, "data": data})
    monkeypatch.setattr(NasClient, "_client", lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    client = TestClient(app_at(tmp_path, NasClient(), nas_url="https://nas.example"))
    assert post(client, "/api/auth/login", {"username": "alice", "password": "private-password"}).status_code == 200
    assert "private-nas-sid" not in caplog.text and "private-password" not in caplog.text
    caplog.clear()
    response = client.get("/api/notebooks")
    assert response.status_code == 200
    events = [json.loads(record.getMessage()) for record in caplog.records if record.name == "uvicorn.error"]
    assert len(events) == 2
    assert all(event["request_id"] == response.headers["X-Request-ID"] for event in events)
    assert any(event["event"] == "nas_request_completed" and event["api"] == NOTEBOOK and event["method"] == "list" for event in events)


@pytest.mark.parametrize("omitted_arrays", [("shortcuts",), ("tags",), ("shortcuts", "tags")])
def test_notes_api_accepts_empty_shortcut_and_tag_pages_without_arrays(tmp_path, monkeypatch, omitted_arrays):
    from urllib.parse import parse_qs
    import httpx
    from synonote_web.nas import AUTH, NOTE, NasClient

    shortcut, tag = "SYNO.NoteStation.Shortcut", "SYNO.NoteStation.Tag"
    info = {api: {"path": "entry.cgi", "minVersion": 1, "maxVersion": version}
            for api, version in [(AUTH, 6), (NOTE, 3), (shortcut, 1), (tag, 1)]}

    def handler(request):
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        api = form["api"]
        if api == "SYNO.API.Info":
            data = info
        elif api == AUTH:
            data = {"sid": "sid"}
        elif api == NOTE:
            # Missing inline tags must exercise Tag.list as well as Shortcut.list.
            data = {"offset": 0, "total": 1, "notes": [{
                "object_id": "note1", "parent_id": "book1", "title": "hello", "ver": "v1",
                "encrypt": False, "recycle": False,
            }]}
        else:
            assert api in (shortcut, tag)
            assert form["version"] == "1" and form["offset"] == "0" and form["limit"] == "500"
            key = "shortcuts" if api == shortcut else "tags"
            data = {"offset": 0, "total": 0}
            if key not in omitted_arrays:
                data[key] = []
        return httpx.Response(200, json={"success": True, "data": data})

    monkeypatch.setattr(NasClient, "_client", lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    client = TestClient(app_at(tmp_path, NasClient(), nas_url="https://nas.example"))
    assert post(client, "/api/auth/login", {"username": "alice", "password": "correct"}).status_code == 200
    response = client.get("/api/notes")
    assert response.status_code == 200
    assert response.json() == {"notes": [{
        "id": "note1", "title": "hello", "notebook_id": "book1", "version": "v1",
        "locked": False, "trashed": False, "created_at": None, "modified_at": None,
        "favorite": False, "tags": [], "excerpt": "",
    }]}


def test_stale_request_after_rotation_cannot_delete_the_new_cookie(tmp_path):
    app = app_at(tmp_path, nas_url="https://nas.example")
    client = TestClient(app)
    assert post(client, "/api/auth/login", {"username": "alice", "password": "correct", "remember": True}).status_code == 200
    old = client.cookies.get("synonote_session")
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        db.execute("UPDATE sessions SET rotated=0")
    assert client.get("/api/auth/me").status_code == 200
    assert client.cookies.get("synonote_session") != old
    stale = TestClient(app)
    stale.cookies.set("synonote_session", old)
    response = stale.get("/api/auth/me")
    assert response.status_code == 200
    assert response.cookies.get('synonote_session') == client.cookies.get('synonote_session')
    assert client.get("/api/auth/me").status_code == 200


def test_failed_manual_nas_login_also_revokes_existing_web_session(tmp_path):
    nas = FakeNas()
    app = app_at(tmp_path, nas, nas_url="https://nas.example")
    client = TestClient(app)
    assert post(client, "/api/auth/login", {"username": "alice", "password": "correct", "remember": True}).status_code == 200
    old = client.cookies.get("synonote_session")
    nas.error = "NAS_API_ERROR"
    response = post(client, "/api/auth/login", {"username": "alice", "password": "wrong"})
    assert response.status_code == 503
    assert 'Max-Age=0' in response.headers['set-cookie']
    assert client.cookies.get("synonote_session") is None
    replay = TestClient(app)
    replay.cookies.set("synonote_session", old)
    assert replay.get("/api/auth/me").status_code == 401


def test_app_html_is_not_cached_across_frontend_deployments(tmp_path, monkeypatch):
    static = tmp_path / "static"
    static.mkdir()
    (static / "index.html").write_text('<html><script src="/assets/current.js"></script></html>')
    monkeypatch.setenv("WEB_STATIC_DIR", str(static))
    client = TestClient(app_at(tmp_path / "data", nas_url="https://nas.example"))
    response = client.get("/")
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
