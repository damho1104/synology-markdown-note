"""Stage tested release binaries and generate platform-specific checksums."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli" / "src"))
from synonote_cli.build_version import release_version

PLATFORMS = ("macos-arm64", "ubuntu-22.04-amd64", "ubuntu-24.04-amd64",
             "linux-glibc2.28-amd64")


def stage(tag: str, platform: str, cli: Path, output: Path, app_package: Path | None = None) -> None:
    base = tomllib.loads((ROOT / "cli/pyproject.toml").read_text())["project"]["version"]
    version = release_version(tag, base)
    if platform not in PLATFORMS:
        raise ValueError("Unsupported release platform")
    result = subprocess.run([str(cli.resolve()), "version"], check=True, capture_output=True, text=True)
    if result.stdout.strip() != version:
        raise ValueError("Release CLI version must match the tag without a commit suffix")
    subprocess.run([str(cli.resolve()), "--help"], check=True, stdout=subprocess.DEVNULL)
    inputs = [(cli, f"synonote-cli-{tag}-{platform}")]
    if platform == "macos-arm64":
        if app_package is None:
            raise ValueError("macOS release requires an app package")
        for suffix in ("dmg", "zip"):
            name = f"SynologyMarkdownNote-{version}-arm64.{suffix}"
            inputs.append((app_package / name, name))
        inputs += [(app_package / "manifest.json", "manifest-macos-arm64.json"),
                   (app_package / "distribution.ko.md", "distribution.ko.md")]
    for source, _ in inputs:
        if not source.is_file() or source.stat().st_size == 0:
            raise ValueError(f"Missing or empty release input: {source.name}")
    if output.exists():
        raise ValueError("Release output directory already exists")
    output.mkdir(parents=True)
    checksums = []
    for source, name in inputs:
        target = output / name
        shutil.copy2(source, target)
        checksums.append(f"{hashlib.sha256(target.read_bytes()).hexdigest()}  {name}\n")
    (output / f"SHA256SUMS-{platform}").write_text("".join(checksums))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--app-package", type=Path)
    args = parser.parse_args()
    stage(args.tag, args.platform, args.cli, args.output, args.app_package)
