# synonote CLI

[English](README.md) | **한국어**

LLM과 사용자가 작성한 UTF-8 Markdown을 Synology Note Station의 지정된 책장/메모장에 **업로드**하고, 검증된 Markdown을 **다운로드**하는 도구입니다. 동기화·자동 병합 기능은 없습니다. macOS 앱이 사용하는 `SourceEnvelope` 문서 형식을 공유합니다.

Synology가 제작하거나 지원하는 공식 제품이 아닌 독립적인 오픈소스 프로젝트이며, 자체 소스는 [MIT 라이선스](LICENSE)로 제공합니다. 외부 의존성에는 각각의 라이선스가 적용됩니다.

## 설치

**PyInstaller `--onefile`로 빌드한 단일 실행 파일**을 사용합니다. 실행 환경에는 Python이나 uv가 필요하지 않습니다.

### Ubuntu 22.04·24.04: 릴리스 실행 파일 설치 (권장)

**Ubuntu 22.04·24.04 amd64에서는 직접 빌드하지 않고 릴리스 파일을 받아 설치하는 방법을 권장합니다.**

[GitHub Releases](https://github.com/damho1104/synology-markdown-note/releases)에 파일이 게시된 경우 Ubuntu 22.04/24.04 amd64 또는 macOS arm64에 맞는 `synonote-cli-<VERSION_TAG>-<플랫폼>` 파일과 해당 `SHA256SUMS-<플랫폼>` 파일을 받습니다. 다운로드 폴더에서 체크섬을 확인한 뒤 실행 파일을 `synonote`라는 이름으로 설치합니다. 아직 릴리스가 없다면 아래의 소스 빌드 안내를 이용하세요.

| 환경 | 실행 파일 | 체크섬 |
| --- | --- | --- |
| Ubuntu 22.04 amd64 | `synonote-cli-<VERSION_TAG>-ubuntu-22.04-amd64` | `SHA256SUMS-ubuntu-22.04-amd64` |
| Ubuntu 24.04 amd64 | `synonote-cli-<VERSION_TAG>-ubuntu-24.04-amd64` | `SHA256SUMS-ubuntu-24.04-amd64` |

Ubuntu 24.04에서는 아래 두 파일명의 `22.04`를 `24.04`로 바꿉니다.

```shell
# Ubuntu 22.04 amd64 예시: <VERSION_TAG>를 다운로드한 버전으로 바꾸세요.
sha256sum --check SHA256SUMS-ubuntu-22.04-amd64
mkdir -p "$HOME/.local/bin"
install -m 755 './synonote-cli-<VERSION_TAG>-ubuntu-22.04-amd64' "$HOME/.local/bin/synonote"
export PATH="$HOME/.local/bin:$PATH"
synonote version
```

`PATH` 설정은 사용하는 셸의 설정 파일에도 추가하세요.

macOS arm64에서는 체크섬을 `shasum -a 256 -c SHA256SUMS-macos-arm64`로 확인하고 macOS용 파일을 같은 방식으로 설치합니다. 실행 파일 이름을 바꾸기 전에 체크섬을 확인하세요.

### 여러 Linux 배포판용 x86_64 실행 파일

`v1.2.17` 재빌드부터 `synonote-cli-<VERSION_TAG>-linux-glibc2.28-amd64`와 `SHA256SUMS-linux-glibc2.28-amd64`를 추가로 제공합니다. Python 설치가 필요 없는 공용 실행 파일이며, **x86_64 및 glibc 2.28 이상** 환경을 대상으로 합니다. 기존 Ubuntu 전용 실행 파일도 유지합니다.

릴리스 워크플로는 다음 **12개 컨테이너 환경에서 동일한 공용 실행 파일을 검증**하고, 하나라도 실패하면 게시를 중단합니다.

| 계열 | 검사 환경 |
| --- | --- |
| Debian | 11, 12, 13 |
| Ubuntu | 20.04, 22.04, 24.04 |
| AlmaLinux | 8, 9 |
| Rocky Linux | 8, 9 |
| Fedora | 43 |
| openSUSE Leap | 16.0 |

버전·도움말, 한글 설정 경로, 파일 기반 인증 정보 삭제, SSL/HTTP 클라이언트 초기화를 확인합니다. 실제 NAS 로그인·업로드·다운로드 검증은 별도입니다. Linux Mint 등 같은 glibc 기반 파생 배포판은 별도로 검증하지 않습니다. Alpine(musl), Linux ARM64, 32비트는 지원 대상에 포함하지 않습니다.

```sh
uname -m                 # x86_64인지 확인
getconf GNU_LIBC_VERSION # glibc 2.28 이상인지 확인
sha256sum --check SHA256SUMS-linux-glibc2.28-amd64
mkdir -p "$HOME/.local/bin"
install -m 755 './synonote-cli-<VERSION_TAG>-linux-glibc2.28-amd64' "$HOME/.local/bin/synonote"
```

### 소스에서 onefile 빌드 (선택)

빌드할 때는 [uv](https://docs.astral.sh/uv/getting-started/installation/)로 Python 3.13과 잠금 파일의 의존성을 준비합니다. 사용할 OS·아키텍처에서 저장소의 `cli/` 폴더로 이동해 실행하세요.

```shell
uv python install 3.13
uv sync --locked
uv run --locked python build_onefile.py
```

`build_onefile.py`는 PyInstaller에 **`--onefile`** 옵션을 전달하고 Git 커밋이 포함된 버전 정보를 묶습니다. 결과는 `dist/synonote`(macOS/Linux) 또는 `dist/synonote.exe`(Windows)이며, 다른 OS용 교차 빌드는 지원하지 않습니다.

macOS/Linux에서는 `cli/` 폴더에서 다음과 같이 설치합니다.

```shell
mkdir -p "$HOME/.local/bin"
install -m 755 ./dist/synonote "$HOME/.local/bin/synonote"
export PATH="$HOME/.local/bin:$PATH"
synonote --help
synonote version
```

`PATH` 설정은 사용하는 셸의 설정 파일에도 추가하세요. 설치하지 않고 `./dist/synonote`로 직접 실행해도 됩니다. Windows에서는 `dist/synonote.exe`를 PATH에 포함된 폴더에 두거나 PowerShell에서 `./dist/synonote.exe --help`로 실행하세요. 아래 예시는 실행 파일이 PATH에 있는 것을 기준으로 합니다.

정식 릴리스 앱·CLI의 표시 버전은 `1.2.17`처럼 커밋 해시 없는 버전입니다. 일반 소스 개발 빌드는 `x.y.z-<GIT_COMMIT_SHORT_HASH>` 형식입니다(예: `1.2.17-7cb95a5`). CLI의 `version` 명령은 NAS 로그인 없이 실행되며, `--json`은 `action: version`, `status: ok`, `version` 필드를 반환합니다. 설치 패키지의 버전 메타데이터에는 패키징 규약에 따라 `1.2.2`를 사용합니다.

## 로그인과 자동 로그인

아래 명령의 NAS 주소, 사용자 이름, 책장·메모장 이름, 파일 경로와 ID는 예시입니다. 자신의 환경에 맞게 바꾸세요. OTP 예시도 로그인 시 발급된 현재 코드로 바꿉니다. 제품의 기본값과 필수 이름은 별도로 설명합니다.

```shell
synonote login --server https://nas.example:5001 --username alice --remember
synonote login --server https://nas.example:5001 --username alice --otp 123456 --remember
synonote auth status --json
synonote logout
```

같은 NAS에 연결하는 URL만 바꾸려면 다음 명령을 사용합니다. 저장된 비밀번호와 신뢰 기기 정보를 이용해 새 URL에서 인증을 먼저 확인하고, 성공한 경우에만 로컬 설정을 갱신합니다. 새 주소에서 인증에 실패하면 기존 설정이 유지됩니다.

```shell
synonote auth set-server --server https://new-nas.example:5001
synonote auth status --json
```

이 명령은 로그인 정보를 저장한 **해당 기기**에서 실행해야 합니다. 다른 기기의 CLI 설정은 변경되지 않습니다. 새 주소는 유효한 HTTPS 주소여야 하며, OTP를 새로 요구하면 `login --server ... --username ... --remember`로 다시 로그인해야 합니다.

대화형 입력에서 비밀번호를 안전하게 받으며, OTP 요청 시 추가 입력을 받습니다. 자동화의 경우 비밀번호를 별도 안전한 프로세스에서 **표준입력**으로 전달하고 `--password-stdin --non-interactive --json` 옵션을 사용합니다. 비밀번호를 명령행 인자에 넣지 마세요. `--remember`를 지정해야 다음 CLI 실행에서 자동 로그인할 수 있습니다.

서버 URL/사용자 이름은 로컬 `profile.json`에 저장합니다. 비밀번호와 DSM 신뢰 기기 ID는 **macOS Keychain**, **Windows Credential Manager**에 저장하며, **Linux(Ubuntu/headless 포함)**에서는 `~/.config/synonote/credentials.json`에 **평문 JSON 파일**로 저장합니다. Linux에서 `XDG_CONFIG_HOME`을 설정했다면 `$XDG_CONFIG_HOME/synonote/credentials.json`을 사용합니다. Linux의 `synonote` 디렉터리는 `0700`, `credentials.json`과 `profile.json`은 `0600` 권한으로 생성하며 자격 증명 파일은 원자적으로 교체합니다. 따라서 Linux 계정 또는 파일 백업에 접근 가능한 사람은 저장된 비밀번호를 읽을 수 있습니다. `logout`은 저장된 자격 증명을 삭제합니다. 기존 Linux keyring 로그인은 자동으로 파일로 이전하지 않으므로 다시 `login --remember`를 실행해야 합니다. OTP·세션 ID는 저장하지 않습니다. HTTPS 인증서 검증 무시 옵션은 없습니다.

## 책장·메모장 탐색

```shell
synonote stack list --json
synonote notebook list --stack '업무' --json
synonote note list --stack '업무' --notebook '일지' --json
synonote note info --id NOTE_ID --json
```

책장은 Note Station의 `stack` 속성입니다. 메모장 이름이 여러 개면 `--notebook-id`를 사용합니다.

## 일일 요약 지식 인덱스

`--stack`으로 지정한 책장에서 `YYYY-MM` 형식의 월별 메모장만 읽어 인덱스를 만듭니다. 책장 이름은 자유롭게 선택할 수 있습니다. 원본 노트는 수정하지 않습니다. 현재는 월별 메모장에 모은 일일 요약 노트용 기능이며, 다른 이름의 메모장은 읽지 않습니다. 프로젝트 분류는 `by_project` 메타데이터, 주제 분류는 본문의 기술 용어와 정규식을 사용합니다. LLM 호출이나 공급자별 분류는 수행하지 않습니다.

`--index-notebook`은 허브 노트를 저장할 메모장 이름입니다. 이 메모장은 지정한 책장에 미리 만들어야 하며, 옵션을 생략하면 기본값 `llm-index`를 사용합니다. 아래 예시는 `업무` 책장과 `지식 인덱스` 메모장을 사용합니다. 두 이름을 자신의 환경에 맞게 바꾸세요.

- `--index-notebook`으로 지정한 메모장: 아래의 네 허브 노트만 보관
- `by-project`: 프로젝트 상세 인덱스 보관
- `by-topic`: 주제 상세 인덱스 보관

- `00-전체 인덱스`: 월별·날짜별 전체 원본 노트 목록
- `01-프로젝트 인덱스`: 원본의 `by_project` 메타데이터를 이용해 프로젝트별 기록과 다중 프로젝트 연결 생성. 기본적으로 3일 이상 기록된 프로젝트는 상세 페이지 생성
- `02-주제 인덱스`: 본문에 등장한 용어와 정규식에 기반한 기술 주제. 주제별 상세 페이지에는 분류 근거 발췌 표시
- `03-연관 지식`: 공통 프로젝트·주제·희소 키워드로 점수화한 날짜 간 연관 후보 최대 70쌍. LLM 임베딩 기반 의미 유사도가 아니므로 실제 관계는 원본에서 확인

```shell
# 먼저 전체 결과를 확인합니다. --dry-run이 기본값입니다.
synonote index build --stack '업무' --index-notebook '지식 인덱스' --dry-run --json
# 검토 후 누락된 상세 노트북 생성 및 기존 관리 노트 이동·게시
synonote index build --stack '업무' --index-notebook '지식 인덱스' --apply --json
# 이후에는 같은 명령을 재실행하면 변경된 관리 대상만 갱신합니다.
```

`--project-min-days 3`으로 프로젝트 상세 노트 생성 기준을 조정할 수 있습니다(최소 2). `--index-notebook`으로 지정한 허브 메모장을 먼저 준비하세요. 상세 노트북 `by-project`, `by-topic`이 없으면 `--apply`에서 생성하여 같은 책장에 넣습니다. 기존 허브 메모장에 게시된 프로젝트·주제 상세 노트는 **노트 ID, HTML, 첨부파일을 검증하며 원격에서 직접 이동**합니다. `--dry-run`은 `placement`, `move`, `move_update`, `notebooks_to_create`를 보여 주며 아무것도 수정하지 않습니다.

전체 NAS의 제목 충돌, 원본 링크 해석, 기존 관리 마커(`<!-- synonote-index:v1 -->`)를 확인합니다. 사용자가 작성한 노트는 같은 제목이어도 덮어쓰지 않습니다. 기존 인덱스 내용이 같으면 불필요한 쓰기를 생략합니다. 각 인덱스 링크는 `노트 제목.md` 형식이며 macOS 앱의 내부 링크 지원을 전제로 합니다.

여러 노트북/노트의 변경은 NAS의 단일 트랜잭션이 아닙니다. CLI는 이동 및 노트북 생성/배치 의도를 `operations` 디렉터리에 영속 기록합니다. 이동 결과가 유실되었더라도 같은 ID·HTML·첨부파일이 대상 노트북에서 확인되면 다음 실행 때 저널을 정리합니다. 결과를 증명할 수 없으면 `WRITE_UNCERTAIN`과 `operation_id`를 반환하고 해당 변경을 **자동으로 다시 보내지 않습니다**. 이 경우 NAS와 저널을 확인해야 합니다. 인덱스 본문 업로드의 `operation_id`는 아래 `operation status` 명령으로 별도 조회할 수 있습니다. 이미 생성된 인덱스 페이지는 자동 삭제되지 않습니다.

## 업로드·비교·덮어쓰기

```shell
synonote upload ./report.md --stack '업무' --notebook '일지' --json
synonote upload ./report.md --notebook-id NOTEBOOK_ID --diff --json
synonote upload ./report.md --notebook-id NOTEBOOK_ID --overwrite --json --non-interactive
synonote upload ./report.md --notebook-id NOTEBOOK_ID --note-id NOTE_ID --overwrite --json
```

기본 제목은 `.md` 파일명(확장자 제외)이며 `--title`로 지정할 수 있습니다. 동일 제목 노트가 있으면 기본적으로 NAS와 로컬의 unified diff를 반환한 뒤 **쓰기 없이 중단**합니다. `--diff`는 비교만 수행하며 노트가 없으면 `would_create`입니다. `--overwrite`는 NAS 원문이 검증된 Markdown이고 제목/메모장/버전이 일치하는 경우만 허용됩니다. HTML 전용 노트, 원문 미확인 노트, 잠긴 노트, 제목 중복 후보가 여럿인 경우는 거부합니다.

## 다운로드

```shell
synonote download --id NOTE_ID --output ./report.md --json
synonote download --id NOTE_ID --output ./report.md --force-local --json
```

검증된 Markdown의 UTF-8 바이트를 보존합니다(CRLF, 마지막 개행 없음 포함). 기존 파일은 `--force-local`이 있어야 교체합니다. 원문에 보존 블록이 있으면 `.md.preserved.json` 파일도 내보내며, 더 이상 보존 블록이 없는 문서로 강제 다운로드하면 오래된 sidecar도 함께 제거합니다. 다중 파일 저장 실패 시 기존 파일을 복원합니다.

## 쓰기 중단 후 상태 확인

네트워크 단절 등으로 `WRITE_UNCERTAIN`과 `operation_id`가 반환되면 **업로드를 즉시 재실행하지 말고** 읽기 전용으로 확인합니다.

```shell
synonote operation status --id OPERATION_UUID --json
synonote operation recover --id OPERATION_UUID --json
```

`confirmed`는 원문·본문·제목·첨부 정리가 확인되어 로컬 저널이 종료된 상태입니다. `uncertain`이면 단계(`phase`)와 후보 노트 ID를 보고 수동 확인해야 합니다. `recover`도 자동 재전송이나 삭제를 하지 않습니다. 로컬 `synonote/operations/` 저널에는 Markdown 원문이 포함될 수 있으므로 공유/백업 시 주의하세요.

## JSON과 종료 코드

`--json` 출력은 한 줄 JSON입니다. `schema_version: 1`, `action`, `status`를 포함하며 오류 시 `error.code`가 반환됩니다. diff 출력에는 NAS 문서의 본문이 포함될 수 있습니다.

| 코드 | 의미 |
| ---: | --- |
| 0 | 성공·동일·차이 없는 비교 |
| 2 | 인자/로컬 파일/출력 대상 오류 또는 없음 |
| 3 | 제목 충돌·후보 모호·비교 결과 다름 |
| 4 | 검증 불가 또는 Markdown이 아닌 문서 |
| 5 | 인증·OTP·보안 저장소 오류 |
| 6 | 원격 변경/버전 충돌 |
| 7 | NAS 쓰기 결과 불확실 |
| 8 | 네트워크/NAS API 오류 |
| 9 | 현재 미지원 Markdown 기능 |

## 지원 범위와 제한

**현재 지원:** UTF-8 `.md` 단일 파일, 일반 CommonMark/GFM 서식(테스트한 부분집합), Swift `SourceEnvelope` v1/v2/v3 읽기, 검증된 원문 다운로드, 동일 제목 diff, 버전 확인, HTML 전용 문서 덮어쓰기 거부, 사용자 첨부 보존, NAS 쓰기 확인 저널. `:::synology-block ... :::` 보존 블록과 해당 `.md.preserved.json` sidecar를 함께 업로드하고 다운로드할 수 있습니다. 덮어쓰기 시 원격 블록과 로컬 블록이 다르면 변경을 차단합니다.

**안전상 아직 미지원:** 상대 경로 이미지/첨부 리소스 업로드, 참조 첨부/수식이 포함된 노트 내보내기·덮어쓰기, 첨부 참조가 있는 보존 블록 업로드, TeX 수식 PNG 렌더링. 지원하지 않는 입력은 `UNSUPPORTED_MARKDOWN_FEATURE`로 거부합니다. 보존 블록 토큰과 sidecar가 불일치하면 `INVALID_SOURCE`로 거부합니다.

Swift 코드가 생성한 골든 fixture 및 모의 NAS 테스트는 완료했습니다. 실제 NAS에서 앱 ↔ CLI 양방향 왕복, 2FA, Keychain, 공식 Note Station, Windows/Linux 실환경 동작 검증은 추가로 필요합니다. 전체 앱 기능 동등성으로 발표하지 않습니다.

## GitHub 배포

공식 소스는 [GitHub 저장소](https://github.com/damho1104/synology-markdown-note)에서 관리합니다. `develop`·`main` 브랜치의 변경 사항과 Pull Request에 대해 Python CLI 및 Swift 테스트를 실행합니다. `v1.2.17` 또는 `1.2.17` 형식의 버전 태그를 `main`에 반영된 커밋에 붙여 푸시하면 macOS arm64·Ubuntu 22.04/24.04 amd64 CLI와 Linux x86_64/glibc 2.28+ 공용 CLI 및 체크섬을 [GitHub Releases](https://github.com/damho1104/synology-markdown-note/releases)에 자동 게시합니다. 태그는 프로젝트 버전과 일치해야 하며 short commit을 붙이지 않습니다. 릴리스 실행 파일의 표시 버전도 `1.2.17`처럼 해시 없이 표시됩니다. 설정과 사용법은 [GitHub 릴리스 안내](../docs/github-release.ko.md)를 참고하세요.

CLI는 macOS와 Linux에서 PyInstaller를 이용해 단일 실행 파일로 빌드할 수 있습니다. 공식 릴리스에 사용할 실행 파일 및 체크섬은 해당 OS에서 별도로 검증해야 합니다.

## 개발·테스트

빌드와 테스트 도구(pytest, PyInstaller)는 기본 `dev` 의존성 그룹에 포함됩니다. 의존성 변경은 `uv add 패키지명`, 개발용 의존성 변경은 `uv add --dev 패키지명`으로 수행하며 `pyproject.toml`과 `uv.lock`을 함께 커밋합니다. `--locked`는 잠금 파일 불일치를 검출합니다.

`cli/`에서:

```shell
uv sync --locked
uv run --locked pytest -q tests
```

Swift 계약 fixture/앱 테스트는 저장소 루트에서 실행합니다.

```shell
swift run CLIContractFixtures
swift test
```

Swift 전체 테스트는 Xcode 설치와 해당 Xcode 라이선스 동의가 필요합니다.
