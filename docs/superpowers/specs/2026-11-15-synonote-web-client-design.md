# Synology Markdown Note Web Client Draft Design

**English** | [한국어](2026-11-15-synonote-web-client-design.ko.md)

- Written: 2026-11-15 (Asia/Seoul)
- Status: pre-implementation review proposal (incorporates NAS address configuration and keep-me-signed-in requirements)
- Working repository: `<repository-root>` (`feature/web-client`, branched from `develop`)

## Purpose and Scope

Add a **third client (Web)** using the same Synology Note Station data while **keeping the existing macOS app and Python CLI unchanged**. The goal is to provide the macOS app's main user features and level of data protection on the web as well. The web app must be deployable with Docker on a separate server and installable through `compose.yaml` in **Container Manager → Project** on a Synology NAS.

- The default principle is to leave product behavior in the existing `Sources/`, `Tests/`, and `cli/` unchanged. Add necessary compatibility contracts under `contracts/`.
- Support both server and client running on separate devices and a container running on the same NAS.
- Note Station is the authoritative data store. Web-specific SQLite and browser IndexedDB are auxiliary stores for caching, pending saves, and conflict recovery.
- Initial target features: NAS login/OTP, stacks/notebooks/notes, Markdown and existing HTML editing, images/attachments, KaTeX/Mermaid, autosave/offline/synchronization, version conflict resolution, search/smart notebooks, tags/favorites, links/backlinks/graph, move/trash/restore, import/export, version history, settings/diagnostics, and responsive UI.
- Body editing for encrypted Note Station notes and reproducing unsupported widgets from the official app are out of scope. Protect complex HTML on the web as the existing app does.
- A central SaaS service open to multiple users is out of scope. Isolate each user's NAS permissions and web session in self-hosted deployments.
- Connect to **one NAS per installation instance** only. Set the NAS address through a Compose environment variable or initial web setup. Users signing in to the same web instance use their own accounts on that same NAS.
- Manage development and design documents on the `feature/web-client` branch of the `github/` repository, then integrate into `develop` after verification. Do not directly change `main` or existing macOS/CLI releases.

## Approaches Considered

| Approach | Advantages | Disadvantages / decision |
| --- | --- | --- |
| Call NAS WebAPI directly from the browser | Simple web server | Rejected because of direct NAS exposure, browser origin/session/authentication issues, and offline synchronization complexity |
| **React + FastAPI, single deployment image** | Server-managed web sessions; installable as one Compose service | Requires packaging FastAPI and frontend assets together. **Recommended** |
| Separate frontend, API, and DB containers | Suited to independent scaling and operations | NAS installation and volume/network management are too complex for the initial requirements |

## Repository and Runtime Structure

```text
github/                          # Independent GitHub repository (working branch: feature/web-client)
├── Sources/                     # Existing macOS: retain
├── cli/                         # Existing Python CLI: retain
├── contracts/                   # Compatibility fixtures/contracts for all three clients
├── web/
│   ├── frontend/                # React, TypeScript, Vite
│   ├── backend/                 # FastAPI, NAS adapter, synchronization/storage
│   ├── tests/                   # Browser/API/contract/synchronization tests
│   ├── Dockerfile               # Multi-stage build, single runtime image
│   ├── compose.yaml             # For Docker Compose / Container Manager projects
│   ├── .env.example             # Optional configuration examples; no real secrets
│   └── README.md                # General Docker and DSM installation/backup guide
├── .github/workflows/           # Later integration of Web tests and image publication
└── docs/superpowers/specs/      # This draft design
```

```text
Chrome / Safari / Edge (React + CodeMirror + IndexedDB)
                      │ HTTPS, session cookies
                      ▼
      FastAPI (frontend static assets + /api)
         ├─ NAS connections per session/user
         ├─ SQLite + attachment/operation journal
         ├─ Note Station API adapter
         └─ Synchronization/conflicts/source verification
                      │ HTTPS
                      ▼
             Synology Note Station
                      ▲
                 macOS app / CLI
```

