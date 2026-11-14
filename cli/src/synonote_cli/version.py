"""Human-facing version of the CLI, including the source revision."""

from importlib.metadata import PackageNotFoundError, version as installed_version
from importlib.resources import files
from pathlib import Path
import re
import subprocess


def display_version() -> str:
    # Running from a checkout always reflects the current HEAD.
    repository = Path(__file__).resolve().parents[3]
    if (repository / ".git").exists():
        try:
            sha = subprocess.check_output(
                ["git", "rev-parse", "--short=7", "HEAD"], cwd=repository,
                stderr=subprocess.DEVNULL, text=True
            ).strip()
            base = installed_version("synonote-cli")
            if re.fullmatch(r"[0-9a-f]{7,40}", sha):
                return f"{base}-{sha}"
        except (OSError, subprocess.CalledProcessError, PackageNotFoundError):
            pass

    # Wheel/sdist and onefile distributions embed their build-time revision.
    bundled = files("synonote_cli").joinpath("_version_build.txt").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+-[0-9a-f]{7,40}", bundled):
        raise ValueError("Invalid bundled CLI version")
    return bundled
