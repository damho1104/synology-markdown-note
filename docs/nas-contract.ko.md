# Note Station HTTP·저장·동기화 계약

[English](nas-contract.md) | **한국어**

갱신일: 2026-11-07 (Asia/Seoul). 대상: 1.2.12-<GIT_COMMIT_SHORT_HASH>, 빌드 23의 현재 코드.

초기 HTTP 어댑터는 읽기만 활성화했지만 현재 앱은 노트·첨부 자동 업로드와 메모장·휴지통 관리를 제공합니다. 이 문서는 현재 동작을 기준으로 작성했으며 과거 NAS 진단 결과와 이번 로컬 테스트를 구분합니다.

## 근거와 검증 범위

- 구현: `NoteStationClient`, `NoteStationSyncTransport`, `SyncCoordinator`, `NoteRepository`, `SourceEnvelope`와 앱의 `Services/`.
- API 조사: 공식 클라이언트 3.0.0-883의 호출 구조를 참고했습니다. 공식 앱 코드 전체는 복제하지 않았습니다.
- 2026-10-16: `rtk proxy ./script/test.sh`, 175개 테스트 / 20개 스위트 통과. API는 합성 응답으로 검사하며 미리보기는 실제 WebKit에서도 검사합니다.
- 과거 NAS 진단 기록: 전용 노트의 수정·버전 충돌 거절, 이미지·Markdown 원문 바이트 왕복, 기기 토큰 저장·재사용과 재실행 자동 로그인이 확인되었습니다. 이번 정리에서는 실제 NAS 접속·쓰기를 재실행하지 않았습니다.
- 공식 앱 편집 후 전체 왕복, 여러 Mac 동시 편집, 다른 Mac 설치, 모든 DSM 버전의 호환성을 검증한 것은 아닙니다.
- 2026-10-17: 책장(Stack) 기능을 공식 클라이언트 3.0.0-883 코드와 합성 NAS 요청/응답으로 검사했습니다. 실제 NAS에서 책장 생성·변경·삭제와 공식 앱 간 왕복은 아직 재검증하지 않았습니다.

## HTTP 클라이언트와 쓰기 활성화

`NoteStationClient`는 actor입니다. 생성자는 `init(baseURL:session:allowsValidatedWrites:)`이며 마지막 인자의 기본값은 false입니다. `supportsReads=true`, `supportsEncryptedNotes=false`, `supportsWrites=allowsValidatedWrites`입니다. 앱의 `LibraryStore.connect`는 쓰기를 true로 활성화합니다. 일반 자동 업로드는 진단 보고서나 과거 자동 업로드 꺼짐 설정에 의존하지 않습니다.

주요 공개 API는 다음과 같습니다. actor 외부에서는 연결 해제도 await로 호출합니다.

| API | 용도 |
| --- | --- |
| `connect(username:password:otp:rememberDevice:deviceID:)` | 로그인·기기 기억 |
| `disconnect()`, `isAuthenticated`, `trustedDeviceID` | 로컬 세션 폐기·인증·기기 토큰 상태 |
| `notebooks()`, `createNotebook(name:)`, `renameNotebook(notebookID:name:)`, `deleteNotebook(notebookID:)` | 메모장 관리 |
| `moveNotebooksToStack(ids:name:creatingNew:)`, `renameStack(from:to:)`, `deleteStack(name:)` | 책장 관리·메모장 소속 변경 |
| `notes()`, `fetch(noteID:)`, `versionHistory(noteID:)`, `download(fileID:noteID:)` | 조회·첨부 |
| `update(noteID:baseVersion:title:html:)`, `permanentlyDeleteNote(noteID:baseVersion:)` | 버전 기준 수정·휴지통 영구 삭제 |

연결 해제는 SID·캐시·기기 토큰을 인스턴스 메모리에서 폐기합니다. 서버 로그아웃이나 URLSession 무효화는 수행하지 않습니다. 연결 세대 식별자로 이전 요청의 늦은 응답을 거부합니다.

## 주소·인증·요청 인코딩