- The web API **uses the proven HTTP/source-format code in the existing `cli/src/synonote_cli` as a dependency where feasible**. Do not run the existing CLI itself as a web server or share the CLI's global credential storage.
- Implement operations absent from the CLI (synchronization journal, version history management, full stack/trash functionality, HTML-preserving editing, etc.) in `web/backend/`. Cross-check this area against Swift NoteCore's verified behavior and contract fixtures.
- Markdown editor: CodeMirror 6; safe preview: KaTeX + Mermaid; HTML editing: a separate editing mode that satisfies existing HTML protection rules.
- React routing/navigation uses the same back/forward navigation state on every screen. Rearrange navigation panels on mobile/tablet devices.

## NAS Address Configuration and First Launch

**Precedence:** `NAS_URL` environment variable (when nonempty) → NAS address saved in the persistent data volume → initial web setup screen.

| State | Web behavior | Configuration storage |
| --- | --- | --- |
| An HTTPS address is set in Compose's `NAS_URL` | Show the NAS address as already configured and display the login screen immediately. The address cannot be edited from ordinary screens. | The environment variable takes precedence and does not overwrite the existing address in the web DB. Apply changes by editing Compose and restarting the container. |
| `NAS_URL` is absent or empty; a saved address exists | Display the login screen using the saved NAS address. | Load it from the single-instance settings in SQLite. Restore it from the persistent volume after container restarts and image updates. |
| `NAS_URL` is absent or empty; no saved address exists | Enter the NAS HTTPS address on the initial setup screen. After a connectivity check, save it once and proceed to login. | Save it in the instance settings SQLite database. Protect initial setup with a one-time setup code or similar mechanism so an arbitrary visitor cannot claim the address setting first. |

- Allow values such as `https://nas.example.com:5001` or an HTTPS path through a reverse proxy, but reject user information, queries, and fragments. Server-side SSRF defenses are mandatory, including host/IP checks before and after connection, blocked redirects, and TLS certificate verification.
- The NAS address first entered through the web **applies to the whole installation**. Do not provide per-user server selection. Offer administrator address changes as a separate protected configuration operation; verify safe transition/holding of existing login sessions and queued synchronization operations when changing it.
- When the environment variable contains an address, make the web settings field read-only and display the configuration source. If changed to an empty value, use the saved address if present; otherwise open initial setup. Report invalid nonempty values as configuration errors instead of silently ignoring them.

## Login Screen and “Keep Me Signed In”

- Base the UI on the familiar existing Note Station web flow: **username / password / two-factor authentication code (when needed) / `Keep me signed in` checkbox / login button**. Since the rules above determine the NAS URL, users normally do not reenter it in the login form.
- **Unchecked (default)**: issue only a browser session cookie. Require login again after the browser closes by default, and do not persist the NAS password on the server. Browser session restoration options may make actual browser closure detection unreliable, so also enforce server-side idle/maximum session expiry.
- **Checked**: issue a persistent login token with an expiration period (initial proposal: 30 days) so the session can be restored after closing/reopening the browser or restarting the web container. Store only the token hash on the server; apply `HttpOnly`, HTTPS `Secure`, and an appropriate `SameSite` option to the cookie. Rotate tokens periodically and revoke them on logout, administrator session cancellation, or expiry.
- Reauthentication is needed for the user's chosen **keep-me-signed-in behavior to actually work** even after the NAS SID expires. Therefore, design automatic per-session re-login using the NAS password and trusted-device ID stored encrypted on the server only when the checkbox is selected. Encryption keys require generation, persistence, backup, and rotation policies; support a separate Docker secret/externally managed key where possible. **Do not store OTPs or NAS SIDs in browser storage or logs.** Show the login screen again on password changes, renewed OTP requests, token revocation, or similar cases.
- When unchecked, do not leave existing persistent tokens or retained credentials behind; discard them when the session ends. Keep-me-signed-in selection is independent for each browser/user session. Present the web's `Keep me signed in` and Synology's `Trusted device` choice as separate concepts.
- Show a separate 2FA code entry step when needed and never save the code. NAS accounts determine per-user access permissions. Clearly disclose in the checkbox help/installation documentation that the web app may store passwords and device tokens.

