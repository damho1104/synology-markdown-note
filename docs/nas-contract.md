# Note Station HTTP, Storage, and Synchronization Contract

**English** | [한국어](nas-contract.ko.md)

Updated: 2026-11-07 (Asia/Seoul). Scope: the current code for 1.2.12-<GIT_COMMIT_SHORT_HASH>, build 23.

The initial HTTP adapter enabled reads only, but the current app supports automatic note and attachment uploads and notebook and trash management. This document describes current behavior and distinguishes historical NAS diagnostic results from the local tests performed for this update.

## Evidence and Validation Scope

- Implementation: `NoteStationClient`, `NoteStationSyncTransport`, `SyncCoordinator`, `NoteRepository`, `SourceEnvelope`, and the app's `Services/`.
- API investigation: the call structure of the official client 3.0.0-883 was used as a reference. The official app's entire code was not replicated.
- 2026-10-16: `./script/test.sh`, 175 tests / 20 suites passed. APIs are tested with synthetic responses, and previews are also tested in actual WebKit.
- Historical NAS diagnostics confirmed editing dedicated notes, rejecting version conflicts, byte-for-byte round trips of images and Markdown source, storing and reusing device tokens, and automatic login after relaunch. Actual NAS connections and writes were not rerun for this update.
- Full round trips after editing in the official app, simultaneous editing on multiple Macs, installation on another Mac, and compatibility with every DSM version have not been validated.
- 2026-10-17: Stack functionality was tested against official client 3.0.0-883 code and synthetic NAS requests/responses. Creating, modifying, and deleting stacks on a real NAS and round trips with the official app have not yet been revalidated.

## HTTP Client and Enabling Writes

`NoteStationClient` is an actor. Its initializer is `init(baseURL:session:allowsValidatedWrites:)`, with the last argument defaulting to false. It exposes `supportsReads=true`, `supportsEncryptedNotes=false`, and `supportsWrites=allowsValidatedWrites`. The app's `LibraryStore.connect` enables writes by setting this to true. Ordinary automatic uploads do not depend on a diagnostic report or a previous setting that disabled automatic uploads.

The main public APIs are listed below. Outside the actor, even disconnecting must be called with await.

| API | Purpose |
| --- | --- |
| `connect(username:password:otp:rememberDevice:deviceID:)` | Login and remembering the device |
| `disconnect()`, `isAuthenticated`, `trustedDeviceID` | Discarding the local session, authentication, and device token status |
| `notebooks()`, `createNotebook(name:)`, `renameNotebook(notebookID:name:)`, `deleteNotebook(notebookID:)` | Notebook management |
| `moveNotebooksToStack(ids:name:creatingNew:)`, `renameStack(from:to:)`, `deleteStack(name:)` | Stack management and changing notebook membership |
| `notes()`, `fetch(noteID:)`, `versionHistory(noteID:)`, `download(fileID:noteID:)` | Retrieval and attachments |
| `update(noteID:baseVersion:title:html:)`, `permanentlyDeleteNote(noteID:baseVersion:)` | Version-based updates and permanent deletion from trash |

Disconnecting discards the SID, cache, and device token from instance memory. It does not log out on the server or invalidate URLSession. Connection generation identifiers reject late responses from earlier requests.

## Addresses, Authentication, and Request Encoding

- Uses `webapi/` under the NAS HTTPS root or a reverse-proxy path prefix. Examples: `https://nas.example.invalid:5001/`, `https://example.invalid/nas`.
- Rejects baseURLs containing user information, queries, or fragments; HTTP; external origins; and API paths that escape webapi. HTTP redirects, bypassing certificate validation, and QuickConnect ID discovery are not supported.
- Discovers Auth before login and all APIs after login. Auth prefers v6 within the supported range; if the server's minimum version is higher, it uses that minimum.
- Remembering a device uses `enable_device_token=yes`, `device_name`, the response's `did`, and `device_id` in subsequent requests. A previous device ID is not sent when a new OTP is entered. OTPs are not stored.
- CGI and Auth form-encode raw arguments; JSON WebAPI form-encodes JSON-serialized values. Characters outside the RFC 3986 unreserved set are percent-encoded.
- Authentication arguments for ordinary form requests are in the body. Attachment multipart requests follow the official contract by placing `api/method/version/_sid` in the URL query and note arguments and binary data in the multipart body. Authenticated multipart URLs are therefore also treated as secrets and are not logged.
- Requests bypass the URLSession cache and disable cookie handling. The HTTP layer does not log request or response bodies or authentication arguments.

