# SQL Express 2017 to 2022: real-server rehearsal

Reviewed 2026-09-29. Package: **v0.3.1**. This document supplements the generated
instance-specific text plans. It does not certify an unseen production server.

## What is verified

| Check | Evidence and limit |
| --- | --- |
| Local discovery / safety guards | 13 source safety assertions and 8 selection cases passed, including default/custom named instances and ambiguous selection. |
| SQL upgrade path in the lab | Earlier lab testing covered SQL 2017 Express 14.0.1000.169 to SQL 2022 16.0.1000.6, reboot, checks and checkpoint recovery. This is not a test of your production application. |
| Current lab state | Read-only check on 2026-09-29 found SQL 2022 16.0.1000.6, no running setup process and the demo database ONLINE after the user's manual upgrade. This alone is not full application acceptance. |
| New backup folder | Live v0.3.1 function test under the lab operator account: SQL size estimate, real volume capacity, new folder and SQL service SID ACL, demo COPY_ONLY/CHECKSUM backup and VERIFYONLY passed. Test used the now-upgraded SQL 2022 instance; the complete v0.3.1 workflow was not rerun on SQL 2017. |
| Guidance and failures | Isolated tests passed for free-space ranking, insufficient capacity, custom folder, backup age, missing/changed files, readiness results and generated documents. |
| Wizard launcher | Arguments and guards tested with a mocked launcher; user reported that the real wizard opened and ran. No automated GUI acceptance claim. |
| Remaining site-specific work | Actual server OS/features, application/vendor support, large backup timing, mounted-volume/storage layout, external recovery and final CU/security servicing require confirmation. Independent export-import disaster recovery is not certified by these tests. |

## Before connecting

Record the real server, owner, maintenance window, rollback decision deadline,
application stop/start procedure and person who can operate the VM backup console.
Confirm application/vendor support for SQL 2022 and the client drivers in use.
This package targets local English x64 standalone Express Database Engine.
HA/clustered, encrypted/replicated/snapshot databases and additional SQL features
need separate review. Do not use a passing generic menu as proof of feature support.

The real server must have a supported OS, enough capacity and no pending restart.
Microsoft supports the [2017 Express to 2022 Express upgrade path](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/supported-version-and-edition-upgrades-2022?view=sql-server-ver16).
Check its [hardware and OS requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2022?view=sql-server-ver16)
against the actual server before downtime. SQL Setup rules are an additional gate.

## 1. Connect and install

1. Open Remote Desktop Connection (`mstsc`) and connect to the actual SQL server,
   or use Hyper-V Manager > select the verified VM > Connect.
2. Sign in with an authorized Windows account that is local administrator and
   SQL sysadmin for the selected instance. Do not enter credentials into scripts.
