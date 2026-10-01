# Validation record - v0.4.0-rc2

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
- Initial Microsoft SQL 2022 ENU media inspection extracted it in a host temporary
  folder: Authenticode valid; SQL 2022 Express 16.0.1000.6 metadata; numeric LCID 1033;
  extracted language XML and x64 engine MSI template validated. Numeric LCID avoids
  localized Windows language-name strings. That host-only inspection did not launch
  SQL installation; the later isolated guest rehearsal is recorded below.
- Read-only live Microsoft metadata: CU27 KB5104824 16.0.4295.3 and security rows parsed;
  parser ordered the newest CU-branch servicing target correctly. This snapshot is not
  hard-coded as a permanent latest build. Discovery runs again when patching is requested.
- Release builder parses allowlisted scripts, runs isolated suites in Windows PowerShell
  5.1, builds ZIP/SHA256 metadata and compares every file after archive extraction.

## Scope

No production connection, upgrade, patch, restart or recovery was performed.
The following real lab checks supersede rc1's fixture-only installer qualification.
Media-download orchestration on German Windows was fixture-tested; the original
production locale was not reproduced live.

## Real Hyper-V rehearsal - 2026-10-01

The preserved SQL 2017 guest was already network-disconnected. The main SQL 2022
guest and domain controller were not upgraded or rolled back. Credentials, raw
logs, media, backups and recovery artifacts remain outside Git.

- Windows PowerShell 5.1; named SQLEXPRESS instance; source 14.0.1000.169, English
  SQL on Windows Server 2022. Automatic local discovery and real Prepare passed.
- Actual menu: capacity/custom-folder selection, SQL service-SID ACL, COPY_ONLY /
  CHECKSUM backups, VERIFYONLY, final readiness/cache reuse, recovery text and
  instance-specific scripts, full scratch restore and CHECKDB passed.
- Microsoft engine upgrade completed with exit 0 to 16.0.1000.6. The test harness
  invoked unattended Setup separately; the product menu remains an interactive
  Wizard launcher. Session-0 launch refusal and pre-reboot Verify refusal passed.
  After an actual reboot, quick Verify and original row/checksum comparison passed.
- First real menu 8 failed before patch installation: SQL Setup rejected NORESTART
  with 0x84b40003 (-2068578301). Failure state/logs were retained. The unsupported
  switch was removed and regression coverage now checks the supported argument set.
- Fixed menu 8 installed Microsoft-signed CU27 KB5104824, build 16.0.4295.3, exit 0.
  Original SQL 2017 backup manifest remained unchanged and a separate SQL 2022 set
  was created. Windows did not restart automatically. A further real reboot and
  explicit menu 5 marked the patch Verified; no patch was repeated.
- The offline guest used freshly fetched official Microsoft catalog HTML and a
  pre-staged official CU. Only HTTP catalog responses were replayed. SQL calls,
  signature/Defender checks, installer execution and durable state were real;
  this is not an end-to-end network download test from the isolated guest.
- Real menu 9 full CHECKDB, menu 10 backup registration, menu 12 explicit user-only
  compatibility 140-to-160, subsequent Verify and completion summary passed.
  Original two application rows/checksum remained identical; a synthetic write was
  added deliberately for recovery to discard. Vendor application acceptance is
  not inferred from this small demonstration database.
- A fresh offline checkpoint was independently exported. Importing that export as
  a new VM identity with its network disconnected booted successfully on SQL 2017;
  original rows/checksum and all four generated rollback CHECKDB checks passed.
  This proves this Hyper-V export recovery, not Azure Backup or domain trust.
- Native Hyper-V commands restored the recorded checkpoint to the original guest;
  SQL 2017, original rows/checksum and the generated guest CHECKDB verifier passed.
  The deliberate post-upgrade test write was discarded. The first host-wrapper UAC
  launch was canceled. After the user confirmed a retry, the actual generated
  Restore-HyperV.ps1 ran in elevated Windows PowerShell 5.1, restored the recorded
  checkpoint and passed the recovered guest verifier again. Its administrator
  requirement was retained. Capture was performed explicitly before testing because
  existing checkpoints require review; the helper's fresh Capture branch was not
  re-qualified here.
- The published rc1 installer was executed on the main lab guest with NoLaunch,
  including GitHub ZIP digest validation and a second existing-folder invocation.
  Its existing SQL/runtime were not changed.

## Remaining limits

The visible Wizard click-through was not exercised: the isolated guest had no
interactive user session. Domain trust after recovery was not probed because the
recovered copies stayed disconnected. Azure Backup, vendor application acceptance,
large workload timings, third-party drivers, additional SQL features and other
storage layouts require site-specific validation. The release remains a candidate.

A newer security target may require the operator to supply its exact official Microsoft
EXE URL and published SHA256, if available. Unsupported/malformed catalog metadata
fails closed. SQL sources other than English 1033 are explicitly not qualified.

Validation-cache reuse compares protected manifest hashes and current file metadata,
not repeated full-file hashing; deliberately altered content with preserved metadata
is outside the cache threat model. Keep runtime/backups protected. Invalidate the
record deliberately when independent fresh verification is required.
