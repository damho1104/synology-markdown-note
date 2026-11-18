from email.parser import BytesParser
from email.policy import default
import hashlib
import json
from urllib.parse import parse_qs

import httpx
import pytest

from synonote_web.compat.source_envelope import SourceEnvelope
from synonote_web.nas import NOTE, NasClient, NasError, NasLogin


BASE = "https://nas.example"
LOGIN = NasLogin("sid", None, {NOTE: {"path": "entry.cgi", "minVersion": 1, "maxVersion": 3}})
UPLOAD_ID = "11111111-1111-4111-8111-111111111111"
SECOND_ID = "22222222-2222-4222-8222-222222222222"
LINK = f"[파일](attachment://{UPLOAD_ID})"
PAYLOAD = b"attachment part one\nattachment part two"


def upload(**overrides):
    return dict(upload_id=UPLOAD_ID, name="보고서.md", mime="text/markdown",
                size=len(PAYLOAD), sha256=hashlib.sha256(PAYLOAD).hexdigest(),
                image=False, chunks=lambda: iter((PAYLOAD[:18], PAYLOAD[18:]))) | overrides


class Parts(httpx.SyncByteStream):
    def __init__(self, data):
        self.data = data

    def __iter__(self):
        yield self.data[:11]
        yield self.data[11:]


class MockNas(httpx.BaseTransport):
    def __init__(self, *, existing=False, fault=None):
        self.fault = fault
        self.mutations = []
        self.files = {}
        self.downloads = []
        self.references = {}
        self.row = {}
        if existing:
            body = "<p>Old</p>\n"
            source = SourceEnvelope.make("Old", body).encode()
            self.files = {"old-source": ("legacy-source.md", source), "old-file": ("old.pdf", b"original")}
            self.row = dict(object_id="n1", parent_id="b1", title="Old", content=body,
                            ver="v0", encrypt=False, recycle=False)

    def handle_request(self, request):
        form = dict(request.url.params)
        chunks = list(request.stream)
        body = b"".join(chunks)
        files = {}
        if request.headers["content-type"].startswith("multipart/"):
            assert int(request.headers["content-length"]) == len(body)
            assert "transfer-encoding" not in request.headers
            message = BytesParser(policy=default).parsebytes(
                b"Content-Type: " + request.headers["content-type"].encode() + b"\r\n\r\n" + body
            )
            for part in message.iter_parts():
                field = part.get_param("name", header="content-disposition")
                data = part.get_payload(decode=True)
                if part.get_filename():
                    files[field] = (part.get_filename(), data)
                    if data == PAYLOAD:
                        assert part.get_content_type() == "text/markdown"
                        assert PAYLOAD[:18] in chunks and PAYLOAD[18:] in chunks
                else:
                    form[field] = data.decode()
        else:
            form.update({key: value[0] for key, value in parse_qs(body.decode()).items()})
        method = form.pop("method")
        for field in ("api", "version", "_sid"):
            form.pop(field)
        params = {key: json.loads(value) for key, value in form.items()}
        if method == "download":
            file_id = params["file_id"]
            self.downloads.append((len(self.mutations), file_id))
            data = self.files[file_id][1]
            if self.fault == "final-hash" and len(self.mutations) == 4 and file_id == "file-2":
                data = b"x" * len(data)
            return httpx.Response(200, stream=Parts(data))
        if method == "get":
            data = dict(self.row, attachment={
                fid: {"name": name, "ref": self.references.get(fid, f"ref-{fid}")} for fid, (name, _) in self.files.items()
            })
        else:
            phase = len(self.mutations) + 1
            if self.row:
                assert params["ver"] == self.row["ver"] and params["check_conflict"] is True
            else:
                self.row.update(object_id="n1", parent_id=params["parent_id"], encrypt=False, recycle=False)
            for key in ("title", "content"):
                if key in params:
                    self.row[key] = params[key]
            self.row["ver"] = f"v{phase}"
            self.mutations.append(params)
            for entry in params.get("attachment", []):
                if entry["action"] == "delete":
                    del self.files[entry["file_id"]]
                    continue
                name, data = files[entry["name"]]
                file_id = f"file-{phase}"
                if phase == 2:
                    if self.fault == "old-id":
                        file_id = "old-file"
                    if self.fault == "extra-id":
                        self.files["extra"] = ("extra", b"extra")
                    if self.fault == "name":
                        name = "renamed"
                    if self.fault == "oversize":
                        data += b"!"
                self.files[file_id] = name, data
                if "ref" in entry:
                    self.references[file_id] = (None if self.fault == "missing-ref" else entry["ref"])
            if self.fault == phase:
                raise httpx.ReadError("NAS committed before losing the receipt")
            receipt = {"object_id": "n1", "ver": self.row["ver"]}
            data = receipt if method == "create" else {"data": [receipt]}
        return httpx.Response(200, json={"success": True, "data": data})


