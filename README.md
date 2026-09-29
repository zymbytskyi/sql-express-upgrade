# SQL Express 2017 to 2022 — local upgrade toolkit

Run this package **on the Windows server that hosts SQL Express**, in elevated
64-bit Windows PowerShell. No Hyper-V module, VM name, remote computer name,
WinRM endpoint or separate credentials are needed for the normal workflow.
All scripts, prompts and documentation are English.

Release 0.2.0 replaces the host-oriented 0.1.0 menu. Start a new local runtime
folder; do not reuse a host campaign.json. Existing 0.1.0 recovery images remain
valuable and must not be deleted just because the package changed.

## Install with PowerShell

Open Windows PowerShell **as administrator inside the SQL server**:

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -le 5) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$installer = Join-Path $env:TEMP 'Install-SqlExpressUpgrade-v0.2.0.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-express-upgrade/v0.2.0/Install.ps1' -OutFile $installer -UseBasicParsing
Unblock-File -LiteralPath $installer
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& $installer
```

The installer downloads the versioned release ZIP, verifies its GitHub-published
SHA-256 digest, extracts into `C:\Tools\SqlExpressUpgrade-v0.2.0` and opens the
local menu. It never starts a SQL upgrade on installation. Existing destination
folders are not overwritten. No password or SQL authentication prompt is used:
the signed-in Windows account must be local administrator and SQL sysadmin.

Reopen after signing in or after a restart:

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& C:\Tools\SqlExpressUpgrade-v0.2.0\Start-SqlExpressUpgradeMenu.ps1
```

## Detection and defaults

- Reads the local 64-bit SQL instance registry and Windows services.
- One running SQL 2017 Express instance is selected automatically. Supports
  `MSSQLSERVER`, `SQLEXPRESS` and custom named instances.
- Multiple eligible instances produce a numbered choice, never a guessed target.
  Only the selected instance is upgraded. Shared components and full-server
  recovery can affect every instance; coordinate the whole server maintenance.
- Live SQL identity, edition, version and sysadmin membership are checked before
  preparing. SQL uses local shared-memory connections (`lpc:`), not TCP aliases.
- Discovers the selected instance's configured backup directory automatically.
  It must exist, be local and permit SQL service writes. The real backup test
  verifies this before the maintenance day.
- Default runtime folder: `C:\SqlExpressUpgradeData`. Plans, downloads, hashes,
  backups metadata and state are stored outside the source package. SQL backups
  remain in the SQL backup directory. Protect runtime/backups with operator and
  required service access, and copy recovery material off the server.
- Plans bind to the local computer/instance; workflow state also binds to its
  Windows machine GUID. A mutex prevents concurrent sessions for one instance.

## Preparation day

1. **Prepare**: discover/select the local instance, find its backup directory,
   download signed SQL 2022 Express media, configure a local plan, extract the
   media, record SHA-256 hashes, then run preflight. Preparation can be rerun
   after a pending reboot; completed media is validated instead of redownloaded.
2. **Preflight**: verify SQL identity/build, database scope, .NET, pending reboot,
   SQL service, media integrity and per-volume disk headroom.
3. **Backup**: CHECKDB and COPY_ONLY/CHECKSUM backups of master/model/msdb and user
   databases, followed by VERIFYONLY. New backups invalidate old rehearsal evidence.
4. **Restore rehearsal**: restore user backups into unique temporary databases,
   run CHECKDB and drop only those test databases. Failed restores are retained.
5. **Recovery plan**: generate `RECOVERY.md` for this local server. Have the
   infrastructure/backup owner capture and verify full-server recovery after
   application writers stop. Keep its exact reference and restoration procedure.

The package supports English x64 standalone SQL 2017 Express Database Engine on
Windows Server 2016/2019/2022 and corresponding supported Windows 10 builds.
It blocks HA/WSFC/FCI/AG, replication, encrypted databases, snapshots,
full-text/Advanced Services, offline databases and databases at the Express size
ceiling. This is local automation across supported installations, not a claim
that every SQL feature or operating system is supported.

## Upgrade day

