# Project Sweep Implementation Plan

> **For agentic workers:** Use subagent-driven-development for isolated feature ownership and independent review. Track tasks with checkboxes.

**Goal:** Deliver the approved native, local Mac project cleanup app with guarded deletion and verifiable recovery.

**Architecture:** CleanupCore owns immutable scan/selection models, a filesystem scanner, explicit rules, tool-specific adapters, and guarded execution. A SwiftUI executable owns folder grants, presentation, selection, previews and confirmation. A SwiftPM build script creates the native app bundle.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation, CryptoKit, system SQLite, XCTest; no third-party packages.

**Spec:** ../specs/2026-09-10-project-sweep.md

## Global Constraints

- Apple Silicon, macOS 14+; Chinese interface.
- No model, API key, backend, account, telemetry, or automatic deletion.
- Only explicitly authorized roots; use test fixtures for every destructive test.
- No history backup by default; no chat bodies in application operation logs.
- Never enable Cursor conversation mutation without actual-version validation.

## Tasks

- [x] **1. Filesystem core** — `Models.swift`, `FileSafety.swift`, `ProjectScanner.swift`, `SelectionPlanner.swift`, `CleanupExecutor.swift`, `RecordStore.swift`; `FileSafetyTests`, `ProjectScannerTests`, `CleanupExecutorTests`. First assert scope escapes, changed trees, tracked/keep protection, overlapping selections, and restoration collisions are rejected; implement guarded scan/trash/restore; run `swift test --filter ProjectScannerTests` and the complete core suite.
- [x] **2. Tool adapters** — `Sources/CleanupCore/Tools/`; `ToolDataServiceTests`. Build deterministic two-project fixtures for Codex/Claude/Cursor. Assert unknown formats stay read-only, per-session selection preserves other sessions and configuration, linked children are expanded, changed indexes abort, and incomplete operations recover. Inspect generated local Codex JSON schema at `.build/protocol`; never invoke deletion against normal CODEX_HOME. Implement and report exact support limits.
- [x] **3. Native interface** — `Sources/ProjectSweepApp/`. Build an accessible native split interface with folder drop/picker, mode switch, category list/tree, size ordering, preview, keep rules, explicit tool root grants, project/session grouping, review sheet, persistent records and restore. Integrate only through the contract below. Compile `swift build`; test actual app via CUA.
- [x] **4. Packaging and acceptance** — `scripts/build-app.sh`, `scripts/make-icon.swift`, `README.md`. Run complete tests, release build and codesign verification. Exercise a Chinese-path disposable project in the native UI, including scan, selection, confirmation, Trash and restoration. Independently review task boundaries and the complete safety-sensitive diff, fix findings, and record results.

## Integration contract

`Models.swift` is the shared source of truth. All core services are Sendable; SwiftUI state is MainActor-isolated.

```swift
ProjectScanner().scan(_ request: ScanRequest,
  progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanResult
SelectionPlanner.makePlan(items: [CleanupItem], selectedIDs: Set<String>) throws -> CleanupPlan
ToolDataService().scan(_ configuration: ToolConfiguration,
  progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanResult
ToolDataService().deleteSessions(_ items: [CleanupItem], configuration: ToolConfiguration,
  batchID: UUID) async -> [CleanupRecord]
ToolDataService.ensureClosed(_ tool: ToolKind) throws
CleanupExecutor(store: RecordStore()).execute(_ plan: CleanupPlan,
  configurations: [ToolConfiguration], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [CleanupRecord]
CleanupExecutor(store: RecordStore()).restore(_ record: CleanupRecord) async throws -> CleanupRecord
RecordStore(directory: URL? = nil) // actor; load(), append(_ records:), replace(_ record:) throw
PathSafety.validate(_ url: URL, within root: URL) throws
Snapshotter.capture(_ url: URL, recursive: Bool = false) throws -> FileSnapshot
Snapshotter.verify(_ url: URL, matches snapshot: FileSnapshot) throws
```

Every selectable filesystem item has a snapshot. Directory snapshots include the full descendant metadata digest; ancestors with protected/unreadable content cannot be selected. Session adapter metadata never contains conversation bodies. The UI uses `relatedIDs` to explain selection expansion before invoking the executor.

## Checkpoint log

Initial repository was empty and had no commits. Work uses dedicated `codex/native-cleaner` branch in the user's explicitly selected project folder. Existing user data is out of scope for mutation.

| Boundary | Producer / consumer | Check |
|---|---|---|
| Core → UI | Models and integration contract above | Shared immutable types, async calls, no filesystem mutation from views |
| Core → adapters | PathSafety/Snapshotter; session executor interface | Revalidation shared; history mutation is explicit action |
| UI → executor | SelectionPlanner review plan | Executor receives reviewed plan, not raw arbitrary paths |
| Task 1 | Scan and trash/restore tests | Tests assert user-file preservation and concurrency changes |
| Task 2 | Isolated adapter fixtures | No real session deletion; Cursor write gate retained |
| Task 3 | Real native interface | No fabricated scan results |
| Task 4 | Build/review/UI evidence | Ship only verified artifact; document unavailable capabilities |

## Final acceptance

56 core XCTest cases passed, including installed Codex 0.147.0 official-interface acceptance in an isolated home; 11 UI boundary checks passed. The arm64 Release bundle was built and signature-verified. Native CUA checks covered project scan, Git protection, tree, preview, review, real Trash/restore, two-project tool grouping and individual selection. See `docs/acceptance.md` for actual-version limits: Cursor writes remain disabled, Claude production-history restart acceptance and a separate macOS 14 runtime remain unverified. No real user data was deleted.
