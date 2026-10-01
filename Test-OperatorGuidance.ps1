#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'OperatorGuidance.ps1')
$WorkRoot=Join-Path $env:TEMP ('SqlGuidanceTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $WorkRoot | Out-Null
$planPath=Join-Path $WorkRoot 'plan.json'
$InstanceName='APPDATA'
$backupFolder=Join-Path $WorkRoot 'existing-backup'
New-Item -ItemType Directory $backupFolder | Out-Null
$p=[ordered]@{Id='fixture';Computer=$env:COMPUTERNAME;Instance=$InstanceName;SourceBuild='14.0.1000.169';BackupDirectory=$backupFolder;Baseline=@{Databases=@(@{Name='Demo';Bytes=100})}}
$p | ConvertTo-Json -Depth 10 | Set-Content $planPath
$backupFile=Join-Path $backupFolder 'test.bak';'fixture' | Set-Content $backupFile
$b=[ordered]@{PlanId='fixture';Build=$p.SourceBuild;CreatedUtc=[datetime]::UtcNow.AddHours(-30).ToString('o');Files=@(@{Database='Demo';Path=$backupFile;Sha256=(Get-FileHash $backupFile).Hash})}
$b | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $WorkRoot 'backups.json')
function Get-LiveBuild {'14.0.1000.169'}
function Get-CimInstance {param($ClassName,$Filter)
    @([pscustomobject]@{DeviceID='C:';FreeSpace=5GB;FileSystem='NTFS'},[pscustomobject]@{DeviceID='D:';FreeSpace=100GB;FileSystem='NTFS'},[pscustomobject]@{DeviceID='E:';FreeSpace=50GB;FileSystem='ReFS'})
}
try {
    $c=@(Get-BackupCandidates 20GB)
    if($c[0].Drive -ne 'D:' -or $c[2].Enough){throw 'Capacity recommendation failed'}
    if(@(Get-BackupCandidates 200GB | Where-Object Enough).Count){throw 'Insufficient disks accepted'}
    Write-OperatorPlans
    foreach($name in @('UPGRADE-PLAN.txt','ROLLBACK-PLAN.txt')){
        $text=Get-Content (Join-Path $WorkRoot $name) -Raw
        if(-not$text.Contains('APPDATA') -or -not$text.Contains('14.0.1000.169')){throw "Target missing: $name"}
    }
    $r=Get-Content (Join-Path $WorkRoot 'ROLLBACK-PLAN.txt') -Raw
    foreach($expected in @('Hyper-V Manager','OPTIONAL','SQL 2022 backups cannot restore','loss of all changes','Azure')){if(-not$r.Contains($expected)){throw "Recovery instruction missing: $expected"}}
    Write-ReadinessReport 'CHECKING'
    $r=Get-Content (Join-Path $WorkRoot 'FINAL-READINESS.txt') -Raw
    if(-not$r.Contains('30 hours') -or -not$r.Contains($backupFile) -or -not$r.Contains('more than 24 hours')){throw 'Backup age/path warning missing'}
    # Cache invalidation and checksum control flow are tested in Test-ProductionFindings.ps1.
    Remove-Item -LiteralPath $backupFile
    Write-ReadinessReport 'NOT READY' 'Fixture missing backup'
    if((Get-Content (Join-Path $WorkRoot 'FINAL-READINESS.txt') -Raw) -notmatch 'MISSING: Demo'){throw 'Missing file not reported'}
    # Folder selection with a pre-existing folder: preserve ACL, recheck capacity.
    $originalRoot=$WorkRoot
    $WorkRoot=Join-Path $originalRoot 'runtime'
    New-Item -ItemType Directory $WorkRoot | Out-Null
    function Get-BackupSpaceEstimate {20GB}
    function Read-Host {param($Prompt) $backupFolder}
    $script:free=100GB
    function Get-Volume {param($FilePath,$ErrorAction) [pscustomobject]@{FileSystem='NTFS';DriveType='Fixed';SizeRemaining=$script:free}}
    Select-BackupFolder
    if((Get-Content $planPath -Raw | ConvertFrom-Json).BackupDirectory -ne $backupFolder){throw 'Custom folder selection failed'}
    $script:free=1GB;$blocked=$false
    try{Select-BackupFolder}catch{$blocked=$true}
    if(-not$blocked){throw 'Insufficient custom volume accepted'}
    'PASS: capacity ranking/rejection, target-specific GUI runbooks, backup age/paths, missing backup reporting and custom folder choice. SQL and volume capacity were mocked; no VM touched.'
} finally {
    # Remove only files created in this unique fixture directory, then empty directories.
    $root=if(Get-Variable originalRoot -ErrorAction SilentlyContinue){$originalRoot}else{$WorkRoot}
    Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
    Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
    Remove-Item -LiteralPath $root
}