- NAS HTTPS 루트 또는 역방향 프록시 접두 경로 아래 `webapi/`를 사용합니다. 예: `https://nas.example.invalid:5001/`, `https://example.invalid/nas`.
- 사용자 정보·쿼리·fragment가 포함된 baseURL, HTTP, 외부 origin 또는 webapi 밖으로 벗어나는 API 경로는 거절합니다. HTTP 리디렉션·인증서 검증 우회·QuickConnect ID 탐색은 지원하지 않습니다.
- 로그인 전 Auth를 탐색하고 로그인 후 전체 API를 탐색합니다. Auth는 지원 범위 내 v6을 우선하며 서버 최소 버전이 더 높으면 그 최소 버전을 사용합니다.
- 기기 기억은 `enable_device_token=yes`, `device_name`, 응답 `did`, 다음 요청의 `device_id`를 사용합니다. 새 OTP 입력 시 이전 device ID를 보내지 않습니다. OTP는 저장하지 않습니다.
- CGI·Auth는 원시 인자를, JSON WebAPI는 JSON 직렬화한 값을 폼 인코딩합니다. RFC 3986 unreserved 문자 외를 퍼센트 인코딩합니다.
- 일반 폼 요청의 인증 인자는 본문에 있습니다. 첨부 multipart는 공식 계약에 맞춰 `api/method/version/_sid`를 URL 쿼리에, 노트 인자·바이너리를 multipart 본문에 넣습니다. 따라서 인증된 multipart URL도 비밀 정보로 취급하며 로그에 기록하지 않습니다.
- 요청은 URLSession 캐시를 우회하고 쿠키 처리를 끕니다. HTTP 계층은 요청·응답 본문이나 인증 인자를 로깅하지 않습니다.

## API·응답 매핑

| 작업 | API / 메서드 | 버전·계약 |
| --- | --- | --- |
| 인증 | `SYNO.API.Auth/login` | 탐색된 범위, v6 우선, notestation 세션 |
| 메모장 | `SYNO.NoteStation.Notebook/list/create/set/delete` | v2, 삭제 시 recursive=false |
| 책장 소속 | `SYNO.NoteStation.Notebook/set` | v2, object_id 배열과 stack 문자열, 해제는 빈 문자열 |
| 책장 이름 변경·삭제 | `SYNO.NoteStation.Stack/set/delete` | v1, stack_id는 책장 이름과 owner UID 결합 |
| 노트 | `SYNO.NoteStation.Note/list/get/create/set` | v2/v3, 수정 시 object_id/ver/check_conflict=true |
| 영구 삭제 | `SYNO.NoteStation.Note/delete` | v3, recycle=false, 휴지통·현재 버전 사전 확인 |
| 즐겨찾기 | `SYNO.NoteStation.Shortcut/list/set/delete` | v1, category=note의 ID 결합 |
| 태그 보완 | `SYNO.NoteStation.Tag/list` | v1, tag 누락 시 items의 노트 ID 결합 |
| 수정 이력 | `SYNO.NoteStation.Note.Version/list` | v2, filter={listable:true}, versions[].version/mtime |
| 첨부 다운로드 | `SYNO.NoteStation.Note/download` | v1, file_id/object_id/format=raw/mode=download |
| 첨부 생성·제거 | 노트 create/set의 attachment | 바이너리는 multipart, 제거는 action=delete/file_id |

object_id/title/parent_id/ver/mtime/tag/recycle/encrypt를 노트 요약으로 변환합니다. mtime은 Unix 초이며 버전은 숫자로 비교하지 않는 불투명 문자열입니다. 첨부 사전의 키는 파일 ID, 값의 name/type/ref는 파일명·MIME·참조입니다. 각 API는 탐색한 지원 범위와 구현 상한의 교집합을 사용합니다.

목록은 offset/limit로 끝까지 읽고 총 개수·offset·중복 ID·필수 필드·완료 전 빈 페이지를 검증합니다. 정상 빈 목록의 null·필드 생략은 허용하고 부분 실패를 빈 목록이나 성공으로 바꾸지 않습니다. 본문 버전은 본문 응답에서 확인하며 목록 버전만으로 최신이라고 표시하지 않습니다. 안정적인 서버 snapshot cursor는 확인하지 못했습니다.

암호화 노트는 잠금 상태로 표시하고 본문 편집·복호화를 지원하지 않습니다. 다운로드는 원본 바이트를 반환하되 Synology 실패 envelope는 파일로 반환하지 않습니다. 정상 JSON 파일 자체가 실패 envelope와 같은 모양이면 구별할 수 없는 제한이 있습니다.

