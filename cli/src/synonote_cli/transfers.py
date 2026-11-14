"""Collision checking, verified Markdown reads, guarded multi-stage NAS writes."""
from __future__ import annotations

import base64
import difflib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import unicodedata
import uuid

from .api import Note, NoteStationAPI
from .errors import CLIError
from .markdown import render
from .operations import save, done
from .source_envelope import SourceEnvelope, fingerprint, validate_blocks


ATTACH_REF = re.compile(r"attachment://([0-9a-fA-F-]{36})")


def verified_source(api: NoteStationAPI, note: Note) -> tuple[SourceEnvelope, str, list[str]]:
    if note.locked or note.trashed:
        raise CLIError("UNSUPPORTED_DOCUMENT_TYPE", "잠금/휴지통 노트는 Markdown으로 편집할 수 없습니다.")
    matches: list[tuple[SourceEnvelope, str]] = []
    for file in note.attachments:
        if not file["name"].endswith(".md"):
            continue
        content = api.download(file["id"], note.id)
        try:
            value = SourceEnvelope.decode(content)
        except CLIError:
            continue
        if value.matches(note.html):
            matches.append((value, file["id"]))
    if len(matches) != 1:
        raise CLIError("UNSUPPORTED_DOCUMENT_TYPE", "검증된 Markdown 원문 첨부가 정확히 하나여야 합니다.", candidates=len(matches))
    source, source_file_id = matches[0]
    # Check attachment bindings with the exact rules used by the Swift importer.
    for ref in set(ATTACH_REF.findall(source.markdown)) | set(source.math_attachments):
        try:
            normalized = uuid.UUID(ref)
        except ValueError as ex:
            raise CLIError("INVALID_SOURCE", "첨부파일 참조 UUID가 올바르지 않습니다.") from ex
        binding = next((v for k, v in source.attachment_bindings.items() if uuid.UUID(k) == normalized), None)
        candidates = [f for f in note.attachments if f["id"] == binding] if binding else [
            f for f in note.attachments if f["id"].lower() == str(normalized) or
            (f.get("ref") and _uuid_equal(f["ref"], normalized))]
        if len(candidates) != 1:
            raise CLIError("INVALID_SOURCE", "NAS 첨부파일을 유일하게 찾을 수 없습니다.")
        api.download(candidates[0]["id"], note.id)
    return source, source_file_id, [f["id"] for f in note.attachments]


def _uuid_equal(candidate: str, value: uuid.UUID) -> bool:
    try:
        return uuid.UUID(candidate) == value
    except ValueError:
        return False


def select_notebook(api: NoteStationAPI, *, stack: str | None, notebook: str | None, notebook_id: str | None) -> dict:
    books = api.notebooks()
    selected = [book for book in books if (notebook_id is None or book["id"] == notebook_id) and
                (notebook is None or book["name"] == notebook) and (stack is None or book["stack"] == stack)]
    if not (notebook_id or notebook):
        raise CLIError("INVALID_ARGUMENT", "--notebook 또는 --notebook-id 가 필요합니다.")
    if not selected:
        raise CLIError("NOT_FOUND", "대상 메모장을 찾지 못했습니다.")
    if len(selected) != 1:
        raise CLIError("AMBIGUOUS_TARGET", "같은 이름의 메모장이 여러 개입니다. --notebook-id를 사용하세요.", ids=[x["id"] for x in selected])
    return selected[0]


def select_note(api: NoteStationAPI, notebook_id: str, title: str, note_id: str | None = None) -> Note | None:
    name = unicodedata.normalize("NFC", title)
    summaries = [n for n in api.notes() if n["notebook_id"] == notebook_id and
                 unicodedata.normalize("NFC", n["title"]) == name and not n["trashed"]]
    if note_id:
        summaries = [n for n in summaries if n["id"] == note_id]
    if len(summaries) > 1:
        raise CLIError("AMBIGUOUS_TARGET", "동일한 제목의 노트가 여럿입니다.", ids=[v["id"] for v in summaries])
    return api.fetch(summaries[0]["id"]) if summaries else None


def diff(source: str, local: str, note_id: str, local_path: Path) -> str:
    return "".join(difflib.unified_diff(source.splitlines(keepends=True), local.splitlines(keepends=True),
                                        fromfile="NAS/" + note_id, tofile="LOCAL/" + str(local_path)))


