"""Synology Note Station WebAPI: HTTPS, validated discovery and strict pagination."""
from __future__ import annotations

import json
import re
import time
import uuid
from dataclasses import dataclass
from urllib.parse import urlsplit

import httpx

from .errors import CLIError


NOTE = "SYNO.NoteStation.Note"
NOTEBOOK = "SYNO.NoteStation.Notebook"
AUTH = "SYNO.API.Auth"
SAFE_PATH = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")


@dataclass(frozen=True)
class Note:
    id: str
    notebook_id: str
    title: str
    version: str
    html: str
    attachments: list[dict]
    locked: bool = False
    trashed: bool = False


def checked_server(url: str) -> str:
    value = urlsplit(url)
    if value.scheme.lower() != "https" or not value.hostname or value.username or value.password or value.query or value.fragment:
        raise CLIError("INVALID_ARGUMENT", "The server URL must use HTTPS and must not include credentials, a query, or a fragment.")
    return url.rstrip("/")


class NoteStationAPI:
    def __init__(self, server: str, client: httpx.Client | None = None):
        self.server = checked_server(server)
        self.client = client or httpx.Client(timeout=120, follow_redirects=False)
        self.sid: str | None = None
        self.info: dict = {}
        self.device_id: str | None = None

    def close(self) -> None:
        self.client.close()

    def _send(self, api: str, method: str, version: int, path: str, params: dict, *, raw: bool = False,
              upload: list[tuple[str, str, str, bytes]] | None = None) -> httpx.Response:
        if not SAFE_PATH.fullmatch(path) or path in (".", "..") or any(p in (".", "..") for p in path.split("/")):
            raise CLIError("REMOTE_ERROR", "The server returned an invalid API path.")
        fields: dict[str, str] = {"api": api, "method": method, "version": str(version)}
        if self.sid:
            fields["_sid"] = self.sid
        request_format = self.info.get(api, {}).get("requestFormat", "")
        as_json = not raw and (str(request_format).upper() == "JSON" or path == "entry.cgi")
        for key, value in params.items():
            fields[key] = (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                           if as_json or not isinstance(value, str) else value)
        url = self.server + "/webapi/" + path
        try:
            if upload:
                routing = {k: fields.pop(k) for k in ("api", "method", "version", "_sid")}
                files = [(part, (name, data, mime)) for part, name, mime, data in upload]
                result = self.client.post(url, params=routing, data=fields, files=files)
            else:
                result = self.client.post(url, data=fields)
            if result.status_code < 200 or result.status_code >= 300:
                raise CLIError("TRANSPORT_ERROR", f"NAS HTTP status: {result.status_code}")
            return result
        except (httpx.HTTPError, OSError) as ex:
            raise CLIError("TRANSPORT_ERROR", f"Could not connect to the NAS: {type(ex).__name__}") from ex

    @staticmethod
    def _data(response: httpx.Response, *, auth: bool = False, empty: bool = False) -> dict:
        try:
            content = response.json()
            if not isinstance(content, dict) or type(content.get("success")) is not bool:
                raise ValueError()
            if not content["success"]:
                code = content["error"]["code"]
                if code == 403 and auth:
                    raise CLIError("OTP_REQUIRED", "A one-time password is required.")
                if code in (106, 107, 119) and not auth:
                    raise CLIError("AUTH_REQUIRED", "The NAS login session has expired.")
                if code == 1064:
                    raise CLIError("REMOTE_CHANGED", "The NAS document version has changed.")
                if code in (400, 401, 402, 404) and auth:
                    raise CLIError("AUTH_REQUIRED", "NAS authentication failed. Check the one-time password.")
                raise CLIError("REMOTE_ERROR", f"NAS API error code: {code}")
            data = content.get("data")
            if empty and data is None:
                return {}
            if not isinstance(data, dict) or data.get("has_fail") is True:
                raise ValueError()
            for item in data.get("result", []):
                if item.get("success") is False:
                    raise CLIError("REMOTE_ERROR", "One or more requests in the NAS batch failed.")
            return data
        except (ValueError, KeyError, TypeError, AttributeError) as ex:
            raise CLIError("REMOTE_ERROR", "The NAS API response has an invalid format.") from ex

    def _discover(self, query: str) -> dict:
        return self._data(self._send("SYNO.API.Info", "query", 1, "query.cgi", {"query": query}, raw=True))

    def login(self, username: str, password: str, *, otp: str | None = None, remember: bool = True,
              device_id: str | None = None) -> str | None:
        auth = self._discover(AUTH).get(AUTH)
        if not isinstance(auth, dict):
            raise CLIError("REMOTE_ERROR", "The DSM authentication API could not be found.")
        version = min(6, int(auth["maxVersion"]))
        if version < int(auth["minVersion"]):
            raise CLIError("REMOTE_ERROR", "The authentication API version is unsupported.")
        params = {"account": username, "passwd": password, "session": "notestation", "format": "sid"}
        if otp:
            params["otp_code"] = otp
        if remember and version >= 6:
            params.update(device_name="synonote CLI", enable_device_token="yes")
            if device_id and not otp:
                params["device_id"] = device_id
        data = self._data(self._send(AUTH, "login", version, auth["path"], params, raw=True), auth=True)
        sid = data.get("sid")
        if not isinstance(sid, str) or not sid:
            raise CLIError("AUTH_REQUIRED", "The NAS login response did not include a session.")
        self.sid = sid
        self.info = self._discover("all")
        if NOTE not in self.info:
            raise CLIError("REMOTE_ERROR", "The Note Station API is unavailable.")
        self.device_id = data.get("did") or device_id
        return self.device_id

    def _api(self, api: str, method: str, cap: int, minimum: int, params: dict | None = None,
             *, upload: list[tuple[str, str, str, bytes]] | None = None, empty: bool = False) -> dict:
        if not self.sid:
            raise CLIError("AUTH_REQUIRED", "Login is required.")
        info = self.info.get(api)
        if not isinstance(info, dict):
            raise CLIError("REMOTE_ERROR", f"Unsupported NAS API: {api}")
        version = min(int(info["maxVersion"]), cap)
        if version < max(minimum, int(info["minVersion"])):
            raise CLIError("REMOTE_ERROR", f"Unsupported version for NAS API: {api}")
        return self._data(self._send(api, method, version, info["path"], params or {}, upload=upload), empty=empty)

    def _list(self, api: str, key: str, identity: str, cap: int, minimum: int = 1) -> list[dict]:
        rows: list[dict] = []
        seen: set[str] = set()
        total: int | None = None
        while True:
            data = self._api(api, "list", cap, minimum, {"offset": len(rows), "limit": 500})
            if type(data.get("total")) is not int or data["total"] < 0 or type(data.get("offset")) is not int or data["offset"] != len(rows):
                raise CLIError("REMOTE_ERROR", "A page is missing from the NAS list.")
            if total is None:
                total = data["total"]
            elif total != data["total"]:
                raise CLIError("REMOTE_CHANGED", "The NAS list changed while it was being retrieved.")
            page = data.get(key, [])
            if not isinstance(page, list) or any(not isinstance(v, dict) or not isinstance(v.get(identity), str) for v in page):
                raise CLIError("REMOTE_ERROR", "The NAS list contains duplicate or invalid entries.")
            page_ids = [v[identity] for v in page]
            if len(page_ids) != len(set(page_ids)) or any(v in seen for v in page_ids):
                raise CLIError("REMOTE_ERROR", "The NAS list contains duplicate or invalid entries.")
            for v in page:
                seen.add(v[identity])
            rows.extend(page)
            if len(rows) == total:
                return rows
            if not page or len(rows) > total:
                raise CLIError("REMOTE_ERROR", "The NAS list is incomplete.")

    def notebooks(self) -> list[dict]:
        rows = self._list(NOTEBOOK, "notebooks", "object_id", 2, 2)
        return [{"id": v["object_id"], "name": v["title"], "stack": v.get("stack") or ""} for v in rows]

    def create_notebook(self, name: str) -> dict:
        """Create once and verify by ID. A lost receipt must never trigger a retry."""
        if not name or name != name.strip():
            raise CLIError("INVALID_ARGUMENT", "The notebook name is invalid.")
        if any(b["name"] == name for b in self.notebooks()):
            raise CLIError("TITLE_CONFLICT", "A notebook with that name already exists.", notebook=name)
        try:
            result = self._api(NOTEBOOK, "create", 2, 2,
                               {"title": name, "commit_msg": {"device": "desktop"}})
        except CLIError as error:
            if error.code in ("TRANSPORT_ERROR", "WRITE_UNCERTAIN"):
                raise CLIError("WRITE_UNCERTAIN", "It is unclear whether the notebook was created. Check the notebook list.", notebook=name) from error
            raise
        book_id = result.get("object_id")
        if not isinstance(book_id, str) or not book_id:
            raise CLIError("WRITE_UNCERTAIN", "The notebook creation response did not include an ID.", notebook=name)
        matches = [b for b in self.notebooks() if b["id"] == book_id and b["name"] == name]
        if len(matches) != 1:
            raise CLIError("WRITE_UNCERTAIN", "Could not verify the newly created notebook.", notebook=name, notebook_id=book_id)
        return matches[0]

    def move_notebook_to_stack(self, notebook_id: str, stack: str) -> dict:
        """Assign a newly created notebook to a stack, then read back."""
        current = [b for b in self.notebooks() if b["id"] == notebook_id]
        if len(current) != 1:
            raise CLIError("NOT_FOUND", "The target notebook does not exist.", notebook_id=notebook_id)
        if current[0]["stack"] == stack:
            return current[0]
        try:
            self._api(NOTEBOOK, "set", 2, 2,
                      {"object_id": [notebook_id], "stack": stack,
                       "commit_msg": {"device": "desktop"}}, empty=True)
        except CLIError as error:
            if error.code in ("TRANSPORT_ERROR", "WRITE_UNCERTAIN"):
                raise CLIError("WRITE_UNCERTAIN", "It is unclear whether the notebook was moved to the target stack.", notebook_id=notebook_id) from error
            raise
        matches = [b for b in self.notebooks() if b["id"] == notebook_id and b["stack"] == stack]
        if len(matches) != 1:
            raise CLIError("WRITE_UNCERTAIN", "Could not verify the notebook move to the target stack.", notebook_id=notebook_id)
        return matches[0]

    def move_note(self, note: Note, notebook_id: str) -> Note:
        """Change only parent_id with version protection; preserve note identity and contents."""
        if note.locked or note.trashed:
            raise CLIError("UNSUPPORTED_DOCUMENT_TYPE", "Locked or trashed notes cannot be moved.")
        if note.notebook_id == notebook_id:
            return note
        try:
            data = self._api(NOTE, "set", 3, 2, {
                "object_id": note.id, "ver": note.version, "check_conflict": True,
                "parent_id": notebook_id, "mtime": int(time.time()),
                "commit_msg": {"device": "desktop", "listable": False}})
            records = data.get("data")
            if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0].get("ver"), str):
                raise CLIError("WRITE_UNCERTAIN", "Could not verify the version in the move response.")
            receipt_version = records[0]["ver"]
            current = self.fetch(note.id)
            if (current.version != receipt_version or current.id != note.id or
                current.notebook_id != notebook_id or current.title != note.title or
                current.html != note.html or current.attachments != note.attachments or
                current.locked != note.locked or current.trashed != note.trashed):
                raise CLIError("WRITE_UNCERTAIN", "The note state after the move differs from the expected state.")
            return current
        except CLIError as error:
            if error.code == "REMOTE_CHANGED":
                raise
            raise CLIError("WRITE_UNCERTAIN", "It is unclear whether the note was moved. Check the note on the NAS.",
                           note_id=note.id, target_notebook_id=notebook_id) from error

    def notes(self) -> list[dict]:
        rows = self._list(NOTE, "notes", "object_id", 3, 2)
        return [{"id": v["object_id"], "title": v["title"], "notebook_id": v.get("parent_id", ""),
                 "version": str(v["ver"]), "locked": bool(v.get("encrypt", False)),
                 "trashed": bool(v.get("recycle", False))} for v in rows]

    def fetch(self, note_id: str) -> Note:
        row = self._api(NOTE, "get", 3, 2, {"object_id": note_id})
        if row.get("object_id", note_id) != note_id or not isinstance(row.get("attachment", {}), dict):
            raise CLIError("REMOTE_ERROR", "The NAS returned an invalid note response.")
        details = row.get("attachment") or {}
        return Note(note_id, str(row.get("parent_id", "")), str(row["title"]), str(row["ver"]),
                    str(row["content"]), [{"id": k, "name": v["name"], "ref": v.get("ref")}
                                          for k, v in details.items()], bool(row.get("encrypt", False)), bool(row.get("recycle", False)))

    def download(self, file_id: str, note_id: str) -> bytes:
        info = self.info[NOTE]
        version = min(1, int(info["maxVersion"]))
        response = self._send(NOTE, "download", version, info["path"],
                              {"file_id": file_id, "object_id": note_id, "format": "raw", "mode": "download"})
        # A NAS error envelope can arrive with an incorrect content type.
        # Conversely, the user's attachment may itself be JSON.
        try:
            obj = response.json()
        except (ValueError, UnicodeError):
            obj = None
        if isinstance(obj, dict) and obj.get("success") is False:
            raise CLIError("REMOTE_ERROR", "Could not download the attachment from the NAS.")
        return response.content

    def write(self, *, note_id: str | None, notebook_id: str | None = None, title: str | None = None,
              html: str | None = None, version: str | None = None,
              uploads: list[tuple[str, str, bytes]] | None = None, deleting: list[str] | None = None) -> tuple[str, str]:
        params: dict = {"mtime": int(time.time()), "commit_msg": {"device": "desktop", "listable": False}}
        method = "set" if note_id else "create"
        if note_id:
            if version is None:
                raise CLIError("INVALID_ARGUMENT", "Updating a note requires its NAS version.")
            params.update(object_id=note_id, ver=version, check_conflict=True)
        else:
            if not notebook_id or title is None or html is None:
                raise CLIError("INVALID_ARGUMENT", "Creating a note requires a notebook, title, and body.")
            params.update(parent_id=notebook_id, title=title, content=html, encrypt=False, ctime=int(time.time()), latitude=0, longitude=0)
        if title is not None:
            params["title"] = title
        if html is not None:
            params["content"] = html
            params["brief"] = html[:180]
        entries: list[dict] = [{"action": "delete", "file_id": v} for v in (deleting or [])]
        files = []
        for name, mime, data in (uploads or []):
            part = "upload-" + str(uuid.uuid4())
            entries.append({"action": "create", "format": "raw", "name": part, "rotate": False, "convert": False})
            files.append((part, name, mime, data))
        if entries:
            params["attachment"] = entries
        result = self._api(NOTE, method, 3, 2, params, upload=files or None)
        if method == "set":
            rows = result.get("data")
            if not isinstance(rows, list) or len(rows) != 1:
                raise CLIError("WRITE_UNCERTAIN", "The NAS response did not confirm the note update.")
            row = rows[0]
        else:
            row = result
        updated_id = row.get("object_id") or note_id
        if not isinstance(updated_id, str) or not updated_id or (note_id and updated_id != note_id) or not isinstance(row.get("ver"), str):
            raise CLIError("WRITE_UNCERTAIN", "Could not verify the NAS write result.")
        return updated_id, row["ver"]