## API and Response Mapping

| Operation | API / Method | Version and Contract |
| --- | --- | --- |
| Authentication | `SYNO.API.Auth/login` | Discovered range, v6 preferred, notestation session |
| Notebooks | `SYNO.NoteStation.Notebook/list/create/set/delete` | v2, recursive=false on deletion |
| Stack membership | `SYNO.NoteStation.Notebook/set` | v2, object_id array and stack string; an empty string removes membership |
| Renaming and deleting stacks | `SYNO.NoteStation.Stack/set/delete` | v1, stack_id combines the stack name and owner UID |
| Notes | `SYNO.NoteStation.Note/list/get/create/set` | v2/v3, object_id/ver/check_conflict=true on updates |
| Permanent deletion | `SYNO.NoteStation.Note/delete` | v3, recycle=false, checks trash status and current version first |
| Favorites | `SYNO.NoteStation.Shortcut/list/set/delete` | v1, joins IDs for category=note |
| Tag supplementation | `SYNO.NoteStation.Tag/list` | v1, joins note IDs from items when tag is missing |
| Revision history | `SYNO.NoteStation.Note.Version/list` | v2, filter={listable:true}, versions[].version/mtime |
| Attachment download | `SYNO.NoteStation.Note/download` | v1, file_id/object_id/format=raw/mode=download |
| Attachment creation and removal | attachment in note create/set | Binary data uses multipart; removal uses action=delete/file_id |

object_id/title/parent_id/ver/mtime/tag/recycle/encrypt are converted into note summaries. mtime is in Unix seconds, and versions are opaque strings that are not compared numerically. Attachment dictionary keys are file IDs; the values' name/type/ref fields represent the filename, MIME type, and reference. Each API uses the intersection of the discovered supported range and the implementation's upper limit.

Lists are read to completion with offset/limit, validating total counts, offsets, duplicate IDs, required fields, and empty pages before completion. Nulls and omitted fields are allowed for valid empty lists; partial failures are not turned into empty lists or successes. Body versions are checked in body responses; a note is not marked current based solely on its list version. A stable server snapshot cursor has not been confirmed.

Encrypted notes are displayed as locked, and body editing and decryption are not supported. Downloads return original bytes, but Synology failure envelopes are not returned as files. A valid JSON file whose content has the same shape as a failure envelope cannot be distinguished from one.

## Local Storage and Markdown Source

The `NoteRepository` actor owns each account's notes.sqlite3 connection. It uses WAL, synchronous=FULL, and foreign keys, and stores notes, full revision history, pending transfer jobs, transfer attempts, search text, and permanent-deletion markers. Network requests are not executed within transactions. Attachments are stored in separate files and verified with hashes.

Markdown HTML for the server is separated from preview decorations, but both paths protect TeX delimiters and backslashes before CommonMark processing. During synchronization, offline KaTeX renders equations into PNGs with a white background and publishes them as ordinary Note Station image attachments. Identical equations reuse images, and generated images for deleted equations are cleaned up after version checks. Literal math examples in code, links, and original HTML are not converted to images. `SourceEnvelope` is a .md attachment that stores the exact UTF-8 Markdown source after a metadata comment. It validates SHA-256 fingerprints for the body, source, preservation blocks, and attachment mappings, as well as document and operation IDs. Reading v1/v2/v3 is supported. When equation images are present, v3 is published with dimensions, equation keys, attachment IDs, and their fingerprints; operation IDs, staging, and attachment mappings for ordinary uploads use v2.

Markdown mode opens only when exactly one source matches the body and attachment UUIDs can be restored. Outdated source and ambiguous references open in the original HTML rich-text editing mode. Existing documents can be edited directly without conversion to Markdown, and the HTML body is saved after local history and version checks. Complex HTML is retained in preservation blocks; before removing attachments, references are checked in Markdown, the rendered body, and active preservation blocks.

Search uses instr substring matching in a separate normalized text table, not FTS. Automatic age or size limits for revision history and the ordinary attachment cache are not yet provided.

