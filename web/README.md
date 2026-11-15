# Synology Markdown Note — Web (초기 구현)

React/TypeScript/Vite + Tailwind/shadcn/ui 기반 화면과 FastAPI/SQLite 서버의 **첫 개발 버전**입니다. 현재는 NAS 최초 설정·연결 확인·아이디/비밀번호/OTP 로그인·로그인 유지·로그아웃만 지원합니다. 노트 읽기·편집·오프라인 저장·동기화·NAS 쓰기는 아직 구현하지 않았습니다.

## Docker Compose 실행

프로젝트 루트의 `web/` 디렉터리에서 `docker-compose.yaml`을 실행합니다. 기본 설정은 개인 Registry에서 이미지를 내려받습니다. Registry 인증이 필요한 서버에서는 먼저 `docker login dr.dmomo.net`을 실행하세요.

```sh
cd web
cp -n .env.example .env  # 최초 실행 시 1회; 기존 .env는 유지
# .env의 WEB_IMAGE 및 HTTPS 프록시 설정을 배포 환경에 맞게 수정
docker compose pull
docker compose up -d
docker compose ps
docker compose exec web cat /data/setup-code
```

P1 최신 이미지는 `dr.dmomo.net/damho1104/synonote-web:0.1.1-p1`이며 `linux/amd64`, `linux/arm64`용으로 게시했습니다. HTTP NAS 지원, 연결 경고와 초기 설정 코드 확인 안내를 포함합니다. `.env`의 `WEB_IMAGE`로 태그를 변경할 수 있습니다. P1은 최초 설정·인증 UI 단계이며 노트 탐색·편집은 아직 제공하지 않습니다.

소스에서 이미지를 직접 빌드하려면 `web/` 디렉터리에서 `docker build -t synonote-web:local .`을 실행한 뒤 `WEB_IMAGE=synonote-web:local docker compose up -d`로 시작할 수 있습니다. Synology Container Manager에서는 `docker-compose.yaml` 내용을 프로젝트 YAML로 입력하고, NAS에 Registry 접근 권한을 설정하세요.

기본 공개 포트는 **호스트 `127.0.0.1:8787`**입니다. 브라우저의 `http://localhost:8787`에서 초기 설정을 진행할 때에는 `.env`에서 `WEB_COOKIE_SECURE=false`로 변경해야 합니다. 운영에서는 외부 HTTPS 역방향 프록시를 구성하고 `WEB_COOKIE_SECURE=true`, `WEB_PUBLIC_ORIGIN=https://실제-웹-도메인`을 설정하세요. `WEB_PUBLIC_ORIGIN`은 브라우저에서 접근하는 **origin**으로, 끝에 경로를 붙이지 않습니다. 프록시는 원래 Host를 전달해야 하고 앱은 임의 `X-Forwarded-*` 헤더를 신뢰하지 않습니다.

`.env` 없이도 Compose의 기본값으로 실행할 수 있지만, 배포 환경에 맞춘 설정은 `.env.example`을 `.env`로 복사해 수정합니다. `.env`에는 실제 비밀번호 등 비밀 정보를 커밋하지 마세요. `NAS_URL`을 비워 두면 최초 설정에서 NAS HTTP 또는 HTTPS 주소와 `/data/setup-code`를 입력합니다. 서버가 NAS API에 연결되는 것을 확인해야 주소가 SQLite에 저장됩니다. 코드는 최초 설정이 완료되면 삭제되며, 다시 조회할 수 없습니다. 이미 주소가 저장되어 있으면 다른 사용자는 주소를 덮어쓸 수 없습니다. 환경변수 `NAS_URL`을 지정하면 해당 주소가 최우선이고 웹에서는 읽기 전용입니다.

IP 또는 DNS 이름이 사설 네트워크를 가리키는 NAS는 **관리자만** `NAS_ALLOW_PRIVATE=true`로 설정할 수 있습니다. 로컬·링크 로컬·메타데이터 IP 및 리디렉션은 차단합니다. DNS 조회 결과를 확인한 뒤 검증된 IP로 직접 연결하며 HTTPS에서는 원래 호스트 이름으로 TLS 인증서를 검증합니다. 공개 CA를 사용하지 않는 HTTPS NAS는 검증 가능한 CA 파일을 컨테이너에 읽기 전용으로 마운트하고 `NAS_CA_FILE`을 해당 경로로 지정해야 합니다. 인증서 검증 비활성화는 지원하지 않습니다. `localhost`는 NAS가 아니라 웹 컨테이너 자체를 뜻합니다.

NAS 주소에 `http://192.168.1.10:5000`처럼 HTTP도 지정할 수 있으며 최초 설정과 로그인 화면에 경고가 표시됩니다. **HTTP에서는 웹 서버와 NAS 사이의 비밀번호·OTP·세션 정보 및 노트 데이터가 암호화되지 않습니다.** 내부망이라도 다른 장비에서 트래픽을 볼 수 있으므로 신뢰할 수 있는 네트워크에서만 사용하고 가능하면 HTTPS를 선택하세요. NAS가 사설 주소라면 HTTP에서도 `NAS_ALLOW_PRIVATE=true`가 필요합니다. 웹 클라이언트에 접속하는 브라우저의 HTTPS 설정(`WEB_PUBLIC_ORIGIN`, `WEB_COOKIE_SECURE`)과 NAS 연결 방식은 별개입니다.

