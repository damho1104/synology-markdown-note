"""Local profile and platform-specific remembered login credentials."""
from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
from pathlib import Path

import keyring
from keyring.errors import KeyringError

from .api import NoteStationAPI, checked_server
from .errors import CLIError


def state_dir() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("APPDATA") or Path.home() / "AppData/Roaming")
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "synonote"


def profile_path() -> Path:
    return state_dir() / "profile.json"


def credentials_path() -> Path:
    return state_dir() / "credentials.json"


def _uses_file_credentials() -> bool:
    return sys.platform.startswith("linux")


def _ensure_state_dir() -> None:
    directory = state_dir()
    if directory.is_symlink():
        raise OSError("credential directory is a symlink")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not stat.S_ISDIR(directory.lstat().st_mode):
        raise OSError("credential directory is not a directory")
    if os.name != "nt":
        directory.chmod(0o700)


def _atomic_write_json(path: Path, value: dict) -> None:
    """Keep secret files private and avoid following an existing target symlink."""
    _ensure_state_dir()
    if path.is_symlink():
        raise OSError("credential path is a symlink")
    temporary: str | None = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        if os.name != "nt":
            os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


def _read_credentials_file() -> str:
    path = credentials_path()
    try:
        if path.parent.is_symlink() or path.is_symlink():
            raise OSError("credential path is a symlink")
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise OSError("credential path is not a regular file")
            if os.name != "nt" and (stat.S_IMODE(info.st_mode) & 0o077 or info.st_uid != os.getuid()):
                raise OSError("credential file ownership or permissions are unsafe")
            return stream.read(65537)
    except FileNotFoundError as ex:
        raise CLIError("AUTH_REQUIRED", "No saved login password was found.") from ex
    except (OSError, UnicodeError) as ex:
        raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not safely read the local credentials file.") from ex


def load_profile() -> dict:
    path = profile_path()
    if not path.exists():
        raise CLIError("AUTH_REQUIRED", "Run synonote login --remember first.")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return {"server": checked_server(data["server"]), "username": data["username"]}
    except (KeyError, ValueError, OSError, TypeError) as ex:
        raise CLIError("AUTH_REQUIRED", "Could not read the saved login profile.") from ex


def _service(profile: dict) -> str:
    return "synonote-cli|" + profile["server"]


def _get(profile: dict) -> dict:
    if _uses_file_credentials():
        raw = _read_credentials_file()
    else:
        try:
            raw = keyring.get_password(_service(profile), profile["username"])
        except (KeyringError, RuntimeError) as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "The operating system's secure credential store is unavailable.") from ex
    if not raw:
        raise CLIError("AUTH_REQUIRED", "No saved login password was found.")
    try:
        data = json.loads(raw)
        if not isinstance(data, dict) or not isinstance(data.get("password"), str) or not data["password"]:
            raise ValueError()
        if _uses_file_credentials() and (data.get("server") != profile["server"] or data.get("username") != profile["username"]):
            raise ValueError()
        return data
    except (ValueError, TypeError) as ex:
        raise CLIError("AUTH_REQUIRED", "The saved login credentials are invalid.") from ex


def authenticate(api: NoteStationAPI) -> dict:
    profile = load_profile()
    credential = _get(profile)
    api.login(profile["username"], credential["password"], device_id=credential.get("device_id"))
    return profile


def login(server: str, username: str, password: str, otp: str | None, remember: bool) -> dict:
    server = checked_server(server)
    api = NoteStationAPI(server)
    try:
        did = api.login(username, password, otp=otp, remember=remember)
    finally:
        api.close()
    profile = {"server": server, "username": username}
    if remember:
        _save_credentials(profile, password, did)
        try:
            _atomic_write_json(profile_path(), profile)
        except OSError as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not save the login profile.") from ex
    return {"server": server, "username": username, "remembered": remember}


def set_server(server: str) -> dict:
    """Move a remembered login to another HTTPS address for the same NAS."""
    server = checked_server(server)
    previous = load_profile()
    if server == previous["server"]:
        return {"status": "unchanged", **previous}

    credential = _get(previous)
    api = NoteStationAPI(server)
    try:
        device_id = api.login(previous["username"], credential["password"],
                              device_id=credential.get("device_id"))
    finally:
        api.close()

    updated = {**previous, "server": server}
    stored = {**credential, "device_id": device_id or credential.get("device_id")}
    if _uses_file_credentials():
        # credentials.json includes the server; it must track profile.json.
        try:
            _atomic_write_json(credentials_path(), {**stored, **updated})
            try:
                _atomic_write_json(profile_path(), updated)
            except OSError:
                _atomic_write_json(credentials_path(), {**credential, **previous})
                raise
        except OSError as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not save the server URL. Check the credentials file.") from ex
    else:
        # Native keyrings use the server URL as part of the entry key.
        _save_credentials(updated, stored["password"], stored.get("device_id"))
        try:
            _atomic_write_json(profile_path(), updated)
        except OSError as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not save the server URL.") from ex
    return {"status": "updated", **updated}


def _save_credentials(profile: dict, password: str, device_id: str | None) -> None:
    if _uses_file_credentials():
        try:
            _atomic_write_json(credentials_path(), {**profile, "password": password, "device_id": device_id})
        except OSError as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not save the local credentials file.") from ex
    else:
        try:
            keyring.set_password(_service(profile), profile["username"], json.dumps({"password": password, "device_id": device_id}))
        except (KeyringError, RuntimeError) as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not save the credentials in the secure store.") from ex


def logout() -> None:
    profile = load_profile()
    if _uses_file_credentials():
        try:
            path = credentials_path()
            if path.parent.is_symlink() or path.is_symlink():
                raise OSError("credential path is a symlink")
            path.unlink(missing_ok=True)
        except OSError as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not remove the local credentials file.") from ex
    else:
        try:
            keyring.delete_password(_service(profile), profile["username"])
        except (KeyringError, RuntimeError) as ex:
            raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not remove the saved credentials.") from ex
    try:
        profile_path().unlink(missing_ok=True)
    except OSError as ex:
        raise CLIError("CREDENTIAL_STORE_UNAVAILABLE", "Could not remove the login profile.") from ex
