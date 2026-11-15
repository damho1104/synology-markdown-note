"""Library actions against mock HTTP, real FastAPI and durable Store."""
from copy import deepcopy
import json
import hashlib
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi.testclient import TestClient

from synonote_web.main import create_app
from synonote_web.nas import NasClient, NasLogin
from synonote_web.settings import Settings

BASE = "https://nas.example/proxy"
OWNER = hashlib.sha256((BASE + "\x00alice").encode()).hexdigest()
NOTE = "SYNO.NoteStation.Note"
BOOK = "SYNO.NoteStation.Notebook"
SHORTCUT = "SYNO.NoteStation.Shortcut"
STACK = "SYNO.NoteStation.Stack"
INFO = "SYNO.NoteStation.Info"


class MockStation:
    def __init__(self):
        self.path, self.request_format = "entry.cgi", ""
        self.note = {"object_id": "note1", "title": "기존 제목", "content": "<p>본문</p>",
                     "parent_id": "book1", "encrypt": False, "recycle": False,
                     "ver": "v1", "tag": ["old"], "ctime": 42, "brief": "본문",
                     "attachment": {"file1": {"name": "source.md", "ref": "ref1", "size": 12}}}
        self.books = [{"object_id": "book1", "title": "기존 메모장", "stack": "책장 & A"},
                      {"object_id": "book2", "title": "다른 메모장", "stack": ""}]
        self.shortcuts, self.mutations, self.calls = [], [], []
        self.download_bytes = b"opaque attachment"
        self.receipt_override = None
        self.fail, self.corrupt = None, None
        self.read_fail, self.info_fail, self.omit_tag = False, False, False

    def handler(self, request):
        assert request.url.host == "nas.example"
        assert request.url.path.startswith("/proxy/webapi/")
        form = {k: v[0] for k, v in parse_qs(request.content.decode(), keep_blank_values=True).items()}
        api, method = form["api"], form["method"]
        self.calls.append((api, method))
        if api == "SYNO.API.Info":
            if self.info_fail:
                return httpx.Response(200, json={"success": False, "error": {"code": 119}})
            data = {name: {"path": self.path, "requestFormat": self.request_format,
                           "minVersion": 1, "maxVersion": cap}
                    for name, cap in [(NOTE, 3), (BOOK, 2), (SHORTCUT, 1), (STACK, 1), (INFO, 2)]}
            return self.ok(data)
        params = {k: json.loads(v) if self.path == "entry.cgi" or self.request_format == "JSON" else
                  json.loads(v) if v in ("true", "false") or v.startswith(("[", "{")) else v
                  for k, v in form.items() if k not in {"api", "method", "version", "_sid"}}
        if method == "download":
            return httpx.Response(200, content=self.download_bytes)
        if method in {"get", "list"}:
            if self.read_fail and self.mutations:
                raise httpx.ReadError("lost readback")
            if api == NOTE and method == "get":
                data = deepcopy(self.note)
                if self.omit_tag:
                    data.pop("tag", None)
            elif api == INFO:
                data = {"uid": 123}
            else:
                key, rows = {NOTE: ("notes", [self.note]), BOOK: ("notebooks", self.books),
                             SHORTCUT: ("shortcuts", self.shortcuts)}[api]
                data = {"total": len(rows), "offset": 0, key: deepcopy(rows)}
            return self.ok(data)
        self.mutations.append((api, method, params, form))
        if self.fail in {"reject", "expired"}:
            return httpx.Response(200, json={"success": False, "error": {"code": 1064 if self.fail == "reject" else 119}})
        if api == NOTE:
            self.note.update({k: deepcopy(v) for k, v in params.items() if k in {"tag", "parent_id", "recycle"}})
            self.note["ver"] = "v2"
            data = {"data": [{"object_id": "note1", "ver": "v2"}]}
        elif api == SHORTCUT:
            self.shortcuts = [{"id": "note1", "category": "note"}] if method == "set" else []
            data = None
        elif api == BOOK:
            if method == "create":
                self.books.append({"object_id": "newbook", "title": params["title"], "stack": ""})
                data = {"object_id": "newbook"}
            else:
                ids = params["object_id"]
                ids = ids if isinstance(ids, list) else [ids]
                for book in self.books:
                    if book["object_id"] in ids:
                        book.update({k: v for k, v in params.items() if k in {"title", "stack"}})
                data = None
        elif api == STACK:
            assert params["stack_id"] == "책장 & A#123"
            for book in self.books:
                if book["stack"] == "책장 & A":
                    book["stack"] = params["name"]
            data = None
        else:
            raise AssertionError((api, method))
        if self.corrupt:
            self.corrupt(self)
        if self.fail == "lost":
            raise httpx.ReadError("sid-private password-private response lost")
        if self.fail == "malformed":
            return httpx.Response(200, json={"success": True, "data": {"data": []}})
        if self.receipt_override is not None:
            data = self.receipt_override
        return self.ok(data)

    @staticmethod
    def ok(data):
        return httpx.Response(200, json={"success": True, "data": data})