def input_markdown(path: Path) -> tuple[str, list[dict]]:
    if path.suffix.lower() != ".md" or not path.is_file():
        raise CLIError("INVALID_ARGUMENT", "UTF-8 .md 파일만 업로드할 수 있습니다.")
    try:
        data = path.read_bytes()
        markdown = data.decode("utf-8", errors="strict")
    except (OSError, UnicodeError) as ex:
        raise CLIError("INVALID_ARGUMENT", "Markdown 파일을 읽을 수 없습니다.") from ex
    blocks_path = path.with_name(path.name + ".preserved.json")
    if blocks_path.exists():
        try:
            blocks = json.loads(blocks_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as ex:
            raise CLIError("INVALID_SOURCE", "보존 블록 sidecar를 읽을 수 없습니다.") from ex
    else:
        blocks = []
    if not validate_blocks(markdown, blocks):
        raise CLIError("INVALID_SOURCE", "원문 보존 블록의 참조가 유효하지 않습니다.")
    if any(ATTACH_REF.search(block["html"]) for block in blocks):
        raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "첨부 참조가 있는 보존 블록은 아직 지원되지 않습니다.")
    if ATTACH_REF.search(markdown) or re.search(r"!\[[^]]*\]\((?!https?://|data:)[^)]+\)", markdown):
        raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "로컬 이미지와 첨부 리소스 업로드는 아직 지원되지 않습니다.")
    return markdown, blocks


def download(api: NoteStationAPI, note_id: str, destination: Path, *, force: bool = False) -> dict:
    note = api.fetch(note_id)
    source, _, _ = verified_source(api, note)
    if ATTACH_REF.search(source.markdown) or source.math_attachments:
        raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "첨부 리소스가 있는 Markdown의 로컬 내보내기는 아직 지원되지 않습니다.")
    targets: dict[Path, bytes | None] = {destination: source.markdown.encode("utf-8")}
    sidecar = destination.with_name(destination.name + ".preserved.json")
    if source.blocks:
        targets[sidecar] = json.dumps(source.blocks, ensure_ascii=False, indent=2).encode("utf-8")
    elif sidecar.exists() or sidecar.is_symlink():
        # An old sidecar would make a later upload interpret the new source incorrectly.
        # Removing it is an explicit part of --force-local and uses the same rollback.
        targets[sidecar] = None
    if destination.suffix.lower() != ".md":
        raise CLIError("INVALID_ARGUMENT", "다운로드 경로는 .md 파일이어야 합니다.")
    if any(target.exists() for target in targets) and not force:
        raise CLIError("OUTPUT_EXISTS", "출력 파일이 이미 존재합니다. --force-local 옵션을 사용하세요.")
    for target in targets:
        if target.is_symlink() or not target.parent.is_dir() or (target.exists() and not target.is_file()):
            raise CLIError("INVALID_ARGUMENT", "출력 디렉터리가 없거나 심볼릭 링크가 존재합니다.")
    # Keep the identity of every destination stable while staging and backing up.
    # In particular, never follow a symlink substituted after the initial check.
    originals = {target: target.stat() if target.exists() else None for target in targets}

    def unchanged(target: Path) -> bool:
        before = originals[target]
        try:
            now = target.lstat()
        except FileNotFoundError:
            return before is None
        return (before is not None and stat.S_ISREG(now.st_mode)
                and (now.st_dev, now.st_ino, now.st_size, now.st_mtime_ns) ==
                    (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns))

    staged: dict[Path, str] = {}
    backups: dict[Path, str] = {}
    published: list[Path] = []
    retain_backups = False
    try:
        for target, content in targets.items():
            if content is None:
                continue
            fd, tmp = tempfile.mkstemp(prefix=".synonote-", dir=target.parent)
            staged[target] = tmp
            with os.fdopen(fd, "wb") as file:
                file.write(content)
                file.flush()
                os.fsync(file.fileno())
        # Keep original local files recoverable until every output is published.
        for target in targets:
            if not unchanged(target):
                raise OSError("local destination changed before backup")
            if originals[target] is not None:
                fd, backup = tempfile.mkstemp(prefix=".synonote-backup-", dir=target.parent)
                backups[target] = backup
                flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
                if os.name != "nt":
                    flags |= getattr(os, "O_NONBLOCK", 0)
                with os.fdopen(fd, "wb") as output:
                    original_fd = os.open(target, flags)
                    with os.fdopen(original_fd, "rb") as original:
                        current = os.fstat(original.fileno())
                        prior = originals[target]
                        if (not stat.S_ISREG(current.st_mode) or
                                (current.st_dev, current.st_ino) != (prior.st_dev, prior.st_ino)):
                            raise OSError("local destination changed during backup")
                        shutil.copyfileobj(original, output)
                        output.flush()
                        os.fsync(output.fileno())
                if not unchanged(target):
                    raise OSError("local destination changed during backup")
        for target, content in targets.items():
            if not unchanged(target):
                raise OSError("local destination changed before publish")
            if content is None:
                target.unlink(missing_ok=True)
            else:
                os.replace(staged[target], target)
            published.append(target)
    except OSError as ex:
        recovery_errors = []
        for target in reversed(published):
            try:
                if target in backups:
                    os.replace(backups[target], target)
                    backups.pop(target)
                else:
                    target.unlink(missing_ok=True)
            except OSError:
                recovery_errors.append(str(target))
        if recovery_errors:
            retain_backups = True
            raise CLIError("OUTPUT_EXISTS", "출력 실패 후 기존 파일 복원에도 실패했습니다. 백업 파일을 확인하세요.",
                           affected_paths=recovery_errors, backup_paths=list(backups.values())) from ex
        raise CLIError("INVALID_ARGUMENT", "출력 파일을 저장하지 못했습니다.") from ex
    finally:
        for tmp in staged.values():
            if os.path.exists(tmp):
                os.unlink(tmp)
        # Retain backups when rollback failed so they can be restored manually.
        if not retain_backups:
            for backup in backups.values():
                if os.path.exists(backup):
                    os.unlink(backup)
    return {"status": "downloaded", "downloaded": True, "note_id": note.id, "remote_version": note.version, "path": str(destination)}


