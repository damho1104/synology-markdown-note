# Synology Markdown Note

**Synology Note Station을 Markdown으로 활용하는 macOS 앱과 CLI**를 제공합니다.

Synology가 제작하거나 지원하는 공식 제품이 아닌 독립적인 오픈소스 프로젝트입니다. Synology 및 Note Station 명칭은 해당 권리자의 상표입니다.

macOS 앱에서는 기존 NAS의 책장·메모장·노트를 그대로 활용해 Markdown 편집, 노트 간 연결, 검색을 사용할 수 있습니다. 변경 내용은 NAS에 자동 동기화되며 오프라인 편집도 가능합니다. 별도 제공하는 **`synonote` CLI**로는 터미널에서 Markdown 파일을 업로드·다운로드하고 노트를 탐색할 수 있습니다.

## 주요 기능

### macOS 앱

- **Markdown 편집** — 소스 편집, 읽기 및 분할 미리보기. 기존 Note Station의 일반 노트는 서식 편집기로 열어 수정할 수 있습니다.
- **자동 동기화와 오프라인 작업** — 변경 내용을 먼저 Mac에 저장하고 NAS에 전송합니다. 연결이 끊기면 변경 사항을 보관했다가 재연결 후 전송합니다.
- **노트 정리** — 책장·메모장 관리, 태그, 즐겨찾기, 노트 이동, 휴지통과 복원.
- **검색** — 노트 본문 전문 검색, 제목·태그·날짜 등의 조건 검색과 스마트 메모장.
- **노트 연결** — `[[`로 다른 노트를 검색해 연결하고, 백링크와 전체·주변 노트 그래프로 관계를 살펴볼 수 있습니다.
- **풍부한 문서** — 이미지·첨부파일, Mermaid 다이어그램, KaTeX 수식, Markdown 가져오기·내보내기.

### CLI (`synonote`)

- **NAS 탐색** — 책장·메모장·노트 목록과 노트 정보 조회.
- **Markdown 업로드·다운로드** — 지정한 메모장에 `.md` 파일을 올리고 검증된 Markdown 노트를 파일로 저장.
- **안전한 덮어쓰기** — 기존 노트와 차이점 비교, 충돌·지원하지 않는 문서 변경 차단.
- **지식 인덱스 생성** — 일일 요약 노트를 프로젝트·주제·연관 지식별로 정리하고, 적용 전에 변경 사항 미리 확인.
- **스크립트 연동** — JSON 출력, 2단계 인증 및 로그인 정보 저장 지원.

## 설치 및 소스 빌드

