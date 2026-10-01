# Operator runbook - v0.4.0-rc1

This is a release candidate validated with isolated orchestration tests. Do not treat
mocked installer tests as a production patch/upgrade acceptance. Start on a restored
non-production copy. See VALIDATION.md for evidence and remaining limits.

## Preparation day

1. Connect to the SQL server using Remote Desktop (`mstsc`) or your verified VM console.
   Sign in with authorized local administrator and SQL sysadmin rights. Open 64-bit
   Windows PowerShell 5.1 as Administrator and use the README installer block.
2. Confirm the displayed computer and selected instance. Menu 1 creates the plan,
   validates SQL-source language, prepares signed media and writes UPGRADE-PLAN.txt.
   German Windows with English SQL is supported. Non-English SQL sources are not qualified.
3. Read the pending restart details. Edge file renames are shown with a likely-source
   label; they are never cleared. You can still use menu 2 for backups, but plan a
   restart before upgrade. Microsoft Setup reboot rules remain in force.
4. Menu 2 lists storage and proposes a dedicated folder. Override with a full local
   path if required. Review physical storage/I/O policy; most free space does not mean
   an independent backup. COPY_ONLY/CHECKSUM + VERIFYONLY runs without compression,
   scratch restore or CHECKDB. Every new backup set is retained.
5. Menu 3 runs current upgrade checks and reuses matching expensive verification.
   Open FINAL-READINESS.txt and inspect backup age/files and verification mode.
   Choose menu 7 only if you want a full user-database restore rehearsal. It explains
   disk allocation and workload before confirmation. Menu 9 is optional full CHECKDB.
6. Menu 11 records external recovery provider/reference/procedure. Menu 6 prints and
   saves ROLLBACK-PLAN.txt. Copy the whole protected runtime and SQL backups off-server.
   Use the actual provider's tested VM recovery procedure, including Azure Backup if
   applicable. Hyper-V helpers are optional and run only on the Hyper-V HOST.
7. For preparation-only testing, exit here. Capture timing/capacity and application
   compatibility findings before approving downtime.

## Upgrade window

1. Confirm application/vendor SQL 2022 support, the maintenance owner, stop/start steps,
   rollback deadline, approved servicing target and a tested full-server recovery point.
2. Stop application writers using the agreed procedure; this package does not guess
   or stop application services. Take final backups, copy them off-server and keep
   writers stopped through acceptance. Old backup age alone cannot prove completeness.
3. Resolve pending restart; rerun menu 3. Menu 4 displays the exact setup.exe path and
   a copyable interactive command. Its current checks reuse cached expensive evidence.
   An existing Setup session blocks another launch. Invalid evidence requests menu 3.
4. In the wizard, select Installation > Upgrade from a previous version when needed.
   Select the EXISTING intended instance, review rules/features and Ready to Upgrade,
   then click Upgrade yourself. Save Summary/Detail logs at Complete.
5. Manual fallback runs Microsoft's Setup checks, not the package's backup/recovery
   evidence checks. Complete menu 3 before using it. `/UPDATEENABLED=False` is explicit:
   base Setup does not service itself. Microsoft Update checkbox controls future scans,
   whereas Include SQL Server product updates controls the current Setup operation.
6. Close Setup, restart Windows, reopen the same package/runtime and run menu 5. This
   quick check does not run CHECKDB and does not mark RTM as fully serviced.

## Servicing and acceptance

1. Menu 8 shows installed build, latest Microsoft CU and security release rows, plus
   an explicit recommended CU-branch build/KB/source. Review vendor compatibility and
   approve the target. If it is already installed, no installer is rerun; choose 5.
2. Review MSDB backup history. Choose 0 no new backups, 1 system databases, or 2 system
   and user databases except tempdb. New SQL 2022 backups never replace the SQL 2017
   recovery set. Use a dedicated post-upgrade folder if required.
3. The latest CU downloads from Microsoft. If the current target is a newer security
   package, supply its exact official x64 EXE URL from that KB. Signature and expected
   build are checked. Paste Microsoft's published SHA256 when available. Read the
   displayed local hash; it alone is not publisher validation.
4. Confirm PATCH only after stopping writers and qualifying recovery. The package
   targets `/instancename=...`, never `/AllInstances`; shared components may change.
   Quiet installation shows elapsed time, process IDs and Setup log locations.
5. A failure retains state/logs. Success and restart-required exits are distinct.
   Restart only by explicit confirmation; later use menu 5 for post-restart verification.
   Installation is never automatically repeated on reopening the menu.
6. Optionally use menu 12 for selected USER database compatibility 160 only after
   patching/required restart/technical verification. Confirm application/vendor support.
   Retain old/new levels and copyable revert commands. No system database is altered.
7. The application owner must test login, representative data, reads/writes, integrations
   and performance. Quick SQL verification is not application acceptance. Menu 13 writes
   a completion summary; retain it internally with Setup logs and recovery references.

## Recovery and troubleshooting

- Pending reboot: inspect the displayed CBS/Windows Update/file-operation entries;
  restart during the approved window and recheck. Do not delete registry entries.
- Language/media error: read expected vs detected metadata, rerun Prepare. Wrong files
  remain in unique rejected/download folders; never rename a German package to ENU.
- Backup access/capacity error: select an approved dedicated local folder. New folders
  grant the SQL service SID Modify only there; existing folder ACLs stay unchanged.
  Do not grant Everyone or alter drive-root ACLs. No scratch reserve is needed for VERIFYONLY.
- Changed validation input: menu 4 explains invalidation and stops; use menu 3 to validate.
- Failed scratch restore: retain its uniquely named UpgradeRehearsal database/files,
  inspect errors and drop only that owned test database after diagnosis.
- Failed Setup/patch: retain logs, keep writers stopped and decide recovery before the
  agreed deadline. The external provider restores the full VM; all later changes are
  lost. Preserve later business writes before approving that loss.
- SQL 2022 backups cannot restore onto SQL 2017; keep original pre-upgrade backups.
  There is no in-place downgrade. After external recovery verify original build,
  database integrity, logins, representative data and domain trust before traffic.

## References

- [Microsoft supported SQL 2022 upgrade paths](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/supported-version-and-edition-upgrades-2022?view=sql-server-ver16)
- [SQL 2022 build and security release table](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions)
- [Microsoft SQL 2022 CU download](https://www.microsoft.com/en-us/download/details.aspx?id=105013)
- [Reused self-patch source](https://github.com/zymbytskyi/sql-server-2022-express-self-patch/tree/c528b6d1e17bf3621549ac73e3685fb7cd1b1062)
