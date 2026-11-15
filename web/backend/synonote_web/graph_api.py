"""Read-only graph snapshots; register inside create_app with its session reader.

No graph cache, credentials, guessed title links, or independent NAS transport.
Only verified source envelopes exposed by NasClient.fetch supply document IDs.
"""
from __future__ import annotations

import re
from collections import defaultdict
from html.parser import HTMLParser
from urllib.parse import unquote

from fastapi import FastAPI, Request, Response, Query
from markdown_it import MarkdownIt

from .nas import NasClient, NasError


_DOCUMENT = "synology-note://note/"
_REMOTE = "synology-note://remote/"
_UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
_BAD_ESCAPE = re.compile(r"%(?![0-9a-fA-F]{2})")
_READ_ERRORS = {"NAS_UNAVAILABLE", "NAS_API_ERROR", "REMOTE_CHANGED", "ATTACHMENT_TOO_LARGE",
                "NAS_ADDRESS_BLOCKED", "NAS_HTTP_BLOCKED", "DOCUMENT_READ_ONLY"}


def _decode(value: str) -> str | None:
    if _BAD_ESCAPE.search(value):
        return None
    try:
        return unquote(value, errors="strict")
    except UnicodeDecodeError:
        return None


def _identity(destination: str) -> tuple[str, str] | None:
    """Mirror InternalNoteLinks.documentID/remoteID, including decode order."""
    decoded = _decode(destination)
    value = decoded if decoded is not None else destination
    if value.lower().startswith(_DOCUMENT):
        suffix = value[len(_DOCUMENT):]
        if _UUID.fullmatch(suffix):
            return "document", suffix.lower()
    if destination.lower().startswith(_REMOTE):
        suffix = destination[len(_REMOTE):]
        if suffix and not any(c in suffix for c in "/?#"):
            remote = _decode(suffix)
            if remote:
                return "remote", remote
    return None


class _Anchors(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.destinations: set[str] = set()
        self.hidden: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "template", "textarea", "title",
                   "xmp", "iframe", "noembed", "noframes", "plaintext"}:
            self.hidden.append(tag)
        if tag == "a" and not self.hidden:
            # HTML keeps the first attribute when a malformed anchor repeats
            # href; accepting the last could invent a different destination.
            href = next((value for key, value in attrs if key == "href"), None)
            if href:
                self.destinations.add(href)

    def handle_endtag(self, tag):
        for index in range(len(self.hidden) - 1, -1, -1):
            if self.hidden[index] == tag:
                del self.hidden[index:]
                break

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)


def _destinations(detail: dict, markdown: MarkdownIt) -> set[str]:
    if isinstance(detail.get("markdown"), str):
        # Like the native Markdown AST walker: ignore code, images, comments,
        # raw HTML text and unresolved reference links. Never scan URL substrings.
        return {child.attrGet("href") for token in markdown.parse(detail["markdown"])
                for child in (token.children or [])
                if child.type == "link_open" and child.attrGet("href")}
    parser = _Anchors()
    parser.feed(detail["html"])
    parser.close()
    return parser.destinations


def _snapshot(nas: NasClient, base, active) -> dict:
    summaries = [row for row in nas.notes(base, active) if not row["locked"] and not row["trashed"]]
    nodes = {row["id"]: {key: row[key] for key in ("id", "title", "notebook_id")} for row in summaries}
    documents: dict[str, list[str]] = defaultdict(list)
    destinations: dict[str, set[str]] = {}
    failures = []
    markdown = MarkdownIt("commonmark")
    # Deliberately sequential: a large library must not spawn one future/client
    # per note. All HTTP and attachment verification stay inside NasClient.
    for summary in summaries:
        note_id = summary["id"]
        try:
            detail = nas.fetch(base, active, note_id)
            if detail["locked"] or detail["trashed"]:
                nodes.pop(note_id, None)
                continue
            if detail["version"] != summary["version"]:
                raise NasError("REMOTE_CHANGED")
            nodes[note_id] = {key: detail[key] for key in ("id", "title", "notebook_id")}
            document_id = detail.get("source_document_id")
            if isinstance(document_id, str) and _UUID.fullmatch(document_id):
                documents[document_id.lower()].append(note_id)
            destinations[note_id] = _destinations(detail, markdown)
        except NasError as exc:
            # The parent owns SID renewal and cookie/session state. Do not turn
            # an expired session into a misleading successful partial graph.
            if exc.code == "NAS_SESSION_EXPIRED":
                raise
            failures.append({"id": note_id, "error": exc.code if exc.code in _READ_ERRORS else "NAS_API_ERROR"})
    identities = {document: ids[0] for document, ids in documents.items() if len(ids) == 1}
    for ids in documents.values():
        if len(ids) > 1:
            failures.extend({"id": note_id, "error": "AMBIGUOUS_DOCUMENT_ID"} for note_id in ids)
    edges = set()
    for source, links in destinations.items():
        for link in links:
            identity = _identity(link)
            if identity is None:
                continue
            kind, value = identity
            target = identities.get(value) if kind == "document" else value
            if target in nodes and source != target:
                edges.add((source, target))
    return {"nodes": sorted(nodes.values(), key=lambda row: row["id"]),
            "edges": [{"source": source, "target": target} for source, target in sorted(edges)],
            "failures": sorted(failures, key=lambda row: (row["id"], row["error"]))}


def register_graph_routes(app: FastAPI, *, read_nas, nas: NasClient) -> None:
    """Use the same authenticated, origin-checked reader as /api/notes."""
    @app.get("/api/resolve-note")
    def resolve_note(request: Request, response: Response, target: str = Query(max_length=2048)):
        return {"note_id": read_nas(request, response, lambda base, active: _resolve(nas, base, active, target))}

    @app.get("/api/graph")
    def graph(request: Request, response: Response):
        response.headers["Cache-Control"] = "no-store"
        return read_nas(request, response, lambda base, active: _snapshot(nas, base, active))


def _resolve(nas, base, active, target: str) -> str:
    from fastapi import HTTPException
    identity = _identity(target)
    if identity is None:
        raise HTTPException(422, detail='INVALID_NOTE_LINK')
    kind,value=identity
    rows=[n for n in nas.notes(base,active) if not n.get('locked') and not n.get('trashed')]
    if kind=='remote':
        if any(n['id']==value for n in rows):return value
        raise HTTPException(404,detail='NOTE_LINK_NOT_FOUND')
    matches=[]
    for row in rows:
        detail=nas.fetch(base,active,row['id'])
        if detail.get('locked') or detail.get('trashed'):continue
        if row.get('version') is not None and detail.get('version')!=row['version']:
            raise NasError('REMOTE_CHANGED')
        if (detail.get('source_document_id') or '').lower()==value:matches.append(row['id'])
    if len(matches)>1:raise HTTPException(409,detail='AMBIGUOUS_NOTE_LINK')
    if not matches:raise HTTPException(404,detail='NOTE_LINK_NOT_FOUND')
    return matches[0]
