"""Embed the release revision in wheels and source distributions."""

from pathlib import Path
import re
import subprocess
import tempfile
import tomllib

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        root = Path(self.root)
        base = tomllib.loads((root / "pyproject.toml").read_text())["project"]["version"]
        repository = root.parent
        if (repository / ".git").exists():
            commit = subprocess.check_output(
                ["git", "rev-parse", "--short=7", "HEAD"], cwd=repository, text=True
            ).strip()
            display = f"{base}-{commit}"
        else:
            display = (root / "src/synonote_cli/_version_build.txt").read_text().strip()
        if not re.fullmatch(rf"{re.escape(base)}-[0-9a-f]{{7,40}}", display):
            raise ValueError(f"Invalid CLI release revision: {display}")
        self._temp_dir = tempfile.TemporaryDirectory(prefix="synonote-version-")
        stamp = Path(self._temp_dir.name) / "_version_build.txt"
        stamp.write_text(display + "\n")
        destination = "src/synonote_cli/_version_build.txt" if self.target_name == "sdist" else "synonote_cli/_version_build.txt"
        build_data["force_include"][str(stamp)] = destination

    def finalize(self, version, build_data, artifact_path):
        self._temp_dir.cleanup()
