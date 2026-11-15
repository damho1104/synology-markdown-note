"""Single-install settings. Never put NAS credentials or keys in these values."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


def _bool_env(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    if value.lower() not in {"true", "false", "1", "0"}:
        raise ValueError(f"{name} must be true or false")
    return value.lower() in {"true", "1"}


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    nas_url: str = ""
    allow_private_nas: bool = False
    nas_ca_file: str | None = None
    public_origin: str | None = None
    secure_cookies: bool | None = None
    idle_seconds: int = 12 * 3600
    session_seconds: int = 24 * 3600
    remember_seconds: int = 30 * 24 * 3600
    remember_idle_seconds: int = 7 * 24 * 3600
    rotate_seconds: int = 7 * 24 * 3600

    def __post_init__(self) -> None:
        if self.public_origin:
            parsed = urlsplit(self.public_origin)
            if (parsed.scheme not in {"https", "http"} or not parsed.netloc
                    or parsed.username or parsed.password or parsed.query or parsed.fragment
                    or parsed.path not in {"", "/"}):
                raise ValueError("WEB_PUBLIC_ORIGIN must be an origin without a path")
        if min(self.idle_seconds, self.session_seconds, self.remember_seconds,
               self.remember_idle_seconds, self.rotate_seconds) <= 0:
            raise ValueError("Session lifetimes must be positive")
        if self.remember_idle_seconds > self.remember_seconds:
            raise ValueError("Persistent idle lifetime exceeds maximum lifetime")
        if self.rotate_seconds >= self.remember_seconds:
            raise ValueError("Rotation interval must be shorter than persistent lifetime")

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            data_dir=Path(os.getenv("WEB_DATA_DIR", "/data")),
            nas_url=os.getenv("NAS_URL", "").strip(),
            allow_private_nas=_bool_env("NAS_ALLOW_PRIVATE", False),
            nas_ca_file=os.getenv("NAS_CA_FILE") or None,
            public_origin=os.getenv("WEB_PUBLIC_ORIGIN") or None,
            secure_cookies=(None if os.getenv("WEB_COOKIE_SECURE", "auto").lower() in {"", "auto"}
                            else _bool_env("WEB_COOKIE_SECURE", True)),
        )
