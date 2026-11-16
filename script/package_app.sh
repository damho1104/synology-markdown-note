#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE_NAME="Synology Markdown Note.app"
BUILD=0
SOURCE_APP="$ROOT_DIR/dist/$APP_BUNDLE_NAME"
OUTPUT=""
EXPLICIT_APP=0
usage() {
    cat <<'USAGE'
사용법: rtk proxy ./script/package_app.sh [--build | --app '/path/Synology Markdown Note.app'] [--output /new/output]
  --build    별도 scratch 경로에서 native Release 빌드 (실행 중 앱/dist 앱 유지)
  --app      이미 서명된 앱 번들을 복사해 패키징 (원본 수정/재서명 안 함)
  --output   새 출력 디렉터리 (기본 dist/releases/SynologyMarkdownNote-<version>-<arch>)
기본 동작은 dist/Synology Markdown Note.app을 패키징합니다. 기존 출력은 덮어쓰지 않습니다.
기존 credential helper와 로컬 서명 인증서가 필요합니다. 앱 실행/NAS 연결은 하지 않습니다.
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD=1; shift ;;
        --app|--output)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
            if [[ "$1" == --app ]]; then SOURCE_APP="$2"; EXPLICIT_APP=1; else OUTPUT="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ "$BUILD" == 1 && "$EXPLICIT_APP" == 1 ]]; then usage >&2; exit 2; fi
if [[ -n "$OUTPUT" && -e "$OUTPUT" ]]; then
    echo "출력 경로가 이미 존재합니다: $OUTPUT" >&2; exit 1
fi

HELPER_CACHE="$ROOT_DIR/.build/credential-helper/SynologyCredentialHelper"
HELPER_HASH=""
if [[ -f "$HELPER_CACHE" ]]; then HELPER_HASH="$(shasum -a 256 "$HELPER_CACHE" | awk '{print $1}')"; fi
if [[ "$BUILD" == 1 ]]; then
    [[ -n "$HELPER_HASH" ]] || { echo "기존 서명된 credential helper가 필요합니다." >&2; exit 1; }
fi
# Packaging never bootstraps a signing identity or changes Keychain settings.
python3 - <<'PY'
import pathlib
import os
metadata = pathlib.Path(os.environ.get('SYNOLOGY_NOTE_SIGNING_IDENTITY_FILE', str(pathlib.Path.home() / 'Library/Application Support/SynologyMarkdown/DevelopmentSigning/identity.json')))
if not metadata.is_file():
    raise SystemExit('기존 로컬 서명 인증서 설정이 필요합니다. docs/development-signing.ko.md를 확인하세요.')
PY
SIGNING_IDENTITY="$(python3 "$ROOT_DIR/script/local_signing_identity.py")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/synology-note-package.XXXXXX")"
MOUNT_POINT="$WORK/mounted"
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then
        if ! hdiutil detach "$MOUNT_POINT" -quiet; then
            echo "이미지 분리 실패: 수동 분리 후 임시 경로를 정리하세요: $WORK" >&2
            return
        fi
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$BUILD" == 1 ]]; then
    SOURCE_APP="$WORK/build/$APP_BUNDLE_NAME"
    # Shared-workspace edits must not change compiler inputs mid-build. Freeze
    # the inputs as well as isolating SwiftPM's scratch directory. Do not copy
    # dist, user data, signing private keys, or the existing SwiftPM build tree.
    SNAPSHOT="$WORK/source"
    mkdir -p "$SNAPSHOT/script" "$SNAPSHOT/tools" "$SNAPSHOT/.build/credential-helper" "$SNAPSHOT/cli/src/synonote_cli"
    ditto "$ROOT_DIR/Sources" "$SNAPSHOT/Sources"
    # SwiftPM resolves every declared target's path even for --product builds.
    ditto "$ROOT_DIR/Tests" "$SNAPSHOT/Tests"
    ditto "$ROOT_DIR/tools/CredentialHelper" "$SNAPSHOT/tools/CredentialHelper"
    cp "$ROOT_DIR/Package.swift" "$ROOT_DIR/Package.resolved" "$SNAPSHOT/"
    for name in build_and_run.sh build_credential_helper.py swift.sh sign_app.sh local_signing_identity.py version_info.py; do
        cp "$ROOT_DIR/script/$name" "$SNAPSHOT/script/$name"
    done
    cp "$ROOT_DIR/cli/pyproject.toml" "$SNAPSHOT/cli/pyproject.toml"
    cp "$ROOT_DIR/cli/src/synonote_cli/build_version.py" "$SNAPSHOT/cli/src/synonote_cli/build_version.py"
    cp "$HELPER_CACHE" "$SNAPSHOT/.build/credential-helper/SynologyCredentialHelper"
    cp "$ROOT_DIR/.build/credential-helper/manifest.json" "$SNAPSHOT/.build/credential-helper/manifest.json"
    cmp "$HELPER_CACHE" "$SNAPSHOT/.build/credential-helper/SynologyCredentialHelper"
    SYNOLOGY_NOTE_APP_BUNDLE="$SOURCE_APP" \
    SYNOLOGY_NOTE_SCRATCH_PATH="$WORK/scratch" \
    SYNOLOGY_NOTE_CONFIGURATION=release \
    SYNOLOGY_NOTE_REQUIRE_CACHED_HELPER=1 \
    SYNOLOGY_NOTE_GIT_COMMIT="$(python3 "$ROOT_DIR/script/version_info.py" --hash)" \
        /bin/bash "$SNAPSHOT/script/build_and_run.sh" --build
