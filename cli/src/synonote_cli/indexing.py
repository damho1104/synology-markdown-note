"""Guarded Note Station knowledge indexes, separated by notebook role."""
from __future__ import annotations

import ast
import json
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date
from hashlib import sha256
from html import unescape
from html.parser import HTMLParser
from math import log, sqrt
from pathlib import Path
import re
import tempfile
import unicodedata
import uuid
from urllib.parse import quote, unquote

from .api import NoteStationAPI
from .errors import CLIError
from .markdown import PARSER, render
from .operations import done, journal_directory, save
from .transfers import upload, verified_source


MANAGED = "<!-- synonote-index:v1 -->"
HUBS = ("00-전체 인덱스", "01-프로젝트 인덱스", "02-주제 인덱스", "03-연관 지식")
PROJECT_BOOK = "by-project"
TOPIC_BOOK = "by-topic"
MONTH_BOOK = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


def destination(title: str, index_notebook: str) -> str:
    if title in HUBS:
        return index_notebook
    if title.startswith("프로젝트-"):
        return PROJECT_BOOK
    if title.startswith("주제-"):
        return TOPIC_BOOK
    raise CLIError("INVALID_SOURCE", "Could not determine the category of the index title.", title=title)

# Explicit, reviewable vocabulary: topic membership has a matching source term.
TOPICS: dict[str, str] = {
    "CI-CD": r"\bCI(?:/CD)?\b|GitHub Actions|Gitea Actions|GitLab CI|파이프라인|워크플로|workflow|Runner|자동 빌드",
    "빌드-릴리즈": r"릴리즈|배포|패키징|버전 태그|코드 서명|notariz|PyInstaller|APK|DMG|빌드 실패",
    "네트워크-DNS": r"Tailscale|\bDNS\b|프록시|reverse proxy|게이트웨이|\bWAN\b|\bLAN\b|포트 포워딩|라우팅|방화벽|\bNginx\b|연결 끊김",
    "인증-보안": r"OAuth|Keychain|Credential|인증|로그인|토큰|권한|TLS|\bSSL\b|암호화|취약점|보안 검토|인증서",
    "데이터베이스": r"PostgreSQL|MongoDB|SQLite|TimescaleDB|\bSQL\b|\bORM\b|스키마|인덱스 쿼리|데이터베이스|\bDB\b",
    "동기화-정합성": r"동기화|중복 처리|race condition|경합|checkpoint|데이터 정합성|마이그레이션|충돌 해결|원자적|중복 동기화",
    "장애-디버깅": r"장애|원인 분석|디버깅|오류|에러|실패|복구|재현|로그 분석|타임아웃|\bOOM\b",
    "테스트-검증": r"테스트|검증|회귀|pytest|\bJUnit\b|\bXCTest\b|단위 시험|E2E|커버리지",
    "UI-UX": r"\bUI\b|\bUX\b|레이아웃|디자인|스타일|반응형|모바일 화면|다크 모드|화면 구성|접근성",
    "Android-모바일": r"Android|안드로이드|\bADB\b|Galaxy|갤럭시|태블릿|Kotlin|\bAPK\b|Compose",
    "macOS-Swift": r"\bSwift\b|SwiftUI|macOS|Mac mini|\bXcode\b|AppKit|\bDMG\b|Keychain",
    "웹-프론트엔드": r"React|Next\.js|Vue|TypeScript|JavaScript|프론트엔드|웹페이지|\bCSS\b|브라우저",
    "서버-API": r"\bAPI\b|\bHTTP\b|REST|Webhook|백엔드|서버 개발|\bSSE\b|GraphQL",
    "Docker-인프라": r"Docker|컨테이너|Kubernetes|K8s|Compose|인프라|\bLXC\b|Proxmox|서버 운영",
    "클라우드-AWS": r"\bAWS\b|\bEC2\b|\bALB\b|\bS3\b|Lambda|CloudFront|클라우드|클라우드 비용",
    "LLM-에이전트": r"\bLLM\b|Codex|Claude|에이전트|\bMCP\b|프롬프트|임베딩|\bRAG\b|모델 추론",
    "검색-지식관리": r"검색|인덱싱|백링크|그래프 뷰|지식 베이스|Wiki|위키|노트 링크|\bFTS\b",
    "성능-최적화": r"성능|최적화|속도|메모리 사용|캐시|병목|지연|응답 시간|부하",
    "자동화-스크립트": r"자동화|스크립트|\bCLI\b|\bcron\b|배치 작업|스케줄러|GitHub Actions|Gitea Actions",
    "IoT-스마트홈": r"IoT|Home Assistant|Lovelace|센서|스마트홈|MQTT|홈 어시스턴트",
    "로또-금융": r"로또|당첨 번호|가상자산|\bBTC\b|비트코인|매매|거래소|금융",
}

