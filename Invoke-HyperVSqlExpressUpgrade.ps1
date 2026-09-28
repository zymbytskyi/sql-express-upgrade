#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Controls one Hyper-V SQL Express upgrade campaign using PowerShell Direct.
.DESCRIPTION
Credentials remain in memory. Cold checkpoints and exported recovery images
are retained. No VM, checkpoint, export, or backup is automatically deleted.
#>
[CmdletBinding()]
param(
    [ValidateSet('Configure','Deploy','Prepare','Preflight','Backup','Rehearse','Capture','Upgrade','Verify','Rollback')]
    [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$WorkRoot,
    [pscredential]$Credential,
    [string]$GuestWorkRoot = 'C:\SqlExpressUpgradeData',
    [string]$InstanceName = 'SQLEXPRESS',
    [string]$GuestBackupDirectory = 'C:\SqlExpress\Backup',
    [string]$MediaPath,
    [string]$GuestAddress,
    [string]$HttpsCertificateThumbprint,
    [switch]$ConfirmDowntime,
    [switch]$ConfirmDiscardChanges
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
if ($WorkRoot -eq $PSScriptRoot -or $WorkRoot.StartsWith($PSScriptRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery data must be outside the source package.' }
$statePath=Join-Path $WorkRoot 'campaign.json'
$vm=Get-VM -Name $VMName -ErrorAction Stop
if(Test-Path $statePath){
    $saved=Get-Content $statePath -Raw | ConvertFrom-Json
    if($saved.VMId -ne $vm.Id.ToString()){throw 'Saved campaign belongs to another VM.'}
    if(($GuestAddress -and $GuestAddress -ne $saved.GuestAddress) -or ($HttpsCertificateThumbprint -and $HttpsCertificateThumbprint -ne $saved.HttpsCertificateThumbprint)){throw 'Transport identity changed. Review and create a new campaign.'}
    $GuestAddress=$saved.GuestAddress;$HttpsCertificateThumbprint=$saved.HttpsCertificateThumbprint
}
. (Join-Path $PSScriptRoot 'GuestTransport.ps1')
$guestTarget=Get-UpgradeGuestTransport -VMName $VMName -Address $GuestAddress -CertificateThumbprint $HttpsCertificateThumbprint
if($vm.Generation -ne 2) { throw 'This package requires a Generation 2 VM.' }
if(-not $Credential){$Credential=Get-Credential -Message "Windows administrator and SQL sysadmin on $VMName"}
function Save-State($State) {
    $State | ConvertTo-Json -Depth 12 | Set-Content "$statePath.tmp" -Encoding UTF8
    Move-Item "$statePath.tmp" $statePath -Force
}
function Guest($Block,$Arguments=@()) {
    Invoke-Command @guestTarget -Credential $Credential -ScriptBlock $Block -ArgumentList $Arguments -ErrorAction Stop
}
function Wait-Guest([string]$PreviousBoot) {
    $deadline=[datetime]::UtcNow.AddMinutes(10)
    do {
        $job=Invoke-Command @guestTarget -Credential $Credential -ScriptBlock {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")} -AsJob
        try {
            if(Wait-Job $job -Timeout 15){$result=Receive-Job $job -ErrorAction Stop; if($result -and (!$PreviousBoot -or $result -ne $PreviousBoot)){return}}
        } catch {} finally {Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        Start-Sleep 5
    }while([datetime]::UtcNow -lt $deadline)
    throw 'Guest readiness timed out. Inspect VM; do not rerun Setup blindly.'
}
function Stop-Guest {
    # Graceful shutdown only: never turn off or save a running database VM.
    Guest {shutdown.exe /s /t 0 /d p:4:2 /c 'SQL Express upgrade recovery capture'} | Out-Null
    $deadline=[datetime]::UtcNow.AddMinutes(5)
    do {if((Get-VM -Id $vm.Id).State -eq 'Off'){return};Start-Sleep 3}while([datetime]::UtcNow -lt $deadline)
    throw 'Graceful shutdown timed out; no force-off was attempted.'
}
function Run-Worker([string]$Action) {
    Guest {
        param($Action,$Root,$Instance,$Backup)
        $ErrorActionPreference='Stop'
        & C:\SqlExpressUpgrade\Invoke-SqlExpressUpgrade.ps1 -Mode $Action -WorkRoot $Root -InstanceName $Instance -BackupDirectory $Backup -MediaPath C:\SqlExpressUpgrade\SQLEXPR2022_x64_ENU.exe
    } @($Action,$GuestWorkRoot,$InstanceName,$GuestBackupDirectory)
}
if($Mode -eq 'Configure') {
    if(Test-Path $statePath){throw 'Campaign exists. Use its saved settings or choose a new directory.'}
    if(@(Get-VMSnapshot -VM $vm).Count){throw 'Start with a VM without checkpoints.'}
    $disks=@(Get-VMHardDiskDrive -VM $vm)
    if(-not $disks.Count -or @($disks | Where-Object {-not $_.Path}).Count){throw 'Pass-through or absent disks are unsupported.'}
    $computer=Guest {Get-CimInstance Win32_ComputerSystem | Select-Object Name,Domain,DomainRole}
    if($computer.DomainRole -ge 4){throw 'A domain controller cannot be an upgrade target.'}
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    Save-State ([ordered]@{Schema=1;VMId=$vm.Id.ToString();VMName=$VMName;Computer=$computer.Name;Domain=$computer.Domain;GuestAddress=$GuestAddress;HttpsCertificateThumbprint=$HttpsCertificateThumbprint;GuestWorkRoot=$GuestWorkRoot;Instance=$InstanceName;BackupDirectory=$GuestBackupDirectory;Phase='Configured';CheckpointId='';ExportPath='';ExportFiles=@();SourceBuild='';CapturedUtc='';SetupExitCode=$null})
    Write-Host "Configured $VMName ($($vm.Id)). Next: Deploy."
    return
}
$state=Get-Content $statePath -Raw | ConvertFrom-Json
if($state.Schema -ne 1 -or $state.VMId -ne $vm.Id.ToString() -or $state.VMName -ne $VMName){throw 'Campaign/VM identity mismatch.'}
$GuestWorkRoot=$state.GuestWorkRoot;$InstanceName=$state.Instance;$GuestBackupDirectory=$state.BackupDirectory
switch($Mode) {
    Deploy {
        if($state.Phase -ne 'Configured'){throw 'Deploy is allowed only before preparation.'}
        if(-not(Test-Path $MediaPath -PathType Leaf)){throw 'Provide local SQL 2022 Express full media with -MediaPath.'}
        $sig=Get-AuthenticodeSignature $MediaPath
        if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation' -or (Get-Item $MediaPath).VersionInfo.ProductMajorPart -ne 16){throw 'Require signed Microsoft SQL 2022 media.'}
        $session=New-PSSession @guestTarget -Credential $Credential
        try {
            Invoke-Command -Session $session -ScriptBlock {New-Item -ItemType Directory C:\SqlExpressUpgrade -Force | Out-Null}
            Copy-Item (Join-Path $PSScriptRoot 'Invoke-SqlExpressUpgrade.ps1') -Destination C:\SqlExpressUpgrade -ToSession $session -Force
            $localHash=(Get-FileHash $MediaPath).Hash
            $remoteHash=Invoke-Command -Session $session -ScriptBlock {if(Test-Path C:\SqlExpressUpgrade\SQLEXPR2022_x64_ENU.exe){(Get-FileHash C:\SqlExpressUpgrade\SQLEXPR2022_x64_ENU.exe).Hash}}
            if($remoteHash -ne $localHash){Copy-Item $MediaPath -Destination C:\SqlExpressUpgrade\SQLEXPR2022_x64_ENU.exe -ToSession $session -Force}
        }finally{Remove-PSSession $session}
        Run-Worker Configure
        $state.Phase='Deployed';Save-State $state
    }
    Prepare {Run-Worker Prepare;$state.Phase='Prepared';Save-State $state}
    Preflight {Run-Worker Preflight}
    Backup {Run-Worker Backup}
    Rehearse {Run-Worker Rehearse}
    Capture {
        if(-not $ConfirmDowntime){throw 'Stop applications/writers and supply -ConfirmDowntime. Keep them stopped through acceptance or rollback.'}
        if($state.CheckpointId){throw 'Recovery point already exists. Use a new campaign for another maintenance window.'}
        Run-Worker Preflight
        # Always refresh backups after the operator has stopped application writes.
        Run-Worker Backup
        Run-Worker Rehearse
        $state.SourceBuild=Guest {param($Root);(Get-Content (Join-Path $Root 'plan.json') -Raw | ConvertFrom-Json).SourceBuild} @($GuestWorkRoot)
        $disks=@(Get-VMHardDiskDrive -VM $vm)
        $allocated=[long](($disks | ForEach-Object {(Get-VHD $_.Path).FileSize} | Measure-Object -Sum).Sum)
        $volume=Get-Volume -FilePath $WorkRoot
        if($volume.SizeRemaining -lt ($allocated+64GB)){throw 'Need export space plus 64 GiB host safety headroom.'}
        Stop-Guest
        # The VM is OFF, so disk contents and all SQL instance metadata are consistent.
        $checkpoint=Checkpoint-VM -VM $vm -SnapshotName ('Sql2017BeforeUpgrade-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmss')) -Passthru
        $state.CheckpointId=$checkpoint.Id.ToString();$state.Phase='CaptureInProgress';Save-State $state
        $export=Join-Path $WorkRoot 'RecoveryExport'
        Export-VMSnapshot -VMSnapshot $checkpoint -Path $export
        $state.ExportPath=$export
        $state.ExportFiles=@(Get-ChildItem $export -File -Recurse | ForEach-Object {[pscustomobject]@{Path=$_.FullName;Sha256=(Get-FileHash $_.FullName).Hash}})
        if(-not $state.ExportFiles.Count){throw 'Recovery export is empty.'}
        $state.CapturedUtc=[datetime]::UtcNow.ToString('o');$state.Phase='RecoveryCaptured';Save-State $state
        Start-VM -VM $vm | Out-Null;Wait-Guest
        Write-Host 'Recovery checkpoint and independent export captured. Keep application writes stopped.'
    }
    Upgrade {
        if(-not $ConfirmDowntime){throw 'Keep application writes stopped and supply -ConfirmDowntime.'}
        if($state.Phase -ne 'RecoveryCaptured'){throw 'Capture a fresh recovery point before Upgrade. A failed/interrupted Setup requires diagnosis or rollback.'}
        if(([datetime]::UtcNow-[datetime]$state.CapturedUtc).TotalHours -gt 2){throw 'Recovery point is over 2 hours old. Use a fresh campaign/recovery point.'}
        if(-not(Get-VMSnapshot -VM $vm | Where-Object Id -EQ $state.CheckpointId)){throw 'Recovery checkpoint is missing.'}
        foreach($file in $state.ExportFiles){if((Get-FileHash $file.Path).Hash -ne $file.Sha256){throw 'Recovery export hash mismatch.'}}
        Run-Worker Preflight
        $state.Phase='Upgrading';Save-State $state
        $code=Guest {
            param($Root,$Instance)
            $setup=Join-Path $Root 'Media2022\setup.exe'
            $process=Start-Process $setup -ArgumentList @('/Q','/ACTION=Upgrade',"/INSTANCENAME=$Instance",'/IACCEPTSQLSERVERLICENSETERMS','/UPDATEENABLED=False') -WindowStyle Hidden -Wait -PassThru
            $process.ExitCode
        } @($GuestWorkRoot,$InstanceName)
        $state.SetupExitCode=$code
        if($code -notin @(0,3010)){$state.Phase='SetupFailed';Save-State $state;throw "SQL Setup failed ($code). Inspect guest SQL Setup logs; recovery remains intact."}
        $state.Phase='RestartRequired';Save-State $state
        $previousBoot=Guest {(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")}
        Guest {shutdown.exe /r /t 5 /d p:4:2 /c 'SQL Express version upgrade'} | Out-Null
        Start-Sleep 15;Wait-Guest -PreviousBoot $previousBoot
        Run-Worker Verify
        $state.Phase='DatabaseChecksPassed';Save-State $state
    }
    Verify {Wait-Guest;Run-Worker Verify;$state.Phase='DatabaseChecksPassed';Save-State $state}
    Rollback {
        if(-not $ConfirmDowntime -or -not $ConfirmDiscardChanges){throw 'Rollback discards ALL VM changes after capture. Stop writers; supply -ConfirmDowntime -ConfirmDiscardChanges.'}
        if(-not $state.CheckpointId){throw 'No recovery checkpoint recorded.'}
        $checkpoint=@(Get-VMSnapshot -VM $vm | Where-Object Id -EQ $state.CheckpointId)
        if($checkpoint.Count -ne 1){throw 'Exact recovery checkpoint missing. Use the retained export; do not select another checkpoint.'}
        if((Get-VM -Id $vm.Id).State -ne 'Off'){Stop-Guest}
        $state.Phase='RollingBack';Save-State $state
        Restore-VMSnapshot -VMSnapshot $checkpoint[0] -Confirm:$false
        Start-VM -VM $vm | Out-Null;Wait-Guest
        Run-Worker Preflight
        $secure=Guest {if((Get-CimInstance Win32_ComputerSystem).PartOfDomain){Test-ComputerSecureChannel}else{$true}}
        if(-not $secure){throw 'SQL rollback completed but domain trust requires repair before acceptance.'}
        $state.Phase='RolledBack';Save-State $state
        Write-Host 'Restored the full pre-upgrade VM and verified SQL 2017/domain trust. Application acceptance is still required.'
    }
}
