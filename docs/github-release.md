# Automated GitHub releases

**English** | [한국어](github-release.ko.md)

`.github/workflows/release.yml` runs on **self-hosted runners** registered with the GitHub repository. Version validation, Linux builds, and release publishing use the labels `[self-hosted, Linux, X64, docker-compose]`; macOS builds use `[self-hosted, macOS, ARM64]`. The Linux runner needs Docker, and the macOS runner needs compatible Swift development tools.

## Tags and versions

`develop` is the development and integration branch, and `main` is the branch used as the basis for official releases. The default branch is `main`. Maintainers integrate verified changes directly with `git merge --no-ff`. External contributors can submit pull requests as described in the [contributing guide](../CONTRIBUTING.md). Integrate feature → develop and develop → main directly with `git merge --no-ff`, and create version tags on `main`.

Only an optional `v` prefix is allowed before `X.Y.Z`, as in `v1.2.17` or `1.2.17`. Short commit suffixes such as `1.2.17-abcdef0` and prerelease suffixes are not allowed. The build stops if the tag version differs from `project.version` in `cli/pyproject.toml`.

1. Apply the shared version to `cli/pyproject.toml`, `web/backend/pyproject.toml`, and `web/frontend/package.json` together. Update lockfiles with `uv lock` in the CLI and web backend, and `npm install --package-lock-only` in the web frontend.
2. Commit the changes and push to `develop`.
3. Once CI passes, update local `main` to the latest remote state, integrate with `git merge --no-ff develop`, and push `main`.
4. Update local `main`, then create and push a version tag. The example below assumes source version `1.2.17`; do not recreate or move a tag that has already been published.

```sh
git switch main
git pull --ff-only origin main
git tag v1.2.17
git push origin v1.2.17
```

The displayed version of release apps and CLIs is `1.2.17`, and filenames also omit the short commit. Separate internal Git commit metadata in the app is retained for traceability. Regular source development builds continue to display versions such as `1.2.17-abcdef0`.

Tags point to commits, not branches. A tag on a commit shared by `main` and `develop` can appear on both branches. The release workflow fetches the latest `origin/main` and checks whether it contains the tagged commit, stopping before the build if the development commit has not yet been merged into `main`. The release workflow runs only on version tag pushes; branch pushes and manual runs are not allowed.

## Build artifacts

| Target | GitHub execution environment | Published files |
| --- | --- | --- |
| macOS arm64 | macOS ARM64 self-hosted runner | App DMG and ZIP, CLI, app manifest and installation guide, `SHA256SUMS-macos-arm64` |
| Ubuntu 22.04 amd64 | `ubuntu:22.04` container on the Linux X64 self-hosted runner | CLI, `SHA256SUMS-ubuntu-22.04-amd64` |
| Ubuntu 24.04 amd64 | `ubuntu:24.04` container on the Linux X64 self-hosted runner | CLI, `SHA256SUMS-ubuntu-24.04-amd64` |
| Linux x86_64 / glibc 2.28+ | `quay.io/pypa/manylinux_2_28_x86_64` container on the same Linux runner | Portable CLI, `SHA256SUMS-linux-glibc2.28-amd64` |

Example filenames are `SynologyMarkdownNote-1.2.17-arm64.dmg` and `synonote-cli-v1.2.17-ubuntu-22.04-amd64`. CLI filenames use the pushed tag exactly as supplied.

Each build environment runs CLI tests and verifies the single-file executable's `version` and `--help` commands. macOS also runs Swift tests and verifies nested code signing, DMG mounting, and ZIP extraction. Once all builds and checksum checks finish, files are uploaded to a Draft release and published. An already published release for the same tag is not overwritten; an interrupted Draft can be resumed by rerunning the workflow.

The release workflow has no `workflow_dispatch`. A version tag push is required to start testing, building, and publishing. Use the CI workflow for regular development validation.

## Web Docker images / GHCR

The release workflow also publishes web images. **Image building and publishing run on the `[self-hosted, Linux, X64, docker-compose]` runner.** This Linux host needs Docker and Python 3, and must be able to run QEMU/binfmt and a Buildx builder through Docker. Web tests based on Node 22 and Python 3.13 are prepared in an Ubuntu container on the same runner.

