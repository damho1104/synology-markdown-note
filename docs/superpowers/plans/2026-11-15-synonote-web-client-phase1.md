# Web Client Implementation Plan / First Execution Scope

**English** | [한국어](2026-11-15-synonote-web-client-phase1.ko.md)

Basis: `feature/web-client`, preservation of existing macOS/CLI functionality, the final design `../specs/2026-11-15-synonote-web-client-design.md`, and `../../nas-contract.md`.

## Confirmed Security and Operations Decisions

1. **Bootstrap**: read the owner-only (0600) random code automatically generated at `/data/setup-code` before setup and use it for one-time registration. Do not expose the code through the API; delete it on success. Limit failures to at most 6 attempts per connecting peer in 15 minutes. Administrator reset and address changes will be implemented in a later phase through a safe transition tool.
2. **Single NAS**: prefer `NAS_URL`, then SQLite, then initial setup if neither exists. Report an invalid nonempty environment URL as a configuration error. Allow only public DNS/IP addresses by default; administrators must explicitly set `NAS_ALLOW_PRIVATE=true` for LAN NAS connections. Reject user information, queries, fragments, encoded paths, dot segments, and similar elements in URLs. Validate DNS addresses on every HTTPS request and pin the connection to that IP while retaining TLS hostname verification. Do not use proxies or redirects. Operators who need a CA mount a read-only CA file.
3. **Browser origin**: the API does not provide CORS. Mutating requests require a JSON `Content-Type` and an exact Origin. Set `WEB_PUBLIC_ORIGIN` for an HTTPS reverse proxy. Cookies default to Secure/HttpOnly/SameSite=Strict; allow `WEB_COOKIE_SECURE=false` only for development localhost HTTP. Operate the initial Docker server with `--no-proxy-headers` and a single worker.
4. **Sessions/keep me signed in**: when unchecked, use only an in-memory session (a browser session cookie, 12-hour idle/24-hour absolute expiry). When checked, store the random token hash/CSRF/account name/encrypted password and selected trusted-device ID in SQLite. Browser cookie expiry and maximum DB expiry are 30 days; renew tokens used for at least 7 days. Reauthenticate with the NAS using the stored password after a server restart. If OTP is required or credentials are rejected, the user signs in again. Distinguish network errors that prevent automatic NAS login from credential deletion. Generate the encryption key initially at `/data/master.key` and store it with mode 0600. Operators manage key/DB backup and recovery; key rotation is a later operational feature.
5. **Permission scope**: this phase allows only NAS `SYNO.API.Info` queries and `SYNO.API.Auth/login`. It does not yet create, modify, or delete NAS notes. Open write endpoints only after per-user note data isolation, source/attachment verification, version conflicts, and offline queues have been verified in later phases. Perform real NAS write checks only on separate test notes.

## Implementation Order and Passing Criteria by Phase

| Order | Implementation | Verification |
| --- | --- | --- |
| P1-a | React/TS/Vite·Tailwind/shadcn/ui skeleton, FastAPI + SQLite, Dockerfile/Compose | TS build, Python import, Compose configuration validation, container health |
| P1-b | Initial setup code, NAS_URL precedence, URL/SSRF/TLS policies | Initial setup authorization, blocked address changes, restart restoration, invalid URLs, blocked IPs, DNS tests |
| P1-c | NAS authentication discovery/OTP, sessions/CSRF/keep me signed in | Mock NAS login/OTP/logout/restart, account separation, expiry, cookie verification |
| P2 | Per-user account context, NAS read APIs, stack/notebook/note lists, search | Synthetic Note Station API, permissions, pagination, UI E2E |
| P3 | CodeMirror6, Markdown source/HTML preservation, attachments, KaTeX/Mermaid | Swift/CLI SourceEnvelope v1–v3 contract fixtures, conflict-free round trips |
| P4 | Write journal, conflicts, offline IndexedDB/PWA, backlinks/graph and remaining features | Lost responses/re-execution, multiple users, real NAS test notes |
| P5 | Multi-architecture builds, physical Container Manager devices, CI/GHCR/release integration | amd64/arm64 verification, DSM project installation, backup, recovery |

Implement **P1 only** in the current work. Verify physical Docker arm64 devices, NAS connectivity, and actual HTTPS reverse-proxy service behavior separately once the environment is available. Merging into `develop`, publishing to GHCR, and deployment depend on a later request.
