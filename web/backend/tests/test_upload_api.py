import asyncio
import hashlib
import uuid

import httpx
from fastapi.testclient import TestClient

from test_api import FakeNas, app_at, post


class WritingNas(FakeNas):
    def __init__(self):
        super().__init__()
        self.attachments = []

    def write_markdown(self, base, active, **args):
        self.attachments.extend(b"".join(item["chunks"]()) for item in args["uploads"])
        return {"id": "note-1"}


def test_staged_upload_is_private_and_used_once_by_create_receipt(tmp_path):
    nas = WritingNas()
    app = app_at(tmp_path, nas, nas_url="https://nas.example")
    client = TestClient(app)
    other = TestClient(app)
    csrf = post(client, "/api/auth/login", {"username": "alice", "password": "correct"}).json()["csrf_token"]
    post(other, "/api/auth/login", {"username": "bob", "password": "correct"})
    draft, upload, create = (str(uuid.uuid4()) for _ in range(3))
    url = f"/api/drafts/{draft}/uploads/{upload}"
    payload = b"document contents"
    headers = {"Origin": "http://testserver", "X-CSRF-Token": csrf,
               "Content-Type": "application/octet-stream", "X-Upload-Name": "notes.txt",
               "X-Upload-Size": str(len(payload))}
    uploaded = client.put(url, params={"notebook_id": "book", "client_request_id": create},
                          content=payload, headers=headers)
    assert uploaded.status_code == 200, uploaded.text
    assert uploaded.json()["sha256"] == hashlib.sha256(payload).hexdigest()
    assert other.get(url).status_code == 404
    assert client.get(url + "/content").content == payload
    assert client.get(url + "/content").headers["content-disposition"].startswith("attachment")
    body = {"title": "Test", "notebook_id": "book", "client_request_id": create, "draft_id": draft,
            "markdown": f"[notes.txt](attachment://{upload})",
            "uploads": [{"upload_id": upload, "sha256": uploaded.json()["sha256"]}]}
    assert post(client, "/api/notes", {**body, "draft_id": str(uuid.uuid4())}, csrf=csrf).status_code == 404
    assert post(client, "/api/notes", body, csrf=csrf).json() == {"id": "note-1"}
    assert post(client, "/api/notes", body, csrf=csrf).json() == {"id": "note-1"}
    assert nas.attachments == [payload]


def test_upload_size_limit_and_csrf_apply_to_raw_body(tmp_path):
    client = TestClient(app_at(tmp_path, nas_url="https://nas.example"))
    csrf = post(client, "/api/auth/login", {"username": "alice", "password": "correct"}).json()["csrf_token"]
    url = f"/api/drafts/{uuid.uuid4()}/uploads/{uuid.uuid4()}"
    query = {"notebook_id": "book", "client_request_id": str(uuid.uuid4())}
    headers = {"Origin": "http://testserver", "Content-Type": "application/octet-stream",
               "X-Upload-Name": "large.bin", "X-Upload-Size": "50000001"}
    assert client.put(url, params=query, headers=headers).status_code == 403
    assert client.put(url, params=query, headers={**headers, "X-CSRF-Token": csrf}).status_code == 413
    assert client.get(url).status_code == 404


def test_streamed_overflow_without_content_length_discards_partial_upload(tmp_path, monkeypatch):
    monkeypatch.setattr("synonote_web.main.MAX_UPLOAD_SIZE", 300_000)
    app = app_at(tmp_path, nas_url="https://nas.example")
    url = f"/api/drafts/{uuid.uuid4()}/uploads/{uuid.uuid4()}"
    query = {"notebook_id": "book", "client_request_id": str(uuid.uuid4())}

    async def exercise():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://testserver") as client:
            login = await client.post("/api/auth/login", json={"username": "alice", "password": "correct"},
                                      headers={"Origin": "http://testserver"})
            csrf = login.json()["csrf_token"]
            headers = {"Origin": "http://testserver", "Content-Type": "application/octet-stream",
                       "X-CSRF-Token": csrf, "X-Upload-Name": "limit.bin", "X-Upload-Size": "300000"}
            receiving = asyncio.Event()
            proceed = asyncio.Event()

            async def body():
                yield b"A" * 262_144
                receiving.set()
                await proceed.wait()
                yield b"B" * 37_857

            upload = asyncio.create_task(client.put(url, params=query, headers=headers, content=body()))
            try:
                await asyncio.wait_for(receiving.wait(), timeout=3)
                state = await asyncio.wait_for(client.get(url), timeout=3)
                assert state.json()["status"] == "receiving"
                assert (await asyncio.wait_for(client.get("/api/health"), timeout=3)).status_code == 200
            finally:
                proceed.set()
                response = await upload
            assert "content-length" not in response.request.headers
            assert response.status_code == 413, response.text
            assert (await client.get(url)).status_code == 404
            response = await client.put(url, params=query, headers=headers, content=b"A" * 300_000)
            assert response.status_code == 200, response.text

    asyncio.run(exercise())
