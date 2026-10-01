# Human-readable plans for the local v0.4 workflow.
function Write-OperatorPlans {
    $p=Get-Content $planPath -Raw|ConvertFrom-Json
    $text=@"
SQL EXPRESS UPGRADE AND SERVICING PLAN
Server: $($p.Computer) | Instance: $($p.Instance) | Source SQL: $($p.SourceBuild)
Databases: $(@($p.Baseline.Databases.Name) -join ', ')
Current backup directory: $($p.BackupDirectory)
Prepared media: $WorkRoot\Media2022\setup.exe

1. Sign in to this SQL server. Start > Windows PowerShell > Run as administrator.
   Open Start-SqlExpressUpgradeMenu.ps1 from the installed package.
2. Menu 1 discovers SQL language (not Windows language), prepares signed SQL 2022
   Express x64 English media and shows pending restart details. It may prepare
   media while restart is pending; it does not clear registry indicators.
3. Menu 2 recommends a backup folder using allocated SQL sizes + 2 GiB reserve.
   Press Enter or enter another dedicated local folder. COPY_ONLY/CHECKSUM backups
   and VERIFYONLY run. No COMPRESSION, scratch restore or CHECKDB is performed.
   Copy backups off-server. Original sets and SQL 2017 backups are retained.
4. Menu 3 performs upgrade preflight and reuses matching completed VERIFYONLY
   evidence. Changed inputs invalidate it with a reason. Inspect FINAL-READINESS.txt
   for backup age/paths and the exact validation mode. VERIFYONLY is not a restore test.
5. Menu 7 is optional: full user-database restore into unique scratch databases and
   CHECKDB. Read the disk/I/O estimate before confirming REHEARSE. Failed scratch
   databases are retained for diagnosis; only successful owned tests are dropped.
6. Menu 11 records the actual external VM recovery provider, reference and procedure.
   Menu 6 writes ROLLBACK-PLAN.txt. Qualify full-server recovery BEFORE downtime.
7. At downtime stop application writers with the application owner. Repeat final
   backups/checks; keep writers stopped. Resolve pending restart before Upgrade.
8. Menu 4 shows a copyable manual command, checks current conditions and cached
   evidence, then opens interactive Setup. It never repeats a full rehearsal.
   In Setup: Installation > Upgrade from a previous version > select $($p.Instance).
   Review license/rules/Ready to Upgrade, then click Upgrade yourself.
   UpdateEnabled=False excludes updates from THIS Setup. Microsoft Update checkbox
   enables FUTURE Windows Update scans; it is not proof this installation is patched.
9. At Complete inspect every feature and save logs from SQL Server\160\Setup Bootstrap\Log.
   Close Setup and restart Windows, then reopen the menu and choose 5 (quick checks).
10. Menu 8 discovers CU/security candidates from Microsoft and shows installed/target
    build, KB and source. Approve the servicing target, choose 0/1/2 pre-patch backups
    (none/system/all), and confirm PATCH only when writers are stopped and recovery ready.
    The selected instance is targeted; shared components can also be serviced.
    Read progress/log paths. Restart only when requested/approved, then use menu 5.
11. Menu 5 checks connectivity/build, ONLINE databases, restart and approved compatibility.
    It does not run CHECKDB. Menu 9 offers full CHECKDB separately (CPU/I/O intensive).
12. Menu 12 optionally changes selected USER databases to compatibility 160 after
    verified patching. Confirm vendor/application support, retain displayed revert
    commands and test the application. System database levels are never changed.
    Menu 14 only registers already-approved EXISTING level-160 changes from older runs.
13. Menu 13 writes the completion summary. The application owner must validate logins,
    representative reads/writes, integrations and performance before reopening traffic.
    SQL technical checks do not prove application acceptance; RTM is not fully serviced.

Manual backups: menu 10 inspects headers/identity/checksums and registers a complete
matching set; files are never renamed or rewritten. Backup age can miss later writes.
"@
    $text|Set-Content (Join-Path $WorkRoot 'UPGRADE-PLAN.txt') -Encoding UTF8
    $recovery=@"
EXTERNAL RECOVERY PLAN - $($p.Computer)\$($p.Instance)
Original SQL build: $($p.SourceBuild). Preserve pre-upgrade SQL 2017 backups.
Menu 11 records provider, recovery point ID and tested restore procedure (no secrets).
Menu 6 refreshes this document with the recorded details. Local SQL backups must be
copied off-server and are not a complete VM recovery image.
Before restore: stop writers, preserve diagnostics/later business writes, approve
loss of all changes since the recovery point, then use the provider's tested procedure.
After restore: verify original SQL build, database integrity, logins, data and domain
trust. Application owner acceptance is required before reopening traffic.
SQL 2022 backups cannot restore to SQL 2017. No in-place downgrade is implemented.
Hyper-V is OPTIONAL: only on an actual Hyper-V host use Hyper-V Manager and the
separate Capture/Restore helper in optional/Invoke-HyperVRecovery.ps1. It requires
an OFF VM and explicit identity/data-loss review. Other providers, including Azure
Backup, use their own restore console and approved runbook.
"@
    $recovery|Set-Content (Join-Path $WorkRoot 'ROLLBACK-PLAN.txt') -Encoding UTF8
    Write-Host "Text plans: $WorkRoot\UPGRADE-PLAN.txt and $WorkRoot\ROLLBACK-PLAN.txt"
}
function Get-BackupSpaceEstimate {
    $server=if($InstanceName -eq 'MSSQLSERVER'){'lpc:.'}else{"lpc:.\$InstanceName"}
    $c=[Data.SqlClient.SqlConnection]::new("Server=$server;Database=master;Integrated Security=True;Connect Timeout=10")
    try {
        $c.Open();$cmd=$c.CreateCommand()
        $cmd.CommandText='SELECT SUM(Bytes)*1.2+2147483648 FROM (SELECT SUM(CONVERT(bigint,size))*8192 AS Bytes FROM sys.master_files WHERE database_id<>2 GROUP BY database_id) s'
        [long][math]::Ceiling([decimal]$cmd.ExecuteScalar())
    } finally {$c.Dispose()}
}

