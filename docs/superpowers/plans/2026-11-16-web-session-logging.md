# NAS session invalidation and diagnostics

User requirement: NAS login failure must log the web user out; logs must expose the failing request and actual NAS error. New Aside login read successfully; original failing browser returned NAS_API_ERROR with no diagnostic, so its precise upstream cause remains unproven.

- [x] Add regression coverage for transient expiry, repeated expiry after one remembered read retry, every failed NAS relogin including network/API errors, cookie removal and token replay rejection.
- [x] Revoke affected credentials/session and clear cookies on proven NAS authentication failure. Preserve drafts. Preserve unknown-token responses without cookie deletion so a late pre-rotation request cannot remove a newer cookie.
- [x] Keep authenticated discovery with the NAS login as macOS does; route expired sessions to the actual API instead of relying on rediscovery. Decode nested API failure codes as well as envelope errors.
- [x] Correlate request completion, NAS operations, errors and invalidation through server-generated IDs, with durations and sanitized diagnostics; omit credentials, note data and query strings. Keep normal Uvicorn access logging disabled.
- [x] Centralize frontend authentication-expiry notification so graph and attachment error handlers cannot retain a logged-in screen.
- [x] Verify complete suites/build, Aside simulated NAS expiry with remember on/off, review and multiarch image publication.

No real NAS writes or session-expiration mutations were performed against production. Do not retry writes or invalidate unrelated user sessions. Old NAS_API_ERROR cannot retrospectively establish the NAS numeric code; new logs preserve it for recurrence.

Browser evidence: Aside simulated expiry with login-maintenance disabled/enabled returned to login and /api/auth/me returned401; graph401 also now returns to login. Production fresh login read notebooks and notes successfully, without NAS writes. Browser additionally reused old cached HTML (old script URL differed from cache-bypassing index); now HTML sends Cache-Control:no-store. Existing cached copies need one hard refresh after update.

Independent review found missing-token response could delete rotated cookie; fixed and covered. Already-expired explicit logout is treated as locally complete while other logout failures preserve drafts. Tests verify credentials/tokens and query strings never appear in captured logs; timestamps, API operation, status and timing correlate by server-generated request ID.

Final verification: backend238 tests, frontend49 tests, production build and Compose validation passed. Both linux/amd64 and linux/arm64 published manifests were pulled and run: installed version0.4.2, HTTP/HTTPS login/read, failed remembered NAS re-login ->401, revoked session/deleted cookies, request IDs, emitted invalidation logs, HTML no-store and UID/private modes all passed. Image index sha256:265803b7ff8bcd4f28d48010d9d5c28b18d812e1f659d936ec010837a02d012c. Production service deployment was not changed.
