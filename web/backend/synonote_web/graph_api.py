"""Read-only graph snapshots and bounded, versioned link indexing.

Cached link metadata is encrypted and scoped to the authenticated NAS account.
Only verified source envelopes exposed by NasClient.fetch supply document IDs.
"""
from __future__ import annotations

import re
import json
from concurrent.futures import ThreadPoolExecutor
from threading import BoundedSemaphore

_GRAPH_READS = BoundedSemaphore(4)
from collections import defaultdict
from html.parser import HTMLParser
from urllib.parse import unquote
from unicodedata import normalize

from fastapi import FastAPI, Request, Response, Query
from markdown_it import MarkdownIt
from pydantic import BaseModel, Field

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
    title = _decode(destination) or destination
    if title.lower().endswith('.md') and not any(c in title for c in '/\\?#:\n') and len(title) > 3:
        return 'title', title[:-3]
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


class _BodyText(_Anchors):
    boundaries = {"p", "div", "br", "li", "tr", "td", "th", "pre", "blockquote",
                  "h1", "h2", "h3", "h4", "h5", "h6"}

    def __init__(self):
        super().__init__()
        self.parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        super().handle_starttag(tag, attrs)
        if tag in self.boundaries and not self.hidden:
            self.parts.append(" ")

    def handle_endtag(self, tag):
        super().handle_endtag(tag)
        if tag in self.boundaries and not self.hidden:
            self.parts.append(" ")

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def _search_text(value: str) -> str:
    return " ".join(normalize("NFKC", value).casefold().split())


class BodySearch(BaseModel):
    query: str = Field(min_length=1, max_length=256)


def _graph_entry(entry: dict) -> dict:
    return {name: value for name, value in entry.items() if name != "body_text"}


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
    titles = defaultdict(list)
    for node in nodes.values(): titles[node['title']].append(node['id'])
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
            target = identities.get(value) if kind == "document" else (titles[value][0] if kind == 'title' and len(titles[value]) == 1 else None) if kind == 'title' else value
            if target in nodes and source != target:
                edges.add((source, target))
    return {"nodes": sorted(nodes.values(), key=lambda row: row["id"]),
            "edges": [{"source": source, "target": target} for source, target in sorted(edges)],
            "failures": sorted(failures, key=lambda row: (row["id"], row["error"]))}


def register_graph_routes(app: FastAPI, *, read_nas, nas: NasClient, store=None, owner_for_request=None) -> None:
    """Use the same authenticated, origin-checked reader as /api/notes."""
    @app.get("/api/resolve-note")
    def resolve_note(request: Request, response: Response, target: str = Query(max_length=2048)):
        response.headers['Cache-Control'] = 'no-store'
        owner = owner_for_request(request, response) if owner_for_request else None
        return {"note_id": read_nas(request, response, lambda base, active: _resolve(nas, base, active, target, store=store, owner=owner))}

    @app.post("/api/search/body")
    def search_body(body: BodySearch, request: Request, response: Response):
        response.headers["Cache-Control"] = "no-store"
        owner = owner_for_request(request, response) if owner_for_request else None
        needle = _search_text(body.query)

        def search(base, active):
            versions = {row["id"]: row["version"] for row in nas.notes(base, active)
                        if not row["locked"] and not row["trashed"]}
            entries = store.load_graph_index(owner, versions) if store and owner else []
            indexed = [entry for entry in entries if isinstance(entry.get("body_text"), str)]
            return {"matches": [{"id": row["id"], "version": row["version"]} for row in indexed
                                if needle and needle in row["body_text"]],
                    "indexed": len(indexed), "total": len(versions)}

        return read_nas(request, response, search)

    @app.get("/api/graph")
    def graph(request: Request, response: Response, summary: bool = False):
        response.headers["Cache-Control"] = "no-store"
        if summary:
            owner = owner_for_request(request, response) if owner_for_request else None
            def summaries(base, active):
                rows = [row for row in nas.notes(base, active) if not row['locked'] and not row['trashed']]
                entries = store.load_graph_index(owner, {row['id']: row['version'] for row in rows}) if store and owner else []
                indexed = {entry['id'] for entry in entries if isinstance(entry.get('body_text'), str)}
                return dict(nodes=[{key: row[key] for key in ('id', 'title', 'notebook_id', 'version', 'tags')} for row in rows],
                            edges=[], failures=[], entries=[_graph_entry(entry) for entry in entries],
                            pending=[row['id'] for row in rows if row['id'] not in indexed])
            return read_nas(request, response, summaries)
        return read_nas(request, response, lambda base, active: _snapshot(nas, base, active))

    @app.get('/api/graph/entries')
    def graph_entries(request: Request, response: Response, ids: str = Query(max_length=8192)):
        from fastapi import HTTPException
        try:
            values = json.loads(ids)
            if not isinstance(values, list) or not 1 <= len(values) <= 8 or any(not isinstance(v, str) or not 1 <= len(v) <= 256 for v in values) or len(set(values)) != len(values):
                raise ValueError()
        except (ValueError, TypeError):
            raise HTTPException(422, detail='INVALID_ID')
        response.headers['Cache-Control'] = 'no-store'
        owner = owner_for_request(request, response) if owner_for_request else None
        result = read_nas(request, response, lambda base, active: _entries(nas, base, active, values))
        if store and owner:
            for entry in result['entries']: store.save_graph_index(owner, entry)
        return {'entries': [_graph_entry(entry) for entry in result['entries']]}


