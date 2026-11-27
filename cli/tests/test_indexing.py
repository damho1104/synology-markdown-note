"""Live-shaped, write-counted contract checks for generated NAS indexes."""
from dataclasses import dataclass
from types import SimpleNamespace
import re
import sys
import unicodedata

import pytest

from synonote_cli import indexing, main, operations
from synonote_cli.api import Note
from synonote_cli.errors import CLIError
from synonote_cli.markdown import PARSER, render


def html(projects: dict[str, int], body: str) -> str:
    return ("<h2>type: daily\ndate: 2026-10-18\nby_project: " + repr(projects) +
            "\n</h2><h2>🤖 AI 회고</h2><p><strong>기록 회고</strong></p><p>" + body + "</p>")


@dataclass
class IndexNAS:
    duplicate: bool = False

    def __post_init__(self):
        self.writes = 0
        self.upload_writes = 0
        self.move_writes = 0
        self.index_pages: dict[str, str] = {}
        self.index_locations: dict[str, str] = {}
        self.book_rows = [{"id": "nb1", "name": "2026-09", "stack": "LLM-Daily-Summary"},
                          {"id": "nb2", "name": "2026-10", "stack": "LLM-Daily-Summary"},
                          {"id": "idx", "name": "llm-index", "stack": "LLM-Daily-Summary"}]
        self.sources = [
            Note("d1", "nb1", "2026-10-16 기록", "1", html({"alpha": 2, "beta": 1},
                 "Tailscale Gitea Docker 네트워크 분석 abcunique 접속 실패 디버깅 복구." * 6), []),
            Note("d2", "nb1", "2026-10-17 기록", "1", html({"alpha": 1, "gamma": 1},
                 "Tailscale Gitea Docker 네트워크 분석 abcunique 접속 실패 디버깅 복구." * 6), []),
            Note("d3", "nb2", "2026-10-18 기록", "1", html({"alpha": 3},
                 "Tailscale Gitea Docker 네트워크 분석 abcunique 접속 실패 디버깅 복구." * 6), []),
            Note("d4", "nb2", "2026-10-19 기록", "1", html({"beta": 2},
                 "SwiftUI macOS 앱 화면 개선 검증 배포." * 6), []),
        ]

    def notebooks(self):
        return list(self.book_rows)

    def create_notebook(self, name):
        assert name not in [b["name"] for b in self.book_rows]
        self.writes += 1
        book = {"id": name, "name": name, "stack": ""}
        self.book_rows.append(book)
        return dict(book)

    def move_notebook_to_stack(self, notebook_id, stack):
        self.writes += 1
        book = next(b for b in self.book_rows if b["id"] == notebook_id)
        book["stack"] = stack
        return dict(book)

    def move_note(self, note, notebook_id):
        assert self.index_locations[note.title] == note.notebook_id
        self.writes += 1
        self.move_writes += 1
        self.index_locations[note.title] = notebook_id
        return self.fetch(note.id)

    def notes(self):
        records = self.sources + [Note("i" + str(n), self.index_locations.get(title, "idx"), title, "1", "", [])
                                  for n, title in enumerate(self.index_pages)]
        result = [{"id": n.id, "notebook_id": n.notebook_id, "title": n.title,
                   "trashed": False, "locked": False} for n in records]
        if self.duplicate:
            result.append(dict(result[0], id="duplicate", title=unicodedata.normalize("NFD", result[0]["title"])))
        return result

    def fetch(self, note_id):
        for n in self.sources:
            if n.id == note_id:
                return n
        for n, title in enumerate(self.index_pages):
            if note_id == "i" + str(n):
                return Note(note_id, self.index_locations.get(title, "idx"), title, "1",
                            render(self.index_pages[title]), [])
        raise AssertionError(note_id)

    def close(self):
        pass


def fake_upload(api, path, *, stack, notebook, notebook_id, title, note_id, overwrite, compare_only):
    assert stack == "LLM-Daily-Summary"
    assert notebook == indexing.destination(title, "llm-index")
    assert notebook_id == next(b["id"] for b in api.book_rows if b["name"] == notebook)
    assert (title in api.index_pages) == overwrite
    api.writes += 1
    api.upload_writes += 1
    api.index_pages[title] = path.read_text(encoding="utf-8")
    api.index_locations[title] = notebook_id
    return {"status": "uploaded", "note_id": "i" + str(list(api.index_pages).index(title))}


@pytest.fixture
def api(monkeypatch, tmp_path):
    monkeypatch.setattr(operations, "journal_directory", lambda: tmp_path)
    monkeypatch.setattr(indexing, "journal_directory", lambda: tmp_path)
    nas = IndexNAS()
    monkeypatch.setattr(indexing, "upload", fake_upload)
    monkeypatch.setattr(indexing, "verified_source", lambda nas, note: (
        SimpleNamespace(markdown=nas.index_pages[note.title]), None, []))
    return nas