TOPIC_PATTERNS = {name: re.compile(pattern, re.I) for name, pattern in TOPICS.items()}
WORD = re.compile(r"[A-Za-z][A-Za-z0-9_.+/-]{2,}|[가-힣]{2,}")
STOP = {"그리고", "그러나", "하도록", "있도록", "위해서", "대해서", "진행", "확인", "구현", "적용", "기능", "작업", "검증", "추가", "완료", "분석", "문제", "테스트", "설정", "변경", "관련", "개선", "정리", "지원", "사용", "사용자", "시스템", "정상", "동작", "구성", "진단", "유지", "진행했다", "확인했다", "구현했다", "결과", "통해", "기존", "오류", "발생", "파일", "서비스", "데이터", "처리", "환경", "기준", "기록", "대상", "수정", "작성", "비교", "내용", "주요", "회고", "기술", "원인", "추적", "가능", "추가했다", "추가로", "사용해", "코드", "그대로", "버전", "저장", "생성", "새로운", "운영", "일일", "노트", "프로젝트", "요약", "작업을", "작업에", "작업과", "최종"}


class TextOnly(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.fragments: list[str] = []

    def handle_data(self, value: str):
        self.fragments.append(value)


def clean(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def plain(html: str) -> str:
    parser = TextOnly()
    parser.feed(html)
    return clean(" ".join(parser.fragments))


def parse_projects(html: str) -> dict[str, int]:
    match = re.search(r"(?:^|\n)by_project:\s*([^\n<]+)", unescape(html))
    if not match:
        return {}
    try:
        value = ast.literal_eval(match.group(1))
    except (SyntaxError, ValueError, TypeError, MemoryError):
        return {}
    if not isinstance(value, dict):
        return {}
    return {k: v for k, v in value.items() if isinstance(k, str) and k.strip()
            and type(v) is int and v > 0}


def unique_title(value: str, prefix: str) -> str:
    safe = unicodedata.normalize("NFC", value)
    safe = re.sub(r"[\\/:?#<>\[\]\r\n]", "-", safe).strip(" .-")
    safe = re.sub(r"\s+", "-", safe)[:65].rstrip(" .-") or "미분류"
    return prefix + safe


def link(title: str, label: str | None = None) -> str:
    # Swift InternalNoteLinks accepts a single .md basename, without query/fragment.
    if not title or any(c in title for c in "/\\:?#\r\n\x00"):
        raise CLIError("INVALID_SOURCE", "Could not encode the target title for an internal link.", title=title)
    label = (label or title).replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
    # Quote literal percent signs, angle brackets, and other URI metacharacters.
    # Swift's InternalNoteLinks.title(for:) percent-decodes the destination.
    return f"[{label}](<{quote(title, safe='-._~!$&\'()+,;=@[] ')}.md>)"


def validate_links(pages: dict[str, str], source_titles: set[str]) -> None:
    """All rendered internal links must resolve to exactly one generated/source title."""
    allowed = {unicodedata.normalize("NFC", t) for t in source_titles | set(pages)}
    for page, markdown in pages.items():
        for token in PARSER.parse(markdown):
            for child in token.children or []:
                if child.type != "link_open":
                    continue
                destination = unquote(child.attrGet("href") or "")
                if (not destination.lower().endswith(".md") or
                    unicodedata.normalize("NFC", destination[:-3]) not in allowed):
                    raise CLIError("INVALID_SOURCE", "An internal index link has no target.",
                                   index_title=page, destination=destination)


@dataclass
class Daily:
    id: str
    title: str
    notebook: str
    projects: dict[str, int]
    body: str
    summary: str
    topics: tuple[str, ...] = ()
    evidence: dict[str, str] = field(default_factory=dict)


def excerpt(body: str, hit: re.Match | None = None, max_length: int = 130) -> str:
    if not body:
        return ""
    if hit is None:
        return body[:max_length].rstrip() + ("…" if len(body) > max_length else "")
    begin = max(0, hit.start() - 32)
    end = min(len(body), begin + max_length)
    return ("…" if begin else "") + body[begin:end].strip() + ("…" if end < len(body) else "")


def read_daily(api: NoteStationAPI, *, stack: str, index_notebook: str) -> tuple[list[Daily], dict, list[dict]]:
    books = [b for b in api.notebooks() if b["stack"] == stack]
    indexes = [b for b in books if b["name"] == index_notebook]
    if len(indexes) != 1:
        raise CLIError("NOT_FOUND" if not indexes else "AMBIGUOUS_TARGET",
                       "The index notebook is missing or its name is shared by multiple notebooks.", notebook=index_notebook)
    # The source set is strictly the observed monthly daily notebooks. Index
    # notebooks must never be fed into a subsequent indexing pass.
    allowed = {b["id"]: b["name"] for b in books if MONTH_BOOK.fullmatch(b["name"])}
    all_notes = api.notes()
    rows = [row for row in all_notes if row["notebook_id"] in allowed and not row["trashed"]]
    duplicates = Counter(unicodedata.normalize("NFC", row["title"])
                         for row in all_notes if not row["trashed"])
    # Title-based link lookup is global in the macOS app. Fail before publishing.
    conflicts = [r["title"] for r in rows if duplicates[unicodedata.normalize("NFC", r["title"])] > 1]
    if conflicts:
        raise CLIError("AMBIGUOUS_TARGET", "One or more source note titles are duplicated on the NAS.", titles=sorted(set(conflicts)))
    notes = []
    for row in sorted(rows, key=lambda n: n["title"]):
        if row.get("locked"):
            raise CLIError("UNSUPPORTED_DOCUMENT_TYPE", "Locked source notes cannot be indexed.", title=row["title"])
        link(row["title"])  # Check the source filename before generating any index.
        detail = api.fetch(row["id"])
        body_html = re.sub(r"<h2>type:\s*daily\b.*?</h2>", "", detail.html, count=1, flags=re.S | re.I)
        body = plain(body_html)
        first = re.search(r"<h2>🤖 AI 회고</h2>\s*<p><strong>(.*?)</strong>", body_html, re.S)
        summary = plain(first.group(1)) if first else excerpt(body, max_length=95)
        matches = []
        evidence = {}
        for name, pattern in TOPIC_PATTERNS.items():
            hits = list(pattern.finditer(body))
            if hits:
                matches.append((min(len(hits), 5), name))
                evidence[name] = excerpt(body, hits[0])
        topics = tuple(name for _, name in sorted(matches, key=lambda x: (-x[0], x[1]))[:8])
        notes.append(Daily(row["id"], row["title"], allowed[row["notebook_id"]],
                           parse_projects(detail.html), body, summary, topics, evidence))
    return notes, indexes[0], all_notes


def related(notes: list[Daily], *, limit: int = 70) -> list[tuple[Daily, Daily, str, tuple[str, ...], float]]:
    """Find explainable candidate connections; no claim of LLM/embedding inference."""
    vocab: list[set[str]] = []
    frequency: Counter = Counter()
    for note in notes:
        terms = {s.casefold() for s in WORD.findall(note.body) if len(s) > 2 and s.casefold() not in STOP}
        vocab.append(terms)
        frequency.update(terms)
    candidates: list[tuple[float, int, int, tuple[str, ...], str]] = []
    for i, a in enumerate(notes):
        if len(a.body) < 110:
            continue
        for j in range(i + 1, len(notes)):
            b = notes[j]
            if len(b.body) < 110:
                continue
            common_topics = set(a.topics) & set(b.topics)
            common_projects = (set(a.projects) & set(b.projects)) - {"uncategorized"}
            keywords = sorted((term for term in vocab[i] & vocab[j] if frequency[term] <= max(12, len(notes) // 10)),
                              key=lambda term: (-log((len(notes) + 1) / (frequency[term] + 1)), term))
            # Require a shared specific technical term; shared broad categories alone are noisy.
            if len(keywords) < 2 or not (common_topics or common_projects):
                continue
            high_value = sorted(keywords, key=lambda s: (frequency[s], -len(s), s))[:4]
            specificity = sum(log((len(notes) + 1) / (frequency[w] + 1)) for w in high_value)
            score = specificity + 1.1 * len(common_topics) + 2.0 * len(common_projects)
            reason = ("같은 프로젝트: " + ", ".join(sorted(common_projects)[:2]) if common_projects else
                      "공통 주제: " + ", ".join(sorted(common_topics)[:2]))
            candidates.append((score, i, j, tuple(high_value), reason))
    # Diversify coverage so one prolific day cannot consume the entire index.
    selected = []
    per_note: Counter = Counter()
    for score, i, j, words, reason in sorted(candidates, key=lambda item: (-item[0], notes[item[1]].title, notes[item[2]].title)):
        if per_note[i] >= 3 or per_note[j] >= 3:
            continue
        selected.append((notes[i], notes[j], reason, words, round(score, 2)))
        per_note[i] += 1
        per_note[j] += 1
        if len(selected) == limit:
            break
    return selected


def _section_header(title: str, description: str) -> list[str]:
    return [MANAGED, "", f"# {title}", "", description, "", "← " + " · ".join(link(name) for name in HUBS if name != title), ""]


def build_pages(notes: list[Daily], *, project_min_days: int = 3) -> tuple[dict[str, str], dict]:
    if project_min_days < 2:
        raise CLIError("INVALID_ARGUMENT", "Detailed project indexes require a minimum of two days.")
    pages: dict[str, str] = {}
    by_project: dict[str, list[Daily]] = defaultdict(list)
    by_topic: dict[str, list[Daily]] = defaultdict(list)
    for note in notes:
        for key in note.projects:
            by_project[key].append(note)
        for key in note.topics:
            by_topic[key].append(note)

    names: set[str] = set(HUBS)
    def make_name(original: str, prefix: str) -> str:
        name = unique_title(original, prefix)
        if name in names:
            name += "-" + sha256(original.encode()).hexdigest()[:8]
        names.add(name)
        return name

    project_titles = {k: make_name(k, "프로젝트-") for k in sorted(by_project)
                      if len(by_project[k]) >= project_min_days and k != "uncategorized"}
    topic_titles = {k: make_name(k, "주제-") for k in sorted(by_topic) if len(by_topic[k]) >= 3}

    timeline = _section_header(HUBS[0], f"일일 기록 **{len(notes)}개** · LLM 구분 없이 원본 노트를 날짜순으로 탐색합니다.")
    timeline += ["## 탐색", "", "- " + link(HUBS[1]), "- " + link(HUBS[2]), "- " + link(HUBS[3]), ""]
    months: dict[str, list[Daily]] = defaultdict(list)
    for note in notes:
        months[note.notebook].append(note)
    for month in sorted(months, reverse=True):
        month_notes = sorted(months[month], key=lambda n: n.title, reverse=True)
        timeline += [f"## {month} ({len(month_notes)}개)", ""]
        timeline.extend("- " + link(n.title) + (" — " + n.summary[:95] if n.summary else "") for n in month_notes)
        timeline.append("")
    pages[HUBS[0]] = "\n".join(timeline).rstrip() + "\n"

    projects = _section_header(HUBS[1], f"**{len(by_project)}개 프로젝트** · 일일 노트의 `by_project` 메타데이터 기반. 다중 프로젝트가 있는 날짜는 각 프로젝트에 모두 연결합니다.")
    projects += ["반복 기록(3일 이상 등)은 상세 인덱스로, 단발성 기록은 원본 날짜로 바로 이동합니다.", ""]
    for key, rows in sorted(by_project.items(), key=lambda it: (-len(it[1]), it[0])):
        sessions = sum(n.projects[key] for n in rows)
        projects += [f"## {key} ({len(rows)}일 · {sessions}세션)", ""]
        if key in project_titles:
            projects += ["- " + link(project_titles[key], "프로젝트 기록 전체 보기"), ""]
        else:
            projects += ["- " + " · ".join(link(n.title) for n in sorted(rows, key=lambda n: n.title, reverse=True)), ""]
        if key in project_titles:
            title = project_titles[key]
            content = _section_header(title, f"`by_project` = `{key}` · {len(rows)}일 · {sessions}세션. 각 링크는 원본 날짜 기록으로 이동합니다.")
            for n in sorted(rows, key=lambda n: n.title, reverse=True):
                content += [f"- {link(n.title)} — {n.projects[key]}세션"]
            pages[title] = "\n".join(content).rstrip() + "\n"
    pages[HUBS[1]] = "\n".join(projects).rstrip() + "\n"

    topics = _section_header(HUBS[2], "본문에 실제로 등장한 기술 용어와 작업 키워드로 주제를 추출합니다. 주제는 여러 개가 동시에 연결될 수 있습니다.")
    topics += ["분류는 규칙 기반이며, 각 상세 인덱스는 매칭된 본문 발췌를 근거로 제공합니다.", ""]
    for key, rows in sorted(by_topic.items(), key=lambda it: (-len(it[1]), it[0])):
        topics += [f"## {key} ({len(rows)}일)", ""]
        if key in topic_titles:
            topics += ["- " + link(topic_titles[key], "근거와 원본 날짜 보기"), ""]
            title = topic_titles[key]
            content = _section_header(title, f"{len(rows)}개 일일 기록에서 `{key}`에 해당하는 표현을 확인했습니다.")
            for n in sorted(rows, key=lambda n: n.title, reverse=True):
                content.append(f"- {link(n.title)} — {n.evidence[key]}")
            pages[title] = "\n".join(content).rstrip() + "\n"
        else:
            topics += ["- " + " · ".join(link(n.title) for n in sorted(rows, key=lambda n: n.title, reverse=True)), ""]
    pages[HUBS[2]] = "\n".join(topics).rstrip() + "\n"

    relationships = related(notes)
    knowledge = _section_header(HUBS[3], "서로 다른 날짜의 노트에서 겹치는 기술 표현과 프로젝트·주제를 함께 비교한 **연관 후보**입니다.")
    knowledge += ["이 인덱스는 본문 유사성과 명시적 공통 키워드를 사용하며, LLM 임베딩이나 인과관계 분석 결과는 아닙니다. 각 연결의 근거를 원본에서 확인하세요.", ""]
    if not relationships:
        knowledge += ["연결 기준을 충족한 기록이 없습니다.", ""]
    for a, b, reason, words, score in relationships:
        knowledge += [f"## {link(a.title)} ↔ {link(b.title)}", "",
                      f"- 연결 근거: {reason}", f"- 공통 표현: {', '.join(words)}", ""]
    pages[HUBS[3]] = "\n".join(knowledge).rstrip() + "\n"

    # Link resolution is title-based across ALL notebooks; avoid name collisions.
    if any(n.title in pages for n in notes):
        raise CLIError("AMBIGUOUS_TARGET", "A generated index title conflicts with a source note.")
    for title, markdown in pages.items():
        render(markdown)  # fail before writing anything if Markdown cannot be preserved
    validate_links(pages, {n.title for n in notes})
    return pages, {"source_notes": len(notes), "project_names": len(by_project),
                   "project_details": len(project_titles), "topic_names": len(by_topic),
                   "topic_details": len(topic_titles), "related_pairs": len(relationships)}


def _index_journal(api: NoteStationAPI, stack: str) -> None:
    """Reconcile completed moves on restart; never silently replay an unknown write."""
    for path in sorted(journal_directory().glob("*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if record.get("kind") != "index.structure" or record.get("stack") != stack:
            continue
        operation_id = record["operation_id"]
        kind = record["mutation"]
        if kind == "move":
            note = api.fetch(record["note_id"])
            confirmed = (note.id == record["note_id"] and note.notebook_id == record["target_id"]
                         and note.title == record["title"]
                         and sha256(note.html.encode()).hexdigest() == record["html_sha256"]
                         and note.attachments == record["attachments"])
            if confirmed:
                source, _, _ = verified_source(api, note)
                confirmed = source.markdown.startswith(MANAGED + "\n")
        elif kind == "stack":
            confirmed = any(b["id"] == record["target_id"] and b["stack"] == stack
                            for b in api.notebooks())
        else:
            # Without a creation receipt ID a matching name is not proof of
            # ownership; stop and require manual inspection.
            confirmed = False
        if confirmed:
            done(record)
            continue
        raise CLIError("WRITE_UNCERTAIN", "The result of a previous index change is uncertain. Check the journal and NAS.",
                       operation_id=operation_id, mutation=kind, title=record.get("title"))


def _mutate(api: NoteStationAPI, stack: str, mutation: str, **fields):
    record = {"operation_id": str(uuid.uuid4()), "kind": "index.structure",
              "stack": stack, "mutation": mutation,
              **{key: value for key, value in fields.items() if key != "note"}}
    save(record)  # Durable intent BEFORE the first write.
    try:
        if mutation == "create":
            result = api.create_notebook(fields["title"])
        elif mutation == "stack":
            result = api.move_notebook_to_stack(fields["target_id"], stack)
        else:
            result = api.move_note(fields["note"], fields["target_id"])
            source, _, _ = verified_source(api, result)
            if not source.markdown.startswith(MANAGED + "\n"):
                raise CLIError("WRITE_UNCERTAIN", "Could not verify the managed source after the move.")
    except CLIError as exc:
        # A version conflict or rejected request is definite only before a write.
        if exc.code in ("REMOTE_CHANGED", "INVALID_ARGUMENT", "TITLE_CONFLICT", "NOT_FOUND"):
            done(record)
        else:
            exc.details.setdefault("operation_id", record["operation_id"])
        raise
    done(record)
    return result


def build(api: NoteStationAPI, *, stack: str, index_notebook: str, apply: bool = False,
          project_min_days: int = 3) -> dict:
    if len({index_notebook, PROJECT_BOOK, TOPIC_BOOK}) != 3:
        raise CLIError("INVALID_ARGUMENT", "Hub and detail index notebooks must have distinct names.")
    notes, index_book, all_notes = read_daily(api, stack=stack, index_notebook=index_notebook)
    if not notes:
        raise CLIError("NOT_FOUND", "No source notes were found to index.")
    pages, stats = build_pages(notes, project_min_days=project_min_days)
    books = api.notebooks()
    destinations = (index_notebook, PROJECT_BOOK, TOPIC_BOOK)
    selected: dict[str, dict] = {index_notebook: index_book}
    for name in destinations[1:]:
        same = [b for b in books if b["name"] == name]
        if len(same) > 1 or (same and same[0]["stack"] != stack):
            raise CLIError("TITLE_CONFLICT", "A detail notebook name conflicts with an existing notebook.", notebook=name)
        if same:
            selected[name] = same[0]
    managed_books = {b["id"] for b in selected.values()}
    active = [n for n in all_notes if not n["trashed"]]
    by_title: dict[str, list[dict]] = defaultdict(list)
    for item in active:
        by_title[unicodedata.normalize("NFC", item["title"])].append(item)

    actions: dict[str, str] = {}
    known: dict[str, object] = {}
    # Complete every collision / ownership / content check before any write.
    for title, content in pages.items():
        candidates = by_title[unicodedata.normalize("NFC", title)]
        if not candidates:
            actions[title] = "create"
            continue
        if len(candidates) != 1 or candidates[0]["notebook_id"] not in managed_books:
            raise CLIError("TITLE_CONFLICT", "An index title conflicts with another note.", title=title)
        note = api.fetch(candidates[0]["id"])
        source, _, _ = verified_source(api, note)
        if not source.markdown.startswith(MANAGED + "\n"):
            raise CLIError("TITLE_CONFLICT", "User-authored notes cannot be overwritten.", title=title)
        target = destination(title, index_notebook)
        moved = target not in selected or note.notebook_id != selected[target]["id"]
        changed = source.markdown != content
        known[title] = note
        actions[title] = ("move_update" if changed else "move") if moved else ("update" if changed else "unchanged")
    counts = {kind: sum(v == kind for v in actions.values())
              for kind in ("create", "update", "move", "move_update", "unchanged")}
    missing = [name for name in destinations[1:] if name not in selected]
    if not apply:
        return {"status": "dry_run", "stack": stack, "index_notebook": index_notebook,
                "notebooks_to_create": missing, "placement": {name: sum(destination(t, index_notebook) == name
                    for t in pages) for name in destinations}, **stats, "total_index_notes": len(pages),
                **counts, "preview": [{"title": key, "action": actions[key]} for key in HUBS]}

    _index_journal(api, stack)
    result = {"status": "applied", "stack": stack, "index_notebook": index_notebook, **stats,
              "total_index_notes": len(pages), "created": 0, "updated": 0,
              "moved": 0, "unchanged": 0, "notebooks_created": []}
    for name in missing:
        book = _mutate(api, stack, "create", title=name)
        selected[name] = book
        result["notebooks_created"].append(name)
        if book["stack"] != stack:
            _mutate(api, stack, "stack", target_id=book["id"])
    # Move existing detail notes before publishing any new notes.
    for title in sorted(pages):
        if actions[title] not in ("move", "move_update"):
            continue
        note = known[title]
        target_id = selected[destination(title, index_notebook)]["id"]
        try:
            _mutate(api, stack, "move", note=note, note_id=note.id, target_id=target_id,
                    title=title, html_sha256=sha256(note.html.encode()).hexdigest(),
                    attachments=note.attachments)
        except CLIError as exc:
            exc.details.update(index_title=title, moved=result["moved"])
            raise
        result["moved"] += 1
    # Publish detail pages before hubs. The upload path has its own durable journal.
    with tempfile.TemporaryDirectory(prefix="synonote-index-") as temp:
        path = Path(temp) / "generated.md"
        for title in sorted(pages, key=lambda name: (name in HUBS, name)):
            action = actions[title]
            if action in ("unchanged", "move"):
                result["unchanged"] += 1
                continue
            path.write_text(pages[title], encoding="utf-8")
            target = destination(title, index_notebook)
            try:
                response = upload(api, path, stack=stack, notebook=target,
                                  notebook_id=selected[target]["id"], title=title,
                                  note_id=known[title].id if title in known else None,
                                  overwrite=action != "create", compare_only=False)
            except CLIError as exc:
                exc.details.update(index_title=title, created=result["created"],
                                   updated=result["updated"], moved=result["moved"])
                raise
            if response["status"] != "uploaded":
                raise CLIError("REMOTE_ERROR", "The index status after publishing differs from the expected status.", title=title)
            result["created" if action == "create" else "updated"] += 1
    return result
