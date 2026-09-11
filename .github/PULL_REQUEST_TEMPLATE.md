## What changed

Describe the concrete problem and the resulting behavior.

## Validation

- [ ] `swift test`
- [ ] `bash scripts/verify-ui-boundaries.sh`
- [ ] `bash scripts/build-app.sh` when app or packaging code changed
- [ ] Tested only with generated or disposable data

## Data safety

- [ ] The change keeps scans within explicitly authorized directories.
- [ ] Destructive actions still require review and identity/scope rechecks.
- [ ] Logs, fixtures, screenshots, and commits contain no credentials, conversation text, private project names, or personal paths.
- [ ] Unknown tool formats remain read-only or disabled.

## Interface changes

Add before/after screenshots for visible changes. Use generated projects and sanitized paths.
