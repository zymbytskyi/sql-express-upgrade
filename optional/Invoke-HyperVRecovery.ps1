#Requires -Version 5.1
#Requires -RunAsAdministrator
# Optional infrastructure recovery tool. Run on the Hyper-V host, never inside the SQL guest.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Capture','Restore')][string]$Mode,
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$RecoveryDirectory,
    [switch]$ConfirmDiscardChanges
)
$ErrorActionPreference='Stop'
$vm=Get-VM -Name $VMName
if($vm.State -ne 'Off'){throw 'Gracefully shut down the VM first. This helper never force-powers off a server.'}
$RecoveryDirectory=[IO.Path]::GetFullPath($RecoveryDirectory).TrimEnd('\')
if($RecoveryDirectory -eq $PSScriptRoot -or $RecoveryDirectory.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep recovery images outside the package.'}
$file=Join-Path $RecoveryDirectory 'recovery.json'
if($Mode -eq 'Capture'){
    if(Test-Path $file){throw 'Recovery record already exists. Do not replace a retained recovery point.'}
    if(@(Get-VMSnapshot -VM $vm).Count){throw 'Existing VM checkpoints require review before a new capture.'}
    $disks=@(Get-VMHardDiskDrive -VM $vm)
    if(-not$disks.Count -or @($disks | Where-Object {-not$_.Path}).Count){throw 'Pass-through or absent disks are unsupported.'}
    New-Item -ItemType Directory $RecoveryDirectory -Force|Out-Null
    $bytes=[long](($disks | ForEach-Object {(Get-VHD $_.Path).FileSize} | Measure-Object -Sum).Sum)
    if((Get-Volume -FilePath $RecoveryDirectory).SizeRemaining -lt ($bytes+64GB)){throw 'Need full export space plus 64 GiB host safety headroom.'}
    $checkpoint=Checkpoint-VM -VM $vm -SnapshotName ('BeforeLocalSqlUpgrade-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmss')) -Passthru
    $record=[ordered]@{VMId=$vm.Id.ToString();VMName=$vm.Name;CheckpointId=$checkpoint.Id.ToString();CapturedUtc=[datetime]::UtcNow.ToString('o');Phase='CheckpointCreated';ExportFiles=@()}
    $record|ConvertTo-Json -Depth 6|Set-Content $file -Encoding UTF8
    $export=Join-Path $RecoveryDirectory 'Export'
    Export-VMSnapshot -VMSnapshot $checkpoint -Path $export
    $record.ExportFiles=@(Get-ChildItem $export -Recurse -File|ForEach-Object {[pscustomobject]@{Path=$_.FullName;Sha256=(Get-FileHash $_.FullName).Hash}})
    if(-not$record.ExportFiles.Count){throw 'Export is empty; do not approve recovery readiness.'}
    $record.Phase='Captured';$record|ConvertTo-Json -Depth 6|Set-Content $file -Encoding UTF8
    Write-Host "Recovery captured. Reference: $($checkpoint.Id). Start the VM and continue the LOCAL menu."
}else{
    if(-not$ConfirmDiscardChanges){throw 'Restore discards ALL changes after capture. Supply -ConfirmDiscardChanges after an explicit recovery decision.'}
    $record=Get-Content $file -Raw|ConvertFrom-Json
    if($record.VMId -ne $vm.Id.ToString() -or $record.VMName -ne $vm.Name -or $record.Phase -ne 'Captured'){throw 'Recovery identity/status mismatch.'}
    $checkpoint=@(Get-VMSnapshot -VM $vm|Where-Object Id -EQ $record.CheckpointId)
    if($checkpoint.Count -ne 1){throw 'Recorded checkpoint missing. Follow the backup-provider export-import recovery procedure.'}
    Restore-VMSnapshot -VMSnapshot $checkpoint[0] -Confirm:$false
    Write-Host 'Recorded checkpoint restored. Start the VM and validate original SQL build, data and application/domain access.'
}
