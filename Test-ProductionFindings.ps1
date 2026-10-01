#Requires -Version 5.1
# Isolated orchestration tests. No SQL, installers, restart, registry writes or VM actions.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Join-Path $env:TEMP ('SqlFindings-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root|Out-Null
$WorkRoot=$root;$InstanceName='APPDATA';$planPath=Join-Path $root 'plan.json'
$worker=Join-Path $PSScriptRoot 'Invoke-SqlExpressUpgrade.ps1'
. (Join-Path $PSScriptRoot 'ConsoleActions.ps1')
function Assert-Test($Condition,[string]$Message){if(-not$Condition){throw $Message};Write-Host "PASS: $Message"}
function Must-Fail([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action}catch{$failed=$true};Assert-Test $failed $Message}
function Invoke-DownloadFixture([string]$Destination){
    # Keep the real downloader body; use already-imported helpers so mocks can supply OS metadata.
    $source=Get-Content (Join-Path $PSScriptRoot 'Save-Sql2022ExpressMedia.ps1') -Raw
    $source=$source.Replace(". (Join-Path `$PSScriptRoot 'MediaSupport.ps1')",'')
    & ([scriptblock]::Create($source)) -Destination $Destination
}
$script:major=14;$script:sql=@();$script:failCheck=$false
$script:dbs=@(foreach($name in @('master','model','msdb','Demo space')){[pscustomobject]@{Name=$name;State='ONLINE';Compatibility=140;Bytes=1024;DataBytes=1024}})
function Get-Inventory {param($Instance) [pscustomobject]@{Server=[pscustomobject]@{Build="$script:major.0.1000.6";Edition='Express';Machine=$env:COMPUTERNAME;EngineEdition=4;IsSysadmin=1};Databases=$script:dbs}}
function Assert-Inventory {param($Inventory,$Major)}
function Assert-Disk {param($Directory,$Required)}
function Get-RebootIndicators {[pscustomobject]@{Source='Likely Microsoft Edge Update';Details='edge.dll -> pending'}}
function Invoke-Query {param($Instance,$Sql)
    $script:sql+=,$Sql
    if($Sql -match '^BACKUP DATABASE'){$m=[regex]::Match($Sql,"TO DISK=N'((?:''|[^'])*)'");Set-Content -LiteralPath ($m.Groups[1].Value.Replace("''","'")) -Value 'fixture backup'}
    if($Sql -like 'RESTORE FILELISTONLY*'){[pscustomobject]@{Type='D';LogicalName='DemoData';Size=128;FileId=1}}
    if($script:failCheck -and $Sql -like 'DBCC CHECKDB*'){[pscustomobject]@{Error='fixture error'}}
}
try{
    $folder=Join-Path $root 'backups';New-Item -ItemType Directory $folder|Out-Null
    $plan=[ordered]@{Schema=1;Id='fixture';Computer=$env:COMPUTERNAME;Instance=$InstanceName;SourceBuild='14.0.1000.6';BackupDirectory=$folder;Baseline=(Get-Inventory $InstanceName);Prepared=$true;MediaFiles=@()}
    Save-Json $planPath $plan
    Invoke-Backup
    Assert-Test (Test-Path (Join-Path $root 'backups.json')) 'pending reboot does not block valid backups'
    Assert-Test (-not(@($script:sql|Where-Object {$_ -match 'DBCC|RESTORE DATABASE|COMPRESSION'}).Count)) 'default backups use VERIFYONLY, no restore/CHECKDB/compression'
    $names=@(Get-ChildItem $folder -File|ForEach-Object Name)
    Assert-Test ([bool]($names -match '^DB_Demo_space_')) 'recognizable sanitized database backup names'
    $n=Get-SafeBackupName 'CON / bad:*?"<>|.'
    Assert-Test ($n -notmatch '[<>:"/\\|?*]' -and $n -ne (Get-SafeBackupName 'CON / bad:*?"<>|.')) 'filename invalid characters/reserved prefixes/collisions handled'
    $count=$script:sql.Count;Invoke-ValidateBackups -ReuseOnly
    Assert-Test ($script:sql.Count -eq $count) 'backup-time VERIFYONLY evidence avoids a duplicate readiness scan'
    Remove-Item (Join-Path $root 'validation-VerifyOnly.json')
    $count=$script:sql.Count;Invoke-ValidateBackups
    Assert-Test ($script:sql.Count -gt $count) 'first validation performs VERIFYONLY'
    $count=$script:sql.Count;Invoke-ValidateBackups -ReuseOnly
    Assert-Test ($script:sql.Count -eq $count) 'unchanged validation reused with zero expensive SQL calls'
    $file=Get-ChildItem $folder -File|Select-Object -First 1
    $original=Get-Content $file.FullName -Raw;Add-Content $file.FullName 'changed'
    Must-Fail {Invoke-ValidateBackups -ReuseOnly} 'changed file metadata invalidates launcher evidence'
    Must-Fail {Invoke-ValidateBackups} 'changed content fails checksum manifest'
    Invoke-Backup
    $ValidationMode='FullRestore';Invoke-ValidateBackups
    Assert-Test ([bool]@($script:sql|Where-Object {$_ -match '^RESTORE DATABASE \[UpgradeRehearsal_'}).Count) 'full restore only occurs in explicitly selected mode'
    Assert-Test (-not@($script:sql|Where-Object {$_ -match '^DROP DATABASE' -and $_ -notmatch '^DROP DATABASE \[UpgradeRehearsal_[a-f0-9]{32}\];$'}).Count) 'only uniquely owned rehearsal databases are removed'
    $ValidationMode='VerifyOnly';Invoke-ValidateBackups
    $p=Read-Plan;$p.BackupDirectory=$folder+'-changed';Save-Json $planPath $p
    Must-Fail {Invoke-ValidateBackups -ReuseOnly} 'relevant storage configuration invalidates evidence'
    $p.BackupDirectory=$folder;Save-Json $planPath $p
    $pre=(Get-FileHash (Join-Path $root 'backups.json')).Hash
    $script:major=16;Invoke-Backup
    Assert-Test ((Get-FileHash (Join-Path $root 'backups.json')).Hash -eq $pre) 'post-upgrade backup retains original SQL 2017 manifest'
    Assert-Test (Test-Path (Join-Path $root 'backups-2022.json')) 'separate post-upgrade manifest'
    Must-Fail {Assert-NoReboot} 'same reboot indicator blocks upgrade/patch readiness'
    function Get-RebootIndicators {}
    $script:sql=@();Invoke-Verify
    Assert-Test (-not@($script:sql|Where-Object {$_ -match 'CHECKDB'}).Count) 'quick verification does not run CHECKDB'
    $script:dbs[3].Compatibility=160
    Must-Fail {Invoke-Verify} 'unapproved compatibility change rejected'
    Save-Json (Join-Path $root 'approved-compatibility.json') @{PlanId='fixture';Changes=@(@{Database='Demo space';Old=140;New=160})}
    Invoke-Verify
    Assert-Test ((Get-ApprovedCompatibility (Read-Plan) 'Demo space') -eq 160) 'approved intentional compatibility change passes subsequent Verify'
    $args=Get-PatchArguments APPDATA
    Assert-Test (($args -join '|') -eq '/quiet|/action=patch|/instancename=APPDATA|/IAcceptSQLServerLicenseTerms') 'patch uses only supported SQL CU switches for the selected instance; no rejected NORESTART or AllInstances'
    Assert-Test ((Get-PatchResult 0) -eq 'Installed' -and (Get-PatchResult 3010) -eq 'RestartRequired' -and (Get-PatchResult 1641) -eq 'RestartInitiated') 'success/restart result handling'
    Must-Fail {Get-PatchResult 1603} 'installer failure not accepted as success'
    & {
        $script:state=[pscustomobject]@{Phase='WizardOpened';BootBeforeSetup='before'}
        $script:testBoot='before'
        function Get-Boot {$script:testBoot}
        function Get-LiveBuild {'16.0.1000.6'}
        function Run-Worker {param($Action) Invoke-Verify}
        function Save-State {}
        function Write-CompletionSummary {}
        Save-Json (Join-Path $root 'patch-state.json') @{PlanId='fixture';Instance='APPDATA';Status='RestartRequired';BootBefore='before';TargetBuild='16.0.1000.6';KB='KB0000000'}
        Must-Fail {Verify-Local} 'post-install verification requires the requested restart'
        $script:testBoot='after';Verify-Local
        Assert-Test ((Get-Content (Join-Path $root 'patch-state.json') -Raw|ConvertFrom-Json).Status -eq 'Verified') 'explicit post-restart check records Verified without reinstalling'
        $script:state.BootBeforeSetup=''
        Save-Json (Join-Path $root 'patch-state.json') @{PlanId='fixture';Instance='APPDATA';Status='RestartRequired';BootBefore='after';TargetBuild='16.0.1000.6';KB='KB0000000'}
        function Get-Process {param($Name,$ErrorAction)}
        Must-Fail {Invoke-IntegratedPatch} 'restart-required state blocks repeated patch installation'
    }
    $rows=@(Convert-ServicingRows '<table><tr><td>CU27</td><td>16.0.4295.3</td><td>KB5104824</td></tr><tr><td>CU27 + GDR security</td><td>16.0.4300.1</td><td>KB9999999</td></tr></table>')
    Assert-Test ($rows[0].Security -and $rows[0].Build -eq '16.0.4300.1') 'security servicing newer than CU ranks first'
    Must-Fail {Assert-SupportedLanguage 1031} 'unsupported SQL language fails explicitly instead of renaming media'
    & {
        function Assert-BackupPhase {}
        function Read-Host {param($Prompt) (Get-ChildItem $folder -File|Select-Object -First 1).FullName}
        function Invoke-Query {param($Instance,$Sql) if($Sql -like 'RESTORE HEADERONLY*'){[pscustomobject]@{DatabaseName='master';ServerName='FOREIGN\OTHER';BackupType=1;HasBackupChecksums=$true;SoftwareVersionMajor=16}}}
        Must-Fail {Register-ManualBackups} 'manual backup from another server/instance rejected before registration'
    }
    & {
        Save-Json (Join-Path $root 'patch-state.json') @{PlanId='fixture';Instance='APPDATA';Status='Verified';BootBefore='old';TargetBuild='16.0.1000.6';KB='KB0000000'}
        $script:dbs[3].Compatibility=140
        function Verify-Local {}
        function Write-CompletionSummary {}
        function Read-Host {param($Prompt) if($Prompt -like 'Select user*'){'1'}else{'COMPATIBILITY160'}}
        $script:sql=@();Set-Compatibility160
        Assert-Test (@($script:sql|Where-Object {$_ -match '^ALTER DATABASE \[Demo space\] SET COMPATIBILITY_LEVEL = 160;'}).Count -eq 1) 'optional compatibility action alters selected user database only'
        Assert-Test (-not@($script:sql|Where-Object {$_ -match 'ALTER DATABASE \[(master|model|msdb)\]'}).Count) 'system compatibility levels remain untouched'
        $approval=Get-Content (Join-Path $root 'approved-compatibility.json') -Raw|ConvertFrom-Json
        Assert-Test ($approval.Changes[-1].Old -eq 140 -and $approval.Changes[-1].New -eq 160 -and $approval.Changes[-1].Revert -match '140') 'old/new compatibility and revert command recorded'
    }
    & {
        function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft, O=Microsoft Corporation, C=US'}}}
        function Get-BinaryLanguage {param($Path) 1031}
        function Get-Item {param($LiteralPath) [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductMajorPart=16;ProductName='Microsoft SQL Server 2022 Express';ProductVersion='16.0.1000.6';Language='German (Germany)'}}}
        Must-Fail {Assert-FullMedia 'renamed_ENU.exe' 1033} 'actual German metadata rejected even when file is named ENU'
    }
    # Downloader retries twice then succeeds; all network/process/metadata calls mocked.
    & {
        $download=Join-Path $root 'download';$global:sqlFixtureDownloadAttempts=0
        function Get-BinaryLanguage {param($Path) 1033}
        function Get-Command {param($Name,$ErrorAction) $null}
        function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing) $global:sqlFixtureDownloadAttempts++;Set-Content $OutFile 'partial';if($global:sqlFixtureDownloadAttempts -lt 3){throw 'interrupted fixture'}}
        # The downloader imports its real validator, so use metadata fixtures instead of skipping it.
        function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft, O=Microsoft Corporation, C=US'}}}
        function Get-Item {param($LiteralPath) [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductMajorPart=16;ProductName='Microsoft SQL Server 2022 Express';ProductVersion='16.0.1000.6';Language='English (United States)'}}}
        Invoke-DownloadFixture $download
        Assert-Test ($global:sqlFixtureDownloadAttempts -eq 3 -and (Test-Path (Join-Path $download 'SQLEXPR_x64_ENU.exe'))) 'interrupted downloads retry without manual deletion'
        Invoke-DownloadFixture $download
        Assert-Test ($global:sqlFixtureDownloadAttempts -eq 3) 'valid existing media reused without downloading again'
    }
    & {
        $download=Join-Path $root 'bootstrap-reuse';New-Item -ItemType Directory $download|Out-Null
        Set-Content (Join-Path $download 'SQL2022-SSEI-Expr.exe') 'bootstrap fixture'
        $global:sqlFixtureBootstrapCalls=0
        function Get-BinaryLanguage {param($Path) 1033}
        function Get-AuthenticodeSignature {param($LiteralPath) [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft, O=Microsoft Corporation, C=US'}}}
        function Get-Item {param($LiteralPath) [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductMajorPart=16;ProductName='Microsoft SQL Server 2022 Express';ProductVersion='16.0.1000.6';Language='English (United States)'}}}
        function Start-Process {param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru,[switch]$Wait)
            $global:sqlFixtureBootstrapCalls++
            if($ArgumentList -notcontains '/LANGUAGE=en-US'){throw 'Language not explicit'}
            $out=($ArgumentList|Where-Object {$_ -like '/MEDIAPATH=*'}) -replace '^/MEDIAPATH="','' -replace '"$',''
            Set-Content (Join-Path $out 'SQLEXPR_x64_ENU.exe') 'media fixture'
            [pscustomobject]@{ExitCode=0}
        }
        Invoke-DownloadFixture $download
        Assert-Test ($global:sqlFixtureBootstrapCalls -eq 1 -and (Test-Path (Join-Path $download 'SQLEXPR_x64_ENU.exe'))) 'valid bootstrapper reused with explicit English media language'
    }
    'PASS: production findings orchestration suite; fixtures only.'
}finally{
    # Verified unique test root only; no recursive deletion command.
    if($root -notlike (Join-Path $env:TEMP 'SqlFindings-*')){throw 'Unexpected test cleanup path'}
    Get-ChildItem -LiteralPath $root -Recurse -File|ForEach-Object {Remove-Item -LiteralPath $_.FullName}
    Get-ChildItem -LiteralPath $root -Recurse -Directory|Sort-Object {$_.FullName.Length} -Descending|ForEach-Object {Remove-Item -LiteralPath $_.FullName}
    Remove-Item -LiteralPath $root
}
