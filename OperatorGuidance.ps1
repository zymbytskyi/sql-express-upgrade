# English operator documents and local backup storage selection.
function Write-OperatorPlans {
    $p=Get-Content $planPath -Raw | ConvertFrom-Json
    $target=if($p.Instance -eq 'MSSQLSERVER'){$p.Computer}else{"$($p.Computer)\$($p.Instance)"}
    $upgrade=@"
SQL EXPRESS UPGRADE PLAN
Generated: $([datetime]::UtcNow.ToString('u'))
Server/instance: $target
Original build: $($p.SourceBuild); target: SQL Server 2022 Express
Databases: $(@($p.Baseline.Databases.Name) -join ', ')
Current backup folder: $($p.BackupDirectory)
Media: $WorkRoot\Media2022\setup.exe

PREPARATION DAY
1. Sign in to $($p.Computer) with your Windows administrator/SQL sysadmin account.
   Start menu > Windows PowerShell > right-click > Run as administrator.
   Open this package's Start-SqlExpressUpgradeMenu.ps1. Run it on this SQL server.
2. Menu 1 prepares the plan/media and checks this instance. Keep this document.
3. Menu 2 lists local fixed disks, free space and estimated backup/rehearsal space.
   Press Enter for the recommended folder or enter another local folder.
   This creates CHECKDB-checked COPY_ONLY/CHECKSUM backups and verifies them.
   Existing backups are retained. SQL service access is required for the folder.
4. Menu 3 restores user backups into temporary databases and checks integrity.
   Read FINAL-READINESS.txt: backup times, age, file paths and technical result.
5. Read ROLLBACK-PLAN.txt. Copy the entire Rollback folder, runtime and verified
   backups to storage outside this server. Arrange and test full-server recovery.

UPGRADE WINDOW
6. Stop application writers using your application's approved maintenance procedure.
   Repeat menu 2 and 3. Take external recovery after writers stop; keep them stopped.
   Old backups may miss later writes even when their restore test passes.
7. Menu 4 repeats technical checks and opens the interactive SQL Setup Wizard.
   If Installation Center appears: Installation > Upgrade from a previous version.
   Review license/rules; keep Product Updates disabled for this prepared media.
   Select existing instance $($p.Instance); do not choose New installation.
   Review features and Ready to Upgrade, then click Upgrade yourself.
8. Wait for Complete. Every feature must succeed. Save Summary/Detail logs from
   C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log.
   On failure, keep writers stopped, preserve logs and consult ROLLBACK-PLAN.txt.
9. Close Setup. Start > Power > Restart. Sign in and reopen the same package menu.
10. Menu 5 checks SQL 2022 and database integrity after restart. Test application
    login, representative reads/writes and performance before reopening traffic.

Technical checks do not validate application compatibility or external recovery.
The prepared base media requires an approved SQL 2022 servicing review before production.
"@
    $rollback=@"
ROLLBACK PLAN - $target
Original build required after recovery: $($p.SourceBuild)
Databases: $(@($p.Baseline.Databases.Name) -join ', ')
SQL backup folder: $($p.BackupDirectory)
Recovery scripts: $WorkRoot\Rollback

WHAT THESE FILES DO
RecoveryTarget.json records this computer, instance, original build and databases.
Capture-HyperV.ps1 runs on the Hyper-V HOST: creates a cold checkpoint and a hashed
export, then records the exact VM/checkpoint identity in recovery.json.
Restore-HyperV.ps1 runs on that HOST: restores the recorded checkpoint after explicit
VM-name and data-loss confirmation. It never guesses which VM to restore.
Verify-Rollback.ps1 runs INSIDE the recovered server: verifies original SQL build,
expected ONLINE databases and CHECKDB. It does not change SQL versions or restore data.
Invoke-HyperVRecovery.ps1 is the shared implementation; keep all files together.

BEFORE THE UPGRADE
1. Stop application writers; run menu 2 (fresh backups) and 3 (test restore).
2. Copy the whole Rollback folder and backup files to protected off-server storage.
3. On the Hyper-V host, open Hyper-V Manager. Select the VM containing $target.
   Confirm its identity using Connect and the guest computer name. The Hyper-V VM
   name can differ from $($p.Computer); record the actual name, do not guess it.
4. In the guest: Start > Power > Shut down. Wait until Hyper-V shows Off.
5. On the HOST, open PowerShell as administrator. Change to the copied Rollback folder:
   Set-Location 'D:\Recovery\Rollback'
   .\Capture-HyperV.ps1 -VMName 'ACTUAL_VM_NAME' -RecoveryDirectory 'D:\Recovery\BeforeSqlUpgrade'
   Replace example paths/name with real host locations. Use a new recovery directory
   on a volume with full export capacity plus 64 GiB headroom. Existing checkpoints
   require review: the helper refuses to overwrite a previous recovery campaign.
6. Require successful completion and retain recovery.json, checkpoint ID and export.
   Hyper-V Manager > select VM > Start > Connect. Keep application writers stopped.
   A captured export is not a tested disaster recovery; rehearse the agreed recovery
   procedure before production. Continue the local upgrade only when recovery is ready.

IF UPGRADE OR APPLICATION ACCEPTANCE FAILS
7. Keep writers stopped. Preserve Setup logs and any business writes made since the
   recovery image. Agree whether recovery is appropriate: ALL later VM changes are lost.
8. Gracefully shut down the VM and wait for Off. On the HOST, in the same copied folder:
   .\Restore-HyperV.ps1 -VMName 'ACTUAL_VM_NAME' -RecoveryDirectory 'D:\Recovery\BeforeSqlUpgrade'
   Use the SAME VM and recorded recovery directory from step 5. Confirm its identity
   and type RESTORE only after approving the loss of changes since capture.
   The script restores the recorded checkpoint. If it is missing, stop and follow a
   separately tested Hyper-V Import Virtual Machine/export or backup-provider runbook.
   Do not attempt an improvised import alongside the original VM on the same network.
9. Hyper-V Manager > Start > Connect. Sign in to the recovered server. Open elevated
   PowerShell, change to its retained Rollback folder and run:
   .\Verify-Rollback.ps1
   Require original build $($p.SourceBuild), expected databases ONLINE and CHECKDB success.
10. Test application logins, representative data, reads/writes and domain trust.
    Reopen writers only after the application owner accepts recovery.

SQL 2022 backups cannot restore to SQL 2017. Do not uninstall SQL to downgrade it.
SQL user backups alone do not restore logins, server configuration or the operating
system. Full-server recovery affects every instance/application on this VM.
For another hypervisor/physical server use its tested full-server backup procedure.
"@
    $upgrade | Set-Content (Join-Path $WorkRoot 'UPGRADE-PLAN.txt') -Encoding UTF8
    $rollback | Set-Content (Join-Path $WorkRoot 'ROLLBACK-PLAN.txt') -Encoding UTF8
    Write-Host "Step-by-step upgrade plan: $WorkRoot\UPGRADE-PLAN.txt"
    Write-Host "Step-by-step rollback plan: $WorkRoot\ROLLBACK-PLAN.txt"
}