@pytest.fixture
def harness(tmp_path, monkeypatch):
    # Exercise the parent's one real route registration and session guards.
    monkeypatch.setenv("WEB_STATIC_DIR", str(tmp_path / "no-static"))
    station = MockStation()
    class LibraryClient(NasClient):
        def _client(self):
            return httpx.Client(transport=httpx.MockTransport(station.handler), follow_redirects=False)

        def login(self, *args, **kwargs):
            # Authentication is not the behavior under test; session creation,
            # ownership, expiry handling and CSRF still use the real app code.
            return NasLogin("sid-private", None)

    nas = LibraryClient()
    app = create_app(Settings(data_dir=tmp_path, nas_url=BASE, secure_cookies=False), nas)
    store = app.state.store
    client = TestClient(app)
    login = client.post("/api/auth/login", json={"username": "alice", "password": "password-private"},
                        headers={"Origin": "http://testserver"})
    assert login.status_code == 200
    csrf = login.json()["csrf_token"]
    def post(body, **headers):
        if headers.pop("x-session", "yes") == "no":
            headers["Cookie"] = ""
        return client.post("/api/library/action", json=body,
                           headers={"Origin": "http://testserver", "X-CSRF-Token": csrf, **headers})
    return station, store, post, client


@pytest.mark.parametrize("action,value,field,want", [
    ("tags", ["한글", "x & y"], "tag", ["한글", "x & y"]),
    ("trash", None, "recycle", True), ("restore", None, "recycle", False),
    ("move", "book2", "parent_id", "book2"),
])
@pytest.mark.parametrize("path,format", [("entry.cgi", ""), ("note.cgi", "JSON"), ("note.cgi", "")])
def test_note_metadata_uses_conflict_guard_and_preserves_body(harness, action, value, field, want, path, format):
    station, store, post, _ = harness
    station.path, station.request_format = path, format
    station.note["recycle"] = action == "restore"
    original = deepcopy(station.note)
    body = {"kind": "note", "id": "note1", "action": action, "version": "v1"}
    if value is not None:
        body["value"] = value
    response = post(body)
    assert response.status_code == 200, response.text
    assert response.json() == {"ok": True}
    assert len(station.mutations) == 1
    api, method, params, form = station.mutations[0]
    assert (api, method) == (NOTE, "set")
    assert params["ver"] == "v1" and params["check_conflict"] is True
    assert params[field] == want
    assert "content" not in params and "attachment" not in params and "title" not in params
    assert station.note["content"] == original["content"]
    assert station.note["attachment"] == original["attachment"]
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("favorite", [True, False])
def test_favorite_uses_native_shortcut_contract(harness, favorite):
    station, store, post, _ = harness
    station.shortcuts = [] if favorite else [{"id": "note1", "category": "note"}]
    response = post({"kind": "note", "id": "note1", "action": "favorite", "version": "v1", "value": favorite})
    assert response.status_code == 200, response.text
    assert response.json() == {"ok": True}
    assert len(station.mutations) == 1
    assert station.mutations[0][:3] == (SHORTCUT, "set" if favorite else "delete", {"object_id": "note1"})
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("body,api,method,expected", [
    ({"kind": "notebook", "action": "create", "name": "새 메모장"}, BOOK, "create", {"title": "새 메모장"}),
    ({"kind": "notebook", "id": "book1", "action": "rename", "name": "새 이름"}, BOOK, "set", {"object_id": "book1", "title": "새 이름"}),
    ({"kind": "notebook", "id": "book2", "action": "move", "value": "책장 & A"}, BOOK, "set", {"object_id": ["book2"], "stack": "책장 & A"}),
    ({"kind": "notebook", "id": "book1", "action": "move", "value": ""}, BOOK, "set", {"object_id": ["book1"], "stack": ""}),
    ({"kind": "stack", "action": "create", "name": "새 책장", "value": ["book1", "book2"]}, BOOK, "set", {"object_id": ["book1", "book2"], "stack": "새 책장"}),
    ({"kind": "stack", "id": "책장 & A", "action": "rename", "name": "이름 & 변경"}, STACK, "set", {"stack_id": "책장 & A#123", "name": "이름 & 변경"}),
])
def test_library_contracts_and_verified_success(harness, body, api, method, expected):
    station, store, post, _ = harness
    response = post(body)
    assert response.status_code == 200, response.text
    assert response.json() == {"ok": True}
    assert len(station.mutations) == 1
    got_api, got_method, params, _ = station.mutations[0]
    assert (got_api, got_method) == (api, method)
    for key, value in expected.items():
        assert params[key] == value
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("failure", ["lost", "reject", "expired", "malformed", "readback"])
def test_every_post_mutation_error_retains_lock_and_prevents_resend(harness, failure):
    station, store, post, _ = harness
    station.fail = failure
    station.read_fail = failure == "readback"
    body = {"kind": "note", "id": "note1", "action": "tags", "version": "v1", "value": ["new"]}
    response = post(body)
    assert response.status_code == 409, response.text
    assert response.json() == {"error": "WRITE_UNCERTAIN"}
    assert "sid-private" not in response.text and "password-private" not in response.text
    pending = store.pending_writes(OWNER)
    assert len(pending) == 1 and pending[0]["status"] == "uncertain"
    assert pending[0]["target"] == "note1"
    assert post(body).status_code == 409
    assert len(station.mutations) == 1


