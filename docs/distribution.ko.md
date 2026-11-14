# Synology Markdown Note 설치 및 배포

## 지원 환경

macOS 앱은 **Apple Silicon(arm64), macOS 14 이상**을 대상으로 합니다. Synology NAS에 Note Station이 설치되어 있어야 하며, NAS 서버에는 HTTPS로 연결합니다. CLI는 별도의 소스 빌드 또는 검증된 릴리스 실행 파일을 사용할 수 있습니다.

## 릴리스 설치

1. [GitHub Releases](https://github.com/damho1104/synology-markdown-note/releases)에 설치 파일이 게시되어 있는지 확인합니다. **릴리스 파일이 없으면 배포된 바이너리가 없는 상태입니다.**
2. macOS용 DMG와 체크섬이 게시된 경우 출처와 SHA-256을 확인한 뒤 DMG를 열어 앱을 `Applications` 폴더로 복사합니다.
3. 앱을 실행한 뒤 설정에서 자신의 NAS URL과 계정 정보를 입력합니다.

개발용 인증서로 서명된 앱은 **Apple Developer ID 서명·Apple 공증을 받지 않았습니다.** 배포 신뢰가 자동으로 확인되거나 Gatekeeper를 통과한다는 뜻이 아닙니다. OS가 실행을 차단하면 출처를 충분히 확인한 뒤 macOS의 **시스템 설정 → 개인정보 보호 및 보안** 안내를 따르세요. 보안 설정을 전역으로 해제하거나 검증되지 않은 파일을 실행하지 마세요.

Intel Mac, 다른 Mac에서의 설치·키체인 호환성, 실제 NAS와의 동작은 별도 검증이 필요합니다. 현재 개발 빌드 환경의 서명·키체인 설정은 [개발 빌드 안내](development-signing.ko.md)를 참고하세요.

## 소스 빌드

Swift 개발 도구(Xcode 또는 Command Line Tools)를 설치한 뒤 저장소 루트에서 다음을 실행합니다.

```sh
swift build
./script/test.sh
```

`./script/build_and_run.sh --build`는 macOS 앱 번들을 만들지만, 서명된 Credential Helper 및 개발용 서명 인증서 설정이 필요합니다. 이 스크립트는 공증된 배포판을 만드는 도구가 아닙니다.

CLI는 [uv](https://docs.astral.sh/uv/getting-started/installation/)를 설치한 후 다음과 같이 빌드합니다.

```sh
cd cli
uv python install 3.13
uv sync --locked
uv run --locked pytest -q tests
uv run --locked python build_onefile.py
```

빌드 실행 파일은 `cli/dist/synonote`이며, 실행 환경과 같은 OS·아키텍처에서 빌드해야 합니다. 사용법은 [CLI 문서](../cli/README.md)를 참고하세요.

## 릴리스 검증 범위

소스 테스트 통과가 코드 서명·공증·다른 기기에서의 실행을 보장하지 않습니다. 추후 GitHub Releases에 설치 파일을 게시할 때는 각 파일의 체크섬, 서명 상태, 대상 기기 설치 및 NAS 동작을 별도로 확인해야 합니다.