fi
[[ -d "$SOURCE_APP" ]] || { echo "앱 번들이 없습니다: $SOURCE_APP" >&2; exit 1; }
mkdir -p "$WORK/payload" "$WORK/result" "$MOUNT_POINT"
APP="$WORK/payload/$APP_BUNDLE_NAME"
ditto "$SOURCE_APP" "$APP"

# Inspect the copied app before making any installable artifact. No deep signing:
# sign_app.sh already signs the outer bundle around the unchanged signed helper.
codesign --verify --strict --deep "$APP"
codesign --verify --strict "$APP/Contents/Helpers/SynologyCredentialHelper"
codesign -d --extract-certificates="$WORK/app-cert-" "$APP"
codesign -d --extract-certificates="$WORK/helper-cert-" "$APP/Contents/Helpers/SynologyCredentialHelper"
cmp "$WORK/app-cert-0" "$WORK/helper-cert-0"
codesign --verify --strict "-R=identifier \"com.damho.SynologyMarkdown\" and certificate leaf = H\"$SIGNING_IDENTITY\"" "$APP"
codesign --verify --strict "-R=identifier \"com.damho.SynologyMarkdown.CredentialHelper\" and certificate leaf = H\"$SIGNING_IDENTITY\"" "$APP/Contents/Helpers/SynologyCredentialHelper"
if [[ -n "$HELPER_HASH" ]]; then
    [[ "$(shasum -a 256 "$HELPER_CACHE" | awk '{print $1}')" == "$HELPER_HASH" ]]
    [[ "$(shasum -a 256 "$APP/Contents/Helpers/SynologyCredentialHelper" | awk '{print $1}')" == "$HELPER_HASH" ]]
fi

