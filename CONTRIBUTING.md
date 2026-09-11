# Contributing

**English** | [简体中文](CONTRIBUTING.zh-CN.md)

Use an Apple Silicon Mac running macOS 14 or later with a Swift 6 toolchain. After cloning, run:

```sh
swift build
swift test
bash scripts/verify-ui-boundaries.sh
bash scripts/build-app.sh
```

Tests use generated, isolated data. The actual Codex protocol test requires `PROJECT_SWEEP_TEST_CODEX` and is skipped when it is not configured; see the [README](README.md). Native interface validation and its limitations are documented in the [acceptance record (Chinese)](docs/acceptance.md).

## Reporting issues

Include your macOS, Project Sweep, and relevant AI tool versions, steps that reproduce the issue in a generated project, expected behavior, and actual results. Remove personal paths, project names, conversation content, credentials, and login information from screenshots and logs. Do not upload real tool databases.

## Submitting changes

Explain the problem, the user-visible change, and the verification performed. Changes to scanning, selection, cleanup, or restoration should include isolated regression coverage for data boundaries. Test deletion and restoration only with files you generated.

Preserve pre-execution checks, explicit confirmation, system protection, and restoration without overwriting. Uncertain associations and unvalidated tool formats must remain read-only. Cursor session deletion is disabled; simulated tests cannot replace compatibility validation against an actual tool version.