@pytest.mark.parametrize("field,value", [("content", "changed"), ("attachment", {}), ("title", "changed"), ("parent_id", "other")])
def test_readback_detects_unrequested_changes(harness, field, value):
    station, store, post, _ = harness
    station.corrupt = lambda s: s.note.update({field: value})
    response = post({"kind": "note", "id": "note1", "action": "tags", "version": "v1", "value": ["new"]})
    assert response.status_code == 409 and response.json() == {"error": "WRITE_UNCERTAIN"}
    assert store.pending_writes(OWNER)[0]["status"] == "uncertain"


@pytest.mark.parametrize("body", [
    {"kind": "note", "id": "note1", "action": "move", "value": "book2"},
    {"kind": "note", "id": "note1", "action": "favorite", "version": "v1", "value": "true"},
    {"kind": "note", "id": "note1", "action": "tags", "version": "v1", "value": [1]},
    {"kind": "note", "id": "../bad", "action": "trash", "version": "v1"},
    {"kind": "notebook", "id": "book1", "action": "delete"},
    {"kind": "stack", "id": "old", "action": "delete"},
    {"kind": "note", "id": "note1", "action": "delete", "version": "v1"},
    {"kind": "stack", "action": "create", "name": "empty", "value": []},
    {"kind": "notebook", "action": "create", "name": " "},
    {"kind": "note", "id": "note1", "action": "rename", "name": "unsupported", "version": "v1"},
])
def test_invalid_actions_do_not_read_or_write_nas(harness, body):
    station, store, post, _ = harness
    assert post(body).status_code == 422
    assert station.calls == []
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("body", [
    {"kind": "note", "id": "note1", "action": "trash", "version": "old"},
    {"kind": "note", "id": "note1", "action": "move", "version": "v1", "value": "missing"},
    {"kind": "notebook", "action": "create", "name": "기존 메모장"},
    {"kind": "stack", "action": "create", "name": "책장 & A", "value": ["book2"]},
    {"kind": "stack", "id": "missing", "action": "rename", "name": "new"},
])
def test_safe_preflight_rejection_releases_reservation(harness, body):
    station, store, post, _ = harness
    assert post(body).status_code in {404, 409, 422}
    assert station.mutations == []
    assert store.pending_writes(OWNER) == []


def test_csrf_origin_and_session_rejected_before_reservation(harness):
    station, store, post, client = harness
    body = {"kind": "note", "id": "note1", "action": "trash", "version": "v1"}
    assert post(body, **{"X-CSRF-Token": "bad"}).status_code == 403
    assert post(body, **{"x-session": "no"}).status_code == 401
    assert post(body, Origin="https://attacker.example").status_code == 403
    assert client.post("/api/library/action", json=body).status_code == 403
    assert station.calls == []
    assert store.pending_writes(OWNER) == []


