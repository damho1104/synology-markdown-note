# synonote CLI 0.1.0

**English** | [한국어](cli-0.1.0.ko.md)

Tag: `cli-v0.1.0` (separate from macOS app release `1.2.2`)

The first release of a standalone Python 3.13-based CLI for uploading and downloading Synology Note Station Markdown. Packages are managed with `uv`, and PyInstaller `--onefile` executables are supported.

## Main Features

- List stacks, notebooks, and notes, with JSON output for LLM automation.
- Upload UTF-8 Markdown, download verified Markdown, and display diffs for same-title conflicts.
- Require explicit `--overwrite`, recheck the remote version, and reject overwriting HTML-only notes.
- Read the app's `SourceEnvelope` v1/v2/v3, with mock NAS and shared fixture validation.
- Provide operation journal inspection and recovery-check commands when the outcome of a NAS write is uncertain.
- Remembered login: macOS Keychain, Windows Credential Manager, and a permission-restricted local JSON file on Linux (`~/.config/synonote/credentials.json`, plaintext).

## Distribution Files

- `synonote-macos-arm64`: PyInstaller onefile executable for macOS Apple Silicon. If it lacks execute permission after download, set it with `chmod +x synonote-macos-arm64`.
- `synonote_cli-0.1.0-py3-none-any.whl`: wheel for Python 3.13 (dependencies must be installed to run).
- `synonote_cli-0.1.0.tar.gz`: Python source distribution package.
- `SHA256SUMS`: SHA-256 checklist for the attached distribution files.

## Validation and Limitations

- Completed onefile build, help execution, JSON error code checks with authentication unconfigured, and local code signature validation on macOS arm64.
- 61 Python tests passed; `uv lock --check` completed.
- Linux/Windows onefile binaries and real NAS round trips have not yet been validated, so those binaries are not attached. On those operating systems, use the `uv` installation and OS-specific onefile build instructions in `cli/README.md`.
- Some image and equation attachment operations are safely rejected. See `cli/README.md` for detailed limitations.
- The macOS executable has not received Apple Developer ID notarization. Passing Gatekeeper on another Mac is not guaranteed.
