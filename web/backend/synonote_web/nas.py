"""NAS bootstrap and authentication with DNS-address pinning.

Always connect to a prevalidated resolved IP; preserve the original hostname for
TLS SNI/certificate matching on HTTPS. HTTP is permitted for trusted networks,
but credentials are not encrypted on that connection. CGI paths are fixed.
"""

from __future__ import annotations

import ipaddress
import re
import socket
import ssl
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

import httpx


AUTH = "SYNO.API.Auth"
NOTE = "SYNO.NoteStation.Note"
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


class NasClient:
    def __init__(self, *, allow_private: bool = False, ca_file: str | None = None):
        self.allow_private = allow_private
        self.ca_file = ca_file

    @staticmethod
    def _data(response: httpx.Response, auth: bool = False) -> dict:
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
                raise NasError("NAS_API_ERROR")
            data = payload.get("data")
            if not isinstance(data, dict) or data.get("has_fail") is True:
                raise ValueError()
            return data
        except (ValueError, TypeError, AttributeError) as exc:
            raise NasError("NAS_API_ERROR") from exc

    @staticmethod
    def _post(client: httpx.Client, base: str, path: str, data: dict) -> dict:
        if not PATH.fullmatch(path) or any(p in {".", ".."} for p in path.split("/")):
            raise NasError("NAS_API_ERROR")
        try:
            response = client.post(f"{base}/webapi/{path}", data=data)
            # httpx is not allowed to follow redirects, including same-origin ones.
            if response.is_redirect:
                raise NasError("NAS_UNAVAILABLE")
            return NasClient._data(response, auth=data.get("api") == AUTH)
        except (httpx.HTTPError, OSError) as exc:
            raise NasError("NAS_UNAVAILABLE") from exc

    @staticmethod
    def _discover(client: httpx.Client, base: str, name: str) -> dict:
        return NasClient._post(client, base, "query.cgi", {
            "api": "SYNO.API.Info", "method": "query", "version": "1", "query": name,
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
            all_info = self._discover(client, base, "all")
            if NOTE not in all_info:
                raise NasError("NAS_API_ERROR")
            did = result.get("did") or device_id
            if did is not None and not isinstance(did, str):
                raise NasError("NAS_API_ERROR")
            return NasLogin(sid=sid, device_id=did)
