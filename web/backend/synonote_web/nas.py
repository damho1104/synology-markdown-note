"""NAS bootstrap and authentication with DNS-address pinning.

Always connect to a prevalidated resolved IP; preserve the original hostname for
TLS SNI/certificate matching on HTTPS. HTTP is permitted for trusted networks,
but credentials are not encrypted on that connection. CGI paths are fixed.
"""

from __future__ import annotations

import ipaddress
import json
import re
import socket
import ssl
import time
import uuid
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit

import httpx

from .compat.source_envelope import SourceEnvelope
from .compat.markdown import render as render_markdown
from .compat.errors import CLIError
from .html_text import annotate, patch as patch_html_text
from .library_nas import LibraryNasOperations


AUTH = "SYNO.API.Auth"
NOTE = "SYNO.NoteStation.Note"
NOTEBOOK = "SYNO.NoteStation.Notebook"
PATH = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")
HOST = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", re.I)
BASE_PATH = re.compile(r"^/(?:[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*)?$|^$")
PRIVATE_V4 = tuple(ipaddress.ip_network(prefix) for prefix in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))
PRIVATE_V6 = ipaddress.ip_network("fc00::/7")


class NasError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class _SimpleHtmlParser(HTMLParser):
    """Restrict early web editing to plain HTML without opaque note metadata."""

    TAGS = {"p", "br", "div", "span", "h1", "h2", "h3", "h4", "h5", "h6",
            "strong", "b", "em", "i", "u", "s", "ul", "ol", "li",
            "blockquote", "pre", "code", "hr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.safe = True

    def handle_starttag(self, tag, attrs):
        if tag not in self.TAGS or attrs:
            self.safe = False

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag not in self.TAGS:
            self.safe = False

    def handle_comment(self, data):
        self.safe = False

    def handle_decl(self, decl):
        self.safe = False

    def unknown_decl(self, data):
        self.safe = False

    def handle_pi(self, data):
        self.safe = False


def simple_html(html: str) -> bool:
    if not isinstance(html, str) or "\x00" in html:
        return False
    parser = _SimpleHtmlParser()
    try:
        parser.feed(html)
        parser.close()
        return parser.safe
    except ValueError:
        return False


def edit_block_reason(detail: dict) -> str | None:
    if detail["locked"]:
        return "LOCKED"
    if detail["trashed"]:
        return "TRASHED"
    if detail["attachments"]:
        return "ATTACHMENTS"
    if not simple_html(detail["html"]):
        return "COMPLEX_HTML"
    return None


def validate_url(value: str) -> str:
    """Reject ambiguous/unsafe URLs, keeping any explicit reverse-proxy prefix."""
    if not isinstance(value, str) or len(value) > 2048 or value != value.strip():
        raise NasError("INVALID_NAS_URL")
    if any(c in value for c in "?#\\\r\n\t") or any(ord(c) < 33 for c in value):
        raise NasError("INVALID_NAS_URL")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
        path = parsed.path[:-1] if parsed.path.endswith("/") else parsed.path
        if (parsed.scheme not in {"https", "http"} or not hostname or parsed.username is not None
                or parsed.password is not None or not BASE_PATH.fullmatch(path)
                or not HOST.fullmatch(hostname) and not _is_ip(hostname)):
            raise ValueError()
        # No numeric-host aliases, scoped IPv6, percent-encoded hostnames, or dot segments.
        if "%" in hostname or any(p in {".", ".."} for p in parsed.path.split("/")):
            raise ValueError()
        if port is not None and not 1 <= port <= 65535:
            raise ValueError()
        hostname = hostname.lower()
        # Rebuild the authority so all callers use a canonical host and port.
        host_display = f"[{hostname}]" if ":" in hostname else hostname
        authority = host_display + (f":{port}" if port is not None else "")
        return urlunsplit((parsed.scheme, authority, path, "", ""))
    except (ValueError, AttributeError) as exc:
        raise NasError("INVALID_NAS_URL") from exc


def _is_ip(hostname: str) -> bool:
    try:
        ipaddress.ip_address(hostname)
        return True
    except ValueError:
        return False


def _checked_address(raw: str, allow_private: bool) -> str:
    try:
        address = ipaddress.ip_address(raw.split("%", 1)[0])
    except ValueError as exc:
        raise NasError("NAS_ADDRESS_BLOCKED") from exc
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    private_nas = allow_private and (
        isinstance(address, ipaddress.IPv4Address) and any(address in subnet for subnet in PRIVATE_V4)
        or isinstance(address, ipaddress.IPv6Address) and address in PRIVATE_V6
    )
    if address.is_global or private_nas:
        return str(address)
    raise NasError("NAS_ADDRESS_BLOCKED")


class PinnedTransport(httpx.BaseTransport):
    """Resolve and filter on every call, then connect directly to the allowed IP.

    No HTTP(S) proxies are used and HTTP redirects must be rejected by the caller.
    """

    def __init__(self, allow_private: bool, ca_file: str | None = None):
        self.allow_private = allow_private
        context = ssl.create_default_context(cafile=ca_file)
        self.transport = httpx.HTTPTransport(verify=context, trust_env=False, retries=0)

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        host = request.url.host
        if request.url.scheme not in {"https", "http"} or not host:
            raise NasError("NAS_ADDRESS_BLOCKED")
        if request.url.scheme == "http" and not self.allow_private:
            raise NasError("NAS_HTTP_BLOCKED")
        port = request.url.port or (443 if request.url.scheme == "https" else 80)
        try:
            resolved = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except (socket.gaierror, OSError) as exc:
            raise NasError("NAS_UNAVAILABLE") from exc
        addresses = list(dict.fromkeys(row[4][0] for row in resolved))
        if not addresses:
            raise NasError("NAS_UNAVAILABLE")
        # Refuse hosts with mixed safe and unsafe addresses, not just the first answer.
        checked = [_checked_address(ip, self.allow_private) for ip in addresses]
        headers = request.headers.copy()
        headers["host"] = request.url.netloc.decode("ascii")
        extensions = dict(request.extensions)
        if request.url.scheme == "https":
            extensions["sni_hostname"] = host
        pinned = httpx.Request(
            request.method, request.url.copy_with(host=checked[0]),
            headers=headers, content=request.stream,
            extensions=extensions,
        )
        return self.transport.handle_request(pinned)

    def close(self) -> None:
        self.transport.close()


@dataclass(frozen=True)
class NasLogin:
    sid: str
    device_id: str | None


class NasClient(LibraryNasOperations):
    def __init__(self, *, allow_private: bool = False, ca_file: str | None = None):
        self.allow_private = allow_private
        self.ca_file = ca_file

    @staticmethod
    def _data(response: httpx.Response, auth: bool = False, empty: bool = False) -> dict:
        if response.status_code != 200:
            raise NasError("NAS_UNAVAILABLE")
        try:
            payload = response.json()
            if not isinstance(payload, dict) or type(payload.get("success")) is not bool:
                raise ValueError()
            if not payload["success"]:
                error = payload.get("error") or {}
                code = error.get("code") if isinstance(error, dict) else None
                if auth and code == 403:
                    raise NasError("OTP_REQUIRED")
                if auth and code in {400, 401, 402, 404}:
                    raise NasError("AUTH_FAILED")
                if not auth and code in {106, 107, 119}:
                    raise NasError("NAS_SESSION_EXPIRED")
                if code == 1064:
                    raise NasError("REMOTE_CHANGED")
                raise NasError("NAS_API_ERROR")
            data = payload.get("data")
            if empty and data is None:
                return {}
            if not isinstance(data, dict) or data.get("has_fail") is True:
                raise ValueError()
            if any(not isinstance(item, dict) or item.get("success") is False
                   for item in data.get("result", [])):
                raise ValueError()
            return data
        except (ValueError, TypeError, AttributeError) as exc:
            raise NasError("NAS_API_ERROR") from exc

    @staticmethod
    def _post(client: httpx.Client, base: str, path: str, data: dict,
              *, empty: bool = False) -> dict:
        if not PATH.fullmatch(path) or any(p in {".", ".."} for p in path.split("/")):
            raise NasError("NAS_API_ERROR")
        try:
            response = client.post(f"{base}/webapi/{path}", data=data)
            # httpx is not allowed to follow redirects, including same-origin ones.
            if response.is_redirect:
                raise NasError("NAS_UNAVAILABLE")
            return NasClient._data(response, auth=data.get("api") == AUTH, empty=empty)
        except (httpx.HTTPError, OSError) as exc:
            raise NasError("NAS_UNAVAILABLE") from exc

    @staticmethod
    def _discover(client: httpx.Client, base: str, name: str, sid: str | None = None) -> dict:
        return NasClient._post(client, base, "query.cgi", {
            "api": "SYNO.API.Info", "method": "query", "version": "1", "query": name,
            **({"_sid": sid} if sid else {}),
        })

    def _client(self) -> httpx.Client:
        return httpx.Client(
            transport=PinnedTransport(self.allow_private, self.ca_file),
            follow_redirects=False, trust_env=False, timeout=httpx.Timeout(12.0),
        )

    def probe(self, base: str) -> None:
        base = validate_url(base)
        with self._client() as client:
            auth = self._discover(client, base, AUTH).get(AUTH)
            if not isinstance(auth, dict) or not isinstance(auth.get("path"), str):
                raise NasError("NAS_API_ERROR")

    def login(self, base: str, username: str, password: str, otp: str | None,
              trust_device: bool, device_id: str | None = None) -> NasLogin:
        base = validate_url(base)
        with self._client() as client:
            auth = self._discover(client, base, AUTH).get(AUTH)
            if not isinstance(auth, dict):
                raise NasError("NAS_API_ERROR")
            try:
                minimum = int(auth["minVersion"])
                version = min(6, int(auth["maxVersion"]))
                if version < minimum or not isinstance(auth["path"], str):
                    raise ValueError()
            except (ValueError, KeyError, TypeError) as exc:
                raise NasError("NAS_API_ERROR") from exc
            data = {"api": AUTH, "method": "login", "version": str(version),
                    "account": username, "passwd": password,
                    "session": "notestation", "format": "sid"}
            if otp:
                data["otp_code"] = otp
            if trust_device and version >= 6:
                data.update(device_name="Synology Markdown Note Web", enable_device_token="yes")
                if device_id and not otp:
                    data["device_id"] = device_id
            result = self._post(client, base, auth["path"], data)
            sid = result.get("sid")
            if not isinstance(sid, str) or not sid:
                raise NasError("NAS_API_ERROR")
            all_info = self._discover(client, base, "all", sid)
            if NOTE not in all_info:
                raise NasError("NAS_API_ERROR")
            did = result.get("did") or device_id
            if did is not None and not isinstance(did, str):
                raise NasError("NAS_API_ERROR")
            return NasLogin(sid=sid, device_id=did)

    @staticmethod
    def _info(client: httpx.Client, base: str, api: str, cap: int, minimum: int,
              login: NasLogin | None = None) -> tuple[str, int, bool]:
        info = NasClient._discover(client, base, "all", login.sid if login else None).get(api)
        if not isinstance(info, dict):
            raise NasError("NAS_API_ERROR")
        try:
            low, high = info["minVersion"], info["maxVersion"]
            if isinstance(low, bool) or isinstance(high, bool):
                raise ValueError()
            version = min(int(high), cap)
            path = info["path"]
            if (version < max(minimum, int(low)) or not isinstance(path, str)
                    or not PATH.fullmatch(path) or any(v in {".", ".."} for v in path.split("/"))):
                raise ValueError()
        except (ValueError, KeyError, TypeError) as exc:
            raise NasError("NAS_API_ERROR") from exc
        return path, version, str(info.get("requestFormat", "")).upper() == "JSON" or path == "entry.cgi"

    @staticmethod
    def _fields(api: str, method: str, version: int, sid: str, params: dict,
                as_json: bool) -> dict[str, str]:
        fields = {"api": api, "method": method, "version": str(version), "_sid": sid}
        for key, value in params.items():
            fields[key] = (json.dumps(value, separators=(",", ":"), ensure_ascii=False)
                           if as_json or not isinstance(value, str) else value)
        return fields

    @classmethod
    def _call(cls, client: httpx.Client, base: str, login: NasLogin, api: str,
              method: str, cap: int, minimum: int, params: dict | None = None,
              *, empty: bool = False) -> dict:
        path, version, as_json = cls._info(client, base, api, cap, minimum, login)
        return cls._post(client, base, path, cls._fields(
            api, method, version, login.sid, params or {}, as_json), empty=empty)

    @classmethod
    def _list(cls, client: httpx.Client, base: str, login: NasLogin,
              api: str, key: str, cap: int, identity: str = "object_id") -> list[dict]:
        path, version, as_json = cls._info(client, base, api, cap, min(cap, 2), login)
        rows: list[dict] = []
        seen: set[str] = set()
        expected_total: int | None = None
        while True:
            response = cls._post(client, base, path, cls._fields(api, "list", version, login.sid,
                {"offset": len(rows), "limit": 500}, as_json))
            total, offset, page = response.get("total"), response.get("offset"), response.get(key)
            if (type(total) is not int or total < 0 or total > 100000
                    or type(offset) is not int or offset != len(rows) or not isinstance(page, list)
                    or (expected_total is not None and total != expected_total)):
                raise NasError("REMOTE_CHANGED" if expected_total is not None and total != expected_total
                               else "NAS_API_ERROR")
            expected_total = total
            ids = [item.get(identity) for item in page if isinstance(item, dict)]
            if (len(ids) != len(page) or any(not isinstance(v, str) or not v for v in ids)
                    or len(ids) != len(set(ids)) or any(v in seen for v in ids)
                    or not page and len(rows) < total or len(rows) + len(page) > total):
                raise NasError("NAS_API_ERROR")
            rows.extend(page)
            seen.update(ids)
            if len(rows) == total:
                return rows

    @staticmethod
    def _note(row: dict, note_id: str) -> dict:
        if (row.get("object_id", note_id) != note_id
                or not all(isinstance(row.get(k), str) for k in ("title", "content"))
                or not isinstance(row.get("ver"), (str, int))
                or row.get("attachment") is not None and not isinstance(row["attachment"], dict)
                or not isinstance(row.get("parent_id"), str)
                or any(type(row.get(k)) not in (bool, int) or row[k] not in (0, 1)
                       for k in ("encrypt", "recycle"))):
            raise NasError("NAS_API_ERROR")
        attachments = []
        for file_id, value in (row.get("attachment") or {}).items():
            if (not isinstance(file_id, str) or not isinstance(value, dict)
                    or not isinstance(value.get("name"), str)
                    or (value.get("ref") is not None and not isinstance(value["ref"], str))):
                raise NasError("NAS_API_ERROR")
            attachments.append({"id": file_id, "name": value["name"], "ref": value.get("ref")})
        detail = {"id": note_id, "notebook_id": str(row.get("parent_id", "")),
                "title": row["title"], "version": str(row["ver"]), "html": row["content"],
                "attachments": attachments, "locked": bool(row.get("encrypt", False)),
                "trashed": bool(row.get("recycle", False)),
                "created_at": row.get("ctime"), "modified_at": row.get("mtime"),
                "tags": row.get("tag") if isinstance(row.get("tag"), list) else [],
                "excerpt": row.get("brief") if isinstance(row.get("brief"), str) else ""}
        reason = edit_block_reason(detail)
        return {**detail, "editable": reason is None, "read_only_reason": reason}

    @classmethod
    def _fetch(cls, client: httpx.Client, base: str, login: NasLogin, note_id: str) -> dict:
        result = cls._call(client, base, login, NOTE, "get", 3, 2, {"object_id": note_id})
        missing = [k for k in ("parent_id", "encrypt", "recycle") if result.get(k) is None]
        if missing:
            rows = cls._list(client, base, login, NOTE, "notes", 3)
            fallback = next((row for row in rows if row["object_id"] == note_id), None)
            if fallback is None or str(fallback.get("ver")) != str(result.get("ver")):
                raise NasError("REMOTE_CHANGED")
            result = {**result, **{k: fallback.get(k) for k in missing}}
        return cls._note(result, note_id)

    def notebooks(self, base: str, login: NasLogin) -> list[dict]:
        with self._client() as client:
            rows = self._list(client, validate_url(base), login, NOTEBOOK, "notebooks", 2)
        if any(not isinstance(v.get("title"), str) for v in rows):
            raise NasError("NAS_API_ERROR")
        return [{"id": v["object_id"], "name": v["title"],
                 "stack": v.get("stack") if isinstance(v.get("stack"), str) else ""} for v in rows]

    def notes(self, base: str, login: NasLogin) -> list[dict]:
        with self._client() as client:
            rows = self._list(client, validate_url(base), login, NOTE, "notes", 3)
            info = self._discover(client, base, "all", login.sid)
            favorites = set()
            if "SYNO.NoteStation.Shortcut" in info:
                shortcuts = self._list(client, base, login, "SYNO.NoteStation.Shortcut", "shortcuts", 1, "id")
                favorites = {v["id"] for v in shortcuts if v.get("category") == "note"}
            if "SYNO.NoteStation.Tag" in info and any(v.get("tag") is None for v in rows):
                tags = self._list(client, base, login, "SYNO.NoteStation.Tag", "tags", 1, "tag_id")
                for row in rows:
                    if row.get("tag") is None:
                        row["tag"] = [t["title"] for t in tags if row["object_id"] in t.get("items", [])]
        if any(not isinstance(v.get("title"), str) or not isinstance(v.get("ver"), (int, str))
               for v in rows):
            raise NasError("NAS_API_ERROR")
        return [{"id": v["object_id"], "title": v["title"],
                 "notebook_id": str(v.get("parent_id", "")), "version": str(v["ver"]),
                 "locked": bool(v.get("encrypt", False)), "trashed": bool(v.get("recycle", False)),
                 "created_at": v.get("ctime"), "modified_at": v.get("mtime"),
                 "favorite": v["object_id"] in favorites,
                 "tags": v.get("tag") if isinstance(v.get("tag"), list) else [],
                 "excerpt": v.get("brief") if isinstance(v.get("brief"), str) else ""}
                for v in rows]

    def fetch(self, base: str, login: NasLogin, note_id: str) -> dict:
        with self._client() as client:
            detail = self._fetch(client, validate_url(base), login, note_id)
        if detail["locked"]:
            return detail
        candidates = []
        staged_source = False
        for file in detail["attachments"]:
            if not file["name"].endswith(".md"):
                continue
            try:
                source = SourceEnvelope.decode(self.download(base, login, note_id, file["id"]))
            except CLIError:
                continue
            if source.is_staging:
                staged_source = True
            if source.matches(detail["html"]):
                candidates.append((source, file["id"]))
        if len(candidates) == 1:
            source, file_id = candidates[0]
            detail.update(markdown=source.markdown, blocks=source.blocks,
                          source_document_id=source.document_id, source_file_id=file_id,
                          attachment_bindings=source.attachment_bindings)
            # Existing math image bindings require the original app's PNG export.
            detail["editable"] = not detail["trashed"] and not source.math_attachments
            detail["read_only_reason"] = "TRASHED" if detail["trashed"] else "MATH_EXPORT" if source.math_attachments else None
        elif len(candidates) > 1:
            detail.update(editable=False, read_only_reason="AMBIGUOUS_SOURCE")
        elif not detail["trashed"] and not staged_source:
            detail.update(annotate(detail["html"]))
        if staged_source:
            detail.update(editable=False, read_only_reason="WRITE_IN_PROGRESS", write_in_progress=True)
        return detail

    def download(self, base: str, login: NasLogin, note_id: str, file_id: str) -> bytes:
        base = validate_url(base)
        with self._client() as client:
            path, _, as_json = self._info(client, base, NOTE, 1, 1, login)
            fields = self._fields(NOTE, "download", 1, login.sid,
                {"file_id": file_id, "object_id": note_id, "format": "raw", "mode": "download"}, as_json)
            try:
                with client.stream("POST", f"{base}/webapi/{path}", data=fields) as response:
                    if response.status_code != 200 or response.is_redirect:
                        raise NasError("NAS_UNAVAILABLE")
                    raw = bytearray()
                    for chunk in response.iter_bytes():
                        if len(raw) + len(chunk) > 32 * 1024 * 1024:
                            raise NasError("ATTACHMENT_TOO_LARGE")
                        raw.extend(chunk)
            except (httpx.HTTPError, OSError) as exc:
                raise NasError("NAS_UNAVAILABLE") from exc
        # Synology can return an error envelope with a misleading Content-Type.
        try:
            envelope = json.loads(raw)
        except (ValueError, UnicodeError):
            envelope = None
        if isinstance(envelope, dict) and envelope.get("success") is False:
            code = (envelope.get("error") or {}).get("code")
            raise NasError("NAS_SESSION_EXPIRED" if code in {106, 107, 119} else "NAS_API_ERROR")
        return bytes(raw)

    def write(self, base: str, login: NasLogin, *, note_id: str | None,
              notebook_id: str | None, title: str, html: str, version: str | None) -> dict:
        """One remote write per invocation; never retry on a lost receipt."""
        base = validate_url(base)
        with self._client() as client:
            if note_id:
                current = self._fetch(client, base, login, note_id)
                if current["version"] != version:
                    raise NasError("REMOTE_CHANGED")
                if current["locked"] or current["trashed"] or current["notebook_id"] != notebook_id:
                    raise NasError("DOCUMENT_READ_ONLY")
                if edit_block_reason(current) is not None:
                    raise NasError("DOCUMENT_READ_ONLY")
                if not simple_html(html):
                    raise NasError("DOCUMENT_READ_ONLY")
                if current["title"] == title and current["html"] == html:
                    return current
            elif not simple_html(html):
                raise NasError("DOCUMENT_READ_ONLY")
            fields = {"mtime": int(time.time()),
                      "commit_msg": {"device": "web", "listable": False},
                      "title": title, "content": html, "brief": html[:180]}
            if note_id:
                fields.update(object_id=note_id, ver=version, check_conflict=True)
            else:
                if not notebook_id:
                    raise NasError("NAS_API_ERROR")
                fields.update(parent_id=notebook_id, encrypt=False, ctime=int(time.time()),
                              latitude=0, longitude=0)
            # Once a mutation begins, even a transport failure may mean success.
            try:
                receipt = self._call(client, base, login, NOTE,
                                     "set" if note_id else "create", 3, 2, fields)
            except NasError as exc:
                if exc.code in {"NAS_UNAVAILABLE", "NAS_API_ERROR", "NAS_SESSION_EXPIRED"}:
                    raise NasError("WRITE_UNCERTAIN") from exc
                raise
            row = receipt
            if note_id:
                records = receipt.get("data")
                row = records[0] if isinstance(records, list) and len(records) == 1 else None
            if not isinstance(row, dict):
                raise NasError("WRITE_UNCERTAIN")
            returned_id = row.get("object_id") or note_id
            returned_version = row.get("ver")
            if (not isinstance(returned_id, str) or not returned_id or
                    not isinstance(returned_version, str) or note_id and returned_id != note_id):
                raise NasError("WRITE_UNCERTAIN")
            try:
                verified = self._fetch(client, base, login, returned_id)
            except NasError as exc:
                raise NasError("WRITE_UNCERTAIN") from exc
            if (verified["version"] != returned_version or verified["title"] != title
                    or verified["html"] != html or verified["notebook_id"] != notebook_id
                    or verified["locked"] or verified["trashed"]
                    or note_id and verified["attachments"] != current["attachments"]):
                raise NasError("WRITE_UNCERTAIN")
            return verified

    def _mutate_markdown(self, base: str, login: NasLogin, *, note_id: str | None,
                         version: str | None, notebook_id: str, title: str | None = None,
                         html: str | None = None, upload: tuple[str, bytes] | None = None,
                         deleting: list[str] | None = None) -> tuple[str, str]:
        params = {"mtime": int(time.time()), "commit_msg": {"device": "web", "listable": False}}
        if note_id:
            params.update(object_id=note_id, ver=version, check_conflict=True)
        else:
            params.update(parent_id=notebook_id, encrypt=False, ctime=int(time.time()), latitude=0, longitude=0)
        if title is not None:
            params["title"] = title
        if html is not None:
            params.update(content=html, brief=html[:180])
        entries = [{"action": "delete", "file_id": v} for v in deleting or []]
        part = "upload-" + str(uuid.uuid4())
        if upload:
            entries.append({"action": "create", "format": "raw", "name": part, "rotate": False, "convert": False})
        if entries:
            params["attachment"] = entries
        method = "set" if note_id else "create"
        with self._client() as client:
            path, api_version, as_json = self._info(client, base, NOTE, 3, 2, login)
            fields = self._fields(NOTE, method, api_version, login.sid, params, as_json)
            if upload:
                routing = {key: fields.pop(key) for key in ("api", "method", "version", "_sid")}
                try:
                    response = client.post(f"{base}/webapi/{path}", params=routing, data=fields,
                                           files={part: (upload[0], upload[1], "text/markdown")})
                    receipt = self._data(response)
                except (httpx.HTTPError, OSError) as exc:
                    raise NasError("WRITE_UNCERTAIN") from exc
            else:
                receipt = self._post(client, base, path, fields)
        rows = receipt.get("data") if note_id else None
        row = rows[0] if isinstance(rows, list) and len(rows) == 1 else receipt if not note_id else None
        if not isinstance(row, dict) or not isinstance(row.get("ver"), str):
            raise NasError("WRITE_UNCERTAIN")
        returned_id = row.get("object_id") or note_id
        if not isinstance(returned_id, str) or not returned_id or note_id and returned_id != note_id:
            raise NasError("WRITE_UNCERTAIN")
        return returned_id, row["ver"]

    def write_markdown(self, base: str, login: NasLogin, *, note_id: str | None,
                       notebook_id: str, title: str, markdown: str, version: str | None,
                       operation_id: str | None = None) -> dict:
        """Use the same staged source/body/publication contract as the CLI/macOS app."""
        base = validate_url(base)
        old = self.fetch(base, login, note_id) if note_id else None
        if old and old["version"] != version:
            raise NasError("REMOTE_CHANGED")
        if old and (not old["editable"] or old["notebook_id"] != notebook_id or "markdown" not in old):
            raise NasError("DOCUMENT_READ_ONLY")
        previous = (SourceEnvelope.decode(self.download(base, login, note_id, old["source_file_id"]))
                    if old else None)
        if previous and (not previous.matches(old["html"]) or previous.markdown != old["markdown"]):
            raise NasError("REMOTE_CHANGED")
        blocks = previous.blocks if previous else []
        references = set(re.findall(r"attachment://([0-9a-fA-F-]{36})", markdown))
        original_references = set(re.findall(r"attachment://([0-9a-fA-F-]{36})", previous.markdown if previous else ""))
        if not references.issubset(original_references):
            raise NasError("MARKDOWN_UNSUPPORTED")
        try:
            html = render_markdown(markdown, blocks)
            document_id = previous.document_id if previous else str(uuid.uuid4()).upper()
            operation_id = operation_id or str(uuid.uuid4())
            bindings = previous.attachment_bindings if previous else {}
            original = old["html"] if old else "<p>문서를 전송하고 있습니다.</p>"
            stage = SourceEnvelope.make(markdown, original, document_id=document_id,
                operation_id=operation_id, is_staging=True, blocks=blocks, attachment_bindings=bindings).encode()
        except CLIError as exc:
            raise NasError("MARKDOWN_UNSUPPORTED") from exc
        stage_name = f"synology-note-upload-{document_id}-{operation_id}.md"
        protected = {f["id"] for f in old["attachments"] if f["id"] != old["source_file_id"]} if old else set()
        try:
            target, stage_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                notebook_id=notebook_id, title=None if old else title, html=None if old else original,
                upload=(stage_name, stage))
            current = self.fetch(base, login, target)
            if (current["version"] != stage_version or current["html"] != original
                    or current["notebook_id"] != notebook_id or current["title"] != (old["title"] if old else title)):
                raise NasError("WRITE_UNCERTAIN")
            staged = [f for f in current["attachments"] if f["name"] == stage_name
                      and self.download(base, login, target, f["id"]) == stage]
            if len(staged) != 1:
                raise NasError("WRITE_UNCERTAIN")
            _, body_version = self._mutate_markdown(base, login, note_id=target, version=stage_version,
                notebook_id=notebook_id, title=title, html=html)
            current = self.fetch(base, login, target)
            if (current["version"] != body_version or current["html"] != html
                    or current["title"] != title or current["notebook_id"] != notebook_id):
                raise NasError("WRITE_UNCERTAIN")
            final = SourceEnvelope.make(markdown, current["html"], document_id=document_id,
                operation_id=operation_id, blocks=blocks, attachment_bindings=bindings).encode()
            deleting = [staged[0]["id"]] + ([old["source_file_id"]] if old else [])
            _, final_version = self._mutate_markdown(base, login, note_id=target, version=body_version,
                notebook_id=notebook_id, upload=(f"synology-note-source-{document_id}.md", final), deleting=deleting)
            verified = self.fetch(base, login, target)
            ids = {f["id"] for f in verified["attachments"]}
            if (verified["version"] != final_version or verified.get("markdown") != markdown
                    or verified["html"] != html or verified["title"] != title
                    or verified["notebook_id"] != notebook_id or verified.get("blocks") != blocks
                    or not protected.issubset(ids) or any(v in ids for v in deleting)):
                raise NasError("WRITE_UNCERTAIN")
            return verified
        except (NasError, CLIError) as exc:
            # Every failure after staging starts may already have changed the NAS.
            raise NasError("WRITE_UNCERTAIN") from exc


    def write_html_text(self, base: str, login: NasLogin, *, note_id: str, notebook_id: str,
                        title: str, version: str, changes: list[dict]) -> dict:
        current = self.fetch(base, login, note_id)
        if current["version"] != version:
            raise NasError("REMOTE_CHANGED")
        if current["locked"] or current["trashed"] or current["notebook_id"] != notebook_id or "markdown" in current or current.get("write_in_progress") or "html_text_preview" not in current:
            raise NasError("DOCUMENT_READ_ONLY")
        try:
            if any("\x00" in change["text"] for change in changes):
                raise ValueError()
            html = patch_html_text(current["html"], changes)
        except (ValueError, KeyError, TypeError) as exc:
            raise NasError("HTML_PATCH_INVALID") from exc
        if html == current["html"] and title == current["title"]:
            return current
        try:
            _, next_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                notebook_id=notebook_id, title=title, html=html)
            result = self.fetch(base, login, note_id)
            if (result["version"] != next_version or result["html"] != html or result["title"] != title
                    or result["notebook_id"] != notebook_id or result["locked"] or result["trashed"]
                    or sorted(result["attachments"],key=lambda f:f["id"]) != sorted(current["attachments"],key=lambda f:f["id"])):
                raise NasError("WRITE_UNCERTAIN")
            return result
        except NasError as exc:
            raise NasError("WRITE_UNCERTAIN") from exc
