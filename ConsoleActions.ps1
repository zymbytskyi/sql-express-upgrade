# Imported into the local entry point after legacy function definitions.
# Reuse pure worker functions, without executing its standalone entry point.
$workerAst=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$null,[ref]$null)
foreach($definition in $workerAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}){. ([scriptblock]::Create($definition.Extent.Text))}
. (Join-Path $PSScriptRoot 'WorkflowSupport.ps1')
. (Join-Path $PSScriptRoot 'WorkflowOperations.ps1')
. (Join-Path $PSScriptRoot 'MediaSupport.ps1')
. (Join-Path $PSScriptRoot 'IntegratedPatch.ps1')
$ValidationMode='VerifyOnly';$BackupScope='All'
function Assert-BackupPhase {
    if(Get-Process setup -ErrorAction SilentlyContinue){throw 'Setup is running. Wait until it completes before starting backups.'}
    if(-not(Test-Path $planPath)){throw 'Run menu 1 to create the instance plan first.'}
}
function Prepare-Local {
    Assert-PreparationPhase
    if(-not(Test-Path $planPath)){
        $backup=Get-DefaultBackupDirectory
        $media=if($MediaPath){$MediaPath}else{Join-Path $WorkRoot 'Downloads\SQLEXPR_x64_ENU.exe'}
        # Configure binds source language/edition/instance before downloading anything.
        & $worker -Mode Configure -WorkRoot $WorkRoot -InstanceName $InstanceName -MediaPath $media -BackupDirectory $backup
    }
    $p=Read-Plan
    Write-OperatorPlans
    $pending=@(Show-RebootIndicators);if($pending.Count){Write-Host 'Preparation/download and backups may continue; Upgrade remains blocked until restart.'}
    if(-not$p.Prepared){
        if(-not$MediaPath){& (Join-Path $PSScriptRoot 'Save-Sql2022ExpressMedia.ps1') -Destination (Join-Path $WorkRoot 'Downloads') -SourceLanguage (Get-SourceLanguage $InstanceName)}
        Invoke-Prepare
    }else{Assert-ExtractedMedia (Join-Path $WorkRoot 'Media2022') (Get-SourceLanguage $InstanceName)|Out-Null}
    $script:state.Phase='Prepared';Save-State
    Write-RecoveryPlan
    Write-Host 'Preparation finished. Upgrade-only reboot checks were reported, not bypassed. Next: menu 2 then 3.'
}
function Final-Readiness {
    try{
        Assert-PreparationPhase
        Write-ReadinessReport 'CHECKING' 'Default validation is VERIFYONLY WITH CHECKSUM; no scratch restore or CHECKDB.'
        Run-Worker Preflight
        & $worker -Mode ValidateBackups -WorkRoot $WorkRoot -InstanceName $InstanceName -ValidationMode VerifyOnly
        Write-ReadinessReport 'TECHNICAL CHECKS PASSED' 'VERIFYONLY WITH CHECKSUM (not restore/CHECKDB). Validation persisted for launcher reuse. External recovery and application acceptance remain operator responsibilities.'
    }catch{$failure=$_;Write-ReadinessReport 'NOT READY' $failure.Exception.Message;throw $failure}
}
function Open-UpgradeWizard {
    $setup=Join-Path $WorkRoot 'Media2022\setup.exe'
    Write-Host "Prepared Setup: $setup"
    $escaped=$setup.Replace("'","''")
    Write-Host "Manual fallback: & '$escaped' /ACTION=Upgrade /INSTANCENAME=$InstanceName /UPDATEENABLED=False"
    Write-Host 'Manual route runs Microsoft Setup rules only. It does not validate this package plan, backup evidence or external recovery. Run menu 3 first. Microsoft Update controls future scans; UpdateEnabled=False excludes updates from this Setup operation.'
    if(Get-Process setup -ErrorAction SilentlyContinue){throw 'Setup already running. Switch to that window; no second session launched.'}
    if([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Open the menu in an interactive desktop/RDP PowerShell window to launch Setup.'}
    if((Get-LiveBuild) -notlike '14.*'){throw 'Upgrade requires SQL 2017. Use Verify/Patch for SQL 2022.'}
    Write-Host '[1/3] Current instance, restart, media integrity and capacity checks...'
    Run-Worker Preflight
    Assert-ExtractedMedia (Join-Path $WorkRoot 'Media2022') (Get-SourceLanguage $InstanceName)|Out-Null
    Write-Host '[2/3] Reusing completed expensive validation (no restore or CHECKDB will run)...'
    & $worker -Mode ReuseValidation -WorkRoot $WorkRoot -InstanceName $InstanceName -ValidationMode VerifyOnly
    Write-Host '[3/3] Opening interactive wizard; you control Upgrade and restart.'
    $script:state.BootBeforeSetup=Get-Boot;$script:state.Phase='WizardOpened';Save-State
    Start-Process -FilePath $setup -ArgumentList @('/ACTION=Upgrade',"/INSTANCENAME=$InstanceName",'/UPDATEENABLED=False')|Out-Null
}
function Invoke-OptionalRehearsal {
    $p=Read-Plan;$live=Get-Inventory $p.Instance
    $size=[long](($live.Databases|Where-Object Name -NotIn @('master','model','msdb')|Measure-Object Bytes -Maximum).Maximum)+2GB
    Write-Host "OPTIONAL: full user backup restores into uniquely named temporary databases, followed by CHECKDB. CPU/I/O intensive; approximately $([math]::Round($size/1GB,2)) GiB scratch headroom on $($p.BackupDirectory). Working databases are untouched. Failed scratch databases are retained for diagnosis."
    if((Read-Host 'Type REHEARSE to run (Enter = cancel)') -cne 'REHEARSE'){return}
    & $worker -Mode ValidateBackups -WorkRoot $WorkRoot -InstanceName $InstanceName -ValidationMode FullRestore
}
function Verify-Local {
    if((Get-LiveBuild) -notlike '16.*'){throw 'SQL is still on the old version. Complete the wizard before verification.'}
    if($script:state.BootBeforeSetup -and (Get-Boot) -eq $script:state.BootBeforeSetup){throw 'Restart the server after completing Setup, then Verify.'}
    Run-Worker Verify
    $path=Join-Path $WorkRoot 'patch-state.json'
    if(Test-Path $path){
        $patch=Get-Content $path -Raw|ConvertFrom-Json
        if($patch.PlanId -ne (Read-Plan).Id -or $patch.Instance -ne $InstanceName){throw 'Patch state identity mismatch.'}
        if($patch.Status -notin @('Installed','RestartRequired','RestartInitiated','Verified')){throw "Patch status $($patch.Status) requires review; no automatic retry."}
        if($patch.Status -in @('RestartRequired','RestartInitiated') -and $patch.BootBefore -eq (Get-Boot)){throw 'Patch requires a Windows restart before acceptance.'}
        if([version](Get-LiveBuild) -lt [version]$patch.TargetBuild){throw 'Installed build is below approved patch target.'}
        $patch.Status='Verified';Save-Json $path $patch
    }
    $script:state.Phase='DatabaseChecksPassed';Save-State;Write-CompletionSummary
}
function Write-RecoveryPlan {
    $p=Read-Plan;Write-OperatorPlans
    $path=Join-Path $WorkRoot 'external-recovery.json'
    $ref=if(Test-Path $path){Get-Content $path -Raw|ConvertFrom-Json}else{$null}
    $lines=@('EXTERNAL FULL-SERVER RECOVERY',"Computer: $env:COMPUTERNAME | Instance: $InstanceName | Original SQL: $($p.SourceBuild)",
      'Record the actual platform/provider (Azure Backup, VMware, Hyper-V or other), recovery point ID, operator and tested restore procedure.',
      'Preserve SQL 2017 pre-upgrade backups and copy them off-server. SQL 2022 backups cannot restore to SQL 2017. No in-place downgrade.',
      'Before recovery: keep application writers stopped, preserve logs/later writes, confirm the loss of all changes after the recovery point.',
      'Restore through the recorded provider, then verify original SQL build, database integrity, application access and domain trust. A local SQL script cannot recover its own OS.',
      'For Azure Backup: Azure portal > Recovery Services vault > Backup items > Azure Virtual Machine > select the verified VM > Restore VM. Follow the approved restore-disk/new-VM procedure and network identity plan. Never connect an unreviewed duplicate VM to the production network.',
      'Hyper-V helpers are optional under optional/. Use only on a confirmed Hyper-V host; they are not part of the local SQL workflow.')
    if($ref){$lines+="Provider: $($ref.Provider) | Reference: $($ref.Reference)";$lines+="Procedure: $($ref.Procedure)"}else{$lines+='NOT RECORDED: external recovery must be qualified before downtime.'}
    if($ref -and $ref.Provider -match '^Hyper-?V$'){
        & (Join-Path $PSScriptRoot 'New-RecoveryKit.ps1') -WorkRoot $WorkRoot
        $lines+="Hyper-V confirmed: copy $WorkRoot\Rollback off-server. On the HOST, use Capture-HyperV.ps1 with the actual VM name and new recovery directory while the VM is OFF. Restore-HyperV.ps1 requires the same recorded identity and explicit data-loss confirmation. Inside the recovered guest run Verify-Rollback.ps1, then obtain application acceptance."
    }
    $lines|Set-Content (Join-Path $WorkRoot 'ROLLBACK-PLAN.txt') -Encoding UTF8
    $lines|ForEach-Object {Write-Host $_}
}
function Set-ExternalRecovery {
    Write-Host 'Record an existing external recovery arrangement. This does not create a backup or validate provider recovery.'
    $provider=Read-Host 'Provider/platform (Azure Backup / VMware / Hyper-V / other)'
    $reference=Read-Host 'Recovery point/job ID and operator (no secrets)'
    $procedure=Read-Host 'Tested restore procedure or protected internal runbook location'
    if(-not$provider -or -not$reference -or -not$procedure){throw 'Provider, reference and procedure are required.'}
    Save-Json (Join-Path $WorkRoot 'external-recovery.json') @{PlanId=(Read-Plan).Id;Provider=$provider;Reference=$reference;Procedure=$procedure;RecordedUtc=[datetime]::UtcNow.ToString('o')}
    Write-RecoveryPlan
}
function Register-ManualBackups {
    Assert-BackupPhase;$p=Read-Plan;$live=Get-Inventory $p.Instance
    Write-Host 'Register one full CHECKSUM backup file per current database, excluding tempdb. Headers must identify this source server/database/build. VERIFYONLY and hashes run; original files are not changed.'
    $server=if($p.Instance -eq 'MSSQLSERVER'){$env:COMPUTERNAME}else{"$env:COMPUTERNAME\$($p.Instance)"}
    $records=@()
    foreach($db in $live.Databases){
        $path=(Read-Host "Full .bak path for $($db.Name) (Enter cancels)").Trim().Trim('"');if(-not$path){return}
        $path=[IO.Path]::GetFullPath($path)
        if($path -notmatch '^[A-Za-z]:\\' -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'An existing local backup file is required.'}
        $header=@(Invoke-Query $p.Instance ('RESTORE HEADERONLY FROM DISK='+(Quote-Sql $path)+';'))
        if($header.Count -ne 1){throw 'Require one backup set per file; multiple appended sets are not auto-selected.'}
        $h=$header[0]
        if($h.DatabaseName -ne $db.Name -or $h.ServerName -ne $server -or $h.BackupType -ne 1 -or -not$h.HasBackupChecksums -or $h.SoftwareVersionMajor -ne ([version]$live.Server.Build).Major){throw "Backup identity/type/checksum/version mismatch for $($db.Name); detected server=$($h.ServerName), database=$($h.DatabaseName), type=$($h.BackupType), major=$($h.SoftwareVersionMajor)."}
        Invoke-Query $p.Instance ('RESTORE VERIFYONLY FROM DISK='+(Quote-Sql $path)+' WITH CHECKSUM;')|Out-Null
        Write-Host "Verified $($h.DatabaseName), finished $($h.BackupFinishDate), server $($h.ServerName)"
        $records+=[pscustomobject]@{Database=$db.Name;Path=$path;Sha256=(Get-FileHash -LiteralPath $path).Hash;Compatibility=$db.Compatibility;BackupFinish=$h.BackupFinishDate}
    }
    if((Read-Host 'Register these verified files for this campaign? Type REGISTER') -cne 'REGISTER'){return}
    $record=@{PlanId=$p.Id;Computer=$env:COMPUTERNAME;Instance=$p.Instance;Build=$live.Server.Build;CreatedUtc=(@($records|Sort-Object BackupFinish)[0].BackupFinish.ToUniversalTime().ToString('o'));RegisteredUtc=[datetime]::UtcNow.ToString('o');Files=$records}
    $sets=Join-Path $WorkRoot 'BackupSets';New-Item -ItemType Directory $sets -Force|Out-Null
    Save-Json (Join-Path $sets ([guid]::NewGuid().ToString('N')+'.json')) $record
    Save-Json (Get-ActiveBackupPath $p) $record
}
function Set-Compatibility160 {
    Assert-NoReboot;$p=Read-Plan
    $patch=Get-Content (Join-Path $WorkRoot 'patch-state.json') -Raw|ConvertFrom-Json
    if($patch.PlanId -ne $p.Id -or $patch.Instance -ne $InstanceName -or $patch.Status -ne 'Verified'){throw 'Complete patch target approval and explicit post-patch verification first.'}
    Verify-Local
    $dbs=@((Get-Inventory $p.Instance).Databases|Where-Object Name -NotIn @('master','model','msdb'))
    for($i=0;$i -lt $dbs.Count;$i++){Write-Host "$($i+1): $($dbs[$i].Name) | compatibility $($dbs[$i].Compatibility)"}
    $selection=Read-Host 'Select user database numbers separated by comma (Enter cancels)';if(-not$selection){return}
    $indexes=@($selection.Split(',')|ForEach-Object {if($_.Trim() -notmatch '^\d+$'){throw 'Invalid selection'};$n=[int]$_.Trim()-1;if($n -lt 0 -or $n -ge $dbs.Count){throw 'Invalid database number'};$n}|Select-Object -Unique)
    if((Read-Host 'Confirm application/vendor support for level 160 on selected databases; type COMPATIBILITY160') -cne 'COMPATIBILITY160'){return}
    $path=Join-Path $WorkRoot 'approved-compatibility.json'
    $record=if(Test-Path $path){Get-Content $path -Raw|ConvertFrom-Json}else{[pscustomobject]@{PlanId=$p.Id;Changes=@()}}
    if($record.PlanId -ne $p.Id){throw 'Compatibility approval identity mismatch.'}
    foreach($index in $indexes){
        $db=$dbs[$index];if($db.Compatibility -eq 160){continue}
        $revert='ALTER DATABASE '+(Quote-Name $db.Name)+' SET COMPATIBILITY_LEVEL = '+$db.Compatibility+';'
        $intent=@{Database=$db.Name;Old=$db.Compatibility;New=160;Revert=$revert;Utc=[datetime]::UtcNow.ToString('o')}
        Save-Json (Join-Path $WorkRoot 'compatibility-change-pending.json') $intent
        Write-Host "Revert command: $revert"
        Invoke-Query $p.Instance ('ALTER DATABASE '+(Quote-Name $db.Name)+' SET COMPATIBILITY_LEVEL = 160;')|Out-Null
        $record.Changes=@($record.Changes)+[pscustomobject]$intent;Save-Json $path $record
    }
    Write-Host 'Approved baseline updated. Test the application now; reverting compatibility does not revert data/schema changes.'
    Write-CompletionSummary
}
function Register-ExistingCompatibility {
    $p=Read-Plan;$live=Get-Inventory $p.Instance;Assert-Inventory $live 16
    $changes=@($live.Databases|Where-Object {$_.Name -notin @('master','model','msdb') -and $_.Compatibility -eq 160 -and (Get-ApprovedCompatibility $p $_.Name) -ne 160})
    if(-not$changes.Count){Write-Host 'No existing level-160 changes need registration.';return}
    $changes|Select-Object Name,Compatibility|Format-Table|Out-Host
    Write-Host 'Migration only: these databases are ALREADY at 160. This records the application/vendor approval; it does not issue ALTER DATABASE or claim application acceptance.'
    if((Read-Host 'Confirm these existing changes were approved by the application/vendor; type REGISTER160') -cne 'REGISTER160'){return}
    $path=Join-Path $WorkRoot 'approved-compatibility.json'
    $record=if(Test-Path $path){Get-Content $path -Raw|ConvertFrom-Json}else{[pscustomobject]@{PlanId=$p.Id;Changes=@()}}
    foreach($db in $changes){$old=Get-ApprovedCompatibility $p $db.Name;$record.Changes=@($record.Changes)+[pscustomobject]@{Database=$db.Name;Old=$old;New=160;Utc=[datetime]::UtcNow.ToString('o');Migration=$true;Revert=('ALTER DATABASE '+(Quote-Name $db.Name)+' SET COMPATIBILITY_LEVEL = '+$old+';')}}
    Save-Json $path $record
    Write-Host 'Approval registered. Run menu 5 and obtain application owner acceptance.'
}
function Write-CompletionSummary {
    $p=Read-Plan;$live=Get-Inventory $p.Instance
    $patchFile=Join-Path $WorkRoot 'patch-state.json';$patch=if(Test-Path $patchFile){Get-Content $patchFile -Raw|ConvertFrom-Json}else{$null}
    $summary=[ordered]@{Computer=$env:COMPUTERNAME;Instance=$InstanceName;SourceBuild=$p.SourceBuild;FinalBuild=$live.Server.Build;PatchKB=if($patch){$patch.KB}else{'Not approved/verified'};Servicing=if($patch){$patch.Status}else{'Not verified; RTM is not fully serviced'};Databases=@($live.Databases|Select-Object Name,State,Compatibility);ValidationMode='Quick verification; backup validation mode recorded separately';BackupFolder=$p.BackupDirectory;PreUpgradeManifest=(Join-Path $WorkRoot 'backups.json');PostUpgradeManifest=(Join-Path $WorkRoot 'backups-2022.json');ApplicationAcceptance='REQUIRED: application owner must test and approve'}
    $summary.ValidationEvidence=@(Get-ChildItem $WorkRoot -Filter 'validation-*.json'|ForEach-Object {Get-Content $_.FullName -Raw|ConvertFrom-Json}|Select-Object Mode,Result,CheckedUtc)
    $approved=Join-Path $WorkRoot 'approved-compatibility.json'
    $summary.CompatibilityChanges=if(Test-Path $approved){(Get-Content $approved -Raw|ConvertFrom-Json).Changes}else{@()}
    $summary.BackupFiles=@(foreach($name in @('backups.json','backups-2022.json')){$file=Join-Path $WorkRoot $name;if(Test-Path $file){(Get-Content $file -Raw|ConvertFrom-Json).Files|Select-Object Database,Path}})
    Save-Json (Join-Path $WorkRoot 'completion.json') $summary
    $summary|ConvertTo-Json -Depth 8|Set-Content (Join-Path $WorkRoot 'COMPLETION.txt') -Encoding UTF8
    Get-Content (Join-Path $WorkRoot 'COMPLETION.txt')|Out-Host
}
