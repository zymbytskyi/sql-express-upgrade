# Validation record - v0.4.0-rc1

Date: 2026-10-01. Release candidate: **not production-certified**.

## Executed

- Windows PowerShell 5.1: Test-Safety.ps1 (13 source guards + 8 discovery cases).
- Test-Menu.ps1: actual current launcher functions with mocked SQL/process calls;
  interactive selected-instance arguments, cache-only validation, invalidation and
  duplicate Setup blocking. A session-0 environment tests refusal instead of GUI.
- Test-OperatorGuidance.ps1: document content, storage selection/capacity, backup age,
  missing/modified file diagnostics and folder choice, using isolated fixtures.
- Test-ProductionFindings.ps1: backup during pending reboot; default VERIFYONLY vs
  optional full restore; cache reuse and invalidation; no working database drops;
  pre/post-upgrade manifest separation; quick verification; patch instance/restart
  arguments and success/failure/restart state; security-vs-CU ordering; compatibility
  approval/revert records and system-database exclusion; foreign manual backup rejection;
  filename safety; wrong-language metadata; automatic interrupted-download retry;
  reuse of valid media/bootstrapper with explicit language.
- Real Microsoft SQL 2022 ENU media downloaded and EXTRACTED ONLY in a host temporary
  folder: Authenticode valid; SQL 2022 Express 16.0.1000.6 metadata; numeric LCID 1033;
  extracted language XML and x64 engine MSI template validated. Numeric LCID avoids
  localized Windows language-name strings. No SQL installation was launched.
- Read-only live Microsoft metadata: CU27 KB5104824 16.0.4295.3 and security rows parsed;
  parser ordered the newest CU-branch servicing target correctly. This snapshot is not
  hard-coded as a permanent latest build. Discovery runs again when patching is requested.
- Release builder parses allowlisted scripts, runs isolated suites in Windows PowerShell
  5.1, builds ZIP/SHA256 metadata and compares every file after archive extraction.

## Not claimed

No production connection, SQL upgrade, patch installation, restart or recovery was
performed during this development. The lab VM was found off and was not started.
Real patch installer exit/restart behavior and the complete revised workflow still
need a controlled non-production rehearsal. Media-download orchestration on German
Windows was fixture-tested; the original production locale was not reproduced live.

The optional Hyper-V helper's historical testing is not evidence of Azure Backup or
an independent export/import recovery. External recovery and application acceptance
remain operator-owned. Large workload timings, third-party drivers, vendor support,
additional SQL features and other storage layouts require site-specific validation.

A newer security target may require the operator to supply its exact official Microsoft
EXE URL and published SHA256, if available. Unsupported/malformed catalog metadata
fails closed. SQL sources other than English 1033 are explicitly not qualified.

Validation-cache reuse compares protected manifest hashes and current file metadata,
not repeated full-file hashing; deliberately altered content with preserved metadata
is outside the cache threat model. Keep runtime/backups protected. Invalidate the
record deliberately when independent fresh verification is required.
