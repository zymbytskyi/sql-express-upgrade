# SQL Express 2017 to 2022: local upgrade and servicing

**v0.4.0-rc2 is a release candidate.** Run on the SQL server in elevated 64-bit
Windows PowerShell 5.1. Test against a restored non-production copy before a new
production campaign. [Runbook](PRODUCTION-RUNBOOK.md), [migration](MIGRATION.md),
[test evidence and limits](VALIDATION.md).

## Install

```powershell
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -le 5) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$installer = Join-Path $env:TEMP 'Install-SqlExpressUpgrade-v0.4.0-rc2.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/zymbytskyi/sql-express-upgrade/v0.4.0-rc2/Install.ps1' -OutFile $installer -UseBasicParsing
Unblock-File $installer
Set-ExecutionPolicy -Scope Process RemoteSigned -Force
& $installer
```

The installer verifies the GitHub release ZIP digest and installs into its own
versioned folder. Rerunning opens that version's menu. Close older menus first.
Runtime is `C:\SqlExpressUpgradeData`; never publish runtime, logs, backups or credentials.
A single eligible local instance is automatic; multiple source instances require a choice.
No VM name, remote credentials or Hyper-V module is required for the SQL workflow.

## Menu and workload

| Item | Behavior |
| --- | --- |
| 1 Prepare | Discover SQL language; download/reuse English SQL 2022 Express media, verify metadata/signature/x64 layout, generate text plan. Pending restart is reported but does not prevent preparation. |
| 2 Backups | Choose capacity-ranked local folder; COPY_ONLY, CHECKSUM and VERIFYONLY. No compression, restore or CHECKDB. Restart indicators do not block valid backups. |
| 3 Final readiness | Current upgrade prerequisites plus persisted VERIFYONLY evidence. Report backup age, files and mode. Completed backup-time verification is reused. |
| 4 Upgrade | Show copyable manual command, current stage and UpdateEnabled=False; run current checks and require valid cached evidence, then open interactive Setup. No automatic Upgrade click/restart. |
| 5 Quick Verify | Connectivity, SQL 2022 Express build, databases ONLINE, pending restart and approved compatibility. Explicit post-patch target verification; never repeats installation. |
| 6 Recovery plan | Provider-neutral text with recorded recovery reference. SQL 2017 backups remain necessary for SQL 2017 recovery. |
| 7 Optional rehearsal | Confirm full user backup restores into unique scratch databases plus CHECKDB, after space/workload explanation. Failed tests are retained for diagnosis. |
| 8 Patch | Review live Microsoft CU/security candidates and explicit target; optional 0/1/2 backups; selected-instance patch with progress/log locations and explicit restart choice. |
| 9 Optional CHECKDB | Confirm full database integrity scans separately from quick verification. |
| 10 Register backups | Inspect manual full backup headers, server/database/version/checksum identity, run VERIFYONLY and hash; register without changing files. |
| 11 External recovery | Record provider, recovery reference and tested procedure, including Azure Backup. No provider backup is created automatically. |
| 12 Optional compatibility 160 | After patch verification, select user databases, confirm vendor support, record old/new levels and revert commands. Never system databases. |
| 13 Summary | Source/final build, patch KB/status, databases, validation evidence, compatibility changes, backup files and required application acceptance. |
| 14 Existing compatibility approval | Migration only: explicitly register already-approved existing level-160 changes, with no ALTER. |

Every action shows START/SUCCESS/FAILED, elapsed time and an Enter pause. Long SQL
operations and quiet patch installation report elapsed time; patching also reports
installer processes and the latest Setup log path. Application services are never
stopped/started by guessing their names.

## Media and storage

SQL source language comes from the SQL registry, not Windows display language.
This release supports English source SQL (1033) only, including German Windows.
Existing valid SQL 2022 bootstrapper/media is reused. Bootstrapper download uses
`/LANGUAGE=en-US`; incorrect results fall back to the verified version-specific
Microsoft ENU full-media URL. Files are not renamed to impersonate another language.
Invalid/partial artifacts are retained separately; rerun Prepare to recover.
After extraction the language pack XML and x64 engine MSI are checked as well as
Microsoft signatures and SQL 2022 Express metadata. Unsupported source language
fails explicitly. Evergreen Microsoft links can point to a different SQL major.

Default capacity is 120% of allocated database files plus 2 GiB reserve, without
scratch restore space. Full rehearsal checks its additional allocation separately.
New dedicated folders grant the selected SQL service SID Modify; existing ACLs stay
unchanged. Never grant Everyone/drive-root permissions. Copy local backups off-server.
Recognizable sanitized database names, timestamps and GUIDs avoid filename collisions.
Previous `.bak` sets and historical manifests are retained. Post-upgrade backups use
a separate `backups-2022.json`; use menu 2 to choose a dedicated post-upgrade folder.

## Evidence reuse and recovery boundaries

Validation binds computer/instance, plan, live build/scope/compatibility, manifest,
mode, storage, expected hashes and current file sizes/modified times. First validation
hashes files. Subsequent launcher checks use immutable recorded hashes plus metadata
instead of rescanning large files. This is an operational cache, not protection from
an attacker deliberately preserving timestamps and altering files/state. Keep runtime
and backups protected. To force a revalidation, retain/archive the relevant validation
JSON and run menu 3 again. A change causes an explicit invalidation reason.

VERIFYONLY does not prove full restore/CHECKDB. Technical PASS does not prove
application acceptance, external recovery or current servicing. The base media is
RTM; menu 8 explicitly approves CU/security servicing and menu 5 verifies its target.
An optional Hyper-V host helper remains separate under `optional/`. It is not used
for Azure/other VM platforms. No in-place SQL downgrade is provided.

## Integrated patch provenance and limits

Discovery/download/signature helpers derive from
[sql-server-2022-express-self-patch](https://github.com/zymbytskyi/sql-server-2022-express-self-patch)
commit `c528b6d1e17bf3621549ac73e3685fb7cd1b1062`, under the included MIT notice.
The upstream interactive entry point is not executed. The wrapper adds explicit
CU/security-table review, target/build validation, durable restart state, progress,
backup integration and selected-instance arguments; it never uses `/AllInstances`.

The latest CU downloads automatically from Microsoft Download Center. If a newer
security target is listed, the operator supplies its exact official Microsoft EXE
URL from that KB. Published SHA256, when supplied by Microsoft, can be pasted and is
verified; otherwise Authenticode and the exact expected package build are required,
and a local SHA256 is recorded/displayed. A local hash alone is not publisher proof.
An unreadable servicing page, unexpected package build/signature or pending restart
blocks patch execution. Servicing-target approval is explicit, not a claim that the
application vendor supports the latest CU. Shared SQL components can also be serviced.

The Microsoft Update checkbox controls future Windows Update scans. Include SQL
Server product updates (`UpdateEnabled`) affects the current Setup operation.
The major-upgrade launcher uses `/UPDATEENABLED=False`; servicing is menu 8.
