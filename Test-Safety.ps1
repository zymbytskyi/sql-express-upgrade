#Requires -Version 5.1
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

. (Join-Path $PSScriptRoot 'LocalInstance.ps1')
function Candidate($Name,$Version='14.0.1000.169',$Status='Running'){[pscustomobject]@{Instance=$Name;Version=$Version;Status=$Status}}
if((Select-LocalExpressInstance -Candidates @(Candidate 'MSSQLSERVER')).Instance -ne 'MSSQLSERVER'){throw 'Default instance detection failed.'}
if((Select-LocalExpressInstance -Candidates @(Candidate 'APPDATA')).Instance -ne 'APPDATA'){throw 'Custom named instance detection failed.'}
$blocked=$false;try{Select-LocalExpressInstance -Candidates @((Candidate 'FIRST'),(Candidate 'SECOND'))|Out-Null}catch{$blocked=$true};if(-not$blocked){throw 'Ambiguous instance selection was not blocked.'}
if((Select-LocalExpressInstance -Candidates @((Candidate 'FIRST'),(Candidate 'SECOND')) -Requested SECOND).Instance -ne 'SECOND'){throw 'Explicit local selection failed.'}
foreach($test in @(@{Items=@();Name='No local instance'},@{Items=@(Candidate 'APP' '16.0.1000.6');Name='Already upgraded'},@{Items=@(Candidate 'APP' '14.0.1000.169' 'Stopped');Name='Stopped instance'})){
    $blocked=$false;try{Select-LocalExpressInstance -Candidates $test.Items|Out-Null}catch{$blocked=$true};if(-not$blocked){throw "$($test.Name) was not blocked."}
}
$blocked=$false;try{Select-LocalExpressInstance -Candidates @(Candidate 'APP') -Requested 'REMOTE\APP'|Out-Null}catch{$blocked=$true};if(-not$blocked){throw 'Remote target was not rejected.'}
Write-Output 'PASS: eight local discovery/selection cases, including default, custom named, multiple, stopped and remote targets.'