def client(monkeypatch, server):
    nas = NasClient()
    monkeypatch.setattr(nas, "_client", lambda: httpx.Client(transport=server))
    return nas


def save(nas, *, markdown=LINK, uploads=None, existing=False):
    return nas.write_markdown(BASE, LOGIN, note_id="n1" if existing else None, notebook_id="b1",
                              title="Title", markdown=markdown, version="v0" if existing else None,
                              uploads=[upload()] if uploads is None else uploads)


def test_missing_image_ref_stops_before_publishing_body(monkeypatch):
    server = MockNas(existing=True, fault="missing-ref")
    content = b"fixture image bytes"
    raster = upload(name="photo.png", mime="image/png", image=True,
                    chunks=lambda: iter([content]), size=len(content),
                    sha256=hashlib.sha256(content).hexdigest())
    with pytest.raises(NasError, match="WRITE_UNCERTAIN"):
        save(client(monkeypatch, server), markdown="!" + LINK, uploads=[raster], existing=True)
    assert len(server.mutations) == 2


@pytest.mark.parametrize("existing", [False, True])
def test_same_names_get_distinct_links_and_verified_readback(monkeypatch, existing):
    server = MockNas(existing=existing)
    nas = client(monkeypatch, server)
    markdown = LINK + f"\n\n[두 번째](attachment://{SECOND_ID})"
    result = save(nas, existing=existing, markdown=markdown,
                  uploads=[upload(), upload(upload_id=SECOND_ID)])
    assert result["attachment_bindings"] == {UPLOAD_ID: "file-2", SECOND_ID: "file-3"}
    assert result["markdown"] == markdown and result["editable"]
    assert 'ref="ref-file-2" href="https://nas.example/' in result["html"]
    assert 'ref="ref-file-3" href="https://nas.example/' in result["html"]
    assert "n1" in result["html"] and "_sid" not in result["html"]
    assert server.files["file-2"][0] != server.files["file-3"][0]
    assert all("보고서.md" in server.files[f"file-{phase}"][0] for phase in (2, 3))
    assert [(phase, fid) for phase, fid in server.downloads if fid in {"file-2", "file-3"}] == [
        (2, "file-2"), (3, "file-3"), (5, "file-2"), (5, "file-3"),
    ]
    if existing:
        assert server.files["old-file"] == ("old.pdf", b"original")


@pytest.mark.parametrize(("markdown", "uploads"), [
    (LINK, []),
    ("no link", [upload()]),
    (f"`{LINK}`", [upload()]),
    (f"!{LINK}", [upload(mime="image/svg+xml", image=True)]),
    (LINK + f"\n\n!{LINK}", [upload()]),
    (LINK + f'\n\n<iframe src="attachment://{UPLOAD_ID}"></iframe>', [upload()]),
    (LINK, [upload(), upload()]),
    (LINK, [upload(sha256="0" * 64)]),
    (LINK, [upload(size=len(PAYLOAD) + 1)]),
])
def test_invalid_attachment_is_rejected_before_staging(monkeypatch, markdown, uploads):
    server = MockNas()
    with pytest.raises(NasError, match="MARKDOWN_UNSUPPORTED"):
        save(client(monkeypatch, server), markdown=markdown, uploads=uploads)
    assert not server.mutations


