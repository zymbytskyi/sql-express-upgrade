# SQL Express 2017 to 2022 — local upgrade toolkit

Start with the [real-server runbook](PRODUCTION-RUNBOOK.md) before production rehearsal. It includes the pinned installer, GUI steps, GO/NO-GO criteria, servicing requirements and a dated evidence matrix. Preparation-only testing stops after menus 1/2/3/6.

Run this package **on the Windows server that hosts SQL Express**, in elevated
64-bit Windows PowerShell. No Hyper-V module, VM name, remote computer name,
WinRM endpoint or separate credentials are needed for the normal workflow.
All scripts, prompts and documentation are English.

Release 0.3.1 adds visible results and a manual wizard. For migration from the host-oriented 0.1.0 menu, start a new local runtime
folder; do not reuse a host campaign.json. Existing 0.1.0 recovery images remain
valuable and must not be deleted just because the package changed.

## Install with PowerShell

Open Windows PowerShell **as administrator inside the SQL server**:

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -le 5) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$installer = Join-Path $env:TEMP 'Install-SqlExpressUpgrade-v0.3.1.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-express-upgrade/v0.3.1/Install.ps1' -OutFile $installer -UseBasicParsing
Unblock-File -LiteralPath $installer
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& $installer
```

The installer downloads the versioned release ZIP, verifies its GitHub-published
SHA-256 digest, extracts into `C:\Tools\SqlExpressUpgrade-v0.3.1` and opens the
local menu. It never starts a SQL upgrade on installation. Existing destination
folders are not overwritten; rerunning this version opens its existing menu. No password or SQL authentication prompt is used:
the signed-in Windows account must be local administrator and SQL sysadmin.

Reopen after signing in or after a restart:

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& C:\Tools\SqlExpressUpgrade-v0.3.1\Start-SqlExpressUpgradeMenu.ps1
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

## Operator documents and backup storage

Menu 1 writes `UPGRADE-PLAN.txt`: preparation-day and upgrade-window steps, the
actual server/instance, databases, media/backup paths and SQL Setup GUI actions.
Menu 6 prints and saves `ROLLBACK-PLAN.txt`: what each generated script does,
where to run it, GUI shutdown/start steps, example commands, expected results
and the consequences of recovery. Open these plain-text files in Notepad.
Both are in `C:\SqlExpressUpgradeData` (or your selected WorkRoot).

Menu 2 lists fixed NTFS/ReFS disks and free GiB, recommends the eligible disk
with the most free space and proposes a dedicated instance/campaign folder.
Press Enter or type a full local folder path. The estimate uses live allocated
SQL file sizes: 120% of total database size + largest database + 10 GiB reserve.
It does not assume backup compression. Existing backups are not deleted.
The chosen volume is rechecked, including paths on mounted volumes. The scan
lists drive-letter volumes; mounted-only volumes can be supplied by full path.
A new folder grants Modify to the selected SQL service SID only; existing folder
ACLs are preserved. SQL BACKUP failure blocks successful completion if the service
cannot write. Local staging backups still need a protected off-server copy.

Menu 3 prints and saves `FINAL-READINESS.txt`: last complete backup set time/age,
each database's actual file path/size/modified time, and technical PASS or NOT READY
with a reason. All backup hashes and database scope must match before rehearsal.
Backups over 24 hours old get a reminder to refresh; no age can prove that writers
were stopped. Technical PASS is not external recovery or application acceptance.
Do not change package/preparation during an active Setup session.

## Six-step menu

| Item | Action |
| --- | --- |
| 1 Prepare | Detect local instance; create plan; download/extract media; run preflight; generate rollback kit. |
| 2 Backups | CHECKDB, COPY_ONLY/CHECKSUM backups and VERIFYONLY. |
| 3 Final readiness check | Repeat preflight, actually restore user backups to temporary databases, CHECKDB and remove successful test restores. Refresh recovery instructions. |
| 4 Upgrade | Repeat technical readiness checks and open interactive SQL Setup Wizard. You click through Setup and restart Windows yourself. |
| 5 Verify | After Setup and restart, verify SQL 2022 and database integrity. Complete application acceptance yourself. |
| 6 Rollback plan | Display RECOVERY.md and regenerate the instance-specific Rollback folder. Does not execute recovery. |

Run 1 in advance, then 2 and 3 to rehearse. At downtime stop writers, repeat 2 and 3,
copy artifacts off-server and capture external full-server recovery before 4.
Reopen the menu after reboot and choose 5. Item 0 exits.
Every action displays START/SUCCESS/FAILED and waits for Enter. Transcripts are
saved as Menu-*.log. Technical readiness does not prove external recovery readiness.

The package supports English x64 standalone SQL 2017 Express Database Engine on
Windows Server 2016/2019/2022 and corresponding supported Windows 10 builds.
It blocks HA/WSFC/FCI/AG, replication, encrypted databases, snapshots,
full-text/Advanced Services, offline databases and databases at the Express size
ceiling. This is local automation across supported installations, not a claim
that every SQL feature or operating system is supported.

## Manual upgrade day

Choose **4 Upgrade** in an interactive desktop/RDP PowerShell window. Session 0
launch is blocked. Follow the printed and saved MANUAL-UPGRADE.md:

1. If Installation Center appears, select **Installation > Upgrade from a previous version of SQL Server**.
2. Review SQL 2022 Express license terms and rules. Product Updates remain disabled for prepared media.
3. Select the detected existing instance, review features and **Ready to Upgrade**.
4. Click **Upgrade** yourself; wait for **Complete**, inspect all feature results and retain Setup logs.
5. Close Setup and restart Windows manually. Reopen this menu and choose **5 Verify**.
6. Test application access, reads/writes and performance before reopening traffic.

The launcher does not click Upgrade, accept terms or restart Windows. If Setup
fails after modifying components, retain logs and use the recovery decision process.

No upgrade or reboot runs automatically in this release. The old unattended
`-ConfirmDowntime`, `-RecoveryReference` and `-NoRestart` parameters were removed.
`-Mode Upgrade` now opens the interactive wizard. `-Mode Verify` verifies the
manually upgraded instance. The normal menu never requests a VM or remote host.

Setup logs: `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log`.
Runtime: `C:\SqlExpressUpgradeData`. Keep the existing 0.2.0 plan/media/backups
when installing 0.3.1 into its new package folder; do not repeat Configure.
A failed Setup requires diagnosis or external recovery, not a blind retry.

## Rollback boundary

There is no supported SQL 2022-to-2017 in-place downgrade. SQL 2022 backups cannot
be restored on SQL 2017. Restore the complete pre-upgrade server image using your
approved backup platform. This discards **all** server changes after capture.
A script running inside that same server cannot restore its entire running OS.

Items 1, 3 and 6 generate a `Rollback` folder containing:

- `RecoveryTarget.json`: computer, instance, original build, database names and backup path.
- `Capture-HyperV.ps1`: on the host, confirm the matching VM and create a cold checkpoint plus hashed export.
- `Restore-HyperV.ps1`: on the host, confirm the matching VM and explicit loss of later changes, then restore the recorded checkpoint.
- `Verify-Rollback.ps1`: inside the recovered server, check the original build, expected databases and CHECKDB.
- `Invoke-HyperVRecovery.ps1`: shared host implementation.

Copy the **entire folder** and verified backups outside the SQL server before downtime.
Gracefully shut down the VM before Capture or Restore. Host commands (replace example values):

```powershell
.\Rollback\Capture-HyperV.ps1 -VMName 'YOUR_ACTUAL_VM' -RecoveryDirectory 'D:\Recovery\SqlUpgrade01'
# Start the VM and perform the local upgrade with application writers still stopped.
# If recovery is approved, preserve logs/later business data and gracefully shut down again:
.\Rollback\Restore-HyperV.ps1 -VMName 'YOUR_ACTUAL_VM' -RecoveryDirectory 'D:\Recovery\SqlUpgrade01'
# Start the VM; inside the recovered guest:
.\Rollback\Verify-Rollback.ps1
```

VM names belong to Hyper-V and cannot safely be inferred from the guest computer
name. Only the host recovery commands request them. The helper requires the
recorded checkpoint; if it is lost, follow a separately rehearsed export-import
procedure. This release does not claim an independent export-import recovery test.
Application logins, representative data and domain trust still need acceptance.

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
