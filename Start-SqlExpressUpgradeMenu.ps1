#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Menu','Discover','Prepare','Preflight','Backup','Rehearse','Recovery','Upgrade','Verify','Restart')][string]$Mode='Menu',
    [string]$WorkRoot='C:\SqlExpressUpgradeData',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,15}$')][string]$InstanceName,
    [string]$MediaPath,
    [switch]$ConfirmDowntime,
    [string]$RecoveryReference,
    [switch]$NoRestart
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not[Environment]::Is64BitProcess){throw 'Run 64-bit PowerShell as administrator on the SQL server.'}
. (Join-Path $PSScriptRoot 'LocalInstance.ps1')
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
if($WorkRoot -notmatch '^[A-Za-z]:\\' -or $WorkRoot.Contains('"')){throw 'Use an absolute local runtime directory without quotes.'}
if($WorkRoot -eq $PSScriptRoot -or $WorkRoot.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep runtime data outside the package directory.'}
$worker=Join-Path $PSScriptRoot 'Invoke-SqlExpressUpgrade.ps1'
$planPath=Join-Path $WorkRoot 'plan.json'
$statePath=Join-Path $WorkRoot 'local-state.json'
$machineGuid=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
if($Mode -eq 'Discover'){Get-LocalExpressInstance;return}
if(Test-Path $planPath){
    $plan=Get-Content $planPath -Raw | ConvertFrom-Json
    if($plan.Computer -ne $env:COMPUTERNAME){throw 'Plan belongs to a different computer.'}
    if($InstanceName -and $InstanceName -ne $plan.Instance){throw 'Instance does not match the saved local plan.'}
    $InstanceName=$plan.Instance
}else{
    $selected=Select-LocalExpressInstance -Candidates @(Get-LocalExpressInstance) -Requested $InstanceName -Interactive:($Mode -eq 'Menu')
    $InstanceName=$selected.Instance
}
if($InstanceName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,15}$'){throw 'Invalid local instance name.'}
$mutex=[Threading.Mutex]::new($false,'Global\SqlExpressUpgrade-'+$InstanceName)
$held=$false
try{
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not$held){throw 'Another upgrade session is already open for this instance. Close it before retrying.'}
    New-Item -ItemType Directory $WorkRoot -Force | Out-Null
    if(Test-Path $statePath){
        $script:state=Get-Content $statePath -Raw | ConvertFrom-Json
        if($state.Schema -ne 1 -or $state.MachineGuid -ne $machineGuid -or $state.Instance -ne $InstanceName){throw 'Saved workflow identity mismatch.'}
    }else{
        $script:state=[pscustomobject]@{Schema=1;Computer=$env:COMPUTERNAME;MachineGuid=$machineGuid;Instance=$InstanceName;Phase='New';SetupExitCode=$null;BootBeforeSetup='';RecoveryReference='';UpgradeStartedUtc=''}
    }
    function Save-State {
        $script:state | ConvertTo-Json | Set-Content "$statePath.tmp" -Encoding UTF8
        Move-Item "$statePath.tmp" $statePath -Force
    }
    function Get-Boot {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
    function Run-Worker([string]$Action){& $worker -Mode $Action -WorkRoot $WorkRoot -InstanceName $InstanceName}
    function Get-DefaultBackupDirectory {
        $registry=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        $id=$registry.$InstanceName
        $path=(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\MSSQLServer").BackupDirectory
        if(-not $path -or -not(Test-Path -LiteralPath $path -PathType Container)){throw 'SQL default backup directory is missing. Configure a writable local SQL backup directory before continuing.'}
        $path
    }
    function Assert-PreparationPhase {
        if($script:state.Phase -in @('Upgrading','SetupFailed','RestartRequired','DatabaseChecksPassed')){throw 'Setup already started. Use Verify after restart or follow the recovery plan; do not rerun preparation or Setup blindly.'}
    }
    function Prepare-Local {
        Assert-PreparationPhase
        if(-not(Test-Path $planPath)){
            $backup=Get-DefaultBackupDirectory
            $media=$MediaPath
            if(-not$media){
                $download=Join-Path $WorkRoot 'Downloads'
                $media=Join-Path $download 'SQLEXPR_x64_ENU.exe'
                if(-not(Test-Path $media)){& (Join-Path $PSScriptRoot 'Save-Sql2022ExpressMedia.ps1') -Destination $download | Out-Host}
            }
            & $worker -Mode Configure -WorkRoot $WorkRoot -InstanceName $InstanceName -MediaPath $media -BackupDirectory $backup
        }
        $p=Get-Content $planPath -Raw | ConvertFrom-Json
        if(-not$p.Prepared){Run-Worker Prepare}
        Run-Worker Preflight
        $script:state.Phase='Prepared';Save-State
        Write-Host 'Preparation complete. Next: backup, restore rehearsal, and recovery planning.'
    }
    function Write-RecoveryPlan {
        if(-not(Test-Path $planPath)){throw 'Run Prepare first.'}
        $p=Get-Content $planPath -Raw | ConvertFrom-Json
        $lines=@(
            '# Recovery plan',
            "Computer: $env:COMPUTERNAME; local instance: $InstanceName; original SQL build: $($p.SourceBuild).",
            "SQL backup directory: $($p.BackupDirectory). Copy verified pre-upgrade backups and this runtime directory to storage outside this server before downtime.",
            'Stop application writers before the final backup and keep them stopped until acceptance or rollback.',
            'Have the infrastructure/backup operator capture and validate a full server recovery image after writers stop. Record its exact backup/checkpoint ID and restore procedure.',
            'A script inside the server cannot restore the entire running server or a host-owned VM checkpoint. Recovery must be initiated from the backup console or hypervisor.',
            'For Hyper-V, optional/Invoke-HyperVRecovery.ps1 provides a separate host-side Capture/Restore helper. It is never invoked by the local upgrade menu.',
            'If SQL Setup fails, retain logs and do not retry blindly. Restore the complete pre-upgrade server image through the agreed recovery system.',
            'Recovery discards all server changes after the selected image. Decide how to preserve later writes before restoring.',
            'After recovery, confirm the original SQL build, database integrity, application logins, representative data and domain trust before reopening writers.',
            'SQL 2022 backups cannot be restored to SQL 2017. This package does not uninstall SQL or attempt an in-place downgrade.',
            'SQL-only recovery onto a rebuilt SQL 2017 server requires a separately tested plan for logins/SIDs, certificates, server configuration and all dependent features. User database backups alone are not full-server rollback.'
        )
        $lines | Set-Content (Join-Path $WorkRoot 'RECOVERY.md') -Encoding UTF8
        $lines | ForEach-Object {Write-Host $_}
    }
    function Verify-Local {
        if($script:state.Phase -notin @('RestartRequired','DatabaseChecksPassed')){throw 'This workflow has no successful Setup awaiting verification. Inspect local-state.json and SQL Setup logs.'}
        if($script:state.Phase -eq 'RestartRequired' -and (Get-Boot) -eq $script:state.BootBeforeSetup){throw 'Restart this server before post-upgrade verification.'}
        Run-Worker Verify
        $script:state.Phase='DatabaseChecksPassed';Save-State
    }
    function Restart-Local {
        if($script:state.Phase -ne 'RestartRequired'){throw 'The workflow is not awaiting a restart.'}
        Write-Host 'Restarting in 15 seconds. Sign in again and reopen this same menu to verify.'
        shutdown.exe /r /t 15 /d p:4:2 /c 'SQL Express local upgrade verification'
        if($LASTEXITCODE -ne 0){throw "Restart request failed: $LASTEXITCODE"}
    }
    function Upgrade-Local([bool]$Downtime,[string]$Recovery){
        if(-not$Downtime -or [string]::IsNullOrWhiteSpace($Recovery)){throw 'Stop all writers and provide a verified external full-server recovery reference before Upgrade.'}
        if($script:state.Phase -ne 'Prepared'){throw 'Run Prepare first. A failed/interrupted Setup must be investigated, not rerun.'}
        Run-Worker Preflight
        Run-Worker Backup
        Run-Worker Rehearse
        Write-RecoveryPlan
        $script:state.RecoveryReference=$Recovery
        $script:state.BootBeforeSetup=Get-Boot
        $script:state.UpgradeStartedUtc=[datetime]::UtcNow.ToString('o')
        $script:state.Phase='Upgrading';Save-State
        try{
            $setup=Join-Path $WorkRoot 'Media2022\setup.exe'
            $process=Start-Process -FilePath $setup -ArgumentList @('/Q','/ACTION=Upgrade',"/INSTANCENAME=$InstanceName",'/IACCEPTSQLSERVERLICENSETERMS','/UPDATEENABLED=False') -WindowStyle Hidden -PassThru -Wait
            $script:state.SetupExitCode=$process.ExitCode
            if($process.ExitCode -notin @(0,3010)){throw "SQL Setup failed ($($process.ExitCode)). Inspect SQL Setup Bootstrap logs. Recovery is external; no downgrade was attempted."}
            $script:state.Phase='RestartRequired';Save-State
        }catch{$script:state.Phase='SetupFailed';Save-State;throw}
        if($NoRestart){Write-Host 'Setup succeeded. Restart and reopen the menu to verify.'}else{Restart-Local}
    }
    if($Mode -eq 'Menu'){
        if($script:state.Phase -eq 'RestartRequired' -and (Get-Boot) -ne $script:state.BootBeforeSetup){try{Verify-Local}catch{Write-Warning $_.Exception.Message}}
        do{
            Write-Host "`nLOCAL SQL Express 2017 -> 2022 | $env:COMPUTERNAME\$InstanceName"
            Write-Host "Phase: $($script:state.Phase) | Runtime: $WorkRoot"
            Write-Host '1 Prepare (detect/download/configure) | 2 Preflight | 3 Backup | 4 Restore rehearsal'
            Write-Host '5 Recovery plan | 6 Upgrade | 7 Verify after restart | 8 Restart after Setup | 0 Exit'
            $choice=Read-Host 'Choose'
            try{
                switch($choice){
                    '1' {Prepare-Local}
                    '2' {Run-Worker Preflight}
                    '3' {Assert-PreparationPhase;Run-Worker Backup}
                    '4' {Assert-PreparationPhase;Run-Worker Rehearse}
                    '5' {Write-RecoveryPlan}
                    '6' {
                        Write-Host 'Stop all writers. Full-server recovery must already be captured and verified outside this server.'
                        $reference=Read-Host 'Recovery image/checkpoint ID or backup job reference'
                        if((Read-Host 'Type UPGRADE to confirm downtime, recovery readiness and local upgrade') -ceq 'UPGRADE'){Upgrade-Local $true $reference}
                    }
                    '7' {Verify-Local}
                    '8' {if((Read-Host 'Type RESTART') -ceq 'RESTART'){Restart-Local}}
                    '0' {} default {Write-Host 'Unknown choice.'}
                }
            }catch{Write-Warning $_.Exception.Message}
        }while($choice -ne '0')
    }else{
        switch($Mode){
            Prepare {Prepare-Local} Preflight {Run-Worker Preflight}
            Backup {Assert-PreparationPhase;Run-Worker Backup} Rehearse {Assert-PreparationPhase;Run-Worker Rehearse}
            Recovery {Write-RecoveryPlan} Upgrade {Upgrade-Local ([bool]$ConfirmDowntime) $RecoveryReference}
            Verify {Verify-Local} Restart {Restart-Local}
        }
    }
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
