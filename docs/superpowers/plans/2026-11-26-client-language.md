# Client Language Implementation Plan

**Goal** — Provide Korean and English in the web and macOS clients and English in the CLI.

**Spec** — [Client language design](../specs/2026-11-26-client-language-design.md)

- [x] Web deployment. Test that omitted settings return `auto` and configured settings return `en` or `ko` to anonymous clients. Expose `GET /api/public-config` returning `{"default_language":"auto"}` (or the configured mode) with no-store. Wire Compose and the example environment file.
- [x] Web UI. Test language selection for ordered browser preferences, unsupported languages and fixed overrides. Bootstrap the language before rendering. Localize interface strings, accessibility and feedback. Run frontend tests, build and verify rendered modes.
- [x] macOS. Use SwiftPM localization resources and macOS language resolution. Add a Settings selector for system, English and Korean, apply its saved choice on relaunch and test its precedence over the OS preference. Cover UI and app messages with English and Korean resources, and verify that the packaged app includes them. Run Swift tests and exercise the app in both languages.
- [x] CLI. Test a deterministic English error rendered in text and JSON under different locale environments. Translate command help and application messages. Run CLI tests and verify existing exit codes and response structure.
- [x] Add a bottom-right NAS status indicator to web and macOS. Web uses the outcome of its existing authenticated list loads and shows the disconnected state after logout. macOS uses the existing connection state. Show green for a confirmed connection and red for failure or disconnection, with an accessible localized label.
- [x] Verify the combined diff and record packaging and runtime coverage in the local handover.
