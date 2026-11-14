#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVELOPER_ROOT="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$DEVELOPER_ROOT" == *.app ]]; then
    DEVELOPER_ROOT="$DEVELOPER_ROOT/Contents/Developer"
fi

# Command Line Tools and full Xcode store Swift Testing in different places.
# Do not mix a CLT Testing.framework with Xcode's Swift compiler.
TEST_FRAMEWORKS=""
for candidate in \
    "$DEVELOPER_ROOT/Library/Developer/Frameworks" \
    "$DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
    if [[ -d "$candidate/Testing.framework" ]]; then
        TEST_FRAMEWORKS="$candidate"
        break
    fi
done

if [[ -n "$TEST_FRAMEWORKS" ]]; then
    # Importing Foundation alongside Testing loads the _Testing_Foundation
    # cross-import overlay, which may be missing from incomplete CLT installs.
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/synonote-testing-XXXXXXXX")"
    trap 'rm -rf "$probe_dir"' EXIT
    printf 'import Foundation\nimport Testing\n' > "$probe_dir/TestingImport.swift"
    if ! swiftc -typecheck -F "$TEST_FRAMEWORKS" "$probe_dir/TestingImport.swift"; then
        echo "Swift Testing is incomplete or incompatible with the selected compiler ($DEVELOPER_ROOT)." >&2
        echo "Install matching Command Line Tools or Xcode and verify Testing and _Testing_Foundation frameworks." >&2
        exit 1
    fi
    # CLT's Testing.framework loads lib_TestingInterop.dylib from a sibling
    # Developer/usr/lib directory. SwiftPM does not add that runpath itself.
    # The extra runpath is harmless for Xcode installations which bundle it
    # elsewhere, and avoids copying or modifying Apple-supplied libraries.
    TEST_INTEROP_LIB="$DEVELOPER_ROOT/Library/Developer/usr/lib"
    swift_test_args=(-Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS")
    if [[ -f "$TEST_INTEROP_LIB/lib_TestingInterop.dylib" ]]; then
        swift_test_args+=(-Xlinker -rpath -Xlinker "$TEST_INTEROP_LIB")
    fi
    ./script/swift.sh test --disable-xctest --enable-swift-testing \
        "${swift_test_args[@]}" "$@"
else
    ./script/swift.sh test --disable-xctest --enable-swift-testing "$@"
fi