- `web-checks.yml`: All backend tests, frontend tests and builds, and validation that the app, CLI, web frontend, and web backend share the same version.
- `ci.yml`: Regular branches and PRs run only the above checks and do not publish images. As with the existing CI policy, PR tests are isolated in GitHub-hosted environments, while regular branch checks and release work use self-hosted runners.
- `release.yml`: Once the release tag/`main` validation above and the app and CLI checks all pass, the `web-image` job builds `linux/amd64` and `linux/arm64` images and publishes them to GHCR. It also checks that both platforms are present in the manifest.
- The image name is `ghcr.io/<repository-owner>/synology-md-note-web`, and tags are `latest` and the shared release version `X.Y.Z`. For example, for a `v1.2.18` release, set the app, CLI, and web versions to `1.2.18` and publish `:latest` and `:1.2.18`. Web settings also display `1.2.18`. A version mismatch fails validation before publishing.
- GHCR login uses `GITHUB_TOKEN` and the job's `packages: write` permission. No private registry address or separate registry password is needed.

After the first publication, check that the `synology-md-note-web` package is **Public** in GitHub Packages. If it is private, users cannot pull the image without authentication. If you fork and publish under another owner's account, also update the GHCR owner portion in Compose and `.env.example`.

User-facing download and run commands are in the [self-hosting installation guide](../web/SELF-HOSTING.md). Distinguish between having written the workflow files and actually running a tag successfully and publishing the image.

## Verifying the portable Linux executable

`script/build_linux_portable.sh` uses uv-managed CPython 3.13 with shared libraries in a glibc 2.28 build container. The image's bundled static CPython is not used because it lacks the `libpython.so` required by PyInstaller. The lockfile and all CLI tests are checked in a temporary virtual environment, and the result is published as `synonote-cli-<TAG>-linux-glibc2.28-amd64`. Existing Ubuntu-specific files are also retained.

The `linux-compatibility` job runs the same portable binary in clean containers for Debian 11, 12, and 13; Ubuntu 20.04, 22.04, and 24.04; AlmaLinux 8 and 9; Rocky Linux 8 and 9; Fedora 43; and openSUSE Leap 16.0. Python is not installed in the target containers. After verifying the checksum, `script/smoke_linux_binary.sh` checks the version, subcommand help, a Korean configuration path, logout, and SSL client initialization. The connection test checks error handling against an unused local port and does not send credentials to an actual NAS.

The `publish` job starts only after all distribution checks pass. Starting with the `v1.2.17` rebuild, this portable executable and its dedicated checksum are published alongside the existing macOS and Ubuntu artifacts. Image tags use fixed distribution versions, but their contents may change with security updates. Actual NAS operation, Linux ARM64, and Alpine/musl are outside the scope of this verification. See the [PyInstaller guide](https://pyinstaller.org/en/stable/usage.html#making-gnu-linux-apps-forward-compatible) and [manylinux guide](https://github.com/pypa/manylinux).

## macOS signing setup

The release-only certificate is stored in these Repository Secrets.

- `MACOS_SIGNING_P12_BASE64`: Base64 of a PKCS#12 file containing the certificate and private key.
- `MACOS_SIGNING_P12_PASSWORD`: The password for that PKCS#12 file.
- `MACOS_SIGNING_CERT_SHA1`: The pinned certificate's SHA-1 fingerprint (40 characters, without colons).

For initial setup, you can run the following in an environment with OpenSSL and an authenticated GitHub CLI.

```sh
python3 script/create_release_signing.py --repo OWNER/REPOSITORY
```

This script generates a new self-signed certificate, registers it in the Secrets above, and cleans up temporary private key files. If release Secrets already exist, it stops without replacing the certificate. The runner verifies the certificate fingerprint, signs using a temporary Keychain for that run, then removes that Keychain from the search list and deletes it. Other Keychains on the runner are retained. The signing certificate must remain the same across releases to maintain Keychain access compatibility.

This self-signing **is not Apple Developer ID signing or Apple notarization.** Installation on actual other Macs, NAS connections, and inherited Keychain access from previous versions require separate verification. Also see the [installation and distribution guide](distribution.md).

References: [GitHub container jobs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container), [GitHub self-hosted runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners), [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create).
