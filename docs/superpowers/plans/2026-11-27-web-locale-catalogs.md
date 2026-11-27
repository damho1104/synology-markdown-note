# Web Locale Catalogs Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for implementation and verification.

**Goal** — Make web translations extensible through language files and a shared registry.

**Architecture** — The Python package and Vite consume one language registry. The web uses typed keys and i18next to look up grouped JSON catalogs, including startup and editor messages.

**Tech Stack** — React, TypeScript, Vite, i18next, FastAPI, Docker.

**Spec** — [Web translation resources](../specs/2026-11-27-web-locale-catalogs-design.md)

## Global Constraints

The server's forced mode and its retry behavior continue to control when the app starts. Existing note, notebook, and draft values remain readable.

## Review Focus

Check region-tag matching, an additional registry entry, previous attachment error messages, catalog interpolation parity, and the first render following a startup failure.

- [x] Bind Python settings and Docker's frontend build to the same packaged registry. Test current fixed modes and an additional registry entry.
- [x] Move all web UI phrases, including startup and CodeMirror, to grouped English and Korean JSON. Type calls using the English catalog. Test missing keys, placeholder parity, and old attachment error display.
- [x] Run the backend and frontend suites, production build, full npm audit, and browser smoke tests with the normal and extended registry.
- [x] Commit the verified implementation.
