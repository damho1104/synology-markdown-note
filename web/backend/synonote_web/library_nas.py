"""One-shot library mutations, using NoteStationClient.swift's NAS contracts.

Compose as ``class NasClient(LibraryNasOperations, ...)``. Preflight is read-only
and may be retried by read_nas. apply_library_action must never be retried: any
exception after entry means WRITE_UNCERTAIN, even a typed NAS rejection.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import time
import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .nas import NasLogin

NOTE = "SYNO.NoteStation.Note"
BOOK = "SYNO.NoteStation.Notebook"
SHORTCUT = "SYNO.NoteStation.Shortcut"
STACK = "SYNO.NoteStation.Stack"
INFO = "SYNO.NoteStation.Info"


class LibraryPreflightError(Exception):
    """A read-only refusal; the caller may release its reservation."""
    def __init__(self, code: str, status_code: int = 409):
        self.code, self.status_code = code, status_code
        super().__init__(code)


@dataclass(frozen=True)
class LibraryPlan:
    base: str
    command: dict
    api: str
    method: str
    routing: tuple[str, int, bool]
    params: dict
    before: dict
    expected: dict


def _require(condition: bool, code: str = "NAS_API_ERROR") -> None:
    from .nas import NasError
    if not condition:
        raise NasError(code)


def _note_invariants(row: dict) -> dict:
    # Note/get also returns derived notebook labels, paths and sync counters.
    # Verify the document and its access metadata, not those location caches.
    fields = {'object_id', 'title', 'content', 'parent_id', 'ver', 'encrypt', 'recycle',
              'tag', 'attachment', 'ctime', 'brief', 'latitude', 'longitude',
              'todo', 'tasks', 'reminder', 'perm', 'archive', 'category',
              'individual_joined', 'location', 'source_url', 'link_id'}
    fields.update(key for key in row if re.search(
        r'share|permission|encrypt|owner|acl|access|public|readonly|read_only', key, re.I))
    return {key: value for key, value in row.items() if key in fields}


class LibraryNasOperations:
    """Mixin requiring NasClient's pinned _client, _call, _list and _fields."""

    def _library_note(self, client, base: str, login: NasLogin, note_id: str) -> dict:
        row = self._call(client, base, login, NOTE, "get", 3, 2, {"object_id": note_id})
        row = deepcopy(row)
        # Note/get can omit list metadata. Only merge a matching-version row.
        missing = [k for k in ("parent_id", "encrypt", "recycle", "tag") if row.get(k) is None]
        if missing:
            rows = self._list(client, base, login, NOTE, "notes", 3)
            match = next((v for v in rows if v["object_id"] == note_id), None)
            _require(match is not None and str(match.get("ver")) == str(row.get("ver")), "REMOTE_CHANGED")
            row.update({k: deepcopy(match.get(k)) for k in missing})
        if row.get("tag") is None:
            tags = self._list(client, base, login, "SYNO.NoteStation.Tag", "tags", 1, "tag_id")
            _require(all(isinstance(t.get("title"), str) and isinstance(t.get("items"), list)
                         and all(isinstance(v, str) for v in t["items"]) for t in tags))
            row["tag"] = [t["title"] for t in tags if note_id in t["items"]]
        self._note(row, note_id)
        _require("attachment" in row and type(row.get("ver")) in (str, int)
                 and bool(str(row["ver"])) and isinstance(row.get("tag"), list)
                 and all(isinstance(v, str) for v in row["tag"]))
        row["object_id"] = note_id
        row["ver"] = str(row["ver"])
        row["attachment"] = row["attachment"] or {}
        return row

    def _library_books(self, client, base: str, login: NasLogin) -> dict[str, dict]:
        rows = self._list(client, base, login, BOOK, "notebooks", 2)
        _require(all(isinstance(v.get("title"), str) and
                     (v.get("stack") is None or isinstance(v["stack"], str)) for v in rows))
        return {v["object_id"]: {"title": v["title"], "stack": v.get("stack") or ""} for v in rows}

    def _library_favorites(self, client, base: str, login: NasLogin) -> set[str]:
        rows = self._list(client, base, login, SHORTCUT, "shortcuts", 1, "id")
        _require(all(isinstance(v.get("category"), str) for v in rows))
        return {v["id"] for v in rows if v["category"] == "note"}

    def preflight_library_action(self, base: str, login: NasLogin, command: dict) -> LibraryPlan:
        """Read and prepare an already validated library_api.LibraryActionInput.

        All discovery is completed here, before the mutation boundary. Plans are
        request-local, contain no SID, and are never persisted or browser-visible.
        """
        from .nas import validate_url
        base = validate_url(base)
        command = deepcopy(command)
        kind, action = command["kind"], command["action"]
        object_id, name, value = command.get("id"), command.get("name"), command.get("value")
        with self._client() as client:
            if kind == "note":
                # fetch inspects SourceEnvelope staging attachments. Raw Note/get
                # alone cannot detect an interrupted Markdown two-phase write.
                detail = self.fetch(base, login, object_id)
                _require(not detail.get("write_in_progress")
                         and detail.get("read_only_reason") != "WRITE_IN_PROGRESS", "DOCUMENT_READ_ONLY")
                before = self._library_note(client, base, login, object_id)
                _require(before["ver"] == command["version"] == detail["version"], "REMOTE_CHANGED")
                _require(not before["encrypt"], "DOCUMENT_READ_ONLY")
                _require(bool(before["recycle"]) == (action == "restore"), "DOCUMENT_READ_ONLY")
                if action == "move":
                    books = self._library_books(client, base, login)
                    if value not in books:
                        raise LibraryPreflightError("NOTEBOOK_NOT_FOUND", 404)
                expected = deepcopy(before)
                params = {"object_id": object_id}
                if action == "favorite":
                    # Shortcut v1 has no ver/check_conflict contract. Require a
                    # matching note version before AND after the shortcut write.
                    self._library_favorites(client, base, login)
                    api, method, cap, minimum = SHORTCUT, "set" if value else "delete", 1, 1
                elif action in {'trash', 'restore'}:
                    # Official Note Station notestation.js: v3 delete with
                    # recycle=true is soft trash; restore is a separate method.
                    # Neither method exposes ver/check_conflict. Preflight and
                    # invariant readback guard the one-shot request instead.
                    api, method, cap, minimum = NOTE, 'delete' if action == 'trash' else 'restore', 3, 3
                    if action == 'trash': params['recycle'] = True
                    expected['recycle'] = action == 'trash'
                else:
                    api, method, cap, minimum = NOTE, "set", 3, 2
                    field, new_value = {"tags": ("tag", value), "move": ("parent_id", value)}[action]
                    params.update(ver=command["version"], check_conflict=True,
                                  mtime=int(time.time()), commit_msg={"device": "web", "listable": False})
                    params[field] = new_value
                    expected[field] = deepcopy(new_value)
            else:
                before = self._library_books(client, base, login)
                expected = deepcopy(before)
                api, method, cap, minimum = BOOK, "set", 2, 2
                params = {"commit_msg": {"device": "web"}}
                if kind == "notebook" and action == "create":
                    if any(v["title"] == name for v in before.values()):
                        raise LibraryPreflightError("DUPLICATE_NOTEBOOK_NAME")
                    if value and not any(v["stack"] == value for v in before.values()):
                        raise LibraryPreflightError("STACK_NOT_FOUND", 404)
                    method = "create"
                    params["title"] = name
                elif kind == "notebook":
                    if object_id not in before:
                        raise LibraryPreflightError("NOTEBOOK_NOT_FOUND", 404)
                    if action == "rename":
                        if any(k != object_id and v["title"] == name for k, v in before.items()):
                            raise LibraryPreflightError("DUPLICATE_NOTEBOOK_NAME")
                        params.update(object_id=object_id, title=name)
                        expected[object_id]["title"] = name
                    else:
                        if value and not any(v["stack"] == value for v in before.values()):
                            raise LibraryPreflightError("STACK_NOT_FOUND", 404)
                        params.update(object_id=[object_id], stack=value)
                        expected[object_id]["stack"] = value
                elif action == "create":
                    if any(v["stack"] == name for v in before.values()):
                        raise LibraryPreflightError("DUPLICATE_STACK_NAME")
                    if any(v not in before for v in value):
                        raise LibraryPreflightError("NOTEBOOK_NOT_FOUND", 404)
                    params.update(object_id=value, stack=name)
                    for member in value:
                        expected[member]["stack"] = name
                else:
                    members = [k for k, v in before.items() if v["stack"] == object_id]
                    if not members:
                        raise LibraryPreflightError("STACK_NOT_FOUND", 404)
                    if name != object_id and any(v["stack"] == name for v in before.values()):
                        raise LibraryPreflightError("DUPLICATE_STACK_NAME")
                    info = self._call(client, base, login, INFO, "get", 2, 2)
                    uid = info.get("uid")
                    _require(type(uid) in (int, str) and bool(str(uid)))
                    api, cap, minimum = STACK, 1, 1
                    params = {"stack_id": f"{object_id}#{uid}", "name": name}
                    for member in members:
                        expected[member]["stack"] = name
            routing = self._info(client, base, api, cap, minimum, login)
        return LibraryPlan(base, command, api, method, routing, params, before, expected)

    def _library_send(self, client, base: str, login: NasLogin, plan: LibraryPlan,
                      method: str, params: dict, *, empty: bool = True) -> dict:
        path, version, as_json = plan.routing
        return self._post(client, base, path, self._fields(
            plan.api, method, version, login.sid, params, as_json), empty=empty)

    def _verify_library_note(self, client, base, login, plan, version):
        from .nas import NasError
        for attempt, delay in enumerate((0, 0.05, 0.15)):
            if delay: time.sleep(delay)
            try:
                actual = self._library_note(client, base, login, plan.command['id'])
            except NasError as exc:
                if exc.code not in {'REMOTE_CHANGED', 'NAS_UNAVAILABLE'} or attempt == 2:
                    raise
                continue
            expected = deepcopy(plan.expected)
            action = plan.command['action']
            if action == 'trash' and actual['parent_id'] != expected['parent_id']:
                # Live NAS moves the note into a system recycle notebook and
                # records its real notebook separately. Never accept a lost or
                # substituted origin merely because recycle became true.
                if actual.get('old_parent_id') != plan.before['parent_id']:
                    continue
                expected['parent_id'] = actual['parent_id']
            if action == 'restore' and plan.before.get('old_parent_id'):
                origin = plan.before['old_parent_id']
                expected['parent_id'] = origin
                if actual['parent_id'] != origin:
                    books = self._library_books(client, base, login)
                    # Note Station restores into an existing notebook when the
                    # original notebook was removed. Otherwise require origin.
                    if origin not in books and actual['parent_id'] in books:
                        expected['parent_id'] = actual['parent_id']
            # A successful but sparse mutation response is only a receipt of
            # acceptance. Every intended field and invariant must be read back;
            # a lost/rejected response never reaches this reader. NAS metadata
            # changes (verified live for move) need not change content version.
            if plan.api == NOTE:
                if version is not None and actual['ver'] != version:
                    if actual['ver'] == plan.before['ver']: continue
                    break
                expected['ver'] = actual['ver']
            if _note_invariants(actual) == _note_invariants(expected):
                return
        _require(False)

    def apply_library_action(self, base: str, login: NasLogin, plan: LibraryPlan) -> None:
        """Mutation boundary: send once, verify by reads, never replay/relogin."""
        from .nas import NasError
        try:
            _require(base == plan.base)
            with self._client() as client:
                receipt = self._library_send(client, base, login, plan, plan.method, plan.params)
                command = plan.command
                if command["kind"] == "note":
                    note_id = command["id"]
                    version = None
                    if plan.api == NOTE:
                        row = receipt
                        if 'data' in receipt:
                            rows = receipt['data']
                            _require(isinstance(rows, list) and len(rows) <= 1)
                            row = rows[0] if rows else {}
                        _require(isinstance(row, dict) and row.get('object_id', note_id) == note_id)
                        if 'ver' in row:
                            _require(type(row['ver']) in (str, int) and bool(str(row['ver'])))
                            version = str(row['ver'])
                    self._verify_library_note(client, base, login, plan, version)
                    if plan.api == SHORTCUT:
                        favorites = self._library_favorites(client, base, login)
                        _require((note_id in favorites) == command["value"])
                else:
                    expected = deepcopy(plan.expected)
                    if command["kind"] == "notebook" and command["action"] == "create":
                        created = receipt.get("object_id")
                        _require(isinstance(created, str) and bool(created) and created not in plan.before)
                        expected[created] = {"title": command["name"], "stack": ""}
                        _require(self._library_books(client, base, login) == expected)
                        if command.get("value"):
                            # The documented create has no stack parameter. A
                            # lost create receipt never reaches this second write.
                            self._library_send(client, base, login, plan, "set", {
                                "object_id": [created], "stack": command["value"],
                                "commit_msg": {"device": "web"}})
                            expected[created]["stack"] = command["value"]
                    elif plan.api == BOOK and "object_id" in receipt:
                        wanted = plan.params["object_id"]
                        wanted = wanted if isinstance(wanted, list) else [wanted]
                        _require(receipt["object_id"] in wanted)
                    _require(self._library_books(client, base, login) == expected)
        except Exception as exc:
            raise NasError("WRITE_UNCERTAIN") from exc
