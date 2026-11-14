#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?usage: sign_app.sh target [identifier]}"
SIGNING_IDENTITY="$(python3 "$SCRIPT_DIR/local_signing_identity.py")"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "임시 서명은 재빌드 시 자동 로그인 권한을 잃습니다. 고정된 서명 인증서를 사용하세요." >&2
    exit 1
fi
if [[ -n "${SYNOLOGY_NOTE_RCODESIGN:-}" ]]; then
    : "${SYNOLOGY_NOTE_SIGNING_P12_FILE:?Missing signing P12 file}"
    : "${SYNOLOGY_NOTE_SIGNING_P12_PASSWORD_FILE:?Missing P12 password file}"
    SIGNING_ARGS=(sign --p12-file "$SYNOLOGY_NOTE_SIGNING_P12_FILE"
        --p12-password-file "$SYNOLOGY_NOTE_SIGNING_P12_PASSWORD_FILE" --timestamp-url none)
    if [[ -n "${2:-}" ]]; then
        SIGNING_ARGS+=(--binary-identifier "$2")
    elif [[ -d "$TARGET" && -f "$TARGET/Contents/Helpers/SynologyCredentialHelper" ]]; then
        # The already-signed helper must retain its exact bytes and identity.
        SIGNING_ARGS+=(--exclude Contents/Helpers/SynologyCredentialHelper)
    fi
    "$SYNOLOGY_NOTE_RCODESIGN" "${SIGNING_ARGS[@]}" "$TARGET"
else
    SIGNING_ARGS=(--force --sign "$SIGNING_IDENTITY")
    if [[ -n "${SYNOLOGY_NOTE_SIGNING_KEYCHAIN:-}" ]]; then
        SIGNING_ARGS+=(--keychain "$SYNOLOGY_NOTE_SIGNING_KEYCHAIN")
    fi
    if [[ -n "${2:-}" ]]; then
        /usr/bin/codesign "${SIGNING_ARGS[@]}" --timestamp=none --identifier "$2" "$TARGET"
    else
        /usr/bin/codesign "${SIGNING_ARGS[@]}" --timestamp=none "$TARGET"
    fi
fi
/usr/bin/codesign --verify --strict "-R=certificate leaf = H\"$SIGNING_IDENTITY\"" "$TARGET"
