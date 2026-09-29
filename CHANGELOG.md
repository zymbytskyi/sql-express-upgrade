# Changelog

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
