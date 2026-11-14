from dataclasses import replace
import json
from pathlib import Path
import uuid

import pytest

from synonote_cli.api import Note
from synonote_cli.errors import CLIError
from synonote_cli.source_envelope import SourceEnvelope
from synonote_cli import transfers


class FakeNAS:
    def __init__(self, *, html_only=False, duplicated=False, extras=False):
        self.seq = 0
        self.writes = 0
        self.files = {}
        self.current = None
        self.fail_at = None
        if html_only:
            self.current = Note("n1", "nb", "report", "1", "<p>HTML only</p>", [])
        else:
            content = "# old\n"
            html = "<h1>old</h1>\n"
            envelope = SourceEnvelope.make(content, html, document_id=str(uuid.uuid4())).encode()
            files = [{"id": "old-source", "name": "source.md"}]
            self.files["old-source"] = envelope
            if extras:
                files.append({"id": "user-asset", "name": "important.png"})
                self.files["user-asset"] = b"original user attachment"
            self.current = Note("n1", "nb", "report", "1", html, files)
        self.duplicated = duplicated

    def notebooks(self):
        return [{"id": "nb", "stack": "work", "name": "notes"}]

    def notes(self):
        if self.current is None:
            return []
        n = self.current
        row = {"id": n.id, "title": n.title, "notebook_id": n.notebook_id,
               "version": n.version, "trashed": n.trashed}
        return [row, dict(row, id="n2")] if self.duplicated else [row]

    def fetch(self, note_id):
        assert self.current is not None
        assert note_id == self.current.id
        return self.current

    def download(self, file_id, note_id):
        return self.files[file_id]

    def write(self, *, note_id=None, notebook_id=None, title=None, html=None,
              version=None, uploads=None, deleting=None):
        self.writes += 1
        if note_id:
            if version != self.current.version:
                raise CLIError("REMOTE_CHANGED", "stale version")
        else:
            assert self.current is None
            self.current = Note("created", notebook_id, title, "0", html, [])
        if self.fail_at == self.writes:
            raise CLIError("TRANSPORT_ERROR", "lost write receipt")
        updated = self.current
        files = list(updated.attachments)
        for file_id in deleting or []:
            files = [f for f in files if f["id"] != file_id]
            self.files.pop(file_id, None)
        for name, _mime, content in uploads or []:
            self.seq += 1
            fid = f"upload-{self.seq}"
            files.append({"id": fid, "name": name})
            self.files[fid] = content
        self.current = replace(updated, version=str(int(updated.version) + 1),
                               html=html if html is not None else updated.html, attachments=files)
        return self.current.id, self.current.version


def file(tmp_path, content="# new\n"):
    path = tmp_path / "report.md"
    path.write_text(content, encoding="utf-8")
    return path


def transfer(api, path, *, overwrite=False, compare_only=False):
    return transfers.upload(api, path, stack="work", notebook="notes", notebook_id=None,
                            title=None, note_id=None, overwrite=overwrite, compare_only=compare_only)


@pytest.fixture(autouse=True)
def isolated_journal(monkeypatch, tmp_path):
    monkeypatch.setattr(transfers, "save", lambda record: None)
    monkeypatch.setattr(transfers, "done", lambda record: None)


def test_duplicate_title_shows_diff_and_never_writes(tmp_path):
    api = FakeNAS()
    with pytest.raises(CLIError) as error:
        transfer(api, file(tmp_path))
    assert error.value.code == "TITLE_CONFLICT"
    assert "-# old" in error.value.details["diff"]
    assert "+# new" in error.value.details["diff"]
    assert api.writes == 0


def test_html_note_never_overwritten(tmp_path):
    api = FakeNAS(html_only=True)
    with pytest.raises(CLIError) as error:
        transfer(api, file(tmp_path), overwrite=True)
    assert error.value.code == "UNSUPPORTED_DOCUMENT_TYPE"
    assert api.writes == 0


