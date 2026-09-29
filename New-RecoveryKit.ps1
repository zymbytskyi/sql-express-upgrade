#Requires -Version 5.1
param([Parameter(Mandatory)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$plan=Get-Content (Join-Path $WorkRoot 'plan.json') -Raw | ConvertFrom-Json
$kit=Join-Path $WorkRoot 'Rollback'
New-Item -ItemType Directory $kit -Force | Out-Null
[ordered]@{Computer=$plan.Computer;Instance=$plan.Instance;SourceBuild=$plan.SourceBuild;Databases=@($plan.Baseline.Databases.Name);BackupDirectory=$plan.BackupDirectory;PlanId=$plan.Id} |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $kit 'RecoveryTarget.json') -Encoding UTF8
Copy-Item (Join-Path $PSScriptRoot 'optional\Invoke-HyperVRecovery.ps1') $kit -Force
@'
#Requires -Version 5.1
#Requires -RunAsAdministrator
# Run inside the recovered SQL server with SQL sysadmin rights.
$ErrorActionPreference='Stop'
$target=Get-Content (Join-Path $PSScriptRoot 'RecoveryTarget.json') -Raw | ConvertFrom-Json
if($env:COMPUTERNAME -ne $target.Computer){throw 'Wrong recovery computer.'}
$server=if($target.Instance -eq 'MSSQLSERVER'){'lpc:.'}else{'lpc:.\'+$target.Instance}
$connection=[Data.SqlClient.SqlConnection]::new("Server=$server;Database=master;Integrated Security=True;Connect Timeout=10")
try {
    $connection.Open()
    $cmd=$connection.CreateCommand()
    $cmd.CommandText="SELECT CONVERT(nvarchar(32),SERVERPROPERTY('ProductVersion'))"
    $build=[string]$cmd.ExecuteScalar()
    if($build -ne $target.SourceBuild){throw "Expected original build $($target.SourceBuild), found $build"}
    foreach($db in $target.Databases){
        $cmd=$connection.CreateCommand();$cmd.CommandTimeout=0
        $cmd.CommandText='SELECT state_desc FROM sys.databases WHERE name=@name'
        [void]$cmd.Parameters.AddWithValue('@name',[string]$db)
        if([string]$cmd.ExecuteScalar() -ne 'ONLINE'){throw "Database missing or not ONLINE: $db"}
        $cmd=$connection.CreateCommand();$cmd.CommandTimeout=0
        $cmd.CommandText='DBCC CHECKDB ('+"N'"+$db.Replace("'","''")+"') WITH NO_INFOMSGS, ALL_ERRORMSGS"
        [void]$cmd.ExecuteNonQuery()
        Write-Host "PASS: $db ONLINE and CHECKDB"
    }
    Write-Host "PASS: original SQL build $build. Test application logins, representative data, reads/writes and domain trust before reopening traffic."
} finally {$connection.Dispose()}
'@ | Set-Content (Join-Path $kit 'Verify-Rollback.ps1') -Encoding UTF8
foreach($mode in @('Capture','Restore')){
    $template=@'
#Requires -Version 5.1
#Requires -RunAsAdministrator
# Run on the Hyper-V HOST. Guest computer names are not reliable VM names.
param([Parameter(Mandatory)][string]$VMName,[Parameter(Mandatory)][string]$RecoveryDirectory)
$ErrorActionPreference='Stop'
$target=Get-Content (Join-Path $PSScriptRoot 'RecoveryTarget.json') -Raw | ConvertFrom-Json
Write-Host "Recovery target: $($target.Computer)\$($target.Instance), SQL $($target.SourceBuild). Host VM selected: $VMName"
if((Read-Host 'Confirm this VM contains that SQL server by typing its exact VM name') -cne $VMName){throw 'VM identity not confirmed.'}
__CONFIRM__
& (Join-Path $PSScriptRoot 'Invoke-HyperVRecovery.ps1') -Mode __MODE__ -VMName $VMName -RecoveryDirectory $RecoveryDirectory __SWITCH__
'@
    $confirm=if($mode -eq 'Restore'){"if((Read-Host 'Restore discards all changes after capture. Type RESTORE to proceed') -cne 'RESTORE'){throw 'Restore canceled.'}"}else{''}
    $switch=if($mode -eq 'Restore'){'-ConfirmDiscardChanges'}else{''}
    $template.Replace('__CONFIRM__',$confirm).Replace('__MODE__',$mode).Replace('__SWITCH__',$switch) | Set-Content (Join-Path $kit "$mode-HyperV.ps1") -Encoding UTF8
}
Write-Host "Instance-specific recovery scripts generated: $kit"
