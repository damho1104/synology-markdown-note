# GitHub 자동 릴리스

`.github/workflows/release.yml`은 GitHub 저장소에 등록한 **셀프호스팅 러너**에서 실행합니다. 버전 검증·Linux 빌드·릴리스 게시에는 `[self-hosted, Linux, X64, docker-compose]`, macOS 빌드에는 `[self-hosted, macOS, ARM64]` 라벨을 사용합니다. Linux 러너에는 Docker가, macOS 러너에는 호환되는 Swift 개발 도구가 필요합니다.

## 태그와 버전

`develop`은 개발·통합 브랜치, `main`은 정식 릴리스 기준 브랜치입니다. 기본 브랜치는 `main`입니다. 이 사용자 소유 저장소에서는 Pull Request를 만들지 않습니다. feature → develop, develop → main은 직접 `git merge --no-ff`로 통합하고, `main`에서 버전 태그를 만듭니다.

`v1.2.17` 또는 `1.2.17`처럼 `X.Y.Z` 앞에 선택적으로 `v`만 붙일 수 있습니다. `1.2.17-abcdef0` 같은 short commit 접미사, 사전 릴리스 접미사는 허용하지 않습니다. 태그 버전이 `cli/pyproject.toml`의 `project.version`과 다르면 빌드를 중단합니다.

1. 공통 버전을 `cli/pyproject.toml`, `web/backend/pyproject.toml`, `web/frontend/package.json`에 함께 반영합니다. CLI와 웹 백엔드에서 `uv lock`, 웹 프런트엔드에서 `npm install --package-lock-only`로 잠금 파일도 갱신합니다.
2. 변경 사항을 커밋하고 `develop`에 푸시합니다.
3. CI가 통과하면 로컬 `main`을 최신 원격 상태로 갱신하고 `git merge --no-ff develop`으로 통합한 뒤 `main`을 푸시합니다. PR은 생성하지 않습니다.
4. 로컬 `main`을 갱신한 뒤 버전 태그를 붙여 푸시합니다. 아래는 소스 버전이 `1.2.17`일 때의 예이며, 이미 게시된 태그는 다시 만들거나 이동하지 않습니다.

```sh
git switch main
git pull --ff-only origin main
git tag v1.2.17
git push origin v1.2.17
```

릴리스 앱·CLI의 표시 버전은 `1.2.17`이며 파일명에도 short commit을 붙이지 않습니다. 앱 내부의 별도 Git commit 메타데이터는 추적용으로 유지합니다. 일반 소스 개발 빌드는 기존처럼 `1.2.17-abcdef0` 형태로 표시합니다.

태그는 브랜치가 아닌 커밋을 가리킵니다. `main`과 `develop`이 공유하는 커밋의 태그는 두 브랜치에서 모두 보일 수 있습니다. 릴리스 워크플로는 최신 `origin/main`을 가져와 태그 커밋의 포함 여부를 검사하고, 아직 `main`에 병합되지 않은 개발 커밋이면 빌드 전에 중단합니다. 릴리스 워크플로는 버전 태그 푸시로만 실행하며, 브랜치 푸시와 수동 실행은 허용하지 않습니다.

## 빌드 산출물

| 대상 | GitHub 실행 환경 | 게시 파일 |
| --- | --- | --- |
| macOS arm64 | macOS ARM64 셀프호스팅 러너 | 앱 DMG·ZIP, CLI, 앱 manifest·설치 안내, `SHA256SUMS-macos-arm64` |
| Ubuntu 22.04 amd64 | Linux X64 셀프호스팅 러너의 `ubuntu:22.04` 컨테이너 | CLI, `SHA256SUMS-ubuntu-22.04-amd64` |
| Ubuntu 24.04 amd64 | Linux X64 셀프호스팅 러너의 `ubuntu:24.04` 컨테이너 | CLI, `SHA256SUMS-ubuntu-24.04-amd64` |
| Linux x86_64 / glibc 2.28+ | 같은 Linux 러너의 `quay.io/pypa/manylinux_2_28_x86_64` 컨테이너 | 공용 CLI, `SHA256SUMS-linux-glibc2.28-amd64` |

