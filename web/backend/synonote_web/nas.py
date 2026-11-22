"""NAS bootstrap and authentication with DNS-address pinning.

Always connect to a prevalidated resolved IP; preserve the original hostname for
TLS SNI/certificate matching on HTTPS. HTTP is permitted for trusted networks,
but credentials are not encrypted on that connection. CGI paths are fixed.
"""

from __future__ import annotations

import ipaddress
import base64
import hashlib
import struct
import json
import logging
from datetime import datetime, timezone
from functools import cache
import re
import socket
import ssl
import time
import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit, urlencode

import httpx

from .compat.source_envelope import SourceEnvelope
from .compat.markdown import render as render_markdown, math_plan
from .compat.errors import CLIError
from .html_text import annotate, layout_identity, patch as patch_html_text
from .html_structure import apply_structure
from .attachment_html import bind_html, references_file
from .library_nas import LibraryNasOperations
from .observability import request_id


AUTH = "SYNO.API.Auth"
NOTE = "SYNO.NoteStation.Note"
NOTE_VERSION = "SYNO.NoteStation.Note.Version"
NOTEBOOK = "SYNO.NoteStation.Notebook"
SOURCE_DOWNLOAD_LIMIT = 32 * 1024 * 1024
STAGING_SOURCE_PREFIX = "synology-note-upload-"
ATTACHMENT_PREFIX = "synology-note-attachment-"
DOWNLOAD_ONLY_PREFIX = ATTACHMENT_PREFIX + "file-"
IMAGE_MIMES = {"image/png", "image/jpeg", "image/gif", "image/webp"}
PATH = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$")
HOST = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", re.I)
BASE_PATH = re.compile(r"^/(?:[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*)?$|^$")
PRIVATE_V4 = tuple(ipaddress.ip_network(prefix) for prefix in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))
PRIVATE_V6 = ipaddress.ip_network("fc00::/7")


class NasError(Exception):
    def __init__(self, code: str, *, diagnostic: dict | None = None):
        self.code = code
        self.diagnostic = {}
        for key, value in (diagnostic or {}).items():
            if key in {"nas_code", "http_status"} and type(value) is int:
                self.diagnostic[key] = value
            elif key in {"api", "method", "reason", "transport"} and isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.]{1,100}", value):
                self.diagnostic[key] = value
        super().__init__(code)


class NasPreflightError(NasError):
    """An NAS failure raised before any mutation was attempted."""


class _AttachmentReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags: dict[str, set[str]] = {}

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if not value or name not in {"href", "src", "data", "poster", "action", "formaction",
                                         "xlink:href", "srcset", "imagesrcset"}:
                continue
            url = value.strip().lower()
            if not url.startswith("attachment:") and not (
                    name in {"srcset", "imagesrcset"} and "attachment:" in url):
                continue
            if (tag, name) not in {("a", "href"), ("img", "src")} or not value.lower().startswith("attachment://"):
                raise ValueError("Unsupported attachment reference")
            if sum(key == name for key, _ in attrs) != 1:
                raise ValueError("Ambiguous attachment reference")
            uid = str(uuid.UUID(value[len("attachment://"):]))
            self.tags.setdefault(uid, set()).add(tag)

    handle_startendtag = handle_starttag


def _verified_upload_chunks(upload: dict) -> Iterator[bytes]:
    digest = hashlib.sha256()
    size = 0
    try:
        for chunk in upload["chunks"]():
            if not isinstance(chunk, bytes):
                raise ValueError("Invalid upload chunk")
            size += len(chunk)
            if size > upload["size"]:
                raise ValueError("Upload exceeds declared size")
            digest.update(chunk)
            if chunk:
                yield chunk
        if size != upload["size"] or digest.hexdigest() != upload["sha256"]:
            raise ValueError("Upload differs from manifest")
    except Exception as exc:
        # The chunks callback belongs to the staging store and may raise its own errors.
        raise NasError("MARKDOWN_UNSUPPORTED", diagnostic={"reason": "UPLOAD_CONTENT_INVALID"}) from exc


def _attachment_filename(operation_id: str, uid: str, name: str, image: bool) -> str:
    prefix = ATTACHMENT_PREFIX + "image-" if image else DOWNLOAD_ONLY_PREFIX
    prefix += f"{uuid.UUID(operation_id).hex}-{uuid.UUID(uid).hex}-"
    name = name.replace('"', "%22")
    stem, dot, extension = name.rpartition(".")
    suffix = (dot + extension).encode() if stem else b""
    if not 1 < len(suffix) <= 24:
        stem, suffix = name, b""
    budget = 255 - len(prefix) - len(suffix)
    return prefix + (stem.encode()[:budget].decode("utf-8", errors="ignore") + suffix.decode())