def test_existing_editor_lock_blocks_metadata_write(harness):
    station, store, post, _ = harness
    assert store.start_write("editor", OWNER, "note1", "note1", "draft", {})
    assert post({"kind": "note", "id": "note1", "action": "trash", "version": "v1"}).status_code == 409
    assert station.calls == []


def test_create_notebook_in_stack_uses_verified_create_then_assignment(harness):
    station, store, post, _ = harness
    response = post({"kind": "notebook", "action": "create", "name": "새 메모장", "value": "책장 & A"})
    assert response.status_code == 200, response.text
    assert response.json() == {"ok": True}
    assert len(station.mutations) == 2
    assert station.mutations[0][0:2] == (BOOK, "create")
    assert "stack" not in station.mutations[0][2]
    assert station.mutations[1][0:2] == (BOOK, "set")
    assert station.mutations[1][2]["object_id"] == ["newbook"]
    assert station.books[-1] == {"object_id": "newbook", "title": "새 메모장", "stack": "책장 & A"}
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("action,value", [("move", "book2"), ("tags", ["new"]), ("favorite", True), ("trash", None), ("restore", None)])
def test_staging_envelope_blocks_all_metadata_before_mutation(harness, action, value):
    from synonote_web.compat.source_envelope import SourceEnvelope
    station, store, post, _ = harness
    station.note["recycle"] = action == "restore"
    station.download_bytes = SourceEnvelope.make("# staged", station.note["content"],
        operation_id="12345678-1234-1234-1234-123456789012", is_staging=True).encode()
    body = {"kind": "note", "id": "note1", "action": action, "version": "v1"}
    if value is not None:
        body["value"] = value
    response = post(body)
    assert response.status_code == 403, response.text
    assert response.json() == {"error": "DOCUMENT_READ_ONLY"}
    assert station.mutations == []
    assert store.pending_writes(OWNER) == []


CATALOG_ACTIONS = [
    {"kind": "notebook", "action": "create", "name": "새 메모장"},
    {"kind": "notebook", "action": "create", "name": "새 메모장", "value": "책장 & A"},
    {"kind": "notebook", "id": "book1", "action": "rename", "name": "새 이름"},
    {"kind": "notebook", "id": "book2", "action": "move", "value": "책장 & A"},
    {"kind": "stack", "action": "create", "name": "새 책장", "value": ["book2"]},
    {"kind": "stack", "id": "책장 & A", "action": "rename", "name": "이름 & 변경"},
]


@pytest.mark.parametrize("body", CATALOG_ACTIONS)
@pytest.mark.parametrize("failure", ["lost", "reject", "expired", "readback"])
def test_catalog_uncertainty_blocks_overlapping_catalog_operations(harness, body, failure):
    station, store, post, _ = harness
    station.fail = failure
    station.read_fail = failure == "readback"
    response = post(body)
    assert response.status_code == 409, response.text
    assert response.json() == {"error": "WRITE_UNCERTAIN"}
    pending = store.pending_writes(OWNER)
    assert len(pending) == 1 and pending[0]["status"] == "uncertain"
    assert post({"kind": "notebook", "id": "book2", "action": "rename", "name": "blocked"}).status_code == 409
    assert len(station.mutations) == 1


@pytest.mark.parametrize("receipt", [
    {"data": [{"object_id": "other", "ver": "v2"}]},
    {"data": [{"object_id": "note1", "ver": "v1"}]},
    {"data": [{"object_id": "note1", "ver": True}]},
    {"data": [{"object_id": "note1", "ver": ""}]},
])
def test_invalid_note_receipt_never_unlocks_even_if_nas_applied_change(harness, receipt):
    station, store, post, _ = harness
    station.receipt_override = receipt
    response = post({"kind": "note", "id": "note1", "action": "tags", "version": "v1", "value": []})
    assert response.status_code == 409
    assert response.json() == {"error": "WRITE_UNCERTAIN"}
    assert store.pending_writes(OWNER)[0]["status"] == "uncertain"


