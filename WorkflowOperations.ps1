# Overrides of v0.3 worker operations; imported after query/inventory helpers.
function Invoke-Backup {
    $p=Read-Plan;$inventory=Get-Inventory $p.Instance
    $major=([version]$inventory.Server.Build).Major
    if($major -notin @(14,16)){throw 'Only SQL 2017/2022 Express backups are supported.'}
    if($inventory.Server.Machine -ne $env:COMPUTERNAME -or $inventory.Server.EngineEdition -ne 4 -or $inventory.Server.IsSysadmin -ne 1){throw 'Backups require local Express and Windows SQL sysadmin rights.'}
    if(@($inventory.Databases|Where-Object State -ne 'ONLINE').Count){throw 'All selected backup databases must be ONLINE.'}
    Show-RebootIndicators | Out-Null
    Write-Host 'Backup prerequisites: local SQL access, ONLINE databases, writable storage and capacity. Pending restart does not block backups.'
    $databases=@($inventory.Databases | Where-Object {$BackupScope -eq 'All' -or $_.Name -in @('master','model','msdb')})
    Assert-Disk $p.BackupDirectory ([long](($databases|Measure-Object Bytes -Sum).Sum*1.2)+2GB)
    $manifestPath=Get-ActiveBackupPath $p
    $records=@();$started=[datetime]::UtcNow.ToString('o')
    foreach($db in $databases){
        $path=Join-Path $p.BackupDirectory (Get-SafeBackupName $db.Name)
        Write-Host "Backup + VERIFYONLY WITH CHECKSUM: $($db.Name) -> $path"
        Invoke-Query $p.Instance ('BACKUP DATABASE '+(Quote-Name $db.Name)+' TO DISK='+(Quote-Sql $path)+' WITH COPY_ONLY,CHECKSUM,STATS=10; RESTORE VERIFYONLY FROM DISK='+(Quote-Sql $path)+' WITH CHECKSUM;') | Out-Null
        $records+=[pscustomobject]@{Database=$db.Name;Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash;Compatibility=$db.Compatibility}
    }
    $manifest=[ordered]@{PlanId=$p.Id;Computer=$env:COMPUTERNAME;Instance=$p.Instance;Build=$inventory.Server.Build;StartedUtc=$started;CreatedUtc=[datetime]::UtcNow.ToString('o');Scope=$BackupScope;Files=$records}
    $sets=Join-Path $WorkRoot 'BackupSets';New-Item -ItemType Directory $sets -Force|Out-Null
    Save-Json (Join-Path $sets (([guid]::NewGuid().ToString('N'))+'.json')) $manifest
    Save-Json $manifestPath $manifest
    if($BackupScope -eq 'All'){Save-ValidationCache $p (Get-Content $manifestPath -Raw|ConvertFrom-Json) 'VerifyOnly'}
    Write-Host "Complete: COPY_ONLY/CHECKSUM + VERIFYONLY. No temporary restore or CHECKDB was performed. Manifest: $manifestPath"
}
function Invoke-ValidateBackups([switch]$ReuseOnly) {
    $p=Read-Plan;$manifestPath=Get-ActiveBackupPath $p
    $b=Get-Content $manifestPath -Raw|ConvertFrom-Json;$live=Get-Inventory $p.Instance
    Assert-Inventory $live (([version]$live.Server.Build).Major)
    if($b.PlanId -ne $p.Id -or $b.Build -ne $live.Server.Build){throw 'Backups do not match the current plan/build. Create or register the appropriate backup set.'}
    if((@($b.Files.Database|Sort-Object)-join '|') -ne (@($live.Databases.Name|Sort-Object)-join '|')){throw 'A complete system and user database backup set is required for readiness.'}
    if(Test-ValidationCache $p $b $ValidationMode){Write-Host "Reusing completed $ValidationMode validation bound to this plan/instance/manifest and unchanged file metadata.";return}
    if($ReuseOnly){throw 'Expensive validation is missing or invalidated. Run menu 3 (or optional full rehearsal) before Setup; the launcher did not repeat it.'}
    foreach($f in $b.Files){if((Get-FileHash -LiteralPath $f.Path).Hash -ne $f.Sha256){throw "Backup hash mismatch: $($f.Path)"};Write-Host "VERIFYONLY WITH CHECKSUM: $($f.Database)";Invoke-Query $p.Instance ('RESTORE VERIFYONLY FROM DISK='+(Quote-Sql $f.Path)+' WITH CHECKSUM;')|Out-Null}
    if($ValidationMode -eq 'FullRestore'){Invoke-Rehearse}
    Save-ValidationCache $p $b $ValidationMode
    if($ValidationMode -eq 'FullRestore'){Save-ValidationCache $p $b 'VerifyOnly'}
    Write-Host "Passed validation mode: $ValidationMode. VERIFYONLY alone does not prove restore or logical database integrity."
}
function Invoke-Rehearse {
    $p=Read-Plan;$live=Get-Inventory $p.Instance;Assert-Inventory $live (([version]$live.Server.Build).Major)
    $b=Get-Content (Get-ActiveBackupPath $p) -Raw|ConvertFrom-Json
    if($b.PlanId -ne $p.Id -or $b.Build -ne $live.Server.Build){throw 'Backup identity mismatch.'}
    foreach($f in @($b.Files|Where-Object Database -NotIn @('master','model','msdb'))){
        if((Get-FileHash -LiteralPath $f.Path).Hash -ne $f.Sha256){throw "Backup hash mismatch: $($f.Path)"}
        $literal=Quote-Sql $f.Path;$files=@(Invoke-Query $p.Instance "RESTORE FILELISTONLY FROM DISK=$literal;")
        if(@($files|Where-Object Type -NotIn @('D','L')).Count){throw 'Unsupported restore file type.'}
        $required=[long](($files|Measure-Object Size -Sum).Sum)+2GB;Assert-Disk $p.BackupDirectory $required
        $scratch='UpgradeRehearsal_'+[guid]::NewGuid().ToString('N')
        $folder=Join-Path $p.BackupDirectory $scratch;New-Item -ItemType Directory $folder|Out-Null
        $moves=@($files|ForEach-Object {'MOVE '+(Quote-Sql $_.LogicalName)+' TO '+(Quote-Sql (Join-Path $folder ($_.FileId.ToString()+'.dat')))})
        $name=Quote-Name $scratch
        Write-Host "Restoring full user database $($f.Database) as $scratch; required $([math]::Round($required/1GB,2)) GiB. Original database remains untouched."
        try{
            Invoke-Query $p.Instance ("RESTORE DATABASE $name FROM DISK=$literal WITH CHECKSUM,RECOVERY,"+($moves -join ',')+';')|Out-Null
            $errors=@(Invoke-Query $p.Instance "DBCC CHECKDB ($name) WITH NO_INFOMSGS,ALL_ERRORMSGS;")
            if($errors.Count){throw 'Restored CHECKDB reported errors.'}
            Invoke-Query $p.Instance "DROP DATABASE $name;"|Out-Null
            Remove-Item -LiteralPath $folder
        }catch{Write-Warning "Retained test database $scratch and files $folder. Inspect SQL errors and CHECKDB; only after diagnosis may the operator drop THIS named test database. No working database is removed.";throw}
    }
}
function Invoke-Verify {
    $p=Read-Plan;Assert-NoReboot
    $inventory=Get-Inventory $p.Instance;Assert-Inventory $inventory 16
    foreach($baseline in $p.Baseline.Databases){
        $actual=@($inventory.Databases|Where-Object Name -eq $baseline.Name)
        if($actual.Count -ne 1 -or $actual[0].State -ne 'ONLINE'){throw "Missing/offline database: $($baseline.Name)"}
        if($baseline.Name -notin @('master','model','msdb') -and $actual[0].Compatibility -ne (Get-ApprovedCompatibility $p $baseline.Name)){throw "Unapproved compatibility level: $($baseline.Name)"}
    }
    Save-Json (Join-Path $WorkRoot 'verification.json') ([ordered]@{PlanId=$p.Id;CheckedUtc=[datetime]::UtcNow.ToString('o');Result='QuickChecksPassed';Inventory=$inventory;ApplicationAcceptance='Required'})
    Write-Host "Quick checks passed: connectivity, Express build $($inventory.Server.Build), ONLINE databases, restart and approved compatibility. No CHECKDB performed. Application owner acceptance is required. RTM is not fully serviced."
}
function Invoke-FullCheckDB {
    $p=Read-Plan;$inventory=Get-Inventory $p.Instance
    foreach($db in $inventory.Databases){Write-Host "Full CHECKDB (I/O/CPU intensive): $($db.Name)";$errors=@(Invoke-Query $p.Instance ('DBCC CHECKDB ('+(Quote-Name $db.Name)+') WITH NO_INFOMSGS,ALL_ERRORMSGS;'));if($errors.Count){throw "CHECKDB errors: $($db.Name)"}}
}
