# Synology Markdown Note Web 설치

[English](SELF-HOSTING.md) | **한국어**

Docker와 Docker Compose v2가 설치된 서버에서 실행합니다. Synology NAS에는 Note Station이 설치되어 있어야 합니다. 웹 컨테이너는 GitHub Actions로 GHCR에 게시한 `ghcr.io/damho1104/synology-md-note-web:latest` 이미지를 사용합니다. 로컬 소스 빌드는 필요하지 않습니다.

## 빠른 설치

```sh
# 1. 설치 폴더 생성
mkdir -p ~/synology-md-note-web && cd ~/synology-md-note-web

# 2. Compose와 설정 파일 다운로드
wget https://raw.githubusercontent.com/damho1104/synology-markdown-note/main/web/docker-compose.yaml
wget -O .env https://raw.githubusercontent.com/damho1104/synology-markdown-note/main/web/.env.example

# 3. 실행
# 내부망 NAS를 쓴다면 먼저 .env의 NAS_ALLOW_PRIVATE를 true로 바꾸세요.
# 다른 PC에서 직접 접속하려면 WEB_BIND_ADDRESS를 0.0.0.0으로 바꾸세요.
docker compose up -d

# 4. NAS 주소를 웹에서 설정할 때 사용할 초기 설정 코드 확인
# .env에 NAS_URL을 미리 지정했다면 이 단계는 생략합니다.
docker compose exec web cat /data/setup-code
```

같은 PC에서는 `http://localhost:8787`, 다른 PC에서는 `http://서버주소:8787`에 접속합니다. 최초 설정 화면에서 NAS 주소와 초기 설정 코드를 입력한 뒤 NAS 계정으로 로그인합니다. 암호화 키와 초기 설정 코드는 자동 생성되므로 사용자가 비밀값을 생성할 필요가 없습니다.

**기본값은 로컬 PC 접속만 허용합니다.** 다른 PC에서 접속할 때는 `.env`의 `WEB_BIND_ADDRESS=0.0.0.0`을 지정하거나 HTTPS 역방향 프록시를 연결하세요. NAS 계정 비밀번호와 OTP는 `.env`에 넣지 않고 웹 로그인 화면에 입력합니다.

## 자주 쓰는 설정 예시

아래 IP·도메인·포트는 예시입니다. NAS와 웹 서버의 실제 주소 및 설정에 맞게 바꾸세요.

내부망 NAS가 `192.168.1.20`이고 다른 PC에서도 웹에 접속할 경우 `.env`를 다음처럼 설정합니다.

```dotenv
NAS_URL=http://192.168.1.20:5000
NAS_ALLOW_PRIVATE=true
WEB_BIND_ADDRESS=0.0.0.0
WEB_PORT=8787
```

공인 인증서를 사용하는 HTTPS NAS 예시:

```dotenv
NAS_URL=https://nas.example.com:5001
NAS_ALLOW_PRIVATE=false
```

NAS 주소가 사설 IP로 연결된다면 HTTPS여도 `NAS_ALLOW_PRIVATE=true`가 필요합니다. HTTP NAS 연결은 계정 정보와 노트 전송을 암호화하지 않습니다. 웹에 접속하는 HTTP/HTTPS와 웹 서버가 NAS에 접속하는 HTTP/HTTPS는 별개입니다.

환경변수를 수정한 뒤에는 다시 실행합니다.

```sh
docker compose up -d
```

## 필수·선택 설정

**환경변수는 모두 기본값이 있어 생략 가능합니다.** NAS 주소는 `.env`의 `NAS_URL` 또는 최초 웹 설정 중 한 곳에서 입력해야 합니다. 상세 주석은 [docker-compose.yaml](docker-compose.yaml)과 [.env.example](.env.example)에 있습니다.

| 설정 | 구분 | 기본값 / 변경할 때 |
| --- | --- | --- |
| `WEB_IMAGE` | 선택 | `ghcr.io/damho1104/synology-md-note-web:latest`. 특정 게시 버전으로 고정할 때 변경 |
| `NAS_URL` | 선택 | 미지정 시 웹에서 NAS 주소 설정 |
| `NAS_ALLOW_PRIVATE` | 조건부 | 기본 `false`. 내부망 주소 또는 HTTP NAS 사용 시 `true` 필요 |
| `WEB_BIND_ADDRESS` | 선택 | `127.0.0.1`. 다른 PC에서 직접 접속하려면 `0.0.0.0` 등으로 변경 |
| `WEB_PORT` | 선택 | `8787` |
| `WEB_DATA_PATH` | 선택 | `synonote-web-data` named volume. 호스트 폴더를 쓰려면 절대 경로 지정 |
| `NAS_CA_FILE` | 선택 | 일반 설치에서는 생략. 사설 CA가 필요한 HTTPS NAS에서만 아래 설정 사용 |
| `WEB_PUBLIC_ORIGIN` | 선택·고급 | 기본 빈 값. 프록시가 브라우저 Host를 보존하지 못할 때 정확한 origin 지정 |
| `WEB_COOKIE_SECURE` | 선택·고급 | `auto`. 일반 설치에서는 변경 불필요 |

## 선택: Synology 폴더에 데이터 보관

기본 named volume을 사용하면 이 과정은 필요 없습니다. NAS 폴더를 직접 연결하려면 **새 전용 폴더**를 준비합니다.

