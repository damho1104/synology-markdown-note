# 기여 안내

Synology Markdown Note에 관심을 가져주셔서 감사합니다. 변경 전 기존 Issue와 Pull Request를 확인하고, 동작 변경은 가능하면 재현 절차와 테스트를 포함해 주세요.

## 브랜치 운영

- `develop`: 개발·통합 브랜치. 기능 수정 Pull Request는 기본적으로 이 브랜치를 대상으로 합니다.
- `main`: 기본 브랜치이자 정식 릴리스 기준. 검증된 `develop`을 Pull Request로 병합합니다.
- 정식 버전 태그는 `main`에서 만들고, 게시된 태그는 이동하지 않습니다. 릴리스 워크플로는 태그 커밋이 `origin/main`에 포함되지 않으면 중단합니다.
- `develop`·`main`의 수동 릴리스 실행은 산출물 검증만 수행하며 태그나 릴리스를 게시하지 않습니다.

자세한 절차는 [GitHub 릴리스 안내](docs/github-release.ko.md)를 참고하세요.

## 로컬 검증

macOS 앱과 공통 로직은 Xcode 및 Swift 도구가 필요합니다.

```sh
./script/test.sh
```

CLI는 Python 3.13과 [uv](https://docs.astral.sh/uv/)를 사용합니다.

```sh
cd cli
uv sync --locked
uv run --locked pytest -q tests
```

Pull Request에는 변경 목적, 테스트 결과, 알려진 제한 사항을 적어 주세요. 내부 NAS를 사용한 검증은 공개 테스트 계정 대신 개인 환경에서 수행하되, 실제 노트·서버 URL·인증정보·진단 원본을 Issue/PR/커밋에 올리지 마세요. 서명 인증서, 키체인과 실행 로그도 공유하지 마세요.

## 코드와 문서

기존 스타일을 유지하고, 관련 기능의 동작이 바뀌면 README 또는 문서도 업데이트해 주세요. 스크립트·워크플로에 개인 경로와 서버 주소를 하드코딩하지 마세요.

이 프로젝트는 Synology가 제작하거나 지원하는 공식 제품이 아닙니다.
