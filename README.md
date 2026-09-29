# SQL Express 2017 to 2022 — local upgrade toolkit

Run this package **on the Windows server that hosts SQL Express**, in elevated
64-bit Windows PowerShell. No Hyper-V module, VM name, remote computer name,
WinRM endpoint or separate credentials are needed for the normal workflow.
All scripts, prompts and documentation are English.

Release 0.2.1 adds visible results and a manual wizard. For migration from the host-oriented 0.1.0 menu, start a new local runtime
folder; do not reuse a host campaign.json. Existing 0.1.0 recovery images remain
valuable and must not be deleted just because the package changed.

## Install with PowerShell

Open Windows PowerShell **as administrator inside the SQL server**:

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -le 5) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$installer = Join-Path $env:TEMP 'Install-SqlExpressUpgrade-v0.2.1.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-express-upgrade/v0.2.1/Install.ps1' -OutFile $installer -UseBasicParsing
Unblock-File -LiteralPath $installer
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& $installer
```

The installer downloads the versioned release ZIP, verifies its GitHub-published
SHA-256 digest, extracts into `C:\Tools\SqlExpressUpgrade-v0.2.1` and opens the
local menu. It never starts a SQL upgrade on installation. Existing destination
folders are not overwritten. No password or SQL authentication prompt is used:
the signed-in Windows account must be local administrator and SQL sysadmin.

Reopen after signing in or after a restart:

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& C:\Tools\SqlExpressUpgrade-v0.2.1\Start-SqlExpressUpgradeMenu.ps1
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

## Manual upgrade day

Every menu action prints START and SUCCESS/FAILED, then waits for Enter before
returning to the menu. Media verification prints progress counts. The full menu
session is saved to `Menu-*.log` in the runtime folder. Item 4 also prints which
backup is being restored; its evidence is `rehearsal.json`. Item 5 prints and
saves `RECOVERY.md` without upgrading anything.

1. Stop application writers and verify external full-server recovery.
2. Run menu 2, then menu 3 for fresh backups and menu 4 for restore rehearsal.
3. Choose **6 Open SQL Setup Wizard**. It validates prepared media and opens
   interactive SQL Setup for the detected instance. It does not run quiet Setup,
   accept the license, click Upgrade, or restart the server. Use an interactive
   desktop/RDP PowerShell window; Session 0 launch is blocked.
4. Follow `MANUAL-UPGRADE.md`, printed and saved in the runtime folder:
   - If Installation Center appears: **Installation > Upgrade from a previous
     version of SQL Server**.
   - Confirm SQL Server 2022 Express, review and accept license terms yourself.
   - Leave Product Updates disabled for the prepared media; resolve failed rules.
   - **Select Instance**: choose the detected existing SQL 2017 instance.
     Do not choose a new installation.
   - Review features, instance configuration and Upgrade Rules.
   - At **Ready to Upgrade**, check the target and click **Upgrade** yourself.
   - Wait for **Complete**, confirm every feature succeeded, save logs and close
     Setup. Canceling before clicking Upgrade leaves SQL unchanged. If Setup has already modified components, inspect its logs before deciding whether to retry or recover.
5. Restart Windows manually after successful Setup. Optional menu 8 asks for
   `RESTART` and checks that SQL 2022 is installed and Setup is closed.
6. Sign in, reopen the menu, choose **7 Verify**. It checks the actual local SQL
   build and works after manual wizard completion; it does not require a recorded
   unattended Setup exit code. SQL 2017 is rejected immediately. If the wizard
   was launched here, the boot timestamp must change before acceptance.
7. Test application login, reads/writes, integrations and performance before
   reopening normal traffic.

No upgrade or reboot runs automatically in this release. The old unattended
`-ConfirmDowntime`, `-RecoveryReference` and `-NoRestart` parameters were removed.
`-Mode Upgrade` now opens the interactive wizard. `-Mode Verify` verifies the
manually upgraded instance. The normal menu never requests a VM or remote host.

Setup logs: `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log`.
Runtime: `C:\SqlExpressUpgradeData`. Keep the existing 0.2.0 plan/media/backups
when installing 0.2.1 into its new package folder; do not repeat Configure.
A failed Setup requires diagnosis or external recovery, not a blind retry.

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
# Opens the interactive wizard; complete Setup yourself:
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Upgrade
# Reopen after restart, or explicitly verify:
.\Start-SqlExpressUpgradeMenu.ps1 -Mode Verify
```

## Validation and servicing

See CHANGELOG.md for the release's actual lab evidence. Run `Test-Safety.ps1`
for isolated source/discovery guards; it neither upgrades SQL nor needs Hyper-V.
The prepared target media is SQL 2022 RTM 16.0.1000.6. A current approved CU/security
update and application-specific acceptance are required before production use.
The package does not silently select or install a CU during downtime.

## Microsoft references

- [SQL 2022 upgrade paths](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/supported-version-and-edition-upgrades-2022?view=sql-server-ver16)
- [SQL backup version restrictions](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/backup-restore/backup-restore-operations)
