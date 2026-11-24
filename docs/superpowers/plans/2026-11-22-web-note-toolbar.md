# Web Note Toolbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 웹에서 기존 메모의 형식을 유지하며 Mac 앱과 같은 편집 명령을 제공한다.

**Architecture:** 웹의 원본 구간 편집을 확장한다. 서버가 구조 명령 및 NAS 버전을 검증하고, 첨부는 기존 전송·복구 흐름을 확장해서 처리한다.

**Tech Stack:** React, TypeScript, Vitest, FastAPI, Python, pytest.

**Spec:** `docs/superpowers/specs/2026-11-22-web-note-toolbar-design.md`

## Global Constraints

- 새 메모는 Markdown, 기존 메모는 저장된 형식. 전체 툴바 위에 별도 편집 영역 라벨을 표시하지 않는다.
- 모드 전환·자동 변환 없음. 읽기·선택만으로 쓰지 않는다.
- 원문·분할·읽기 토글은 Markdown 편집기에만 표시한다. 다른 메모는 이전 보기 설정과 무관하게 단일 편집기를 연다.
- 수정 구간 밖 원본, 기존 첨부·참조, 충돌 및 불확실 저장 보호 유지.
- `hotfix/web-original-editor-parity`에서 작업. 포럼·릴리스·운영 NAS는 변경하지 않는다.

## Review Focus

- 선택이 이모지나 여러 서식에 걸쳐도 구간을 잘못 자르지 않는다 — 1.
- 링크 입력과 지원하지 않는 병합 표는 안전하게 거절한다 — 1.
- 새 메모와 저장된 Markdown 메모는 전체 툴바로 전환되지 않는다 — 2.
- NAS에 먼저 들어간 다른 기기의 편집을 실행 취소가 덮어쓰지 않는다 — 3.
- 첨부 저장 응답 유실 뒤 중복 첨부를 만들지 않는다 — 4.

### 1. 원본을 보존하는 서식과 표 명령

**Files:** `web/backend/synonote_web/html_structure.py`, `web/backend/synonote_web/main.py`, `web/backend/tests/`.

- [ ] `apply_structure(source: str, edit: dict) -> str` 계약 테스트 추가: 문단·글꼴·크기·색·첨자·정렬·목록·체크·들여쓰기·서식 지우기·링크·표 명령마다 예상 변경 구간과 동일한 바깥 원문을 assert. 이모지 UTF-16 경계, 중첩 선택, 허용하지 않는 링크, 병합 표, 표 크기 30×20 상한을 포함한다.
- [ ] `uv run pytest`로 새 명령 테스트가 먼저 실패하는지 확인한다.
- [ ] 기존 `structure_edit`에 명령별 필드를 검증하는 타입을 추가하고, `apply_structure`에서 확인된 위치만 구간 교체한다. 문단·셀에 대응하는 식별자는 현재 버전에서 다시 검증한다.
- [ ] 백엔드 테스트로 지원 명령, 잘못된 선택 거절, 원본 보존, 기존 4종 서식과 표 회귀를 확인한다.

### 2. 웹 편집기 툴바

**Files:** `web/frontend/src/OriginalEditor.tsx`, `web/frontend/src/OriginalEditor.test.tsx`, `web/frontend/src/Workspace.tsx`, `web/frontend/src/Workspace.test.tsx`.

- [ ] `OriginalEditor` 테스트에서 스크린샷의 각 명령이 선택 좌표와 함께 `onStructureEdit`로 전달되는지, 보이지 않거나 비활성화돼야 하는 경우를 확인한다. `Workspace` 테스트에서 새 메모와 기존 Markdown에 전체 툴바가 없고 토글은 유지되며, Markdown 읽기 보기에서 다른 메모로 이동해도 토글 없이 단일 편집기가 열리고 열기·선택만으로 저장되지 않는지 확인한다.
- [ ] 프런트엔드 테스트로 실패를 확인한다.
- [ ] 툴바를 제목 아래에 별도 라벨 없이 배치하고 `StructureEdit`에 1번 서버와 같은 필드를 사용한다. 링크·표 입력이 편집기 선택을 잃지 않도록 복원한다.
- [ ] `npm test -- --run`과 `npm run build`로 확인한다.

### 3. 실행 취소와 다시 실행

**Files:** `web/backend/synonote_web/nas.py`, `web/backend/synonote_web/main.py`, `web/frontend/src/Workspace.tsx`, 백엔드 저장 테스트 및 `Workspace.test.tsx`.

- [ ] 확정된 저장에서만 취소 항목이 생기고, 취소 후 재실행이 가능하며, 새 편집 후 재실행이 사라지는 테스트를 작성한다. 다른 기기가 NAS 버전을 바꿨다면 쓰기 호출이 없어야 한다.
- [ ] 새 테스트가 실패하는지 확인한다.
- [ ] 노트별 현재 편집 세션에 승인된 변경의 역방향·정방향 이력을 관리한다. 적용 시 원본 저장 경로에서 버전 일치를 확인한다. 이미 NAS에 보낸 파일을 취소·재실행 동작으로 자동 삭제하거나 중복 전송하지 않는다.
- [ ] 취소·재실행과 기존 버전 충돌·응답 유실 테스트를 실행한다.

### 4. 첨부와 실제 사용 흐름

**Files:** `web/backend/synonote_web/main.py`, `web/backend/synonote_web/nas.py`, `web/frontend/src/Workspace.tsx`, `web/frontend/src/Workspace.test.tsx`, `web/README.md`.

- [ ] 기존 메모에서 첨부 하나를 골라 저장한 뒤 형식과 기존 첨부가 그대로이고, 응답 유실 뒤 자동 재전송이 없는지 테스트한다. Markdown 첨부는 회귀 검증한다.
- [ ] 새 테스트 실패를 확인한다.
- [ ] 기존 임시 첨부 전송·저장 확인·복구를 재사용해 동일 노트에 첨부를 추가한다. 툴바의 ‘첨부’에서 파일을 선택하되 선택 취소에는 아무 쓰기도 발생하지 않는다.
- [ ] 전체 백엔드·프런트엔드 테스트와 빌드를 검증한다. Aside에서 로컬 웹·모의 NAS로 실제 조작, 재열기, 첨부, 실행 취소·다시 실행을 확인한다. 운영 NAS 결과와 혼동하지 않는다.
- [ ] 스크린샷의 각 명령과 설계 제약을 대조하고 브랜치 및 diff를 검토한다.
