import json

import httpx
import pytest

from synonote_cli.api import NOTE, NOTEBOOK, Note, NoteStationAPI
from synonote_cli.errors import CLIError


def response(payload):
    return httpx.Response(200, json={"success": True, "data": payload})


def make_api(handler):
    api = NoteStationAPI("https://nas.example:5001", httpx.Client(transport=httpx.MockTransport(handler)))
    api.sid = "test-session"
    api.info = {
        NOTE: {"path": "entry.cgi", "minVersion": 1, "maxVersion": 3, "requestFormat": "JSON"},
        NOTEBOOK: {"path": "entry.cgi", "minVersion": 2, "maxVersion": 2, "requestFormat": "JSON"},
    }
    return api


def test_note_create_serializes_json_form_with_no_multipart():
    requests = []
    def handler(request):
        requests.append(request)
        return response({"object_id": "created", "ver": "2"})
    api = make_api(handler)
    try:
        assert api.write(note_id=None, notebook_id="nb", title="한글", html="<h1>제목</h1>") == ("created", "2")
        sent = requests[0]
        assert sent.url.path == "/webapi/entry.cgi"
        assert "multipart" not in sent.headers["content-type"]
        fields = dict(httpx.QueryParams(sent.content.decode("utf-8")).multi_items())
        assert fields["api"] == NOTE and fields["method"] == "create" and fields["_sid"] == "test-session"
        assert json.loads(fields["content"]) == "<h1>제목</h1>"
        assert json.loads(fields["commit_msg"]) == {"device": "desktop", "listable": False}
        assert json.loads(fields["title"]) == "한글"
    finally:
        api.close()


def test_multipart_moves_api_routing_to_query_and_preserves_binary():
    requests = []
    def handler(request):
        requests.append(request)
        return response({"data": [{"ver": "11"}]})
    api = make_api(handler)
    try:
        assert api.write(note_id="n1", version="10", uploads=[("원문.md", "text/markdown", b"\x00\xff\xe1")]) == ("n1", "11")
        sent = requests[0]
        assert sent.url.params["api"] == NOTE and sent.url.params["_sid"] == "test-session"
        assert sent.url.params["method"] == "set" and sent.url.params["version"] == "3"
        assert "multipart/form-data" in sent.headers["content-type"]
        assert b'filename="\xec\x9b\x90\xeb\xac\xb8.md"' in sent.content
        assert b"\x00\xff\xe1" in sent.content
        assert b'name="check_conflict"\r\n\r\ntrue\r\n' in sent.content
    finally:
        api.close()


def test_raw_attachment_download_detects_error_even_without_json_content_type():
    def handler(_request):
        return httpx.Response(200, content=b'{"success":false,"error":{"code":105}}',
                              headers={"content-type": "application/octet-stream"})
    api = make_api(handler)
    try:
        with pytest.raises(CLIError) as error:
            api.download("a1", "n1")
        assert error.value.code == "REMOTE_ERROR"
    finally:
        api.close()


def test_paginated_list_rejects_duplicate_ids():
    def handler(_request):
        return response({"total": 2, "offset": 0, "notebooks": [
            {"object_id": "n1", "title": "first", "stack": ""},
            {"object_id": "n1", "title": "duplicate", "stack": ""}]})
    api = make_api(handler)
    try:
        with pytest.raises(CLIError) as error:
            api.notebooks()
        assert error.value.code == "REMOTE_ERROR"
    finally:
        api.close()


def test_create_notebook_v2_receipt_and_book_readback():
    methods = []
    created = False
    def handler(request):
        nonlocal created
        fields = dict(httpx.QueryParams(request.content.decode()).multi_items())
        methods.append((fields["api"], fields["method"], fields))
        if fields["method"] == "create":
            created = True
            return response({"object_id": "newbook"})
        return response({"offset": 0, "total": 1 if created else 0, "notebooks": [
            {"object_id": "newbook", "title": "by-project", "stack": ""}] if created else []})
    api = make_api(handler)
    try:
        assert api.create_notebook("by-project") == {"id": "newbook", "name": "by-project", "stack": ""}
        assert [method for _, method, _ in methods] == ["list", "create", "list"]
        assert json.loads(methods[1][2]["title"]) == "by-project"
        assert methods[1][2]["version"] == "2"
    finally:
        api.close()


def test_stack_move_accepts_empty_data_and_confirms_membership():
    stack = ""
    def handler(request):
        nonlocal stack
        fields = dict(httpx.QueryParams(request.content.decode()).multi_items())
        if fields["method"] == "set":
            assert json.loads(fields["object_id"]) == ["nb"]
            stack = json.loads(fields["stack"])
            return httpx.Response(200, json={"success": True})
        return response({"offset": 0, "total": 1, "notebooks": [
            {"object_id": "nb", "title": "by-project", "stack": stack}]})
    api = make_api(handler)
    try:
        assert api.move_notebook_to_stack("nb", "LLM-Daily-Summary")["stack"] == "LLM-Daily-Summary"
    finally:
        api.close()


def test_note_move_only_changes_parent_and_preserves_payload():
    original = Note("n1", "old", "프로젝트-sample", "6", "<h1>sample</h1>",
                    [{"id": "file1", "name": "source.md", "ref": None}])
    parent = "old"
    version = "6"
    def handler(request):
        nonlocal parent, version
        fields = dict(httpx.QueryParams(request.content.decode()).multi_items())
        if fields["method"] == "set":
            assert json.loads(fields["object_id"]) == original.id
            assert json.loads(fields["ver"]) == original.version
            assert json.loads(fields["check_conflict"]) is True
            assert json.loads(fields["parent_id"]) == "new"
            assert "content" not in fields and "attachment" not in fields and "title" not in fields
            parent, version = "new", "7"
            return response({"data": [{"ver": version}]})
        assert fields["method"] == "get"
        return response({"object_id": original.id, "parent_id": parent, "title": original.title,
                         "ver": version, "content": original.html,
                         "attachment": {"file1": {"name": "source.md", "ref": None}}})
    api = make_api(handler)
    try:
        after = api.move_note(original, "new")
        assert after.id == original.id and after.notebook_id == "new"
        assert after.html == original.html and after.attachments == original.attachments
    finally:
        api.close()
