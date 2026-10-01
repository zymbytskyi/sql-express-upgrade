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



    function Get-LiveBuild {
        $server=if($InstanceName -eq 'MSSQLSERVER'){'lpc:.'}else{"lpc:.\$InstanceName"}
        $connection=New-Object Data.SqlClient.SqlConnection "Server=$server;Database=master;Integrated Security=True;Connect Timeout=10"
        try{$connection.Open();$command=$connection.CreateCommand();$command.CommandText="SELECT CONVERT(nvarchar(32),SERVERPROPERTY('ProductVersion'));";[string]$command.ExecuteScalar()}finally{$connection.Dispose()}
    }

    function Restart-Local {
        if((Get-LiveBuild) -notlike '16.*'){throw 'SQL 2022 is not installed yet. Finish the wizard before requesting restart.'}
        if(Get-Process -Name setup -ErrorAction SilentlyContinue){throw 'SQL Setup is still open. Complete and close it before restarting.'}
        Write-Host 'Restarting in 15 seconds. Sign in again and reopen this same menu to verify.'
        shutdown.exe /r /t 15 /d p:4:2 /c 'SQL Express manual upgrade verification'
        if($LASTEXITCODE -ne 0){throw "Restart request failed: $LASTEXITCODE"}
    }

    function Invoke-VisibleAction([string]$Label,[scriptblock]$Action){
        $timer=[Diagnostics.Stopwatch]::StartNew()
        Write-Host "`n[$(Get-Date -Format HH:mm:ss)] START: $Label" -ForegroundColor Cyan
        try{& $Action;Write-Host "[$(Get-Date -Format HH:mm:ss)] SUCCESS: $Label ($([math]::Round($timer.Elapsed.TotalSeconds,1)) seconds)" -ForegroundColor Green}
        catch{Write-Host "[$(Get-Date -Format HH:mm:ss)] FAILED: $Label" -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}
        Write-Host "Reports and instructions: $WorkRoot"
        [void](Read-Host 'Press Enter to return to the menu')
    }
    . (Join-Path $PSScriptRoot 'ConsoleActions.ps1')
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
            Write-Host '2 Backups - COPY_ONLY/CHECKSUM + VERIFYONLY (no restore)'
            Write-Host '3 Final readiness - VERIFYONLY + persisted validation'
            Write-Host '4 Upgrade - open SQL Setup Wizard'
            Write-Host '5 Verify after upgrade and Windows restart'
            Write-Host '6 Rollback plan and instance-specific scripts'
            Write-Host '7 Optional full restore rehearsal + CHECKDB (expensive)'
            Write-Host '8 SQL 2022 CU/security patch (selected instance)'
            Write-Host '9 Optional full CHECKDB (expensive)'
            Write-Host '10 Register manually created backups | 11 Record external recovery'
            Write-Host '12 Optional compatibility 160 | 13 Completion summary'
            Write-Host '14 Migration: register already-approved existing level 160 (no ALTER)'
            Write-Host '0 Exit'
            $choice=(Read-Host 'Choose').Trim()
            try{
                switch($choice){
                    '1' {Invoke-VisibleAction 'Prepare' {Prepare-Local}}
                    '2' {Invoke-VisibleAction 'Backups' {
                        try{Assert-BackupPhase;Select-BackupFolder;Write-ReadinessReport 'NOT READY' 'New backup operation in progress.';Run-Worker Backup;Write-ReadinessReport 'BACKUPS COMPLETE; FINAL CHECK REQUIRED' 'Run menu 3 before Upgrade.'}
                        catch{$failure=$_;try{Write-ReadinessReport 'NOT READY' $failure.Exception.Message}catch{};throw $failure}
                    }}
                    '3' {Invoke-VisibleAction 'Final readiness check' {Final-Readiness}}
                    '4' {Invoke-VisibleAction 'Open SQL Setup Wizard' {Open-UpgradeWizard}}
                    '5' {Invoke-VisibleAction 'Verify' {Verify-Local}}
                    '6' {Invoke-VisibleAction 'Rollback plan and scripts' {Write-RecoveryPlan;Get-Content (Join-Path $WorkRoot 'ROLLBACK-PLAN.txt') | Out-Host}}
                    '7' {Invoke-VisibleAction 'Optional restore rehearsal' {Invoke-OptionalRehearsal}}
                    '8' {Invoke-VisibleAction 'SQL servicing' {Invoke-IntegratedPatch}}
                    '9' {Invoke-VisibleAction 'Full CHECKDB' {Write-Host 'Full CHECKDB scans database contents and can be I/O/CPU intensive.';if((Read-Host 'Type CHECKDB to proceed') -ceq 'CHECKDB'){Run-Worker CheckDB}}}
                    '10' {Invoke-VisibleAction 'Register manual backups' {Register-ManualBackups}}
                    '11' {Invoke-VisibleAction 'Record external recovery' {Set-ExternalRecovery}}
                    '12' {Invoke-VisibleAction 'Optional compatibility change' {Set-Compatibility160}}
                    '13' {Invoke-VisibleAction 'Completion summary' {Write-CompletionSummary}}
                    '14' {Invoke-VisibleAction 'Register existing compatibility approval' {Register-ExistingCompatibility}}
                    '0' {} default {Write-Host 'Unknown choice.'}
                }
            }catch{Write-Warning $_.Exception.Message}
        }while($choice -ne '0')
    }else{
        switch($Mode){
            Prepare {Prepare-Local} Preflight {Run-Worker Preflight}
            Backup {Assert-BackupPhase;Run-Worker Backup} Rehearse {Invoke-OptionalRehearsal}
            Recovery {Write-RecoveryPlan} Upgrade {Open-UpgradeWizard}
            Verify {Verify-Local} Restart {Restart-Local}
        }
    }
}finally{if($script:transcriptStarted){Stop-Transcript | Out-Null};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
