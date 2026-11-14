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

## 설치 방법

### macOS 앱

**필요 환경:** macOS 14 이상, Apple Silicon(M1 이상) Mac, Synology NAS의 Note Station 및 NAS 접속 계정.

1. [Releases](https://github.com/damho1104/synology-markdown-note/releases)에서 배포 파일이 게시된 경우 **macOS arm64 DMG** 파일을 다운로드합니다. 릴리스가 아직 없다면 아래의 소스 빌드 안내를 참고하세요.
2. DMG 파일을 열고 **Synology Markdown Note.app**을 **Applications(응용 프로그램)** 폴더로 드래그합니다.
3. 응용 프로그램 폴더에서 앱을 실행합니다.

> 현재 배포 앱은 개발용 인증서로 서명되어 있으며 Apple 공증을 받지 않았습니다. macOS가 실행을 차단하는 경우, 파일 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안**에서 열기를 허용할 수 있습니다. 자세한 내용은 [설치·배포 안내](docs/distribution.ko.md)를 참고하세요.

### CLI

CLI는 **PyInstaller `--onefile`로 빌드한 단일 실행 파일**로 사용합니다. 실행할 때 Python이나 uv를 별도로 설치할 필요가 없습니다.

#### Ubuntu 22.04·24.04: 릴리스 파일 설치 (권장)

[Releases](https://github.com/damho1104/synology-markdown-note/releases)에 실행 파일이 게시된 경우 **사용 중인 Ubuntu 버전에 맞는 amd64 실행 파일과 체크섬 파일**을 다운로드하세요. 릴리스가 아직 없다면 아래의 소스 빌드 안내를 참고하세요.

| 환경 | 실행 파일 | 체크섬 |
| --- | --- | --- |
| Ubuntu 22.04 amd64 | `synonote-cli-<VERSION_TAG>-ubuntu-22.04-amd64` | `SHA256SUMS-ubuntu-22.04-amd64` |
| Ubuntu 24.04 amd64 | `synonote-cli-<VERSION_TAG>-ubuntu-24.04-amd64` | `SHA256SUMS-ubuntu-24.04-amd64` |

다운로드 폴더에서 다음과 같이 설치합니다. 아래는 Ubuntu 22.04 예시이며, `<VERSION_TAG>`는 다운로드한 버전으로 바꾸세요. Ubuntu 24.04에서는 두 파일명의 `22.04`를 `24.04`로 바꿉니다.

```shell
sha256sum --check SHA256SUMS-ubuntu-22.04-amd64
mkdir -p "$HOME/.local/bin"
install -m 755 './synonote-cli-<VERSION_TAG>-ubuntu-22.04-amd64' "$HOME/.local/bin/synonote"
export PATH="$HOME/.local/bin:$PATH"
synonote version
```

`PATH` 설정은 사용하는 셸의 설정 파일에도 추가하세요. macOS arm64용 CLI 실행 파일도 Releases에서 받을 수 있습니다.

#### 소스에서 onefile 빌드 (선택)

직접 빌드하려면 [uv](https://docs.astral.sh/uv/getting-started/installation/) 설치 후 저장소 루트에서 다음 명령을 실행하세요. `build_onefile.py`가 PyInstaller에 `--onefile` 옵션을 전달하고 빌드 버전을 포함합니다.

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
```

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

## 추가 문서

- [설치·배포 상세 안내](docs/distribution.ko.md)
- [개발 환경·빌드 안내](docs/development-signing.ko.md)
- [동기화·저장 동작](docs/nas-contract.ko.md)
- [진단 로그](docs/diagnostics.ko.md)
- [CLI 사용법](cli/README.md) — 설치·빌드 및 인증·탐색·업로드·다운로드·인덱스 명령 상세 안내

소스에서 앱을 빌드하려면 macOS의 Swift 개발 도구(Xcode 또는 Command Line Tools)가 필요합니다. 저장소 루트에서 `./script/build_and_run.sh --build`를 실행하세요.

## 라이선스

이 프로젝트의 자체 소스와 문서는 [MIT 라이선스](LICENSE)로 제공합니다. 외부 라이브러리와 리소스에는 각각의 라이선스가 적용됩니다. 번들에 포함된 [Mermaid](Sources/SynologyNote/Resources/MERMAID-LICENSE.txt)와 [KaTeX](Sources/SynologyNote/Resources/KATEX-LICENSE.txt)의 고지를 함께 확인하세요.

## 기여 및 보안 제보

기여 방법은 [CONTRIBUTING.md](CONTRIBUTING.md)를 확인하세요. 취약점은 공개 Issue 대신 [SECURITY.md](SECURITY.md)의 비공개 제보 절차를 이용해 주세요.
