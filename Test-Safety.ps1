#Requires -Version 7.0
<# .SYNOPSIS Exercises fail-closed source checks without connecting to SQL or Hyper-V. #>
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path=Join-Path $PSScriptRoot 'Invoke-SqlExpressUpgrade.ps1'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join '; ')}
foreach($name in @('Assert-Inventory','Quote-Sql','Quote-Name')){
    $function=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($function.Extent.Text))
}
function Get-Service {param($Name,$ErrorAction) $null}
function New-Inventory {
    [pscustomobject]@{
        Server=[pscustomobject]@{Machine=$env:COMPUTERNAME;EngineEdition=4;Build='14.0.1000.169';Edition='Express Edition';IsSysadmin=1;Clustered=0;Hadr=0}
        Databases=@([pscustomobject]@{Name='Test';State='ONLINE';Encrypted=$false;Published=$false;Subscribed=$false;MergePublished=$false;SnapshotSource=[DBNull]::Value;DataBytes=1MB})
    }
}
$count=0
function Expect-Blocked([string]$Name,[scriptblock]$Change){
    $inventory=New-Inventory
    & $Change $inventory
    $blocked=$false
    try{Assert-Inventory $inventory}catch{$blocked=$true}
    if(-not $blocked){throw "Safety regression: $Name was accepted."}
    $script:count++;Write-Output "PASS: $Name blocked."
}
Assert-Inventory (New-Inventory)
$count++;Write-Output 'PASS: local SQL 2017 Express baseline accepted.'
Expect-Blocked 'SQL 2025 is not SQL 2017' {param($i)$i.Server.Build='17.0.1000.7'}
Expect-Blocked 'SQL 2022 cannot be upgraded again' {param($i)$i.Server.Build='16.0.1000.6'}
Expect-Blocked 'Developer edition' {param($i)$i.Server.EngineEdition=3}
Expect-Blocked 'Remote instance' {param($i)$i.Server.Machine='OTHER-SERVER'}
Expect-Blocked 'Missing sysadmin' {param($i)$i.Server.IsSysadmin=0}
Expect-Blocked 'Clustered instance' {param($i)$i.Server.Clustered=1}
Expect-Blocked 'Always On' {param($i)$i.Server.Hadr=1}
Expect-Blocked 'Offline database' {param($i)$i.Databases[0].State='OFFLINE'}
Expect-Blocked 'Replication subscriber' {param($i)$i.Databases[0].Subscribed=$true}
Expect-Blocked 'Database snapshot' {param($i)$i.Databases[0].SnapshotSource=5}
Expect-Blocked 'Express size ceiling' {param($i)$i.Databases[0].DataBytes=10GB}
if((Quote-Sql "a'b") -cne "N'a''b'" -or (Quote-Name 'a]b') -cne '[a]]b]'){throw 'SQL escaping failed.'}
$count++;Write-Output 'PASS: SQL literal and identifier escaping.'
Write-Output "$count safety assertions passed. No live upgrade or rollback was performed."

# Catch incorrect Hyper-V cmdlet parameter names before a live run.
$controller=Join-Path $PSScriptRoot 'Invoke-HyperVSqlExpressUpgrade.ps1'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($controller,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join '; ')}
foreach($command in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)){
    $name=$command.GetCommandName()
    if($name -notin @('Get-VM','Start-VM','Get-VMHardDiskDrive','Get-VMSnapshot','Checkpoint-VM','Export-VMSnapshot','Restore-VMSnapshot')){continue}
    $definition=Get-Command $name -ErrorAction Stop
    foreach($parameter in $command.CommandElements | Where-Object {$_ -is [System.Management.Automation.Language.CommandParameterAst]}){
        if(-not $definition.Parameters.ContainsKey($parameter.ParameterName)){throw "Unsupported Hyper-V parameter: $name -$($parameter.ParameterName)"}
    }
}
Write-Output 'PASS: controller Hyper-V parameters match the installed cmdlets.'
