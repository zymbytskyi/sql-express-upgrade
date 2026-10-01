#Requires -Version 5.1
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$worker=Join-Path $PSScriptRoot 'Invoke-SqlExpressUpgrade.ps1'
$WorkRoot=Join-Path $env:TEMP ('SqlMenuFixture-'+[guid]::NewGuid().ToString('N'))
$InstanceName='APPDATA';$planPath=Join-Path $WorkRoot 'plan.json'
. (Join-Path $PSScriptRoot 'ConsoleActions.ps1')
$script:state=[pscustomobject]@{Phase='Prepared';BootBeforeSetup=''}
$script:build='14.0.3485.1';$script:existing=$false;$script:launched=0;$script:checks=@();$script:cacheValid=$true
function Get-Process {param($Name,$ErrorAction) if($script:existing){[pscustomobject]@{Id=123}}}
function Get-LiveBuild {$script:build}
function Get-Boot {'before'}
function Get-SourceLanguage {param($Instance) 1033}
function Assert-ExtractedMedia {param($Directory,$Language)}
function Save-State {}
function Run-Worker {param($Action) $script:checks+=,$Action}
function Start-Process {param($FilePath,$ArgumentList) $script:launched++;$script:arguments=$ArgumentList}
# Worker invocations are captured instead of executing SQL.
$worker={param($Mode,$WorkRoot,$InstanceName,$ValidationMode) $script:checks+=,$Mode;if(-not$script:cacheValid){throw 'Invalidated cache fixture'}}
if([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){
    $blocked=$false;try{Open-UpgradeWizard}catch{$blocked=$true}
    if(-not$blocked -or $script:launched){throw 'Session 0 GUI guard failed'}
}else{
    Open-UpgradeWizard
    if($script:launched -ne 1 -or $script:arguments -notcontains '/INSTANCENAME=APPDATA' -or $script:arguments -contains '/Q'){throw 'Interactive selected-instance launcher failed'}
    if($script:checks -notcontains 'ReuseValidation' -or $script:checks -contains 'ValidateBackups' -or $script:checks -contains 'Rehearse'){throw 'Launcher repeated expensive validation'}
    $script:cacheValid=$false;$blocked=$false;try{Open-UpgradeWizard}catch{$blocked=$true}
    if(-not$blocked -or $script:launched -ne 1){throw 'Invalid validation launched Setup'}
}
$script:existing=$true;$blocked=$false;try{Open-UpgradeWizard}catch{$blocked=$true}
if(-not$blocked){throw 'Duplicate Setup not blocked'}
'PASS: current interactive launcher, cache-only readiness, invalidation and existing Setup guards. All process/SQL calls mocked.'