function Get-BackupSpaceEstimate {
    $server=if($InstanceName -eq 'MSSQLSERVER'){'lpc:.'}else{"lpc:.\$InstanceName"}
    $c=[Data.SqlClient.SqlConnection]::new("Server=$server;Database=master;Integrated Security=True;Connect Timeout=10")
    try {
        $c.Open();$cmd=$c.CreateCommand()
        $cmd.CommandText='SELECT SUM(Bytes)*1.2+MAX(Bytes)+10737418240 FROM (SELECT SUM(CONVERT(bigint,size))*8192 AS Bytes FROM sys.master_files WHERE database_id<>2 GROUP BY database_id) s'
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
    Write-Host ('Estimated new backup + largest scratch restore + 10 GiB reserve: {0:N1} GiB' -f ($required/1GB))
    $disks | Select-Object Drive,@{n='FreeGiB';e={[math]::Round($_.FreeBytes/1GB,1)}},Enough | Format-Table | Out-Host
    $best=@($disks | Where-Object Enough | Select-Object -First 1)
    $recommend=if($best.Count){Join-Path ($best[0].Drive+'\') ("SqlUpgradeBackups\$InstanceName\"+$p.Id)}else{''}
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
    $p.BackupDirectory=$chosen
    $p | ConvertTo-Json -Depth 12 | Set-Content "$planPath.tmp" -Encoding UTF8
    Move-Item "$planPath.tmp" $planPath -Force
    Write-OperatorPlans
    Write-Host "Selected backup folder: $chosen"
}

function Write-ReadinessReport([string]$Result,[string]$Reason='') {
    $lines=@("FINAL READINESS: $Result","Checked UTC: $([datetime]::UtcNow.ToString('u'))","Instance: $env:COMPUTERNAME\$InstanceName","Details: $Reason")
    $file=Join-Path $WorkRoot 'backups.json'
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
