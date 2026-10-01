#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Version='v0.4.0-rc1')
$ErrorActionPreference='Stop'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if($OutputDirectory -eq $PSScriptRoot -or $OutputDirectory.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Build outside the source package.'}
$files=@('Install.ps1','Start-SqlExpressUpgradeMenu.ps1','Invoke-SqlExpressUpgrade.ps1','LocalInstance.ps1','OperatorGuidance.ps1','New-RecoveryKit.ps1','Save-Sql2022ExpressMedia.ps1','MediaSupport.ps1','WorkflowSupport.ps1','WorkflowOperations.ps1','ConsoleActions.ps1','IntegratedPatch.ps1','SelfPatchBase.ps1','THIRD-PARTY-LICENSE.txt','README.md','PRODUCTION-RUNBOOK.md','MIGRATION.md','VALIDATION.md','CHANGELOG.md','Test-Safety.ps1','Test-Menu.ps1','Test-OperatorGuidance.ps1','Test-ProductionFindings.ps1','Build-Release.ps1','optional\Invoke-HyperVRecovery.ps1')
foreach($file in $files){
    $path=Join-Path $PSScriptRoot $file
    if(-not(Test-Path $path -PathType Leaf)){throw "Missing release file: $file"}
    if($file -like '*.ps1'){$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors);if($errors){throw $errors}}
}
foreach($test in @('Test-Safety.ps1','Test-Menu.ps1','Test-OperatorGuidance.ps1','Test-ProductionFindings.ps1')){
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE){throw "Release test failed: $test"}
}
New-Item -ItemType Directory $OutputDirectory -Force|Out-Null
$stage=Join-Path $OutputDirectory ('Stage-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory (Join-Path $stage 'optional') -Force|Out-Null
foreach($file in $files){Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $stage $file)}
$hashes=@(foreach($file in $files){'{0}  {1}' -f (Get-FileHash (Join-Path $stage $file)).Hash,$file.Replace('\','/')})
$hashes|Set-Content (Join-Path $stage 'SHA256SUMS.txt') -Encoding ASCII
$zip=Join-Path $OutputDirectory "sql-express-upgrade-$Version.zip"
if(Test-Path $zip){throw 'Release ZIP already exists; use a fresh output directory.'}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$verify=Join-Path $OutputDirectory ('Verify-'+[guid]::NewGuid().ToString('N'))
Expand-Archive $zip $verify
foreach($file in $files){if((Get-FileHash (Join-Path $stage $file)).Hash -ne (Get-FileHash (Join-Path $verify $file)).Hash){throw "Archive round-trip failed: $file"}}
('{0}  {1}' -f (Get-FileHash $zip).Hash,[IO.Path]::GetFileName($zip)) | Set-Content (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Write-Host "Release built and round-trip verified: $zip"
Get-FileHash $zip