def run_build(api, **kwargs):
    return indexing.build(api, stack="LLM-Daily-Summary", index_notebook="llm-index", **kwargs)


def test_parse_projects_and_multi_project_days():
    assert indexing.parse_projects(html({"alpha": 2, "beta": 1}, "hello")) == {"alpha": 2, "beta": 1}
    assert indexing.parse_projects("by_project: {'x': -1, 'y': True, 'z': 3}\n") == {"z": 3}
    assert indexing.parse_projects("by_project: broken\n") == {}


def test_four_hubs_project_and_topic_evidence_and_related_pairs(api):
    notes, _, _ = indexing.read_daily(api, stack="LLM-Daily-Summary", index_notebook="llm-index")
    assert len(notes) == 4
    assert notes[0].projects == {"alpha": 2, "beta": 1}
    assert "네트워크-DNS" in notes[0].topics
    pages, stats = indexing.build_pages(notes)
    assert set(indexing.HUBS).issubset(pages)
    assert stats["source_notes"] == 4
    assert stats["project_names"] == 3
    assert stats["project_details"] == 1
    assert stats["topic_details"] > 0
    assert stats["related_pairs"] > 0
    assert all("<!-- synonote-index:v1 -->" in page for page in pages.values())
    project = next(v for k, v in pages.items() if k.startswith("프로젝트-alpha"))
    assert all(t in project for t in ("2026-10-16", "2026-10-17", "2026-10-18"))
    topic = next(v for k, v in pages.items() if k.startswith("주제-네트워크-DNS"))
    assert "Tailscale" in topic
    assert "공통 표현:" in pages["03-연관 지식"]
    assert "2026-10" in pages["00-전체 인덱스"]


def test_index_dry_run_never_writes_and_reapply_is_idempotent(api):
    first = run_build(api)
    assert first["status"] == "dry_run" and first["create"] == first["total_index_notes"]
    assert api.writes == 0 and not api.index_pages
    published = run_build(api, apply=True)
    assert published["created"] == first["create"] and published["updated"] == 0
    assert api.upload_writes == published["created"]
    assert published["notebooks_created"] == ["by-project", "by-topic"]
    again = run_build(api, apply=True)
    assert again["created"] == again["updated"] == 0
    assert again["unchanged"] == published["created"]
    assert api.upload_writes == published["created"]
    assert len(api.sources) == 4  # Source notebook never written.


def test_managed_page_is_updated_and_unmanaged_page_is_protected(api):
    run_build(api, apply=True)
    api.index_pages["00-전체 인덱스"] += "\n이전 내용\n"
    assert run_build(api)["update"] == 1
    assert run_build(api, apply=True)["updated"] == 1
    api.index_pages["00-전체 인덱스"] = "내가 쓴 노트"
    with pytest.raises(CLIError) as error:
        run_build(api, apply=True)
    assert error.value.code == "TITLE_CONFLICT"


def test_nfc_duplicate_source_titles_block_all_writes(api):
    api.duplicate = True
    with pytest.raises(CLIError) as error:
        run_build(api, apply=True)
    assert error.value.code == "AMBIGUOUS_TARGET" and api.writes == 0


def test_index_collision_outside_destination_blocks_writes(api):
    api.sources.append(Note("other", "nb1", "00-전체 인덱스", "1", html({"x": 1}, "extra"), []))
    with pytest.raises(CLIError) as error:
        run_build(api, apply=True)
    assert error.value.code in ("TITLE_CONFLICT", "AMBIGUOUS_TARGET")
    assert api.writes == 0


def test_partial_publish_failure_propagates_without_retry(api, monkeypatch):
    def fail_second(*args, **kwargs):
        if api.upload_writes == 1:
            raise CLIError("WRITE_UNCERTAIN", "lost receipt", operation_id="op")
        return fake_upload(*args, **kwargs)

    monkeypatch.setattr(indexing, "upload", fail_second)
    with pytest.raises(CLIError) as error:
        run_build(api, apply=True)
    assert error.value.code == "WRITE_UNCERTAIN"
    assert error.value.details["created"] == 1
    assert error.value.details["index_title"]
    assert api.upload_writes == 1


def test_link_percent_encoding_markdown_parser_and_missing_target():
    title = "이름[1] %foo (test) <abc>"
    md = indexing.link(title)
    assert "%25" in md and "%3C" in md and "%3E" in md
    html_content = render(md)
    assert "href=" in html_content
    indexing.validate_links({"00-전체 인덱스": md}, {title})
    with pytest.raises(CLIError, match="An internal index link has no target"):
        indexing.validate_links({"00-전체 인덱스": md}, set())
    assert any(t.type == "link_open" for token in PARSER.parse(md) for t in token.children or [])


