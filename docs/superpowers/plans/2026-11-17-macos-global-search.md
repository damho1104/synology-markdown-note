# macOS Global Search Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement the tasks inline. User authorized implementation in a hotfix branch; continue without another approval round.

**Goal:** 맥앱 돋보기/⇧⌘F로 독립 전체 검색 시트를 열고 결과 선택을 공통 탐색 이력에 연결한다.
**Architecture:** LibraryStore의 별도 비동기 검색이 로컬 색인과 요약을 조합한다. GlobalSearchSheet가 검색어/결과/비동기 수명을 소유하고 LibraryView는 표시/결과 열기만 연결한다.
**Tech Stack:** Swift 5.10, SwiftUI macOS 14+, Swift Testing, 기존 SQLite 검색 색인.
**Spec:** ../specs/2026-11-17-macos-global-search-design.md

## Global Constraints

- 현재 `github` 저장소의 `hotfix/macos-global-search`에서 작업하며 부모 저장소 변경을 보존한다.
- 모든 셸 명령은 rtk로 시작한다. 커밋·태그·푸시/배포/운영 데이터 변경은 하지 않는다.
- 목록/고급 검색과 캐시 본문 검색을 보존하며 NAS 통신을 추가하지 않는다.

## Review Focus

- 검색 중 입력 변경/닫기/계정 변경에 따른 오래된 결과 적용 및 선택 방지.
- 현재 메모장·휴지통·그래프·고급 조건에 종속되지 않는 전체 검색.
- 한글 입력 조합 중 Enter가 노트 열기로 처리되지 않는지 실제 UI 확인.
- 검색 결과 선택 후 공통 이력이 그래프 및 모든 검색 조건을 복원하는지 확인.
- 백그라운드 목록 변경 중 검색어와 포커스 보존 및 결과 갱신.

### Task 1: 전체 검색 및 이력 계약

**Files:** `Services/GlobalNoteSearch.swift`, `Stores/NoteNavigationHistory.swift`, `Tests/NoteCoreTests/GlobalNoteSearchTests.swift`, `Tests/NoteCoreTests/NoteNavigationHistoryTests.swift`.
**Interfaces:** `LibraryStore.globalSearch(query: String) async throws -> [NoteSummary]`; `NoteNavigationHistory.openGlobalSearchResult(_: UUID, from: Location) -> Location`.

- [x] 필터 독립/원래 상태 불변, 제목·미리보기·태그·본문 검색, 휴지통 제외, 공백/빈 검색과 정렬, 취소를 테스트로 작성하고 실패 확인.
- [x] 전체 목록 목적지의 검색/고급 조건 초기화와 뒤로/앞으로 복원을 테스트하고 통과 확인.
- [x] 위 인터페이스를 구현하고 대상 테스트 통과 확인.

### Task 2: SwiftUI 시트와 진입점

**Files:** `Views/GlobalSearchSheet.swift`, `Views/LibraryView.swift`.
**Interfaces:** `GlobalSearchSheet(library:onSelect:onClose:)`는 Task 취소/요청 일치 확인과 첫 100개 결과를 담당한다. 선택 시 Task 1의 이력 인터페이스를 호출한다.

- [x] 검색창 자동 포커스, Esc/닫기, Enter 첫 결과, 결과 클릭, 결과 수/빈 결과/오류를 구현한다. IME를 방해하지 않도록 네이티브 TextField onSubmit을 사용한다.
- [x] 돋보기/메뉴 ⇧⌘F를 같은 시트에 연결하고 계정 전환 시 닫는다.
- [x] Swift 전체 테스트, `rtk git diff --check`, 기존 앱 빌드 스크립트로 번들 빌드 및 격리 실행/UI 검증.
- [x] 리뷰 후 인계 문서에 검증 결과와 남은 제한을 기록한다.

## Execution ledger

- 기준: main `6fd5674`, Swift 337 tests / 36 suites 통과.
- Ruling: 사용자가 hotfix 브랜치 작업을 요청했으므로 깨끗한 중첩 저장소에서 직접 브랜치를 생성한다. 별도 worktree/추가 승인/커밋은 만들지 않는다.
- Task 1: complete — 기존 필터 경로에서 신규 검색 테스트 4개/9 issues 실패 확인 후 수정, 대상 19개 통과. 새 이력 API는 최초 구현부터 통과했으며 별도 의도적 실패 검사는 수행하지 않았다.
- Review fix: 요약 불변/HTML 본문 변경을 로컬 repository observeRemote→mergeRemote로 재현, 새 요청 무효화 테스트 1개 실패 확인. 성공한 LibraryStore.reload마다 searchIndexRevision을 갱신해 수정. 재리뷰 추가 결함 없음.
- Task 2: complete — 최종 Swift 344 tests / 37 suites passed, 앱 번들 빌드·서명·격리 실행 및 CUA UI 확인, diff check 통과.
- UI: 자동 포커스, 106개 활성 노트/100개 표시 안내, 본문·태그·미리보기 검색, 휴지통 제외, Enter/클릭 열기, ⇧⌘F, Esc/X 닫기, 0개 결과, 메모장/목록 검색어 및 그래프 복원, 앞으로 가기 확인.
- UI 한계: 한글은 붙여넣기로 확인했으며 실제 입력기 조합 중 Enter·실제 NAS 계정 전환·다운로드 중 팝업 갱신은 직접 조작하지 않았다. 본문 갱신은 회귀 테스트로 검증했다.
