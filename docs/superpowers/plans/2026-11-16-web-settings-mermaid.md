# Web settings and Mermaid correction

Goal: settings gear opens a real Mac-like preferences dialog; Mermaid text stays aligned and themes retain readable labels.

User direction: continue implementation matching the Mac app. Implement directly using existing React/CodeMirror/Mermaid, without another design approval round.

- [x] Reproduce screenshot diagram and collect SVG text alignment and label color evidence in Aside.
- [x] Add validated browser preferences and accessible modal for screen mode, editor size, line numbers/wrapping, Mermaid style and theme. Apply immediately and persist across reloads without changing drafts or making NAS writes.
- [x] Preserve only safe SVG presentation declarations from Mermaid stylesheet and inline styles. Keep resource restrictions, script removal, foreignObject removal, opaque iframe and CSP. Use matching rendering fonts and serialize Mermaid jobs so old renders cannot override newer settings.
- [x] Verify regression tests, frontend build, Aside desktop/mobile and light/dark settings flow, label geometry/color, system appearance and persistence.
- [x] Review final diff, publish a new immutable 0.4.1 multiarch image and verify manifests/runtime.

Review focus: rapid preference changes during asynchronous render; untrusted SVG CSS URLs/at-rules; draft preservation; modal keyboard/focus handling; system color changes while an explicit theme is selected.

Validation: frontend 46 tests passed; backend 223 tests passed; production frontend build and Compose validation passed. Aside on localhost:5173 at desktop 1440×1000 and mobile 390×844 verified settings modal, style/theme updates, all six node labels within shape bounds and centered within 0.4 CSS pixels, four edge labels with distinct foreground/background, line numbers/wrapping/font size, reload persistence and clean browser console. Keyboard/focus/backdrop/draft-preservation and live system appearance have automated coverage. Independent review found no P1/P2 issue; it additionally compared flowchart, sequence and gitGraph styling with original Mermaid output in Aside. No real NAS writes were performed.

Published: an internal test registry image (0.4.1), index sha256:a6649c5e91a1de97b43f7219dacca1f0caa38f947606a3eca3f41e04e4ef4b33. Both linux/amd64 and linux/arm64 images were pulled by platform manifest digest and passed installed-version 0.4.1, HTTP/HTTPS session/read, static assets, graph routing, Markdown contract, UID and private-mode smoke checks. Production NAS/container deployment was not changed.