아래 `/volume1/docker/synology-md-note-web/data`는 예시 경로입니다. 사용하는 볼륨과 전용 폴더에 맞게 모든 명령 및 `WEB_DATA_PATH`를 함께 바꾸세요.

```sh
sudo mkdir -p /volume1/docker/synology-md-note-web/data
sudo chown 10001:10001 /volume1/docker/synology-md-note-web/data
sudo chmod 700 /volume1/docker/synology-md-note-web/data
```

`.env`:

```dotenv
WEB_DATA_PATH=/volume1/docker/synology-md-note-web/data
```

컨테이너는 UID/GID `10001:10001`로 실행합니다. 기존 다른 서비스 폴더의 권한을 바꾸지 마세요. Container Manager에서는 다운로드한 파일이 있는 폴더를 프로젝트 경로로 사용합니다.

## 선택: HTTPS 역방향 프록시

프록시 대상을 `http://웹서버주소:8787`로 지정하고 브라우저가 사용한 Host와 포트를 보존합니다. 동일 호스트의 프록시라면 `http://127.0.0.1:8787`을 사용할 수 있습니다. 별도 컨테이너의 `127.0.0.1`은 그 컨테이너 자신을 뜻합니다.

Nginx HTTPS 서버 블록 안의 예시:

```nginx
client_max_body_size 20m;
location / {
    client_max_body_size 50m;
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_request_buffering off;
    proxy_set_header Host $http_host;
}
```

도메인과 TLS 인증서는 프록시에서 준비합니다. 일반 구성은 쿠키·origin을 자동 처리하므로 추가 설정이 필요 없습니다. Host를 보존할 수 없는 경우에만 `.env`에 `WEB_PUBLIC_ORIGIN=https://notes.example.com`을 지정하세요. 전용 도메인의 `/`에서 제공합니다.

## 선택: 사설 CA 인증서

**공인 인증서 또는 HTTP NAS에는 필요 없습니다.** 사설 CA를 신뢰해야 하는 HTTPS NAS에만 설정합니다. 별도 Compose 파일은 사용하지 않습니다.

1. 신뢰할 CA PEM을 설치 폴더의 `certs/nas-ca.pem`에 저장합니다. 개인키는 넣지 않습니다.
2. `docker-compose.yaml`의 `volumes` 아래 선택 CA 마운트 주석을 해제합니다. 호스트 경로가 다르면 `source`도 수정합니다.
3. `.env`에 다음 한 줄을 추가합니다.

```dotenv
NAS_CA_FILE=/etc/synonote/nas-ca.pem
```

CA 파일은 읽기 전용으로 연결됩니다. 파일이 없으면 디렉터리를 자동 생성하지 않고 실패하며 UID 10001이 파일을 읽을 수 있어야 합니다. NAS 주소와 인증서 호스트명도 일치해야 합니다. 인증서 검증을 끄는 옵션은 없습니다.

## 업데이트

편집 중인 노트가 저장 완료 상태인지 확인하고 `/data`를 백업한 뒤 실행합니다. 기본 `latest` 또는 `.env`에서 지정한 이미지 태그를 받습니다.

```sh
cd ~/synology-md-note-web
docker compose pull web
docker compose up -d
docker compose ps
```

새 Compose나 환경변수 변경이 있으면 배포 안내에 따라 파일을 비교하여 반영하세요. 기존 `.env`를 새 예제로 무조건 덮어쓰지 말고 NAS 주소·포트·데이터 경로·선택 CA 설정을 유지합니다. 브라우저도 저장 완료 확인 후 새로고침합니다.

## 백업과 문제 확인

웹을 중지한 뒤 `/data` **전체**를 백업합니다. DB와 `master.key`, SQLite의 `-wal`/`-shm` 파일을 함께 보관해야 합니다.

```sh
docker compose stop web
mkdir -p ./backups
chmod 700 ./backups
backup_dir="./backups/data-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$backup_dir"
docker compose cp web:/data/. "$backup_dir/"
docker compose start web
```

복원은 서비스 중지 상태에서 새 전용 폴더에 백업 전체를 복사하고 UID/GID `10001:10001`, 디렉터리 0700, DB/키 파일 0600 권한을 맞춘 뒤 `WEB_DATA_PATH`로 연결합니다. 실행 중인 DB에 덮어쓰지 마세요. 노트 원본은 NAS에 있으므로 Note Station 백업도 별도로 필요합니다. **`docker compose down -v`는 데이터를 삭제하므로 업데이트에 사용하지 않습니다.**

```sh
docker compose logs --tail=100 web
docker compose config --quiet
curl --fail http://127.0.0.1:8787/api/ready
```

주소·포트는 설치값에 맞춥니다. `/api/ready`는 웹 서버 준비 상태이며 NAS 로그인·쓰기 성공까지 뜻하지는 않습니다. 내부망 연결이 거부되면 `NAS_ALLOW_PRIVATE`, 로그인 후 되돌아오면 브라우저 쿠키와 프록시 Host 설정, 권한 오류는 `/data` 소유권을 확인하세요.

기능과 지원 범위는 [웹 README](README_KO.md)를 참고하세요.

> 배포 관리자: 위 설치 명령은 파일이 GitHub `main`에 공개되고 GHCR 이미지가 Actions에서 게시된 뒤 사용할 수 있습니다. GHCR 패키지도 공개 읽기가 가능하도록 설정해야 합니다. 이 문서 작성만으로 게시나 공개 설정이 완료되지는 않습니다.
