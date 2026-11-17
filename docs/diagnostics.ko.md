# Synology Markdown Note 진단 로그

[English](diagnostics.md) | **한국어**

설정 → 진단 → 진단 로그 → 로그 폴더 열기에서 확인한다.

## 개발자 진단 자료 내보내기

설정 → 진단 → 개발자에게 전달할 진단 자료에서 두 가지 ZIP을 저장할 수 있다. 저장 위치를 사용자가 고르며 자동 전송하지 않는다.

- **진단 자료 내보내기**: 현재 선택한 계정의 DB 상태 보고서와 현재·이전 진단 로그를 함께 포함한다. DB 보고서는 SQLite·스키마 버전, 무결성 검사 결과, 페이지 수·크기·빈 페이지, 정해진 테이블의 행 개수, 동기화 상태별 개수, FTS 고아·누락·불일치 행 개수, 백업 개수·총용량으로 제한한다. 실행 중인 저장소의 연결에서 읽기 트랜잭션으로 일관된 상태를 조회하며 원본 DB를 복사하지 않는다.
- **로그만 내보내기**: DB 보고서 없이 현재 및 이전 로그를 설정한 보관 개수 한도 안에서 포함한다. DB 상태 조회가 실패할 때도 로그만 저장할 수 있다.

두 방식 모두 앱·OS 버전과 내보내기 시각, 포함 파일 수, 제외한 손상 로그 줄 수를 기록한다. 계정·노트·메모장 식별자는 ZIP 안에서만 통하는 별칭으로 바꾸고 대응표는 포함하지 않는다. 로그는 원문 복사가 아니라 이벤트·필드·값 허용 목록으로 재구성한다. 알 수 없는 이벤트·손상 줄·허용되지 않은 값은 제외한다. 로그에는 여러 계정의 동작이 포함될 수 있지만 식별자는 모두 익명화한다.

원본 DB, 노트 제목·본문·수정 이력 내용, 첨부파일, NAS 주소·사용자 이름·경로·Keychain 정보는 포함하지 않는다. 작업 시각, 오류 코드, 개수·용량은 진단을 위해 포함하므로 완전한 무정보 자료는 아니다. 원본 로그·DB는 변경하지 않으며, 진단 ZIP은 노트 복원용 백업이 아니다.

DB 열기·무결성 검사·인덱스 재구성·공간 회수·백업·복구·복구 되돌리기는 `database.maintenance`로 기록한다. `operation`과 `phase=started/completed/failed`, 소요 시간(ms), 단계에 따라 행 개수·DB 용량·빈 페이지·백업 개수를 포함한다. 오류 설명 원문은 기록하지 않는다. `diagnostic.export`는 내보내기 시작·완료·실패를 기록하며 저장 경로는 기록하지 않는다. 백업 주기가 아직 지나지 않아 작업을 생략한 경우에는 반복 로그를 남기지 않는다.

## 로컬 진단 로그

기본 위치는 `~/Library/Application Support/SynologyMarkdown/logs/`다. 현재 로그는 `app.jsonl`, 이전 로그는 `app.1.jsonl`부터 순서대로 보관한다. 기본값은 파일당 2 MiB, 현재 파일 포함 최대 4개, 전체 합계 8 MiB다. 설정 → 진단 → 로그 회전·보관에서 파일당 용량(1·2·5·10 MiB), 보관 개수(1~20개), 전체 용량(1~64 MiB)을 변경할 수 있다. 설정은 재시작 후에도 유지되며 모든 계정의 공통 진단 로그에 적용된다. 새 로그 한 건을 기록하기 전에 파일 크기·개수·전체 크기를 검사하며, 한도를 넘기기 전에 회전하거나 오래된 파일부터 삭제한다. 전체 한도가 파일당 한도보다 작으면 전체 한도를 우선 적용한다. 한도를 낮추거나 앱을 다시 시작할 때도 기존 로그를 정리한다. 너무 큰 파일은 최근의 완전한 JSON 줄만 남긴다. 단일 이벤트가 파일 한도보다 크면 파일 기록을 생략하고 오류를 알린다. ‘지금 로그 회전’은 현재 로그를 이전 파일로 넘기고 새 파일을 준비한다. 원본 DB·백업·그 밖의 파일은 이 보관 정책으로 삭제하지 않는다. OSLog의 보관은 macOS가 관리한다.

폴더 권한은 0700, 파일 권한은 0600이다. 로그 파일 기록에 실패해도 노트 저장과 동기화는 계속된다.

각 줄은 독립적인 JSON이다. UTC 시각, 이벤트 이름, 앱 버전·빌드, 프로세스 ID, 계정 키 일부, 노트/메모장 ID, 변경 번호, 전송 대기 수, 오류 종류·코드를 기록한다. 비밀번호·OTP·기기 토큰·세션 ID·서버 URL·노트 제목·본문·첨부 바이트·오류 설명 원문은 기록하지 않는다.

주요 이벤트:

- `connection.started`, `connection.succeeded`, `connection.failed`, `connection.recovery`: 접속과 복구.
- `note.created`, `note.saved`, `note.save_failed`, `note.imported`: 기기 저장과 가져오기.
- `note.delete_requested`, `note.deleted`, `note.delete_failed`, `note.delete_cache_failed`: 휴지통 영구 삭제와 기기 사본 정리. NAS 삭제 확인 전에는 기기 사본을 지우지 않는다.
- `upload.started`, `upload.completed`, `upload.pending`, `upload.failed`: NAS 업로드와 확인. `pending`이 남아 있으면 전송 완료로 판단하지 않는다. 실패 이벤트의 `error_kind`와 `error_code`로 API/HTTP/네트워크 오류를 구분한다.
- `notebook.migrating`, `notebook.migrated`: 이전 로컬 메모장을 NAS로 전환.
- `notebook.created`, `notebook.renamed`, `notebook.delete_requested`, `notebook.deleted`, `notebook.delete_failed`: 메모장 작업.
- `stack.mutation_started`, `stack.mutation_completed`, `stack.mutation_failed`: 책장 생성·이동·이름 변경의 실행 단계 및 실패 원인. 이름 변경은 `state=rename`, `rename.waiting`, `rename.nas`, `rename.local`로 구분한다.
- `inspector.requested`, `inspector.opened`, `inspector.closed`: 정보 패널. 요청은 있지만 열림 기록이 없으면 패널 생성 중 종료됐는지 macOS 진단 보고서와 함께 확인한다.

시스템 로그에도 subsystem `com.damho.SynologyMarkdown`, category `Diagnostics`로 이벤트를 기록한다. 시스템 로그의 부가 메타데이터는 비공개로 표시한다. 앱 종료 시의 스택은 macOS가 `~/Library/Logs/DiagnosticReports/`에 작성하는 `.ips` 보고서로 확인한다. 앱이 비정상 종료되면 종료 직전 이벤트까지 남을 수 있으며, `app.terminating`은 정상 종료 요청에 대한 기록이다.

```sh
rtk proxy /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.damho.SynologyMarkdown" AND category == "Diagnostics"'
```

빌드 5부터 저장 검증 오류는 `error_kind=readback_verification`, 반영 여부 불명은 `write_uncertain`, 실제 버전 충돌은 `remote_changed` 또는 `version_conflict`로 구분한다. 코드 블록의 허용된 HTML 표현 차이는 서버에서 읽은 실제 HTML을 지문으로 기록해 확인하며, Markdown 원문과 보존 블록의 무결성 검사는 유지한다.
