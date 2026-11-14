"""Version rules shared by source, application, and CLI release builds."""

import os
from pathlib import Path
import re
import subprocess


BASE_PATTERN = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"


def release_version(tag: str, base: str) -> str:
    if not re.fullmatch(rf"v?{BASE_PATTERN}", tag):
        raise ValueError("Release tag must be X.Y.Z or vX.Y.Z, without a commit suffix")
    if tag.removeprefix("v") != base:
        raise ValueError(f"Release tag {tag!r} does not match project version {base!r}")
    return base


def source_revision(repository: Path) -> str:
    commit = os.environ.get("SYNOLOGY_NOTE_GIT_COMMIT")
    if commit is None:
        commit = subprocess.check_output(
            ["git", "rev-parse", "--short=7", "HEAD"], cwd=repository, text=True
        ).strip()
    if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
        raise ValueError("Invalid source revision")
    return commit


def checked_build_version(value: str, base: str | None = None) -> str:
    if not re.fullmatch(rf"{BASE_PATTERN}(?:-[0-9a-f]{{7,40}})?", value):
        raise ValueError(f"Invalid build version: {value!r}")
    if base is not None and value.split("-", 1)[0] != base:
        raise ValueError("Bundled version does not match project version")
    return value


def build_version(base: str, repository: Path, stamp: Path | None = None) -> str:
    if not re.fullmatch(BASE_PATTERN, base):
        raise ValueError(f"Invalid project version: {base!r}")
    tag = os.environ.get("SYNOLOGY_NOTE_RELEASE_TAG")
    if tag is not None:
        return release_version(tag, base)
    if (repository / ".git").exists():
        return f"{base}-{source_revision(repository)}"
    if stamp is None:
        return f"{base}-{source_revision(repository)}"
    return checked_build_version(stamp.read_text().strip(), base)
