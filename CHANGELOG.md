# Changelog

All notable user-visible changes are documented here.

## [0.4.2] - 2026-09-12

- Discover and scan existing standard Codex, Claude Code, and Cursor data folders automatically when opening tool data.
- Keep discovery bounded to three fixed local paths, skip symbolic-link roots, and preserve custom folder selection.
- Remember an explicit disconnect so a standard tool is not reconnected automatically.
- Add a one-click discover-and-scan action and update the bilingual setup copy.

## [0.4.1] - 2026-09-12

- Refresh the whole navigation interface immediately when switching between English and Simplified Chinese.
- Make project inventory totals exclude the synthetic root row and label the kept root explicitly.
- Add persistent project filters for recent, scanned, cached, and unavailable entries, plus project pinning.
- Detect standard Codex, Claude Code, and Cursor data locations in a guided setup view while keeping authorization separate.
- Remove empty search and cleanup controls before any tool data directory has been connected.
- Reduce vertical space in project detail so the file tree remains useful at the minimum window size.
- Validate the official `thread/delete` flow against an installed Codex CLI 0.147.0 in an isolated temporary `CODEX_HOME`.

## [0.4.0] - 2026-09-11

- Add a complete English interface alongside Simplified Chinese, with an immediate in-app language switch and a follow-system option.
- Localize file sizes, folder dates, scan states, safety explanations, cleanup results, previews, and accessibility labels.
- Add automated localization coverage and duplicate-key checks to CI.
- Replace compressed 1123 × 768 JPEG repository screenshots with lossless 2280 × 1560 Retina PNGs in English.
- Package localization resources inside the app so standalone builds launch without depending on the source checkout.

## [0.3.3] - 2026-09-11

- Follow the macOS light or dark appearance by default, with optional fixed themes.
- Use the system accent color for interactive controls and semantic colors for caches, warnings, protection, and successful cleanup.
- Use native folder artwork and adaptive surfaces in the project library.
- Add public screenshots, continuous integration, contribution templates, and release documentation.

## 0.3.2 - 2026-09-11

- Make the project hierarchy the default file browser.
- Give the project root a distinct icon and label; show child folders with indentation and independent expansion controls.
- Keep cleanup selections through view and filter changes while limiting whole-project removal to the root item.
- Add keyboard tree navigation and preserve expansion state for rescans of the same project.

## 0.3.1 - 2026-09-11

- Discover default Claude Code, Codex, shared, and plugin skill sources automatically.
- Keep plugin, system, synced, and shared-original skills read-only.
- Remove only the current tool's symbolic-link reference when a skill is shared.

## 0.3.0 - 2026-09-10

- Add native project scanning, selection review, Trash-based cleanup, conflict-safe restore, and local operation records.
- Add adapters for supported Codex and Claude Code local data plus read-only Cursor session handling.
- Protect Git-tracked content, tool configuration, skills, document packages, symbolic-link boundaries, and user keep rules.

[0.4.2]: https://github.com/Oliverzheng0727/project-sweep/releases/tag/v0.4.2
[0.4.1]: https://github.com/Oliverzheng0727/project-sweep/releases/tag/v0.4.1
[0.4.0]: https://github.com/Oliverzheng0727/project-sweep/releases/tag/v0.4.0
[0.3.3]: https://github.com/Oliverzheng0727/project-sweep/releases/tag/v0.3.3