def _resolve(nas, base, active, target: str, *, store=None, owner=None) -> str:
    from fastapi import HTTPException
    identity = _identity(target)
    if identity is None:
        raise HTTPException(422, detail='INVALID_NOTE_LINK')
    kind,value=identity
    rows=[n for n in nas.notes(base,active) if not n.get('locked') and not n.get('trashed')]
    if kind=='remote':
        if any(n['id']==value for n in rows):return value
        raise HTTPException(404,detail='NOTE_LINK_NOT_FOUND')
    if kind == 'title':
        matches = [n['id'] for n in rows if n.get('title') == value]
        if len(matches) > 1: raise HTTPException(409, detail='AMBIGUOUS_NOTE_LINK')
        if matches: return matches[0]
        raise HTTPException(404, detail='NOTE_LINK_NOT_FOUND')
    cached = {entry['id']: entry for entry in store.load_graph_index(owner, {row['id']: row['version'] for row in rows})} if store and owner else {}
    matches=[]
    for row in rows:
        if row['id'] in cached:
            if (cached[row['id']].get('document_id') or '').lower() == value: matches.append(row['id'])
            continue
        with _GRAPH_READS:
            detail=nas.fetch(base,active,row['id'])
        if detail.get('locked') or detail.get('trashed'):continue
        if row.get('version') is not None and detail.get('version')!=row['version']:
            raise NasError('REMOTE_CHANGED')
        if store and owner: store.save_graph_index(owner, entry_from_detail(detail))
        if (detail.get('source_document_id') or '').lower()==value:matches.append(row['id'])
    if len(matches)>1:raise HTTPException(409,detail='AMBIGUOUS_NOTE_LINK')
    if not matches:raise HTTPException(404,detail='NOTE_LINK_NOT_FOUND')
    return matches[0]


def _entries(nas, base, active, ids):
    """Bounded, read-only batches: no full-library request or retained NAS credentials."""
    def read(note_id):
        try:
            with _GRAPH_READS:
                detail = nas.fetch(base, active, note_id)
            return entry_from_detail(detail)
        except NasError as exc:
            if exc.code == 'NAS_SESSION_EXPIRED': raise
            return dict(id=note_id, error=exc.code if exc.code in _READ_ERRORS else 'NAS_API_ERROR')
    with ThreadPoolExecutor(max_workers=4) as pool:
        return {'entries': list(pool.map(read, ids))}


def entry_from_detail(detail):
    note_id = detail['id']
    if detail['locked'] or detail['trashed']:
        return dict(id=note_id, hidden=True)
    links = []
    for link in sorted(_destinations(detail, MarkdownIt('commonmark'))):
        identity = _identity(link)
        if identity: links.append(dict(kind=identity[0], target=identity[1]))
    markdown = detail.get("markdown")
    if isinstance(markdown, str):
        body_text = _search_text(markdown)
    else:
        parser = _BodyText()
        parser.feed(detail["html"])
        parser.close()
        body_text = _search_text("".join(parser.parts))
    return dict(id=note_id, title=detail['title'], notebook_id=detail['notebook_id'],
                version=detail['version'], document_id=detail.get('source_document_id'),
                links=links, body_text=body_text)
