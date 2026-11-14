"""Release version for the macOS bundle and standalone CLI builds."""

import argparse
from pathlib import Path
import re
import sys
import tomllib


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cli" / "src"))
from synonote_cli.build_version import build_version, source_revision


def base_version() -> str:
    project = tomllib.loads((ROOT / "cli" / "pyproject.toml").read_text())
    value = project["project"]["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid release version: {value}")
    return value


def git_commit() -> str:
    return source_revision(ROOT)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", action="store_true")
    parser.add_argument("--hash", action="store_true")
    args = parser.parse_args()
    print(base_version() if args.base else git_commit() if args.hash else build_version(base_version(), ROOT))