Stop all application services, integrations, schedulers and other writers; keep
them stopped until acceptance or rollback. Automatic discovery/stopping of
arbitrary applications is intentionally not performed.

Choose **6 Upgrade**, enter the externally verified full-server recovery
reference, then type `UPGRADE`. The reference is an operator attestation: this
local script cannot validate a hypervisor or backup-provider recovery image.
It repeats preflight, creates fresh SQL backups, rehearses their restore, and
runs local Setup with `/ACTION=Upgrade` for the detected instance. Updates are
disabled so the prepared media remains fixed. Setup result/state is saved before
restart. No failed or interrupted Setup is blindly retried.

On success, the server restarts after 15 seconds. Sign in, reopen the same menu,
and verification resumes automatically. **7 Verify** can repeat verification;
**8 Restart** is available when Setup succeeded but restart is still pending.
The boot timestamp must change before verification can accept a successful Setup.

Verification checks SQL 2022 Express, ONLINE databases, unchanged user database
compatibility and CHECKDB. Application login, representative reads/writes,
integrations, scheduled work and performance still require application acceptance.
Only then reopen normal application writes.

Setup logs: `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log`.
Workflow state: `C:\SqlExpressUpgradeData\local-state.json`.
An interrupted `Upgrading`/`SetupFailed` state requires diagnosis or recovery.
No unattended startup task or saved administrator password is installed.

## Rollback boundary

There is no supported SQL 2022-to-2017 in-place downgrade. SQL 2022 backups cannot
be restored on SQL 2017. Restore the complete pre-upgrade server image using your
approved backup platform. This discards **all** server changes after capture.
A script running inside that same server cannot restore its entire running OS.

For Hyper-V, an **optional infrastructure-only** helper is supplied. It runs on
the host, requires the VM already gracefully shut down, and captures a cold
checkpoint plus independent hashed export. It never participates in local Setup:

```powershell
# Infrastructure operator, on the Hyper-V host, with the VM already OFF:
.\optional\Invoke-HyperVRecovery.ps1 -Mode Capture -VMName 'YOUR_VM' -RecoveryDirectory 'D:\Recovery\SqlUpgrade01'
# Record the returned checkpoint ID, start the VM, and use its LOCAL upgrade menu.
# If rollback is chosen, gracefully shut down the VM again, then:
.\optional\Invoke-HyperVRecovery.ps1 -Mode Restore -VMName 'YOUR_VM' -RecoveryDirectory 'D:\Recovery\SqlUpgrade01' -ConfirmDiscardChanges
```

For physical servers or other hypervisors, use the corresponding verified
full-server restore procedure. After recovery check the original build, data,
logins, application and domain access. SQL-only recovery on a rebuilt SQL 2017
server requires separately tested restoration of logins/SIDs, certificates and
server configuration; user backups alone are not complete rollback.

## Automation interface

```powershell
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Discover
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Prepare
# Optional override only when needed:
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Prepare -InstanceName APPDATA -MediaPath D:\Media\SQLEXPR_x64_ENU.exe -WorkRoot D:\UpgradeData
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Backup
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Rehearse
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Recovery
# After writers stop and infrastructure recovery has been verified:
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Upgrade -ConfirmDowntime -RecoveryReference 'Verified backup job or checkpoint ID'
# Reopen after restart, or explicitly verify:
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Verify
```

`-NoRestart` is available for controlled maintenance orchestration/testing; it
leaves `RestartRequired` and cannot bypass the actual reboot verification gate.

## Validation and servicing

See CHANGELOG.md for the release's actual lab evidence. Run `Test-Safety.ps1`
for isolated source/discovery guards; it neither upgrades SQL nor needs Hyper-V.
The prepared target media is SQL 2022 RTM 16.0.1000.6. A current approved CU/security
update and application-specific acceptance are required before production use.
The package does not silently select or install a CU during downtime.

## Microsoft references

- [SQL 2022 upgrade paths](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/supported-version-and-edition-upgrades-2022?view=sql-server-ver16)
- [SQL backup version restrictions](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/backup-restore/backup-restore-operations)
