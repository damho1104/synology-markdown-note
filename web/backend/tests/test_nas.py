from __future__ import annotations

import socket

import httpx
import pytest

from synonote_web.nas import NasClient, NasError, PinnedTransport, validate_url


@pytest.mark.parametrize("url", [
    "ftp://nas.example", "https://user:pw@nas.example", "https://nas.example?url=1",
    "https://nas.example#fragment", "https://nas.example/path/../admin",
    "https://nas.example/%2e%2e", "https://nas.example\\@evil.example",
    "https://nas.example:0", "https://nas.example:99999", "https://nas.example//proxy",
    "https://fe80::1", "https://fe80::1%eth0", " https://nas.example",
    "http://user:pw@nas.example", "http://nas.example?token=1",
    "http://nas.example/path/../admin", "http://nas.example:0",
])
def test_reject_unsafe_urls(url):
    with pytest.raises(NasError) as exc:
        validate_url(url)
    assert exc.value.code == "INVALID_NAS_URL"


def test_validate_proxy_prefix_and_ipv6():
    assert validate_url("https://nas.example/nas/") == "https://nas.example/nas"
    assert validate_url("https://[2001:db8::1]:5001/nas") == "https://[2001:db8::1]:5001/nas"
    assert validate_url("http://NAS.EXAMPLE:5000/nas/") == "http://nas.example:5000/nas"
    assert validate_url("http://192.168.1.10:5000") == "http://192.168.1.10:5000"


class CaptureTransport(httpx.BaseTransport):
    def __init__(self):
        self.seen = []

    def handle_request(self, request):
        self.seen.append(request)
        return httpx.Response(200, json={"success": True, "data": {}})


def dns(*addresses):
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443)) for address in addresses]


def test_dns_pin_keeps_host_and_tls_identity(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: dns("8.8.8.8"))
    transport = PinnedTransport(False)
    capture = CaptureTransport()
    transport.transport = capture
    with httpx.Client(transport=transport, trust_env=False) as client:
        assert client.post("https://nas.example/webapi/query.cgi", data={"hello": "world"}).status_code == 200
    sent = capture.seen[0]
    assert sent.url.host == "8.8.8.8"
    assert sent.headers["host"] == "nas.example"
    assert sent.extensions["sni_hostname"] == "nas.example"


def test_http_dns_pin_uses_port_80_and_preserves_host(monkeypatch):
    resolved_ports = []

    def resolve(host, port, **kwargs):
        resolved_ports.append((host, port))
        return dns("192.168.1.15")

    monkeypatch.setattr(socket, "getaddrinfo", resolve)
    transport = PinnedTransport(True)
    capture = CaptureTransport()
    transport.transport = capture
    with httpx.Client(transport=transport, trust_env=False) as client:
        assert client.post("http://nas.lan/webapi/query.cgi").status_code == 200
    assert resolved_ports == [("nas.lan", 80)]
    sent = capture.seen[0]
    assert sent.url.scheme == "http" and sent.url.host == "192.168.1.15"
    assert sent.headers["host"] == "nas.lan"
    assert "sni_hostname" not in sent.extensions


def test_http_dns_pin_still_blocks_private_without_opt_in(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: dns("192.168.1.15"))
    transport = PinnedTransport(False)
    capture = CaptureTransport()
    transport.transport = capture
    with httpx.Client(transport=transport, trust_env=False) as client:
        with pytest.raises(NasError) as exc:
            client.post("http://nas.lan/webapi/query.cgi")
    assert exc.value.code == "NAS_ADDRESS_BLOCKED"
    assert capture.seen == []


@pytest.mark.parametrize("addresses", [
    ("127.0.0.1",), ("169.254.169.254",), ("0.0.0.0",),
    ("8.8.8.8", "127.0.0.1"), ("192.168.0.1",),
])
def test_dns_filter_does_not_connect(monkeypatch, addresses):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: dns(*addresses))
    transport = PinnedTransport(False)
    capture = CaptureTransport()
    transport.transport = capture
    with httpx.Client(transport=transport, trust_env=False) as client:
        with pytest.raises(NasError) as exc:
            client.post("https://nas.example/webapi/query.cgi")
    assert exc.value.code == "NAS_ADDRESS_BLOCKED"
    assert capture.seen == []


def test_private_nas_opt_in_still_rejects_localhost_and_metadata(monkeypatch):
    transport = PinnedTransport(True)
    capture = CaptureTransport()
    transport.transport = capture
    with httpx.Client(transport=transport, trust_env=False) as client:
        monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: dns("192.168.1.15"))
        assert client.post("https://nas.lan/webapi/query.cgi").status_code == 200
        monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: dns("127.0.0.1"))
        with pytest.raises(NasError):
            client.post("https://nas.lan/webapi/query.cgi")
    assert len(capture.seen) == 1


@pytest.mark.parametrize("address", [
    "192.0.0.8", "2001:db8::1", "169.254.169.254", "127.0.0.1", "::1",
])
def test_private_nas_opt_in_never_allows_special_purpose_networks(monkeypatch, address):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: dns(address))
    transport = PinnedTransport(True)
    capture = CaptureTransport()
    transport.transport = capture
    with httpx.Client(transport=transport, trust_env=False) as client:
        with pytest.raises(NasError) as exc:
            client.post("https://nas.example/webapi/query.cgi")
    assert exc.value.code == "NAS_ADDRESS_BLOCKED"
    assert capture.seen == []


@pytest.mark.parametrize("base", ["https://nas.example", "http://nas.example:5000"])
def test_actual_auth_contract_with_mock_http(monkeypatch, base):
    calls = []

    def handler(request):
        form = dict(item.split("=", 1) for item in request.content.decode().split("&"))
        calls.append((request.url.path, form))
        if form["api"] == "SYNO.API.Info":
            if form["query"] == "all":
                return httpx.Response(200, json={"success": True, "data": {"SYNO.NoteStation.Note": {"maxVersion": 3}}})
            return httpx.Response(200, json={"success": True, "data": {
                "SYNO.API.Auth": {"path": "auth.cgi", "minVersion": 3, "maxVersion": 6},
            }})
        return httpx.Response(200, json={"success": True, "data": {"sid": "sid", "did": "device"}})

    monkeypatch.setattr(NasClient, "_client", lambda self: httpx.Client(transport=httpx.MockTransport(handler)))
    client = NasClient()
    client.probe(base)
    result = client.login(base, "alice", "secret", "123456", True)
    assert result.sid == "sid" and result.device_id == "device"
    auth = calls[-2]
    assert auth[0] == "/webapi/auth.cgi"
    assert auth[1]["version"] == "6"
    assert auth[1]["session"] == "notestation"
    assert auth[1]["otp_code"] == "123456"
    assert auth[1]["enable_device_token"] == "yes"