BASE_VERSION="$(python3 "$ROOT_DIR/script/version_info.py" --base)"
APP_INFO="$(python3 - "$APP" "$WORK/result/manifest.json" "$BUILD" "$BASE_VERSION" <<'PY'
import hashlib, json, os, pathlib, plistlib, re, subprocess, sys
app, manifest = map(pathlib.Path, sys.argv[1:3])
contents = app / 'Contents'
info = plistlib.loads((contents / 'Info.plist').read_bytes())
base_version = sys.argv[4]
expected = {'CFBundleIdentifier': 'com.damho.SynologyMarkdown',
            'CFBundleExecutable': 'SynologyNote', 'CFBundlePackageType': 'APPL',
            'CFBundleName': 'Synology Markdown Note',
            'CFBundleDisplayName': 'Synology Markdown Note',
            'CFBundleShortVersionString': base_version, 'CFBundleVersion': '29',
            'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '14.0'}
for key, value in expected.items():
    if info.get(key) != value: raise SystemExit(f'{key}: expected {value!r}, got {info.get(key)!r}')
display_version = info.get('SynologyDisplayVersion', '')
commit = info.get('SynologyGitCommit', '')
if not re.fullmatch(rf'{re.escape(base_version)}(?:-[0-9a-f]{{7,40}})?', display_version):
    raise SystemExit(f'Invalid display version: {display_version!r}')
if display_version not in (base_version, f'{base_version}-{commit}'):
    raise SystemExit('Bundle display version and git commit differ')
if os.environ.get('SYNOLOGY_NOTE_RELEASE_TAG') and display_version != base_version:
    raise SystemExit('Release bundle must not include a commit suffix')
binary = contents / 'MacOS/SynologyNote'
helper = contents / 'Helpers/SynologyCredentialHelper'
icon = contents / 'Resources/AppIcon.icns'
resources = contents / 'Resources/SynologyNote_SynologyNote.bundle'
runtime_files = [resources / name for name in (
    'mermaid.min.js', 'MERMAID-LICENSE.txt',
    'katex.min.js', 'katex-offline.min.css', 'KATEX-LICENSE.txt')]
for path in (binary, helper, icon, *runtime_files):
    if not path.is_file() or path.stat().st_size == 0: raise SystemExit(f'Missing bundle file: {path.name}')
math_css = (resources / 'katex-offline.min.css').read_text()
if math_css.count('data:font/woff2;base64,') != 20 or 'url(fonts/' in math_css:
    raise SystemExit('KaTeX offline fonts are missing')
icon_bytes = icon.read_bytes()
if icon_bytes[:4] != b'icns' or int.from_bytes(icon_bytes[4:8], 'big') != len(icon_bytes):
    raise SystemExit('Invalid AppIcon.icns')
def architectures(path):
    return sorted(subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split())
archs = architectures(binary)
if archs != architectures(helper): raise SystemExit('App/helper architecture mismatch')
if archs == ['arm64', 'x86_64']: label = 'universal'
elif archs in (['arm64'], ['x86_64']): label = archs[0]
else: raise SystemExit(f'Unsupported architecture set: {archs}')
record = dict(version=display_version, base_version=base_version, git_commit=commit,
              build=info['CFBundleVersion'],
              architecture=label, minimum_macos=info['LSMinimumSystemVersion'],
              configuration='release' if sys.argv[3] == '1' else 'prebuilt (not inferred)',
              signing='existing local certificate; not Developer ID distribution',
              notarized=False, other_mac_tested=False,
              sha256={str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in (contents / 'Info.plist', binary, helper, icon, *runtime_files)})
manifest.write_text(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
print(f'{label}|{display_version}')
PY
)"
IFS='|' read -r ARCH DISPLAY_VERSION <<< "$APP_INFO"
BASE="SynologyMarkdownNote-$DISPLAY_VERSION-$ARCH"
OUTPUT="${OUTPUT:-$ROOT_DIR/dist/releases/$BASE}"
[[ ! -e "$OUTPUT" ]] || { echo "출력 경로가 이미 존재합니다: $OUTPUT" >&2; exit 1; }
ln -s /Applications "$WORK/payload/Applications"
cp "$ROOT_DIR/docs/distribution.ko.md" "$WORK/payload/설치안내.ko.md"
cp "$WORK/result/manifest.json" "$WORK/payload/manifest.json"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/result/$BASE.zip"
hdiutil create -quiet -srcfolder "$WORK/payload" -volname "Synology Markdown Note $DISPLAY_VERSION" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -nospotlight -noanyowners "$WORK/result/$BASE.dmg"
hdiutil verify "$WORK/result/$BASE.dmg"

# A read-only, non-Finder mount checks the actual image, not just the source tree.
hdiutil attach "$WORK/result/$BASE.dmg" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
codesign --verify --strict --deep "$MOUNT_POINT/$APP_BUNDLE_NAME"
cmp "$APP/Contents/Helpers/SynologyCredentialHelper" "$MOUNT_POINT/$APP_BUNDLE_NAME/Contents/Helpers/SynologyCredentialHelper"
cmp "$APP/Contents/Info.plist" "$MOUNT_POINT/$APP_BUNDLE_NAME/Contents/Info.plist"
cmp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT_POINT/$APP_BUNDLE_NAME/Contents/Resources/AppIcon.icns"
[[ "$(readlink "$MOUNT_POINT/Applications")" == /Applications ]]
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

mkdir "$WORK/unzip"
ditto -x -k "$WORK/result/$BASE.zip" "$WORK/unzip"
codesign --verify --strict --deep "$WORK/unzip/$APP_BUNDLE_NAME"
cmp "$APP/Contents/Helpers/SynologyCredentialHelper" "$WORK/unzip/$APP_BUNDLE_NAME/Contents/Helpers/SynologyCredentialHelper"
if [[ -n "$HELPER_HASH" ]]; then
    [[ "$(shasum -a 256 "$HELPER_CACHE" | awk '{print $1}')" == "$HELPER_HASH" ]]
fi
ditto "$APP" "$WORK/result/$APP_BUNDLE_NAME"
cp "$ROOT_DIR/docs/distribution.ko.md" "$WORK/result/distribution.ko.md"
(
    cd "$WORK/result"
    shasum -a 256 "$BASE.dmg" "$BASE.zip" manifest.json distribution.ko.md > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
mkdir -p "$(dirname "$OUTPUT")"
mv "$WORK/result" "$OUTPUT"
echo "패키징/읽기 전용 이미지/ZIP/중첩 서명 검증 완료: $OUTPUT"
