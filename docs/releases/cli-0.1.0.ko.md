# synonote CLI 0.1.0

태그: `cli-v0.1.0` (macOS 앱 릴리스 `1.2.2`와 별도)

Python 3.13 기반의 독립적인 Synology Note Station Markdown 업로드·다운로드 CLI 첫 배포다. `uv`로 패키지를 관리하며 PyInstaller `--onefile` 실행 파일을 지원한다.

## 주요 기능

- 책장·메모장·노트 조회 및 JSON 출력으로 LLM 자동화 지원.
- UTF-8 Markdown 업로드, 검증된 Markdown 다운로드, 동일 제목 충돌 시 diff 출력.
- 명시적인 `--overwrite`와 원격 버전 재확인, HTML 전용 노트 덮어쓰기 거부.
- 앱의 `SourceEnvelope` v1/v2/v3 읽기와 모의 NAS·공통 fixture 검증.
- NAS 쓰기 결과 불확실 시 작업 저널 조회·복구 확인 명령 제공.
- 기억된 로그인: macOS Keychain, Windows Credential Manager, Linux 권한 제한 로컬 JSON 파일(`~/.config/synonote/credentials.json`, 평문).

## 배포 파일

- `synonote-macos-arm64`: macOS Apple Silicon용 PyInstaller onefile 실행 파일. 다운로드 후 실행 권한이 없으면 `chmod +x synonote-macos-arm64`로 설정한다.
- `synonote_cli-0.1.0-py3-none-any.whl`: Python 3.13용 wheel (실행 시 의존성 설치 필요).
- `synonote_cli-0.1.0.tar.gz`: Python 소스 배포 패키지.
- `SHA256SUMS`: 첨부된 배포 파일의 SHA-256 검사 목록.

## 검증과 한계

- macOS arm64에서 onefile 빌드·도움말 실행·인증 미설정 JSON 오류 코드·로컬 코드 서명 검증 완료.
- Python 테스트 61개 통과, `uv lock --check` 완료.
- Linux/Windows용 onefile 바이너리 및 실제 NAS 왕복은 아직 미검증이므로 첨부하지 않는다. 해당 OS에서는 `cli/README.md`의 `uv` 설치 및 OS별 onefile 빌드 방법을 사용한다.
- 이미지·수식 첨부 관련 일부 작업은 안전하게 거부한다. 자세한 제한은 `cli/README.md` 참고.
- macOS 실행 파일은 Apple Developer ID 공증을 받지 않았다. 다른 Mac에서의 Gatekeeper 통과는 보장하지 않는다.
