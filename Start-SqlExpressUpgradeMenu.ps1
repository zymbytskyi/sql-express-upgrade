#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$WorkRoot)
$ErrorActionPreference='Stop'
if(-not $WorkRoot){$WorkRoot=Read-Host 'Campaign directory on the Hyper-V host (outside Git; enough space for a full VM export)'}
$statePath=Join-Path $WorkRoot 'campaign.json'
if(Test-Path $statePath){$vmName=(Get-Content $statePath -Raw | ConvertFrom-Json).VMName}
else{$vmName=Read-Host 'Exact Hyper-V VM name'}
$credential=Get-Credential -Message 'Guest Windows administrator and SQL sysadmin (kept in memory only)'
$controller=Join-Path $PSScriptRoot 'Invoke-HyperVSqlExpressUpgrade.ps1'
do {
    Write-Host "`nSQL Express 2017 -> 2022 | $vmName | $WorkRoot"
    if(Test-Path $statePath){Write-Host ('Phase: '+(Get-Content $statePath -Raw | ConvertFrom-Json).Phase)}
    Write-Host 'Preparation day: 1 Configure | 2 Download media | 3 Deploy | 4 Prepare | 5 Preflight | 6 Backup | 7 Restore rehearsal'
    Write-Host 'Upgrade day: 8 Final backups + cold recovery capture | 9 Upgrade | 10 Verify | 11 Rollback | 0 Exit'
    $choice=Read-Host 'Choose'
    $common=@{VMName=$vmName;WorkRoot=$WorkRoot;Credential=$credential}
    try {
        switch($choice) {
            '1' {
                $instance=Read-Host 'Instance name [SQLEXPRESS]';if(-not $instance){$instance='SQLEXPRESS'}
                $backup=Read-Host 'Existing guest SQL backup directory'
                $transport=Read-Host 'Transport: 1 PowerShell Direct (default), 2 existing WinRM HTTPS'
                if($transport -eq '2'){
                    $common.GuestAddress=Read-Host 'Guest HTTPS address'
                    $common.HttpsCertificateThumbprint=Read-Host 'Exact TLS certificate thumbprint from a trusted channel'
                }
                & $controller @common -Mode Configure -InstanceName $instance -GuestBackupDirectory $backup
            }
            '2' { & (Join-Path $PSScriptRoot 'Save-Sql2022ExpressMedia.ps1') -Destination (Join-Path $WorkRoot 'Downloads') }
            '3' { $media=Read-Host 'Host full path to SQLEXPR_x64_ENU.exe'; & $controller @common -Mode Deploy -MediaPath $media }
            '4' { & $controller @common -Mode Prepare }
            '5' { & $controller @common -Mode Preflight }
            '6' { & $controller @common -Mode Backup }
            '7' { & $controller @common -Mode Rehearse }
            '8' {
                Write-Host 'Stop application services, schedulers and all other writers. Keep them stopped until final acceptance or rollback.'
                if((Read-Host "Type $vmName to confirm downtime and stopped writers") -ceq $vmName){& $controller @common -Mode Capture -ConfirmDowntime}
            }
            '9' {
                if((Read-Host "Keep writers stopped. Type UPGRADE $vmName") -ceq "UPGRADE $vmName"){& $controller @common -Mode Upgrade -ConfirmDowntime}
            }
            '10' { & $controller @common -Mode Verify }
            '11' {
                Write-Host 'ALL VM changes after recovery capture will be discarded, including non-SQL files and database writes.'
                if((Read-Host "Type ROLLBACK $vmName") -ceq "ROLLBACK $vmName"){& $controller @common -Mode Rollback -ConfirmDowntime -ConfirmDiscardChanges}
            }
            '0' {} default {Write-Host 'Unknown choice.'}
        }
    }catch{Write-Warning $_.Exception.Message}
}while($choice -ne '0')
$credential=$null
