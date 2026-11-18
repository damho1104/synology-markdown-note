"""Durable, encrypted, account-scoped storage for draft attachments."""

from __future__ import annotations

import hashlib
import secrets
import sqlite3
import time
import unicodedata
import uuid
import zlib
from contextlib import contextmanager
from dataclasses import dataclass, field
from itertools import chain, repeat
from typing import Iterator, Protocol

from cryptography.fernet import InvalidToken

from .store import Store, StoreError

MAX_UPLOAD_SIZE = 50_000_000
DRAFT_QUOTA = 150_000_000
OWNER_QUOTA = 300_000_000
INSTALLATION_QUOTA = 1_000_000_000
# Leave time for the API's 600-second deadline and cancellation cleanup.
RECEIVING_TTL = 630
OWNER_RECEIVING_LIMIT = 2
INSTALLATION_RECEIVING_LIMIT = 8
READY_TTL = 7 * 86400
REVIEWED_TTL = 7 * 86400
_CHUNK_SIZE = 256 * 1024
_MAX_IMAGE_RECORDS = 262_144
_BINARY = "application/octet-stream"
_METADATA = ("upload_id", "name", "size", "sha256", "mime", "image",
             "status", "target", "notebook_id", "draft_id")


class UploadError(Exception):
    def __init__(self, code: str, status: int):
        super().__init__(code)
        self.code = code
        self.status = status


class _Digest(Protocol):
    def update(self, data: bytes) -> None: ...
    def hexdigest(self) -> str: ...


@dataclass
class _Receipt:
    key: str
    lease: str
    size: int
    deadline: float
    replay: bool
    received: int = 0
    closed: bool = False
    digest: _Digest = field(default_factory=hashlib.sha256)


def _check_id(value: str) -> None:
    try:
        if str(uuid.UUID(value)) == value:
            return
    except (ValueError, TypeError, AttributeError):
        pass
    raise UploadError("INVALID_ID", 422)


def _name(value: str) -> str:
    cleaned = "".join("_" if char in "/\\" else char for char in value
                      if not unicodedata.category(char).startswith("C"))
    return cleaned.strip(" .")[:200] or "attachment"


def _metadata(row: sqlite3.Row) -> dict:
    result = {key: row[key] for key in _METADATA}
    result["image"] = bool(result["image"])
    return result


def _not_found() -> UploadError:
    return UploadError("UPLOAD_NOT_FOUND", 404)


def _pin_uploads(db: sqlite3.Connection, operation_id: str, owner: str,
                 target: str, notebook_id: str | None,
                 keys: list[tuple[str, str, str, str, str]]) -> None:
    now = time.time()
    for draft, upload, expected_target, expected_notebook, sha256 in keys:
        row = _lookup(db, owner, draft, upload, now)
        if (expected_target != target or (notebook_id is not None and notebook_id != expected_notebook)
                or row["target"] != expected_target or row["notebook_id"] != expected_notebook
                or row["sha256"] != sha256):
            raise UploadError("UPLOAD_MANIFEST_MISMATCH", 409)
        if row["status"] != "ready":
            raise UploadError("UPLOAD_NOT_READY", 409)
        db.execute("""UPDATE draft_uploads SET status='pinned', operation_id=?, expires=NULL
                      WHERE upload_key=?""", (operation_id, row["upload_key"]))


def _finish_uploads(db: sqlite3.Connection, operation_id: str, *,
                    verified: bool) -> None:
    if verified:
        db.execute("""DELETE FROM draft_upload_chunks WHERE upload_key IN
                      (SELECT upload_key FROM draft_uploads WHERE operation_id=?)""",
                   (operation_id,))
        # Keep a durable idempotency record after reclaiming the payload.
        db.execute("""UPDATE draft_uploads SET status='committed', operation_id=NULL
                      WHERE operation_id=?""", (operation_id,))
    else:
        db.execute("""UPDATE draft_uploads SET status='ready', operation_id=NULL, expires=?
                      WHERE operation_id=?""", (time.time() + READY_TTL, operation_id))