예시 파일명은 `SynologyMarkdownNote-1.2.17-arm64.dmg`, `synonote-cli-v1.2.17-ubuntu-22.04-amd64`입니다. CLI 파일명에는 푸시한 태그를 그대로 사용합니다.

각 빌드 환경에서 CLI 테스트와 단일 실행 파일의 `version`·`--help` 실행을 확인합니다. macOS에서는 Swift 테스트, 중첩 코드 서명, DMG 마운트·ZIP 복원 검증도 수행합니다. 모든 빌드와 체크섬 확인이 끝난 뒤 Draft 릴리스에 파일을 업로드하고 게시합니다. 게시된 동일 태그 릴리스는 덮어쓰지 않으며, 중단된 Draft는 재실행으로 이어갈 수 있습니다.

릴리스 워크플로에는 `workflow_dispatch`가 없습니다. 버전 태그 푸시가 있어야 테스트·빌드·게시가 시작됩니다. 일반 개발 검증은 CI 워크플로를 사용합니다.

## 웹 Docker 이미지 / GHCR

릴리스 워크플로에 웹 이미지 게시도 포함합니다. **이미지 빌드·게시는 `[self-hosted, Linux, X64, docker-compose]` 러너**에서 수행합니다. 해당 Linux 호스트에는 Docker와 Python 3가 필요하고 Docker에서 QEMU/binfmt 및 Buildx 빌더를 실행할 수 있어야 합니다. Node 22와 Python 3.13 기반 웹 테스트는 같은 러너의 Ubuntu 컨테이너에서 준비합니다.

- `web-checks.yml`: 백엔드 전체 테스트, 프런트엔드 테스트·빌드, 앱·CLI·웹 프런트/백엔드 공통 버전 일치 검증.
- `ci.yml`: 일반 브랜치 및 PR에서는 위 검증만 수행하며 이미지를 게시하지 않습니다. PR 테스트는 기존 CI 정책처럼 GitHub 호스팅 환경으로 격리하고, 일반 브랜치 검증과 릴리스 작업은 셀프호스트 러너를 사용합니다.
- `release.yml`: 위 릴리스 태그/`main` 검증과 앱·CLI 검증이 모두 통과하면 `web-image` 작업이 `linux/amd64`, `linux/arm64` 이미지를 빌드하여 GHCR에 게시합니다. 두 플랫폼이 manifest에 있는지도 확인합니다.
- 이미지 이름은 `ghcr.io/<저장소 소유자>/synology-md-note-web`이고 태그는 `latest`와 공통 릴리스 버전 `X.Y.Z`입니다. 예를 들어 `v1.2.18` 릴리스라면 앱·CLI·웹 버전을 모두 `1.2.18`로 맞추고 `:latest`, `:1.2.18`을 게시합니다. 웹 설정에도 `1.2.18`로 표시합니다. 버전이 다르면 게시 전에 검증을 실패시킵니다.
- GHCR 로그인은 `GITHUB_TOKEN`과 해당 작업의 `packages: write` 권한을 사용합니다. 개인 레지스트리 주소나 별도 레지스트리 비밀번호는 필요하지 않습니다.

최초 게시 후 GitHub Packages에서 `synology-md-note-web` 패키지가 **Public**인지 확인합니다. 비공개 상태에서는 설치자가 인증 없이 이미지를 내려받을 수 없습니다. 다른 소유자 계정으로 포크하여 게시한다면 Compose와 `.env.example`의 GHCR 소유자 부분도 맞춥니다.

사용자용 다운로드·실행 명령은 [셀프호스팅 설치 안내](../web/SELF-HOSTING.md)에 있습니다. 워크플로 파일을 작성한 상태와 실제 태그 실행·이미지 게시 성공은 구분해서 확인합니다.