## Automatic Uploads, Recovery, and Conflicts

Edits are saved locally after approximately 250ms, and uploads are scheduled approximately 900ms later. While connected, uploads are rechecked every 15 seconds and lists refreshed every 60 seconds. Connections and lists are also checked when the network returns or the Mac wakes from sleep.

1. Validate attachment bytes and preservation blocks, and check the base server version for existing notes.
2. Record a transfer attempt in SQLite and atomically update the file journal before writing.
3. For Markdown notes, the sequence is: prepare attachments and staging source → save the body and metadata → publish the latest source and clean up older protocol attachments. Every update request includes a version conflict check. Original HTML mode prepares any new attachments first, then saves edited HTML, metadata, and explicitly removed attachments with a version check. If the body has not changed, its field is not sent. Local attachment URLs are replaced only in the target tags, preserving the source of other tables, code, and widgets.
4. Fetch again to verify the title, notebook, tags, trash, favorites, source, and attachments, then record completion. Newer local changes made during upload remain queued for the next transfer.
5. If a response is lost, compare the journal with the server. A creation target is not adopted by title alone; it is verified using the operation UUID and staging attachment bytes. If the base version or applied state cannot be proven, the operation is held rather than automatically creating a duplicate.

Failures are isolated per note. Conflicts preserve both versions for comparison and selection. Selecting the server version preserves local history; selecting the local version preserves a server copy. This does not imply automatic merging or a server transaction spanning all requests.

App connection recovery uses exponential backoff for session expiration and transient communication errors, attempting only one connection at a time with the saved account. Authentication, OTP, or Keychain errors require user action. Manual disconnection does not trigger automatic reconnection. The HTTP actor itself does not automatically retry login.

## Notebooks, Deletion, and Offline Storage

- After creating a notebook, verify its ID and name in the list. Uncertain creations retain a receipt and are not blindly retried.
- Notebooks and notes created locally for that NAS account in earlier builds are migrated to the NAS. New notes and Markdown imports now target NAS notebooks.
- Notebook deletion is blocked if unsent changes exist; after deletion is confirmed, its notes are reflected as trashed.
- Permanent note deletion is allowed only for fully synchronized trashed notes while connected. After checking the current version, deleting, and confirming absence, local history and unused attachments are cleaned up. Deletion markers prevent late responses from recreating the note.
- Offline storage fetches unread or outdated bodies and attachments in the background. It excludes locked notes, isolates failures, protects unsaved and unsent changes, and prioritizes uploads.

## Keychain and Logs

Passwords and device tokens are stored under the separate service `cloud.synology-note.notestation.password.v1`. Account-scoped keys use the NAS address and username; the official app's credentials are not reused. OTPs are not stored, and SIDs are kept only in memory. The previous UTF-8 password format can also be read.

The app bundle accesses credentials through a helper with a pinned signing identity; the app and helper check that each uses the same certificate and expected identifiers. Automatic reads are noninteractive and time-limited; only user requests allow interaction. Certificate or helper changes may require access to be authorized again. See the [development signing guide](development-signing.md).

Diagnostic logs record only allowed events, identifiers, error types, and numeric codes, excluding bodies, passwords, SIDs, tokens, and raw request URLs. JSONL rotates at a default of 2MiB per file with 3 backups. See [diagnostic logs](diagnostics.md) for details.

## Diagnostics and Remaining Validation

The creation, update/conflict, image/source, and automatic upload checks in Settings run only when explicitly requested by the user and create dedicated validation notes in the selected notebook. These are not required activation steps for ordinary uploads, and validation notes are not automatically deleted. Results are retained in per-account diagnostic JSON.

Historical attachment check error 101 was resolved in a dedicated-note retest after moving multipart routing arguments to the query; matching image and source bytes and Markdown restoration were recorded. Device token storage and automatic connection after relaunching a bundle with the same signature were also recorded after selecting Auth v6. These results do not guarantee behavior on every NAS or with every signed bundle.

Run the full regression checks with `./script/test.sh`. Remaining validation includes round trips after editing in the official app, simultaneous saves on multiple Macs, actual network disconnection during multistep writes, large-scale performance, and installation and Keychain access on another Mac. For Intel/universal, Developer ID, and Apple notarization, see the [distribution guide](distribution.md).
