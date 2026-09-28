# SQL Express 2017 to 2022 on Hyper-V

**Status: core workflow validated in the Hyper-V lab on 2026-09-28; public GitHub release 0.1.0.**
Production use requires target-specific application acceptance and an approved current SQL 2022 servicing level. The tested target media is RTM 16.0.1000.6.

The package separates preparation from downtime. Run the numbered menu on the
Hyper-V host as an administrator. Supply a guest Windows administrator who is
also SQL sysadmin. Credentials are used in memory through PowerShell Direct
or an existing WinRM HTTPS endpoint with a pinned certificate;
they are not saved in a plan or log.

```powershell
.\Start-SqlExpressUpgradeMenu.ps1
```

Use a runtime campaign directory outside the downloaded source, for example
`D:\SqlUpgradeCampaigns\Express2017-2022`. Restrict that directory and the guest
backup directory to the operators and required service identities: the recovery
export contains the entire VM, including its protected configuration.

## Supported first scope

- One dedicated Generation 2 Hyper-V VM with one English x64 standalone SQL
  Server 2017 Express Database Engine instance; target SQL Server 2022 Express.
- Windows Server 2016, 2019 or 2022; the lab uses Server 2022 Evaluation.
- Windows authentication, local NTFS/ReFS database/backup/media paths and
  ordinary database data/log files. Existing SQL service backup permissions.
- No domain controllers, HA/WSFC/FCI/AG, replication, encrypted databases,
  database snapshots, full-text/Advanced Services, pass-through disks or
  pre-existing Hyper-V checkpoints.
- Year 2017 means engine **14.x**; year 2022 means **16.x**. Engine **17.x** is
  SQL Server 2025 and is explicitly rejected as an upgrade source.

The configured media build is frozen for a campaign. Setup runs offline with
updates disabled. A current SQL 2022 CU/security update needs its own reviewed
media and acceptance before production; this package does not silently download
or choose a CU during downtime.

Menu Configure saves the selected transport. HTTPS uses port 5986 and requires
an exact certificate thumbprint obtained through a trusted channel. The package
does not create listeners, open firewalls or change host TrustedHosts. Any
temporary lab endpoint must be explicitly authorized and removed after testing.

## Preparation day

1. Configure the exact VM, instance, runtime directory and guest backup path.
   The saved campaign binds to the VM GUID as well as its name.
2. Menu Download uses the current version-specific Microsoft SQL 2022 Express bootstrapper, or
   provide an existing full `SQLEXPR_x64_ENU.exe`. Download accepts only the
   Microsoft HTTPS host and verifies its signature and engine major version.
   The default bootstrapper URL and full download were tested on 2026-09-28; older 16.2211 bootstrapper versions are rejected by Microsoft. An explicit `-BootstrapperUri` or `-BootstrapperPath` can replace it after review. Evergreen links may point to SQL 2025; they are not accepted.
3. Deploy the worker and full media to the guest. Configure checks the actual
   SQL build, edition, language, instance count, OS and database features.
4. Prepare extracts the offline media and records SHA-256 for every file.
5. Preflight repeats live SQL identity, database scope, pending reboot, .NET,
   service, media and capacity checks. Space demands are summed per volume
   when system, staging and backup directories share a disk. Backup capacity
   uses allocated database size plus headroom, without assuming compression.
6. Backup runs CHECKDB, then COPY_ONLY/CHECKSUM full backups and VERIFYONLY for
   `master`, `model`, `msdb` and all user databases. Failed SQL write permission
   is discovered here, before the upgrade day.
7. Restore rehearsal restores each user backup under a unique temporary name,
   runs CHECKDB and drops only that temporary database. A failed restore is
   retained for investigation. System database recovery uses the full VM image;
   system backups are not restored over the running instance.

Retain the campaign, media, SQL backups and reports. Verify application/client
compatibility using a representative test copy and application owner tests.
VERIFYONLY alone is not a restore test. A database CHECKDB pass is not proof of
application compatibility, login equivalence or acceptable query performance.

## Upgrade day

1. Stop application services, scheduled tasks and all external writers.
   Prevent automatic application restart. The package does **not** discover or
   stop arbitrary applications; this is an explicit operator prerequisite.
2. Run menu 8. It repeats preflight, makes fresh backups and rehearses their
   restore, then gracefully shuts down the VM. While OFF it creates a recovery
   checkpoint and independent full snapshot export, hashing the exported files.
   It starts the VM afterward. Keep application writes stopped.
