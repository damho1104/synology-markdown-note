# synonote CLI

**English** | [한국어](README_KO.md)

A tool for **uploading** UTF-8 Markdown written by LLMs and users to a specified Synology Note Station stack/notebook, and **downloading** verified Markdown. It has no synchronization or automatic merging features. It shares the `SourceEnvelope` document format used by the macOS app.

This is an independent open-source project, not an official product made or supported by Synology. Its own source is provided under the [MIT license](LICENSE). External dependencies are subject to their respective licenses.

## Installation

Use a **single executable built with PyInstaller `--onefile`**. Python and uv are not required in the runtime environment.

### Ubuntu 22.04 and 24.04: installing a release executable (recommended)

**On Ubuntu 22.04 and 24.04 amd64, downloading and installing a release file is recommended instead of building it yourself.**

If files have been published on [GitHub Releases](https://github.com/damho1104/synology-markdown-note/releases), download the `synonote-cli-<VERSION_TAG>-<platform>` file and corresponding `SHA256SUMS-<platform>` file for Ubuntu 22.04/24.04 amd64 or macOS arm64. Verify the checksum in your download folder, then install the executable as `synonote`. If no release is available yet, use the source build instructions below.

| Environment | Executable | Checksum |
| --- | --- | --- |
| Ubuntu 22.04 amd64 | `synonote-cli-<VERSION_TAG>-ubuntu-22.04-amd64` | `SHA256SUMS-ubuntu-22.04-amd64` |
| Ubuntu 24.04 amd64 | `synonote-cli-<VERSION_TAG>-ubuntu-24.04-amd64` | `SHA256SUMS-ubuntu-24.04-amd64` |

On Ubuntu 24.04, replace `22.04` with `24.04` in the two filenames below.

```shell
# Ubuntu 22.04 amd64 example: replace <VERSION_TAG> with the version you downloaded.
sha256sum --check SHA256SUMS-ubuntu-22.04-amd64
mkdir -p "$HOME/.local/bin"
install -m 755 './synonote-cli-<VERSION_TAG>-ubuntu-22.04-amd64' "$HOME/.local/bin/synonote"
export PATH="$HOME/.local/bin:$PATH"
synonote version
```

Also add the `PATH` setting to your shell's configuration file.

On macOS arm64, verify the checksum with `shasum -a 256 -c SHA256SUMS-macos-arm64` and install the macOS file in the same way. Verify the checksum before renaming the executable.

### An x86_64 executable for multiple Linux distributions

Starting with the `v1.2.17` rebuild, `synonote-cli-<VERSION_TAG>-linux-glibc2.28-amd64` and `SHA256SUMS-linux-glibc2.28-amd64` are also provided. This portable executable requires no Python installation and targets **x86_64 environments with glibc 2.28 or later**. Existing Ubuntu-specific executables are also retained.

The release workflow **verifies the same portable executable in the following 12 container environments**, and stops publication if any check fails.

| Family | Test environments |
| --- | --- |
| Debian | 11, 12, 13 |
| Ubuntu | 20.04, 22.04, 24.04 |
| AlmaLinux | 8, 9 |
| Rocky Linux | 8, 9 |
| Fedora | 43 |
| openSUSE Leap | 16.0 |

Checks cover version and help output, Korean configuration paths, removal of file-based credentials, and SSL/HTTP client initialization. Actual NAS login, upload, and download require separate verification. Other glibc-based derivative distributions such as Linux Mint are not tested separately. Alpine (musl), Linux ARM64, and 32-bit systems are not included in the supported targets.

```sh
uname -m                 # Check for x86_64
getconf GNU_LIBC_VERSION # Check for glibc 2.28 or later
sha256sum --check SHA256SUMS-linux-glibc2.28-amd64
mkdir -p "$HOME/.local/bin"
install -m 755 './synonote-cli-<VERSION_TAG>-linux-glibc2.28-amd64' "$HOME/.local/bin/synonote"
```

### Building a onefile executable from source (optional)

For builds, use [uv](https://docs.astral.sh/uv/getting-started/installation/) to install the Python version pinned in `.python-version` and the dependencies in the lockfile. On the OS and architecture you intend to use, open the repository's `cli/` folder and run:

```shell
uv python install
uv sync --locked
uv run --locked python build_onefile.py
```

`build_onefile.py` passes **`--onefile`** to PyInstaller and bundles version information that includes the Git commit. The output is `dist/synonote` (macOS/Linux) or `dist/synonote.exe` (Windows). Cross-building for another OS is not supported.

On macOS/Linux, install from the `cli/` folder as follows.

```shell
mkdir -p "$HOME/.local/bin"
install -m 755 ./dist/synonote "$HOME/.local/bin/synonote"
export PATH="$HOME/.local/bin:$PATH"
synonote --help
synonote version
```

Also add the `PATH` setting to your shell's configuration file. You can also run `./dist/synonote` directly without installing it. On Windows, place `dist/synonote.exe` in a folder on PATH or run `./dist/synonote.exe --help` in PowerShell. The examples below assume the executable is on PATH.

The displayed version of official release apps and CLIs is a version without a commit hash, such as `1.2.17`. Regular source development builds use `x.y.z-<GIT_COMMIT_SHORT_HASH>` (for example, `1.2.17-7cb95a5`). The CLI's `version` command runs without NAS login; `--json` returns the fields `action: version`, `status: ok`, and `version`. Installation package version metadata uses `1.2.2` according to the packaging convention.

## Login and automatic login

NAS addresses, usernames, stack and notebook names, file paths, and IDs in the commands below are examples. Replace them with values from your own environment, including a current code for the OTP example. Product defaults and required names are identified separately.

```shell
synonote login --server https://nas.example:5001 --username alice --remember
synonote login --server https://nas.example:5001 --username alice --otp 123456 --remember
synonote auth status --json
synonote logout
```

To change only the URL used to connect to the same NAS, use the following command. It first verifies authentication at the new URL using the saved password and trusted device information, and updates local settings only on success. If authentication fails at the new address, existing settings are retained.

```shell
synonote auth set-server --server https://new-nas.example:5001
synonote auth status --json
```

Run this command on **the device** where the login information is saved. CLI settings on other devices are unchanged. The new address must be a valid HTTPS address. If a new OTP is required, log in again with `login --server ... --username ... --remember`.

Interactive input securely prompts for the password and requests additional input when an OTP is required. For automation, supply the password through **standard input** from a separate secure process and use `--password-stdin --non-interactive --json`. Do not put passwords in command-line arguments. Specify `--remember` to enable automatic login on subsequent CLI runs.

The server URL and username are saved in local `profile.json`. Passwords and DSM trusted device IDs are stored in **macOS Keychain** or **Windows Credential Manager**. On **Linux (including Ubuntu/headless environments)**, they are stored as a **plaintext JSON file** at `~/.config/synonote/credentials.json`. If `XDG_CONFIG_HOME` is set on Linux, `$XDG_CONFIG_HOME/synonote/credentials.json` is used. On Linux, the `synonote` directory is created with `0700` permissions, and `credentials.json` and `profile.json` with `0600`; the credentials file is replaced atomically. Anyone with access to the Linux account or file backups can therefore read the saved password. `logout` deletes saved credentials. Existing Linux keyring logins are not automatically migrated to the file, so run `login --remember` again. OTPs and session IDs are not saved. There is no option to bypass HTTPS certificate verification.

## Browsing stacks and notebooks

```shell
synonote stack list --json
synonote notebook list --stack 'Work' --json
synonote note list --stack 'Work' --notebook 'Journal' --json
synonote note info --id NOTE_ID --json
```

A stack is Note Station's `stack` attribute. Use `--notebook-id` if multiple notebooks have the same name.

## Daily summary knowledge index

Builds an index from monthly notebooks named `YYYY-MM` in the stack specified by `--stack`. You can choose any stack name. Original notes are not modified. This feature currently targets daily summary notes organized into monthly notebooks; notebooks with other names are not read. Project classification uses `by_project` metadata, while topic classification uses technical terms and regular expressions in the body. It does not call an LLM or classify notes by LLM provider.

`--index-notebook` names the notebook for hub notes. Create it in the selected stack before running the command. If omitted, the option defaults to `llm-index`. The examples below use a stack named `Work` and a notebook named `Knowledge Index`. Replace both names with your own.

- The notebook specified by `--index-notebook`: Stores only the four hub notes below
- `by-project`: Stores detailed project indexes
- `by-topic`: Stores detailed topic indexes

- `00-전체 인덱스`: Lists all original notes by month and date
- `01-프로젝트 인덱스`: Uses the originals' `by_project` metadata to create project-specific records and connections across multiple projects. By default, detailed pages are created for projects recorded on at least 3 days
- `02-주제 인덱스`: Technical topics based on terms and regular expressions found in the body. Detailed topic pages show excerpts that explain the classification
- `03-연관 지식`: Up to 70 candidate pairs of related dates, scored using shared projects, topics, and rare keywords. This is not semantic similarity based on LLM embeddings; check the originals to confirm actual relationships

```shell
# First review the full result. --dry-run is the default.
synonote index build --stack 'Work' --index-notebook 'Knowledge Index' --dry-run --json
# After review, create missing detail notebooks and move/publish existing managed notes
synonote index build --stack 'Work' --index-notebook 'Knowledge Index' --apply --json
# On subsequent runs, the same command updates only changed managed items.
```

Use `--project-min-days 3` to adjust the threshold for creating detailed project notes (minimum 2). Prepare the hub notebook specified by `--index-notebook` first. If the detail notebooks `by-project` and `by-topic` do not exist, `--apply` creates them and places them in the same stack. Detailed project and topic notes already published in the hub notebook are **moved directly on the remote server while verifying note IDs, HTML, and attachments**. `--dry-run` shows `placement`, `move`, `move_update`, and `notebooks_to_create` without modifying anything.

The CLI checks title collisions across the entire NAS, resolution of original-note links, and existing management markers (`<!-- synonote-index:v1 -->`). User-written notes are not overwritten even when their titles match. Unnecessary writes are skipped when existing index contents are unchanged. Each index link uses the `note title.md` format and assumes internal link support in the macOS app.

Changes to multiple notebooks/notes are not a single NAS transaction. The CLI persistently records movement and notebook creation/placement intents in the `operations` directory. Even if a move result is lost, the next run cleans up the journal if the same ID, HTML, and attachments are verified in the target notebook. If the result cannot be proven, the CLI returns `WRITE_UNCERTAIN` and `operation_id` and **does not automatically resend that change**. In this case, check the NAS and journal. The `operation_id` for an index body upload can be queried separately using the `operation status` command below. Index pages that have already been created are not automatically deleted.

## Uploading, comparing, and overwriting

```shell
synonote upload ./report.md --stack 'Work' --notebook 'Journal' --json
synonote upload ./report.md --notebook-id NOTEBOOK_ID --diff --json
synonote upload ./report.md --notebook-id NOTEBOOK_ID --overwrite --json --non-interactive
synonote upload ./report.md --notebook-id NOTEBOOK_ID --note-id NOTE_ID --overwrite --json
```

The default title is the `.md` filename without its extension; you can specify a title with `--title`. If a note with the same title exists, the default behavior returns a unified diff between the NAS and local versions, then **stops without writing**. `--diff` only compares; if the note does not exist, the result is `would_create`. `--overwrite` is allowed only when the NAS source is verified Markdown and the title, notebook, and version match. HTML-only notes, notes with unverified source, locked notes, and multiple candidates with duplicate titles are rejected.

## Downloading

```shell
synonote download --id NOTE_ID --output ./report.md --json
synonote download --id NOTE_ID --output ./report.md --force-local --json
```

Preserves the UTF-8 bytes of verified Markdown (including CRLF and the absence of a trailing newline). Existing files are replaced only with `--force-local`. If the source contains preserved blocks, a `.md.preserved.json` file is also exported. Forcing a download of a document that no longer has preserved blocks also removes an old sidecar. If saving multiple files fails, existing files are restored.

## Checking status after an interrupted write

If a network interruption or similar issue returns `WRITE_UNCERTAIN` and `operation_id`, **do not immediately rerun the upload**; perform a read-only check.

```shell
synonote operation status --id OPERATION_UUID --json
synonote operation recover --id OPERATION_UUID --json
```

`confirmed` means the source, body, title, and attachment cleanup have been verified and the local journal has been closed. If the status is `uncertain`, inspect the phase (`phase`) and candidate note IDs manually. `recover` also does not automatically resend or delete anything. The local `synonote/operations/` journal may include Markdown source, so take care when sharing or backing it up.

## JSON and exit codes

`--json` produces single-line JSON. It includes `schema_version: 1`, `action`, and `status`, and returns `error.code` on errors. Diff output may contain NAS document bodies.

| Code | Meaning |
| ---: | --- |
| 0 | Success, identical, or comparison with no differences |
| 2 | Argument/local file/output destination error or absence |
| 3 | Title collision, ambiguous candidates, or differing comparison result |
| 4 | Unverifiable or non-Markdown document |
| 5 | Authentication, OTP, or secure storage error |
| 6 | Remote change/version conflict |
| 7 | Uncertain NAS write outcome |
| 8 | Network/NAS API error |
| 9 | Currently unsupported Markdown feature |

## Support and limitations

**Currently supported:** Single UTF-8 `.md` files, standard CommonMark/GFM formatting (the tested subset), reading Swift `SourceEnvelope` v1/v2/v3, downloading verified source, same-title diffs, version checks, refusal to overwrite HTML-only documents, preservation of user attachments, and a NAS write verification journal. `:::synology-block ... :::` preserved blocks can be uploaded and downloaded together with their `.md.preserved.json` sidecars. When overwriting, changes are blocked if remote and local blocks differ.

**Not yet supported for safety:** Uploading images/attachment resources with relative paths, exporting or overwriting notes containing referenced attachments or formulas, uploading preserved blocks with attachment references, and rendering TeX formulas as PNG. Unsupported input is rejected with `UNSUPPORTED_MARKDOWN_FEATURE`. Mismatches between preserved block tokens and the sidecar are rejected with `INVALID_SOURCE`.

Golden fixtures generated by Swift code and mock NAS tests have been completed. Further verification is needed for bidirectional app ↔ CLI round trips on an actual NAS, 2FA, Keychain, official Note Station, and operation in actual Windows/Linux environments. This is not presented as full feature parity with the app.

## GitHub distribution

The official source is maintained in the [GitHub repository](https://github.com/damho1104/synology-markdown-note). Python CLI and Swift tests run for changes to `develop` and `main` and for Pull Requests. Pushing a version tag such as `v1.2.17` or `1.2.17` on a commit included in `main` automatically publishes the macOS arm64 and Ubuntu 22.04/24.04 amd64 CLIs, the portable Linux x86_64/glibc 2.28+ CLI, and checksums to [GitHub Releases](https://github.com/damho1104/synology-markdown-note/releases). Tags must match the project version and must not include a short commit suffix. Release executables also display a version without a hash, such as `1.2.17`. See the [GitHub release guide](../docs/github-release.md) for configuration and usage.

The CLI can be built as a single executable using PyInstaller on macOS and Linux. Executables and checksums intended for official releases must be verified separately on the corresponding OS.

## Development and testing

Build and test tools (pytest and PyInstaller) are included in the default `dev` dependency group. Change dependencies with `uv add <package-name>` and development dependencies with `uv add --dev <package-name>`, and commit `pyproject.toml` and `uv.lock` together. `--locked` detects lockfile mismatches.

From `cli/`:

```shell
uv sync --locked
uv run --locked pytest -q tests
```

Run Swift contract fixture/app tests from the repository root.

```shell
swift run CLIContractFixtures
swift test
```

The full Swift test suite requires Xcode to be installed and its license agreement accepted.
