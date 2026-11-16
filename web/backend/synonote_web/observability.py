"""Request correlation only; never retain credentials or note data."""
from contextvars import ContextVar

request_id: ContextVar[str | None] = ContextVar("synonote_request_id", default=None)
