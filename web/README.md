# Synology Markdown Note Web

macOS 앱의 `LibraryView`·`EditorView`를 기준으로 만든 웹 클라이언트입니다. 책장 아래 메모장을 펼치는 사이드바, 제목·추가 날짜·수정 날짜 정렬, 원문·분할·읽기 보기, CodeMirror Markdown 편집, Mermaid 손그림 다이어그램, KaTeX 미리보기, 노트 정보 패널, 내부 링크·그래프·백링크, 첨부 다운로드를 제공합니다. 즐겨찾기·태그 변경, 휴지통 이동/복원, 노트 이동, 책장·메모장 생성·이름 변경·이동을 지원합니다.

## 화면·편집기 설정

사이드바 아래 톱니바퀴는 노트 정보 패널과 별개의 설정 팝업을 엽니다. 화면 모드(시스템·라이트·다크), 편집기 글꼴 크기(11–22px), Markdown 줄 번호·자동 줄바꿈, Mermaid 기본/스케치 스타일과 색상 테마(화면 모드에 맞춤·라이트·다크·무채색·포레스트)를 설정합니다. 변경은 즉시 반영하고 이 브라우저의 localStorage에 저장합니다. 시스템 모드는 OS 화면 변경을 따라갑니다. 설정을 바꾸어도 편집 중인 본문·기준 버전은 유지하며 NAS에 저장하지 않습니다.

Mermaid SVG는 글자 배치에 사용한 폰트와 정렬·색상 스타일을 유지하며, 표시 속성만 허용하고 각 SVG 안으로 범위를 제한합니다. 외부 리소스·스타일 로딩, 스크립트, foreignObject는 허용하지 않습니다.

## 실행

`web/`에서 실행합니다. NAS 주소는 실행 후 웹에서 한 번 입력해도 됩니다.

```sh
docker compose up -d
docker compose exec web cat /data/setup-code
```

브라우저에서 `http://localhost:8787`을 열고 NAS 주소와 위 초기 설정 코드를 입력합니다. 다른 PC에서 접근하려면 `.env.example`을 `.env`로 복사하고 `WEB_BIND_ADDRESS=0.0.0.0`을 설정하거나 기존 HTTPS 프록시를 연결하세요. Registry 인증이 필요한 서버는 먼저 `docker login dr.dmomo.net`을 실행합니다.

**HTTP/HTTPS 쿠키와 접속 origin은 자동 처리합니다. `WEB_PUBLIC_ORIGIN`, `WEB_COOKIE_SECURE`를 일반 설치에서 설정할 필요가 없습니다.** HTTP 접속은 일반 HttpOnly 쿠키, HTTPS 접속은 Secure/HttpOnly `__Host-` 쿠키를 사용합니다. 상태 변경 요청은 브라우저 Origin의 호스트·포트와 요청 Host가 같아야 하며 CSRF 토큰도 검사합니다. HTTPS 역방향 프록시는 브라우저가 사용한 Host를 그대로 전달하세요. 임의 `X-Forwarded-*` 헤더를 신뢰하지 않습니다.

0.2.x의 Compose를 재사용한다면 새 `docker-compose.yaml`로 교체하세요. 예전 YAML을 유지해야 하면 `WEB_COOKIE_SECURE=auto`, `WEB_PUBLIC_ORIGIN=`으로 두어 자동 모드를 선택할 수 있습니다. 프록시가 Host를 바꿔야 하는 특수 배포만 컨테이너 환경변수 `WEB_PUBLIC_ORIGIN`에 프로토콜을 포함한 정확한 origin을 지정합니다. 이전의 명시적 `WEB_COOKIE_SECURE=true/false`도 호환용으로 지원합니다.

## NAS 연결

- `NAS_URL`이 비어 있으면 웹 최초 설정을 사용합니다. 설정한 NAS 주소는 SQLite에 보존됩니다. 환경변수에 주소를 지정하면 그 값이 우선입니다.
- 내부망 NAS 또는 HTTP NAS 연결을 쓰는 경우에만 `NAS_ALLOW_PRIVATE=true`로 설정합니다. false이면 HTTP와 사설 주소 연결을 차단합니다. 웹 브라우저의 HTTP/HTTPS와 NAS 연결의 HTTP/HTTPS는 별개입니다.
- HTTP NAS에서는 비밀번호·OTP·세션·노트 전송이 암호화되지 않습니다. 신뢰하는 내부망에서 사용하세요.
- 사설 CA는 파일을 읽기 전용 마운트하고 `NAS_CA_FILE`을 지정합니다. HTTPS 인증서 검증을 끄는 옵션은 없습니다.
- SSRF 방어를 위해 DNS 주소를 검증한 뒤 IP를 고정해 연결합니다. 루프백·링크 로컬·메타데이터 주소와 리디렉션은 허용하지 않습니다. 컨테이너의 `localhost`는 NAS가 아닌 컨테이너 자신입니다.

