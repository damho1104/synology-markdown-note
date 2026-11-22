"""Native Note Station revision calls through the web app and mock HTTP."""
import json
from urllib.parse import parse_qs

import httpx
from fastapi.testclient import TestClient

from synonote_web.nas import NOTE, NasClient, NasLogin
from test_api import app_at, post


def test_revision_preview_and_restore_verify_the_nas_version(tmp_path, monkeypatch):
    api_version = "SYNO.NoteStation.Note.Version"
    old = dict(object_id="note1", title="이전 제목", content="<p>이전 본문</p>", ver="old",
               parent_id="book1", encrypt=False, recycle=False, attachment={})
    current = dict(old, title="현재 제목", content="<p>현재 본문</p>", ver="latest")
    mutations = []
    lost = False

    def handler(request):
        fields = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        api, method = fields["api"], fields["method"]
        if api == "SYNO.API.Info":
            payload = {NOTE: {"path":"entry.cgi","minVersion":1,"maxVersion":3},
                       api_version: {"path":"entry.cgi","minVersion":1,"maxVersion":2}}
        elif api == NOTE and method == "get":
            assert json.loads(fields["object_id"]) == "note1"
            payload = old if json.loads(fields.get("ver", "null")) == "old" else current
        elif api == api_version and method == "list":
            assert json.loads(fields["object_id"]) == "note1"
            assert json.loads(fields["filter"]) == {"listable": True}
            payload = {"offset": 0, "total": 1, "versions": [{"version":"old", "mtime":1700000000}]}
        else:
            assert api == api_version and method == "restore" and fields["version"] == "2"
            assert json.loads(fields["ver"]) == "old"
            mutations.append(method)
            current.update(old, ver=f"restored-{len(mutations)}")
            if lost:
                raise httpx.ReadError("lost restoration receipt")
            payload = {}
        return httpx.Response(200, json={"success":True, "data":payload})

    monkeypatch.setattr(NasClient, "_client", lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    monkeypatch.setattr(NasClient, "login", lambda *args: NasLogin("session", None))
    app = app_at(tmp_path, NasClient(), nas_url="https://nas.example")
    with TestClient(app) as client:
        logged_in = post(client, "/api/auth/login", dict(username="alice", password="correct"))
        headers = {"Origin":"http://testserver", "X-CSRF-Token":logged_in.json()["csrf_token"]}
        path = "/api/notes/note1"
        listing = client.get(path + "/revisions")
        assert listing.json() == {"revisions":[{"version":"old","modified_at":1700000000}]}
        preview = client.get(path + "/revisions", params={"version":"old"})
        assert preview.json() == {"version":"old", "title":"이전 제목", "html":"<p>이전 본문</p>"}
        assert preview.headers["Cache-Control"] == "no-store"
        command = {"notebook_id":"book1", "title":"현재 제목", "version":"stale", "restore_version":"old"}
        assert client.put(path, json=command, headers=headers).json()["error"] == "REMOTE_CHANGED"
        assert mutations == []
        command["version"] = "latest"
        restored = client.put(path, json=command, headers=headers)
        assert restored.status_code == 200 and restored.json()["version"] == "restored-1"
        assert restored.json()["html"] == old["content"]
        assert mutations == ["restore"]
        lost = True
        command["version"] = "restored-1"
        assert client.put(path, json=command, headers=headers).json()["error"] == "WRITE_UNCERTAIN"
        assert client.put(path, json=command, headers=headers).json()["detail"] == "WRITE_REVIEW_REQUIRED"
        assert mutations == ["restore", "restore"]