## 로컬 저장·Markdown 원문

`NoteRepository` actor가 계정별 notes.sqlite3 연결을 소유합니다. WAL·synchronous=FULL·외래 키를 사용하고 노트·전체 수정 이력·전송 대기 작업·전송 시도·검색 텍스트·영구 삭제 표식을 저장합니다. 트랜잭션 안에서는 네트워크 요청을 실행하지 않습니다. 첨부는 별도 파일에 보관하고 해시로 검증합니다.

서버용 Markdown HTML과 미리보기 장식을 분리하되 두 경로 모두 CommonMark 처리 전에 TeX 구분자·역슬래시를 보호합니다. 동기화 때 오프라인 KaTeX를 흰 배경 PNG로 렌더링하여 일반 Note Station 이미지 첨부로 게시합니다. 같은 수식은 재사용하고 삭제된 수식의 생성 이미지는 버전 검사 후 정리합니다. 코드·링크·원본 HTML의 리터럴 수식 예제는 이미지로 바꾸지 않습니다. `SourceEnvelope`는 메타데이터 주석 뒤에 정확한 UTF-8 Markdown 원문을 보관하는 .md 첨부입니다. 본문·원문·보존 블록·첨부 매핑의 SHA-256 지문과 문서·작업 ID를 검증합니다. v1/v2/v3 읽기를 지원합니다. 수식 이미지가 있으면 크기·수식 키·첨부 ID와 그 지문을 포함한 v3를 게시하며, 일반 업로드의 작업 ID·staging·첨부 매핑은 v2를 사용합니다.

본문과 일치하는 원문이 하나이고 첨부 UUID를 복원할 수 있어야 Markdown 모드로 엽니다. 이전 원문·모호한 참조는 원본 HTML 서식 편집 모드로 엽니다. 기존 문서는 Markdown으로 변환하지 않고 바로 편집하며, 로컬 이력과 버전 검사 후 HTML 본문을 저장합니다. 복잡한 HTML은 보존 블록으로 유지하며 첨부 제거 전에 Markdown·렌더링 본문·활성 보존 블록에서 참조를 확인합니다.

검색은 정규화한 별도 텍스트 테이블의 instr 부분 검색이며 FTS는 아닙니다. 수정 이력과 일반 첨부 캐시의 자동 기간·용량 제한은 아직 제공하지 않습니다.

## 자동 업로드·복구·충돌

편집 후 약 250ms에 로컬 저장하고 약 900ms 뒤 업로드를 예약합니다. 연결 중 업로드 재확인은 15초, 목록 갱신은 60초 간격입니다. 네트워크·잠자기 복귀에도 연결·목록을 확인합니다.

1. 첨부 바이트·보존 블록을 검증하고 기존 노트의 기준 서버 버전을 확인합니다.
2. 쓰기 전에 SQLite 전송 시도를 기록하고 파일 journal을 원자적으로 갱신합니다.
3. Markdown 노트는 첨부·staging 원문 준비 → 본문·메타데이터 저장 → 최신 원문 게시·이전 프로토콜 첨부 정리 순서입니다. 각 수정 요청에 버전 충돌 검사를 보냅니다. 원본 HTML 모드는 새 첨부가 있으면 먼저 준비하고 편집된 HTML·메타데이터·명시적으로 제거한 첨부를 버전 검사해 저장합니다. 본문이 바뀌지 않았으면 본문 필드를 보내지 않습니다. 로컬 attachment URL은 대상 태그만 치환하여 다른 표·코드·위젯의 원문을 유지합니다.
4. 재조회에서 제목·메모장·태그·휴지통·즐겨찾기·원문·첨부를 확인한 뒤 완료를 기록합니다. 업로드 중 생긴 최신 로컬 변경은 다음 전송 대상으로 남깁니다.
5. 응답 유실 시 journal과 서버를 대조합니다. 생성 대상은 제목만으로 채택하지 않고 작업 UUID·staging 첨부 바이트로 확인합니다. 기준 버전이나 반영 상태를 입증할 수 없으면 보류하며 자동 중복 생성하지 않습니다.