def test_notebook_create_lost_receipt_never_attempts_stack_assignment(harness):
    station, store, post, _ = harness
    station.fail = "lost"
    response = post({"kind": "notebook", "action": "create", "name": "새 메모장", "value": "책장 & A"})
    assert response.status_code == 409
    assert len(station.mutations) == 1
    assert station.books[-1]["stack"] == ""
    assert store.pending_writes(OWNER)[0]["status"] == "uncertain"


def test_notebook_assignment_failure_retains_successful_create(harness):
    station, store, post, _ = harness
    # First create succeeds, its readback is checked, and only the subsequent
    # assignment loses its response. No compensating delete is authorized.
    station.corrupt = lambda s: setattr(s, "fail", "lost") if len(s.mutations) == 2 else None
    response = post({"kind": "notebook", "action": "create", "name": "새 메모장", "value": "책장 & A"})
    assert response.status_code == 409
    assert len(station.mutations) == 2
    assert [v["object_id"] for v in station.books].count("newbook") == 1
    assert store.pending_writes(OWNER)[0]["status"] == "uncertain"


def test_missing_get_tags_are_read_from_matching_version_list(harness):
    station, store, post, _ = harness
    station.omit_tag = True
    response = post({"kind": "note", "id": "note1", "action": "move", "version": "v1", "value": "book2"})
    assert response.status_code == 200, response.text
    assert station.note["tag"] == ["old"]
    assert store.pending_writes(OWNER) == []


def test_preflight_session_expiry_is_read_only_and_releases_lock(harness):
    station, store, post, _ = harness
    station.info_fail = True
    response = post({"kind": "note", "id": "note1", "action": "trash", "version": "v1"})
    assert response.status_code == 401
    assert station.mutations == []
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("favorite", [True, False])
def test_shortcut_readback_must_confirm_requested_membership(harness, favorite):
    station, store, post, _ = harness
    station.corrupt = lambda s: setattr(s, "shortcuts", [] if favorite else [{"id": "note1", "category": "note"}])
    response = post({"kind": "note", "id": "note1", "action": "favorite", "version": "v1", "value": favorite})
    assert response.status_code == 409
    assert store.pending_writes(OWNER)[0]["status"] == "uncertain"


def test_attachment_opaque_metadata_is_part_of_readback(harness):
    station, store, post, _ = harness
    station.corrupt = lambda s: s.note["attachment"]["file1"].update(size=999)
    response = post({"kind": "note", "id": "note1", "action": "tags", "version": "v1", "value": []})
    assert response.status_code == 409
    assert store.pending_writes(OWNER)[0]["status"] == "uncertain"


@pytest.mark.parametrize("version,status,mutations", [("v1", 200, 1), ("stale", 409, 0)])
def test_remember_cookie_rotation_survives_repeated_access_in_one_action(harness, version, status, mutations):
    station, store, _, client = harness
    login = client.post("/api/auth/login", json={"username": "alice", "password": "password-private", "remember": True},
                        headers={"Origin": "http://testserver"})
    assert login.status_code == 200
    csrf = login.json()["csrf_token"]
    with store.connect() as db:
        db.execute("UPDATE sessions SET rotated=0")
    response = client.post("/api/library/action", json={"kind": "note", "id": "note1", "action": "tags", "version": version, "value": ["new"]},
                           headers={"Origin": "http://testserver", "X-CSRF-Token": csrf})
    assert response.status_code == status, response.text
    assert "set-cookie" in response.headers
    assert client.get("/api/auth/me").status_code == 200
    assert len(station.mutations) == mutations
    assert store.pending_writes(OWNER) == []


@pytest.mark.parametrize("failure", [None, "lost"])
def test_store_failure_after_mutation_still_returns_uncertain_and_keeps_lock(harness, monkeypatch, failure):
    from synonote_web.store import StoreError
    station, store, post, _ = harness
    station.fail = failure
    def unavailable(*args, **kwargs):
        raise StoreError("local status unavailable")
    monkeypatch.setattr(store, "finish_write", unavailable)
    body = {"kind": "note", "id": "note1", "action": "tags", "version": "v1", "value": ["new"]}
    response = post(body)
    assert response.status_code == 409, response.text
    assert response.json() == {"error": "WRITE_UNCERTAIN"}
    assert store.pending_writes(OWNER)[0]["status"] == "pending"
    assert post(body).status_code == 409
    assert len(station.mutations) == 1