로그인 유지 체크박스를 선택하면 암호화된 NAS 비밀번호와 선택한 신뢰 기기 ID가 서버의 `/data/web.sqlite3`에 저장되며, 복호화 키는 `/data/master.key`에 보관됩니다. **두 파일을 함께** 안전한 장소에 백업해야 로그인 유지 상태를 복원할 수 있습니다. 쿠키에는 불투명한 랜덤 토큰만 포함하고 서버에는 해시만 저장합니다. 로그아웃하면 현재 토큰과 저장된 자격 증명이 폐기됩니다. OTP는 저장되지 않습니다. 로그인 유지를 선택하지 않은 브라우저 세션은 컨테이너 재시작 후 재로그인이 필요합니다. 타인과 공유하는 기기에서는 로그인 유지와 오프라인 데이터 저장을 권장하지 않습니다.

### `/data` 저장소 권한 (Synology NAS)

컨테이너는 **UID/GID `10001:10001`**로 실행됩니다. 기본 `WEB_DATA_PATH=synonote-web-data`는 Docker가 관리하는 **named volume**이며, 새 볼륨은 이미지의 `/data` 소유권(`10001:10001`)을 상속합니다. 가장 간단한 배포 방법은 이 기본값을 유지하는 것입니다.

NAS의 특정 폴더를 사용하려면 `.env`에서 `WEB_DATA_PATH=/volume1/docker/synonote-web/data`처럼 **절대 경로**를 지정합니다. 첫 실행 전에 DSM의 SSH에서 **새 빈 폴더만** 다음과 같이 준비하세요. 상위 경로도 컨테이너 사용자가 통과할 수 있어야 합니다.

```sh
sudo mkdir -p /volume1/docker/synonote-web/data
sudo chown 10001:10001 /volume1/docker/synonote-web/data
sudo chmod 700 /volume1/docker/synonote-web/data
```

앱은 `/data` 디렉터리를 `0700`, SQLite DB와 비밀 키 파일을 `0600` 권한으로 사용합니다. 기존 파일이 있는 폴더의 소유권을 일괄 변경하거나 `777`로 열지 마세요. 기존 데이터를 옮기거나 복구할 때는 먼저 백업하고 `web.sqlite3`, `master.key`, `setup-code` 및 SQLite의 `-wal`/`-shm` 파일까지 소유권을 개별 확인해야 합니다. 권한 오류로 컨테이너가 시작되지 않으면 `docker compose logs web`로 확인하세요. `docker compose down -v`는 named volume의 데이터를 삭제하므로 실행하지 마세요.

```sh
docker compose logs --tail=100 web
docker compose ps
docker compose down  # 영속 named volume 보존; down -v 실행 금지 (데이터 삭제)
```

업데이트 전에 서비스를 중지한 뒤 `/data` 전체(실제 named volume 또는 바인드 마운트 디렉터리)를 백업합니다. SQLite의 `-wal` 파일이 있을 수 있으므로 **실행 중에는 파일 일부만 복사하지 마세요.** `master.key`가 유실되면 기존 로그인 유지 비밀번호는 복구되지 않습니다. 이미 저장된 `NAS_URL`을 바꾸는 관리 기능은 추후에 세션·전송 대기 작업 보호와 함께 제공합니다.

## 세션·NAS 주소 정책

일반 세션은 최대 24시간이며 12시간 미사용 시 만료됩니다. 로그인 유지 세션은 최대 30일이며 7일 미사용 시 만료됩니다. 로그인 유지 토큰은 7일마다 갱신되지만 최초 로그인 시점의 최대 만료일은 연장하지 않습니다. NAS 주소가 바뀌면 기존 로그인 유지 세션을 무효화하며 다른 NAS에 저장된 자격 증명을 전달하지 않습니다.

`NAS_ALLOW_PRIVATE=true`는 RFC1918 사설 IPv4 범위와 IPv6 ULA 범위만 추가로 허용합니다. 특수 목적 주소, 루프백, 링크 로컬 주소는 허용하지 않습니다.

## 개발 실행

```sh
cd web/backend
uv sync --group dev
WEB_DATA_DIR=/tmp/synonote-web-dev WEB_COOKIE_SECURE=false uv run uvicorn synonote_web.main:create_app --factory --host 127.0.0.1 --port 8000

# 별도 터미널
cd web/frontend
npm ci
npm run dev
```

백엔드 테스트: `cd web/backend && uv run pytest -q`. 프런트 빌드: `cd web/frontend && npm run build`.

## Synology Container Manager 상태

`docker-compose.yaml`은 개인 Registry 이미지를 사용하는 배포용 YAML이며, **Container Manager → 프로젝트 → 생성**에서 사용할 수 있습니다. 실제 Synology 장비에서의 구동은 아직 검증하지 않았습니다. DSM 전용 프로젝트에서는 포트 충돌·볼륨 쓰기 권한(컨테이너 UID 10001)·HTTPS 역방향 프록시·NAS 인증서 CA·NAS로의 네트워크 경로를 확인해야 합니다.
