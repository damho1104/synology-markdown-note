# Synology Markdown Note Web

**English** | [한국어](README_KO.md)

See the [self-hosting guide](SELF-HOSTING.md) for installation and operation. It explains environment variables, migration from an existing Compose setup, HTTPS proxies, private CAs, and backup and restore with examples.

This web client is based on the macOS app's `LibraryView` and `EditorView`. It provides a sidebar that expands notebooks under bookshelves; sorting by title, date added, and date modified; source, split, and reading views; CodeMirror Markdown editing; Mermaid hand-drawn diagrams; KaTeX previews; a note information panel; internal links, graphs, and backlinks; and attachment downloads. It supports changing favorites and tags, moving notes to and restoring them from the trash, moving notes, and creating, renaming, and moving bookshelves and notebooks.

Right-click a notebook or bookshelf in the sidebar to delete it. Deleting a notebook moves its notes to the trash. Deleting a bookshelf clears the grouping and keeps its notebooks and notes.

## Appearance and editor settings

You can check the current app version under **About → Version** at the bottom of Settings.

The gear at the bottom of the sidebar opens a settings popover separate from the note information panel. You can configure appearance (system, light, or dark), editor font size (11–22px), Markdown line numbers and line wrapping, and Mermaid's default/sketch style and color theme (match appearance, light, dark, monochrome, or forest). Changes take effect immediately and are saved in this browser's localStorage. System mode follows OS appearance changes. Changing settings preserves the text being edited and its base version and does not save them to the NAS.

Mermaid SVGs retain the fonts used for text placement and their alignment and color styles. Only presentation properties are allowed, and their scope is restricted to each SVG. External resource and style loading, scripts, and foreignObject are not allowed.

## Panels and graphs

The magnifying glass at the top opens global search. It searches titles, previews, tags, and indexed note bodies outside the trash. Locked note bodies are excluded. Body search shares the link indexer's NAS reads and shows how many note bodies are searchable while indexing runs. Selecting a result clears notebook and tag scopes. Use the shared Back button to restore the previous screen and search state.

The Back and Forward buttons at the top treat notes, bookshelves, notebooks, favorites, tags, trash, and graphs as a single navigation history. They also record changes to note selection, neighborhood view, connection depth, notebook/tag filters, and the display of unconnected notes within the graph. Search input, zooming, and dragging only update the current entry; returning restores both the search query and graph state. Navigating somewhere new after going back clears the previous forward history. Buttons are disabled when there is no corresponding history, and clicking the shared buttons while editing waits for confirmed autosave before navigating. Note bodies and credentials are not included in navigation history.

Use the collapse buttons at the upper-right edges of the bookshelf and note list panels to collapse each panel. A collapsed panel's expand button remains at that edge. On mobile, use the bookshelf menu and a separate note list toggle. Create bookshelf and Add notebook appear in a separate highlighted button area above the list. The collapsed state is saved in this browser.

Once the note list loads after login, link indexing starts in the background whether or not you have visited the full graph. It continues while you edit notes, search, and navigate, and stops when you log out or close the web app. The next visit reuses progress saved on the server. Progress and a retry option on failure appear below the list. The full and local graphs share this work, so opening a view does not trigger separate indexing each time. If autosave changes a version, the current batch finishes without interruption and then checks for changes.

The full graph first displays the note list and saved links, then indexes links in unread notes in small batches. Even on the first run, it does not block the screen until all note bodies have been fetched, and displays progress as `노트 링크 인덱싱 중… 완료/전체` (Indexing note links… completed/total). Body fetches are limited to at most 8 per batch and at most 4 concurrently. If a batch fails, the collected graph is retained and you can retry.

The link and body search index is encrypted in the server's SQLite database and scoped to the NAS and account. After reconnecting or restarting the web server, it checks note versions to determine which notes need indexing. It also reuses bodies read when opening and saving notes.

Links using document IDs, NAS note IDs, and unique `title.md` filenames are connected; if multiple notes have the same title, no arbitrary connection is made. Notebook and tag filters, connection depth for the local graph, and showing unconnected notes are supported. In the full graph, the middle note list becomes a note connection map panel like the Mac app's. It shows key notes, search results, incoming/outgoing connections for the selected note, and a notebook color legend, sharing node colors and connection-direction highlighting with the canvas.

## Running

