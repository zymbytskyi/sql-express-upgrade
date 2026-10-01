#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Prepares a local standalone SQL Server 2017 Express instance for SQL Server 2022.
.DESCRIPTION
Run Configure once, then Prepare, Preflight, Backup and Rehearse. Runtime files
belong outside the downloaded source tree. Windows authentication only.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Configure','Prepare','Preflight','Backup','Rehearse','Verify','ValidateBackups','ReuseValidation','CheckDB','Library')]
    [string]$Mode = 'Menu',
    [string]$WorkRoot = 'C:\SqlExpressUpgradeData',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,15}$')][string]$InstanceName = 'SQLEXPRESS',
    [string]$MediaPath,
    [string]$BackupDirectory,
    [ValidateSet('VerifyOnly','FullRestore')][string]$ValidationMode='VerifyOnly',
    [ValidateSet('All','System')][string]$BackupScope='All'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
if ($WorkRoot -notmatch '^[A-Za-z]:\\' -or $WorkRoot.Contains('"')) { throw 'Use a local absolute runtime directory without quotes.' }
if ($WorkRoot -eq $PSScriptRoot -or $WorkRoot.StartsWith($PSScriptRoot.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep runtime data outside the source/package directory.' }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$planPath = Join-Path $WorkRoot 'plan.json'
$backupPath = Join-Path $WorkRoot 'backups.json'
$rehearsalPath = Join-Path $WorkRoot 'rehearsal.json'

function Save-Json($Path, $Value) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$Path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}
function Read-Plan {
    if (-not (Test-Path $planPath)) { throw 'Run Configure first.' }
    $p = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    if ($p.Schema -ne 1 -or $p.Computer -ne $env:COMPUTERNAME) { throw 'Plan belongs to another computer or schema.' }
    if ($p.Instance -notmatch '^[A-Za-z][A-Za-z0-9_]{0,15}$') { throw 'Invalid saved instance.' }
    $p
}
function Invoke-Query([string]$Instance, [string]$Sql) {
    $server = if ($Instance -eq 'MSSQLSERVER') { 'lpc:.' } else { "lpc:.\$Instance" }
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source']=$server; $builder['Initial Catalog']='master'; $builder['Integrated Security']=$true; $builder['Connect Timeout']=15
    $builder['Asynchronous Processing']=$true
    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    try {
        $connection.Open()
        $command=$connection.CreateCommand(); $command.CommandText=$Sql; $command.CommandTimeout=1800
        $table=New-Object System.Data.DataTable
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $pending=$command.BeginExecuteReader()
        $last=-1
        while(-not$pending.IsCompleted){
            Start-Sleep -Milliseconds 500
            $seconds=[int]$timer.Elapsed.TotalSeconds
            if($seconds -ge $last+10){Write-Host "SQL operation in progress on $Instance | elapsed $($timer.Elapsed.ToString('hh\:mm\:ss'))";$last=$seconds}
        }
        $reader=$command.EndExecuteReader($pending)
        try { $table.Load($reader) } finally { $reader.Dispose() }
        foreach ($row in $table.Rows) {
            $record=[ordered]@{}
            foreach ($column in $table.Columns) { $record[$column.ColumnName]=$row[$column] }
            [pscustomobject]$record
        }
    } finally { $connection.Dispose() }
}
function Quote-Sql([string]$Value) { "N'"+$Value.Replace("'","''")+"'" }
function Quote-Name([string]$Value) { '['+$Value.Replace(']',']]')+']' }
function Assert-MicrosoftFile([string]$Path) {
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        throw "Invalid Microsoft Authenticode signature: $Path"
    }
}
function Get-Inventory([string]$Instance) {
    $server=@(Invoke-Query $Instance @"
SELECT CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) AS [Machine],
 CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) AS [Edition],
 CONVERT(nvarchar(32),SERVERPROPERTY('ProductVersion')) AS [Build],
 CONVERT(int,SERVERPROPERTY('EngineEdition')) AS [EngineEdition],
 CONVERT(int,SERVERPROPERTY('IsClustered')) AS [Clustered],
 CONVERT(int,SERVERPROPERTY('IsHadrEnabled')) AS [Hadr],
 IS_SRVROLEMEMBER('sysadmin') AS [IsSysadmin];
