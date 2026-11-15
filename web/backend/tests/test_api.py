from __future__ import annotations

import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from fastapi.testclient import TestClient

from synonote_web.main import create_app
from synonote_web.nas import NasError, NasLogin
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


def test_persistent_token_rotates_and_old_token_cannot_be_reused(tmp_path):
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
    assert replay.get("/api/auth/me").status_code == 401
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


def test_network_error_during_auto_relogin_preserves_saved_credential(tmp_path):
    nas = FakeNas()
    first = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    assert post(first, "/api/auth/login", {
        "username": "alice", "password": "correct", "remember": True,
    }).status_code == 200
    nas.error = "NAS_UNAVAILABLE"
    restarted = TestClient(app_at(tmp_path, nas, nas_url="https://nas.example"))
    restarted.cookies.update(first.cookies)
    assert restarted.get("/api/auth/me").status_code == 503
    with sqlite3.connect(tmp_path / "web.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 1
    nas.error = None
    assert restarted.get("/api/auth/me").status_code == 200


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
    body = {'title': 'created', 'html': '<p>new</p>', 'notebook_id': 'book1'}
    assert post(client, '/api/notes', body).status_code == 403
    assert nas.write_calls == 0
    assert post(client, '/api/notes', body, csrf=csrf).status_code == 200
    assert client.get('/api/writes').json() == {'operations': []}


def test_uncertain_write_survives_restart_and_blocks_retransmission(tmp_path):
    nas = NotesNas(); nas.write_error = 'WRITE_UNCERTAIN'
    app = app_at(tmp_path, nas, nas_url='https://nas.example'); client = TestClient(app)
    csrf = post(client, '/api/auth/login', {'username': 'alice', 'password': 'correct', 'remember': True}).json()['csrf_token']
    body = {'title': 'created', 'html': '<p>new</p>', 'notebook_id': 'book1'}
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