def test_same_title_multiple_notes_never_overwritten(tmp_path):
    api = FakeNAS(duplicated=True)
    with pytest.raises(CLIError) as error:
        transfer(api, file(tmp_path), overwrite=True)
    assert error.value.code == "AMBIGUOUS_TARGET"
    assert api.writes == 0


def test_diff_only_does_not_create(tmp_path):
    api = FakeNAS()
    api.current = None
    assert transfer(api, file(tmp_path), compare_only=True)["status"] == "would_create"
    assert api.writes == 0


@pytest.mark.parametrize("extras", [False, True])
def test_overwrite_preserves_user_assets_and_cleans_internal_files(tmp_path, extras):
    api = FakeNAS(extras=extras)
    result = transfer(api, file(tmp_path), overwrite=True)
    assert result["status"] == "uploaded"
    assert api.writes == 3
    source, _, _ = transfers.verified_source(api, api.current)
    assert source.markdown == "# new\n"
    assert not any("synology-note-upload-" in f["name"] for f in api.current.attachments)
    assert "old-source" not in api.files
    if extras:
        assert api.files["user-asset"] == b"original user attachment"


@pytest.mark.parametrize("step", [1, 2, 3])
def test_lost_receipt_never_retries_writes(tmp_path, step):
    api = FakeNAS()
    api.fail_at = step
    with pytest.raises(CLIError) as error:
        transfer(api, file(tmp_path), overwrite=True)
    assert error.value.code == "WRITE_UNCERTAIN"
    assert error.value.details["operation_id"]
    assert api.writes == step


def test_invalid_local_utf8_rejected_without_writes(tmp_path):
    api = FakeNAS()
    path = tmp_path / "report.md"
    path.write_bytes(b"\xff")
    with pytest.raises(CLIError) as error:
        transfer(api, path, overwrite=True)
    assert error.value.code == "INVALID_ARGUMENT"
    assert api.writes == 0


def test_download_existing_local_file_does_not_replace(tmp_path):
    api = FakeNAS()
    target = file(tmp_path, "local content")
    with pytest.raises(CLIError) as error:
        transfers.download(api, "n1", target)
    assert error.value.code == "OUTPUT_EXISTS"
    assert target.read_text() == "local content"


def test_download_preserves_crlf_and_final_newline(tmp_path):
    api = FakeNAS()
    original = "---\r\na: 1\r\n---\r\n한글"
    source = SourceEnvelope.make(original, api.current.html).encode()
    api.files["old-source"] = source
    target = tmp_path / "download.md"
    transfers.download(api, "n1", target)
    assert target.read_bytes() == original.encode("utf-8")


def test_new_note_create_publishes_verified_markdown_and_cleans_stage(tmp_path):
    api = FakeNAS()
    api.current = None
    result = transfer(api, file(tmp_path))
    assert result["status"] == "uploaded"
    assert api.writes == 3
    assert api.current.title == "report" and api.current.notebook_id == "nb"
    assert len(api.current.attachments) == 1
    source, _, _ = transfers.verified_source(api, api.current)
    assert source.markdown == "# new\n" and source.matches(api.current.html)
    assert source.operation_id == result["operation_id"].upper()


def test_download_with_sidecar_rolls_back_if_second_file_publish_fails(monkeypatch, tmp_path):
    api = FakeNAS()
    markdown = "intro\n\n:::synology-block preserved :::\n"
    blocks = [{"id": "preserved", "html": "<p>kept</p>", "label": "원본"}]
    api.files["old-source"] = SourceEnvelope.make(markdown, api.current.html, blocks=blocks).encode()
    destination = tmp_path / "report.md"
    sidecar = tmp_path / "report.md.preserved.json"
    destination.write_bytes(b"original markdown")
    sidecar.write_bytes(b"original sidecar")
    original_replace = transfers.os.replace

    def failed_sidecar_replace(src, dest):
        if Path(dest) == sidecar and Path(src).name.startswith(".synonote-") and not Path(src).name.startswith(".synonote-backup-"):
            raise OSError("simulated file-publish error")
        return original_replace(src, dest)

    monkeypatch.setattr(transfers.os, "replace", failed_sidecar_replace)
    with pytest.raises(CLIError):
        transfers.download(api, "n1", destination, force=True)
    assert destination.read_bytes() == b"original markdown"
    assert sidecar.read_bytes() == b"original sidecar"
    assert list(tmp_path.glob(".synonote-*")) == []