3. Run menu 9 within two hours. It verifies the recovery point and export,
   repeats guest preflight and starts `/ACTION=Upgrade` for the saved instance.
   Exit 0/3010 is followed by a graceful restart and database verification.
   A failed/interrupted Setup is never automatically retried or rolled back.
4. Run menu 10 if post-restart verification needs to be resumed. Two consecutive
   SQL probes, ONLINE databases, unchanged user compatibility levels and
   CHECKDB are required. Review SQL Setup logs under
   `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log`.
5. Check application login, a representative read/write transaction, scheduled
   work and performance against the baseline. Decide acceptance or rollback
   **before enabling general application writes**.

No script deletes recovery points or backups. Remove them only after explicit
acceptance and according to retention/capacity policy. Checkpoints consume host
space while retained; monitor both host storage and guest volumes.

## Rollback

Run menu 11 with application writers stopped. Confirm the exact VM name and
loss of **all** changes after capture. The script gracefully stops the VM,
restores only the recorded checkpoint GUID, starts it, verifies the original
SQL 2017 build and checks domain trust. It never restores a SQL 2022 backup into
SQL 2017 and never attempts an in-place downgrade.

RPO is the cold recovery capture. All later SQL and non-SQL VM changes are lost.
If application writes resumed, stop and explicitly decide how to preserve or
reconcile those writes before rollback; automatic reverse data migration is not
provided. Measure RTO during the lab drill rather than assuming a duration.

If the checkpoint is missing, the rollback script stops. The independent export
is retained for host disaster recovery: validate its recorded hashes, ensure
the original VM is OFF, import the exported `.vmcx` as a copy into separate
storage, keep its NIC disconnected until identity is verified, then reconnect
only the chosen recovery VM. This emergency export-import path is a separate
acceptance test; do not run two copies with the same machine/domain identity.

## Automation interface

Use `Invoke-HyperVSqlExpressUpgrade.ps1` with the same `-VMName`, `-WorkRoot`
and in-memory `-Credential`. Modes match the menu:

```powershell
$credential = Get-Credential
$campaign = @{
    VMName = 'SQLEXPRESS17'
    WorkRoot = 'D:\SqlUpgradeCampaigns\Express2017-2022'
    Credential = $credential
}
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Configure
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Deploy -MediaPath 'D:\Media\SQLEXPR_x64_ENU.exe'
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Prepare
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Preflight
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Backup
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Rehearse
# After stopping all writers:
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Capture -ConfirmDowntime
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Upgrade -ConfirmDowntime
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Verify
# Only if the decision is to discard every change after capture:
.\Invoke-HyperVSqlExpressUpgrade.ps1 @campaign -Mode Rollback -ConfirmDowntime -ConfirmDiscardChanges
```

## Acceptance record

- [x] Thirteen isolated safety assertions for wrong version/edition/host,
  missing privilege, HA, database state/features, size ceiling and SQL escaping.
- [x] Domain-joined dedicated lab VM, SQL 2017 Express 14.0.1000.169 and two baseline rows verified on 2026-09-28. Temporary HTTPS listener, host-only rule, certificate and private answer media removed.
- [x] Controller preparation and full media download; extra-media-file rejection; actual guest capacity guard; injected pending-reboot signal (no registry mutation).
- [ ] Interactive numbered-menu walkthrough (controller modes tested directly).
- [x] Real backup, VERIFYONLY, scratch restore and CHECKDB (four databases).
- [x] Offline 14.0.1000.169 to 16.0.1000.6 upgrade and graceful restart.
- [x] Synthetic read/write probe, row checksum and database compatibility comparison.
- [x] Full-VM checkpoint rollback to 14.0.1000.169, original two rows/checksum and domain trust. The post-upgrade inserted row was discarded. SQL access was revalidated; a complete login inventory comparison was not performed.
- [ ] Optional host-disaster export-import drill and measured RTO (independent export created and hash-validated; checkpoint rollback tested).
Public source package: https://github.com/zymbytskyi/sql-express-upgrade (no lab credentials, media or runtime data).

## Microsoft references

- [Supported SQL 2022 upgrade paths](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/supported-version-and-edition-upgrades-2022?view=sql-server-ver16)
- [SQL 2017 operating system requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2017?view=sql-server-ver17)
- [SQL backup/restore version restrictions](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/backup-restore/backup-restore-operations)
