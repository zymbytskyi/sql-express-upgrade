#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Menu','Discover','Prepare','Preflight','Backup','Rehearse','Recovery','Upgrade','Verify','Restart')][string]$Mode='Menu',
    [string]$WorkRoot='C:\SqlExpressUpgradeData',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,15}$')][string]$InstanceName,
    [string]$MediaPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not[Environment]::Is64BitProcess){throw 'Run 64-bit PowerShell as administrator on the SQL server.'}
. (Join-Path $PSScriptRoot 'LocalInstance.ps1')
. (Join-Path $PSScriptRoot 'OperatorGuidance.ps1')
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
$script:transcriptStarted=$false
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
        if(Get-Process -Name setup -ErrorAction SilentlyContinue){throw 'SQL Setup is open. Complete and close it before changing preparation or backups.'}
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
        Write-OperatorPlans
        if(-not$p.Prepared){Run-Worker Prepare}
        Run-Worker Preflight
        $script:state.Phase='Prepared';Save-State
        Write-RecoveryPlan
        Write-Host 'Preparation complete. Next: 2 Backups, then 3 Final readiness check.'
    }
    function Write-RecoveryPlan {
        if(-not(Test-Path $planPath)){throw 'Run Prepare first.'}
        $p=Get-Content $planPath -Raw | ConvertFrom-Json
        & (Join-Path $PSScriptRoot 'New-RecoveryKit.ps1') -WorkRoot $WorkRoot
        $lines=@(
            '# Recovery plan',
            'This plan and its scripts do not create a recovery image automatically. Copy the entire Rollback folder and verified SQL backups outside this server.',
            'BEFORE UPGRADE: stop application writers; run menu 2 and 3; copy artifacts off-server; gracefully shut down the VM for the host-side capture.',
            'HYPER-V HOST: run Rollback\Capture-HyperV.ps1 -VMName <actual-host-VM-name> -RecoveryDirectory <new-host-recovery-directory>. It creates a cold checkpoint plus export and records recovery.json. Restart the VM, keeping writers stopped.',
            'IF ROLLBACK IS APPROVED: preserve Setup logs and any later business data; gracefully shut down the VM. On its Hyper-V host run Rollback\Restore-HyperV.ps1 with the same VMName and RecoveryDirectory. Confirm the target and data loss. Start the VM.',
            'AFTER RESTORE: inside the recovered server run Rollback\Verify-Rollback.ps1. It checks this computer, original SQL build, expected databases and CHECKDB. Then test application access/data and domain trust.',
            'The host helper restores the recorded checkpoint; if that checkpoint is lost, use a separately rehearsed export-import or backup-provider recovery procedure. An export is not proof of a tested disaster recovery.',
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
        Write-Host "Recovery summary saved: $WorkRoot\RECOVERY.md. Menu 6 displays the detailed text instructions."
        Write-OperatorPlans
    }
    function Final-Readiness {
        try {
            Write-ReadinessReport 'CHECKING' 'Checks have not completed yet.'
            Assert-PreparationPhase
            Run-Worker Preflight
            $p=Get-Content $planPath -Raw | ConvertFrom-Json
            $b=Get-Content (Join-Path $WorkRoot 'backups.json') -Raw | ConvertFrom-Json
            if($b.PlanId -ne $p.Id -or $b.Build -ne $p.SourceBuild){throw 'Backup set belongs to another plan/build.'}
            if((@($b.Files.Database | Sort-Object) -join '|') -ne (@($p.Baseline.Databases.Name | Sort-Object) -join '|')){throw 'Backup database scope does not match the plan.'}
            foreach($f in $b.Files){if((Get-FileHash -LiteralPath $f.Path).Hash -ne $f.Sha256){throw "Backup changed: $($f.Path)"}}
            Run-Worker Rehearse
            Write-RecoveryPlan
            Write-ReadinessReport 'TECHNICAL CHECKS PASSED' 'Preflight, all backup file hashes and user-database restore/CHECKDB passed. External recovery and writer shutdown require operator confirmation.'
        }catch{
            $failure=$_
            try{Write-ReadinessReport 'NOT READY' $failure.Exception.Message}catch{Write-Warning 'Unable to write readiness report.'}
            throw $failure
        }
    }
    function Get-LiveBuild {
        $server=if($InstanceName -eq 'MSSQLSERVER'){'lpc:.'}else{"lpc:.\$InstanceName"}
        $connection=New-Object Data.SqlClient.SqlConnection "Server=$server;Database=master;Integrated Security=True;Connect Timeout=10"
        try{$connection.Open();$command=$connection.CreateCommand();$command.CommandText="SELECT CONVERT(nvarchar(32),SERVERPROPERTY('ProductVersion'));";[string]$command.ExecuteScalar()}finally{$connection.Dispose()}
    }
    function Verify-Local {
        $build=Get-LiveBuild
        if($build -notlike '16.*'){throw "SQL is still $build. Complete the SQL 2022 upgrade wizard first. No upgrade is performed by Verify."}
        if($script:state.BootBeforeSetup -and (Get-Boot) -eq $script:state.BootBeforeSetup){throw 'Restart the server after completing the wizard, then run Verify again.'}
        Run-Worker Verify
        $script:state.Phase='DatabaseChecksPassed';Save-State
    }
    function Restart-Local {
        if((Get-LiveBuild) -notlike '16.*'){throw 'SQL 2022 is not installed yet. Finish the wizard before requesting restart.'}
        if(Get-Process -Name setup -ErrorAction SilentlyContinue){throw 'SQL Setup is still open. Complete and close it before restarting.'}
        Write-Host 'Restarting in 15 seconds. Sign in again and reopen this same menu to verify.'
        shutdown.exe /r /t 15 /d p:4:2 /c 'SQL Express manual upgrade verification'
        if($LASTEXITCODE -ne 0){throw "Restart request failed: $LASTEXITCODE"}
    }
    function Open-UpgradeWizard {
        if([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Open the menu in an interactive desktop/RDP PowerShell window on this SQL server to launch Setup Wizard.'}
        if((Get-LiveBuild) -notlike '14.*'){throw 'Wizard launch requires the original SQL 2017 instance. Use Verify if already upgraded.'}
        if(Get-Process -Name setup -ErrorAction SilentlyContinue){throw 'Setup is already open. Switch to the existing Setup window.'}
        Final-Readiness
        $instructions=@(
            '# Manual SQL Server 2022 upgrade',
            "Target: $env:COMPUTERNAME\$InstanceName. Upgrade this existing instance; do not create a new instance.",
            'Before proceeding: stop application writers, take fresh backups (menu 2), pass final readiness (menu 3), and complete the external recovery preparation in menu 6.',
            '1. The launcher opens the interactive Upgrade workflow. If Installation Center appears instead: Installation > Upgrade from a previous version of SQL Server.',
            '2. Confirm SQL Server 2022 Express. Review and accept the license terms yourself.',
            '3. Keep Product Updates disabled for this prepared media. Review Global Rules and resolve every failure.',
            "4. Select Instance: choose $InstanceName. Confirm the existing SQL 2017 instance; do not select New installation.",
            '5. Review detected features, instance configuration and Upgrade Rules. Keep existing settings unless an approved change is required.',
            '6. Ready to Upgrade: verify the target and feature summary. Click Upgrade yourself.',
            '7. Wait for Complete. Confirm every feature succeeded. Save the Summary/Detail log locations and close Setup.',
            '8. Restart Windows manually if requested; this runbook requires a restart before final acceptance. Restart from Windows when ready; the menu does not restart this server.',
            '9. Sign in again, reopen this menu and choose 5 Verify. Test application reads/writes before reopening normal traffic.',
            'If Setup fails, retain logs, investigate or restore the external pre-upgrade server image. Do not uninstall SQL or attempt an in-place downgrade.'
        )
        $instructionsPath=Join-Path $WorkRoot 'MANUAL-UPGRADE.md'
        $instructions | Set-Content $instructionsPath -Encoding UTF8
        $instructions | ForEach-Object {Write-Host $_}
        Write-Host "Instructions saved: $instructionsPath"
        $previous=$script:state.Phase
        $script:state.BootBeforeSetup=Get-Boot
        $script:state.Phase='WizardOpened';Save-State
        try {
            # Interactive only: no /Q, /QS, license acceptance or automatic restart.
            $process=Start-Process -FilePath (Join-Path $WorkRoot 'Media2022\setup.exe') -ArgumentList @('/ACTION=Upgrade',"/INSTANCENAME=$InstanceName",'/UPDATEENABLED=False') -PassThru
            Write-Host "Setup Wizard opened (PID $($process.Id)). Complete the wizard yourself. The menu does not click Upgrade or restart Windows."
        }catch{$script:state.Phase=$previous;Save-State;throw}
    }
    function Invoke-VisibleAction([string]$Label,[scriptblock]$Action){
        $timer=[Diagnostics.Stopwatch]::StartNew()
        Write-Host "`n[$(Get-Date -Format HH:mm:ss)] START: $Label" -ForegroundColor Cyan
        try{& $Action;Write-Host "[$(Get-Date -Format HH:mm:ss)] SUCCESS: $Label ($([math]::Round($timer.Elapsed.TotalSeconds,1)) seconds)" -ForegroundColor Green}
        catch{Write-Host "[$(Get-Date -Format HH:mm:ss)] FAILED: $Label" -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}
        Write-Host "Reports and instructions: $WorkRoot"
        [void](Read-Host 'Press Enter to return to the menu')
    }
    if($Mode -eq 'Menu'){
        $transcript=Join-Path $WorkRoot ('Menu-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+$PID+'.log')
        Start-Transcript -Path $transcript -Force | Out-Null
        $script:transcriptStarted=$true
        Write-Host "Session log: $transcript"
        Write-Host 'Manual upgrade workflow: choose 5 after completing Setup and restarting Windows.'
        do{
            Write-Host "`nLOCAL SQL Express 2017 -> 2022 | $env:COMPUTERNAME\$InstanceName"
            Write-Host "Phase: $($script:state.Phase) | Runtime: $WorkRoot"
            Write-Host '1 Prepare - instance, plan, checks and media'
            Write-Host '2 Backups - CHECKDB and verified SQL backups'
            Write-Host '3 Final readiness check - preflight and test restore'
            Write-Host '4 Upgrade - open SQL Setup Wizard'
            Write-Host '5 Verify after upgrade and Windows restart'
            Write-Host '6 Rollback plan and instance-specific scripts'
            Write-Host '0 Exit'
            $choice=(Read-Host 'Choose').Trim()
            try{
                switch($choice){
                    '1' {Invoke-VisibleAction 'Prepare' {Prepare-Local}}
                    '2' {Invoke-VisibleAction 'Backups' {
                        try{Assert-PreparationPhase;Select-BackupFolder;Write-ReadinessReport 'NOT READY' 'New backup operation in progress.';Run-Worker Backup;Write-ReadinessReport 'BACKUPS COMPLETE; FINAL CHECK REQUIRED' 'Run menu 3 before Upgrade.'}
                        catch{$failure=$_;try{Write-ReadinessReport 'NOT READY' $failure.Exception.Message}catch{};throw $failure}
                    }}
                    '3' {Invoke-VisibleAction 'Final readiness check' {Final-Readiness}}
                    '4' {Invoke-VisibleAction 'Open SQL Setup Wizard' {Open-UpgradeWizard}}
                    '5' {Invoke-VisibleAction 'Verify' {Verify-Local}}
                    '6' {Invoke-VisibleAction 'Rollback plan and scripts' {Write-RecoveryPlan;Get-Content (Join-Path $WorkRoot 'ROLLBACK-PLAN.txt') | Out-Host}}
                    '0' {} default {Write-Host 'Unknown choice.'}
                }
            }catch{Write-Warning $_.Exception.Message}
        }while($choice -ne '0')
    }else{
        switch($Mode){
            Prepare {Prepare-Local} Preflight {Run-Worker Preflight}
            Backup {Assert-PreparationPhase;Run-Worker Backup} Rehearse {Assert-PreparationPhase;Run-Worker Rehearse}
            Recovery {Write-RecoveryPlan} Upgrade {Open-UpgradeWizard}
            Verify {Verify-Local} Restart {Restart-Local}
        }
    }
}finally{if($script:transcriptStarted){Stop-Transcript | Out-Null};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
