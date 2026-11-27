#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Synology Markdown Note"
EXECUTABLE_NAME="SynologyNote"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${SYNOLOGY_NOTE_APP_BUNDLE:-$ROOT_DIR/dist/$APP_NAME.app}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$EXECUTABLE_NAME"

case "$MODE" in run|--verify|--debug|--logs|--telemetry|--build) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
cd "$ROOT_DIR"
APP_VERSION="$(python3 "$ROOT_DIR/script/version_info.py" --base)"
APP_COMMIT="$(python3 "$ROOT_DIR/script/version_info.py" --hash)"
DISPLAY_VERSION="$(python3 "$ROOT_DIR/script/version_info.py")"
# Build and verification can run beside the user's current app. Interactive modes
# still request a normal quit so pending editor changes are flushed first.
if [[ "$MODE" != "--build" && "$MODE" != "--verify" ]] && pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
    pkill -TERM -x "$EXECUTABLE_NAME"
    for attempt in {1..20}; do
        if ! pgrep -x "$EXECUTABLE_NAME" >/dev/null; then break; fi
        sleep 0.25
    done
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then echo "앱에서 저장 오류를 확인하고 종료해 주세요." >&2; exit 1; fi
fi
BUILD_OPTIONS=(--configuration "${SYNOLOGY_NOTE_CONFIGURATION:-debug}")
if [[ -n "${SYNOLOGY_NOTE_SCRATCH_PATH:-}" ]]; then
    BUILD_OPTIONS+=(--scratch-path "$SYNOLOGY_NOTE_SCRATCH_PATH" --skip-update --disable-automatic-resolution)
fi
./script/swift.sh build "${BUILD_OPTIONS[@]}" --product "$EXECUTABLE_NAME"
BUILD_BINARY="$(./script/swift.sh build "${BUILD_OPTIONS[@]}" --show-bin-path)/$EXECUTABLE_NAME"
BUILD_DIR="$(dirname "$BUILD_BINARY")"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
for bundle in SynologyNote_SynologyNote.bundle SynologyNote_NoteCore.bundle; do
    rm -rf "$APP_BUNDLE/$bundle" "$APP_CONTENTS/Resources/$bundle"
    cp -R "$BUILD_DIR/$bundle" "$APP_CONTENTS/Resources/$bundle"
done
chmod +x "$APP_BINARY"
# The cache-aware builder preserves the signed helper for unchanged sources,
# while still honoring deliberate helper/CredentialStore security fixes.
if [[ "${SYNOLOGY_NOTE_REQUIRE_CACHED_HELPER:-0}" == 1 && ! -f "$ROOT_DIR/.build/credential-helper/SynologyCredentialHelper" ]]; then
    echo "기존 credential helper가 없습니다. 별도 개발 설정 후 다시 패키징하세요." >&2
    exit 1
fi
HELPER_BINARY="$(python3 ./script/build_credential_helper.py)"
HELPER_IDENTITY="$(python3 ./script/local_signing_identity.py)"
/usr/bin/codesign --verify --strict \
    "-R=identifier \"com.damho.SynologyMarkdown.CredentialHelper\" and certificate leaf = H\"$HELPER_IDENTITY\"" "$HELPER_BINARY"
mkdir -p "$APP_CONTENTS/Helpers"
cp "$HELPER_BINARY" "$APP_CONTENTS/Helpers/SynologyCredentialHelper"
cmp -s "$HELPER_BINARY" "$APP_CONTENTS/Helpers/SynologyCredentialHelper"
cp "$ROOT_DIR/Sources/SynologyNote/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SynologyNote</string>
<key>CFBundleIdentifier</key><string>com.damho.SynologyMarkdown</string>
<key>CFBundleName</key><string>Synology Markdown Note</string>
<key>CFBundleDisplayName</key><string>Synology Markdown Note</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>30</string>
<key>SynologyDisplayVersion</key><string>$DISPLAY_VERSION</string>
<key>SynologyGitCommit</key><string>$APP_COMMIT</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
bash ./script/sign_app.sh "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --deep "$APP_BUNDLE"
cmp -s "$HELPER_BINARY" "$APP_CONTENTS/Helpers/SynologyCredentialHelper"
case "$MODE" in
    --build) echo "$APP_BUNDLE" ;;
    --debug) lldb -- "$APP_BINARY" ;;
    --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SynologyNote"' ;;
    --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.damho.SynologyMarkdown"' ;;
    --verify)
        VERIFY_DIR="$(mktemp -d)"
        VERIFY_LOG="$(mktemp)"
        SYNOLOGY_NOTE_DATA_DIR="$VERIFY_DIR" "$APP_BINARY" >"$VERIFY_LOG" 2>&1 &
        VERIFY_PID=$!
        sleep 2
        if ! kill -0 "$VERIFY_PID" 2>/dev/null; then
            cat "$VERIFY_LOG" >&2
            rm -rf "$VERIFY_DIR" "$VERIFY_LOG"
            echo "검증용 앱이 시작 직후 종료되었습니다." >&2
            exit 1
        fi
        kill -TERM "$VERIFY_PID"
        for attempt in {1..20}; do
            if ! kill -0 "$VERIFY_PID" 2>/dev/null; then break; fi
            VERIFY_STATE="$(ps -p "$VERIFY_PID" -o state= 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ "$VERIFY_STATE" == Z* ]]; then break; fi
            sleep 0.25
        done
        VERIFY_STATE="$(ps -p "$VERIFY_PID" -o state= 2>/dev/null | tr -d '[:space:]' || true)"
        if kill -0 "$VERIFY_PID" 2>/dev/null && [[ "$VERIFY_STATE" != Z* ]]; then
            rm -rf "$VERIFY_DIR" "$VERIFY_LOG"
            echo "검증용 앱이 정상 종료되지 않았습니다." >&2
            exit 1
        fi
        wait "$VERIFY_PID" 2>/dev/null || true
        rm -rf "$VERIFY_DIR" "$VERIFY_LOG"
        echo "앱 실행 확인: $APP_BUNDLE"
        ;;
    run) open -n "$APP_BUNDLE" ;;
esac