노트별 실패를 격리합니다. 충돌하면 양쪽 내용을 보관하고 비교·선택하도록 합니다. 서버 버전 선택 시 로컬 이력을, 로컬 버전 선택 시 서버 사본을 보존합니다. 자동 병합이나 여러 요청 전체의 서버 트랜잭션을 의미하지 않습니다.

앱 연결 복구는 세션 만료·일시적 통신 오류에 지수 지연을 적용하고 저장된 계정으로 한 번에 하나의 연결만 시도합니다. 인증·OTP 오류나 Keychain 실패는 사용자 조치가 필요합니다. 수동 연결 해제 후 자동 재연결하지 않습니다. HTTP actor 자체는 로그인 자동 재시도를 하지 않습니다.

## 메모장·삭제·오프라인

- 메모장 생성 후 목록에서 ID·이름을 확인합니다. 불분명한 생성은 receipt를 보관하고 무조건 재생성하지 않습니다.
- 이전 빌드에서 해당 NAS 계정에 로컬로 만든 메모장·노트는 NAS로 이전합니다. 현재 새 노트·Markdown 가져오기의 목적지는 NAS 메모장입니다.
- 메모장 삭제는 미전송 변경이 있으면 차단하고 삭제 확인 후 포함 노트를 휴지통 상태로 반영합니다.
- 노트 영구 삭제는 연결된 상태의 동기화 완료 휴지통 노트만 허용합니다. 현재 버전 확인·삭제 후 부재 확인을 거쳐 로컬 이력·미사용 첨부를 정리합니다. 삭제 표식이 늦은 응답에 의한 재생성을 막습니다.
- 오프라인 보관은 미열람·이전 버전 본문·첨부를 백그라운드로 가져옵니다. 잠금 노트 제외, 실패 격리, 미저장·미전송 변경 보호와 업로드 우선을 적용합니다.

## Keychain·로그

별도 service `cloud.synology-note.notestation.password.v1`에 비밀번호·기기 토큰을 저장합니다. NAS 주소·사용자 이름의 계정 범위 키를 사용하고 공식 앱의 자격 증명을 재사용하지 않습니다. OTP는 저장하지 않으며 SID는 메모리에만 둡니다. 기존 UTF-8 비밀번호 형식도 읽습니다.

앱 번들은 서명이 고정된 helper를 통해 접근하며 앱·helper가 서로 동일 인증서와 예상 식별자를 검사합니다. 자동 읽기는 비대화식·시간 제한을 적용하고 사용자 요청만 대화식을 허용합니다. 인증서·helper 변경 시 접근 재승인이 필요할 수 있습니다. [개발 서명 안내](development-signing.ko.md)를 참고하세요.

진단 로그는 허용된 이벤트·식별자·오류 종류·숫자 코드만 기록하며 본문·비밀번호·SID·토큰·원시 요청 URL을 기록하지 않습니다. JSONL은 기본 파일당 2MiB와 백업 3개로 회전합니다. 상세는 [진단 로그](diagnostics.ko.md)에 있습니다.

## 진단과 남은 검증

설정의 생성·수정/충돌·이미지/원문·자동 업로드 검사는 사용자가 명시적으로 실행하며 선택한 메모장에 전용 검증 노트를 생성합니다. 일반 업로드의 필수 활성화 절차가 아니고 검증 노트는 자동 삭제하지 않습니다. 결과는 계정별 진단 JSON에 보존합니다.

과거 첨부 검사 오류 101은 multipart 라우팅 인자를 쿼리로 옮긴 뒤 전용 노트 재검사에서 해소되었고 이미지·원문 바이트 일치와 Markdown 복원이 기록되었습니다. Auth v6 선택 후 기기 토큰 저장·동일 서명 번들의 재실행 자동 연결도 기록되었습니다. 모든 NAS·모든 서명 번들의 보장은 아닙니다.

전체 회귀 검사는 `rtk proxy ./script/test.sh`로 실행합니다. 남은 검증은 공식 앱 편집 후 왕복, 여러 Mac 동시 저장, 다단계 쓰기 도중 실제 네트워크 단절, 대규모 성능, 다른 Mac 설치·Keychain 접근입니다. Intel/universal·Developer ID·Apple 공증은 [배포 안내](distribution.ko.md)를 참고하세요.
