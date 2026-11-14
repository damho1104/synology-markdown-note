"""Release version for the macOS bundle and standalone CLI builds."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tomllib


ROOT = Path(__file__).resolve().parents[1]


def base_version() -> str:
    project = tomllib.loads((ROOT / "cli" / "pyproject.toml").read_text())
    value = project["project"]["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid release version: {value}")
    return value


def git_commit() -> str:
    supplied = os.environ.get("SYNOLOGY_NOTE_GIT_COMMIT")
    if supplied is not None:
        if not re.fullmatch(r"[0-9a-f]{7,40}", supplied):
            raise ValueError("Invalid SYNOLOGY_NOTE_GIT_COMMIT")
        return supplied
    return subprocess.check_output(
        ["git", "rev-parse", "--short=7", "HEAD"], cwd=ROOT, text=True
    ).strip()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", action="store_true")
    parser.add_argument("--hash", action="store_true")
    args = parser.parse_args()
    print(base_version() if args.base else git_commit() if args.hash else f"{base_version()}-{git_commit()}")
