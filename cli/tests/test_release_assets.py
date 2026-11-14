import hashlib
import importlib.util
from pathlib import Path
import tomllib

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_assets", ROOT / "script/release_assets.py")
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
BASE = tomllib.loads((ROOT / "cli/pyproject.toml").read_text())["project"]["version"]


def executable(tmp_path, version):
    binary = tmp_path / "synonote"
    binary.write_text(f"#!/bin/sh\nif [ \"$1\" = version ]; then echo '{version}'; fi\n")
    binary.chmod(0o755)
    return binary


def test_release_rejects_development_binary_before_staging(tmp_path):
    binary = executable(tmp_path, f"{BASE}-abcdef0")
    output = tmp_path / "release"
    with pytest.raises(ValueError, match="without a commit suffix"):
        assets.stage(f"v{BASE}", "ubuntu-22.04-amd64", binary, output)
    assert not output.exists()


@pytest.mark.parametrize("platform", ["ubuntu-24.04-amd64", "linux-glibc2.28-amd64"])
def test_release_asset_name_and_checksum_match_tag(tmp_path, platform):
    binary = executable(tmp_path, BASE)
    output = tmp_path / "release"
    assets.stage(f"v{BASE}", platform, binary, output)
    name = f"synonote-cli-v{BASE}-{platform}"
    assert (output / name).stat().st_mode & 0o111
    assert (output / f"SHA256SUMS-{platform}").read_text() == (
        f"{hashlib.sha256(binary.read_bytes()).hexdigest()}  {name}\n"
    )


def test_macos_cannot_stage_a_partial_cli_only_release(tmp_path):
    binary = executable(tmp_path, BASE)
    output = tmp_path / "release"
    with pytest.raises(ValueError, match="requires an app package"):
        assets.stage(f"v{BASE}", "macos-arm64", binary, output)
    assert not output.exists()