def test_download_with_sidecar_replaces_all_files_and_removes_backups(tmp_path):
    api = FakeNAS()
    markdown = "intro\n\n:::synology-block preserved :::\n"
    blocks = [{"id": "preserved", "html": "<p>kept</p>", "label": "원본"}]
    api.files["old-source"] = SourceEnvelope.make(markdown, api.current.html, blocks=blocks).encode()
    destination = tmp_path / "report.md"
    sidecar = tmp_path / "report.md.preserved.json"
    destination.write_bytes(b"original markdown")
    sidecar.write_bytes(b"original sidecar")
    transfers.download(api, "n1", destination, force=True)
    assert destination.read_bytes() == markdown.encode("utf-8")
    assert b'"preserved"' in sidecar.read_bytes()
    assert list(tmp_path.glob(".synonote-*")) == []


def test_verified_source_surfaces_nas_download_failures():
    api = FakeNAS()
    def unavailable(_file_id, _note_id):
        raise CLIError("TRANSPORT_ERROR", "connection interrupted")
    api.download = unavailable
    with pytest.raises(CLIError) as error:
        transfers.verified_source(api, api.current)
    assert error.value.code == "TRANSPORT_ERROR"


def test_download_first_publish_failure_preserves_existing_files(monkeypatch, tmp_path):
    api = FakeNAS()
    destination = tmp_path / "report.md"
    destination.write_bytes(b"existing")
    original_replace = transfers.os.replace

    def fail_first_publish(src, dest):
        if Path(dest) == destination and Path(src).name.startswith(".synonote-"):
            raise OSError("first publish failed")
        return original_replace(src, dest)

    monkeypatch.setattr(transfers.os, "replace", fail_first_publish)
    with pytest.raises(CLIError):
        transfers.download(api, "n1", destination, force=True)
    assert destination.read_bytes() == b"existing"
    assert not list(tmp_path.glob(".synonote-*"))


def test_download_backup_copy_failure_preserves_existing_files(monkeypatch, tmp_path):
    api = FakeNAS()
    destination = tmp_path / "report.md"
    destination.write_bytes(b"existing")

    def fail_backup(_source, _destination):
        raise OSError("disk full creating backup")

    monkeypatch.setattr(transfers.shutil, "copyfileobj", fail_backup)
    with pytest.raises(CLIError):
        transfers.download(api, "n1", destination, force=True)
    assert destination.read_bytes() == b"existing"
    assert not list(tmp_path.glob(".synonote-*"))


def test_download_rollback_failure_retains_recovery_backup(monkeypatch, tmp_path):
    api = FakeNAS()
    markdown = "intro\n\n:::synology-block preserved :::\n"
    blocks = [{"id": "preserved", "html": "<p>kept</p>", "label": "원본"}]
    api.files["old-source"] = SourceEnvelope.make(markdown, api.current.html, blocks=blocks).encode()
    destination = tmp_path / "report.md"
    sidecar = tmp_path / "report.md.preserved.json"
    destination.write_bytes(b"original markdown")
    sidecar.write_bytes(b"original sidecar")
    original_replace = transfers.os.replace

    def fail_publish_and_restore(src, dest):
        if Path(dest) == sidecar and Path(src).name.startswith(".synonote-") and not Path(src).name.startswith(".synonote-backup-"):
            raise OSError("sidecar publish failed")
        if Path(dest) == destination and Path(src).name.startswith(".synonote-backup-"):
            raise OSError("rollback failed")
        return original_replace(src, dest)

    monkeypatch.setattr(transfers.os, "replace", fail_publish_and_restore)
    with pytest.raises(CLIError) as error:
        transfers.download(api, "n1", destination, force=True)
    assert error.value.code == "OUTPUT_EXISTS"
    paths = [Path(p) for p in error.value.details["backup_paths"]]
    assert paths and any(p.read_bytes() == b"original markdown" for p in paths)
    assert error.value.details["affected_paths"] == [str(destination)]
    assert sidecar.read_bytes() == b"original sidecar"


