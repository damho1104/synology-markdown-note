# Web/macOS alignment implementation record

**English** | [한국어](2026-11-16-web-macos-alignment.ko.md)

Goal: follow the existing macOS LibraryView/EditorView and published screenshot instead of a separate web design. This continues the already authorized web client implementation.

Reference: Sources/SynologyNote/Views/LibraryView.swift, EditorView.swift, Stores/EditorSession.swift, Sources/NoteCore/NoteListSort.swift, docs/images/markdown-split-preview.png, and the existing web client design.

- [x] Automatically choose HTTP/HTTPS cookie attributes from a validated browser origin; preserve cross-origin rejection and explicit legacy overrides. Remove the two variables from ordinary Compose configuration.
- [x] Use the Mac sidebar/list/editor proportions, nested stack disclosure, unstacked notebooks, tags and trash filters, system light/dark palettes, and inspector.
- [x] Match title/creation/modification sorting and direction, including modification-date fallback, with persistent preferences.
- [x] Source/split/read modes with CodeMirror Markdown, local Mermaid hand-drawn SVG, and KaTeX; sandboxed preview blocking note scripts, with only a nonce-protected internal-link bridge.
- [x] Decode the byte-compatible v1-v3 source contract, check body/source fingerprints, and preserve existing source bytes and opaque blocks.
- [x] Stage source, write body, publish verified final source with conflict checks and attachment preservation; retain uncertain write reservations without retries.
- [x] Mock HTTP tests for every lost-receipt phase and committed Mac/CLI fixtures; real-browser checks for navigation, sorting, diagrams and actual HTTP cookies.
- [ ] Real NAS roundtrip verification (requires the user's test environment; no arbitrary live NAS writes).

Additional completed work in 0.4.0:
- [x] Metadata and library routes with encrypted durable reservations, conflict checks, and exact readback: favorites, tags, trash/restore, note move, notebook create/rename/group, stack create/rename. No permanent deletion.
- [x] Graph/backlinks from verified actual links, duplicate document ID protection, internal link insertion/resolution and navigation.
- [x] Original HTML text patches by source offsets, preserving unknown attributes/attachments/opaque payloads; sanitized synchronous text input and readback tests.
- [x] Session rotation regression tests for repeated guards, failure responses, and concurrent frontend reads.

Remaining differences, not represented as completed: math PNG regeneration/upload, unrestricted original HTML formatting changes, attachment addition/removal, version-history management, and offline synchronization. Actual NAS writes and physical Synology Container Manager remain unverified.