## 저장과 호환성

맥 앱·CLI의 `SourceEnvelope` v1/v2/v3 원문 지문을 확인해 기존 Markdown 노트를 읽습니다. 지원하는 Markdown은 임시 원문 등록 → 본문 저장 → 검증된 최종 원문 게시 순서로 저장하며, 매 단계에서 원격 버전과 본문을 다시 확인합니다. 기존 이미지 첨부와 원문 보존 블록을 유지합니다. Mermaid·KaTeX 라이브러리와 폰트는 이미지에 포함되며 CDN에 의존하지 않습니다. 미리보기에서 문서가 포함한 스크립트는 제거합니다. 내부 링크는 nonce로 제한한 자체 전달 코드만 opaque iframe에서 실행하며, 부모는 iframe 출처와 nonce를 검증합니다. 외부 자동 네트워크 요청은 차단합니다.

지원하지 않는 변경을 손실 없이 처리하기 위해 다음은 제한합니다.

- 암호화·휴지통 노트의 본문 편집. 기존 첨부·복합 HTML은 원본 바이트와 속성을 유지하는 텍스트 편집을 지원하며, 원본 서식을 자유롭게 다시 구성하는 편집은 제한합니다.
- 수식 PNG 재생성/업로드, 첨부파일 추가·삭제, 원문 보존 블록의 임의 변경
- 버전 이력 관리와 오프라인 동기화는 아직 macOS와 같은 기능 수준이 아닙니다. 영구 삭제 기능은 이번 범위에서 제공하지 않습니다.

편집본과 기준 버전은 사용자·NAS별로 현재 탭의 sessionStorage에 임시 보관하고 새로고침 후 복원합니다. 탭 종료 시 사라질 수 있습니다. 로그아웃 성공 시 해당 계정의 임시본을 지우며 로그아웃 실패 시 유지합니다. NAS 비밀번호·SID·인증 토큰은 브라우저 저장소에 보관하지 않습니다.

버전 충돌은 내 편집본을 보존한 채 NAS 최신 내용과 비교합니다. 응답 유실 등 결과가 불확실하면 자동 재시도하지 않습니다. 서버에 암호화한 쓰기 의도와 대상 잠금을 보존하므로 Note Station에서 저장 결과를 확인한 뒤 보류를 해제하세요. 진행 중인 작업은 1시간 동안 해제할 수 없습니다.

## 데이터 보관과 권한

기본 `WEB_DATA_PATH=synonote-web-data`는 Docker named volume입니다. 컨테이너는 **UID/GID 10001:10001**로 실행합니다. 새 볼륨은 이미지의 `/data` 소유권을 상속합니다.

NAS 폴더를 직접 연결하려면 새 빈 폴더만 준비하고 `.env`의 `WEB_DATA_PATH`를 지정합니다.

```sh
sudo mkdir -p /volume1/docker/synonote-web/data
sudo chown 10001:10001 /volume1/docker/synonote-web/data
sudo chmod 700 /volume1/docker/synonote-web/data
```

`/data`는 0700, SQLite·키 파일은 0600을 사용합니다. 기존 파일의 소유권을 일괄 변경하거나 777로 열지 마세요. 업데이트·백업 전에 서비스를 중지하고 **`/data` 전체**를 보관합니다. SQLite `-wal`/`-shm`을 포함하고 `web.sqlite3`와 `master.key`를 함께 백업해야 합니다. 키를 잃으면 로그인 유지 정보와 암호화된 저장 의도를 복구할 수 없습니다. `docker compose down -v`는 데이터를 삭제하므로 실행하지 마세요.

로그인 유지 사용 시에만 비밀번호·신뢰 기기 ID를 서버에 암호화해 저장합니다. OTP는 저장하지 않습니다. 일반 세션은 최대 24시간/12시간 미사용, 로그인 유지 세션은 최대 30일/7일 미사용으로 만료됩니다.

## 업데이트와 검증

이미지: `dr.dmomo.net/damho1104/synonote-web:0.4.1` (`linux/amd64`, `linux/arm64`). 게시 여부는 해당 작업의 빌드 결과로 확인합니다.

```sh
docker compose pull web
docker compose up -d --force-recreate web
docker compose logs --tail=100 web
```

소스 빌드: `docker build -t synonote-web:local web`. 실제 Synology Container Manager에서의 실행과 실제 NAS 쓰기는 별도 검증이 필요합니다. 모의 NAS/HTTP 계약·원문 fixture·브라우저 검증은 실제 NAS 검증과 구분합니다.

개발 실행 및 검사:

```sh
cd web/backend
uv sync --group dev
WEB_DATA_DIR=/tmp/synonote-web-dev uv run uvicorn synonote_web.main:create_app --factory --host 127.0.0.1 --port 8000
# 별도 터미널: web/frontend에서 npm ci && npm run dev
uv run pytest -q
# web/frontend에서 npm test && npm run build
```