def test_download_rejects_symlink_swapped_while_preparing_backup(monkeypatch, tmp_path):
    api = FakeNAS()
    destination = tmp_path / "report.md"
    destination.write_bytes(b"existing")
    other_file = tmp_path / "private.md"
    other_file.write_bytes(b"private data")
    original_mkstemp = transfers.tempfile.mkstemp

    def swap_during_backup(*args, **kwargs):
        value = original_mkstemp(*args, **kwargs)
        if kwargs.get("prefix") == ".synonote-backup-":
            destination.unlink()
            destination.symlink_to(other_file)
        return value

    monkeypatch.setattr(transfers.tempfile, "mkstemp", swap_during_backup)
    with pytest.raises(CLIError) as error:
        transfers.download(api, "n1", destination, force=True)
    assert error.value.code == "INVALID_ARGUMENT"
    assert destination.is_symlink()
    assert other_file.read_bytes() == b"private data"


def test_final_write_detects_remote_title_change(tmp_path):
    api = FakeNAS()
    original_write = api.write

    def rename_during_final_write(**kwargs):
        result = original_write(**kwargs)
        if api.writes == 3:
            api.current = replace(api.current, title="modified by another client")
        return result

    api.write = rename_during_final_write
    with pytest.raises(CLIError) as error:
        transfer(api, file(tmp_path), overwrite=True)
    assert error.value.code == "WRITE_UNCERTAIN"
    assert api.writes == 3


def test_new_markdown_with_preserved_block_round_trips(tmp_path):
    api = FakeNAS()
    api.current = None
    markdown = "Intro\n\n:::synology-block original :::\n"
    blocks = [{"id": "original", "html": "<div lang=\"ko\">원문</div>", "label": "원본"}]
    path = file(tmp_path, markdown)
    path.with_name(path.name + ".preserved.json").write_text(json.dumps(blocks), encoding="utf-8")
    result = transfer(api, path)
    assert result["status"] == "uploaded"
    source, _, _ = transfers.verified_source(api, api.current)
    assert source.blocks == blocks
    assert source.markdown == markdown
    assert api.current.html == "<p>Intro</p>\n<div lang=\"ko\">원문</div>\n"


def test_preserved_block_change_is_a_conflict_even_if_markdown_unchanged(tmp_path):
    api = FakeNAS()
    markdown = "Intro\n\n:::synology-block original :::\n"
    original_blocks = [{"id": "original", "html": "<p>keep</p>", "label": "원본"}]
    changed_blocks = [{"id": "original", "html": "<p>changed</p>", "label": "원본"}]
    api.files["old-source"] = SourceEnvelope.make(markdown, api.current.html, blocks=original_blocks).encode()
    path = file(tmp_path, markdown)
    path.with_name(path.name + ".preserved.json").write_text(json.dumps(changed_blocks), encoding="utf-8")
    with pytest.raises(CLIError) as error:
        transfer(api, path)
    assert error.value.code == "TITLE_CONFLICT"
    assert "changed" in error.value.details["diff"]
    assert api.writes == 0


def test_download_without_blocks_rejects_stale_sidecar_without_force(tmp_path):
    api = FakeNAS()
    destination = tmp_path / "report.md"
    sidecar = tmp_path / "report.md.preserved.json"
    destination.write_bytes(b"previous markdown")
    sidecar.write_bytes(b"previous blocks")
    with pytest.raises(CLIError) as error:
        transfers.download(api, "n1", destination)
    assert error.value.code == "OUTPUT_EXISTS"
    assert destination.read_bytes() == b"previous markdown"
    assert sidecar.read_bytes() == b"previous blocks"
    transfers.download(api, "n1", destination, force=True)
    assert destination.read_bytes() == b"# old\n"
    assert not sidecar.exists()
    assert not list(tmp_path.glob(".synonote-*"))
