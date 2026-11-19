# Synology Markdown Note installation and distribution

**English** | [한국어](distribution.ko.md)

## Supported environments

The macOS app targets **Apple Silicon (arm64), macOS 14 or later**. Note Station must be installed on the Synology NAS, and connections to the NAS server use HTTPS. The CLI can be built separately from source or run using a verified release executable.

## Installing a release

1. Check whether installation files are available on [GitHub Releases](https://github.com/damho1104/synology-markdown-note/releases). **If there are no release files, no binaries have been distributed.**
2. If a macOS DMG and checksum are available, verify the source and SHA-256, then open the DMG and copy the app to the `Applications` folder.
3. Launch the app and enter your NAS URL and account details in Settings.

An app signed with a development certificate **does not have Apple Developer ID signing or Apple notarization.** This does not mean that distribution trust is automatically verified or that it will pass Gatekeeper. If the OS blocks execution, thoroughly verify the source, then follow the instructions in macOS **System Settings → Privacy & Security**. Do not disable security settings globally or run unverified files.

Intel Macs, installation and Keychain compatibility on other Macs, and operation with an actual NAS require separate verification. For the signing and Keychain setup in the current development build environment, see the [development build guide](development-signing.md).

## Building from source

Install Swift development tools (Xcode or Command Line Tools), then run the following from the repository root.

```sh
swift build
./script/test.sh
```

`./script/build_and_run.sh --build` creates a macOS app bundle, but requires a signed Credential Helper and development signing certificate setup. This script is not a tool for producing a notarized distribution.

For the CLI, install [uv](https://docs.astral.sh/uv/getting-started/installation/), then build as follows.

```sh
cd cli
uv python install
uv sync --locked
uv run --locked pytest -q tests
uv run --locked python build_onefile.py
```

The resulting executable is `cli/dist/synonote`, and must be built on the same OS and architecture as the runtime environment. See the [CLI documentation](../cli/README.md) for usage.

## Scope of release verification

Passing source tests does not guarantee code signing, notarization, or execution on other devices. When installation files are published to GitHub Releases in the future, each file's checksum, signing status, installation on target devices, and NAS operation must be verified separately.
