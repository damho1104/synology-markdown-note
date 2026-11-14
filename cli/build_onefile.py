"""Build a self-contained synonote binary with its Git revision embedded."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parent
sys.path.insert(0, str(ROOT / "src"))
from synonote_cli.build_version import build_version


def display_version() -> str:
    base = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]["version"]
    return build_version(base, REPOSITORY, ROOT / "src/synonote_cli/_version_build.txt")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=ROOT / "dist")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="synonote-build-") as directory:
        stamp = Path(directory) / "_version_build.txt"
        stamp.write_text(display_version() + "\n")
        command = [sys.executable, "-m", "PyInstaller", "--onefile", "--clean", "--noconfirm",
                   "--name", "synonote", "--paths", "src", "--collect-submodules", "keyring.backends",
                   "--distpath", str(options.out_dir.resolve()), "--workpath", str(Path(directory) / "build"),
                   "--specpath", str(Path(directory) / "spec"),
                   "--add-data", f"{stamp}:synonote_cli", "entrypoint.py"]
        subprocess.run(command, cwd=ROOT, check=True)
