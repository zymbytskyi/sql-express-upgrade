# Integrates the pinned self-patch helpers; never executes the upstream entry point.
. (Join-Path $PSScriptRoot 'SelfPatchBase.ps1')
function Convert-ServicingRows([string]$Html) {
    $rows=@()
    foreach($match in [regex]::Matches($Html,'(?is)<tr[^>]*>.*?</tr>')){
        $text=[Net.WebUtility]::HtmlDecode([regex]::Replace($match.Value,'<[^>]+>',' '))
        $build=[regex]::Match($text,'\b16\.0\.\d+\.\d+\b').Value
        $kb=[regex]::Match($text,'(?i)\bKB\d+\b').Value.ToUpperInvariant()
        if(-not$kb){$id=[regex]::Match($match.Value,'(?i)(?:/|kb)(\d{7})(?:["/?-]|\b)');if($id.Success){$kb='KB'+$id.Groups[1].Value}}
        if($build -and $kb){$rows+=[pscustomobject]@{Build=$build;KB=$kb;Security=($text -match '(?i)GDR|security');Description=([regex]::Replace($text,'\s+',' ')).Trim();Source='https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions'}}
    }
    @($rows|Group-Object Build|ForEach-Object {$_.Group[0]}|Sort-Object @{Expression={[version]$_.Build};Descending=$true})
}
function Get-PatchArguments([string]$TargetInstance) {
    if($TargetInstance -notmatch '^[A-Za-z][A-Za-z0-9_]{0,15}$'){throw 'Invalid patch instance.'}
    @('/quiet','/action=patch',"/instancename=$TargetInstance",'/IAcceptSQLServerLicenseTerms','/norestart')
}
function Get-PatchResult([int]$Code) {
    switch($Code){0 {'Installed'} 3010 {'RestartRequired'} 1641 {'RestartInitiated'} default {throw "Patch failed: exit $Code. Review SQL Setup Bootstrap logs; do not repeat automatically."}}
}
function Invoke-IntegratedPatch {
    if(Get-Process setup -ErrorAction SilentlyContinue){throw 'Setup already running; switch to the existing session.'}
    $previousPath=Join-Path $WorkRoot 'patch-state.json'
    if(Test-Path $previousPath){$previous=Get-Content $previousPath -Raw|ConvertFrom-Json;if($previous.Status -in @('Installing','RestartRequired','RestartInitiated')){throw "Patch state is $($previous.Status). Review logs, restart if required and run menu 5; installation is not repeated automatically."}}
    Assert-NoReboot
    $p=Read-Plan;$live=Get-Inventory $p.Instance;Assert-Inventory $live 16
    $downloadPage='https://www.microsoft.com/en-us/download/details.aspx?id=105013'
    $packageRoot=Join-Path $WorkRoot 'Patches';New-Item -ItemType Directory $packageRoot -Force|Out-Null
    Write-Host 'Discovering Microsoft CU and security servicing rows; no installer has started.'
    $cu=Get-LatestUpdate
    $html=(Invoke-WebRequest 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions' -UseBasicParsing).Content
    $rows=@(Convert-ServicingRows $html)
    if(-not$rows.Count){throw 'Microsoft servicing table could not be parsed. Do not assume CU-only is fully serviced.'}
    $rows|Select-Object -First 8 Build,KB,Security,Description,Source|Format-List|Out-Host
    $recommended=@($rows|Where-Object {([version]$_.Build).Build -ge 4000}|Select-Object -First 1)
    if(-not$recommended.Count){throw 'No CU servicing-branch target could be established.'}
    $target=$recommended[0]
    Write-Host "Installed: $($live.Server.Build) | CU download: $($cu.KB) $($cu.Version) | recommended CU/security target: $($target.KB) $($target.Build)"
    Write-Host 'Microsoft Update checkbox enrolls future Windows Update scans. Include SQL Server product updates / UpdateEnabled applies to the current Setup. Upgrade uses /UPDATEENABLED=False; this is the separate servicing step.'
    if((Read-Host "Approve servicing target $($target.KB) $($target.Build) after reviewing application/vendor requirements? Type APPROVE") -cne 'APPROVE'){return}
    $record=[ordered]@{PlanId=$p.Id;Instance=$p.Instance;KB=$target.KB;TargetBuild=$target.Build;Source=$target.Source;BeforeBuild=$live.Server.Build;BootBefore=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');Status='Selected';ExitCode=$null;CheckedUtc=[datetime]::UtcNow.ToString('o')}
    if([version]$live.Server.Build -ge [version]$target.Build){$record.Status='Installed';Save-Json (Join-Path $WorkRoot 'patch-state.json') $record;Write-Host 'Selected target already met. Run menu 5 for explicit verification; no installation repeated.';return}
    Write-Host 'Last full backup history (MSDB; inspect locations and independent recovery):'
    Invoke-Query $p.Instance "SELECT d.name,MAX(b.backup_finish_date) AS LastFullBackup FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name=d.name AND b.type='D' WHERE d.database_id<>2 GROUP BY d.name;"|Format-Table|Out-Host
    $choice=Read-Host 'New pre-patch backups: 0 none, 1 system databases, 2 all except tempdb [0]'
    if($choice -and $choice -notin @('0','1','2')){throw 'Choose 0, 1 or 2.'}
    if($choice -in @('1','2')){
        Select-BackupFolder
        $scope=if($choice -eq '1'){'System'}else{'All'}
        & $worker -Mode Backup -WorkRoot $WorkRoot -InstanceName $InstanceName -BackupScope $scope
    }
    if($target.KB -eq $cu.KB -and $target.Build -eq $cu.Version){$package=Get-LatestPackage $cu}
    else{
        Write-Host "A security/CU package newer than the CU download page is required. Official build table: $($target.Source)"
        $url=Read-Host "Paste the download.microsoft.com HTTPS x64 EXE URL for $($target.KB) from its Microsoft KB page"
        $uri=[uri]$url
        if($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com' -or $uri.AbsolutePath -notmatch ('/SQLServer2022-'+[regex]::Escape($target.KB)+'-x64\.exe$')){throw 'Expected exact selected Microsoft KB x64 package URL.'}
        $package=Join-Path $packageRoot ([IO.Path]::GetFileName($uri.AbsolutePath))
        Invoke-WebRequest $uri.AbsoluteUri -OutFile ($package+'.download') -UseBasicParsing
        Move-Item ($package+'.download') $package -Force
    }
    Test-UpdatePackage $package
    $version=(Get-Item $package).VersionInfo
    $actual=('{0}.{1}.{2}.{3}' -f $version.ProductMajorPart,$version.ProductMinorPart,$version.ProductBuildPart,$version.ProductPrivatePart)
    if([version]$actual -ne [version]$target.Build){throw "Package build mismatch: expected $($target.Build), detected $actual. No installer started."}
    $published=Read-Host 'Microsoft-published SHA256 (paste if supplied by its download page; Enter if not published)'
    $hash=(Get-FileHash $package).Hash
    if($published -and ($published -notmatch '^[A-Fa-f0-9]{64}$' -or $hash -ne $published)){throw 'Published hash mismatch.'}
    Write-Host "Microsoft signature verified. SHA256: $hash | published hash supplied: $([bool]$published)"
    Write-Host "Will stop/restart SQL services for selected instance $InstanceName only. Shared SQL components may also be serviced. No automatic OS restart."
    if((Read-Host 'Confirm application writers stopped and recovery ready; type PATCH to accept license terms and install') -cne 'PATCH'){return}
    Assert-NoReboot
    if(Get-Process setup -ErrorAction SilentlyContinue){throw 'Another Setup session appeared; patch canceled.'}
    $record.Status='Installing';Save-Json (Join-Path $WorkRoot 'patch-state.json') $record
    try{$exitCode=Invoke-TrackedProcess $package (Get-PatchArguments $InstanceName) 'SQL patch installation';$record.ExitCode=$exitCode;$record.Status=Get-PatchResult $exitCode}
    catch{$record.Status='Failed';Save-Json (Join-Path $WorkRoot 'patch-state.json') $record;throw}
    Save-Json (Join-Path $WorkRoot 'patch-state.json') $record
    Write-Host "Patch result: $($record.Status), exit $exitCode. Logs: $env:ProgramFiles\Microsoft SQL Server\160\Setup Bootstrap\Log"
    if($exitCode -in @(3010,1641) -or @(Get-RebootIndicators).Count){if((Read-Host 'Restart Windows now? Type RESTART (Enter = later)') -ceq 'RESTART'){shutdown.exe /r /t 30 /c 'SQL patch operator-approved restart';if($LASTEXITCODE){throw 'Restart request failed'}}}
    Write-Host 'After any required restart, reopen the menu and choose 5. Installation will never repeat automatically.'
}
