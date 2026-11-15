# Web Client 구현 계획 / 1차 실행 범위

기준: `feature/web-client`, 기존 macOS/CLI 기능 보존, 최종 설계 `../specs/2026-11-15-synonote-web-client-design.md` 및 `../../nas-contract.ko.md`.

## 보안·운영 확정 사항

1. **부트스트랩**: 설정 전 `/data/setup-code`에 자동 생성되는 소유자 전용(0600) 랜덤 코드를 읽어 1회 등록한다. 코드는 API로 공개하지 않고 성공 시 삭제한다. 실패 횟수는 접속 피어별 15분간 최대 6회로 제한한다. 관리자 재설정·주소 변경은 후속 단계에서 안전한 전환 도구로 구현한다.
2. **단일 NAS**: `NAS_URL` 우선, 다음 SQLite, 없으면 최초 설정. 환경변수의 잘못된 비어 있지 않은 URL은 설정 오류로 표시한다. 공개 DNS/IP만 기본 허용하며 LAN NAS 연결은 관리자가 `NAS_ALLOW_PRIVATE=true`를 명시해야 한다. URL에 사용자 정보, 쿼리, fragment, 인코딩 경로, dot segment 등을 허용하지 않는다. 모든 HTTPS 요청에서 DNS 주소를 검증하고 해당 IP로 연결을 고정하며 TLS 호스트명 검증을 유지한다. 프록시·리디렉션은 사용하지 않는다. CA가 필요한 운영자는 읽기 전용 CA 파일을 마운트한다.
3. **브라우저 origin**: API는 CORS를 제공하지 않는다. 변경 요청은 JSON `Content-Type`과 정확한 Origin을 요구한다. HTTPS 역방향 프록시는 `WEB_PUBLIC_ORIGIN`을 지정한다. 쿠키는 기본 Secure/HttpOnly/SameSite=Strict이고 개발 localhost HTTP에서만 `WEB_COOKIE_SECURE=false` 설정을 허용한다. 초기 버전의 Docker 서버는 `--no-proxy-headers`, 단일 워커로 운영한다.
4. **세션/로그인 유지**: 체크 해제는 메모리 세션(쿠키는 브라우저 세션 쿠키, 유휴 12시간/절대 24시간)만 사용한다. 체크 선택 시 랜덤 토큰 해시/CSRF/계정 이름/암호화된 비밀번호와 선택한 신뢰 기기 ID를 SQLite에 저장한다. 브라우저 쿠키 만료 및 DB 최대 만료는 30일이며 7일 이상 사용한 토큰은 갱신한다. 서버 재시작 후 저장된 암호로 NAS 인증을 다시 수행한다. OTP가 필요하거나 자격 증명이 거절되면 사용자가 로그인한다. NAS 서버는 자동 로그인에 실패한 네트워크 오류를 자격 증명 삭제와 구분한다. 암호키는 `/data/master.key`에 최초 생성하고 0600으로 보관한다. 키/DB 백업·복구는 운영자가 관리하고 키 회전은 후속 운영 기능이다.
5. **권한 범위**: 이 단계에서는 NAS `SYNO.API.Info` 조회와 `SYNO.API.Auth/login`만 허용한다. NAS의 노트 생성·수정·삭제는 아직 없다. 추후 사용자별 노트 데이터 격리·원문/첨부 검증·버전 충돌·오프라인 큐가 검증된 이후에만 쓰기 엔드포인트를 연다. 실 NAS 쓰기 검사는 별도의 테스트 노트에서만 진행한다.

## 단계별 구현 순서와 통과 기준

| 순서 | 구현 | 검증 |
| --- | --- | --- |
| P1-a | React/TS/Vite·Tailwind/shadcn/ui 골격, FastAPI + SQLite, Dockerfile/Compose | TS 빌드·Python import·Compose 구성 검사·컨테이너 health |
| P1-b | 최초 설정 코드, NAS_URL 우선순위, URL/SSRF/TLS 정책 | 초기 설정 권한/주소 변경 차단/재시작 복원·잘못된 URL·차단 IP·DNS 테스트 |
| P1-c | NAS 인증 탐색/OTP, 세션/CSRF/로그인 유지 | 모의 NAS 로그인/OTP/로그아웃/재시작·계정 구분·만료·쿠키 검증 |
| P2 | 사용자별 계정 컨텍스트·NAS 읽기 API, 책장/메모장/노트 목록, 검색 | 합성 Note Station API·권한·페이지네이션·UI E2E |
| P3 | CodeMirror6·Markdown 원문/HTML 보존·첨부·KaTeX/Mermaid | Swift/CLI SourceEnvelope v1–v3 계약 fixture·충돌 없는 왕복 |
| P4 | 쓰기 journal·충돌·오프라인 IndexedDB/PWA·백링크/그래프 및 나머지 기능 | 응답 유실/재실행·멀티 사용자·실 NAS 테스트 노트 |
| P5 | 다중 아키텍처 빌드, Container Manager 실장비, CI/GHCR/릴리스 통합 | amd64/arm64 검증, DSM 프로젝트 설치·백업·복구 |

현재 작업에서 **P1만** 구현한다. Docker arm64 실기기, NAS 연결, HTTPS 역방향 프록시 실서비스 동작은 환경을 갖춘 뒤 별도 확인한다. `develop` 병합·GHCR 게시·배포는 추후 요청에 따른다.
