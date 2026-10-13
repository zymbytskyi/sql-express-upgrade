#Requires -Version 5.1
# Isolated rejection/acceptance tests; no installer, SQL or VM is executed.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$WorkRoot=Join-Path $env:TEMP ('Slipstream fixture '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $WorkRoot|Out-Null
$InstanceName='APPDATA';$planPath=Join-Path $WorkRoot 'plan.json'
$worker=Join-Path $PSScriptRoot 'Invoke-SqlExpressUpgrade.ps1'
. (Join-Path $PSScriptRoot 'ConsoleActions.ps1')
function Check($Value,[string]$Message){if(-not$Value){throw $Message};Write-Host "PASS: $Message"}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed $Message}
Save-Json $planPath @{Schema=1;Id='fixture';Computer=$env:COMPUTERNAME;Instance=$InstanceName}
$script:state=[pscustomobject]@{BootBeforeSetup='before'}
$script:build='16.0.4295.3'
function Get-LiveBuild {$script:build}
try {
    Reject {Get-SlipstreamArguments} 'missing CU target blocks launch'
    $folder=Join-Path $WorkRoot 'Updates\KB5104824-16.0.4295.3'
    New-Item -ItemType Directory $folder|Out-Null
    $package=Join-Path $folder 'SQLServer2022-KB5104824-x64.exe'
    'fixture bytes'|Set-Content $package
    $target=@{Schema=1;PlanId='fixture';Computer=$env:COMPUTERNAME;Instance=$InstanceName;KB='KB5104824';TargetBuild='16.0.4295.3';PackagePath=$package;Sha256=(Get-FileHash $package).Hash;Status='Prepared';PreparedUtc=[datetime]::UtcNow.ToString('o')}
    Save-Json (Join-Path $WorkRoot 'slipstream.json') $target
    $script:signature='Valid';$script:packageBuild=4295
    function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status=$script:signature;SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}}}
    function Get-Item {param($LiteralPath) [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductMajorPart=16;ProductMinorPart=0;ProductBuildPart=$script:packageBuild;ProductPrivatePart=3}}}
    $arguments=@(Get-SlipstreamArguments)
    Check ($arguments -contains '/UPDATEENABLED=True' -and $arguments -contains '/UIMODE=Normal' -and $arguments -notcontains '/Q' -and $arguments -contains '/INSTANCENAME=APPDATA') 'interactive selected-instance CU arguments'
    Check (($arguments|Where-Object {$_ -like '/UPDATESOURCE=*'}) -eq ('/UPDATESOURCE="'+$folder+'"')) 'UpdateSource with spaces stays quoted'
    $script:signature='NotSigned';Reject {Assert-SlipstreamMedia} 'invalid signature blocks launch';$script:signature='Valid'
    $script:packageBuild=4000;Reject {Assert-SlipstreamMedia} 'wrong package version blocks launch';$script:packageBuild=4295
    Add-Content $package 'tampered';Reject {Assert-SlipstreamMedia} 'changed CU bytes block launch'
    'fixture bytes'|Set-Content $package
    $extra=Join-Path $folder 'other.exe';'extra'|Set-Content $extra
    Reject {Assert-SlipstreamMedia} 'additional update package blocks launch';Remove-Item -LiteralPath $extra
    $target.PlanId='foreign';Save-Json (Join-Path $WorkRoot 'slipstream.json') $target
    Reject {Assert-SlipstreamMedia} 'foreign campaign target rejected';$target.PlanId='fixture'
    Save-Json (Join-Path $WorkRoot 'slipstream.json') $target
    function Get-LatestUpdate {throw 'Network must not be used for a pinned target'}
    Prepare-Slipstream
    Check $true 'repeat Prepare revalidates pinned CU without network or target change'
    $script:build='16.0.1000.6';Reject {Assert-SlipstreamBuild} 'RTM cannot pass CU acceptance'
    $script:build='16.0.4300.1';Reject {Assert-SlipstreamBuild} 'unapproved newer build cannot pass first acceptance'
    $script:build='16.0.4295.3';Assert-SlipstreamBuild;Complete-SlipstreamVerification
    Check ((Read-SlipstreamTarget).Status -eq 'Verified') 'exact build accepted and servicing state recorded'
    Check ((Get-Content (Join-Path $WorkRoot 'patch-state.json') -Raw|ConvertFrom-Json).Method -eq 'Slipstream') 'compatibility and completion consume integrated servicing evidence'
    $script:build='16.0.4300.1';Assert-SlipstreamBuild
    Check $true 'later servicing is allowed after initial CU acceptance'
    $script:state|Add-Member NoteProperty SlipstreamSha256 ('B'*64)
    $script:state|Add-Member NoteProperty SlipstreamBuild '16.0.4295.3'
    Reject {Assert-SlipstreamBuild} 'target change after Wizard launch rejected'
    Remove-Item -LiteralPath (Join-Path $WorkRoot 'slipstream.json')
    Reject {Assert-SlipstreamBuild} 'deleted target cannot bypass acceptance after Wizard launch'
} finally {
    # Delete only this uniquely created fixture tree after validating its location.
    $safe=[IO.Path]::GetFullPath($WorkRoot)
    if(-not$safe.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\Slipstream fixture ',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $safe -Recurse -Force
}