def test_main_json_dry_run_and_conflicting_options(api, monkeypatch, capsys):
    monkeypatch.setattr(main, "connected", lambda: api)
    monkeypatch.setattr(sys, "argv", ["synonote", "index", "build", "--stack",
                                          "LLM-Daily-Summary", "--json"])
    main.run()
    import json
    result = json.loads(capsys.readouterr().out)
    assert result["action"] == "index.build" and result["status"] == "dry_run"
    assert api.writes == 0
    monkeypatch.setattr(sys, "argv", ["synonote", "index", "build", "--stack",
                                          "LLM-Daily-Summary", "--apply", "--dry-run", "--json"])
    with pytest.raises(SystemExit) as e:
        main.run()
    assert e.value.code == 2
    assert json.loads(capsys.readouterr().out)["error"]["code"] == "INVALID_ARGUMENT"


def legacy_pages(api):
    notes, _, _ = indexing.read_daily(api, stack="LLM-Daily-Summary", index_notebook="llm-index")
    pages, _ = indexing.build_pages(notes)
    api.index_pages.update(pages)
    api.index_locations.update({title: "idx" for title in pages})
    return pages


def test_legacy_migration_preserves_ids_and_content_and_rebuild_is_noop(api):
    pages = legacy_pages(api)
    original = {t: api.fetch("i" + str(n)) for n, t in enumerate(pages)}
    preview = run_build(api)
    detail_count = len(pages) - len(indexing.HUBS)
    assert (preview["create"], preview["move"], preview["move_update"]) == (0, detail_count, 0)
    assert preview["placement"]["llm-index"] == 4
    assert api.writes == 0

    result = run_build(api, apply=True)
    assert result["moved"] == detail_count and result["created"] == result["updated"] == 0
    assert api.move_writes == detail_count
    assert all(api.index_locations[t] == ("idx" if t in indexing.HUBS else
               indexing.destination(t, "llm-index")) for t in pages)
    for title, note in original.items():
        updated = api.fetch(note.id)
        assert (updated.id, updated.html, updated.attachments, updated.title) == (
            note.id, note.html, note.attachments, note.title)
    assert len(api.sources) == 4
    assert not list(indexing.journal_directory().glob("*.json"))
    after = run_build(api, apply=True)
    assert after["moved"] == after["created"] == after["updated"] == 0
    assert after["unchanged"] == len(pages) and api.move_writes == detail_count
    daily, _, _ = indexing.read_daily(api, stack="LLM-Daily-Summary", index_notebook="llm-index")
    assert len(daily) == 4


def test_move_receipt_lost_is_recovered_by_verified_readback(api, monkeypatch):
    legacy_pages(api)
    original_move = api.move_note
    completed = False

    def lose_reply(note, target):
        nonlocal completed
        result = original_move(note, target)
        if not completed:
            completed = True
            raise CLIError("WRITE_UNCERTAIN", "NAS 응답 유실")
        return result

    monkeypatch.setattr(api, "move_note", lose_reply)
    with pytest.raises(CLIError) as error:
        run_build(api, apply=True)
    assert error.value.code == "WRITE_UNCERTAIN"
    assert len(list(indexing.journal_directory().glob("*.json"))) == 1
    assert run_build(api, apply=True)["moved"] == len(api.index_pages) - len(indexing.HUBS) - 1
    assert not list(indexing.journal_directory().glob("*.json"))


def test_unknown_move_receipt_blocks_replay(api, monkeypatch):
    legacy_pages(api)
    writes = 0

    def no_ack(note, target):
        nonlocal writes
        writes += 1
        raise CLIError("WRITE_UNCERTAIN", "NAS 응답 유실")

    monkeypatch.setattr(api, "move_note", no_ack)
    with pytest.raises(CLIError) as first:
        run_build(api, apply=True)
    with pytest.raises(CLIError) as second:
        run_build(api, apply=True)
    assert first.value.code == second.value.code == "WRITE_UNCERTAIN"
    assert writes == 1
    assert len(list(indexing.journal_directory().glob("*.json"))) == 1


def test_conflicting_user_detail_prevents_any_mutation(api):
    pages = legacy_pages(api)
    title = next(t for t in pages if t.startswith("프로젝트-"))
    api.index_pages[title] = "사용자가 작성한 다른 내용"
    with pytest.raises(CLIError) as failure:
        run_build(api, apply=True)
    assert failure.value.code == "TITLE_CONFLICT"
    assert api.writes == 0


def test_detail_name_collision_in_other_stack_blocks_creation(api):
    api.book_rows.append({"id": "other_project", "name": "by-project", "stack": "Other"})
    with pytest.raises(CLIError) as failure:
        run_build(api, apply=True)
    assert failure.value.code == "TITLE_CONFLICT"
    assert api.writes == 0
