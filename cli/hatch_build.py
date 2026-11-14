"""Embed the release revision in wheels and source distributions."""

from pathlib import Path
import sys
import tempfile
import tomllib

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        root = Path(self.root)
        base = tomllib.loads((root / "pyproject.toml").read_text())["project"]["version"]
        repository = root.parent
        sys.path.insert(0, str(root / "src"))
        from synonote_cli.build_version import build_version
        display = build_version(base, repository, root / "src/synonote_cli/_version_build.txt")
        self._temp_dir = tempfile.TemporaryDirectory(prefix="synonote-version-")
        stamp = Path(self._temp_dir.name) / "_version_build.txt"
        stamp.write_text(display + "\n")
        destination = "src/synonote_cli/_version_build.txt" if self.target_name == "sdist" else "synonote_cli/_version_build.txt"
        build_data["force_include"][str(stamp)] = destination

    def finalize(self, version, build_data, artifact_path):
        self._temp_dir.cleanup()
