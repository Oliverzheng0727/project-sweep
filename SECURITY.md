# Security Policy

## Supported versions

Security fixes are provided for the latest `0.4.x` release. Older builds may not receive updates.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/Oliverzheng0727/project-sweep/security/advisories/new). Do not open a public issue for vulnerabilities or privacy problems.

Include the affected version, macOS version, impact, and minimal reproduction steps. Use generated data and redact usernames, local paths, project content, session text, access tokens, and credentials. Do not upload a real AI tool database or project archive.

You should receive an acknowledgement within seven days. The report will remain private while the issue is assessed and a fix is prepared.

## Security model

Project Sweep is a local utility with no accounts, telemetry, AI API calls, or background cleanup. Its main safety boundaries are explicit folder authorization, path and identity checks before execution, fail-closed handling of unknown tool formats, and user review before destructive actions.