@pytest.mark.parametrize(("fault", "phase"), [
    (1, 1), (2, 2), (3, 3), (4, 4),
    ("old-id", 2), ("extra-id", 2), ("name", 2), ("oversize", 2), ("final-hash", 4),
])
def test_uncertain_attachment_write_stops_mutations(monkeypatch, fault, phase):
    server = MockNas(existing=True, fault=fault)
    with pytest.raises(NasError, match="WRITE_UNCERTAIN"):
        save(client(monkeypatch, server), existing=True)
    assert len(server.mutations) == phase
    assert "old-file" in server.files
    if phase < 4:
        assert "old-source" in server.files
        assert all(entry["action"] == "create" for mutation in server.mutations
                   for entry in mutation.get("attachment", []))


def test_iter_download_yields_before_stream_finishes_and_enforces_bound(monkeypatch):
    class Overflow(httpx.SyncByteStream):
        def __iter__(self):
            yield b"first" * 14_000
            yield b"over" * 20_000

    transport = httpx.MockTransport(lambda request: httpx.Response(200, stream=Overflow()))
    chunks = client(monkeypatch, transport).iter_download(BASE, LOGIN, "n1", "f1", max_size=80_000)
    assert next(chunks).startswith(b"first")
    with pytest.raises(NasError, match="ATTACHMENT_TOO_LARGE"):
        list(chunks)


def test_long_unicode_filename_fits_nas_and_preserves_extension(monkeypatch):
    server = MockNas()
    result = save(client(monkeypatch, server), uploads=[upload(name="한" * 190 + ".md")])
    filename, _ = server.files[result["attachment_bindings"][UPLOAD_ID]]
    assert len(filename.encode("utf-8")) <= 255
    assert filename.endswith(".md")


def test_verified_raster_can_render_inline_but_general_file_cannot_on_later_save(monkeypatch):
    server = MockNas()
    nas = client(monkeypatch, server)
    image = f"![photo](attachment://{SECOND_ID})"
    payload = b"fake PNG; the staging store validates the actual format"
    raster = upload(upload_id=SECOND_ID, name="photo.png", mime="image/png", image=True,
                    size=len(payload), sha256=hashlib.sha256(payload).hexdigest(),
                    chunks=lambda: iter((payload,)))
    result = save(nas, markdown=LINK + "\n\n" + image, uploads=[upload(), raster])
    assert f'<img alt="photo" ref="{SECOND_ID}">' in result["html"]
    revised = nas.write_markdown(BASE, LOGIN, note_id="n1", notebook_id="b1", title="Revised",
                                 markdown=image, version=result["version"])
    assert revised["attachment_bindings"] == result["attachment_bindings"]
    assert "file-2" in server.files
    mutations = len(server.mutations)
    with pytest.raises(NasError, match="MARKDOWN_UNSUPPORTED"):
        nas.write_markdown(BASE, LOGIN, note_id="n1", notebook_id="b1", title="Revised",
                           markdown=f"!{LINK}", version=revised["version"])
    assert len(server.mutations) == mutations


def test_chunk_source_failure_after_staging_is_uncertain(monkeypatch):
    server = MockNas(existing=True)

    def chunks():
        if server.mutations:
            raise RuntimeError("staged bytes became unreadable")
        yield PAYLOAD

    with pytest.raises(NasError, match="WRITE_UNCERTAIN"):
        save(client(monkeypatch, server), uploads=[upload(chunks=chunks)], existing=True)
    assert len(server.mutations) == 1
    assert {"old-source", "old-file", "file-1"} == server.files.keys()


@pytest.mark.parametrize("as_attachment", [False, True])
def test_stream_distinguishes_nas_error_from_labelled_download(monkeypatch, as_attachment):
    payload = b'{"success":false,"error":{"code":106}}'
    headers = {"Content-Disposition": "attachment; filename=sample.json"} if as_attachment else {}
    transport = httpx.MockTransport(lambda request: httpx.Response(200, headers=headers, stream=Parts(payload)))
    stream = client(monkeypatch, transport).iter_download(BASE, LOGIN, "n1", "f1")
    if as_attachment:
        assert b"".join(stream) == payload
    else:
        with pytest.raises(NasError, match="NAS_SESSION_EXPIRED"):
            next(stream)
