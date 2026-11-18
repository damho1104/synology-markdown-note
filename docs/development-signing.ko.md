# 개발 빌드의 자동 로그인

[English](development-signing.md) | **한국어**

UI를 다시 빌드한 뒤 키체인 확인을 반복하던 원인은 임시 서명과 macOS의 키체인 partition 검사다. 자체 서명 인증서로 designated requirement를 고정해도, Apple 팀 식별자가 없는 프로그램에는 빌드별 `cdhash` partition이 적용될 수 있다. 실제 검사에서도 본문이 다른 두 프로그램의 키체인 공유가 거부됐다.

현재 빌드는 다음 방식으로 처리한다.

- 앱과 보조 프로그램은 로그인 키체인에 보관한 동일한 로컬 개발 인증서로 서명한다. 루트 인증서 신뢰나 TLS 신뢰 설정은 변경하지 않는다.
- 키체인 접근은 `Contents/Helpers/SynologyCredentialHelper`가 담당한다. 이 바이너리는 보조 프로그램과 CredentialStore 소스가 바뀔 때만 갱신하며 UI 수정 시에는 그대로 재사용한다.
- 앱은 실행 전 보조 프로그램의 서명을 검사한다. 보조 프로그램도 부모 프로세스가 동일한 인증서로 서명된 `com.damho.SynologyMarkdown`인지 확인한다. 임의의 터미널 프로그램이나 다른 앱의 요청은 키체인에 접근하기 전에 거부한다.
- 비밀번호와 NAS 기기 토큰은 프로세스의 표준 입력/출력 파이프로만 전달하며 명령 인수·파일·로그에 저장하지 않는다. 자동 읽기는 3초, 사용자가 요청한 키체인 확인은 180초 안에 완료되지 않으면 보조 프로세스를 종료한다.

기존 앱에서 보조 프로그램으로 전환할 때에는 기존 NAS 키체인 항목에 대해 macOS의 접근 확인이 한 번 필요하다. 이때 ‘항상 허용’을 선택한다. 이후 UI를 다시 빌드하거나 앱을 재실행할 때에는 저장된 비밀번호와 기기 토큰으로 자동 연결한다. 보조 프로그램 자체 변경, NAS의 기기 신뢰 해제, 키체인 잠금 시에는 추가 확인이 필요할 수 있다.

개발 인증서의 공개 지문은 `~/Library/Application Support/SynologyMarkdown/DevelopmentSigning/identity.json`에 저장하며 개인 키는 로그인 키체인에만 보관한다. 이 파일이나 인증서를 임의로 교체하지 않는다.

## 검증

```sh
python3 script/test_signing.py
./script/test.sh
./script/build_and_run.sh
```

서명 검사는 서로 다른 두 앱 바이너리가 같은 보조 프로그램으로 합성 계정의 비밀번호·기기 토큰을 저장하고 다시 읽는지 확인한다. 관련 없는 부모 프로세스와 다른 식별자로 서명된 앱의 요청이 거부되는지도 검사한다. 실제 NAS 계정은 이 검사에서 사용하지 않는다.

참고: [Apple 코드 서명 요구 조건](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [macOS 코드 서명과 키체인](https://developer.apple.com/library/archive/technotes/tn2206/).