def _multipart_upload(fields: dict, part: str, upload: dict) -> tuple[dict, Iterator[bytes]]:
    boundary = uuid.uuid4().hex
    prefix = b"".join(
        f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
        for key, value in fields.items()
    )
    prefix += (f'--{boundary}\r\nContent-Disposition: form-data; name="{part}"; filename="{upload["filename"]}"\r\n'
               f'Content-Type: {upload["mime"]}\r\n\r\n').encode()
    suffix = f"\r\n--{boundary}--\r\n".encode()

    def body():
        yield prefix
        yield from _verified_upload_chunks(upload)
        yield suffix

    return {"Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(prefix) + upload["size"] + len(suffix))}, body()


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
    api_info: dict | None = None


class NasClient(LibraryNasOperations):
    def __init__(self, *, allow_private: bool = False, ca_file: str | None = None):
        self.allow_private = allow_private
        self.ca_file = ca_file

    @staticmethod
    def _data(response: httpx.Response, auth: bool = False, empty: bool = False) -> dict:
        if response.status_code != 200:
            raise NasError("NAS_UNAVAILABLE", diagnostic={"reason": "HTTP_ERROR", "http_status": response.status_code})

        def rejected(error):
            code = error.get("code") if isinstance(error, dict) else None
            result = ("OTP_REQUIRED" if auth and code == 403 else
                      "AUTH_FAILED" if auth and code in {400, 401, 402, 404} else
                      "NAS_SESSION_EXPIRED" if not auth and code in {106, 107, 119} else
                      "REMOTE_CHANGED" if code == 1064 else "NAS_API_ERROR")
            raise NasError(result, diagnostic={"reason": "API_REJECTED", "nas_code": code})

        try:
            payload = response.json()
            if not isinstance(payload, dict) or type(payload.get("success")) is not bool:
                raise ValueError()
            if not payload["success"]:
                rejected(payload.get("error"))
            data = payload.get("data")
            if empty and data is None:
                return {}
            if not isinstance(data, dict):
                raise ValueError()
            results = data.get("result", [])
            if not isinstance(results, list):
                raise ValueError()
            for item in results:
                if not isinstance(item, dict):
                    raise ValueError()
                if item.get("success") is False:
                    rejected(item.get("error"))
            if data.get("has_fail") is True:
                raise ValueError()
            return data
        except (ValueError, TypeError, AttributeError) as exc:
            raise NasError("NAS_API_ERROR", diagnostic={"reason": "INVALID_RESPONSE"}) from exc

    @staticmethod
    def _post(client: httpx.Client, base: str, path: str, data: dict,
              *, empty: bool = False) -> dict:
        if not PATH.fullmatch(path) or any(p in {".", ".."} for p in path.split("/")):
            raise NasError("NAS_API_ERROR", diagnostic={"reason": "INVALID_API_PATH"})
        started = time.monotonic()
        diagnostic = {"api": data.get("api"), "method": data.get("method")}
        outcome = "ok"
        failure = {}
        try:
            response = client.post(f"{base}/webapi/{path}", data=data)
            if response.is_redirect:
                raise NasError("NAS_UNAVAILABLE", diagnostic={"reason": "HTTP_REDIRECT", "http_status": response.status_code})
            return NasClient._data(response, auth=data.get("api") == AUTH, empty=empty)
        except NasError as exc:
            exc.diagnostic.update(NasError(exc.code, diagnostic=diagnostic).diagnostic)
            outcome = exc.code
            failure = exc.diagnostic
            raise
        except (httpx.HTTPError, OSError) as exc:
            outcome = "NAS_UNAVAILABLE"
            error = NasError(outcome, diagnostic={**diagnostic, "reason": "TRANSPORT_ERROR", "transport": type(exc).__name__})
            failure = error.diagnostic
            raise error from exc
        finally:
            logging.getLogger("uvicorn.error").info(json.dumps({"event": "nas_request_completed", "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), "request_id": request_id.get(),
                **NasError("", diagnostic=diagnostic).diagnostic,
                "outcome": outcome, "diagnostic": failure, "duration_ms": round((time.monotonic() - started) * 1000, 1)}, separators=(",", ":")))

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
            return NasLogin(sid=sid, device_id=did, api_info=all_info)

    @staticmethod
    def _info(client: httpx.Client, base: str, api: str, cap: int, minimum: int,
              login: NasLogin | None = None) -> tuple[str, int, bool]:
        discovered = login.api_info if login and login.api_info is not None else NasClient._discover(client, base, "all", login.sid if login else None)
        info = discovered.get(api)
        if not isinstance(info, dict):
            raise NasError("NAS_API_ERROR", diagnostic={"api": api, "reason": "API_NOT_ADVERTISED"})
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
            raise NasError("NAS_API_ERROR", diagnostic={"api": api, "reason": "INVALID_API_METADATA"}) from exc
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
              api: str, key: str, cap: int, identity: str = "object_id", *,
              params: dict | None = None) -> list[dict]:
        path, version, as_json = cls._info(client, base, api, cap, min(cap, 2), login)
        rows: list[dict] = []
        seen: set[str] = set()
        expected_total: int | None = None
        while True:
            response = cls._post(client, base, path, cls._fields(api, "list", version, login.sid,
                {**(params or {}), "offset": len(rows), "limit": 500}, as_json))
            total, offset, page = response.get("total"), response.get("offset"), response.get(key)
            # Note Station can omit the array entirely for an empty first page.
            # Explicit nulls and incomplete/nonempty pages must still be rejected.
            if key not in response and total == 0 and offset == 0:
                page = []
            if (type(total) is not int or total < 0 or total > 100000
                    or type(offset) is not int or offset != len(rows) or not isinstance(page, list)
                    or (expected_total is not None and total != expected_total)):
                raise NasError("REMOTE_CHANGED" if expected_total is not None and total != expected_total
                               else "NAS_API_ERROR", diagnostic={"api": api, "method": "list", "reason": "INVALID_LIST_PAGE"})
            expected_total = total
            ids = [item.get(identity) for item in page if isinstance(item, dict)]
            if (len(ids) != len(page) or any(not isinstance(v, str) or not v for v in ids)
                    or len(ids) != len(set(ids)) or any(v in seen for v in ids)
                    or not page and len(rows) < total or len(rows) + len(page) > total):
                raise NasError("NAS_API_ERROR", diagnostic={"api": api, "method": "list", "reason": "INVALID_LIST_IDENTITIES"})
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
            if not file["name"].endswith(".md") or file["name"].startswith(ATTACHMENT_PREFIX):
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
                          attachment_bindings=source.attachment_bindings, math_attachments=source.math_attachments)
            # Existing math image bindings require the original app's PNG export.
            detail["editable"] = not detail["trashed"]
            detail["read_only_reason"] = "TRASHED" if detail["trashed"] else None
        elif len(candidates) > 1:
            detail.update(editable=False, read_only_reason="AMBIGUOUS_SOURCE")
        elif not detail["trashed"] and not staged_source:
            detail.update(annotate(detail["html"]))
        if staged_source:
            detail.update(editable=False, read_only_reason="WRITE_IN_PROGRESS", write_in_progress=True)
        return detail

    def _version_history(self, client, base: str, login: NasLogin, note_id: str) -> list[dict]:
        rows = self._list(client, base, login, NOTE_VERSION, "versions", 2, "version",
                          params={"object_id": note_id, "filter": {"listable": True}})
        if any(type(row.get("mtime")) not in (int, float) or not 0 <= row["mtime"] <= 253402300799 for row in rows):
            raise NasError("NAS_API_ERROR")
        return [{"version": row["version"], "modified_at": row["mtime"]} for row in rows]

    def _historical_note(self, client, base: str, login: NasLogin, current: dict, version: str) -> dict:
        note_id = current["id"]
        if not any(revision["version"] == version for revision in self._version_history(client, base, login, note_id)):
            raise NasError("REVISION_NOT_FOUND")
        raw = self._call(client, base, login, NOTE, "get", 3, 3, {"object_id": note_id, "ver": version})
        if str(raw.get("ver")) != version:
            raise NasError("NAS_API_ERROR")
        row = {"parent_id": current["notebook_id"], "encrypt":current["locked"], "recycle":current["trashed"], **raw}
        historical = self._note(row, note_id)
        if historical["locked"] or historical["trashed"] or any(
                entry["name"].lower().startswith(STAGING_SOURCE_PREFIX) for entry in historical["attachments"]):
            raise NasError("DOCUMENT_READ_ONLY")
        return historical

    def note_revisions(self, base: str, login: NasLogin, note_id: str, version: str | None = None) -> dict:
        base = validate_url(base)
        with self._client() as client:
            current = self._fetch(client, base, login, note_id)
            if current["locked"] or current["trashed"]:
                raise NasError("DOCUMENT_READ_ONLY")
            if version is None:
                return {"revisions": self._version_history(client, base, login, note_id)}
            historical = self._historical_note(client, base, login, current, version)
            return {key: historical[key] for key in ("version", "title", "html")}

    def restore_revision(self, base: str, login: NasLogin, *, note_id: str, notebook_id: str,
                         version: str, restore_version: str) -> dict:
        try:
            base = validate_url(base)
            current = self.fetch(base, login, note_id)
            if current["version"] != version:
                raise NasError("REMOTE_CHANGED")
            if (current["locked"] or current["trashed"] or current["notebook_id"] != notebook_id
                    or current.get("write_in_progress") or current.get("read_only_reason") == "AMBIGUOUS_SOURCE"):
                raise NasError("DOCUMENT_READ_ONLY")
            if version == restore_version:
                raise NasError("REVISION_NOT_FOUND")
            with self._client() as client:
                historical = self._historical_note(client, base, login, current, restore_version)
                routing = self._info(client, base, NOTE, 3, 2, login)
            files = {entry["id"]: entry for entry in current["attachments"]}
            sources = []
            for entry in historical["attachments"]:
                file_id = entry["id"]
                if entry["name"].lower().endswith(".md") and not entry["name"].startswith(ATTACHMENT_PREFIX):
                    try:
                        data = self.download(base, login, note_id, file_id)
                        envelope = SourceEnvelope.decode(data)
                    except CLIError:
                        pass
                    except NasError as exc:
                        if file_id not in files and exc.code == "NAS_API_ERROR":
                            raise NasError("REVISION_ATTACHMENTS_UNAVAILABLE") from exc
                        raise
                    else:
                        if envelope.matches(historical["html"]) and not envelope.is_staging:
                            sources.append((entry, envelope, data))
                            continue
                if files.get(file_id) != entry:
                    raise NasError("REVISION_ATTACHMENTS_UNAVAILABLE")
            if len(sources) > 1:
                raise NasError("REVISION_ATTACHMENTS_UNAVAILABLE")
            source_file, envelope, data = sources[0] if sources else (None, None, None)
            source_id = source_file["id"] if source_file else None
            current_source_id = current.get("source_file_id")
            deleting = [current_source_id] if current_source_id and source_id != current_source_id else []
            expected = {key: entry for key, entry in files.items() if key not in deleting}
            if envelope and not set(envelope.attachment_bindings.values()).issubset(expected):
                raise NasError("REVISION_ATTACHMENTS_UNAVAILABLE")
            if source_file and source_id in files and files[source_id] != source_file:
                raise NasError("REVISION_ATTACHMENTS_UNAVAILABLE")
            upload = (source_file["name"], data) if source_file and source_id not in files else None
        except NasError as exc:
            raise NasPreflightError(exc.code, diagnostic=exc.diagnostic) from exc

        # Note.Version/restore accepts the historical version only. Applying
        # the snapshot via Note/set lets the NAS compare the current version
        # atomically with the write, including edits from other clients.
        try:
            _, next_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                notebook_id=notebook_id, title=historical["title"], html=historical["html"],
                deleting=deleting, upload=upload, listable=True, routing=routing)
        except NasError as exc:
            if exc.code != "REMOTE_CHANGED":
                raise NasError("WRITE_UNCERTAIN") from exc
            raise
        try:
            restored = self.fetch(base, login, note_id)
            actual = {entry["id"]: entry for entry in restored["attachments"]}
            if upload:
                added = self._new_attachment(set(expected), restored, upload[0])
                source_id = added["id"]
                if (source_id in files or self.download(base, login, note_id, source_id) != data):
                    raise NasError("WRITE_UNCERTAIN")
                del actual[source_id]
            if (restored["version"] != next_version or restored["version"] == version
                    or restored["locked"] or restored["trashed"] or restored.get("write_in_progress")
                    or restored["notebook_id"] != notebook_id or actual != expected
                    or restored["html"] != historical["html"] or restored["title"] != historical["title"]
                    or restored.get("source_file_id") != source_id
                    or envelope and restored.get("markdown") != envelope.markdown):
                raise NasError("WRITE_UNCERTAIN")
            return restored
        except NasError as exc:
            raise NasError("WRITE_UNCERTAIN") from exc

    def iter_download(self, base: str, login: NasLogin, note_id: str, file_id: str,
                      *, max_size: int = 50_000_000) -> Iterator[bytes]:
        """Yield NAS attachment bytes and close the connection on completion or close()."""
        base = validate_url(base)
        with self._client() as client:
            path, _, as_json = self._info(client, base, NOTE, 1, 1, login)
            fields = self._fields(NOTE, "download", 1, login.sid,
                {"file_id": file_id, "object_id": note_id, "format": "raw", "mode": "download"}, as_json)
            try:
                with client.stream("POST", f"{base}/webapi/{path}", data=fields,
                                   headers={"Accept-Encoding": "identity"}) as response:
                    if response.status_code != 200 or response.is_redirect:
                        raise NasError("NAS_UNAVAILABLE")
                    if response.headers.get("content-encoding", "identity").lower() != "identity":
                        raise NasError("NAS_API_ERROR")
                    declared = response.headers.get("content-length")
                    if declared and declared.isascii() and declared.isdecimal() and int(declared) > max_size:
                        raise NasError("ATTACHMENT_TOO_LARGE")
                    # Known NAS error envelopes are small, even with a misleading Content-Type.
                    probe = bytearray() if "content-disposition" not in response.headers else None
                    total = 0
                    for chunk in response.iter_bytes(chunk_size=64 * 1024):
                        total += len(chunk)
                        if total > max_size:
                            raise NasError("ATTACHMENT_TOO_LARGE")
                        if probe is not None:
                            if len(probe) + len(chunk) <= 4096:
                                probe.extend(chunk)
                                continue
                            if probe:
                                yield bytes(probe)
                            probe = None
                        yield chunk
                    if probe:
                        try:
                            envelope = json.loads(probe)
                        except (ValueError, UnicodeError, RecursionError):
                            envelope = None
                        if (isinstance(envelope, dict) and envelope.get("success") is False
                                and isinstance(envelope.get("error"), dict)):
                            code = envelope["error"].get("code")
                            raise NasError("NAS_SESSION_EXPIRED" if code in (106, 107, 119) else "NAS_API_ERROR")
                        yield bytes(probe)
            except (httpx.HTTPError, OSError) as exc:
                raise NasError("NAS_UNAVAILABLE") from exc

    def download(self, base: str, login: NasLogin, note_id: str, file_id: str) -> bytes:
        return b"".join(self.iter_download(base, login, note_id, file_id, max_size=SOURCE_DOWNLOAD_LIMIT))

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
                      "commit_msg": {"device": "web", "listable": True},
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
                         streamed_upload: dict | None = None,
                         deleting: list[str] | None = None, listable: bool = False,
                         routing: tuple[str, int, bool] | None = None) -> tuple[str, str]:
        params = {"mtime": int(time.time()), "commit_msg": {"device": "web", "listable": listable}}
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
        if upload or streamed_upload is not None:
            entries.append({"action": "create", "format": "raw", "name": part, "rotate": False, "convert": False})
            if streamed_upload is not None and streamed_upload["image"]:
                entries[-1]["ref"] = streamed_upload["upload_id"]
        if entries:
            params["attachment"] = entries
        method = "set" if note_id else "create"
        with self._client() as client:
            path, api_version, as_json = routing or self._info(client, base, NOTE, 3, 2, login)
            fields = self._fields(NOTE, method, api_version, login.sid, params, as_json)
            if upload or streamed_upload is not None:
                routing = {key: fields.pop(key) for key in ("api", "method", "version", "_sid")}
                try:
                    if streamed_upload is not None:
                        headers, body = _multipart_upload(fields, part, streamed_upload)
                        response = client.post(f"{base}/webapi/{path}", params=routing, headers=headers, content=body)
                    else:
                        response = client.post(f"{base}/webapi/{path}", params=routing, data=fields,
                                               files={part: (upload[0], upload[1], "image/png" if upload[0].endswith(".png") else "text/markdown")})
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

    @staticmethod
    def _new_attachment(before: set[str], detail: dict, name: str) -> dict:
        after = {file["id"]: file for file in detail["attachments"]}
        added = after.keys() - before
        if not before.issubset(after) or len(added) != 1:
            raise NasError("WRITE_UNCERTAIN")
        file = after[added.pop()]
        if not file["id"] or file["name"] != name:
            raise NasError("WRITE_UNCERTAIN")
        return file

    def _verify_upload(self, base: str, login: NasLogin, note_id: str, file_id: str, upload: dict) -> None:
        size = 0
        digest = hashlib.sha256()
        for chunk in self.iter_download(base, login, note_id, file_id, max_size=upload["size"]):
            size += len(chunk)
            digest.update(chunk)
        if size != upload["size"] or digest.hexdigest() != upload["sha256"]:
            raise NasError("WRITE_UNCERTAIN", diagnostic={"reason": "ATTACHMENT_CONTENT_MISMATCH"})

    def write_markdown(self, base: str, login: NasLogin, *, note_id: str | None,
                       notebook_id: str, title: str, markdown: str, version: str | None,
                       operation_id: str | None = None, math_images: list[dict] | None = None,
                       uploads: list[dict] | None = None) -> dict:
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
        old_files = {file["id"]: file for file in old["attachments"]} if old else {}
        try:
            _, formulas = math_plan(markdown)
            assets = {}
            supplied = {v['key']: v for v in math_images or []}
            if set(supplied) != {v['key'] for v in formulas}:
                raise CLIError("INVALID_SOURCE", "수식 이미지와 원문이 일치하지 않습니다.")
            for key, image in supplied.items():
                data = base64.b64decode(image['png'], validate=True)
                if (len(data) < 33 or len(data) > 4_000_000 or data[:8] != b'\x89PNG\r\n\x1a\n'
                        or data[12:16] != b'IHDR' or struct.unpack('>II', data[16:24]) != (image['width'] * 2, image['height'] * 2)):
                    raise CLIError("INVALID_SOURCE", "잘못된 PNG입니다.")
                assets[key] = dict(image, data=data, ref=str(uuid.uuid4()).upper())
            rendered = render_markdown(markdown, blocks, assets)
            document_id = previous.document_id if previous else str(uuid.uuid4()).upper()
            operation_id = operation_id or str(uuid.uuid4())
            bindings = dict(previous.attachment_bindings) if previous else {}
            normalized = {str(uuid.UUID(uid)): fid for uid, fid in bindings.items()}
            references = _AttachmentReferences()
            references.feed(rendered)
            references.close()
            pending = {}
            for upload in uploads or []:
                uid, name, mime, image, size, sha256, chunks = (
                    upload[field] for field in ("upload_id", "name", "mime", "image", "size", "sha256", "chunks")
                )
                if (not isinstance(uid, str) or str(uuid.UUID(uid)) != uid or uid in pending or uid in normalized
                        or not isinstance(name, str) or not name or re.search(r'[\x00-\x1f\x7f/\\]', name)
                        or not isinstance(mime, str) or not re.fullmatch(r"[\w!#$&^.+-]+/[\w!#$&^.+-]+", mime, re.ASCII)
                        or type(image) is not bool or image and mime not in IMAGE_MIMES
                        or type(size) is not int or size < 0
                        or not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256)
                        or not callable(chunks)):
                    raise ValueError("Invalid attachment manifest")
                filename = _attachment_filename(operation_id, uid, name, image)
                pending[uid] = {**upload, "filename": filename}
            if set(references.tags) - normalized.keys() != pending.keys():
                raise ValueError("Attachment manifest does not match the referenced uploads")
            for uid, tags in references.tags.items():
                if old and uid in normalized and normalized[uid] == old["source_file_id"]:
                    raise ValueError("Source envelope cannot be referenced as an attachment")
                if "img" in tags and (
                        uid in pending and not pending[uid]["image"]
                        or uid in normalized and old_files.get(normalized[uid], {}).get("name", "").startswith(DOWNLOAD_ONLY_PREFIX)):
                    raise ValueError("Attachment is download only")

            @cache
            def download_api():
                with self._client() as client:
                    return self._info(client, base, NOTE, 1, 1, login)

            def download_url(target, file_id):
                path, api_version, as_json = download_api()
                fields = self._fields(NOTE, 'download', api_version, '',
                    dict(file_id=file_id, object_id=target, format='raw', mode='download'), as_json)
                fields.pop('_sid')
                return f'{base}/webapi/{path}?' + urlencode(fields)

            fake_bindings = {uid: f"preflight-{uuid.uuid4().hex}" for uid in pending}
            bind_html(rendered, bindings | fake_bindings,
                      list(old_files.values()) + [{"id": fid} for fid in fake_bindings.values()],
                      lambda fid: download_url(note_id or "preflight", fid))
            for upload in pending.values():
                for _ in _verified_upload_chunks(upload):
                    pass
            original = old["html"] if old else "<p>문서를 전송하고 있습니다.</p>"
            stage = SourceEnvelope.make(markdown, original, document_id=document_id,
                operation_id=operation_id, is_staging=True, blocks=blocks, attachment_bindings=bindings).encode()
        except (CLIError, ValueError, KeyError, TypeError) as exc:
            raise NasError("MARKDOWN_UNSUPPORTED") from exc
        stage_name = f"{STAGING_SOURCE_PREFIX}{document_id}-{operation_id}.md"
        try:
            target, stage_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                notebook_id=notebook_id, title=None if old else title, html=None if old else original,
                upload=(stage_name, stage))
            current = self.fetch(base, login, target)
            stage_title = old["title"] if old else title

            def check_state(detail, expected_version, expected_title, expected_html):
                if (detail["version"] != expected_version or detail["html"] != expected_html
                        or detail["notebook_id"] != notebook_id or detail["title"] != expected_title
                        or detail.get("locked") or detail.get("trashed")):
                    raise NasError("WRITE_UNCERTAIN")

            check_state(current, stage_version, stage_title, original)
            ids = set(old_files)
            staged = self._new_attachment(ids, current, stage_name)
            if self.download(base, login, target, staged["id"]) != stage:
                raise NasError("WRITE_UNCERTAIN")
            ids.add(staged["id"])
            uploaded = {}
            for uid, upload in pending.items():
                _, stage_version = self._mutate_markdown(base, login, note_id=target, version=stage_version,
                    notebook_id=notebook_id, streamed_upload=upload)
                current = self.fetch(base, login, target)
                check_state(current, stage_version, stage_title, original)
                file = self._new_attachment(ids, current, upload["filename"])
                if upload["image"] and ((file.get("ref") or "").lower() != uid or sum(
                        (row.get("ref") or row["id"]).lower() == uid for row in current["attachments"]) != 1):
                    raise NasError("WRITE_UNCERTAIN", diagnostic={"reason": "ATTACHMENT_REFERENCE_MISMATCH"})
                self._verify_upload(base, login, target, file["id"], upload)
                uploaded[uid] = file
                bindings[uid] = file["id"]
                ids.add(file["id"])

            html = bind_html(rendered, bindings, current["attachments"], lambda fid: download_url(target, fid))
            math_metadata = {}
            for key, asset in assets.items():
                reusable = [(uid, meta) for uid, meta in (previous.math_attachments if previous else {}).items() if meta['key'] == key and uid in bindings]
                if len(reusable) == 1:
                    uid, meta = reusable[0]
                    files = [f for f in current['attachments'] if f['id'] == bindings[uid]]
                    if len(files) == 1:
                        data = self.download(base, login, target, files[0]['id'])
                        if data[:8] == b'\x89PNG\r\n\x1a\n':
                            html = html.replace(f'ref="{asset["ref"]}"', f'ref="{files[0].get("ref") or files[0]["id"]}"').replace(f'width="{asset["width"]}" height="{asset["height"]}"', f'width="{int(meta["width"])}" height="{int(meta["height"])}"')
                            math_metadata[uid] = meta
                            continue
                name = f"synology-note-math-{key}-{operation_id}.png"
                _, stage_version = self._mutate_markdown(base, login, note_id=target, version=stage_version,
                    notebook_id=notebook_id, upload=(name, asset['data']))
                current = self.fetch(base, login, target)
                check_state(current, stage_version, stage_title, original)
                file = self._new_attachment(ids, current, name)
                if self.download(base, login, target, file['id']) != asset['data']:
                    raise NasError("WRITE_UNCERTAIN")
                ids.add(file["id"])
                bindings[asset['ref']] = file['id']
                math_metadata[asset['ref']] = {k: asset[k] for k in ('key', 'width', 'height')}
                html = html.replace(f'ref="{asset["ref"]}"', f'ref="{file.get("ref") or file["id"]}"')
            _, body_version = self._mutate_markdown(base, login, note_id=target, version=stage_version,
                notebook_id=notebook_id, title=title, html=html)
            current = self.fetch(base, login, target)
            check_state(current, body_version, title, html)
            current_files = {file["id"]: file for file in current["attachments"]}
            if current_files.keys() != ids or any(current_files[file["id"]] != file for file in uploaded.values()):
                raise NasError("WRITE_UNCERTAIN")
            deleting = [staged["id"]] + ([old["source_file_id"]] if old else [])
            # Delete only explicitly owned images no longer referenced by source/opaque blocks.
            literals = markdown + ''.join(b['html'] for b in blocks)
            for uid in previous.math_attachments if previous else []:
                fid = bindings.get(uid)
                file = current_files.get(fid)
                if (uid not in math_metadata and file and not file["name"].startswith(ATTACHMENT_PREFIX)
                        and not any(bound == fid and key != uid for key, bound in bindings.items())
                        and not any(v in literals for v in (uid, fid, file.get('ref') or fid))):
                    deleting.append(fid)
                    bindings = {k: v for k, v in bindings.items() if v != fid}
            final = SourceEnvelope.make(markdown, current['html'], document_id=document_id,
                operation_id=operation_id, blocks=blocks, attachment_bindings=bindings, math_attachments=math_metadata).encode()
            final_name = f"synology-note-source-{document_id}.md"
            _, final_version = self._mutate_markdown(base, login, note_id=target, version=body_version,
                notebook_id=notebook_id, upload=(final_name, final), deleting=deleting, listable=True)
            verified = self.fetch(base, login, target)
            check_state(verified, final_version, title, html)
            published = self._new_attachment(ids - set(deleting), verified, final_name)
            if (published["id"] in ids or verified.get("source_file_id") != published["id"]
                    or verified.get("markdown") != markdown or verified.get("blocks") != blocks
                    or verified.get("math_attachments", {}) != math_metadata
                    or verified.get("attachment_bindings") != bindings
                    or verified.get("write_in_progress")
                    or self.download(base, login, target, published["id"]) != final):
                raise NasError("WRITE_UNCERTAIN")
            verified_files = {file["id"]: file for file in verified["attachments"]}
            for uid, file in uploaded.items():
                if verified_files[file["id"]] != file:
                    raise NasError("WRITE_UNCERTAIN")
                self._verify_upload(base, login, target, file["id"], pending[uid])
            return verified
        except (NasError, CLIError) as exc:
            # Every failure after staging starts may already have changed the NAS.
            raise NasError("WRITE_UNCERTAIN", diagnostic=getattr(exc, "diagnostic", None)) from exc


    def remove_attachment(self, base: str, login: NasLogin, *, note_id: str, notebook_id: str,
                          version: str, file_id: str, operation_id: str | None = None) -> dict:
        current = self.fetch(base, login, note_id)
        if current["version"] != version:
            raise NasError("REMOTE_CHANGED")
        if (current["locked"] or current["trashed"] or current["notebook_id"] != notebook_id
                or current.get("write_in_progress") or current.get("read_only_reason") == "AMBIGUOUS_SOURCE"):
            raise NasError("DOCUMENT_READ_ONLY")
        files = {file["id"]: file for file in current["attachments"]}
        file = files.get(file_id)
        if file is None:
            raise NasError("ATTACHMENT_NOT_FOUND")
        filename = file["name"]
        source_id = current.get("source_file_id")
        bindings = current.get("attachment_bindings", {})
        math = current.get("math_attachments", {})
        keys = {uid for uid, target in bindings.items() if target == file_id}
        if (file_id == source_id or keys.intersection(math)
                or filename.lower().startswith(("synology-note-source", "synology-note-math-", STAGING_SOURCE_PREFIX))):
            raise NasError("ATTACHMENT_PROTECTED")
        if filename.lower().endswith(".md") and not filename.startswith(ATTACHMENT_PREFIX):
            try:
                SourceEnvelope.decode(self.download(base, login, note_id, file_id))
            except CLIError:
                pass
            else:
                raise NasError("ATTACHMENT_PROTECTED")
        identities = {value.casefold() for value in {file_id, file.get("ref"), *keys} if value}
        blocks = current.get("blocks", [])
        if any(references_file(source, identities, filename)
               for source in [current["html"], current.get("markdown", ""), *(block["html"] for block in blocks)]):
            raise NasError("ATTACHMENT_IN_USE")
        remaining_bindings = {uid: target for uid, target in bindings.items() if target != file_id}
        upload = None
        deleting = [file_id]
        if keys:
            document_id = current["source_document_id"]
            upload = (f"synology-note-source-{document_id}.md", SourceEnvelope.make(
                current["markdown"], current["html"], document_id=document_id,
                operation_id=operation_id or str(uuid.uuid4()), blocks=blocks,
                attachment_bindings=remaining_bindings, math_attachments=math).encode())
            deleting.append(source_id)
        expected = {key: entry for key, entry in files.items() if key not in deleting}
        try:
            _, next_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                notebook_id=notebook_id, deleting=deleting, upload=upload, listable=True)
            result = self.fetch(base, login, note_id)
            if (result["version"] != next_version
                    or any(result.get(key) != current.get(key) for key in
                           ("title", "html", "markdown", "blocks", "source_document_id",
                            "notebook_id", "locked", "trashed", "math_attachments"))
                    or result.get("attachment_bindings", {}) != remaining_bindings
                    or result.get("write_in_progress")):
                raise NasError("WRITE_UNCERTAIN")
            actual = {entry["id"]: entry for entry in result["attachments"]}
            if upload:
                added = self._new_attachment(set(expected), result, upload[0])
                if (added["id"] in files or result.get("source_file_id") != added["id"]
                        or self.download(base, login, note_id, added["id"]) != upload[1]):
                    raise NasError("WRITE_UNCERTAIN")
                del actual[added["id"]]
            if actual != expected:
                raise NasError("WRITE_UNCERTAIN")
            return result
        except NasError as exc:
            raise NasError("WRITE_UNCERTAIN") from exc

    def write_html_text(self, base: str, login: NasLogin, *, note_id: str, notebook_id: str,
                        title: str, version: str, changes: list[dict], text_layout: str | None = None,
                        structure_edit: dict | None = None, uploads: list[dict] | None = None,
                        operation_id: str | None = None, expected_html: str | None = None) -> dict:
        current = self.fetch(base, login, note_id)
        if current["version"] != version:
            raise NasError("REMOTE_CHANGED")
        if current["locked"] or current["trashed"] or current["notebook_id"] != notebook_id or "markdown" in current or current.get("write_in_progress") or "html_text_preview" not in current:
            raise NasError("DOCUMENT_READ_ONLY")
        if text_layout != layout_identity(current['html']):
            raise NasError('HTML_PATCH_INVALID')
        try:
            if any("\x00" in change["text"] for change in changes):
                raise ValueError()
            html = (apply_structure(current["html"], structure_edit) if structure_edit
                    else patch_html_text(current["html"], changes))
            if expected_html is not None and html != expected_html:
                raise ValueError("The local preview differs from the validated edit")
            if structure_edit and len(html) > max(2_000_000, len(current["html"])):
                raise ValueError()
        except (ValueError, KeyError, TypeError) as exc:
            raise NasError("HTML_PATCH_INVALID") from exc
        if html == current["html"] and title == current["title"] and not uploads:
            return current
        try:
            if uploads:
                for upload in uploads:
                    filename = _attachment_filename(operation_id, upload["upload_id"], upload["name"], False)
                    _, next_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                        notebook_id=notebook_id, title=title, html=html, listable=True,
                        streamed_upload={**upload, "filename": filename, "image": False})
                    result = self.fetch(base, login, note_id)
                    before = {item["id"]: item for item in current["attachments"]}
                    added = self._new_attachment(set(before), result, filename)
                    after = {item["id"]: item for item in result["attachments"] if item["id"] != added["id"]}
                    if (after != before or result["version"] != next_version or result["html"] != html
                            or result["title"] != title or result["notebook_id"] != notebook_id
                            or result["locked"] or result["trashed"] or "markdown" in result):
                        raise NasError("WRITE_UNCERTAIN")
                    self._verify_upload(base, login, note_id, added["id"], upload)
                    current, version = result, next_version
                return current
            _, next_version = self._mutate_markdown(base, login, note_id=note_id, version=version,
                notebook_id=notebook_id, title=title, html=html, listable=True)
            result = self.fetch(base, login, note_id)
            if (result["version"] != next_version or result["html"] != html or result["title"] != title
                    or result["notebook_id"] != notebook_id or result["locked"] or result["trashed"]
                    or sorted(result["attachments"],key=lambda f:f["id"]) != sorted(current["attachments"],key=lambda f:f["id"])):
                raise NasError("WRITE_UNCERTAIN")
            return result
        except NasError as exc:
            raise NasError("WRITE_UNCERTAIN") from exc
