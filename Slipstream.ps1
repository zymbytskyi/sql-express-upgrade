# Offline CU integration for the interactive major-version upgrade.
function Read-SlipstreamTarget {
    $path=Join-Path $WorkRoot 'slipstream.json'
    if(-not(Test-Path -LiteralPath $path)){throw 'No prepared CU target. Run menu 1 before upgrading; RTM fallback is disabled.'}
    $s=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $p=Read-Plan
    if($s.Schema -ne 1 -or $s.PlanId -ne $p.Id -or $s.Instance -ne $p.Instance -or $s.Computer -ne $p.Computer){throw 'CU target identity mismatch.'}
    if($s.KB -notmatch '^KB\d+$' -or $s.TargetBuild -notmatch '^16\.0\.\d+\.\d+$' -or ([version]$s.TargetBuild).Build -lt 4000 -or $s.Sha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Invalid CU target metadata.'}
    if($s.Status -notin @('Prepared','Verified')){throw 'Invalid CU workflow status.'}
    $s
}
function Assert-SlipstreamMedia {
    $s=Read-SlipstreamTarget
    $directory=Join-Path $WorkRoot ('Updates\'+$s.KB+'-'+$s.TargetBuild)
    $expected=Join-Path $directory ('SQLServer2022-'+$s.KB+'-x64.exe')
    if($s.PackagePath -ne $expected){throw 'CU package must remain in its dedicated prepared folder.'}
    $files=@(Get-ChildItem -LiteralPath $directory -Recurse -File -ErrorAction Stop)
    if($files.Count -ne 1 -or $files[0].FullName -ne $expected){throw 'Unexpected files in CU source. Keep only the pinned package in this folder.'}
    if((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash -ne $s.Sha256){throw 'CU package hash changed. Upgrade blocked.'}
    $sig=Get-AuthenticodeSignature -LiteralPath $expected
    if($sig.Status -ne 'Valid' -or -not$sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)'){throw 'CU Microsoft signature verification failed.'}
    $v=(Get-Item -LiteralPath $expected).VersionInfo
    $build='{0}.{1}.{2}.{3}' -f $v.ProductMajorPart,$v.ProductMinorPart,$v.ProductBuildPart,$v.ProductPrivatePart
    if($build -ne $s.TargetBuild){throw 'CU package build mismatch.'}
    Write-Host "Pinned CU: $($s.KB) | expected SQL build $($s.TargetBuild) | $expected"
    $s
}
function Prepare-Slipstream {
    $path=Join-Path $WorkRoot 'slipstream.json'
    if(Test-Path -LiteralPath $path){$null=Assert-SlipstreamMedia;Write-Host 'Reusing approved CU; no network refresh or target replacement.';return}
    $downloadPage='https://www.microsoft.com/en-us/download/details.aspx?id=105013'
    $cu=Get-LatestUpdate
    if($cu.Version -notmatch '^16\.0\.\d+\.\d+$' -or ([version]$cu.Version).Build -lt 4000 -or $cu.KB -notmatch '^KB\d+$' -or $cu.FileName -ne ('SQLServer2022-'+$cu.KB+'-x64.exe')){throw 'Invalid Microsoft CU catalog metadata.'}
    $uri=[uri]$cu.Uri
    if($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com' -or [IO.Path]::GetFileName($uri.AbsolutePath) -ne $cu.FileName){throw 'Unexpected CU download URL.'}
    Write-Host "Prepare $($cu.Name) $($cu.KB), target $($cu.Version), from Microsoft. Review its KB known issues and application/vendor support."
    if((Read-Host 'Type APPROVE to pin this CU for the upgrade') -cne 'APPROVE'){throw 'CU not approved. Preparation incomplete; no installer started.'}
    Assert-Disk $WorkRoot 8GB
    $packageRoot=Join-Path $WorkRoot ('Updates\'+$cu.KB+'-'+$cu.Version)
    $package=Get-LatestPackage $cu
    Test-UpdatePackage $package
    $p=Read-Plan
    $record=[ordered]@{Schema=1;PlanId=$p.Id;Computer=$p.Computer;Instance=$p.Instance;KB=$cu.KB;TargetBuild=$cu.Version;PackagePath=$package;Sha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash;Source=$cu.Uri;Catalog=$downloadPage;PreparedUtc=[datetime]::UtcNow.ToString('o');Status='Prepared'}
    # Validate the actual package build before persisting a usable target.
    $v=(Get-Item -LiteralPath $package).VersionInfo
    if(('{0}.{1}.{2}.{3}' -f $v.ProductMajorPart,$v.ProductMinorPart,$v.ProductBuildPart,$v.ProductPrivatePart) -ne $cu.Version){throw 'Downloaded CU build differs from the approved target.'}
    Save-Json $path $record
    $null=Assert-SlipstreamMedia
}
function Get-SlipstreamArguments {
    $s=Assert-SlipstreamMedia
    if($InstanceName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,15}$'){throw 'Invalid upgrade instance.'}
    @('/ACTION=Upgrade',"/INSTANCENAME=$InstanceName",'/UPDATEENABLED=True',('/UPDATESOURCE="{0}"' -f (Split-Path $s.PackagePath -Parent)),'/UIMODE=Normal')
}
function Assert-SlipstreamBuild {
    if(-not(Test-Path (Join-Path $WorkRoot 'slipstream.json'))){
        if($script:state.PSObject.Properties.Name -contains 'SlipstreamSha256'){throw 'Prepared CU record is missing. Verification blocked.'}
        return # Older, already-upgraded campaigns retain the separate servicing path.
    }
    $s=Read-SlipstreamTarget
    if($script:state.PSObject.Properties.Name -contains 'SlipstreamSha256'){
        if($s.Sha256 -ne $script:state.SlipstreamSha256 -or $s.TargetBuild -ne $script:state.SlipstreamBuild){throw 'CU target changed after Wizard launch.'}
    }
    $live=Get-LiveBuild
    if(($s.Status -eq 'Prepared' -and $live -ne $s.TargetBuild) -or [version]$live -lt [version]$s.TargetBuild){throw "Expected prepared CU build $($s.TargetBuild); found $live. Keep writers stopped and inspect Setup Product Updates and logs. RTM is not accepted."}
}
function Complete-SlipstreamVerification {
    if(-not(Test-Path (Join-Path $WorkRoot 'slipstream.json'))){return}
    $s=Read-SlipstreamTarget
    if($s.Status -eq 'Verified'){return}
    # Retain the existing completion/compatibility contract for subsequent servicing.
    Save-Json (Join-Path $WorkRoot 'patch-state.json') @{PlanId=$s.PlanId;Instance=$s.Instance;KB=$s.KB;TargetBuild=$s.TargetBuild;Status='Verified';BootBefore=$script:state.BootBeforeSetup;Method='Slipstream';CheckedUtc=[datetime]::UtcNow.ToString('o')}
    $s.Status='Verified';Save-Json (Join-Path $WorkRoot 'slipstream.json') $s
}
