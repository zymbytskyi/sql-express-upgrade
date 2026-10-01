# v0.3.x migration and runtime preservation

1. Finish any active SQL Setup. Close the old menu. Copy the protected runtime
   directory and original backup manifests off-server before changing tools.
2. Install v0.4.0-rc1 into its new package directory; leave the v0.3.x package intact.
   Open it on the SAME server and instance with the existing WorkRoot. Schema-1 plan
   identity, source baseline and boot state remain supported; no campaign reset occurs.
3. Existing plans/media remain. Preparation validates actual metadata; rejected or
   incomplete downloaded/extracted artifacts are moved to unique `.rejected-*` paths.
   Valid backups/media are not deleted to make a retry work. Never rename DEU to ENU.
4. Old `rehearsal.json` is historical evidence, not silently trusted as a v0.4 cache.
   Menu 3 builds new mode-bound evidence. New full backups save VERIFYONLY evidence
   immediately; subsequent menu 3/4 reuse it when inputs match. Menu 4 will not run a
   surprise expensive revalidation: an invalidated cache directs you to menu 3.
5. `backups.json` remains the pre-upgrade SQL 2017 manifest. SQL 2022 backups use
   `backups-2022.json`; each newly recorded set also has a unique BackupSets manifest.
   Original files stay at their paths. Use menu 2 to choose an approved post-upgrade
   folder; the previous directory is retained as PreUpgradeBackupDirectory metadata.
6. If SQL is ALREADY 2022, do not run source preparation/upgrade again. With the existing
   plan, use menu 8 to discover/approve the installed or newer servicing target, then
   menu 5. A target already met does not install again. Any required restart is gated.
7. If user database levels were already intentionally changed to 160 outside v0.3.x,
   menu 14 explicitly registers application/vendor approval of those existing changes.
   It does not execute ALTER. Then menu 5 can compare against approved levels correctly.
   New compatibility changes use menu 12 only after verified patching. Original source
   baseline stays intact; approved changes and revert commands are separate records.
8. If backups were created manually, menu 10 accepts one full CHECKSUM backup per
   current database, checks the recorded source server/instance/database/major version,
   runs VERIFYONLY and records hashes without rewriting the backups. Files with multiple
   appended sets, mismatched identity or missing checksums fail explicitly. Header identity
   is not a substitute for a rehearsed disaster recovery or source certificate handling.
9. Use menu 11 to record the actual external recovery provider. Earlier Hyper-V recovery
   artifacts remain valuable but do not prove Azure/VMware recovery. Never delete them
   merely because generated guidance changed.

Pending patch state Installing, RestartRequired or RestartInitiated never auto-retries.
Review Setup logs and run explicit verification after the required restart. If a process
was interrupted before durable completion state, inspect logs/build with the operator;
do not hand-edit state to claim success. Retain the pending compatibility journal if
ALTER succeeded but writing approval failed; menu 14 can register reviewed existing 160.

A brand-new campaign still requires a qualified SQL 2017 Express source. This release
is not a general adoption tool for an unrelated SQL 2022 installation without its plan.