## NAS Data and Synchronization Safety

1. The web server uses only one valid NAS address per instance. Prevent SSRF and misuse of NAS connections through initial setup protection, server URL validation, DNS re-resolution/redirect restrictions, and HTTPS certificate verification.
2. Do not return user NAS credentials, SIDs, or OTPs to the frontend. Isolate server-side sessions per user and apply HttpOnly/Secure/SameSite to cookies. Check CSRF and request origins on login/write APIs. Store encrypted credentials/persistent sessions only when `Keep me signed in` is enabled.
3. The browser records edits in IndexedDB first. The web server maintains pending transmission state in SQLite and attachment storage separated by user/NAS account. Define what can be replayed after browser closure/refresh or server restart.
4. Always use the base NAS version and `check_conflict` for writes. If a response is lost, verify whether the write actually took effect through rereads, operation IDs, and source fingerprints; hold retries when the outcome is uncertain.
5. Verify `SourceEnvelope` v1/v2/v3, preserved blocks, attachment references, KaTeX images, and Markdown source byte verification as shared contracts across all three clients.
6. Preserve both the NAS copy and the local copy being edited on conflicts, allowing comparison/selection. Protect encrypted/unsupported documents through read-only mode or blocked editing.
7. Inform users in the UI that personal information remains in the browser cache (offline documents), and implement a local data deletion/retention policy on logout and per-account isolation.
8. Define offline functionality (PWA service worker) as operating in browser secure contexts such as HTTPS or localhost, and ensure reliable recovery on reconnection while accounting for browser limitations on background synchronization.

## Docker Compose / Synology Container Manager

**Goal: a deployment that starts with one container by uploading a single `compose.yaml` file to Container Manager's project settings.** Pin the runtime image to a release version and later use published multi-architecture images (`linux/amd64`, `linux/arm64`). Do not describe deployment as available before image publication.

- `web/compose.yaml`: minimal configuration including image reference, ports (e.g. host `8787` → container `8080`), restart policy, health check, persistent data volume, timezone, and optional `NAS_URL`. Do not require the CLI, a separate DB server, Redis, elevated privileges, or host network.
- `web/.env.example`: configuration examples for general Docker Compose operators. Omitting or leaving `NAS_URL` empty **proceeds to initial web setup**, so do not require an accompanying `.env` file. `NAS_URL` can also be set directly in Container Manager's project YAML editor. Document that relative paths resolve against the DSM project working directory.
- Keep SQLite/attachments/operation journals beneath one persistent mount. For NAS deployments, explain how to back up through a bind mount of, for example, a project-specific shared folder; verify file ownership/permissions and upgrade backup procedures.
- State the web port's default exposure scope and DSM reverse-proxy HTTPS configuration. Explain that `localhost` points to the container itself when the NAS connects to itself, so users must use an accessible DSM LAN address/FQDN. Support mounting CA certificates for self-signed/private CAs, but do not provide a TLS verification bypass option by default.
- Target only models/DSM versions that support Synology's Container Manager package. Building and testing `amd64` and `arm64` images **does not guarantee operation on every NAS model**. Record target devices and image architectures in the deployment verification matrix.
- Provide connection diagnostics and Readiness/Health endpoints to check whether the web server's outbound HTTPS requests to the NAS are permitted by the network/firewall.
- NAS address settings and `Keep me signed in` information are all saved in the persistent volume. Document volume and encryption-key paths so they survive Compose changes, project recreation, and container image replacement.

### Installation and Deployment Contracts

