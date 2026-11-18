# Contributing

**English** | [한국어](CONTRIBUTING_KO.md)

Thank you for your interest in Synology Markdown Note. Before making changes, check existing issues and pull requests. For behavior changes, include reproduction steps and tests where possible.

## Branch workflow

- `develop`: The development and integration branch. Target this branch for feature and bug-fix pull requests by default.
- `main`: The default branch and the basis for stable releases. Maintainers merge verified changes from `develop` with `git merge --no-ff`.
- Create stable version tags on `main` and do not move published tags. The release workflow stops if the tagged commit is not included in `origin/main`.
- Releases run only when a version tag is pushed. Branch pushes and manual runs cannot start a release.

See the [GitHub release guide](docs/github-release.md) for the full procedure.

## Local verification

The macOS app and shared logic require Xcode and Swift tooling.

```sh
./script/test.sh
```

The CLI uses Python 3.13 and [uv](https://docs.astral.sh/uv/).

```sh
cd cli
uv sync --locked
uv run --locked pytest -q tests
```

Describe the purpose of your change, test results, and known limitations in your pull request. Run checks against an internal NAS in your own environment rather than using a public test account. Do not publish real notes, server URLs, credentials, or raw diagnostic data in issues, pull requests, or commits. Do not share signing certificates, Keychain data, or execution logs.

## Code and documentation

Follow the existing style. When a feature's behavior changes, update the README or related documentation. Do not hard-code personal paths or server addresses in scripts or workflows.

This project is not an official product made or supported by Synology.

## External pull request checks

Pull request code runs on GitHub-hosted Ubuntu and macOS runners, not the repository's self-hosted Linux or Mac runners. Pull request workflows do not use the uv cache or retain the checkout token in Git configuration. When making the repository public, configure Actions to require approval for all runs from external contributors and review workflow changes especially carefully. YAML alone does not enforce isolation of access to repository-level runners.

## Public documentation

All public documentation must be understandable and usable without a particular user’s environment. Do not present personal stack or notebook names, server addresses, accounts, absolute local paths, or personal tools as requirements. Use fictional values or placeholders in examples and state what readers must replace. Distinguish examples from actual option defaults, fixed identifiers, and product constraints. Keep official download and image addresses usable. Update the corresponding English and Korean documents together.