3. Start > Windows PowerShell > right-click > Run as administrator. Use 64-bit
   Windows PowerShell 5.1. Run the entire pinned block:

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -le 5) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$installer = Join-Path $env:TEMP 'Install-SqlExpressUpgrade-v0.3.1.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-express-upgrade/v0.3.1/Install.ps1' -OutFile $installer -UseBasicParsing
$expected = '8F1AA46B9F1C616B41AB46C293A69EDDB9796D382767623A4D947689F1B83187'
if ((Get-FileHash $installer -Algorithm SHA256).Hash -ne $expected) {
    throw 'Installer integrity check failed.'
}
Unblock-File $installer
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& $installer
```

The installer verifies the release ZIP digest and opens the menu. Repeating this
version's installer opens its installed menu. Do not paste the old v0.2.0 block.
Confirm the displayed computer and instance before continuing. With multiple
eligible instances, choose explicitly. Never copy the lab's runtime/plan to production.

## 2. Preparation and rehearsal: menus 1, 2, 3 and 6

1. **1 Prepare** downloads/extracts media and creates a plan for this server.
   Open `C:\SqlExpressUpgradeData\UPGRADE-PLAN.txt` in Notepad. Resolve every error.
   If a plan was created but default backup storage fails preflight, choose a
   suitable location with menu 2, then rerun preparation/checks as indicated.
2. **2 Backups** shows free GiB and a folder recommendation. Enter accepts it;
   alternatively type a full local folder, such as `E:\SqlUpgradeBackups\Campaign01`.
   The estimate includes 120% of allocated SQL files, the largest scratch restore
   and 10 GiB reserve. Check actual storage policy: the most free space does not
   prove a different physical disk, acceptable I/O performance or an independent backup.
   New folders receive selected SQL service SID permissions. Existing folders keep
   their ACLs. On access denied, have the administrator grant that SQL service
   Modify on the dedicated folder; do not grant Everyone or change drive-root ACLs.
3. Wait for all backups and VERIFYONLY to finish. CHECKDB, hashing, backup and
   restore rehearsal consume disk space and I/O. Schedule these checks accordingly;
   this is not a zero-impact production inventory. No compression benefit is assumed.
4. **3 Final readiness check** validates the source/media and every recorded backup
   hash, then actually restores user databases to unique scratch databases and runs
   CHECKDB. Successfully tested scratch databases are removed; failed restores are
   retained for diagnosis. Do not delete arbitrary databases to clear space.
5. Read `FINAL-READINESS.txt`: completion time/age, paths/sizes and technical result.
   Older backups can restore correctly while missing later writes. Age over 24 hours
   gets a warning, but even a one-minute-old backup is not a final backup if writes continue.
6. **6 Rollback plan** displays `ROLLBACK-PLAN.txt` and generates the `Rollback`
   folder. Read the guest/host instructions and copy the entire kit, runtime and
   verified SQL backups to protected off-server storage.

If this is only tomorrow's preparation test, **stop here with 0 Exit**.
Nothing requires opening the Upgrade wizard during preparation.

## 3. GO / NO-GO before menu 4

Proceed only when all are true:

- The target computer, selected instance and application maintenance window are correct.
- Application writers are stopped using the approved procedure; take fresh menu 2
  backups and rerun menu 3. Keep writers stopped through acceptance or rollback.
- Technical checks passed without ignored errors. Backup artifacts are copied off-server.
- Full-server recovery has a recorded ID, known storage location, operator and tested
  restoration procedure. The generated scripts/document alone are not a recovery image.
- Application validation and the rollback deadline are agreed. Preserve any later
  business writes before deciding to restore the pre-upgrade VM image.
- The final SQL 2022 servicing level and its application/driver compatibility are approved.

For the supplied Hyper-V helper, gracefully shut down the VM, perform host-side
Capture from the generated plan, then start it with writers still stopped.
The helper requires no pre-existing checkpoints and full export space plus 64 GiB
host headroom. It restores the recorded checkpoint; loss of that checkpoint needs
a separately tested export-import or backup-provider procedure.

## 4. Upgrade, service and validate

1. **4 Upgrade** repeats technical checks and opens SQL Setup. If Installation Center
   appears: Installation > Upgrade from a previous version of SQL Server.
2. Review license/rules, select the existing instance shown in the generated plan,
   and review Ready to Upgrade. Click Upgrade yourself. Do not choose New installation.
3. At Complete, confirm every feature succeeded. Retain Summary/Detail logs under
   `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log`. On any failure,
   keep writers stopped and diagnose or follow the agreed recovery decision.
4. Close Setup and restart Windows. Sign in, reopen elevated PowerShell, then:

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& 'C:\Tools\SqlExpressUpgrade-v0.3.1\Start-SqlExpressUpgradeMenu.ps1'
```

5. Choose **5 Verify**. Require success, then test application logins, representative
   reads/writes, integrations and performance. Do not change database compatibility
   levels as an unplanned part of this upgrade.
6. The prepared media is **SQL 2022 RTM 16.0.1000.6**. Menu 5 can pass on RTM; it does
   not enforce CU/security compliance. Before reopening production, apply the
   application-approved current servicing package using its separate tested procedure,
   reboot as required and repeat verification/application tests. See Microsoft's
   [current SQL 2022 build table](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions).
   As checked on 2026-09-29 it lists CU27, 16.0.4295.3; this package does not install it.
7. Reopen traffic only after application and infrastructure owners accept the result.
   Retain pre-upgrade recovery artifacts through the agreed retention period.

## If something fails

- `Destination exists` naming v0.2.0: an old installer was used. Use the pinned block above.
- Low space or permission failure: stop, choose an approved larger/writable folder and
  retry menu 2; never remove retained recovery artifacts merely to pass a check.
- Media/hash/source mismatch: stop and investigate. Do not edit JSON/hashes to bypass it.
- Setup error or application failure: retain logs, keep writers stopped and use
  `ROLLBACK-PLAN.txt`. Host-side restore discards all VM changes since capture.
- After rollback: run the generated `Verify-Rollback.ps1` inside the recovered server,
  then validate application data/logins and domain trust. SQL 2022 backups cannot
  be used to restore SQL 2017; no in-place downgrade is performed.

Send the operator the package version, generated text plans, latest readiness report,
menu transcript and Setup summary through approved internal channels. Do not upload
production plans, database names, backups, credentials or logs to the public repository.
