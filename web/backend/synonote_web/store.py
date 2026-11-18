"""Private installation settings and encrypted persistent-login records."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import stat
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from cryptography.fernet import Fernet, InvalidToken


class StoreError(Exception):
    pass


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _private_directory(path: Path) -> None:
    if path.is_symlink():
        raise StoreError("Data directory cannot be a symlink")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise StoreError("Data directory must be a directory")
    path.chmod(0o700)


def _private_file(path: Path) -> bytes:
    if path.is_symlink():
        raise StoreError("Secret file cannot be a symlink")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) & 0o077
                or metadata.st_uid != os.getuid()):
            raise StoreError("Secret file has unsafe permissions or ownership")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read(4097)
    finally:
        os.close(fd)


def _create_secret(path: Path, secret: bytes) -> bytes:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except FileExistsError:
        return _private_file(path)
    with os.fdopen(fd, "wb") as stream:
        stream.write(secret)
        stream.flush()
        os.fsync(stream.fileno())
    return secret


@dataclass(frozen=True)
class PersistedSession:
    token_hash: str
    username: str
    nas_url: str
    credential: bytes
    csrf: str
    created: float
    rotated: float
    last_seen: float
    expires: float


class Store:
    def __init__(self, data_dir: Path):
        _private_directory(data_dir)
        self.dir = data_dir
        self.db = data_dir / "web.sqlite3"
        if self.db.is_symlink():
            raise StoreError("Database cannot be a symlink")
        key = _create_secret(data_dir / "master.key", Fernet.generate_key())
        try:
            self.cipher = Fernet(key)
        except (ValueError, TypeError) as exc:
            raise StoreError("Master key is invalid; restore it from backup") from exc
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS graph_index (
                    owner TEXT NOT NULL, note_id TEXT NOT NULL, version TEXT NOT NULL,
                    entry BLOB NOT NULL, PRIMARY KEY(owner, note_id)
                );
                CREATE TABLE IF NOT EXISTS config (
                    name TEXT PRIMARY KEY, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    username TEXT NOT NULL,
                    nas_url TEXT NOT NULL DEFAULT '',
                    credential BLOB NOT NULL,
                    csrf TEXT NOT NULL,
                    created REAL NOT NULL,
                    rotated REAL NOT NULL,
                    last_seen REAL NOT NULL,
                    expires REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS sessions_expires ON sessions(expires);
                CREATE TABLE IF NOT EXISTS session_aliases (
                    old_hash TEXT PRIMARY KEY, current_hash TEXT NOT NULL,
                    token BLOB NOT NULL, expires REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS aliases_current ON session_aliases(current_hash);
                CREATE TABLE IF NOT EXISTS write_operations (
                    operation_id TEXT PRIMARY KEY,
                    owner TEXT NOT NULL,
                    target TEXT NOT NULL,
                    note_id TEXT,
                    title TEXT NOT NULL,
                    intent BLOB NOT NULL,
                    status TEXT NOT NULL,
                    created REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS writes_owner_target
                    ON write_operations(owner, target, status);
                -- One active reservation per NAS account and target, including
                -- databases created before reservations were introduced.
                CREATE TABLE IF NOT EXISTS write_target_locks (
                    owner TEXT NOT NULL,
                    target TEXT NOT NULL,
                    PRIMARY KEY (owner, target)
                );
                INSERT OR IGNORE INTO write_target_locks(owner, target)
                    SELECT DISTINCT owner, target FROM write_operations
                    WHERE status IN ('pending', 'uncertain');
                CREATE TABLE IF NOT EXISTS create_receipts (
                    owner TEXT NOT NULL, client_request_id TEXT NOT NULL,
                    request_hash TEXT NOT NULL, operation_id TEXT NOT NULL,
                    status TEXT NOT NULL, result BLOB,
                    PRIMARY KEY(owner, client_request_id)
                );
                CREATE INDEX IF NOT EXISTS create_receipts_operation ON create_receipts(operation_id);
                CREATE TABLE IF NOT EXISTS draft_uploads (
                    upload_key TEXT PRIMARY KEY,
                    owner TEXT NOT NULL,
                    draft_id TEXT NOT NULL,
                    upload_id TEXT NOT NULL,
                    target TEXT NOT NULL,
                    notebook_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    received INTEGER NOT NULL DEFAULT 0,
                    sha256 TEXT,
                    mime TEXT NOT NULL DEFAULT 'application/octet-stream',
                    image INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'receiving',
                    expires REAL,
                    operation_id TEXT,
                    UNIQUE(owner, draft_id, upload_id)
                );
                CREATE INDEX IF NOT EXISTS uploads_expiry ON draft_uploads(expires);
                CREATE INDEX IF NOT EXISTS uploads_operation ON draft_uploads(operation_id)
                    WHERE operation_id IS NOT NULL;
                CREATE INDEX IF NOT EXISTS uploads_quota ON draft_uploads(owner, draft_id, size, expires)
                    WHERE status != 'committed';
                CREATE TABLE IF NOT EXISTS draft_upload_leases (
                    upload_key TEXT PRIMARY KEY REFERENCES draft_uploads(upload_key) ON DELETE CASCADE,
                    lease_id TEXT NOT NULL,
                    expires REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS draft_upload_chunks (
                    upload_key TEXT NOT NULL REFERENCES draft_uploads(upload_key) ON DELETE CASCADE,
                    offset INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY(upload_key, offset)
                ) WITHOUT ROWID;
            """)
            # Support databases created by the initial development build.
            columns = {row["name"] for row in db.execute("PRAGMA table_info(sessions)")}
            if "nas_url" not in columns:
                db.execute("ALTER TABLE sessions ADD COLUMN nas_url TEXT NOT NULL DEFAULT ''")
        self.db.chmod(0o600)

    @contextmanager
    def connect(self, *, thread_bound: bool = True) -> Iterator[sqlite3.Connection]:
        db: sqlite3.Connection | None = None
        try:
            db = sqlite3.connect(self.db, timeout=5, check_same_thread=thread_bound)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA foreign_keys=ON")
            with db:
                yield db
        except sqlite3.Error as exc:
            raise StoreError("SQLite storage is unavailable") from exc
        finally:
            if db is not None:
                db.close()

    def nas_url(self) -> str | None:
        with self.connect() as db:
            row = db.execute("SELECT value FROM config WHERE name='nas_url'").fetchone()
            return row["value"] if row else None

    def set_first_nas_url(self, url: str) -> bool:
        with self.connect() as db:
            result = db.execute("INSERT OR IGNORE INTO config(name,value) VALUES ('nas_url',?)", (url,))
            return result.rowcount == 1

    def bind_nas(self, url: str) -> None:
        """Invalidate saved credentials whenever the effective NAS changes."""
        with self.connect() as db:
            row = db.execute("SELECT value FROM config WHERE name='active_nas_url'").fetchone()
            if row is None or row["value"] != url:
                db.execute("INSERT OR REPLACE INTO config(name,value) VALUES ('active_nas_url',?)", (url,))
                db.execute("DELETE FROM sessions")
                db.execute('DELETE FROM session_aliases')

    def setup_code(self) -> str:
        path = self.dir / "setup-code"
        if not path.exists():
            _create_secret(path, secrets.token_urlsafe(32).encode("ascii") + b"\n")
        try:
            return _private_file(path).decode("ascii").strip()
        except UnicodeError as exc:
            raise StoreError("Invalid setup code file") from exc

    def clear_setup_code(self) -> None:
        path = self.dir / "setup-code"
        if path.is_symlink():
            raise StoreError("Setup code cannot be a symlink")
        path.unlink(missing_ok=True)

    def encrypt_credential(self, password: str, device_id: str | None, trust_device: bool) -> bytes:
        return self.cipher.encrypt(json.dumps({"password": password, "device_id": device_id,
                                              "trust_device": trust_device}).encode())

    def decrypt_credential(self, credential: bytes) -> dict:
        try:
            data = json.loads(self.cipher.decrypt(credential))
            if (not isinstance(data, dict) or not isinstance(data.get("password"), str)
                    or not isinstance(data.get("trust_device"), bool)
                    or (data.get("device_id") is not None
                        and not isinstance(data["device_id"], str))):
                raise ValueError()
            return data
        except (InvalidToken, ValueError, TypeError, AttributeError, KeyError) as exc:
            raise StoreError("Stored credential cannot be decrypted") from exc

    def save_session(self, token: str, username: str, nas_url: str, credential: bytes,
                     csrf: str, expires: float, now: float) -> None:
        with self.connect() as db:
            db.execute("DELETE FROM sessions WHERE expires<=?", (now,))
            db.execute("""INSERT INTO sessions
                (token_hash, username, nas_url, credential, csrf, created, rotated, last_seen, expires)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (token_hash(token), username, nas_url, credential, csrf, now, now, now, expires))

    def session(self, token: str, nas_url: str, now: float, idle_seconds: int) -> PersistedSession | None:
        digest = token_hash(token)
        with self.connect() as db:
            row = db.execute("SELECT * FROM sessions WHERE token_hash=?", (digest,)).fetchone()
            if not row:
                return None
            if (row["nas_url"] != nas_url or row["expires"] <= now
                    or row["last_seen"] + idle_seconds <= now):
                db.execute("DELETE FROM sessions WHERE token_hash=?", (digest,))
                return None
            db.execute("UPDATE sessions SET last_seen=? WHERE token_hash=?", (now, digest))
            return PersistedSession(**dict(row))

    def rotate_session(self, old_token: str, new_token: str, now: float) -> bool:
        old_hash, new_hash = token_hash(old_token), token_hash(new_token)
        encrypted = self.cipher.encrypt(new_token.encode())
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM session_aliases WHERE expires<=? OR current_hash NOT IN (SELECT token_hash FROM sessions)', (now,))
            result = db.execute("UPDATE sessions SET token_hash=?, rotated=? WHERE token_hash=?",
                                (new_hash, now, old_hash))
            if result.rowcount == 1:
                # Aliases never form chains and retaining an alias never extends
                # its original grace deadline, even with rapid rotations.
                db.execute('UPDATE session_aliases SET current_hash=?,token=? WHERE current_hash=?',
                           (new_hash, encrypted, old_hash))
                db.execute('INSERT INTO session_aliases VALUES(?,?,?,?)', (old_hash, new_hash, encrypted, now + 30))
                db.execute('DELETE FROM session_aliases WHERE current_hash=? AND old_hash NOT IN '
                           '(SELECT old_hash FROM session_aliases WHERE current_hash=? ORDER BY expires DESC LIMIT 8)',
                           (new_hash, new_hash))
            return result.rowcount == 1

    def resolve_session_alias(self, token: str, nas_url: str, now: float, idle_seconds: int) -> str | None:
        with self.connect() as db:
            row = db.execute('''SELECT a.token,a.current_hash FROM session_aliases a
                JOIN sessions s ON s.token_hash=a.current_hash
                WHERE a.old_hash=? AND a.expires>? AND s.nas_url=? AND s.expires>?
                    AND s.last_seen+?>?''', (token_hash(token), now, nas_url, now, idle_seconds, now)).fetchone()
        if row is None: return None
        try:
            canonical = self.cipher.decrypt(row['token']).decode('ascii')
            if token_hash(canonical) != row['current_hash']: raise ValueError()
            return canonical
        except (InvalidToken, UnicodeError, ValueError) as exc:
            raise StoreError('Session alias is unreadable') from exc

    def revoke(self, token: str) -> str:
        digest = token_hash(token)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            alias = db.execute('SELECT current_hash FROM session_aliases WHERE old_hash=?', (digest,)).fetchone()
            current = alias['current_hash'] if alias else digest
            db.execute('DELETE FROM session_aliases WHERE current_hash=? OR old_hash=?', (current, digest))
            db.execute("DELETE FROM sessions WHERE token_hash=?", (current,))
            return current

    def update_credential(self, token: str, credential: bytes) -> None:
        with self.connect() as db:
            db.execute("UPDATE sessions SET credential=? WHERE token_hash=?",
                       (credential, token_hash(token)))

    def start_write(self, operation_id: str, owner: str, target: str,
                    note_id: str | None, title: str, intent: dict, *,
                    client_request_id: str | None = None, request_hash: str | None = None,
                    upload_keys: list[tuple[str, str, str, str, str]] | None = None) -> bool:
        """Durably record a one-shot mutation before sending it to the NAS."""
        encrypted = self.cipher.encrypt(json.dumps(intent, ensure_ascii=False).encode())
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            if client_request_id:
                if db.execute('SELECT 1 FROM create_receipts WHERE owner=? AND client_request_id=?',
                              (owner, client_request_id)).fetchone():
                    return False
                # Keep keys/tombstones permanently: an expired key must never
                # silently become permission to repeat an unknown NAS create.
                if db.execute('SELECT COUNT(*) FROM create_receipts WHERE owner=?', (owner,)).fetchone()[0] >= 10000:
                    raise StoreError('Create receipt ledger is full')
            # INSERT obtains SQLite's writer lock. A second process cannot
            # reserve this target while the first reservation is committing.
            reserved = db.execute("""INSERT OR IGNORE INTO write_target_locks(owner, target)
                VALUES (?, ?)""", (owner, target))
            if reserved.rowcount != 1:
                return False
            db.execute("""INSERT INTO write_operations
                (operation_id, owner, target, note_id, title, intent, status, created)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)""",
                (operation_id, owner, target, note_id, title, encrypted, time.time()))
            if upload_keys:
                from .attachment_uploads import _pin_uploads

                upload_target = note_id if note_id is not None else f"draft-create:{client_request_id}"
                _pin_uploads(db, operation_id, owner, upload_target,
                             intent.get("notebook_id"), upload_keys)
            if client_request_id:
                db.execute('INSERT INTO create_receipts VALUES(?,?,?,?,?,NULL)',
                           (owner, client_request_id, request_hash, operation_id, 'pending'))
        return True

    def create_receipt(self, owner: str, client_request_id: str) -> dict:
        with self.connect() as db:
            row = db.execute('SELECT * FROM create_receipts WHERE owner=? AND client_request_id=?',
                             (owner, client_request_id)).fetchone()
        if row is None:
            return {'status': 'absent'}
        result = dict(status=row['status'], operation_id=row['operation_id'], request_hash=row['request_hash'])
        if row['status'] == 'completed':
            try:
                result['note'] = json.loads(self.cipher.decrypt(row['result']))
                if not isinstance(result['note'], dict): raise ValueError()
            except (InvalidToken, ValueError, TypeError) as exc:
                raise StoreError('Create receipt is unreadable') from exc
        return result

    def finish_write(self, operation_id: str, *, uncertain: bool, result: dict | None = None) -> None:
        encrypted_result = self.cipher.encrypt(json.dumps(result, ensure_ascii=False).encode()) if result is not None else None
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT owner, target, status FROM write_operations WHERE operation_id=?",
                             (operation_id,)).fetchone()
            # A late worker must not modify a reviewed receipt after acknowledgement.
            if row is None:
                return
            if uncertain:
                db.execute("UPDATE write_operations SET status='uncertain' WHERE operation_id=?",
                           (operation_id,))
                db.execute("UPDATE create_receipts SET status='uncertain' WHERE operation_id=?", (operation_id,))
                return
            if encrypted_result is not None:
                db.execute("UPDATE create_receipts SET status='completed',result=? WHERE operation_id=?",
                           (encrypted_result, operation_id))
            elif row["status"] == "pending":
                db.execute('DELETE FROM create_receipts WHERE operation_id=?', (operation_id,))
            else:
                return
            from .attachment_uploads import _finish_uploads

            _finish_uploads(db, operation_id, verified=result is not None)
            db.execute("DELETE FROM write_operations WHERE operation_id=?", (operation_id,))
            self._release_target_if_clear(db, row["owner"], row["target"])

    @staticmethod
    def _release_target_if_clear(db: sqlite3.Connection, owner: str, target: str) -> None:
        db.execute("""DELETE FROM write_target_locks WHERE owner=? AND target=?
            AND NOT EXISTS (SELECT 1 FROM write_operations WHERE owner=? AND target=?
                AND status IN ('pending', 'uncertain'))""", (owner, target, owner, target))

    def pending_writes(self, owner: str) -> list[dict]:
        with self.connect() as db:
            return [dict(row) for row in db.execute("""SELECT operation_id, target,
                note_id, title, status, created FROM write_operations
                WHERE owner=? ORDER BY created DESC""", (owner,))]

    def acknowledge_write(self, owner: str, operation_id: str) -> bool:
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("""SELECT target FROM write_operations
                WHERE owner=? AND operation_id=? AND
                    (status='uncertain' OR (status='pending' AND created<=?))""",
                (owner, operation_id, time.time() - 3600)).fetchone()
            if not row:
                return False
            # Keep any pinned uploads as evidence until the NAS outcome is verified.
            db.execute("DELETE FROM write_operations WHERE owner=? AND operation_id=?",
                       (owner, operation_id))
            db.execute("UPDATE create_receipts SET status='reviewed' WHERE owner=? AND operation_id=?",
                       (owner, operation_id))
            self._release_target_if_clear(db, owner, row["target"])
            return True


    def load_graph_index(self, owner: str, versions: dict[str, str]) -> list[dict]:
        result = []
        with self.connect() as db:
            rows = db.execute('SELECT note_id, version, entry FROM graph_index WHERE owner=?', (owner,)).fetchall()
            deleted = [(owner, row['note_id']) for row in rows if row['note_id'] not in versions]
            db.executemany('DELETE FROM graph_index WHERE owner=? AND note_id=?', deleted)
        for row in rows:
            if versions.get(row['note_id']) != row['version']: continue
            try:
                entry = json.loads(self.cipher.decrypt(row['entry']))
                if isinstance(entry, dict) and entry.get('id') == row['note_id'] and entry.get('version') == row['version']:
                    result.append(entry)
            except (ValueError, TypeError, InvalidToken):
                continue
        return result

    def save_graph_index(self, owner: str, entry: dict) -> None:
        if entry.get('error') or entry.get('hidden') or not entry.get('version'): return
        encrypted = self.cipher.encrypt(json.dumps(entry, ensure_ascii=False).encode())
        with self.connect() as db:
            db.execute('INSERT OR REPLACE INTO graph_index(owner,note_id,version,entry) VALUES(?,?,?,?)',
                (owner, entry['id'], entry['version'], encrypted))