function Get-BackupCandidates([long]$RequiredBytes) {
    @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object {$_.FileSystem -in @('NTFS','ReFS')} |
        Sort-Object @{Expression={ [long]$_.FreeSpace -ge $RequiredBytes };Descending=$true},@{Expression={[long]$_.FreeSpace};Descending=$true} |
        ForEach-Object {[pscustomobject]@{Drive=$_.DeviceID;FreeBytes=[long]$_.FreeSpace;Enough=([long]$_.FreeSpace -ge $RequiredBytes)}})
}

function Select-BackupFolder {
    $p=Get-Content $planPath -Raw | ConvertFrom-Json
    $required=Get-BackupSpaceEstimate
    $disks=@(Get-BackupCandidates $required)
    if(-not $disks.Count){throw 'No supported fixed local volumes found.'}
    Write-Host ('Estimated new backup + 2 GiB reserve (no scratch restore): {0:N1} GiB' -f ($required/1GB))
    $disks | Select-Object Drive,@{n='FreeGiB';e={[math]::Round($_.FreeBytes/1GB,1)}},Enough | Format-Table | Out-Host
    $best=@($disks | Where-Object Enough | Select-Object -First 1)
    $recommend=if($best.Count){[IO.Path]::Combine(($best[0].Drive+'\'),("SqlUpgradeBackups\$InstanceName\"+$p.Id))}else{''}
    Write-Host "Current plan folder: $($p.BackupDirectory)"
    Write-Host "Recommended folder: $recommend"
    Write-Host 'Existing backups are retained. These are local staging backups: copy them off-server for recovery.'
    $chosen=(Read-Host 'Backup folder (Enter = recommendation; or type a full local folder path)').Trim()
    if(-not $chosen){$chosen=$recommend}
    if($chosen -notmatch '^[A-Za-z]:\\' -or $chosen.Contains('"') -or $chosen.IndexOfAny([char[]]'*?') -ge 0){throw 'Specify a full local folder path, not a network share or wildcard.'}
    $chosen=[IO.Path]::GetFullPath($chosen).TrimEnd('\')
    if($chosen.Length -le 3 -or $chosen -eq $PSScriptRoot -or $chosen.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $chosen -eq $WorkRoot -or $chosen.StartsWith($WorkRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Use a dedicated backup folder outside the package and runtime directory.'}
    # Resolve existing ancestors so mounted volumes are checked by their actual capacity.
    $parent=$chosen
    while(-not(Test-Path -LiteralPath $parent)){ $parent=Split-Path $parent -Parent; if(-not$parent){throw 'Cannot resolve backup volume.'} }
    $volume=Get-Volume -FilePath $parent -ErrorAction Stop
    if($volume.FileSystem -notin @('NTFS','ReFS') -or $volume.DriveType -ne 'Fixed' -or $volume.SizeRemaining -lt $required){throw 'Selected volume lacks supported storage or sufficient backup/rehearsal headroom. Choose another folder.'}
    if(-not(Test-Path -LiteralPath $chosen)){
        New-Item -ItemType Directory -Path $chosen -Force | Out-Null
        $service=if($InstanceName -eq 'MSSQLSERVER'){'MSSQLSERVER'}else{'MSSQL$'+$InstanceName}
        $sid=([Security.Principal.NTAccount]::new('NT SERVICE\'+$service)).Translate([Security.Principal.SecurityIdentifier])
        $acl=Get-Acl -LiteralPath $chosen
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'Modify','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $chosen -AclObject $acl
        Write-Host 'Created folder; granted this SQL service SID Modify access to this folder only.'
    }else{Write-Host 'Existing folder ACL retained. SQL BACKUP will verify service write access; permission failure blocks completion.'}
    if($p.PSObject.Properties.Name -notcontains 'PreUpgradeBackupDirectory'){$p|Add-Member NoteProperty PreUpgradeBackupDirectory $p.BackupDirectory}
    $p.BackupDirectory=$chosen
    $p | ConvertTo-Json -Depth 12 | Set-Content "$planPath.tmp" -Encoding UTF8
    Move-Item "$planPath.tmp" $planPath -Force
    Write-OperatorPlans
    Write-Host "Selected backup folder: $chosen"
}

function Write-ReadinessReport([string]$Result,[string]$Reason='') {
    $lines=@("FINAL READINESS: $Result","Checked UTC: $([datetime]::UtcNow.ToString('u'))","Instance: $env:COMPUTERNAME\$InstanceName","Details: $Reason")
    $currentBuild=Get-LiveBuild
    $file=if($currentBuild -like '16.*'){Join-Path $WorkRoot 'backups-2022.json'}else{Join-Path $WorkRoot 'backups.json'}
    if(Test-Path $file){
        $b=Get-Content $file -Raw | ConvertFrom-Json
        $age=([datetime]::UtcNow-([datetime]$b.CreatedUtc).ToUniversalTime()).TotalHours
        $lines+="Last complete backup set (completion UTC): $($b.CreatedUtc); age: $([math]::Round($age,2)) hours"
        foreach($f in $b.Files){
            if(Test-Path -LiteralPath $f.Path){$item=Get-Item -LiteralPath $f.Path;$lines+="$($f.Database): $($f.Path) | $([math]::Round($item.Length/1GB,3)) GiB | file modified UTC $($item.LastWriteTimeUtc.ToString('u'))"}
            else{$lines+="MISSING: $($f.Database): $($f.Path)"}
        }
        if($age -gt 24){$lines+='ATTENTION: backups are more than 24 hours old. Take fresh backups after stopping writers for the upgrade window.'}
    }else{$lines+='No complete backup set recorded. Run menu 2.'}
    $lines+='Technical readiness is separate from business readiness: stop writers, take final backups and confirm external full-server recovery before Upgrade. Backup age alone cannot prove no later writes exist.'
    $lines | Set-Content (Join-Path $WorkRoot 'FINAL-READINESS.txt') -Encoding UTF8
    $lines | ForEach-Object {Write-Host $_}
}
