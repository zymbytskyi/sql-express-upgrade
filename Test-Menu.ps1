#Requires -Version 5.1
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Start-SqlExpressUpgradeMenu.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Open-UpgradeWizard','Verify-Local','Invoke-VisibleAction')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$WorkRoot=Join-Path $env:TEMP ('SqlWizardTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $WorkRoot|Out-Null
$InstanceName='APPDATA'
$script:state=[pscustomobject]@{Phase='Prepared';BootBeforeSetup=''}
$script:build='14.0.1000.169';$script:boot='before';$script:calls=@();$script:pauses=0
function Get-LiveBuild {$script:build}
function Get-Boot {$script:boot}
function Get-Process {param($Name,$ErrorAction) $null}
function Run-Worker {param($Action) $script:calls+=$Action}
function Save-State {}
function Final-Readiness {Run-Worker Preflight}
function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru) $script:launchArgs=$ArgumentList;[pscustomobject]@{Id=123}}
function Read-Host {param($Prompt) $script:pauses++;''}
try {
    # A real GUI is never opened by this test. Session-0 launch is intentionally blocked.
    if([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0){
        Open-UpgradeWizard
        if($script:launchArgs -contains '/Q' -or $script:launchArgs -contains '/QS' -or @($script:launchArgs|Where-Object {$_ -like '/IACCEPT*'}).Count){throw 'Unattended Setup switch detected.'}
        if($script:launchArgs -notcontains '/INSTANCENAME=APPDATA' -or $script:calls -notcontains 'Preflight'){throw 'Wizard target/preflight regression.'}
        if(-not(Test-Path (Join-Path $WorkRoot 'MANUAL-UPGRADE.md'))){throw 'Wizard instructions missing.'}
        'PASS: interactive wizard arguments, selected instance, preflight and instructions; launcher mocked.'
    }else{
        $blocked=$false;try{Open-UpgradeWizard}catch{if($_.Exception.Message -notlike 'Open the menu in an interactive*'){throw};$blocked=$true};if(-not$blocked){throw 'Session-0 launch not blocked'}
        'PASS: Session-0 wizard launch blocked.'
    }
    $blocked=$false;try{Verify-Local}catch{if($_.Exception.Message -notlike 'SQL is still*'){throw};$blocked=$true};if(-not$blocked){throw 'SQL 2017 accepted by Verify'}
    $script:build='16.0.1000.6';$script:state.BootBeforeSetup='before'
    $blocked=$false;try{Verify-Local}catch{if($_.Exception.Message -notlike 'Restart the server*'){throw};$blocked=$true};if(-not$blocked){throw 'Reboot gate bypassed'}
    $script:boot='after';Verify-Local
    if($script:state.Phase -ne 'DatabaseChecksPassed' -or $script:calls -notcontains 'Verify'){throw 'Manual upgrade verification failed'}
    Invoke-VisibleAction 'Success probe' {Write-Host 'Visible result'}
    Invoke-VisibleAction 'Failure probe' {throw 'Expected diagnostic'}
    if($script:pauses -ne 2){throw 'Menu result pause missing'}
    'PASS: SQL 2017 rejection, manual upgrade/reboot verification, success/error display and result pauses.'
}finally{
    $file=Join-Path $WorkRoot 'MANUAL-UPGRADE.md'
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}
    Remove-Item -LiteralPath $WorkRoot
}