Use the [quick installation commands](SELF-HOSTING.md#quick-installation) to download just Compose and `.env` and start the service. It uses the `synology-md-note-web:latest` image from GHCR without building from source. You can also enter the NAS address once in the web interface after startup.

```sh
docker compose up -d
docker compose exec web cat /data/setup-code
```

Open `http://localhost:8787` in a browser and enter the NAS address and the initial setup code above. To access it from another PC, copy `.env.example` to `.env` and set `WEB_BIND_ADDRESS=0.0.0.0`, or connect your existing HTTPS proxy. It runs from the public GHCR image without a source build.

**HTTP/HTTPS cookies and the access origin are handled automatically. Normal installations do not need to set `WEB_PUBLIC_ORIGIN` or `WEB_COOKIE_SECURE`.** HTTP access uses regular HttpOnly cookies; HTTPS access uses Secure/HttpOnly `__Host-` cookies. For state-changing requests, the browser Origin's host and port must match the request Host, and a CSRF token is also checked. An HTTPS reverse proxy must forward the Host used by the browser unchanged. Arbitrary `X-Forwarded-*` headers are not trusted.

If you are reusing Compose from 0.2.x, replace it with the new `docker-compose.yaml`. If you must retain the old YAML, select automatic mode with `WEB_COOKIE_SECURE=auto` and `WEB_PUBLIC_ORIGIN=`. Only special deployments where the proxy must change Host should set the container environment variable `WEB_PUBLIC_ORIGIN` to the exact origin including the protocol. Previous explicit `WEB_COOKIE_SECURE=true/false` settings remain supported for compatibility.

## NAS connection

- If `NAS_URL` is empty, use the initial web setup. The configured NAS address is retained in SQLite. An address specified in the environment variable takes precedence.
- Set `NAS_ALLOW_PRIVATE=true` only when using a NAS on a private network or an HTTP NAS connection. When false, HTTP and private-address connections are blocked. The browser's HTTP/HTTPS connection and the NAS connection's HTTP/HTTPS are separate.
- With an HTTP NAS, passwords, OTPs, sessions, and notes are transmitted without encryption. Use it on a trusted private network. You can dismiss the connection warning with X, and this browser remembers the dismissal. Changing the NAS address resets the hidden state.
- For a private CA, mount the file read-only and specify `NAS_CA_FILE`. See the [self-hosting guide](SELF-HOSTING.md#optional-private-ca-certificate) for the optional CA mount example in `docker-compose.yaml`. There is no option to disable HTTPS certificate verification.
- To defend against SSRF, DNS addresses are validated and connections are pinned to an IP. Loopback, link-local, and metadata addresses and redirects are not allowed. A container's `localhost` refers to the container itself, not the NAS.

## Saving and compatibility

Select a notebook and use **Import Markdown** in the toolbar to create one note per UTF-8 `.md` or `.markdown` file. Add any linked local files separately from the imported note.

Changes are autosaved to the NAS 0.8 seconds after you stop editing. There are no separate Save, Start editing, or Cancel buttons; edit directly in source/split view. You can continue typing while saving, and changes made while awaiting a response are saved next using the confirmed new version as their base. Saving waits during Korean character composition. The bottom status area shows saves as pending, in progress, complete, or stopped. Remaining changes are also saved before navigating away from a note or logging out. In a conflict or when the outcome is uncertain, your edits are preserved and automatic resending stops.

Existing Markdown notes are read by checking source fingerprints in the Mac app/CLI's `SourceEnvelope` v1/v2/v3. Supported Markdown is saved in the sequence: register temporary source → save body → publish verified final source, rechecking the remote version and body at every step. Existing image attachments and source-preservation blocks are retained. Mermaid and KaTeX libraries and fonts are included in the image and do not depend on a CDN. Scripts included in documents are removed from previews. For internal links, only the app's nonce-restricted forwarding code runs in an opaque iframe, and the parent validates the iframe source and nonce. Automatic external network requests are blocked.

In editable Markdown notes, paste an image, drop a file, or choose files from the editor. Each file can be up to 50 MB (50,000,000 bytes). Larger files are rejected. The web server encrypts staged uploads and transfers them to the NAS when the note autosaves.

Use the trash icon next to an attachment in the note information panel to remove it from the NAS. Remove the reference in the note first if the file is still in use. The app manages Markdown source files and generated math images.

In an existing HTML note, select a run of text to apply bold, italic, underline, or strikethrough. Insert a table at the end of the note or select a cell in a regular table to add or remove rows and columns. Changes preserve the original HTML outside the edited range.

Open **Revision history** in the note information panel to preview and restore versions listed by the NAS. Completed web saves publish a listable version. A restore applies the selected NAS version to the current note and verifies the title, body, and attachments.

The following limitations apply to avoid data loss when handling unsupported changes:

- Body editing for encrypted notes and notes in the trash.
- Arbitrary changes to source-preservation blocks.
- Offline synchronization and permanent note deletion.

Your edits and their base version are temporarily stored in the current tab's sessionStorage, separated by user and NAS, and restored after a refresh. They may disappear when the tab closes. Successful logout clears that account's drafts; failed logout retains them. NAS passwords, SIDs, and authentication tokens are not kept in browser storage.

Version conflicts let you compare the latest NAS content while preserving your edits. If the outcome is uncertain, for example because a response was lost, no automatic retry is made. The server retains encrypted write intents and target locks, so check the save result in Note Station before clearing the hold. In-progress operations cannot be released for 1 hour.

After you acknowledge an uncertain save, you can download or discard the web server's temporary attachment copies for seven days. The server reclaims expired copies on the next upload. Discarding a temporary copy does not remove any NAS attachment.

## NAS session failures and logs

When a NAS session expires, a regular login clears the web session and cookies and returns to the login screen. With Remember login, a read request attempts NAS reauthentication once; if relogin fails or the session is still rejected after reauthentication, the web session and saved login information are discarded. Manual login is required again even if NAS relogin failed because of a network outage. Temporary body edits remain in the current tab. Authentication failures during graph or attachment retrieval also return to the login screen. Write operations are not automatically resent.

Structured events are written to container standard output without additional environment variables.

```sh
docker compose logs -f --tail=100 web
```

- `request_completed`: web API path template, HTTP method, status code, duration, and request ID
- `nas_request_completed`: NAS API and method, duration, result, and failure diagnostics for the same request ID
- `session_invalidated`: reason for invalidating the web login and the original NAS failure code
- `nas_error`: original numeric NAS error code or reason for response validation failure

Match the `X-Request-ID` response header against the log's `request_id` to find a failed call. Error JSON also includes only allowed API names, methods, error numbers, and classifications. Account names, passwords, OTPs, cookies, SIDs, trusted-device tokens, original response bodies, and note bodies are not logged. Request query strings and externally supplied request IDs are not logged either.

## Data storage and permissions

The default `WEB_DATA_PATH=synonote-web-data` is a Docker named volume. The container runs as **UID/GID 10001:10001**. New volumes inherit ownership from the image's `/data` directory.

To mount a NAS folder directly, prepare only a new empty folder and specify `WEB_DATA_PATH` in `.env`.

```sh
sudo mkdir -p /volume1/docker/synonote-web/data
sudo chown 10001:10001 /volume1/docker/synonote-web/data
sudo chmod 700 /volume1/docker/synonote-web/data
```

`/data` uses 0700 permissions, and SQLite and key files use 0600. Do not change ownership of existing files in bulk or open permissions to 777. Stop the service before updating or backing up, and retain **all of `/data`**. Include SQLite `-wal`/`-shm` files, and back up `web.sqlite3` and `master.key` together. Losing the key makes saved login information and encrypted write intents unrecoverable. Do not run `docker compose down -v`, which deletes the data.

Passwords and trusted-device IDs are stored encrypted on the server only when Remember login is used. OTPs are not stored. Regular sessions expire after at most 24 hours or 12 hours of inactivity; remembered sessions expire after at most 30 days or 7 days of inactivity.

## Updates and verification

Image: `ghcr.io/damho1104/synology-md-note-web:latest` (`linux/amd64`, `linux/arm64`). Check the relevant job's build results to confirm publication.

```sh
docker compose pull web
docker compose up -d --force-recreate web
docker compose logs --tail=100 web
```

Development source build: run `docker build -t synology-md-note-web:dev web` from the repository root. Running in an actual Synology Container Manager and writing to an actual NAS require separate verification. Mock NAS/HTTP contracts, source fixtures, and browser verification are distinguished from actual NAS verification.

Development run and checks:

```sh
cd web/backend
uv sync --group dev
WEB_DATA_DIR=/tmp/synonote-web-dev uv run uvicorn synonote_web.main:create_app --factory --host 127.0.0.1 --port 8000
# Separate terminal: npm ci && npm run dev in web/frontend
uv run pytest -q
# npm test && npm run build in web/frontend
```

Math is previewed with KaTeX and converted to PNG attachments with embedded fonts when saved. Markdown source and math association information are preserved in the same v3 source format as the macOS app, and uploaded bytes and save results are fetched again for verification. Identical math images are reused, and generated images no longer in use are cleaned up.

When you move the cursor or type during split editing, the preview follows the corresponding source paragraph. Reading mode does not scroll automatically. The preview maintains the same surrounding paragraphs as the document and styles, reserves scrollbar space, and performs temporary Mermaid rendering offscreen.
