"""NAS setup, authenticated web sessions, and guarded Note Station operations."""

from __future__ import annotations

import hmac
import json
import logging
from datetime import datetime, timezone
import hashlib
import os
import re
import secrets
import threading
import time
import uuid
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

from anyio import CancelScope, fail_after
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect

from .attachment_uploads import MAX_UPLOAD_SIZE, UploadError, Uploads
from .nas import NasClient, NasError, NasLogin, validate_url
from .observability import request_id
from .settings import Settings
from .store import Store, StoreError, token_hash


class SetupInput(BaseModel):
    code: str = Field(min_length=1, max_length=128)
    nas_url: str = Field(min_length=1, max_length=2048)


class LoginInput(BaseModel):
    username: str = Field(min_length=1, max_length=256)
    password: str = Field(min_length=1, max_length=4096)
    otp: str | None = Field(default=None, max_length=20)
    remember: bool = False
    trust_device: bool = False


class TextChange(BaseModel):
    index: int = Field(ge=0)
    text: str = Field(max_length=2_000_000)


class MathImageInput(BaseModel):
    key: str = Field(pattern=r"^[0-9a-f]{64}$")
    width: int = Field(ge=1, le=2048)
    height: int = Field(ge=1, le=2048)
    png: str = Field(max_length=6_000_000)


UUID_PATTERN = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
UPLOAD_ROUTE = re.compile(r"/api/drafts/[^/]+/uploads/[^/]+/?")


class UploadInput(BaseModel):
    upload_id: str = Field(pattern=UUID_PATTERN)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class WriteInput(BaseModel):
    title: str = Field(min_length=1, max_length=256)
    html: str = Field(default="", max_length=2_000_000)
    markdown: str | None = Field(default=None, max_length=2_000_000)
    math_images: list[MathImageInput] = Field(default_factory=list, max_length=100)
    text_changes: list[TextChange] | None = Field(default=None, max_length=10000)
    text_layout: str | None = Field(default=None, max_length=128)
    client_request_id: str | None = Field(default=None, pattern=r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    notebook_id: str = Field(min_length=1, max_length=256)
    version: str | None = Field(default=None, max_length=128)
    draft_id: str | None = Field(default=None, pattern=UUID_PATTERN)
    uploads: list[UploadInput] = Field(default_factory=list, max_length=50)


@dataclass
class TransientSession:
    username: str
    csrf: str
    nas: NasLogin
    created: float
    touched: float


class Attempts:
    """Bound failed attempts per direct peer and action within a 15-minute window."""

    def __init__(self):
        self.failures: dict[tuple[str, str], deque[float]] = defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, address: str, action: str) -> bool:
        with self.lock:
            values = self.failures[(address, action)]
            while values and values[0] <= time.time() - 900:
                values.popleft()
            return len(values) < 6

    def fail(self, address: str, action: str) -> None:
        with self.lock:
            self.failures[(address, action)].append(time.time())

    def reset(self, address: str, action: str) -> None:
        with self.lock:
            self.failures.pop((address, action), None)


