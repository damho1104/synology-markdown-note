#!/usr/bin/env bash
# Run inside the PyPA manylinux_2_28_x86_64 image.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test "$(uname -m)" = x86_64
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.28'
: "${SYNOLOGY_NOTE_RELEASE_TAG:?Set the release version tag}"
platform=linux-glibc2.28-amd64
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
export UV_PROJECT_ENVIRONMENT="$build_dir/venv"
export UV_PYTHON_INSTALL_DIR="$build_dir/python"
export UV_PYTHON_PREFERENCE=only-managed
git config --global --add safe.directory "$root"
cd "$root/cli"
uv lock --check
# manylinux's bundled CPython is static; PyInstaller requires libpython.so.
# Install the shared-library build and verify it on the glibc 2.28 host.
uv python install 3.13
uv sync --locked --python 3.13
uv run --locked pytest -q tests
uv run --locked python build_onefile.py --out-dir "$build_dir/bin"
cd "$root"
uv run --project cli --locked python script/release_assets.py \
  --tag "$SYNOLOGY_NOTE_RELEASE_TAG" --platform "$platform" \
  --cli "$build_dir/bin/synonote" --output ".build/release-assets/$platform"
cd ".build/release-assets/$platform"
sha256sum --check "SHA256SUMS-$platform"
