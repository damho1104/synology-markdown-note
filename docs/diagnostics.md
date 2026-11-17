# Synology Markdown Note diagnostic logs

**English** | [한국어](diagnostics.ko.md)

Open them from Settings → Diagnostics → Diagnostic Logs → Open Log Folder.

## Exporting diagnostics for developers

Settings → Diagnostics → Diagnostics to Share with the Developer lets you save two kinds of ZIP files. You choose where to save them; they are not sent automatically.

- **Export Diagnostics**: Includes a DB status report for the currently selected account and the current and previous diagnostic logs. The DB report is limited to SQLite and schema versions, integrity check results, page count, size and free pages, row counts for predefined tables, counts by sync status, counts of orphaned, missing and mismatched FTS rows, and backup count and total size. It queries a consistent state in a read transaction through the running store's connection, without copying the original DB.
- **Export Logs Only**: Includes the current and previous logs within the configured retention count, without a DB report. Logs alone can be saved even if querying DB status fails.

Both exports record the app and OS versions, export time, number of included files, and number of excluded corrupt log lines. Account, note, and notebook identifiers are replaced with aliases that apply only within the ZIP; no mapping table is included. Logs are reconstructed using allowlists for events, fields, and values, rather than copying the originals. Unknown events, corrupt lines, and disallowed values are excluded. Logs may contain activity from multiple accounts, but all identifiers are anonymized.

The original DB, note titles, bodies and revision history contents, attachments, NAS addresses, usernames, paths, and Keychain information are excluded. Operation times, error codes, counts, and sizes are included for diagnosis, so the export is not entirely devoid of information. Original logs and databases are unchanged, and the diagnostic ZIP is not a backup for restoring notes.

DB opening, integrity checks, index rebuilding, space reclamation, backup, recovery, and undoing recovery are logged as `database.maintenance`. Entries include `operation` and `phase=started/completed/failed`, elapsed time (ms), and, depending on the phase, row counts, DB size, free pages, and backup counts. Original error descriptions are not logged. `diagnostic.export` records export start, completion, and failure without recording the save path. Operations skipped because the backup interval has not yet elapsed do not generate repeated log entries.

## Local diagnostic logs

The default location is `~/Library/Application Support/SynologyMarkdown/logs/`. The current log is `app.jsonl`, with previous logs retained in order starting at `app.1.jsonl`. Defaults are 2 MiB per file, up to 4 files including the current file, and 8 MiB in total. Settings → Diagnostics → Log Rotation & Retention lets you change the per-file size (1, 2, 5, or 10 MiB), retention count (1–20 files), and total size (1–64 MiB). Settings persist across restarts and apply to the shared diagnostic logs for all accounts. Before writing each new log entry, the app checks file size, count, and total size, rotating or deleting the oldest files before exceeding a limit. If the total limit is smaller than the per-file limit, the total limit takes precedence. Existing logs are also cleaned up when limits are lowered or the app restarts. Oversized files retain only the most recent complete JSON lines. If a single event exceeds the file limit, it is not written to the file and an error is reported. “Rotate Logs Now” moves the current log to a previous file and prepares a new file. This retention policy does not delete original databases, backups, or other files. macOS manages OSLog retention.

Folder permissions are 0700 and file permissions are 0600. Note saving and synchronization continue even if writing log files fails.

Each line is independent JSON. Entries record the UTC time, event name, app version and build, process ID, part of the account key, note/notebook IDs, revision number, pending transfer count, and error kind and code. Passwords, OTPs, device tokens, session IDs, server URLs, note titles and bodies, attachment bytes, and original error descriptions are not logged.

Main events:

- `connection.started`, `connection.succeeded`, `connection.failed`, `connection.recovery`: Connection and recovery.
- `note.created`, `note.saved`, `note.save_failed`, `note.imported`: Saving on the device and importing.
- `note.delete_requested`, `note.deleted`, `note.delete_failed`, `note.delete_cache_failed`: Permanent deletion from the trash and cleanup of device copies. Device copies are not removed before NAS deletion is confirmed.
- `upload.started`, `upload.completed`, `upload.pending`, `upload.failed`: NAS upload and verification. A remaining `pending` event does not mean the transfer is complete. Failure events' `error_kind` and `error_code` distinguish API, HTTP, and network errors.
- `notebook.migrating`, `notebook.migrated`: Converting a previous local notebook to a NAS notebook.
- `notebook.created`, `notebook.renamed`, `notebook.delete_requested`, `notebook.deleted`, `notebook.delete_failed`: Notebook operations.
- `stack.mutation_started`, `stack.mutation_completed`, `stack.mutation_failed`: Execution phases and failure causes for stack creation, movement, and renaming. Renaming is distinguished by `state=rename`, `rename.waiting`, `rename.nas`, and `rename.local`.
- `inspector.requested`, `inspector.opened`, `inspector.closed`: The information panel. If a request is recorded without an opening event, check macOS diagnostic reports as well to determine whether the app terminated while creating the panel.

Events are also recorded in the system log under subsystem `com.damho.SynologyMarkdown`, category `Diagnostics`. Additional metadata in the system log is marked private. For the stack at app termination, check the `.ips` reports macOS writes to `~/Library/Logs/DiagnosticReports/`. If the app crashes, events immediately before termination may remain; `app.terminating` records a normal termination request.

```sh
rtk proxy /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.damho.SynologyMarkdown" AND category == "Diagnostics"'
```

Since build 5, save verification errors are distinguished as `error_kind=readback_verification`, an unknown write outcome as `write_uncertain`, and actual version conflicts as `remote_changed` or `version_conflict`. Allowed differences in the HTML representation of code blocks are verified by recording a fingerprint of the actual HTML read from the server, while integrity checks for the Markdown source and preserved blocks remain in place.