## Linux 공용 실행 파일 검증

`script/build_linux_portable.sh`는 glibc 2.28 빌드 컨테이너에서 공유 라이브러리를 포함하는 uv 관리 CPython 3.13을 사용합니다. 이미지에 내장된 정적 CPython은 PyInstaller에 필요한 `libpython.so`가 없어 사용하지 않습니다. 임시 가상환경에서 잠금 파일과 전체 CLI 테스트를 확인하고 결과를 `synonote-cli-<TAG>-linux-glibc2.28-amd64`로 게시합니다. 기존 Ubuntu 전용 파일도 유지합니다.

`linux-compatibility` 작업은 동일한 공용 바이너리를 Debian 11·12·13, Ubuntu 20.04·22.04·24.04, AlmaLinux 8·9, Rocky Linux 8·9, Fedora 43, openSUSE Leap 16.0의 깨끗한 컨테이너에서 실행합니다. 대상 컨테이너에는 Python을 설치하지 않습니다. 체크섬을 확인한 후 `script/smoke_linux_binary.sh`로 버전·하위 명령 도움말·한글 설정 경로·로그아웃과 SSL 클라이언트 초기화를 검사합니다. 접속 테스트는 사용하지 않는 로컬 포트에 대한 오류 처리를 확인하며 실제 NAS로 자격 증명을 보내지 않습니다.

모든 배포판 검증이 성공해야 `publish` 작업이 시작됩니다. `v1.2.17` 재빌드부터 이 공용 실행 파일과 전용 체크섬을 기존 macOS·Ubuntu 산출물과 함께 게시합니다. 이미지 태그는 고정된 배포판 버전을 사용하지만 보안 업데이트로 내용은 갱신될 수 있습니다. 실제 NAS, Linux ARM64, Alpine/musl은 이 검증 범위에 포함하지 않습니다. [PyInstaller 안내](https://pyinstaller.org/en/stable/usage.html#making-gnu-linux-apps-forward-compatible)와 [manylinux 안내](https://github.com/pypa/manylinux)를 참고하세요.

## macOS 서명 설정

릴리스 전용 인증서는 다음 Repository Secrets로 보관합니다.

- `MACOS_SIGNING_P12_BASE64`: 인증서와 개인 키가 포함된 PKCS#12 파일의 Base64.
- `MACOS_SIGNING_P12_PASSWORD`: 해당 PKCS#12 암호.
- `MACOS_SIGNING_CERT_SHA1`: 고정한 인증서의 SHA-1 지문(콜론 없는 40자리).

최초 설정 시 OpenSSL과 인증된 GitHub CLI가 있는 환경에서 다음을 실행할 수 있습니다.

```sh
python3 script/create_release_signing.py --repo OWNER/REPOSITORY
```

이 스크립트는 새 자체 서명 인증서를 생성해 위 Secrets에 등록하고 임시 개인 키 파일을 정리합니다. 기존 릴리스 Secrets가 있으면 인증서를 교체하지 않고 중단합니다. 러너는 인증서 지문을 확인하고 실행별 임시 키체인에서 서명한 뒤 해당 키체인을 검색 목록에서 제거하고 삭제합니다. 러너의 다른 키체인은 유지합니다. 서명 인증서는 릴리스 간에 동일하게 유지해야 키체인 접근 호환성을 유지할 수 있습니다.

이 자체 서명은 **Apple Developer ID 서명이나 Apple 공증이 아닙니다.** 실제 다른 Mac 설치, NAS 접속, 기존 버전에서의 키체인 승계는 별도로 검증해야 합니다. [설치·배포 안내](distribution.ko.md)를 함께 확인하세요.

참고: [GitHub 컨테이너 작업](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container), [GitHub 셀프호스팅 러너](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners), [GitHub CLI 릴리스 생성](https://cli.github.com/manual/gh_release_create).