소스와 개발 작업은 [GitHub 저장소](https://github.com/damho1104/synology-markdown-note)의 `develop` 브랜치를 기준으로 합니다. 직접 빌드하려면 먼저 저장소를 내려받으세요.

```shell
git clone --branch develop https://github.com/damho1104/synology-markdown-note.git
cd synology-markdown-note
```

[Releases](https://github.com/damho1104/synology-markdown-note/releases)에 설치 파일이 게시되어 있다면 해당 릴리스의 대상 환경·체크섬·서명 안내를 확인해 사용할 수 있습니다. 설치 파일이 없으면 아래 절차로 소스에서 빌드하세요.

### macOS 앱

**필요 환경:** macOS 14 이상, Apple Silicon(M1 이상) Mac, Synology NAS의 Note Station 및 NAS 접속 계정.

소스 빌드에는 macOS의 Swift 개발 도구(Xcode 또는 Command Line Tools)와 Python 3가 필요합니다. 저장소 루트에서 다음 명령을 실행합니다.

```shell
./script/build_and_run.sh --build
```

기본 빌드 결과는 `dist/Synology Markdown Note.app`입니다. 다음 명령으로 실행할 수 있습니다.

```shell
open "dist/Synology Markdown Note.app"
```

앱 번들 빌드 과정에는 키체인 접근용 Credential Helper와 로컬 개발 인증서를 이용한 서명이 포함됩니다. 서명 설정과 동작은 [개발 빌드 안내](docs/development-signing.ko.md)를 확인하세요.

DMG가 릴리스에 게시된 경우에는 파일을 열고 **Synology Markdown Note.app**을 **Applications(응용 프로그램)** 폴더로 드래그한 뒤 실행하면 됩니다.

> 로컬 개발 인증서로 서명한 빌드는 Apple Developer ID 서명·공증을 받은 배포판이 아닙니다. macOS가 실행을 차단하는 경우, 파일 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안** 안내를 따르세요. 자세한 내용은 [설치·배포 안내](docs/distribution.ko.md)를 참고하세요.

### CLI

CLI는 **PyInstaller `--onefile`로 빌드한 단일 실행 파일**로 사용할 수 있습니다. 완성된 실행 파일을 사용할 때는 Python이나 uv를 별도로 설치할 필요가 없습니다.

#### 소스에서 onefile 빌드

직접 빌드하려면 [uv](https://docs.astral.sh/uv/getting-started/installation/) 설치 후 저장소 루트에서 다음 명령을 실행하세요. Python 3.13을 설치하고, `build_onefile.py`가 PyInstaller에 `--onefile` 옵션을 전달해 빌드 버전을 포함합니다.

```shell
cd cli
uv python install 3.13
uv sync --locked
uv run --locked python build_onefile.py
```

빌드 결과는 `cli/dist/synonote`(macOS/Linux), `cli/dist/synonote.exe`(Windows)입니다. 사용할 OS·아키텍처에서 빌드해야 합니다. macOS/Linux에서는 위의 `cli/` 폴더에서 다음과 같이 설치하면 어디서든 `synonote`로 실행할 수 있습니다.

```shell
mkdir -p "$HOME/.local/bin"
install -m 755 ./dist/synonote "$HOME/.local/bin/synonote"
export PATH="$HOME/.local/bin:$PATH"
synonote version
```

`PATH` 설정은 사용하는 셸의 설정 파일에도 추가하세요.

#### 릴리스 실행 파일 설치

[Releases](https://github.com/damho1104/synology-markdown-note/releases)에 CLI 실행 파일이 게시되어 있다면 자신의 OS·버전·아키텍처에 맞는 파일을 선택하고 제공된 SHA-256 체크섬을 확인하세요. 기존 Ubuntu 전용 파일 외에 다음 릴리스부터 **Linux x86_64 / glibc 2.28 이상용 공용 실행 파일**을 추가합니다. Debian·Ubuntu·AlmaLinux·Rocky Linux·Fedora·openSUSE의 12개 컨테이너 환경을 검사합니다. 대상 버전과 설치 방법은 [Linux CLI 설치 안내](cli/README.md#여러-linux-배포판용-x86_64-실행-파일)를 참고하세요.

자세한 내용은 [CLI 설치·빌드 안내](cli/README.md#설치)를 참고하세요.

## 사용 방법

### macOS 앱

1. **NAS 연결:** 앱의 **설정 → Note Station**에서 NAS의 HTTPS 주소(예: `https://nas.example.com:5001`), 사용자 이름, 비밀번호를 입력하고 **로그인**을 누릅니다. 2단계 인증을 사용하면 인증 코드도 입력합니다.
2. **노트 작성:** 왼쪽에서 메모장을 선택하고 상단 **새 노트** 버튼 또는 `⌘N`을 누릅니다. 기존 노트를 선택해 바로 편집해도 됩니다.
3. **미리보기·검색:** Markdown 노트의 보기 모드를 전환하거나 `⇧⌘P`로 미리보기를 켜고 끕니다. `⇧⌘F`로 전체 노트를 검색할 수 있습니다.
4. **동기화:** 편집 내용은 자동 저장·전송됩니다. 전송 상태는 설정의 **동기화**에서 확인할 수 있고, 연결이 끊겼다면 재연결 후 전송됩니다.

다른 노트로 연결하려면 Markdown 편집 중 `[[`를 입력하세요. 기존 `.md` 파일은 **파일 → Markdown 가져오기…**로 추가할 수 있습니다.

**오프라인 사용 팁:** 아직 열어보지 않은 노트까지 내려받으려면 **설정 → Note Station → 오프라인 보관**에서 **전체 노트 본문·첨부를 이 Mac에 보관**을 켜세요. 새 메모장을 만들거나 NAS에서 처음 노트를 가져오려면 연결이 필요합니다.

### CLI

설치한 실행 파일을 직접 실행합니다.

```shell
synonote login --server https://nas.example.com:5001 --username alice --remember
synonote notebook list --stack '업무'
synonote upload ./report.md --stack '업무' --notebook '일지'
synonote download --id NOTE_ID --output ./downloaded-report.md
```

일일 요약 인덱스 생성은 `synonote index build`로 실행할 수 있으며, 기본적으로 변경 사항만 미리 보여 줍니다. 자세한 옵션과 사용 예시는 [CLI 사용법](cli/README.md)을 참고하세요.

## 알아두기

- Note Station이 설치된 NAS를 사용하며, 별도의 로컬 전용 메모장 모드는 제공하지 않습니다.
- NAS 주소는 **HTTPS URL**을 입력해야 합니다. QuickConnect ID만으로 접속하거나 인증서 검증을 우회하는 방식은 지원하지 않습니다.
- 암호화된 Note Station 노트의 본문 편집은 지원하지 않습니다.
- 로그인 비밀번호와 기기 인증 정보는 macOS **키체인**에 보관할 수 있습니다.
- CLI는 파일 단위 업로드·다운로드 도구로, macOS 앱과 같은 자동 동기화·자동 병합 기능은 제공하지 않습니다.

## 개발 및 테스트

저장소 루트에서 Swift 테스트를 실행합니다. Swift Testing을 포함하고 선택한 컴파일러와 호환되는 Xcode 또는 Command Line Tools가 필요합니다.

```shell
./script/test.sh
```

CLI 테스트는 저장소 루트에서 다음과 같이 실행합니다.

```shell
cd cli
uv python install 3.13
uv sync --locked
uv run --locked pytest -q tests
```

[GitHub Actions CI](.github/workflows/ci.yml)는 `develop` 브랜치에 대한 push, Pull Request, 수동 실행 시 저장소에 등록한 **셀프호스팅 러너**에서 다음을 검사합니다.

- **macOS:** Swift 테스트 실행.
- **Ubuntu 24.04 / Python 3.13:** CLI 잠금 파일 확인 및 테스트 실행.

[Release 워크플로](.github/workflows/release.yml)는 `v1.2.17` 또는 `1.2.17`처럼 **commit 접미사 없는 버전 태그**를 푸시하면 테스트·빌드·체크섬 검증 후 GitHub Releases에 자동 업로드합니다. 태그 버전은 `cli/pyproject.toml`의 버전과 일치해야 합니다. macOS arm64 앱(DMG·ZIP)과 CLI, Ubuntu 22.04·24.04 amd64 CLI, Linux x86_64 / glibc 2.28+ 공용 CLI를 게시하며, 릴리스 앱·CLI의 표시 버전에도 commit 접미사를 붙이지 않습니다.

Ubuntu CLI는 Linux X64 셀프호스팅 러너 안에서 각 대상 버전의 컨테이너로 빌드하며, macOS 앱·CLI는 macOS ARM64 셀프호스팅 러너에서 빌드합니다. 버전 검증과 릴리스 게시도 Linux 셀프호스팅 러너에서 실행합니다. macOS 앱은 릴리스 전용 자체 서명 인증서를 사용하며 Apple 공증은 하지 않습니다. 수동 실행은 산출물 검증만 수행하고 릴리스를 게시하지 않습니다. 설정과 태깅 절차는 [GitHub 릴리스 안내](docs/github-release.ko.md)를 참고하세요. CI 테스트 통과와 실제 기기의 설치·NAS 동작 검증은 별개입니다.

## 추가 문서

- [설치·배포 상세 안내](docs/distribution.ko.md)
- [GitHub 자동 릴리스·태그 안내](docs/github-release.ko.md)
- [개발 환경·빌드 안내](docs/development-signing.ko.md)
- [동기화·저장 동작](docs/nas-contract.ko.md)
- [진단 로그](docs/diagnostics.ko.md)
- [CLI 사용법](cli/README.md) — 설치·빌드 및 인증·탐색·업로드·다운로드·인덱스 명령 상세 안내

## 라이선스

이 프로젝트의 자체 소스와 문서는 [MIT 라이선스](LICENSE)로 제공합니다. 외부 라이브러리와 리소스에는 각각의 라이선스가 적용됩니다. 번들에 포함된 [Mermaid](Sources/SynologyNote/Resources/MERMAID-LICENSE.txt)와 [KaTeX](Sources/SynologyNote/Resources/KATEX-LICENSE.txt)의 고지를 함께 확인하세요.

## 기여 및 보안 제보

기여 방법은 [CONTRIBUTING.md](CONTRIBUTING.md)를 확인하세요. 취약점은 공개 Issue 대신 [SECURITY.md](SECURITY.md)의 비공개 제보 절차를 이용해 주세요.
