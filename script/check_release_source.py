"""Validate the branch policy before building release artifacts."""

import argparse
from pathlib import Path
import subprocess


def validate(repository: Path, event: str, ref_type: str, ref_name: str) -> None:
    if event != "push" or ref_type != "tag":
        raise ValueError("Publishing requires a version tag pushed from main")
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", "HEAD", "refs/remotes/origin/main"],
        cwd=repository, check=False,
    )
    if result.returncode == 1:
        raise ValueError("Release tag commit is not included in origin/main; merge develop into main first")
    if result.returncode != 0:
        raise RuntimeError("Unable to verify origin/main; fetch main before validating the release tag")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True)
    parser.add_argument("--ref-type", required=True)
    parser.add_argument("--ref-name", required=True)
    args = parser.parse_args()
    validate(Path(__file__).resolve().parents[1], args.event, args.ref_type, args.ref_name)
