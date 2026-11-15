"""NAS setup, authenticated web sessions, and guarded Note Station operations."""

from __future__ import annotations

import hmac
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
from urllib.parse import quote

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .nas import NasClient, NasError, NasLogin, validate_url
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


class WriteInput(BaseModel):
    title: str = Field(min_length=1, max_length=256)
    html: str = Field(max_length=2_000_000)
    notebook_id: str = Field(min_length=1, max_length=256)
    version: str | None = Field(default=None, max_length=128)


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
    cookie_name = "__Host-synonote_session" if settings.secure_cookies else "synonote_session"

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

    @app.middleware("http")
    async def no_cache(request: Request, call_next):
        if request.method in {"POST", "PUT", "DELETE", "PATCH"} and request.url.path.startswith("/api/"):
            # Check before FastAPI parses the request body or reports validation errors.
            try:
                origin_guard(request)
            except HTTPException as exc:
                return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)
        response = await call_next(request)
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.exception_handler(NasError)
    async def nas_error(_: Request, exc: NasError):
        code = exc.code
        status = (422 if code == "INVALID_NAS_URL" else 401 if code in
                  {"AUTH_FAILED", "OTP_REQUIRED", "NAS_SESSION_EXPIRED"} else
                  403 if code in {"NAS_ADDRESS_BLOCKED", "NAS_HTTP_BLOCKED", "DOCUMENT_READ_ONLY"} else
                  409 if code in {"REMOTE_CHANGED", "WRITE_UNCERTAIN"} else
                  413 if code == "ATTACHMENT_TOO_LARGE" else 503)
        return JSONResponse({"error": code}, status_code=status)

    @app.exception_handler(StoreError)
    async def store_error(_: Request, __: StoreError):
        return JSONResponse({"error": "LOCAL_STORE_ERROR"}, status_code=503)

    def origin_guard(request: Request) -> None:
        # No CORS: browser mutations require an explicit same-origin Origin header.
        origin = request.headers.get("origin")
        expected = settings.public_origin or f"{request.url.scheme}://{request.headers.get('host', '')}"
        if not origin or origin.rstrip("/") != expected.rstrip("/"):
            raise HTTPException(403, detail="ORIGIN_REQUIRED")
        if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise HTTPException(415, detail="JSON_REQUIRED")

    def rate_limit(request: Request, action: str) -> str:
        peer = request.client.host if request.client else "unknown"
        if not app.state.attempts.allow(peer, action):
            raise HTTPException(429, detail="TOO_MANY_ATTEMPTS")
        return peer

    def set_cookie(response: Response, token: str, remember: bool) -> None:
        response.set_cookie(cookie_name, token, httponly=True, secure=settings.secure_cookies,
                            samesite="strict", path="/",
                            max_age=settings.remember_seconds if remember else None)

    def clear_cookie(response: Response) -> None:
        response.delete_cookie(cookie_name, path="/", secure=settings.secure_cookies,
                               httponly=True, samesite="strict")

    def logout_token(token: str) -> None:
        with app.state.session_lock:
            digest = token_hash(token)
            app.state.transient.pop(digest, None)
            app.state.live_nas.pop(digest, None)
            store.revoke(token)

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
        app.state.attempts.reset(peer, "setup")
        return {"configured": True, "nas_url": target, "source": "database", "read_only": False}

    @app.post("/api/auth/login")
    def login(body: LoginInput, request: Request, response: Response):
        origin_guard(request)
        # Use the validated browser origin: HTTPS proxies contact us over HTTP.
        # Do not authenticate successfully when the browser cannot retain our cookie.
        if settings.secure_cookies and not request.headers["origin"].lower().startswith("https://"):
            raise HTTPException(503, detail="SECURE_COOKIE_REQUIRES_HTTPS")
        peer = rate_limit(request, "login")
        url, _ = configured()
        if url is None:
            raise HTTPException(409, detail="SETUP_REQUIRED")
        try:
            result = nas.login(url, body.username, body.password, body.otp,
                               body.remember and body.trust_device)
        except NasError as exc:
            if exc.code in {"AUTH_FAILED", "OTP_REQUIRED"}:
                app.state.attempts.fail(peer, "login")
            raise
        token = secrets.token_urlsafe(48)
        digest = token_hash(token)
        csrf = secrets.token_urlsafe(32)
        now = time.time()
        previous_token = request.cookies.get(cookie_name)
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
        if previous_token:
            logout_token(previous_token)
        set_cookie(response, token, body.remember)
        return {"username": body.username, "remember": body.remember, "csrf_token": csrf}

    def _current_session_locked(request: Request, response: Response) -> tuple[str, str, str, bool]:
        token = request.cookies.get(cookie_name)
        if not token or len(token) > 256:
            raise HTTPException(401, detail="LOGIN_REQUIRED")
        digest = token_hash(token)
        now = time.time()
        transient = app.state.transient.get(digest)
        if transient is not None:
            if (transient.created + settings.session_seconds <= now or
                    transient.touched + settings.idle_seconds <= now):
                app.state.transient.pop(digest, None)
                raise HTTPException(401, detail="LOGIN_REQUIRED")
            transient.touched = now
            return token, transient.username, transient.csrf, False
        url, _ = configured()
        if not url:
            raise HTTPException(503, detail="NAS_NOT_CONFIGURED")
        session = store.session(token, url, now, settings.remember_idle_seconds)
        if session is None:
            app.state.live_nas.pop(digest, None)
            raise HTTPException(401, detail="LOGIN_REQUIRED")
        if digest not in app.state.live_nas:
            credential = store.decrypt_credential(session.credential)
            try:
                active = nas.login(url, session.username, credential["password"], None,
                                   credential["trust_device"], credential["device_id"])
            except NasError as exc:
                if exc.code in {"AUTH_FAILED", "OTP_REQUIRED"}:
                    logout_token(token)
                    clear_cookie(response)
                    raise HTTPException(401, detail="RELOGIN_REQUIRED") from exc
                raise
            app.state.live_nas[digest] = active
            # Keep an updated device ID encrypted for future server restarts.
            if active.device_id and active.device_id != credential["device_id"]:
                store.update_credential(token, store.encrypt_credential(
                    credential["password"], active.device_id, credential["trust_device"]))
        if now - session.rotated >= settings.rotate_seconds:
            replacement = secrets.token_urlsafe(48)
            if store.rotate_session(token, replacement, now):
                app.state.live_nas[token_hash(replacement)] = app.state.live_nas.pop(digest)
                set_cookie(response, replacement, True)
                token = replacement
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
            if not remembered:
                raise HTTPException(401, detail="RELOGIN_REQUIRED") from exc
            # Persistent credentials can reauthenticate once after a NAS SID expires.
            with app.state.session_lock:
                app.state.live_nas.pop(token_hash(token), None)
            fresh_base, fresh, _, _, _, _ = nas_access(request, response)
            return fn(fresh_base, fresh)

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

    @app.get("/api/notes/{note_id}")
    def note(note_id: str, request: Request, response: Response):
        checked_id(note_id)
        return read_nas(request, response, lambda base, active: nas.fetch(base, active, note_id))

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
            data = nas.download(base, active, note_id, file_id)
            safe_name = match["name"].replace("\r", "").replace("\n", "")[:256]
            return Response(content=data, media_type="application/octet-stream", headers={
                "Content-Disposition": f"attachment; filename=attachment; filename*=UTF-8''{quote(safe_name)}",
                "X-Content-Type-Options": "nosniff",
            })

        result = read_nas(request, response, get_file)
        # Explicit download responses otherwise bypass FastAPI's injected headers.
        result.raw_headers.extend((key, value) for key, value in response.raw_headers
                                  if key.lower() == b"set-cookie")
        return result

    @app.get("/api/writes")
    def writes(request: Request, response: Response):
        _, _, owner, _, _, _ = nas_access(request, response)
        return {"operations": store.pending_writes(owner)}

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
        operation_id = str(uuid.uuid4())
        target = note_id or "new:" + body.notebook_id + ":" + hashlib.sha256(body.title.encode()).hexdigest()
        if not store.start_write(operation_id, owner, target, note_id, body.title,
                                 body.model_dump()):
            raise HTTPException(409, detail="WRITE_REVIEW_REQUIRED")
        try:
            result = nas.write(base, active, note_id=note_id, notebook_id=body.notebook_id,
                               title=body.title, html=body.html, version=body.version)
        except NasError as exc:
            # A rejected preflight/version conflict is safe to retry after refreshing.
            store.finish_write(operation_id, uncertain=exc.code not in
                               {"REMOTE_CHANGED", "DOCUMENT_READ_ONLY", "NAS_SESSION_EXPIRED"})
            raise
        except Exception:
            store.finish_write(operation_id, uncertain=True)
            raise
        store.finish_write(operation_id, uncertain=False)
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
        clear_cookie(response)
        return {"ok": True}

    static_dir = Path(os.getenv("WEB_STATIC_DIR", Path(__file__).parents[2] / "frontend" / "dist"))
    if static_dir.is_dir():
        app.mount("/", StaticFiles(directory=static_dir, html=True), name="frontend")
    return app