def upload(api: NoteStationAPI, local_path: Path, *, stack: str | None, notebook: str | None,
           notebook_id: str | None, title: str | None, note_id: str | None,
           overwrite: bool, compare_only: bool) -> dict:
    if overwrite and compare_only:
        raise CLIError("INVALID_ARGUMENT", "--overwrite와 --diff는 함께 사용할 수 없습니다.")
    markdown, blocks = input_markdown(local_path)
    title = title if title is not None else local_path.stem
    if not title or title.strip() != title:
        raise CLIError("INVALID_ARGUMENT", "노트 제목이 올바르지 않습니다.")
    book = select_notebook(api, stack=stack, notebook=notebook, notebook_id=notebook_id)
    target = select_note(api, book["id"], title, note_id)
    if target is None and note_id:
        raise CLIError("NOT_FOUND", "요청한 노트 ID가 제목/메모장과 일치하지 않습니다.")
    if target is None and overwrite:
        raise CLIError("NOT_FOUND", "덮어쓸 노트가 없습니다.")
    old_source = None
    old_source_id = None
    protected_ids: set[str] = set()
    if target:
        old_source, old_source_id, original_ids = verified_source(api, target)
        protected_ids = set(original_ids) - {old_source_id}
        difference = diff(old_source.markdown, markdown, target.id, local_path)
        if old_source.blocks != blocks:
            before = json.dumps(old_source.blocks, ensure_ascii=False, indent=2, sort_keys=True).splitlines(keepends=True)
            after = json.dumps(blocks, ensure_ascii=False, indent=2, sort_keys=True).splitlines(keepends=True)
            difference += "".join(difflib.unified_diff(before, after,
                fromfile="NAS/" + target.id + ".preserved.json",
                tofile="LOCAL/" + str(local_path) + ".preserved.json"))
        if old_source.markdown == markdown and old_source.blocks == blocks:
            return {"status": "unchanged", "uploaded": False, "note_id": target.id, "remote_version": target.version, "diff": ""}
        if compare_only:
            return {"status": "different", "uploaded": False, "note_id": target.id, "remote_version": target.version, "diff": difference}
        if not overwrite:
            raise CLIError("TITLE_CONFLICT", "동일 제목 노트가 있습니다. 덮어쓰기에는 --overwrite가 필요합니다.",
                           note_id=target.id, remote_version=target.version, diff=difference, uploaded=False, requires_overwrite=True)
        # Protect assets/opaque user content until lossless attachment editing is supported.
        if old_source.attachment_bindings or old_source.math_attachments or old_source.blocks != blocks or ATTACH_REF.search(old_source.markdown):
            raise CLIError("UNSUPPORTED_MARKDOWN_FEATURE", "원격 첨부·수식·보존 블록이 포함된 노트는 아직 덮어쓸 수 없습니다.")
    elif compare_only:
        return {"status": "would_create", "uploaded": False, "title": title, "notebook_id": book["id"]}

    html = render(markdown, blocks=blocks)
    operation_id = str(uuid.uuid4())
    document_id = old_source.document_id if old_source else str(uuid.uuid4()).upper()
    original_html = target.html if target else "<p>문서를 전송하고 있습니다.</p>"
    stage_name = f"synology-note-upload-{document_id}-{operation_id}.md"
    stage = SourceEnvelope.make(markdown, original_html, document_id=document_id,
                                operation_id=operation_id, is_staging=True, blocks=blocks).encode()
    record = {"operation_id": operation_id, "document_id": document_id, "note_id": target.id if target else None,
              "notebook_id": book["id"], "title": title, "markdown": markdown, "blocks": blocks, "desired_html": html,
              "original_html": original_html, "base_version": target.version if target else None,
              "stage_name": stage_name, "stage_bytes": base64.b64encode(stage).decode("ascii"),
              "old_source_id": old_source_id, "protected_ids": sorted(protected_ids), "phase": "prepared"}
    save(record)
    try:
        if target:
            latest = api.fetch(target.id)
            if latest.version != target.version or latest.html != target.html or latest.title != target.title or latest.notebook_id != book["id"]:
                raise CLIError("REMOTE_CHANGED", "비교 후 NAS 노트가 변경되었습니다.")
            checked_source, checked_id, _ = verified_source(api, latest)
            if checked_source != old_source or checked_id != old_source_id:
                raise CLIError("REMOTE_CHANGED", "비교한 Markdown 원문이 변경되었습니다.")
        record["phase"] = "staging"; save(record)
        new_id, stage_version = api.write(note_id=target.id if target else None,
                                          version=target.version if target else None,
                                          notebook_id=book["id"] if not target else None,
                                          title=title if not target else None,
                                          html=original_html if not target else None,
                                          uploads=[(stage_name, "text/markdown", stage)])
        record.update(note_id=new_id, stage_version=stage_version, phase="staged"); save(record)
        current = api.fetch(new_id)
        if current.version != stage_version or current.html != original_html or current.title != title or current.notebook_id != book["id"]:
            raise CLIError("REMOTE_CHANGED", "임시 원문을 등록한 뒤 NAS 문서가 변경되었습니다.")
        stages = [f for f in current.attachments if f["name"] == stage_name and api.download(f["id"], new_id) == stage]
        if len(stages) != 1:
            raise CLIError("WRITE_UNCERTAIN", "NAS 임시 원문을 확인할 수 없습니다.")
        record["phase"] = "body"; save(record)
        _, body_version = api.write(note_id=new_id, version=current.version, html=html)
        record.update(body_version=body_version, phase="body_saved"); save(record)
        current = api.fetch(new_id)
        if current.version != body_version or current.html != html or current.title != title or current.notebook_id != book["id"]:
            raise CLIError("WRITE_UNCERTAIN", "NAS HTML 본문을 검증할 수 없습니다.")
        final = SourceEnvelope.make(markdown, current.html, document_id=document_id, operation_id=operation_id, blocks=blocks).encode()
        delete_ids = [stages[0]["id"]] + ([old_source_id] if old_source_id else [])
        record["phase"] = "publishing"; save(record)
        _, final_version = api.write(note_id=new_id, version=current.version, uploads=[(f"synology-note-source-{document_id}.md", "text/markdown", final)], deleting=delete_ids)
        record.update(final_version=final_version, phase="published"); save(record)
        current = api.fetch(new_id)
        source, _, _ = verified_source(api, current)
        current_ids = {f["id"] for f in current.attachments}
        if (current.version != final_version or current.title != title or
                current.notebook_id != book["id"] or current.html != html or
                source.markdown != markdown or source.blocks != blocks or source.document_id != document_id or
                not source.operation_id or uuid.UUID(source.operation_id) != uuid.UUID(operation_id) or
                any(v in current_ids for v in delete_ids) or not protected_ids.issubset(current_ids)):
            raise CLIError("WRITE_UNCERTAIN", "NAS 최종 원문 확인에 실패했습니다.")
        done(record)
        return {"status": "uploaded", "uploaded": True, "note_id": new_id, "remote_version": current.version,
                "operation_id": operation_id, "notebook_id": book["id"], "title": title}
    except CLIError as ex:
        if record["phase"] == "prepared" or ex.code == "REMOTE_CHANGED" and record["phase"] == "prepared":
            done(record)
            raise
        # Any in-flight mutation may have succeeded after a lost response.
        if ex.code in ("TRANSPORT_ERROR", "WRITE_UNCERTAIN", "REMOTE_ERROR") or record["phase"] in ("staging", "body", "publishing"):
            raise CLIError("WRITE_UNCERTAIN", "NAS 쓰기 결과가 불확실합니다. 작업 상태를 조회하세요.",
                           operation_id=operation_id, phase=record["phase"], note_id=record.get("note_id")) from ex
        raise
