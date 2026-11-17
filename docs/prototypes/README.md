# Markdown macOS App UI/UX Concepts

**English** | [한국어](README_KO.md)

Created: 2026-10-10 (Asia/Seoul)
Tool: built-in Image Gen. These are review images, not an implemented app or screenshots of a running app.
Reference: `../superpowers/specs/2026-10-10-markdown-macos-design.md`.

Numbered in the order they appeared in the chat.

| Number | File | Screen layout |
| --- | --- | --- |
| 1 | [01-native-library-v1.png](01-native-library-v1.png) | Default screen showing notebooks, the note list, and Markdown source together |
| 2 | [02-parallel-writing-v1.png](02-parallel-writing-v1.png) | Split screen showing source and rendered output side by side |
| 3 | [03-focused-writing-v1.png](03-focused-writing-v1.png) | Dark-mode editing screen with the lists collapsed and a document information inspector |

## Shared Prompt Direction

A single screen at a 1440×1024 aspect ratio that looks like a real macOS app. Korean UI, a system font and a monospaced font for source, lightweight lists and dividers, readable text sizes, and no excessive cards or decoration. A new Markdown client that keeps the Note Station server. Use fictional project records instead of the user's actual notes. Reference date: 2026-10-10. Source/split/read switching, note navigation, and distinct local-save and NAS-update states.

Prompt direction for each concept:

1. Native Library: bright macOS three-column lists, blue selection, a spacious source editor, and a closed inspector. Locally saved and updated on NAS states at the bottom.
2. Parallel Writing: narrow navigation area, teal selection, source and preview of the same document, checklists and tables. Locally saved and updated on NAS states at the bottom.
3. Focused Writing: graphite dark mode with restrained purple accents, a button to reopen the note list, a spacious editor, and an inspector for document information, table of contents, and attachments. A state indicating that local saving is complete even offline and the app is waiting for the NAS connection.

## Review Scope

The images were reviewed for information hierarchy, spacing, Korean readability, selection states, view modes, and the distinction between save states. Click behavior, actual keyboard navigation, VoiceOver, source/preview content consistency, and window resizing require separate verification after implementation. Syntax highlighting and checkbox representations in the generated images are conceptual and do not guarantee the exact behavior of source editing.
