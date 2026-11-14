"""Build a self-contained synonote binary with its Git revision embedded."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parent


def display_version() -> str:
    base = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]["version"]
    if (REPOSITORY / ".git").exists():
        commit = subprocess.check_output(["git", "rev-parse", "--short=7", "HEAD"], cwd=REPOSITORY, text=True).strip()
        result = f"{base}-{commit}"
    else:
        result = (ROOT / "src/synonote_cli/_version_build.txt").read_text().strip()
    if not re.fullmatch(rf"{re.escape(base)}-[0-9a-f]{{7,40}}", result):
        raise ValueError("Invalid bundled version")
    return result


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
