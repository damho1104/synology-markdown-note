"""Byte-compatible v1-v3 Swift SourceEnvelope framing and SHA-256 fingerprints."""
from __future__ import annotations

import base64
from dataclasses import dataclass, field
import hashlib
import json
import math
import re
import uuid

from .errors import CLIError

HEADER = re.compile(rb"^<!-- synology-note-source:v([123]) ([A-Za-z0-9+/=]+) -->$")
FINGERPRINT = re.compile(r"^sha256-exact-v1:[0-9a-f]{64}$")
BLOCK_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
TOKEN = re.compile(r"^:::synology-block ([A-Za-z0-9_-]{1,128}) :::$")


def json_bytes(value: object) -> bytes:
    # Swift JSONEncoder(.sortedKeys) escapes '/' and encodes UTF-8 without spaces.
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).replace("/", "\\/").encode("utf-8")


def fingerprint(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return "sha256-exact-v1:" + hashlib.sha256(data).hexdigest()


def validate_blocks(markdown: str, blocks: list[dict]) -> bool:
    ids = [b.get("id") for b in blocks if isinstance(b, dict)]
    if len(ids) != len(blocks) or any(not isinstance(i, str) or not BLOCK_ID.fullmatch(i) for i in ids):
        return False
    if len(set(ids)) != len(ids) or any(set(b) != {"id", "html", "label"} or not isinstance(b["html"], str) or not isinstance(b["label"], str) for b in blocks):
        return False
    # Follow only paragraph tokens, avoiding code fences and inline-code literals.
    from markdown_it import MarkdownIt
    tokens = MarkdownIt("commonmark", {"html": True}).parse(markdown)
    seen: list[str] = []
    for index, token in enumerate(tokens):
        if token.type != "paragraph_open":
            continue
        inline = tokens[index + 1]
        if inline.type != "inline":
            return False
        text = inline.content.strip()
        match = TOKEN.fullmatch(text)
        if match:
            seen.append(match.group(1))
        elif any(line.lstrip().startswith(":::synology-block") for line in text.splitlines()):
            return False
    return len(seen) == len(set(seen)) and set(seen) == set(ids)


@dataclass(frozen=True)
class SourceEnvelope:
    document_id: str
    markdown: str
    body_fingerprint: str
    blocks: list[dict] = field(default_factory=list)
    operation_id: str | None = None
    is_staging: bool = False
    attachment_bindings: dict[str, str] = field(default_factory=dict)
    math_attachments: dict[str, dict] = field(default_factory=dict)

    @classmethod
    def make(cls, markdown: str, html: str, *, document_id: str | None = None, **kw: object) -> SourceEnvelope:
        return cls(document_id or str(uuid.uuid4()).upper(), markdown, fingerprint(html), **kw)

    def encode(self) -> bytes:
        try:
            uuid.UUID(self.document_id)
            if self.operation_id:
                uuid.UUID(self.operation_id)
        except ValueError as ex:
            raise CLIError("INVALID_SOURCE", "잘못된 문서/작업 UUID입니다.") from ex
        if not validate_blocks(self.markdown, self.blocks):
            raise CLIError("INVALID_SOURCE", "원문 보존 블록이 유효하지 않습니다.")
        version = 3 if self.math_attachments else (2 if self.operation_id or self.is_staging or self.attachment_bindings else 1)
        m: dict[str, object] = {
            "formatVersion": version, "fingerprintVersion": 1, "documentID": str(uuid.UUID(self.document_id)).upper(),
            "bodyFingerprint": self.body_fingerprint, "sourceFingerprint": fingerprint(self.markdown),
            "blocksFingerprint": fingerprint(json_bytes(self.blocks)), "blocks": self.blocks,
        }
        if self.operation_id:
            m["operationID"] = str(uuid.UUID(self.operation_id)).upper()
        if version >= 2:
            m.update(isStaging=self.is_staging, attachmentBindings=self.attachment_bindings,
                     bindingsFingerprint=fingerprint(json_bytes(self.attachment_bindings)))
        if version == 3:
            m.update(mathAttachments=self.math_attachments, mathFingerprint=fingerprint(json_bytes(self.math_attachments)))
        # Validate every field before publishing an envelope.
        self._validate(m, version)
        return (f"<!-- synology-note-source:v{version} " + base64.b64encode(json_bytes(m)).decode("ascii") + " -->\n").encode() + self.markdown.encode("utf-8")

    @staticmethod
    def _validate(m: dict, version: int) -> None:
        try:
            if type(m.get("formatVersion")) is not int or m["formatVersion"] != version or type(m.get("fingerprintVersion")) is not int or m["fingerprintVersion"] != 1:
                raise ValueError()
            uuid.UUID(m["documentID"])
            if "operationID" in m and m["operationID"] is not None:
                uuid.UUID(m["operationID"])
            if not all(isinstance(m[k], str) and FINGERPRINT.fullmatch(m[k]) for k in ("bodyFingerprint", "sourceFingerprint", "blocksFingerprint")):
                raise ValueError()
            if not isinstance(m["blocks"], list) or fingerprint(json_bytes(m["blocks"])) != m["blocksFingerprint"]:
                raise ValueError()
            if version >= 2:
                bindings = m["attachmentBindings"]
                if not isinstance(bindings, dict) or any(not isinstance(k, str) or not isinstance(v, str) or not v for k, v in bindings.items()):
                    raise ValueError()
                for k in bindings:
                    uuid.UUID(k)
                if type(m.get("isStaging")) is not bool or fingerprint(json_bytes(bindings)) != m["bindingsFingerprint"]:
                    raise ValueError()
            elif any(k in m for k in ("attachmentBindings", "mathAttachments", "isStaging")):
                raise ValueError()
            if version == 3:
                values = m["mathAttachments"]
                if not isinstance(values, dict) or fingerprint(json_bytes(values)) != m["mathFingerprint"]:
                    raise ValueError()
                for k, v in values.items():
                    uuid.UUID(k)
                    if not isinstance(v, dict) or not isinstance(v.get("key"), str) or not v["key"] or any(type(v.get(n)) not in (float, int) or not math.isfinite(v[n]) or not 0 < v[n] <= 8192 for n in ("width", "height")):
                        raise ValueError()
            elif "mathAttachments" in m:
                raise ValueError()
        except (KeyError, ValueError, TypeError, OverflowError) as ex:
            raise CLIError("INVALID_SOURCE", "원문 메타데이터나 지문이 손상되었습니다.") from ex

    @classmethod
    def decode(cls, data: bytes) -> SourceEnvelope:
        try:
            line, raw = data.split(b"\n", 1)
            match = HEADER.fullmatch(line)
            if not match:
                raise ValueError("header")
            version = int(match.group(1))
            m = json.loads(base64.b64decode(match.group(2), validate=True))
            if not isinstance(m, dict):
                raise ValueError("metadata")
            markdown = raw.decode("utf-8", errors="strict")
            cls._validate(m, version)
            if fingerprint(raw) != m["sourceFingerprint"] or not validate_blocks(markdown, m["blocks"]):
                raise ValueError("content")
            return cls(m["documentID"], markdown, m["bodyFingerprint"], m["blocks"],
                       m.get("operationID"), m.get("isStaging", False), m.get("attachmentBindings", {}), m.get("mathAttachments", {}))
        except (ValueError, UnicodeError, KeyError, TypeError, base64.binascii.Error) as ex:
            raise CLIError("INVALID_SOURCE", "원문 첨부가 유효하지 않습니다.") from ex

    def matches(self, html: str) -> bool:
        return not self.is_staging and self.body_fingerprint == fingerprint(html)
