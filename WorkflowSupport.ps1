# Shared v0.4 workflow helpers. No side effects on import.
function Get-RebootIndicators {
    $result=@()
    foreach($item in @(@('CBS','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'),@('Windows Update','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))){
        if(Test-Path $item[1]){$result+=[pscustomobject]@{Source=$item[0];Details=$item[1]}}
    }
    $pending=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if($pending){
        $ops=@($pending.PendingFileRenameOperations)
        for($i=0;$i -lt $ops.Count;$i+=2){
            $from=[string]$ops[$i];$to=if($i+1 -lt $ops.Count){[string]$ops[$i+1]}else{''}
            $source=if(($from+' '+$to) -match 'EdgeUpdate|Microsoft\\Edge'){'Likely Microsoft Edge Update (path inference)'}else{'Pending file operation; owner unknown'}
            $result+=[pscustomobject]@{Source=$source;Details="$from -> $to"}
        }
    }
    $result
}
function Show-RebootIndicators {
    $r=@(Get-RebootIndicators)
    if($r.Count){$r|Format-List|Out-Host}else{Write-Host 'No pending restart indicators detected.'}
    $r
}
function Assert-NoReboot {
    $r=@(Show-RebootIndicators)
    if($r.Count){throw 'A restart is pending. Backups remain available; restart and recheck before Upgrade/Patch. No registry values were cleared.'}
}
function Get-SafeBackupName([string]$Database) {
    $safe=($Database -replace '[^A-Za-z0-9._-]','_').TrimEnd('.',' ')
    if(-not $safe){$safe='Database'}
    if($safe.Length -gt 64){$safe=$safe.Substring(0,64)}
    'DB_'+$safe+'_'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfff')+'_'+[guid]::NewGuid().ToString('N')+'.bak'
}
function Get-ActiveBackupPath($Plan) {
    $build=(Get-Inventory $Plan.Instance).Server.Build
    if($build -like '14.*'){Join-Path $WorkRoot 'backups.json'}else{Join-Path $WorkRoot 'backups-2022.json'}
}
function Get-ValidationFingerprint($Plan,$Manifest,[string]$ValidationMode) {
    $files=@(foreach($f in $Manifest.Files){
        $item=Get-Item -LiteralPath $f.Path -ErrorAction Stop
        [ordered]@{Database=$f.Database;Path=$item.FullName;Length=$item.Length;Modified=$item.LastWriteTimeUtc.Ticks;Sha256=$f.Sha256}
    })
    $live=Get-Inventory $Plan.Instance
    $value=[ordered]@{Computer=$env:COMPUTERNAME;Plan=$Plan.Id;Instance=$Plan.Instance;Build=$live.Server.Build;Scope=@($live.Databases|Select-Object Name,State,Compatibility);Manifest=$Manifest;Files=$files;Mode=$ValidationMode;Folder=$Plan.BackupDirectory}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($value|ConvertTo-Json -Depth 20 -Compress))))).Replace('-','')}finally{$sha.Dispose()}
}
function Test-ValidationCache($Plan,$Manifest,[string]$ValidationMode) {
    $path=Join-Path $WorkRoot ('validation-'+$ValidationMode+'.json')
    if(-not(Test-Path $path)){Write-Host "No completed $ValidationMode validation; run Final readiness first.";return $false}
    $record=Get-Content $path -Raw|ConvertFrom-Json
    $match=$record.Result -eq 'Passed' -and $record.Fingerprint -eq (Get-ValidationFingerprint $Plan $Manifest $ValidationMode)
    if(-not$match){Write-Host 'Validation invalidated: instance/build, plan, manifest, file metadata, scope, compatibility, storage or mode changed.'}
    $match
}
function Save-ValidationCache($Plan,$Manifest,[string]$ValidationMode) {
    Save-Json (Join-Path $WorkRoot ('validation-'+$ValidationMode+'.json')) ([ordered]@{Result='Passed';Mode=$ValidationMode;CheckedUtc=[datetime]::UtcNow.ToString('o');Fingerprint=Get-ValidationFingerprint $Plan $Manifest $ValidationMode})
}
function Get-ApprovedCompatibility($Plan,[string]$Database) {
    $path=Join-Path $WorkRoot 'approved-compatibility.json'
    if(Test-Path $path){$record=Get-Content $path -Raw|ConvertFrom-Json;if($record.PlanId -ne $Plan.Id){throw 'Compatibility approvals belong to another plan.'};$entry=@($record.Changes|Where-Object Database -eq $Database|Select-Object -Last 1);if($entry.Count){return [int]$entry[0].New}}
    [int](@($Plan.Baseline.Databases|Where-Object Name -eq $Database)[0].Compatibility)
}
function Invoke-TrackedProcess([string]$Path,[string[]]$Arguments,[string]$Stage) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $process=Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    while(-not $process.WaitForExit(1000)){
        if([int]$timer.Elapsed.TotalSeconds % 10 -eq 0){
            $names=@(Get-Process -Name setup,msiexec,sqlservr -ErrorAction SilentlyContinue|ForEach-Object {"$($_.ProcessName):$($_.Id)"}) -join ', '
            $logs=Join-Path $env:ProgramFiles 'Microsoft SQL Server\160\Setup Bootstrap\Log'
            $current=Get-ChildItem $logs -Filter Detail.txt -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
            Write-Host "$Stage | elapsed $($timer.Elapsed.ToString('hh\:mm\:ss')) | processes: $names | logs: $logs"
            if($current){Write-Host "Latest log: $($current.FullName) | updated $($current.LastWriteTime)"}
        }
    }
    $process.WaitForExit();[int]$process.ExitCode
}
