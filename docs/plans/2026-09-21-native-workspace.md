# Native workspace improvements — 0.5.0

Scope approved by continuing the proposed next release: native toolbar and compact file browsing, multiple project libraries, read-only cross-tool skill relationships, and operation-batch restoration. Project deliverable archiving remains a later release.

## Behavior

- Keep macOS 14+, system appearance, English/Simplified Chinese and existing cleanup boundaries.
- Navigation and frequent commands use native toolbar controls. Project contents receive more space; file details can be resized and collapsed without changing cleanup selection.
- Persist independently authorized project-library locations. Migrate the existing location, preserve unavailable entries, and clear stale scans/selections when switching libraries. Adding/removing an entry never changes its files.
- Derive skill relationships only from existing scan evidence. Distinguish AI/source/path and observed references from activation. Relationship browsing cannot delete or merge skills.
- Group records by existing batch ID. Review eligible file restoration before execution; preserve sessions as nonrecoverable, reject conflicts, report partial outcomes, and block concurrent/repeated restoration.

## Validation

- Add isolated regressions for library migration/switching/unavailable locations, skill references and incomplete evidence, and mixed/partial/repeated batch restores.
- Run core and UI state checks, localization coverage, native release build and signature/archive checks.
- Exercise the generated-data UI at the minimum window size, with details open, and in both languages/appearances. Never clean real data.
- Update acceptance documentation, install the signed build locally, and publish the release after CI succeeds.