def create_app(settings: Settings | None = None, nas_client: NasClient | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    store = Store(settings.data_dir)
    uploads = Uploads(store)
    nas = nas_client or NasClient(allow_private=settings.allow_private_nas,
                                  ca_file=settings.nas_ca_file)
    app = FastAPI(title="Synology Markdown Note Web", docs_url=None, redoc_url=None,
                  openapi_url=None)
    app.state.store = store
    app.state.nas = nas
    app.state.transient: dict[str, TransientSession] = {}
    app.state.live_nas: dict[str, NasLogin] = {}
    app.state.session_lock = threading.RLock()
    app.state.attempts = Attempts()
    def cookie_secure(request: Request) -> bool:
        if settings.secure_cookies is not None:
            return settings.secure_cookies
        if request.headers.get("origin"):
            return urlsplit(request.headers["origin"]).scheme == "https"
        if "__Host-synonote_session" in request.cookies:
            return True
        if "synonote_session" in request.cookies:
            return False
        return request.url.scheme == "https"

    def cookie_name(request: Request) -> str:
        return "__Host-synonote_session" if cookie_secure(request) else "synonote_session"

    def allowed_url(value: str) -> str:
        url = validate_url(value)
        if url.startswith("http://") and not settings.allow_private_nas:
            raise NasError("NAS_HTTP_BLOCKED")
        return url

    def configured() -> tuple[str | None, str]:
        if settings.nas_url:
            return allowed_url(settings.nas_url), "environment"
        stored = store.nas_url()
        return (allowed_url(stored), "database") if stored else (None, "setup")

    if not settings.nas_url and not store.nas_url():
        store.setup_code()
    else:
        store.clear_setup_code()

    try:
        initial_url, _ = configured()
        if initial_url:
            store.bind_nas(initial_url)
    except NasError:
        # Keep the health/status API running so invalid configuration is visible.
        pass

    def log_event(request: Request, event: str, level: int = logging.INFO, **fields) -> None:
        route = request.scope.get("route")
        logging.getLogger("uvicorn.error").log(level, json.dumps({"event": event, "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "request_id": getattr(request.state, "request_id", None),
            "method": request.method, "route": getattr(route, "path", "/api/unknown"),
            **fields}, ensure_ascii=False))

    @app.middleware("http")
    async def no_cache(request: Request, call_next):
        request.state.request_id = secrets.token_hex(8)
        request_id_token = request_id.set(request.state.request_id)
        started = time.monotonic()
        response = None
        try:
            if request.method in {"POST", "PUT", "DELETE", "PATCH"} and request.url.path.startswith("/api/"):
                try:
                    origin_guard(request)
                except HTTPException as exc:
                    response = JSONResponse({"detail": exc.detail}, status_code=exc.status_code)
            if response is None:
                response = await call_next(request)
            for header in getattr(request.state, "session_cookie_headers", []):
                if header not in response.raw_headers:
                    response.raw_headers.append(header)
            if request.url.path.startswith("/api/"):
                response.headers["Cache-Control"] = "no-store"
                response.headers["X-Content-Type-Options"] = "nosniff"
                response.headers["X-Request-ID"] = request.state.request_id
            elif response.headers.get("content-type", "").startswith("text/html"):
                # Always obtain the current hashed script entry after an update.
                response.headers["Cache-Control"] = "no-store"
            return response
        except Exception as exc:
            # Exception messages/tracebacks may contain NAS URLs or request data.
            log_event(request, "request_exception", logging.ERROR, exception_type=type(exc).__name__)
            raise
        finally:
            if request.url.path.startswith("/api/"):
                status = response.status_code if response is not None else 500
                log_event(request, "request_completed", logging.WARNING if status >= 400 else logging.INFO,
                          status=status, duration_ms=round((time.monotonic() - started) * 1000, 1))
            request_id.reset(request_id_token)

    def invalidate_session(request: Request, response: Response, token: str | None, reason: str,
                           error: NasError | None = None) -> None:
        if getattr(request.state, "session_invalidated", False):
            return
        if token:
            logout_token(token)
        clear_cookie(request, response)
        request.state.session_invalidated = True
        log_event(request, "session_invalidated", logging.WARNING, reason=reason,
                  **({"error": error.code, "diagnostic": error.diagnostic} if error else {}))

    @app.exception_handler(NasError)
    async def nas_error(request: Request, exc: NasError):
        code = exc.code
        status = (422 if code in {"INVALID_NAS_URL", "MARKDOWN_UNSUPPORTED", "HTML_PATCH_INVALID"} else 401 if code in
                  {"AUTH_FAILED", "OTP_REQUIRED", "NAS_SESSION_EXPIRED"} else
                  403 if code in {"NAS_ADDRESS_BLOCKED", "NAS_HTTP_BLOCKED", "DOCUMENT_READ_ONLY"} else
                  409 if code in {"REMOTE_CHANGED", "WRITE_UNCERTAIN"} else
                  413 if code == "ATTACHMENT_TOO_LARGE" else 503)
        body = {"error": code}
        if exc.diagnostic:
            body["diagnostic"] = exc.diagnostic
        response = JSONResponse(body, status_code=status)
        if status == 401:
            token = getattr(request.state, "session_token_override", None) or request.cookies.get(cookie_name(request))
            invalidate_session(request, response, token, "nas_auth_failed", exc)
        log_event(request, "nas_error", logging.WARNING, error=code, diagnostic=exc.diagnostic)
        return response

    @app.exception_handler(StoreError)
    async def store_error(request: Request, exc: StoreError):
        log_event(request, "store_error", logging.ERROR, exception_type=type(exc).__name__)
        return JSONResponse({"error": "LOCAL_STORE_ERROR"}, status_code=503)

    @app.exception_handler(UploadError)
    async def upload_error(request: Request, exc: UploadError):
        return JSONResponse({"error": exc.code}, status_code=exc.status)

    def origin_guard(request: Request) -> None:
        # No CORS: browser mutations require an explicit same-origin Origin header.
        origin = request.headers.get("origin")
        # Browser Origin is checked against Host; proxies preserve Host. Never
        # trust arbitrary X-Forwarded-* values or accept a different authority.
        expected = settings.public_origin
        try:
            parsed = urlsplit(origin or "")
        except ValueError as exc:
            raise HTTPException(403, detail="ORIGIN_REQUIRED") from exc
        valid = (origin.rstrip("/") == expected.rstrip("/")) if origin and expected else (
            bool(origin) and parsed.scheme in {"http", "https"} and not parsed.username
            and not parsed.password and not parsed.query and not parsed.fragment
            and parsed.path == "" and parsed.netloc.lower() == request.headers.get("host", "").lower())
        if not valid:
            raise HTTPException(403, detail="ORIGIN_REQUIRED")
        raw_upload = request.method == "PUT" and UPLOAD_ROUTE.fullmatch(request.url.path)
        media_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if raw_upload and media_type != "application/octet-stream":
            raise HTTPException(415, detail="UPLOAD_BODY_REQUIRED")
        if not raw_upload and media_type != "application/json":
            raise HTTPException(415, detail="JSON_REQUIRED")

    def rate_limit(request: Request, action: str) -> str:
        peer = request.client.host if request.client else "unknown"
        if not app.state.attempts.allow(peer, action):
            raise HTTPException(429, detail="TOO_MANY_ATTEMPTS")
        return peer

    def set_cookie(request: Request, response: Response, token: str, remember: bool) -> None:
        response.set_cookie(cookie_name(request), token, httponly=True, secure=cookie_secure(request),
                            samesite="strict", path="/",
                            max_age=settings.remember_seconds if remember else None)
        request.state.session_cookie_headers = [h for h in response.raw_headers if h[0] == b"set-cookie"]

    def clear_cookie(request: Request, response: Response) -> None:
        for name, secure in (("__Host-synonote_session", True), ("synonote_session", False)):
            response.delete_cookie(name, path="/", secure=secure, httponly=True, samesite="strict")
        request.state.session_cookie_headers = [h for h in response.raw_headers if h[0] == b"set-cookie"]

    def logout_token(token: str) -> None:
        with app.state.session_lock:
            digest = token_hash(token)
            app.state.transient.pop(digest, None)
            app.state.live_nas.pop(digest, None)
            revoked = store.revoke(token)
            app.state.live_nas.pop(revoked, None)

    @app.get("/api/health")
    def health():
        return {"ok": True}

    @app.get("/api/ready")
    def ready():
        try:
            configured()
            return {"ok": True}
        except NasError:
            raise HTTPException(503, detail="INVALID_NAS_CONFIGURATION")

    @app.get("/api/status")
    def status():
        try:
            url, source = configured()
        except NasError:
            return JSONResponse({"configured": False, "error": "INVALID_NAS_CONFIGURATION"}, 503)
        return {"configured": url is not None, "nas_url": url, "source": source,
                "read_only": source == "environment"}

    @app.post("/api/setup")
    def setup(body: SetupInput, request: Request):
        origin_guard(request)
        url, _ = configured()
        if url is not None:
            raise HTTPException(409, detail="ALREADY_CONFIGURED")
        peer = rate_limit(request, "setup")
        if not hmac.compare_digest(body.code, store.setup_code()):
            app.state.attempts.fail(peer, "setup")
            raise HTTPException(403, detail="INVALID_SETUP_CODE")
        target = allowed_url(body.nas_url)
        # Connecting to user-selected addresses happens only after setup-code verification.
        nas.probe(target)
        if not store.set_first_nas_url(target):
            raise HTTPException(409, detail="ALREADY_CONFIGURED")
        store.bind_nas(target)
        store.clear_setup_code()
        log_event(request, "nas_setup_succeeded")
        app.state.attempts.reset(peer, "setup")
        return {"configured": True, "nas_url": target, "source": "database", "read_only": False}

    @app.post("/api/auth/login")
    def login(body: LoginInput, request: Request, response: Response):
        origin_guard(request)
        # Use the validated browser origin: HTTPS proxies contact us over HTTP.
        # Do not authenticate successfully when the browser cannot retain our cookie.
        if settings.secure_cookies is True and not request.headers["origin"].lower().startswith("https://"):
            raise HTTPException(503, detail="SECURE_COOKIE_REQUIRES_HTTPS")
        peer = rate_limit(request, "login")
        url, _ = configured()
        if url is None:
            raise HTTPException(409, detail="SETUP_REQUIRED")
        try:
            result = nas.login(url, body.username, body.password, body.otp,
                               body.remember and body.trust_device)
        except NasError as exc:
            for name in ("__Host-synonote_session", "synonote_session"):
                previous = request.cookies.get(name)
                if previous:
                    logout_token(previous)
            invalidate_session(request, response, None, "nas_login_failed", exc)
            if exc.code in {"AUTH_FAILED", "OTP_REQUIRED"}:
                app.state.attempts.fail(peer, "login")
            raise
        token = secrets.token_urlsafe(48)
        digest = token_hash(token)
        csrf = secrets.token_urlsafe(32)
        now = time.time()
        previous_tokens = {request.cookies.get(name) for name in ("__Host-synonote_session", "synonote_session")}
        if body.remember:
            credential = store.encrypt_credential(body.password, result.device_id,
                                                  body.trust_device)
            store.save_session(token, body.username, url, credential, csrf,
                               now + settings.remember_seconds, now)
            with app.state.session_lock:
                app.state.live_nas[digest] = result
        else:
            with app.state.session_lock:
                app.state.transient[digest] = TransientSession(body.username, csrf, result, now, now)
        for previous_token in previous_tokens:
            if previous_token:
                logout_token(previous_token)
        set_cookie(request, response, token, body.remember)
        log_event(request, "login_succeeded", remember=body.remember)
        return {"username": body.username, "remember": body.remember, "csrf_token": csrf}

    def _current_session_locked(request: Request, response: Response) -> tuple[str, str, str, bool]:
        token = getattr(request.state, "session_token_override", None) or request.cookies.get(cookie_name(request))
        if not token or len(token) > 256:
            raise HTTPException(401, detail="LOGIN_REQUIRED")
        digest = token_hash(token)
        now = time.time()
        transient = app.state.transient.get(digest)
        if transient is not None:
            if (transient.created + settings.session_seconds <= now or
                    transient.touched + settings.idle_seconds <= now):
                invalidate_session(request, response, token, "web_session_expired")
                raise HTTPException(401, detail="LOGIN_REQUIRED")
            transient.touched = now
            return token, transient.username, transient.csrf, False
        url, _ = configured()
        if not url:
            raise HTTPException(503, detail="NAS_NOT_CONFIGURED")
        alias = store.resolve_session_alias(token, url, now, settings.remember_idle_seconds)
        if alias is not None:
            token, digest = alias, token_hash(alias)
            request.state.session_token_override = token
            set_cookie(request, response, token, True)
        session = store.session(token, url, now, settings.remember_idle_seconds)
        if session is None:
            app.state.live_nas.pop(digest, None)
            # A stale token may belong to a request sent before cookie rotation.
            # Its late response must not delete a newer valid browser cookie.
            log_event(request, "web_session_missing", logging.WARNING)
            raise HTTPException(401, detail="LOGIN_REQUIRED")
        if digest not in app.state.live_nas:
            credential = store.decrypt_credential(session.credential)
            try:
                active = nas.login(url, session.username, credential["password"], None,
                                   credential["trust_device"], credential["device_id"])
            except NasError as exc:
                invalidate_session(request, response, token, "nas_relogin_failed", exc)
                raise HTTPException(401, detail="RELOGIN_REQUIRED") from exc
            log_event(request, "nas_relogin_succeeded")
            app.state.live_nas[digest] = active
            # Keep an updated device ID encrypted for future server restarts.
            if active.device_id and active.device_id != credential["device_id"]:
                store.update_credential(token, store.encrypt_credential(
                    credential["password"], active.device_id, credential["trust_device"]))
        if now - session.rotated >= settings.rotate_seconds:
            replacement = secrets.token_urlsafe(48)
            if store.rotate_session(token, replacement, now):
                app.state.live_nas[token_hash(replacement)] = app.state.live_nas.pop(digest)
                set_cookie(request, response, replacement, True)
                token = replacement
                request.state.session_token_override = replacement
        return token, session.username, session.csrf, True

    def current_session(request: Request, response: Response) -> tuple[str, str, str, bool]:
        with app.state.session_lock:
            return _current_session_locked(request, response)

    def nas_access(request: Request, response: Response) -> tuple[str, NasLogin, str, str, bool, str]:
        with app.state.session_lock:
            token, username, csrf, remembered = _current_session_locked(request, response)
            digest = token_hash(token)
            active = (app.state.live_nas.get(digest) if remembered else
                      app.state.transient[digest].nas)
            if active is None:
                invalidate_session(request, response, token, "nas_session_missing")
                raise HTTPException(401, detail="RELOGIN_REQUIRED")
            base, _ = configured()
            if base is None:
                raise HTTPException(503, detail="NAS_NOT_CONFIGURED")
            owner = hashlib.sha256((base + "\x00" + username).encode()).hexdigest()
            return base, active, owner, csrf, remembered, token

    def read_nas(request: Request, response: Response, fn):
        base, active, _, _, remembered, token = nas_access(request, response)
        try:
            return fn(base, active)
        except NasError as exc:
            if exc.code != "NAS_SESSION_EXPIRED":
                raise
            log_event(request, "nas_session_expired", logging.WARNING, diagnostic=exc.diagnostic)
            if not remembered:
                invalidate_session(request, response, token, "nas_session_expired", exc)
                raise HTTPException(401, detail="RELOGIN_REQUIRED") from exc
            # Persistent credentials can reauthenticate once after a NAS SID expires.
            with app.state.session_lock:
                app.state.live_nas.pop(token_hash(token), None)
            fresh_base, fresh, _, _, _, _ = nas_access(request, response)
            try:
                return fn(fresh_base, fresh)
            except NasError as retry_error:
                if retry_error.code == "NAS_SESSION_EXPIRED":
                    current_token = getattr(request.state, "session_token_override", None) or token
                    invalidate_session(request, response, current_token, "nas_session_expired_after_relogin", retry_error)
                    raise HTTPException(401, detail="RELOGIN_REQUIRED") from retry_error
                raise

    def csrf_guard(request: Request, expected: str) -> None:
        if not hmac.compare_digest(request.headers.get("x-csrf-token", ""), expected):
            raise HTTPException(403, detail="CSRF_REQUIRED")

    def checked_id(value: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,256}", value):
            raise HTTPException(422, detail="INVALID_ID")
        return value

    @app.get("/api/auth/me")
    def me(request: Request, response: Response):
        _, username, csrf, remembered = current_session(request, response)
        return {"username": username, "remember": remembered, "csrf_token": csrf}

    @app.get("/api/notebooks")
    def notebooks(request: Request, response: Response):
        return {"notebooks": read_nas(request, response, nas.notebooks)}

    @app.get("/api/notes")
    def notes(request: Request, response: Response):
        return {"notes": read_nas(request, response, nas.notes)}

    def remember_graph_entry(detail: dict, owner: str):
        if not {"id", "title", "notebook_id", "version", "html", "locked", "trashed"}.issubset(detail): return
        from .graph_api import entry_from_detail
        try:
            store.save_graph_index(owner, entry_from_detail(detail))
        except StoreError:
            logging.getLogger(__name__).warning("graph_index_unavailable")

    @app.get("/api/notes/{note_id}")
    def note(note_id: str, request: Request, response: Response):
        checked_id(note_id)
        owner = nas_access(request, response)[2]
        detail = read_nas(request, response, lambda base, active: nas.fetch(base, active, note_id))
        remember_graph_entry(detail, owner)
        return detail

    def stream_file(stream, media_type: str, headers: dict) -> StreamingResponse:
        # Read the first chunk before sending headers so access, expiry, and
        # immediate upstream failures can still produce a normal error response.
        try:
            first = next(stream, None)
        except BaseException:
            stream.close()
            raise

        async def content():
            try:
                chunk = first
                while chunk is not None:
                    yield chunk
                    chunk = await run_in_threadpool(next, stream, None)
            finally:
                with CancelScope(shield=True):
                    await run_in_threadpool(stream.close)

        return StreamingResponse(content(), media_type=media_type, headers=headers)

    @app.get("/api/notes/{note_id}/attachments/{file_id}")
    def attachment(note_id: str, file_id: str, request: Request, response: Response):
        checked_id(note_id)
        checked_id(file_id)

        def get_file(base: str, active: NasLogin):
            detail = nas.fetch(base, active, note_id)
            if detail["locked"]:
                raise HTTPException(403, detail="DOCUMENT_READ_ONLY")
            match = next((f for f in detail["attachments"] if f["id"] == file_id), None)
            if match is None:
                raise HTTPException(404, detail="ATTACHMENT_NOT_FOUND")
            safe_name = match["name"].replace("\r", "").replace("\n", "")[:256]
            headers = {
                "Content-Disposition": f"attachment; filename=attachment; filename*=UTF-8''{quote(safe_name)}",
                "X-Content-Type-Options": "nosniff",
            }
            if not isinstance(nas, NasClient):
                return Response(content=nas.download(base, active, note_id, file_id),
                                media_type="application/octet-stream", headers=headers)
            stream = nas.iter_download(base, active, note_id, file_id, max_size=MAX_UPLOAD_SIZE)
            return stream_file(stream, "application/octet-stream", headers)

        result = read_nas(request, response, get_file)
        # Explicit download responses otherwise bypass FastAPI's injected headers.
        result.raw_headers.extend((key, value) for key, value in response.raw_headers
                                  if key.lower() == b"set-cookie")
        return result

    @app.post("/api/math/plan")
    def math_plan_api(body: WriteInput, request: Request, response: Response):
        _, _, _, csrf, _, _ = nas_access(request, response)
        csrf_guard(request, csrf)
        from .compat.markdown import math_plan
        masked, formulas = math_plan(body.markdown or "")
        return {"markdown": masked, "formulas": formulas}

    upload_path = "/api/drafts/{draft_id}/uploads/{upload_id}"

    def upload_ids(draft_id: str, upload_id: str) -> None:
        if not re.fullmatch(UUID_PATTERN, draft_id) or not re.fullmatch(UUID_PATTERN, upload_id):
            raise HTTPException(422, detail="INVALID_UPLOAD")

    @app.put(upload_path)
    async def put_upload(draft_id: str, upload_id: str, request: Request, response: Response,
                         notebook_id: str, note_id: str | None = None,
                         client_request_id: str | None = None):
        base, active, owner, csrf, _, _ = await run_in_threadpool(nas_access, request, response)
        csrf_guard(request, csrf)
        upload_ids(draft_id, upload_id)
        checked_id(notebook_id)
        if (note_id is None) == (client_request_id is None):
            raise HTTPException(422, detail="INVALID_UPLOAD")
        if note_id is not None:
            checked_id(note_id)
        if client_request_id is not None and not re.fullmatch(UUID_PATTERN, client_request_id):
            raise HTTPException(422, detail="INVALID_UPLOAD")
        raw_size = request.headers.get("x-upload-size", "")
        raw_filename = request.headers.get("x-upload-name", "")
        if not re.fullmatch(r"[0-9]{1,12}", raw_size) or not 1 <= len(raw_filename) <= 4096:
            raise HTTPException(422, detail="INVALID_UPLOAD")
        size = int(raw_size)
        content_length = request.headers.get("content-length")
        if size > MAX_UPLOAD_SIZE:
            raise HTTPException(413, detail="ATTACHMENT_TOO_LARGE")
        if content_length is not None:
            if not re.fullmatch(r"[0-9]{1,12}", content_length):
                raise HTTPException(422, detail="INVALID_UPLOAD")
            if int(content_length) > MAX_UPLOAD_SIZE:
                raise HTTPException(413, detail="ATTACHMENT_TOO_LARGE")
            if int(content_length) != size:
                raise HTTPException(422, detail="UPLOAD_SIZE_MISMATCH")
        if not size:
            raise HTTPException(422, detail="INVALID_UPLOAD")
        try:
            name = unquote(raw_filename, errors="strict")
        except UnicodeError as exc:
            raise HTTPException(422, detail="INVALID_UPLOAD") from exc
        if note_id is not None:
            detail = await run_in_threadpool(nas.fetch, base, active, note_id)
            if not detail.get("editable") or "markdown" not in detail or detail["notebook_id"] != notebook_id:
                raise HTTPException(403, detail="DOCUMENT_READ_ONLY")
        target = note_id if note_id is not None else "draft-create:" + client_request_id
        receipt = await run_in_threadpool(uploads.reserve, owner, draft_id, upload_id, target, notebook_id, name, size)
        published = False
        size_received = 0
        pending = bytearray()
        chunk_size = 256 * 1024
        try:
            with fail_after(600):
                async for raw in request.stream():
                    size_received += len(raw)
                    if size_received > MAX_UPLOAD_SIZE:
                        raise HTTPException(413, detail="ATTACHMENT_TOO_LARGE")
                    if size_received > size:
                        raise HTTPException(422, detail="UPLOAD_SIZE_MISMATCH")
                    remaining = memoryview(raw)
                    while remaining:
                        take = min(chunk_size - len(pending), len(remaining))
                        pending.extend(remaining[:take])
                        remaining = remaining[take:]
                        if len(pending) == chunk_size:
                            await run_in_threadpool(uploads.append, receipt, bytes(pending))
                            pending.clear()
                if size_received != size:
                    raise HTTPException(422, detail="UPLOAD_SIZE_MISMATCH")
                if pending:
                    await run_in_threadpool(uploads.append, receipt, bytes(pending))
                result = await run_in_threadpool(uploads.publish, receipt)
                published = True
                return result
        except (TimeoutError, ClientDisconnect) as exc:
            raise HTTPException(408, detail="UPLOAD_INCOMPLETE") from exc
        finally:
            if not published:
                with CancelScope(shield=True):
                    await run_in_threadpool(uploads.abort, receipt)

    @app.get(upload_path)
    def get_upload(draft_id: str, upload_id: str, request: Request, response: Response):
        upload_ids(draft_id, upload_id)
        owner = nas_access(request, response)[2]
        return uploads.get(owner, draft_id, upload_id)

    @app.delete(upload_path)
    def delete_upload(draft_id: str, upload_id: str, request: Request, response: Response):
        upload_ids(draft_id, upload_id)
        _, _, owner, csrf, _, _ = nas_access(request, response)
        csrf_guard(request, csrf)
        uploads.delete(owner, draft_id, upload_id)
        return {"deleted": True}

    @app.get(upload_path + "/content")
    def upload_content(draft_id: str, upload_id: str, request: Request, response: Response):
        upload_ids(draft_id, upload_id)
        owner = nas_access(request, response)[2]
        meta = uploads.get(owner, draft_id, upload_id)
        if meta["status"] not in {"ready", "pinned", "reviewed"}:
            raise HTTPException(404, detail="UPLOAD_NOT_FOUND")
        result = stream_file(uploads.iter_content(owner, draft_id, upload_id),
                             meta["mime"] if meta["image"] else "application/octet-stream",
                             {"Content-Length": str(meta["size"]),
                              "Content-Disposition": f"attachment; filename=attachment; filename*=UTF-8''{quote(meta['name'], safe='')}"})
        result.raw_headers.extend((key, value) for key, value in response.raw_headers
                                  if key.lower() == b"set-cookie")
        return result

    @app.get("/api/writes")
    def writes(request: Request, response: Response):
        _, _, owner, _, _, _ = nas_access(request, response)
        return {"operations": store.pending_writes(owner)}

    @app.get('/api/creates/{client_request_id}')
    def create_receipt(client_request_id: str, request: Request, response: Response):
        try:
            if str(uuid.UUID(client_request_id)) != client_request_id: raise ValueError()
        except ValueError as exc:
            raise HTTPException(422, detail='INVALID_ID') from exc
        owner = nas_access(request, response)[2]
        receipt = store.create_receipt(owner, client_request_id)
        return {key: value for key, value in receipt.items() if key != 'request_hash'}

    def write_note(body: WriteInput, request: Request, response: Response,
                   note_id: str | None = None):
        if note_id is not None:
            checked_id(note_id)
        checked_id(body.notebook_id)
        if (not body.title.strip() or body.title != body.title.strip()
                or "\x00" in body.html):
            raise HTTPException(422, detail="INVALID_NOTE")
        if note_id and not body.version or not note_id and body.version:
            raise HTTPException(422, detail="VERSION_REQUIRED")
        base, active, owner, csrf, _, _ = nas_access(request, response)
        csrf_guard(request, csrf)
        if note_id is None and body.client_request_id is None:
            raise HTTPException(422, detail='CLIENT_REQUEST_ID_REQUIRED')
        if body.uploads and (not body.draft_id or body.markdown is None or body.text_changes is not None):
            raise HTTPException(422, detail="INVALID_UPLOAD")
        intent = body.model_dump(exclude={"draft_id", "uploads"})
        if body.uploads:
            intent.update(draft_id=body.draft_id, uploads=[item.model_dump() for item in body.uploads])
        request_hash = hashlib.sha256(json.dumps(intent, sort_keys=True, ensure_ascii=False,
                                                 separators=(',', ':')).encode()).hexdigest()
        def previous_create():
            receipt = store.create_receipt(owner, body.client_request_id)
            if receipt['status'] == 'absent': return None
            if receipt['request_hash'] != request_hash:
                raise HTTPException(409, detail='CREATE_KEY_REUSED')
            if receipt['status'] == 'completed': return receipt['note']
            raise HTTPException(409, detail='WRITE_REVIEW_REQUIRED')
        if note_id is None:
            previous = previous_create()
            if previous is not None: return previous
        upload_keys = []
        attachments = []
        seen = set()
        for item in body.uploads:
            upload_target = note_id or "draft-create:" + body.client_request_id
            if item.upload_id in seen:
                raise HTTPException(422, detail="INVALID_UPLOAD")
            seen.add(item.upload_id)
            meta = uploads.get(owner, body.draft_id, item.upload_id)
            if (meta["target"] != upload_target or meta["notebook_id"] != body.notebook_id
                    or meta["sha256"] != item.sha256 or meta["status"] != "ready"):
                raise HTTPException(409, detail="UPLOAD_NOT_READY")
            upload_keys.append((body.draft_id, item.upload_id, upload_target, body.notebook_id, item.sha256))
            attachments.append(dict(meta, chunks=lambda upload_id=item.upload_id:
                                    uploads.iter_content(owner, body.draft_id, upload_id)))
        operation_id = str(uuid.uuid4())
        target = note_id or "new:" + body.notebook_id + ":" + hashlib.sha256(body.title.encode()).hexdigest()
        if not store.start_write(operation_id, owner, target, note_id, body.title,
                                 intent, client_request_id=body.client_request_id if note_id is None else None,
                                 request_hash=request_hash, **({"upload_keys": upload_keys} if upload_keys else {})):
            if note_id is None:
                previous = previous_create()
                if previous is not None: return previous
            raise HTTPException(409, detail="WRITE_REVIEW_REQUIRED")
        try:
            if body.text_changes is not None:
                if not note_id or not body.version or body.markdown is not None:
                    raise NasError("HTML_PATCH_INVALID")
                result = nas.write_html_text(base, active, note_id=note_id, notebook_id=body.notebook_id,
                    title=body.title, version=body.version, text_layout=body.text_layout,
                    changes=[v.model_dump() for v in body.text_changes])
            elif body.markdown is not None:
                result = nas.write_markdown(base, active, note_id=note_id, notebook_id=body.notebook_id,
                                           title=body.title, markdown=body.markdown, version=body.version,
                                           operation_id=operation_id,
                                           **({"math_images": [v.model_dump() for v in body.math_images]} if body.math_images else {}),
                                           **({"uploads": attachments} if attachments else {}))
            else:
                result = nas.write(base, active, note_id=note_id, notebook_id=body.notebook_id,
                                   title=body.title, html=body.html, version=body.version)
        except NasError as exc:
            # A rejected preflight/version conflict is safe to retry after refreshing.
            store.finish_write(operation_id, uncertain=exc.code not in
                               {"REMOTE_CHANGED", "DOCUMENT_READ_ONLY", "NAS_SESSION_EXPIRED", "MARKDOWN_UNSUPPORTED", "HTML_PATCH_INVALID"})
            raise
        except Exception:
            store.finish_write(operation_id, uncertain=True)
            raise
        store.finish_write(operation_id, uncertain=False, result=result)
        remember_graph_entry(result, owner)
        return result

    @app.post("/api/notes")
    def create_note(body: WriteInput, request: Request, response: Response):
        return write_note(body, request, response)

    @app.put("/api/notes/{note_id}")
    def update_note(note_id: str, body: WriteInput, request: Request, response: Response):
        return write_note(body, request, response, note_id)

    @app.post("/api/writes/{operation_id}/ack")
    def acknowledge_write(operation_id: str, request: Request, response: Response):
        try:
            uuid.UUID(operation_id)
        except ValueError as exc:
            raise HTTPException(422, detail="INVALID_ID") from exc
        _, _, owner, csrf, _, _ = nas_access(request, response)
        csrf_guard(request, csrf)
        if not store.acknowledge_write(owner, operation_id):
            raise HTTPException(404, detail="OPERATION_NOT_FOUND")
        return {"ok": True}

    @app.post("/api/auth/logout")
    def logout(request: Request, response: Response):
        origin_guard(request)
        with app.state.session_lock:
            token, _, csrf, _ = _current_session_locked(request, response)
            supplied = request.headers.get("x-csrf-token", "")
            if not hmac.compare_digest(supplied, csrf):
                raise HTTPException(403, detail="CSRF_REQUIRED")
            logout_token(token)
        clear_cookie(request, response)
        return {"ok": True}

    from .library_api import install_library_routes
    install_library_routes(app, nas=nas, read_nas=read_nas, nas_access=nas_access,
                           csrf_guard=csrf_guard, checked_id=checked_id, store=store)
    from .graph_api import register_graph_routes
    register_graph_routes(app, read_nas=read_nas, nas=nas, store=store, owner_for_request=lambda request, response: nas_access(request, response)[2])

    static_dir = Path(os.getenv("WEB_STATIC_DIR", Path(__file__).parents[2] / "frontend" / "dist"))
    if static_dir.is_dir():
        app.mount("/", StaticFiles(directory=static_dir, html=True), name="frontend")
    return app