"@)[0]
    $databases=@(Invoke-Query $Instance @"
SELECT d.name AS [Name],d.state_desc AS [State],d.compatibility_level AS [Compatibility],
 d.is_read_only AS [ReadOnly],d.is_encrypted AS [Encrypted],d.source_database_id AS [SnapshotSource],
 d.is_published AS [Published],d.is_subscribed AS [Subscribed],d.is_merge_published AS [MergePublished],
 CONVERT(bigint,SUM(CONVERT(bigint,f.size))*8192) AS [Bytes],
 CONVERT(bigint,SUM(CASE WHEN f.type=0 THEN CONVERT(bigint,f.size) ELSE 0 END)*8192) AS [DataBytes]
FROM sys.databases d JOIN sys.master_files f ON d.database_id=f.database_id
WHERE d.database_id<>2 GROUP BY d.name,d.state_desc,d.compatibility_level,d.is_read_only,
 d.is_encrypted,d.source_database_id,d.is_published,d.is_subscribed,d.is_merge_published;
"@)
    [pscustomobject]@{Server=$server; Databases=$databases}
}
function Assert-Inventory($Inventory,[int]$Major=14) {
    $s=$Inventory.Server
    if ($s.Machine -ne $env:COMPUTERNAME -or $s.EngineEdition -ne 4 -or $s.Build -notlike "$Major.*") { throw "Require local SQL $Major.x Express; found $($s.Machine) / $($s.Build) / $($s.Edition)." }
    if ($s.IsSysadmin -ne 1) { throw 'Windows account needs SQL sysadmin.' }
    if ($s.Clustered -ne 0 -or $s.Hadr -ne 0 -or (Get-Service ClusSvc -ErrorAction SilentlyContinue)) { throw 'HA/cluster targets are outside this package scope.' }
    foreach ($db in $Inventory.Databases) {
        if ($db.State -ne 'ONLINE' -or $db.Encrypted -or $db.Published -or $db.Subscribed -or $db.MergePublished -or $db.SnapshotSource -isnot [DBNull]) { throw "Unsupported database state/features: $($db.Name)." }
        if ($db.Name -notin @('master','model','msdb') -and $db.DataBytes -ge 10GB) { throw "Express database has no headroom below 10 GiB: $($db.Name)." }
    }
}

function Assert-Disk([string]$Directory,[long]$Required) {
    if ($Directory -notmatch '^[A-Za-z]:\\') { throw "Only local drive paths are supported: $Directory" }
    $volume=Get-Volume -FilePath $Directory -ErrorAction Stop
    if ($volume.FileSystemType -notin @('NTFS','ReFS') -or $volume.SizeRemaining -lt $Required) { throw "Insufficient/unsupported disk at $Directory; need $([math]::Ceiling($Required/1GB)) GiB free." }
}
function Invoke-Configure {
    if (Test-Path $planPath) { throw 'Plan already exists. Use a new WorkRoot for a new campaign.' }
    if (-not $MediaPath) { $script:MediaPath=Read-Host 'Full path to Microsoft SQL 2022 Express SQLEXPR_x64_ENU.exe' }
    if (-not $BackupDirectory) { $script:BackupDirectory=Read-Host 'Existing local SQL backup directory (SQL service must have write access)' }
    $inventory=Get-Inventory $InstanceName
    Assert-Inventory $inventory
    if (-not (Test-Path $BackupDirectory -PathType Container)) { throw 'Backup directory must exist.' }
    $os=Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 14393 -or [int]$os.BuildNumber -ge 26100) { throw 'This first package supports Windows Server 2016/2019/2022 and corresponding Windows 10 builds; review other operating systems separately.' }
    $registry=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'

    $instanceId=$registry.$InstanceName
    $setup=Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\Setup"
    if ($setup.Language -ne 1033) { throw 'This package uses English media and requires an English SQL source.' }
    $fulltext=@(Invoke-Query $InstanceName "SELECT CONVERT(int,FULLTEXTSERVICEPROPERTY('IsFullTextInstalled')) AS [Installed];")[0]
    if ($fulltext.Installed -ne 0) { throw 'Full-text requires Advanced Services media; this core-engine package blocks it.' }
    Save-Json $planPath ([ordered]@{Schema=1;Id=[guid]::NewGuid().ToString();Computer=$env:COMPUTERNAME;Instance=$InstanceName;InstanceId=$instanceId;SourceBuild=$inventory.Server.Build;CreatedUtc=[datetime]::UtcNow.ToString('o');MediaSource=[IO.Path]::GetFullPath($MediaPath);BackupDirectory=[IO.Path]::GetFullPath($BackupDirectory);Baseline=$inventory;Prepared=$false;MediaFiles=@()})
    Write-Host "Saved plan: $planPath"
}