- General Docker: provide a release-version image and `web/compose.yaml`, start with `docker compose up -d`, and document backup/update/recovery commands.
- Synology: install the same Compose file through **Container Manager → Project → Create → Upload/Edit YAML**. Explain GUI project paths, port conflicts, volume permissions, and reverse-proxy configuration step by step.
- GitHub releases: provide a web image matching the version tag (planned GHCR publication), downloadable Compose examples, and installation instructions together. Preserve existing macOS/CLI release pipelines.
- Design Web tests and Docker image publication on the existing Linux X64 self-hosted runner, but first check whether Buildx cross-builds and emulation/physical-device verification are possible for `arm64`. Use the macOS ARM64 runner for existing macOS checks. Follow tag/`main` protection rules.

## Implementation Order / Completion Criteria / Budget

| Phase | Main work | Phase verification | Approximate total input/output tokens |
| --- | --- | --- | ---: |
| 1. Shared contracts | Swift/CLI feature map, API schemas, contract fixtures | Matching read formats across macOS/CLI/web | 50,000–80,000 |
| 2. Backend | Login/OTP, API, user sessions/isolation, NAS operations | Mock NAS authentication/read/write, error handling | 100,000–180,000 |
| 3. Screens/search | Responsive UI, stacks/notebooks/notes, search/navigation | Browser E2E/keyboard/Korean input | 120,000–200,000 |
| 4. Editing/attachments | Markdown/HTML, source preservation, math/images/attachments | Round trips with macOS/CLI and loss prevention | 200,000–360,000 |
| 5. Knowledge management | Tags, favorites, backlinks, graph, trash, etc. | CRUD/links/version conflict cases | 120,000–200,000 |
| 6. Offline/synchronization | IndexedDB, operation queues, retries, conflict UI | Disconnection/restart/multiple-browser verification | 150,000–280,000 |
| 7. Deployment/stabilization | Images/Compose, GHCR, CI, security/performance verification | Docker Linux and actual Container Manager tests | 130,000–250,000 |
| **Total** | **Web client covering the main macOS features** | **Verification through actual NAS round trips** | **870,000–1,550,000** |

The budget is a rough estimate including implementation, verification, and debugging; it varies with the model, tools, and context reuse. The planning baseline is about **1.2 million tokens**, with a contingency ceiling of about **1.6 million tokens**. Docker/Container Manager compatibility verification may require additional work.

**Final acceptance criteria:** verify both configured/unconfigured `NAS_URL` paths and configuration restoration after restart; browser/container restarts and NAS session expiry with keep-me-signed-in unchecked/checked; consecutive editing of the same note in the macOS app and web; data preservation after conflicts/lost responses; attachment/Markdown source integrity; nondestructive HTML editing; reconnection after offline use; per-user session isolation; and actual Docker Compose deployment and deployment/recovery through Container Manager on a supported NAS. Use dedicated test notes for actual NAS write verification.

## Items to Verify Before Implementation

- NAS SSL certificate/connection path/permissions, and `SourceEnvelope`/HTML/attachment round-trip contracts between macOS and web.
- The extent to which the CLI's Python `NoteStationAPI` can be safely reused per session in the web backend, including thread/timeout handling.
- Whether the Linux X64 runner can build and smoke-test arm64 images with Docker Buildx, and which Synology models/architectures are available for testing.
- Limit the initial deployment to **one NAS per installation**. Prefer `NAS_URL`; otherwise save the address after administrator authentication during initial web setup. Finalize initial setup code issuance/display and queue/session policies for configuration changes in the detailed implementation design.
- Verify the encryption-key lifecycle for NAS credentials required by `Keep me signed in`, per-account revocation and re-login error handling, and cookie behavior behind an HTTPS reverse proxy.

This document is a **design proposal for review** that forms the basis for the implementation plan. Actual implementation and release of runtime code, Docker images, and Compose files take place in later phases.
