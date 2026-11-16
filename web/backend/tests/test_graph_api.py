"""Graph contracts through real NasClient calls and in-memory HTTP only."""
import json
from urllib.parse import parse_qs

import httpx
import pytest
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from synonote_web.compat.source_envelope import SourceEnvelope
from synonote_web.graph_api import register_graph_routes
from synonote_web.nas import NOTE, NasClient, NasError, NasLogin


DOC_A = "12345678-1234-1234-1234-123456789abc"
DOC_B = "abcdefab-abcd-abcd-abcd-abcdefabcdef"


@pytest.fixture
def graph_http(monkeypatch):
    rows, files, errors, seen = {}, {}, {}, []

    def add(note_id, *, markdown=None, document_id=DOC_A, html="<p>body</p>", **changes):
        row = dict(object_id=note_id, title=note_id, parent_id="book1", ver="1",
                   encrypt=False, recycle=False, content=html, attachment=None)
        if markdown is not None:
            row["attachment"] = {"source": {"name": "synology-note-source.md", "ref": None}}
            files[note_id] = SourceEnvelope.make(markdown, html, document_id=document_id).encode()
        row.update(changes)
        rows[note_id] = row

    def handler(request):
        assert request.url.host == "nas.example"
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        seen.append(form)
        assert form["method"] in {"query", "list", "get", "download"}, "Graph must never write"
        if form["api"] == "SYNO.API.Info":
            data = {NOTE: {"path": "entry.cgi", "minVersion": 1, "maxVersion": 3}}
        elif form["method"] == "list":
            offset = int(form["offset"])
            page = [{k: v for k, v in row.items() if k not in {"content", "attachment"}}
                    for row in rows.values()][offset:offset + 2]
            data = {"offset": offset, "total": len(rows), "notes": page}
        else:
            note_id = json.loads(form["object_id"])
            if note_id in errors:
                error = errors[note_id]
                if isinstance(error, Exception):
                    raise error
                if isinstance(error, dict):
                    return httpx.Response(200, json={"success": True, "data": {**rows[note_id], **error}})
                return httpx.Response(200, json={"success": False, "error": {"code": error}})
            if form["method"] == "download":
                return httpx.Response(200, content=files[note_id])
            data = rows[note_id]
        return httpx.Response(200, json={"success": True, "data": data})

    monkeypatch.setattr(NasClient, "_client", lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    nas = NasClient()
    app = FastAPI()

    @app.exception_handler(NasError)
    async def nas_error(_request, exc):
        return JSONResponse({"error": exc.code}, status_code=502)

    def read_nas(request, response, fn):
        if request.cookies.get("session") != "test-session":
            raise HTTPException(401, "LOGIN_REQUIRED")
        response.headers["Cache-Control"] = "no-store"
        return fn("https://nas.example", NasLogin("private-sid", None))

    register_graph_routes(app, read_nas=read_nas, nas=nas)
    client = TestClient(app)
    client.cookies.set("session", "test-session")
    yield client, add, errors, seen
    client.close()


def test_verified_markdown_and_html_resolve_only_existing_identities(graph_http):
    client, add, _, seen = graph_http
    add("a", markdown=f"[target](<synology-note://note/{DOC_B.upper()}>)\n"
        "[legacy](synology-note://remote/legacy%2Did)\n"
        "[missing](synology-note://remote/absent)\n[guess](legacy-id.md)\n"
        "[self](synology-note://remote/a)")
    add("b", markdown="", document_id=DOC_B)
    add("legacy-id", html='<a href="synology-note://remote/a">backlink</a>')
    response = client.get("/api/graph")
    assert response.status_code == 200
    assert response.json() == {
        "nodes": [{"id": "a", "title": "a", "notebook_id": "book1"},
                  {"id": "b", "title": "b", "notebook_id": "book1"},
                  {"id": "legacy-id", "title": "legacy-id", "notebook_id": "book1"}],
        "edges": [{"source": "a", "target": "b"}, {"source": "a", "target": "legacy-id"},
                  {"source": "legacy-id", "target": "a"}], "failures": [],
    }
    assert response.headers["Cache-Control"] == "no-store"
    assert "private-sid" not in response.text
    assert [f["offset"] for f in seen if f["method"] == "list"] == ["0", "2"]


def test_duplicate_document_id_never_chooses_one_but_remote_link_still_works(graph_http):
    client, add, _, _ = graph_http
    add("a", markdown=f"[ambiguous](synology-note://note/{DOC_B})\n[exact](synology-note://remote/b)")
    add("b", markdown="", document_id=DOC_B)
    add("c", markdown="", document_id=DOC_B.upper())
    graph = client.get("/api/graph").json()
    assert graph["edges"] == [{"source": "a", "target": "b"}]
    assert graph["failures"] == [{"id": "b", "error": "AMBIGUOUS_DOCUMENT_ID"},
                                 {"id": "c", "error": "AMBIGUOUS_DOCUMENT_ID"}]


def test_code_images_comments_and_stale_html_are_not_markdown_links(graph_http):
    client, add, _, _ = graph_http
    add("a", markdown="`[inline](synology-note://remote/b)`\n\n"
        "```md\n[fenced](synology-note://remote/b)\n```\n\n"
        "![image](synology-note://remote/b)\n<!-- [comment](synology-note://remote/b) -->",
        html='<a href="synology-note://remote/b">stale</a>')
    add("b")
    assert client.get("/api/graph").json()["edges"] == []


@pytest.mark.parametrize("destination,linked", [
    (f"SYNOLOGY-NOTE://NOTE/{DOC_B.upper()}", True),
    (f"synology-note%3A%2F%2Fnote%2F{DOC_B}", True),
    (f"synology-note://note/{DOC_B}?x=1", False),
    (f"synology-note://note/{{{DOC_B}}}", False),
    ("synology-note://remote/%62", True),
    ("synology-note%3A%2F%2Fremote%2Fb", False),
    ("synology-note://remote/b?x=1", False),
    ("synology-note://remote/b/", False),
    ("synology-note://remote/%ZZ", False),
    ("synology-note://remote/%FF", False),
    ("https://example.org/synology-note://remote/b", False),
])
def test_internal_note_links_swift_identity_contract(graph_http, destination, linked):
    client, add, _, _ = graph_http
    add("a", html=f'<a href="{destination}">target</a>')
    add("b", markdown="", document_id=DOC_B)
    assert client.get("/api/graph").json()["edges"] == ([{"source": "a", "target": "b"}] if linked else [])


def test_locked_and_trashed_are_not_fetched_or_linked(graph_http):
    client, add, _, seen = graph_http
    add("a", html='<a href="synology-note://remote/locked">x</a><a href="synology-note://remote/trash">x</a>')
    add("locked", encrypt=True)
    add("trash", recycle=True)
    graph = client.get("/api/graph").json()
    assert graph == {"nodes": [{"id": "a", "title": "a", "notebook_id": "book1"}], "edges": [], "failures": []}
    assert [json.loads(f["object_id"]) for f in seen if f["method"] == "get"] == ["a"]


def test_read_failure_is_reported_without_private_exception_details(graph_http):
    client, add, errors, _ = graph_http
    add("a")
    add("b")
    errors["b"] = httpx.ReadError("private-sid password secret")
    response = client.get("/api/graph")
    assert response.json()["failures"] == [{"id": "b", "error": "NAS_UNAVAILABLE"}]
    assert "private-sid" not in response.text and "password" not in response.text


def test_expired_sid_is_propagated_for_parent_reauthentication(graph_http):
    client, add, errors, _ = graph_http
    add("a")
    errors["a"] = 119
    response = client.get("/api/graph")
    assert response.status_code == 502
    assert response.json() == {"error": "NAS_SESSION_EXPIRED"}


def test_authentication_wraps_the_entire_snapshot(graph_http):
    client, add, _, seen = graph_http
    add("a")
    client.cookies.clear()
    assert client.get("/api/graph").status_code == 401
    assert seen == []


def test_empty_graph(graph_http):
    client, _, _, _ = graph_http
    assert client.get("/api/graph").json() == {"nodes": [], "edges": [], "failures": []}


def test_html_literal_regions_and_ignored_duplicate_href_do_not_make_links(graph_http):
    client, add, _, _ = graph_http
    add("a", html='<pre><code>&lt;a href="synology-note://remote/b"&gt;</code></pre>'
        '<!-- <a href="synology-note://remote/b">comment</a> -->'
        '<script><a href="synology-note://remote/b">script</a></script>'
        '<textarea><a href="synology-note://remote/b">literal</a></textarea>'
        '<a href="https://example.org" href="synology-note://remote/b">external</a>')
    add("b")
    assert client.get("/api/graph").json()["edges"] == []


def test_reference_markdown_links_deduplicate_and_decode_remote_ids_once(graph_http):
    client, add, _, _ = graph_http
    add("a", markdown="[one][ref]\n[two][ref]\n\n[ref]: <synology-note://remote/NAS:%ED%95%9C%EA%B8%80%20%25%20%3F%20%2F>")
    add("NAS:한글 % ? /")
    assert client.get("/api/graph").json()["edges"] == [{"source": "a", "target": "NAS:한글 % ? /"}]


def test_html_real_anchor_inside_code_is_still_an_actual_link(graph_http):
    client, add, _, _ = graph_http
    add("a", html='<code><a href="synology-note://remote/b">clickable HTML anchor</a></code>')
    add("b")
    assert client.get("/api/graph").json()["edges"] == [{"source": "a", "target": "b"}]


def test_nested_template_keeps_its_outer_contents_hidden(graph_http):
    client, add, _, _ = graph_http
    add("a", html='<template><template></template><a href="synology-note://remote/b">hidden</a></template>'
        '<a href="synology-note://remote/c">visible</a>')
    add("b")
    add("c")
    assert client.get("/api/graph").json()["edges"] == [{"source": "a", "target": "c"}]


@pytest.mark.parametrize("changed", [{"encrypt": True}, {"recycle": True}])
def test_notes_that_become_hidden_during_fetch_leave_no_dangling_edges(graph_http, changed):
    client, add, errors, _ = graph_http
    add("a", html='<a href="synology-note://remote/b">link</a>')
    add("b")
    errors["b"] = changed
    graph = client.get("/api/graph").json()
    assert [node["id"] for node in graph["nodes"]] == ["a"]
    assert graph["edges"] == []


def test_changed_version_is_a_visible_failure_instead_of_an_unverified_edge(graph_http):
    client, add, errors, _ = graph_http
    add("a", html='<a href="synology-note://remote/b">link</a>')
    add("b")
    errors["a"] = {"ver": "2"}
    graph = client.get("/api/graph").json()
    assert graph["edges"] == []
    assert graph["failures"] == [{"id": "a", "error": "REMOTE_CHANGED"}]


def test_resolver_uses_remote_ids_or_unique_verified_document_ids():
    from fastapi import HTTPException
    from synonote_web.graph_api import _resolve
    class Nas:
        def notes(self,*args):return [{'id':'n1'},{'id':'n2'}]
        def fetch(self,base,active,note_id):return {'source_document_id':'12345678-1234-4321-ABCD-123456789ABC' if note_id=='n1' else None}
    nas=Nas()
    assert _resolve(nas,'base',None,'synology-note://remote/n2')=='n2'
    assert _resolve(nas,'base',None,'synology-note://note/12345678-1234-4321-ABCD-123456789ABC')=='n1'
    with pytest.raises(HTTPException) as exc:_resolve(nas,'base',None,'https://evil.example')
    assert exc.value.status_code==422
    nas.fetch=lambda *args:{'source_document_id':'12345678-1234-4321-ABCD-123456789ABC'}
    with pytest.raises(HTTPException) as exc:_resolve(nas,'base',None,'synology-note://note/12345678-1234-4321-ABCD-123456789ABC')
    assert exc.value.status_code==409


def test_summary_is_immediate_and_index_survives_restart_and_only_refetches_changed_notes(tmp_path):
    from synonote_web.store import Store
    from threading import Lock
    import time
    class Nas:
        def __init__(self):
            self.calls = []; self.versions = {}; self.active = 0; self.maximum = 0; self.lock = Lock()
        def notes(self, *args):
            return [dict(id=str(i), title=f'Note {i}', notebook_id='book', version=self.versions.get(str(i),'1'), tags=[], locked=False, trashed=False) for i in range(500)]
        def fetch(self, base, login, note_id):
            with self.lock:
                self.calls.append(note_id); self.active += 1; self.maximum = max(self.maximum, self.active)
            try:
                time.sleep(0.001)
                return dict(id=note_id, title=f'Note {note_id}', notebook_id='book', version=self.versions.get(note_id,'1'), locked=False, trashed=False, source_document_id='12345678-1234-4321-abcd-123456789abc' if note_id == '7' else None, html='<a href="Note 1.md">target</a>')
            finally:
                with self.lock: self.active -= 1
    nas = Nas()
    def client():
        app = FastAPI()
        register_graph_routes(app, read_nas=lambda req,res,fn:fn('base',None), nas=nas,
            store=Store(tmp_path), owner_for_request=lambda req,res:req.headers.get('x-account','first'))
        return TestClient(app)
    with client() as web:
        first = web.get('/api/graph?summary=true').json()
        assert len(first['nodes']) == len(first['pending']) == 500 and nas.calls == []
        for offset in range(0,500,8):
            response = web.get('/api/graph/entries', params={'ids':json.dumps(first['pending'][offset:offset+8])})
            assert response.status_code == 200
        assert len(nas.calls) == 500 and nas.maximum <= 4
        warm = web.get('/api/graph?summary=true').json()
        assert warm['pending'] == [] and len(warm['entries']) == 500 and len(nas.calls) == 500
        assert warm['entries'][0]['links'] == [{'kind':'title','target':'Note 1'}]
        assert web.get('/api/resolve-note', params={'target':'synology-note://note/12345678-1234-4321-abcd-123456789abc'}).json() == {'note_id':'7'}
        assert len(nas.calls) == 500  # Navigation shares the already verified index.

        nas.versions['7'] = '2'
        changed = web.get('/api/graph?summary=true').json()
        assert changed['pending'] == ['7'] and len(nas.calls) == 500
        web.get('/api/graph/entries', params={'ids':'["7"]'})
        assert len(nas.calls) == 501
        assert web.get('/api/graph/entries',params={'ids':json.dumps([str(i) for i in range(9)])}).status_code == 422
        other = web.get('/api/graph?summary=true',headers={'x-account':'other'}).json()
        assert len(other['pending']) == 500 and other['entries'] == []
    with client() as web:
        restarted = web.get('/api/graph?summary=true').json()
        assert restarted['pending'] == [] and len(nas.calls) == 501
    assert b'Note 1.md' not in (tmp_path/'web.sqlite3').read_bytes()


def test_title_links_resolve_only_unique_plain_filenames(graph_http):
    client, add, _, _ = graph_http
    add('a', markdown='[target](<한글 노트.md>) [path](folder/한글%20노트.md)')
    add('b', title='한글 노트')
    assert client.get('/api/graph').json()['edges'] == [{'source':'a','target':'b'}]
    assert client.get('/api/resolve-note',params={'target':'한글%20노트.md'}).json()['note_id'] == 'b'
    add('c', title='한글 노트')
    assert client.get('/api/graph').json()['edges'] == []
    assert client.get('/api/resolve-note',params={'target':'한글%20노트.md'}).status_code == 409


def test_batched_reads_keep_authentication_and_session_expiry(graph_http):
    client, add, errors, seen = graph_http
    add('a')
    errors['a'] = 119
    assert client.get('/api/graph/entries',params={'ids':'["a"]'}).json() == {'error':'NAS_SESSION_EXPIRED'}
    client.cookies.clear(); seen.clear()
    assert client.get('/api/graph/entries',params={'ids':'["a"]'}).status_code == 401
    assert seen == []
