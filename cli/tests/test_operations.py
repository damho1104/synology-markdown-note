from dataclasses import replace
import uuid

from synonote_cli import operations, transfers
from synonote_cli.errors import CLIError
from synonote_cli.source_envelope import SourceEnvelope
from test_transfers import FakeNAS, file, transfer
import pytest


def published_operation(monkeypatch, tmp_path):
    monkeypatch.setattr(operations, "journal_directory", lambda: tmp_path / "operations")
    api = FakeNAS(extras=True)
    operation_id = str(uuid.uuid4())
    original = api.current
    markdown = "# new\n"
    final = SourceEnvelope.make(markdown, original.html, operation_id=operation_id).encode()
    api.files["final-source"] = final
    api.files["stage"] = b"temporary source"
    api.current = replace(original, attachments=[
        {"id": "final-source", "name": "synology-note-source-new.md"},
        {"id": "stage", "name": "synology-note-upload-staged.md"},
        {"id": "user-asset", "name": "important.png"},
    ])
    record = {
        "operation_id": operation_id, "note_id": "n1", "markdown": markdown,
        "desired_html": original.html, "phase": "publishing", "title": "report",
        "notebook_id": "nb", "stage_name": "synology-note-upload-staged.md",
        "old_source_id": "old-source", "protected_ids": ["user-asset"],
    }
    operations.save(record)
    return api, record


def test_recovery_requires_temporary_upload_to_be_removed(monkeypatch, tmp_path):
    api, record = published_operation(monkeypatch, tmp_path)
    result = operations.status(api, record["operation_id"])
    assert result["status"] == "uncertain"
    assert api.current.attachments[1]["id"] == "stage"
    assert operations.load(record["operation_id"])["phase"] == "publishing"

    api.current = replace(api.current, attachments=[v for v in api.current.attachments if v["id"] != "stage"])
    assert operations.status(api, record["operation_id"])["status"] == "confirmed"


def test_recovery_requires_original_user_attachments(monkeypatch, tmp_path):
    api, record = published_operation(monkeypatch, tmp_path)
    api.current = replace(api.current, attachments=[v for v in api.current.attachments if v["id"] not in ("stage", "user-asset")])
    assert operations.status(api, record["operation_id"])["status"] == "uncertain"


def test_recovery_requires_original_target_identity(monkeypatch, tmp_path):
    api, record = published_operation(monkeypatch, tmp_path)
    api.current = replace(api.current, title="renamed", attachments=[v for v in api.current.attachments if v["id"] != "stage"])
    assert operations.status(api, record["operation_id"])["status"] == "uncertain"


def test_lost_create_receipt_is_located_read_only_without_duplicate(monkeypatch, tmp_path):
    monkeypatch.setattr(operations, "journal_directory", lambda: tmp_path / "operations")
    monkeypatch.setattr(transfers, "save", operations.save)
    monkeypatch.setattr(transfers, "done", operations.done)
    api = FakeNAS()
    api.current = None
    original_write = api.write

    def commit_then_lose_receipt(**kwargs):
        result = original_write(**kwargs)
        if api.writes == 1:
            raise CLIError("TRANSPORT_ERROR", "create committed, receipt lost")
        return result

    api.write = commit_then_lose_receipt
    with pytest.raises(CLIError) as failure:
        transfer(api, file(tmp_path))
    assert failure.value.code == "WRITE_UNCERTAIN"
    operation_id = failure.value.details["operation_id"]
    assert operations.status(api, operation_id)["status"] == "uncertain"
    assert operations.load(operation_id)["note_id"] == "created"
    assert api.writes == 1
    assert len(api.notes()) == 1


def test_lost_final_receipt_can_be_confirmed_without_retry(monkeypatch, tmp_path):
    monkeypatch.setattr(operations, "journal_directory", lambda: tmp_path / "operations")
    monkeypatch.setattr(transfers, "save", operations.save)
    monkeypatch.setattr(transfers, "done", operations.done)
    api = FakeNAS(extras=True)
    original_write = api.write

    def lose_final_receipt(**kwargs):
        result = original_write(**kwargs)
        if api.writes == 3:
            raise CLIError("TRANSPORT_ERROR", "response lost after commit")
        return result

    api.write = lose_final_receipt
    with pytest.raises(CLIError) as error:
        transfer(api, file(tmp_path), overwrite=True)
    operation_id = error.value.details["operation_id"]
    assert error.value.code == "WRITE_UNCERTAIN"
    result = operations.status(api, operation_id)
    assert result["status"] == "confirmed"
    assert api.writes == 3
    with pytest.raises(CLIError) as missing:
        operations.load(operation_id)
    assert missing.value.code == "NOT_FOUND"


def test_corrupted_local_stage_receipt_returns_structured_error(monkeypatch, tmp_path):
    monkeypatch.setattr(operations, "journal_directory", lambda: tmp_path / "operations")
    api = FakeNAS()
    api.current = None
    operation_id = str(uuid.uuid4())
    operations.save({"operation_id": operation_id, "note_id": None, "phase": "staging",
                     "stage_bytes": "invalid base64!!!", "stage_name": "stage.md",
                     "title": "report", "notebook_id": "nb"})
    with pytest.raises(CLIError) as error:
        operations.status(api, operation_id)
    assert error.value.code == "INVALID_SOURCE"
