# Editing Existing Note Station Documents

**English** | [한국어](html-editing.ko.md)

Starting with 0.2.1 build 8, opening an existing HTML document displays a rich-text editor without converting it to Markdown. Changes to the body, title, tags, and attachments are first saved to local revision history and automatically sent to the NAS.

## Editing Features

- Paragraphs, headings, quotations, code, fonts, sizes, text and highlight colors, bold, italic, underline, strikethrough, superscript, and subscript.
- Alignment, indentation, bulleted and numbered lists, checklists, and adding or removing links.
- Creating tables, adding or deleting rows and columns, and deleting tables. Existing content in merged tables is preserved, and unsupported structural operations are not performed.
- File and image attachments, pasting images and dropping files, undo, and redo.

Simply opening or selecting a document preserves the original HTML bytes. Actual edits are saved as an HTML DOM while preserving existing styles, tables, and attachment references. The WebKit editor ignores stale changes arriving after the account or note has changed and defers refreshes during Korean input composition.

## Preserving Original Content and Attachments

Unsupported widgets and executable elements, such as audio, video, and iframes, are replaced with inactive placeholders that preserve the originals. The original HTML is restored when saving edits; editing the widgets themselves is not supported. Existing styles apply only within the editor, and user scripts and automatic remote requests are not executed.

NAS ref-only images and download URLs are displayed as validated local attachments. Export restores the original references so that editor markers and preview URLs do not enter the saved HTML. New attachments are replaced with NAS references during synchronization, without reserializing source content outside the affected tags. Attachments referenced by the body cannot be removed.

Notes whose Markdown source fingerprint has changed due to web edits also open in this editor to retain the latest HTML. To switch to Markdown, use the separate conversion button at the top. Conversion may introduce original-content preservation blocks, so switching is unnecessary if you want to continue editing the existing formatting.

Local save status and NAS synchronization status are displayed separately. During conflicts, both bodies can be compared; selecting either the server or local version preserves the other content in revision history or a copy.

## Validation Scope

Formatting, tables, attachments, checkboxes, Korean input composition, undo, and blocking external requests are tested in actual WebKit. Saving, attachments, conflicts, and source restoration are tested with a synthetic NAS and actual SQLite. This does not replicate every widget or tool in the official Note Station app; round-trip validation with a real NAS and another Mac is separate.
