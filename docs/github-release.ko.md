# GitHub 자동 릴리스

`.github/workflows/release.yml`은 GitHub 호스팅 러너에서 실행합니다.

## 태그와 버전

`v1.2.17` 또는 `1.2.17`처럼 `X.Y.Z` 앞에 선택적으로 `v`만 붙일 수 있습니다. `1.2.17-abcdef0` 같은 short commit 접미사, 사전 릴리스 접미사는 허용하지 않습니다. 태그 버전이 `cli/pyproject.toml`의 `project.version`과 다르면 빌드를 중단합니다.

1. `cli/pyproject.toml`의 버전을 수정하고 `cli/`에서 `uv lock`을 실행해 `uv.lock`을 갱신합니다.
2. 변경 사항을 커밋하고 `develop`에 푸시합니다.
3. 해당 커밋에 버전 태그를 붙여 푸시합니다. 아래는 소스 버전이 `1.2.17`일 때의 예입니다.

```sh
git tag v1.2.17
git push origin v1.2.17
```

릴리스 앱·CLI의 표시 버전은 `1.2.17`이며 파일명에도 short commit을 붙이지 않습니다. 앱 내부의 별도 Git commit 메타데이터는 추적용으로 유지합니다. 일반 소스 개발 빌드는 기존처럼 `1.2.17-abcdef0` 형태로 표시합니다.

## 빌드 산출물

| 대상 | GitHub 실행 환경 | 게시 파일 |
| --- | --- | --- |
| macOS arm64 | `macos-15` arm64 러너 | 앱 DMG·ZIP, CLI, 앱 manifest·설치 안내, `SHA256SUMS-macos-arm64` |
| Ubuntu 22.04 amd64 | `ubuntu-24.04` 호스트의 `ubuntu:22.04` 컨테이너 | CLI, `SHA256SUMS-ubuntu-22.04-amd64` |
| Ubuntu 24.04 amd64 | `ubuntu-24.04` 호스트의 `ubuntu:24.04` 컨테이너 | CLI, `SHA256SUMS-ubuntu-24.04-amd64` |

예시 파일명은 `SynologyMarkdownNote-1.2.17-arm64.dmg`, `synonote-cli-v1.2.17-ubuntu-22.04-amd64`입니다. CLI 파일명에는 푸시한 태그를 그대로 사용합니다.

각 빌드 환경에서 CLI 테스트와 단일 실행 파일의 `version`·`--help` 실행을 확인합니다. macOS에서는 Swift 테스트, 중첩 코드 서명, DMG 마운트·ZIP 복원 검증도 수행합니다. 모든 빌드와 체크섬 확인이 끝난 뒤 Draft 릴리스에 파일을 업로드하고 게시합니다. 게시된 동일 태그 릴리스는 덮어쓰지 않으며, 중단된 Draft는 재실행으로 이어갈 수 있습니다.

Actions의 수동 실행은 동일한 빌드·검증 후 7일 보관되는 Actions Artifact만 생성합니다. 수동 실행으로 릴리스나 태그를 생성하지 않습니다.

## macOS 서명 설정

릴리스 전용 인증서는 다음 Repository Secrets로 보관합니다.

- `MACOS_SIGNING_P12_BASE64`: 인증서와 개인 키가 포함된 PKCS#12 파일의 Base64.
- `MACOS_SIGNING_P12_PASSWORD`: 해당 PKCS#12 암호.
- `MACOS_SIGNING_CERT_SHA1`: 고정한 인증서의 SHA-1 지문(콜론 없는 40자리).

최초 설정 시 OpenSSL과 인증된 GitHub CLI가 있는 환경에서 다음을 실행할 수 있습니다.

```sh
python3 script/create_release_signing.py --repo OWNER/REPOSITORY
```

이 스크립트는 새 자체 서명 인증서를 생성해 위 Secrets에 등록하고 임시 개인 키 파일을 정리합니다. 기존 릴리스 Secrets가 있으면 인증서를 교체하지 않고 중단합니다. 러너는 인증서 지문을 확인하고 임시 키체인에서 서명한 뒤 키체인을 삭제합니다. 서명 인증서는 릴리스 간에 동일하게 유지해야 키체인 접근 호환성을 유지할 수 있습니다.

이 자체 서명은 **Apple Developer ID 서명이나 Apple 공증이 아닙니다.** 실제 다른 Mac 설치, NAS 접속, 기존 버전에서의 키체인 승계는 별도로 검증해야 합니다. [설치·배포 안내](distribution.ko.md)를 함께 확인하세요.

참고: [GitHub 컨테이너 작업](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container), [GitHub 호스팅 러너](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [GitHub CLI 릴리스 생성](https://cli.github.com/manual/gh_release_create).
