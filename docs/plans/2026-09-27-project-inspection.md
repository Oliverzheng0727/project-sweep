# Project inspection improvements — 0.6.0

Continue the three previously prioritized improvements: cache coverage, persistent prior-scan summaries, and storage composition with large-file filters. Keep native macOS 14+ UI, English/Simplified Chinese, and all existing protection and confirmation boundaries.

## Scope

- Recognize a small set of documented tool caches only when an in-root local manifest and the exact tool path provide evidence. Bound manifest reads; reject symlinks, cloud placeholders, and configuration execution. Preserve Git, source/artwork, keep, and protected-directory checks. Explain producer and regeneration impact.
- Persist only complete scan totals, cache bytes, original scan time and root identity. Reopened summaries are explicitly historical and unverified. They never populate executable file results or selection. Opening a project still starts a fresh scan; successful scans replace history. Missing/replaced directories cannot borrow another project's statistics.
- Show non-overlapping storage composition derived from the scanned inventory, with document, image, video, audio, source, dependency, build, cache and other categories. Add category and minimum-size filters that combine with existing filters, retain tree ancestors and preserve cleanup selections. Unknown statistics stay incomplete.
- Keep space composition compact and collapsible; use semantic colors with labels and native controls. Folder creation dates remain independent of scan dates.

Deliverable archiving, restore preflight, application updating, new session-deletion compatibility, and Developer ID/notarization are outside this release.

## Verification and delivery

Add isolated regressions before the relevant behavior changes; run complete core tests, UI state checks and localization coverage. Exercise generated mixed projects in the native UI, including search/size/category combinations, source protection, relaunch history, minimum window, both languages and appearances. Never clean real projects or tool history. Review the implementation, build and verify the app archive, install locally and publish source/release after CI passes.