function Invoke-Preflight {
    $p=Read-Plan
    if (-not [Environment]::Is64BitProcess) { throw 'Run 64-bit Windows PowerShell.' }
    $framework=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release
    if ($framework.Release -lt 461808) { throw 'SQL 2022 requires .NET Framework 4.7.2 or later.' }
    Assert-NoReboot
    $inventory=Get-Inventory $p.Instance
    Assert-Inventory $inventory
    if ($inventory.Server.Build -ne $p.SourceBuild) { throw 'SQL source build changed. Create a new campaign and requalify rollback.' }
    if ((@($inventory.Databases.Name | Sort-Object) -join '|') -ne (@($p.Baseline.Databases.Name | Sort-Object) -join '|')) { throw 'Database scope changed. Create a new campaign.' }
    if (-not $p.Prepared -or @($p.MediaFiles).Count -eq 0) { throw 'Run Prepare first.' }
    $media=Join-Path $WorkRoot 'Media2022'
    if (@(Get-ChildItem $media -File -Recurse).Count -ne @($p.MediaFiles).Count) { throw 'Media file count changed.' }
    Write-Host "Checking $(@($p.MediaFiles).Count) media file hashes. Please wait..."
    $checked=0
    foreach ($file in $p.MediaFiles) {
        $checked++
        if($checked % 30 -eq 0){Write-Host "Media verification: $checked / $(@($p.MediaFiles).Count)"}
        $path=[IO.Path]::GetFullPath((Join-Path $media $file.Path))
        if (-not $path.StartsWith($media+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $path).Hash -ne $file.Sha256) { throw "Media changed: $($file.Path)" }
    }
    Assert-MicrosoftFile (Join-Path $media 'setup.exe')
    $backupBytes=[long](($inventory.Databases | Measure-Object Bytes -Sum).Sum*1.2)+1GB
    # Sum demands per physical volume, including when backup and system share C:.
    $demands=@{}
    foreach ($requirement in @(@{Path=$env:SystemRoot;Bytes=8GB},@{Path=$WorkRoot;Bytes=2GB},@{Path=$p.BackupDirectory;Bytes=$backupBytes})) {
        $volume=Get-Volume -FilePath $requirement.Path
        $key=$volume.UniqueId
        if (-not $demands.ContainsKey($key)) { $demands[$key]=@{Path=$requirement.Path;Bytes=0L} }
        $demands[$key].Bytes+=$requirement.Bytes
    }
    foreach($demand in $demands.Values) { Assert-Disk $demand.Path $demand.Bytes }
    $files=@(Invoke-Query $p.Instance 'SELECT physical_name AS [Path] FROM sys.master_files;')
    foreach($file in $files) { Assert-Disk (Split-Path $file.Path -Parent) 1GB }
    $serviceName=if($p.Instance -eq 'MSSQLSERVER'){'MSSQLSERVER'}else{'MSSQL$'+$p.Instance}
    if((Get-Service -Name $serviceName).Status -ne 'Running'){throw 'Selected SQL service is not running.'}
    Save-Json (Join-Path $WorkRoot 'preflight.json') ([ordered]@{PlanId=$p.Id;CheckedUtc=[datetime]::UtcNow.ToString('o');Result='Passed';Inventory=$inventory})
    Write-Host 'PASS: live source, database scope, media, restart state and volume capacity.'
}



. (Join-Path $PSScriptRoot 'WorkflowSupport.ps1')
. (Join-Path $PSScriptRoot 'WorkflowOperations.ps1')
. (Join-Path $PSScriptRoot 'MediaSupport.ps1')
if ($Mode -eq 'Menu') {
    do {
        Write-Host "`nSQL Express 2017 -> 2022 preparation | $WorkRoot"
        Write-Host '1 Configure | 2 Prepare local media | 3 Preflight | 4 Backup + VERIFYONLY | 5 Restore rehearsal | 6 Quick verify after upgrade | 0 Exit'
        $choice=Read-Host 'Choose'
        try {
            switch($choice) {
                '1' {Invoke-Configure} '2' {Invoke-Prepare} '3' {Invoke-Preflight}
                '4' {Invoke-Backup} '5' {Invoke-Rehearse} '6' {Invoke-Verify}
                '0' {} default {Write-Host 'Unknown choice.'}
            }
        } catch { Write-Warning $_.Exception.Message }
    } while ($choice -ne '0')
} else {
    switch($Mode) {
        Configure {Invoke-Configure} Prepare {Invoke-Prepare} Preflight {Invoke-Preflight}
        Backup {Invoke-Backup} Rehearse {Invoke-Rehearse} Verify {Invoke-Verify}
        ValidateBackups {Invoke-ValidateBackups} ReuseValidation {Invoke-ValidateBackups -ReuseOnly}
        CheckDB {Invoke-FullCheckDB}
    }
}
