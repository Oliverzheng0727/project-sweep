# Project Sweep — approved product specification

Native Chinese macOS app, Apple Silicon, macOS 14+. SwiftUI, AppKit/Foundation, SQLite. No model, API key, backend, account, telemetry, background automatic cleanup, or cloud-history deletion.

Users choose or drop one project folder. Organize mode finds rule-based caches and exposes the entire file tree for explicit selection; remove mode moves the entire chosen project to Trash. Code and creative/document projects are equally supported. Preserve Git-tracked files and user keep rules in organize mode. Never label files disposable solely because names contain temp, old, final, or a version number. Build artifacts and dependencies require explicit selection. Show categories, sizes, previews, Finder reveal, keep rules, and scan cancellation.

Independently authorize roots for Codex, Claude Code, and Cursor (including custom locations). List caches/logs, local sessions grouped by tool/project, and separately protected project memory. Support both complete project groups and individual conversations. Determine project ownership from canonical recorded paths/IDs, not encoded directory names. Expand inseparable child/shared-data dependencies in the review plan. Preserve auth, settings, plugins and skills.

Files/cache/logs go to macOS Trash; record actual resulting Trash path and support non-overwriting restoration. Historical conversations default to no backup; show irreversible impact before execution. Records contain no transcript bodies. Report bytes processed separately from bytes moved to Trash, never promise immediate space reclamation for Trash.

Use official Codex thread/delete when supported. Claude sessions: narrowly scoped JSONL/index/snapshot updates. Cursor: only tested schema adapters may write; current machine has no Cursor, so session deletion must stay disabled until actual version acceptance. Do not replace session deletion with a whole-database reset. Require tool shutdown, freshness checks, SQLite transactions where relevant, and interrupted-operation recovery; fail closed on unknown formats or incomplete links.

Validate scope, root identity, path ancestors and file metadata before mutation. No following symlinks, exposing document/application package contents as cleanup choices, fetching cloud placeholders, or arbitrary filesystem traversal. Packages stay atomic in the interface; metadata-only fingerprints include their descendants to detect changes without reading document bodies. Denied permissions/changed files/partial failures must remain visible. Never execute deletion against the user's real data during development.

Deliver reproducibly built .app and source, meaningful automated core tests, and actual native UI validation. Public distribution, notarization and App Store submission are deferred.

## Project-library flow correction (user feedback, 2026-09-10)

Select a parent project library, such as Desktop/Claude. List its immediate project folders first, without scanning each project recursively. Select one card and open its deep-cleaning workspace. Offer both preserve-results cleanup and entire-project removal, with project files and explicitly linked local sessions in the same workspace and confirmation plan. Tool record roots remain independently authorized. Related cross-project sessions must be shown explicitly; global/unattributed records remain in the tool-data page.