def _discard_reviewed(db: sqlite3.Connection, *, upload_key: str | None = None) -> None:
    condition, args = ("expires<=?", (time.time(),)) if upload_key is None else ("upload_key=?", (upload_key,))
    selector = f"status='reviewed' AND {condition}"
    db.execute(f"""DELETE FROM draft_upload_chunks WHERE upload_key IN
                   (SELECT upload_key FROM draft_uploads WHERE {selector})""", args)
    db.execute(f"""UPDATE draft_uploads SET status='discarded', expires=NULL,
                   name='', size=0, received=0, sha256=NULL, mime=?, image=0
                   WHERE {selector}""", (_BINARY, *args))


def _lookup(db: sqlite3.Connection, owner: str, draft_id: str, upload_id: str,
            now: float) -> sqlite3.Row:
    row = db.execute("""SELECT * FROM draft_uploads
                        WHERE owner=? AND draft_id=? AND upload_id=? AND status!='discarded'
                        AND (expires IS NULL OR expires>?)""",
                     (owner, draft_id, upload_id, now)).fetchone()
    if row is None:
        raise _not_found()
    return row


class Uploads:
    def __init__(self, store: Store):
        self.store = store

    @contextmanager
    def _connect(self, *, write: bool = False, thread_bound: bool = True) -> Iterator[sqlite3.Connection]:
        try:
            with self.store.connect(thread_bound=thread_bound) as db:
                db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
                yield db
        except StoreError as exc:
            raise UploadError("UPLOAD_STORAGE_UNAVAILABLE", 503) from exc

    def reserve(self, owner: str, draft_id: str, upload_id: str, target: str,
                notebook_id: str, name: str, size: int) -> _Receipt:
        _check_id(draft_id)
        _check_id(upload_id)
        if size <= 0:
            raise UploadError("INVALID_UPLOAD_SIZE", 422)
        if size > MAX_UPLOAD_SIZE:
            raise UploadError("ATTACHMENT_TOO_LARGE", 413)
        name = _name(name)
        # Reap expired reservations and payloads independently of whether the
        # new reservation ultimately succeeds.
        with self._connect(write=True) as db:
            now = time.time()
            _discard_reviewed(db)
            db.execute("DELETE FROM draft_uploads WHERE expires<=? AND status!='reviewed'", (now,))
            db.execute("DELETE FROM draft_upload_leases WHERE expires<=?", (now,))
        with self._connect(write=True) as db:
            now = time.time()
            deadline = now + RECEIVING_TTL
            existing = db.execute("""SELECT * FROM draft_uploads
                                     WHERE owner=? AND draft_id=? AND upload_id=?""",
                                  (owner, draft_id, upload_id)).fetchone()
            if existing and existing["expires"] is not None and existing["expires"] <= now:
                if existing["status"] != "reviewed":
                    db.execute("DELETE FROM draft_uploads WHERE upload_key=?", (existing["upload_key"],))
                    existing = None
            if existing:
                if existing["status"] in ("reviewed", "discarded"):
                    raise UploadError("UPLOAD_ID_REUSED", 409)
                if (existing["target"], existing["notebook_id"], existing["name"],
                        existing["size"]) != (target, notebook_id, name, size):
                    raise UploadError("UPLOAD_ID_REUSED", 409)
                if db.execute("""SELECT 1 FROM draft_upload_leases
                                 WHERE upload_key=? AND expires>?""",
                              (existing["upload_key"], now)).fetchone():
                    raise UploadError("UPLOAD_RECEIVING", 409)
            account_slots, installation_slots = db.execute("""SELECT
                COUNT(*) FILTER (WHERE u.owner=?), COUNT(*)
                FROM draft_upload_leases AS l JOIN draft_uploads AS u USING (upload_key)
                WHERE l.expires>?""", (owner, now)).fetchone()
            if account_slots >= OWNER_RECEIVING_LIMIT or installation_slots >= INSTALLATION_RECEIVING_LIMIT:
                raise UploadError("UPLOAD_RECEIVING_LIMIT", 429)
            if existing is None:
                counts = db.execute("""SELECT
                    COALESCE(SUM(size) FILTER (WHERE owner=? AND draft_id=?), 0),
                    COALESCE(SUM(size) FILTER (WHERE owner=?), 0), COALESCE(SUM(size), 0)
                    FROM draft_uploads WHERE status!='committed' AND status!='discarded'
                      AND (expires IS NULL OR expires>?)""", (owner, draft_id, owner, now)).fetchone()
                if any(used + size > quota for used, quota in
                       zip(counts, (DRAFT_QUOTA, OWNER_QUOTA, INSTALLATION_QUOTA))):
                    raise UploadError("UPLOAD_QUOTA_EXCEEDED", 413)
                key = secrets.token_hex(16)
                db.execute("""INSERT INTO draft_uploads
                    (upload_key, owner, draft_id, upload_id, target, notebook_id, name, size, expires)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                           (key, owner, draft_id, upload_id, target, notebook_id, name, size, deadline))
            else:
                # A retry only hashes the request body and reserves a receive slot.
                key = existing["upload_key"]
            lease = secrets.token_hex(16)
            db.execute("INSERT OR REPLACE INTO draft_upload_leases VALUES (?, ?, ?)",
                       (key, lease, deadline))
            return _Receipt(key, lease, size, deadline, replay=existing is not None)

    def append(self, receipt: _Receipt, chunk: bytes) -> None:
        self._check_receipt(receipt)
        first_offset = receipt.received
        total = first_offset + len(chunk)
        if total > MAX_UPLOAD_SIZE:
            raise UploadError("ATTACHMENT_TOO_LARGE", 413)
        if total > receipt.size:
            raise UploadError("UPLOAD_SIZE_MISMATCH", 422)
        if not chunk:
            return
        if not receipt.replay:
            with self._connect(write=True) as db:
                updated = db.execute("""UPDATE draft_uploads SET received=?
                    WHERE upload_key=? AND status='receiving' AND expires>? AND received=?""",
                    (total, receipt.key, time.time(), first_offset))
                if updated.rowcount != 1:
                    raise _not_found()
                for start in range(0, len(chunk), _CHUNK_SIZE):
                    offset = first_offset + start
                    data = self.store.cipher.encrypt(
                        self._chunk_context(receipt.key, offset) + chunk[start:start + _CHUNK_SIZE])
                    db.execute("INSERT INTO draft_upload_chunks VALUES (?, ?, ?)",
                               (receipt.key, offset, data))
        receipt.digest.update(chunk)
        receipt.received = total

    def publish(self, receipt: _Receipt) -> dict:
        self._check_receipt(receipt)
        if receipt.received != receipt.size:
            raise UploadError("UPLOAD_SIZE_MISMATCH", 422)
        digest = receipt.digest.hexdigest()
        if not receipt.replay:
            # Validate from a read snapshot without holding SQLite's writer lock.
            with self._connect() as db:
                self._leased_row(db, receipt)
                mime = _image_mime(_Reader(self._chunks(db, receipt.key, receipt.size)))
        with self._connect(write=True) as db:
            row = self._leased_row(db, receipt)
            if receipt.replay:
                if row["sha256"] != digest:
                    raise UploadError("UPLOAD_ID_REUSED", 409)
            elif row["status"] == "receiving" and row["received"] == receipt.size:
                db.execute("""UPDATE draft_uploads SET status='ready', sha256=?, mime=?, image=?,
                    expires=? WHERE upload_key=?""",
                    (digest, mime, int(mime != _BINARY), time.time() + READY_TTL, receipt.key))
                row = db.execute("SELECT * FROM draft_uploads WHERE upload_key=?",
                                 (receipt.key,)).fetchone()
            else:
                raise _not_found()
            db.execute("DELETE FROM draft_upload_leases WHERE upload_key=?", (receipt.key,))
        receipt.closed = True
        return _metadata(row)

    def abort(self, receipt: _Receipt) -> None:
        if not receipt.closed:
            with self._connect(write=True) as db:
                removed = db.execute("DELETE FROM draft_upload_leases WHERE upload_key=? AND lease_id=?",
                                     (receipt.key, receipt.lease))
                if removed.rowcount == 1 and not receipt.replay:
                    db.execute("DELETE FROM draft_uploads WHERE upload_key=? AND status='receiving'",
                               (receipt.key,))
        receipt.closed = True

    def get(self, owner: str, draft_id: str, upload_id: str) -> dict:
        with self._connect() as db:
            return _metadata(_lookup(db, owner, draft_id, upload_id, time.time()))

    def delete(self, owner: str, draft_id: str, upload_id: str) -> None:
        with self._connect(write=True) as db:
            row = _lookup(db, owner, draft_id, upload_id, time.time())
            if row["status"] in ("pinned", "committed"):
                raise UploadError("UPLOAD_PINNED", 409)
            if row["status"] == "reviewed":
                _discard_reviewed(db, upload_key=row["upload_key"])
            else:
                db.execute("DELETE FROM draft_uploads WHERE upload_key=?", (row["upload_key"],))

    def iter_content(self, owner: str, draft_id: str, upload_id: str) -> Iterator[bytes]:
        # The streaming response steps this read-only iterator sequentially,
        # but each step may use a different worker thread.
        with self._connect(thread_bound=False) as db:
            row = _lookup(db, owner, draft_id, upload_id, time.time())
            if row["status"] not in ("ready", "pinned", "reviewed"):
                raise _not_found()
            yield from self._chunks(db, row["upload_key"], row["size"])

    @staticmethod
    def _leased_row(db: sqlite3.Connection, receipt: _Receipt) -> sqlite3.Row:
        now = time.time()
        row = db.execute("""SELECT u.* FROM draft_uploads AS u
            JOIN draft_upload_leases AS l USING (upload_key)
            WHERE u.upload_key=? AND l.lease_id=? AND l.expires>? AND u.status NOT IN ('reviewed', 'discarded')
              AND (u.expires IS NULL OR u.expires>?)""",
                         (receipt.key, receipt.lease, now, now)).fetchone()
        if row is None:
            raise _not_found()
        return row

    @staticmethod
    def _check_receipt(receipt: _Receipt) -> None:
        if receipt.closed or receipt.deadline <= time.time():
            raise _not_found()

    @staticmethod
    def _chunk_context(key: str, offset: int) -> bytes:
        return b"draft-upload\x00" + bytes.fromhex(key) + offset.to_bytes(8, "big")

    def _chunks(self, db: sqlite3.Connection, key: str, size: int) -> Iterator[bytes]:
        received = 0
        for row in db.execute("""SELECT offset, data FROM draft_upload_chunks
                                 WHERE upload_key=? ORDER BY offset""", (key,)):
            context = self._chunk_context(key, received)
            try:
                plaintext = self.store.cipher.decrypt(row["data"])
            except InvalidToken as exc:
                raise UploadError("UPLOAD_CONTENT_CORRUPT", 500) from exc
            chunk = plaintext[len(context):]
            if (row["offset"] != received or not plaintext.startswith(context)
                    or not chunk or len(chunk) > min(_CHUNK_SIZE, size - received)):
                raise UploadError("UPLOAD_CONTENT_CORRUPT", 500)
            received += len(chunk)
            yield chunk
        if received != size:
            raise UploadError("UPLOAD_CONTENT_CORRUPT", 500)


class _Reader:
    """Read image framing from authenticated chunks with bounded lookahead."""

    def __init__(self, chunks: Iterator[bytes]):
        self.chunks = chunks
        self.buffer = b""
        self.offset = 0
        self.position = 0
        self.records_left = _MAX_IMAGE_RECORDS

    def record(self) -> None:
        self.records_left -= 1
        if self.records_left < 0:
            raise ValueError("Image structure exceeds validation budget")

    def peek(self, size: int) -> bytes:
        if len(self.buffer) - self.offset < size:
            self.buffer = self.buffer[self.offset:]
            self.offset = 0
            while len(self.buffer) < size:
                more = next(self.chunks, b"")
                if not more:
                    break
                self.buffer += more
        return self.buffer[self.offset:self.offset + size]

    def read(self, size: int) -> bytes:
        result = self.peek(size)
        if len(result) != size:
            raise ValueError("Truncated image")
        self.position += size
        self.offset += size
        return result

    def blocks(self, size: int) -> Iterator[bytes]:
        while size:
            chunk = self.read(min(size, 64 * 1024))
            size -= len(chunk)
            yield chunk

    def skip(self, size: int) -> None:
        for _ in self.blocks(size):
            pass

    def jpeg_marker(self) -> int:
        # Skip entropy bytes up to the next marker and accept stuffed FF bytes
        # and restart markers encountered inside a scan.
        while self.peek(1):
            index = self.buffer.find(b"\xff", self.offset)
            end = index if index >= 0 else len(self.buffer)
            length = end - self.offset
            self.offset = end
            self.position += length
            if index < 0:
                continue
            self.record()
            self.read(1)
            code = self.read(1)[0]
            while code == 0xFF:
                self.record()
                code = self.read(1)[0]
            if code != 0 and not 0xD0 <= code <= 0xD7:
                return code
        raise ValueError("Missing JPEG end marker")


def _dimensions(width: int, height: int) -> None:
    if not (0 < width <= 8192 and 0 < height <= 8192 and width * height <= 32_000_000):
        raise ValueError("Unsafe image dimensions")


def _number(data: bytes, order: str = "big") -> int:
    return int.from_bytes(data, order)


def _png(reader: _Reader) -> None:
    reader.read(8)
    expected = 0
    decoded = 0
    decoder = zlib.decompressobj()
    row_lengths = iter(())
    filter_offset = 0
    seen_data = False
    after_data = False
    seen_palette = False
    color = -1
    while True:
        reader.record()
        size = _number(reader.read(4))
        tag = reader.read(4)
        if size > MAX_UPLOAD_SIZE or (not expected and (tag != b"IHDR" or size != 13)):
            raise ValueError("Invalid PNG chunk")
        crc = zlib.crc32(tag)
        if tag == b"IHDR":
            if expected:
                raise ValueError("Duplicate PNG header")
            header = reader.read(13)
            crc = zlib.crc32(header, crc)
            width, height = _number(header[:4]), _number(header[4:8])
            _dimensions(width, height)
            depth, color, compression, filtering, interlace = header[8:]
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8),
                      4: (8, 16), 6: (8, 16)}
            if depth not in depths.get(color, ()) or compression or filtering or interlace not in (0, 1):
                raise ValueError("Invalid PNG header")
            channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
            passes = ((0, 0, 1, 1),) if not interlace else (
                (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
            row_groups = []
            for x, y, dx, dy in passes:
                columns, rows = (width - x + dx - 1) // dx, (height - y + dy - 1) // dy
                if columns > 0 and rows > 0:
                    stride = 1 + (columns * channels * depth + 7) // 8
                    expected += rows * stride
                    row_groups.append(repeat(stride, rows))
            row_lengths = chain.from_iterable(row_groups)
        else:
            if tag == b"IDAT":
                if after_data or (color == 3 and not seen_palette):
                    raise ValueError("Out-of-order PNG image data")
                seen_data = True
            elif seen_data:
                after_data = True
            if tag == b"PLTE":
                if seen_palette or seen_data or not 0 < size <= 768 or size % 3:
                    raise ValueError("Invalid PNG palette")
                seen_palette = True
            for block in reader.blocks(size):
                crc = zlib.crc32(block, crc)
                if tag == b"IDAT":
                    compressed = block
                    while compressed:
                        data = decoder.decompress(compressed, 64 * 1024)
                        end = decoded + len(data)
                        if end > expected or decoder.unused_data:
                            raise ValueError("Invalid PNG image data")
                        while filter_offset < end:
                            if data[filter_offset - decoded] > 4:
                                raise ValueError("Invalid PNG row filter")
                            filter_offset += next(row_lengths)
                        decoded = end
                        compressed = decoder.unconsumed_tail
        if _number(reader.read(4)) != crc:
            raise ValueError("Invalid PNG checksum")
        if tag == b"IEND":
            if size or not seen_data or not decoder.eof or decoded != expected:
                raise ValueError("Incomplete PNG")
            return


def _jpeg(reader: _Reader) -> None:
    reader.read(2)
    dimensions = False
    scanned = False
    marker = None
    # Common sequential, extended sequential, and progressive JPEG.
    while True:
        reader.record()
        if marker is None:
            if reader.read(1) != b"\xff":
                raise ValueError("Missing JPEG marker")
            marker = reader.read(1)[0]
            while marker == 0xFF:
                reader.record()
                marker = reader.read(1)[0]
        if marker == 0xD9:
            if dimensions and scanned:
                return
            raise ValueError("Incomplete JPEG")
        if marker in (0, 1, 0xD8) or 0xD0 <= marker <= 0xD7:
            raise ValueError("Unexpected JPEG marker")
        size = _number(reader.read(2)) - 2
        if size < 0:
            raise ValueError("Invalid JPEG segment")
        if marker in (0xC0, 0xC1, 0xC2):
            if dimensions or size < 6:
                raise ValueError("Invalid JPEG frame")
            header = reader.read(6)
            _dimensions(_number(header[3:5]), _number(header[1:3]))
            if header[0] not in (8, 12) or header[5] not in (1, 3, 4) or size != 6 + 3 * header[5]:
                raise ValueError("Invalid JPEG frame")
            reader.skip(size - 6)
            dimensions = True
        elif marker == 0xDA:
            if not dimensions or size < 6:
                raise ValueError("Invalid JPEG scan")
            components = reader.read(1)[0]
            if components not in (1, 2, 3, 4) or size != 4 + 2 * components:
                raise ValueError("Invalid JPEG scan")
            reader.skip(size - 1)
            scan_start = reader.position
            marker = reader.jpeg_marker()
            if reader.position <= scan_start + 2:
                raise ValueError("Empty JPEG scan")
            scanned = True
            continue
        else:
            reader.skip(size)
        marker = None


def _gif_sub_blocks(reader: _Reader) -> bool:
    has_content = False
    while size := reader.read(1)[0]:
        reader.record()
        reader.skip(size)
        has_content = True
    return has_content


def _gif(reader: _Reader) -> None:
    reader.read(6)
    screen = reader.read(7)
    width, height = _number(screen[:2], "little"), _number(screen[2:4], "little")
    _dimensions(width, height)
    if screen[4] & 0x80:
        reader.skip(3 << ((screen[4] & 7) + 1))
    frames = False
    while True:
        reader.record()
        marker = reader.read(1)
        if marker == b";" and frames:
            return
        if marker == b"!":
            reader.read(1)
            _gif_sub_blocks(reader)
            continue
        if marker != b",":
            raise ValueError("Invalid GIF frame")
        x, y, columns, rows = [_number(reader.read(2), "little") for _ in range(4)]
        _dimensions(columns, rows)
        if x + columns > width or y + rows > height:
            raise ValueError("GIF frame outside canvas")
        flags = reader.read(1)[0]
        if flags & 0x80:
            reader.skip(3 << ((flags & 7) + 1))
        elif not screen[4] & 0x80:
            raise ValueError("Missing GIF palette")
        if not 2 <= reader.read(1)[0] <= 8 or not _gif_sub_blocks(reader):
            raise ValueError("Missing GIF image data")
        frames = True


def _webp_payload(reader: _Reader, tag: bytes, size: int) -> tuple[int, int]:
    if tag == b"VP8 " and size > 10:
        header = reader.read(10)
        frame = _number(header[:3], "little")
        if frame & 1 or header[3:6] != b"\x9d\x01\x2a" or frame >> 5 >= size - 10:
            raise ValueError("Invalid WebP VP8 frame")
        width = _number(header[6:8], "little") & 0x3FFF
        height = _number(header[8:10], "little") & 0x3FFF
        reader.skip(size - 10)
    elif tag == b"VP8L" and size > 5:
        header = reader.read(5)
        bits = _number(header[1:], "little")
        if header[0] != 0x2f or bits >> 29:
            raise ValueError("Invalid WebP lossless frame")
        width, height = (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        reader.skip(size - 5)
    else:
        raise ValueError("Invalid WebP frame")
    _dimensions(width, height)
    return width, height


def _webp_chunk(reader: _Reader, end: int) -> tuple[bytes, int, int]:
    reader.record()
    header = reader.read(8)
    size = _number(header[4:], "little")
    next_chunk = reader.position + size + (size % 2)
    if next_chunk > end:
        raise ValueError("Invalid WebP chunk length")
    return header[:4], size, next_chunk


def _webp(reader: _Reader) -> None:
    header = reader.read(12)
    end = _number(header[4:8], "little") + 8
    if not 20 < end <= MAX_UPLOAD_SIZE or end % 2:
        raise ValueError("Invalid WebP length")
    width = height = 0
    animated = animation_header = False
    frames = 0
    while reader.position < end:
        tag, size, next_chunk = _webp_chunk(reader, end)
        if tag == b"VP8X":
            if reader.position != 20 or size != 10:
                raise ValueError("Invalid WebP extended header")
            data = reader.read(10)
            animated = bool(data[0] & 2)
            width = 1 + _number(data[4:7], "little")
            height = 1 + _number(data[7:10], "little")
            _dimensions(width, height)
        elif tag == b"ANIM":
            if not animated or animation_header or size != 6:
                raise ValueError("Invalid WebP animation header")
            reader.skip(size)
            animation_header = True
        elif tag == b"ANMF":
            if not animation_header or size < 24:
                raise ValueError("Invalid WebP animation frame")
            frame_end = reader.position + size
            data = reader.read(16)
            x, y = 2 * _number(data[:3], "little"), 2 * _number(data[3:6], "little")
            columns = 1 + _number(data[6:9], "little")
            rows = 1 + _number(data[9:12], "little")
            if x + columns > width or y + rows > height:
                raise ValueError("WebP frame outside canvas")
            frame_seen = False
            while reader.position < frame_end:
                child_tag, child_size, child_end = _webp_chunk(reader, frame_end)
                if frame_seen or child_tag not in (b"ALPH", b"VP8 ", b"VP8L"):
                    raise ValueError("Invalid WebP animation payload")
                if child_tag != b"ALPH":
                    frame_seen = True
                    if _webp_payload(reader, child_tag, child_size) != (columns, rows):
                        raise ValueError("WebP frame dimensions mismatch")
                reader.skip(child_end - reader.position)
            if not frame_seen:
                raise ValueError("Missing WebP image data")
            frames += 1
        elif tag in (b"VP8 ", b"VP8L"):
            if animated or frames:
                raise ValueError("Unexpected WebP image data")
            dimensions = _webp_payload(reader, tag, size)
            if width and dimensions != (width, height):
                raise ValueError("WebP canvas dimensions mismatch")
            frames += 1
        else:
            reader.skip(size)
        reader.skip(next_chunk - reader.position)
    if not frames:
        raise ValueError("Incomplete WebP")


def _image_mime(reader: _Reader) -> str:
    header = reader.peek(12)
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        mime, parse = "image/png", _png
    elif header.startswith(b"\xff\xd8\xff"):
        mime, parse = "image/jpeg", _jpeg
    elif header.startswith((b"GIF87a", b"GIF89a")):
        mime, parse = "image/gif", _gif
    elif header.startswith(b"RIFF") and header[8:12] == b"WEBP":
        mime, parse = "image/webp", _webp
    else:
        return _BINARY
    try:
        parse(reader)
        return mime if not reader.peek(1) else _BINARY
    except (ValueError, zlib.error):
        return _BINARY
