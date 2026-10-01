# Changelog

## 0.4.0-rc1 - 2026-10-01

- Respond to production findings: SQL-language-aware signed media reuse/retry/fallback, numeric language and extracted x64 metadata validation; no language-renaming workaround.
- Separate backup prerequisites from upgrade restart gates. Show pending operations and likely source without clearing them.
- Default COPY_ONLY/CHECKSUM + VERIFYONLY; full restore/CHECKDB is optional, explained and isolated. Cache mode/plan/instance/manifest/hash/config evidence; launcher never surprises operators with a repeated full rehearsal.
- Add manual Setup command/current-stage output, fast post-upgrade verification and separate full CHECKDB.
- Integrate pinned MIT-licensed self-patch helpers with live CU/security target review, selected-instance patching, optional backups, progress, explicit restart and durable post-restart verification.
- Add explicit user-database compatibility 160 approval/revert records, migration approval for existing changes, manual-backup registration and completion summary.
- Preserve SQL 2017 manifests/sets; recognizable safe filenames; no Express native compression; provider-neutral recovery including external Azure Backup references.
- Add fixture suites and allowlisted release/integrity build. See VALIDATION.md for exact evidence and limits; no production upgrade, patch, restart or recovery executed for this release candidate.

## Documentation review - 2026-09-29 (v0.3.1 unchanged)

- Added PRODUCTION-RUNBOOK.md: pinned installer, real-server preparation, GUI upgrade, explicit GO/NO-GO, external recovery, SQL servicing and application acceptance.
- Closed the pending new-folder check with a live isolated lab test under Dex: actual SQL size/volume checks, new service-SID folder ACL, ExpressUpgradeDemo COPY_ONLY/CHECKSUM backup and VERIFYONLY passed. Current SQL is 2022 16.0.1000.6 after the user's upgrade; no new upgrade, reboot or VM restore was run.
- Repeated safety/discovery, guidance and menu tests passed. A full v0.3.1 SQL 2017 production workflow, large datasets, mounted storage and independent export-import recovery remain unverified.
- Executable release v0.3.1 and its pinned hashes remain unchanged. This runbook is maintained in the repository main branch; the existing release ZIP predates this documentation update.

## 0.3.1 - 2026-09-29

- Generate UPGRADE-PLAN.txt and ROLLBACK-PLAN.txt with target-specific paths, step-by-step GUI/actions, script purpose/execution location and recovery acceptance.
- Menu 2 recommends a local backup folder using live SQL sizes and volume capacity, accepts a custom path, preserves old backups and scopes new-folder permissions to the selected SQL service.
- Final readiness records backup set age, actual file paths/sizes and a technical result in FINAL-READINESS.txt; checks all backup hashes/scope and reports failures explicitly.
- Isolated guidance tests cover disk ranking/insufficient space, custom-folder selection, document content, old/missing/modified backups and readiness results. Existing safety/menu tests pass. No active lab VM, Setup, reboot or recovery was touched; live new-folder SQL write validation remains pending.

## 0.3.0 - 2026-09-29

- Simplified menu to Prepare, Backups, Final readiness check, Upgrade Wizard, Verify and Rollback plan.
- Final readiness includes a real user-database restore rehearsal; wizard launch repeats it.
- Generate per-instance recovery target metadata, host capture/restore wrappers with explicit identity/data-loss confirmation, and local original-build/database integrity verification.
- Repeated installation opens the existing versioned menu. Existing preparation is retained.
- Lab: preparation, fresh backups, final readiness and generated rollback verification passed on SQL 2017. SQL 2022 acceptance is rejected while still on 2017. Wizard launch is mocked; no new upgrade, VM restore or reboot performed.

## 0.2.1 - 2026-09-29

- Display timestamped START/SUCCESS/FAILED, elapsed time, a result pause and per-session transcripts for menu actions; show media hash and restore progress.
- Menu 6 opens only the interactive Upgrade wizard, prints/saves selected-instance instructions, and never runs silent Setup or automatically restarts.
- Verify now inspects the actual SQL build after a manual wizard upgrade; rejects SQL 2017 immediately and preserves the reboot gate. Restart remains explicitly confirmed.
- Existing v0.2.0 plan/media/backups are reused unchanged. Install the new package in its own versioned directory.
- Live SQLEXPRESS17 menu tests passed for 2 (Preflight), 4 (actual restore and CHECKDB) and 5 (Recovery plan); 7 correctly rejected the unchanged SQL 2017 instance.
- Wizard launch parameters tested with a mocked process launcher; no new SQL upgrade was performed for this UI fix.

## 0.2.0 - 2026-09-29

- Local-server entry point: no VM/server-name or credential prompts, no Hyper-V dependency.
- Automatic default/custom named Express discovery and SQL backup-directory detection; explicit selection only for multiple eligible local instances.
- One-step prepare/download/configure, fresh pre-upgrade backups/rehearsal, local Setup, durable state and reboot-aware verification when reopened.
- English-only installer, scripts, menu and documentation. Versioned PowerShell installer verifies the release ZIP digest.
- Separate optional infrastructure recovery helper; local menu generates a recovery plan and requires an operator-attested full-server recovery reference.
- Validation: 13 source safety checks and eight discovery/selection cases passed. A real named-instance lab run completed automatic local preparation/download, backup/restore rehearsal, upgrade 14.0.1000.169 to 16.0.1000.6, blocked verification before reboot, automatic menu verification after reboot, reads/writes, and full-server recovery to 14.0.1000.169 with original rows/checksum and domain trust. Default/custom/multiple instance selection was additionally tested with isolated fixtures; a separate real default-instance upgrade was not performed.

## 0.1.0 - 2026-09-28

- Initial Hyper-V host-oriented preparation/upgrade/rollback toolkit.
- Lab passed 14.0.1000.169 -> 16.0.1000.6 -> 14.0.1000.169 with synthetic reads/writes and domain trust.
