"""Release versions are plain semver; development builds include the revision."""

from importlib.metadata import PackageNotFoundError, version as installed_version
from importlib.resources import files
from pathlib import Path
import subprocess

from .build_version import build_version, checked_build_version


def display_version() -> str:
    # Running from a checkout always reflects the current HEAD.
    repository = Path(__file__).resolve().parents[3]
    if (repository / ".git").exists():
        try:
            base = installed_version("synonote-cli")
            return build_version(base, repository)
        except (OSError, subprocess.CalledProcessError, PackageNotFoundError):
            pass

    # Wheel/sdist and onefile distributions embed their build-time revision.
    bundled = files("synonote_cli").joinpath("_version_build.txt").read_text().strip()
    return checked_build_version(bundled)
