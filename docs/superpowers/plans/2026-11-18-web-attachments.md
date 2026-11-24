# Web Attachments Implementation Plan

> Use the design and the interfaces below for implementation and review. Keep changes uncommitted on `feature/web-attachments`.

**Goal:** Add image paste, file drop, and file selection to Markdown notes, with a 50MB per-file limit.

**Architecture:** Stream file bytes to encrypted temporary storage. Bind staged files to the write journal and verify NAS bytes before reporting a successful save.

**Tech stack:** FastAPI, SQLite, HTTPX, React, and CodeMirror.

**Spec:** `docs/superpowers/specs/2026-11-17-web-attachments-design.md`.

## Constraints

- 50,000,000 bytes inclusive. Browser and server both enforce the boundary. The server counts actual bytes independently from length headers.
- Use the existing session, Origin/CSRF, writing lock, create receipt, and source envelope. Preserve existing note content and attachments.
- Preserve staged files for unresolved NAS mutations. Recheck before retrying a temporary upload. Do not automatically retry a NAS mutation.
- Use only the explicitly designated QA notes for NAS writes.

## Work items

- [x] Implement `Uploads` in `attachment_uploads.py` and pinning in `store.py`. Exercise durable staging, expiry, encrypted streaming, replays, quota, and uncertain pins.
- [x] Expose binary PUT and authenticated GET/DELETE/content endpoints in `main.py`. Test authentication, ownership, 50MB acceptance, streaming overflow and cleanup, and repeated create receipts.
- [x] Extend `NasClient.write_markdown(..., uploads=None)`. Pass a manifest entry per upload with metadata and a repeatable `chunks()` iterator. Test multipart data, manifest validation, preservation, and uncertain results with a controlled NAS fixture.
- [x] Connect CodeMirror events and the picker to the upload queue. Pass `draft_id` and `uploads: [{upload_id, sha256}]` in save snapshots. Test rejection before transfer, save gating, late response isolation, and text paste.
- [x] Verify file selection, image paste, drop, and oversized-file rejection in the browser fixture.
- [ ] Confirm multipart and readback against the designated NAS. Preflight returned `OTP_REQUIRED` before opening a note.
