"""Durable write journal; any lost write receipt remains uncertain until readback."""
from __future__ import annotations

import base64
import binascii
import json
import os
from pathlib import Path
import tempfile
import uuid

from .auth import state_dir
from .errors import CLIError


def journal_directory() -> Path:
    return state_dir() / "operations"


def save(record: dict) -> None:
    path = journal_directory()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    dest = path / (record["operation_id"] + ".json")
    fd, staging = tempfile.mkstemp(prefix=".journal-", dir=path)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(staging, dest)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)
    if os.name != "nt":
        dest.chmod(0o600)


def load(operation_id: str) -> dict:
    try:
        operation_id = str(uuid.UUID(operation_id))
        path = journal_directory() / (operation_id + ".json")
        record = json.loads(path.read_text(encoding="utf-8"))
        if record.get("operation_id") != operation_id:
            raise ValueError()
        return record
    except (OSError, ValueError, KeyError, TypeError) as ex:
        raise CLIError("NOT_FOUND", "Could not find the transfer operation record.") from ex


def done(record: dict) -> None:
    (journal_directory() / (record["operation_id"] + ".json")).unlink(missing_ok=True)


def status(api, operation_id: str) -> dict:
    """Reconcile safely with READS ONLY. Never resend a write from an unknown state."""
    from .transfers import verified_source

    record = load(operation_id)
    note_id = record.get("note_id")
    if note_id:
        note = api.fetch(note_id)
        if record.get("phase") in ("published", "publishing"):
            try:
                source, _, _ = verified_source(api, note)
                ids = {f["id"] for f in note.attachments}
                protected = record.get("protected_ids")
                stage_name = record.get("stage_name")
                complete = (
                    note.title == record.get("title")
                    and note.notebook_id == record.get("notebook_id")
                    and note.html == record.get("desired_html")
                    and isinstance(protected, list)
                    and all(isinstance(v, str) and v in ids for v in protected)
                    and isinstance(stage_name, str)
                    and not any(f["name"] == stage_name for f in note.attachments)
                    and (not record.get("old_source_id") or record["old_source_id"] not in ids)
                )
                if complete and source.operation_id and str(uuid.UUID(source.operation_id)) == operation_id and source.markdown == record["markdown"] and source.blocks == record.get("blocks", []):
                    done(record)
                    return {"operation_id": operation_id, "status": "confirmed", "note_id": note_id, "version": note.version}
            except CLIError as ex:
                if ex.code not in ("INVALID_SOURCE", "UNSUPPORTED_DOCUMENT_TYPE"):
                    raise
        return {"operation_id": operation_id, "status": "uncertain", "phase": record["phase"], "note_id": note_id,
                "remote_version": note.version, "requires_review": True}
    # Lost create response: a matching title alone is never proof of ownership.
    matches = []
    try:
        stage = base64.b64decode(record["stage_bytes"], validate=True)
        if not stage:
            raise ValueError("empty stage")
    except (KeyError, ValueError, TypeError, binascii.Error) as ex:
        raise CLIError("INVALID_SOURCE", "The staging source in the transfer journal is corrupt.") from ex
    for candidate in api.notes():
        if candidate["title"] != record["title"] or candidate["notebook_id"] != record["notebook_id"]:
            continue
        note = api.fetch(candidate["id"])
        for attachment in note.attachments:
            if attachment["name"] == record["stage_name"] and api.download(attachment["id"], note.id) == stage:
                matches.append(note.id)
    if len(set(matches)) == 1:
        record["note_id"] = matches[0]
        record["phase"] = "staging_ack_unknown"
        save(record)
    return {"operation_id": operation_id, "status": "uncertain", "phase": record["phase"],
            "candidate_note_ids": sorted(set(matches)), "requires_review": True}
