#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [uri]$BootstrapperUri,
    [string]$BootstrapperPath
)
$ErrorActionPreference='Stop'
if(-not $BootstrapperUri -and -not $BootstrapperPath){
    $BootstrapperUri=[uri]'https://download.microsoft.com/download/29654887-7cde-4397-bba3-d7f087970845/SQL2022-SSEI-Expr.exe'
}
if(-not $BootstrapperPath -and ($BootstrapperUri.Scheme -ne 'https' -or $BootstrapperUri.Host -ne 'download.microsoft.com' -or $BootstrapperUri.AbsolutePath -notmatch '/SQL2022-SSEI-Expr\.exe$')){
    throw 'Require a version-specific SQL2022-SSEI-Expr.exe download.microsoft.com HTTPS URL.'
}
$Destination=[IO.Path]::GetFullPath($Destination)
if($Destination.StartsWith($PSScriptRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Download media outside the source package.'}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$bootstrap=Join-Path $Destination 'SQL2022-SSEI-Expr.exe'
if(Test-Path $bootstrap){throw 'Bootstrapper already exists; use another download directory to avoid silent replacement.'}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$ProgressPreference='SilentlyContinue'
if($BootstrapperPath){Copy-Item -LiteralPath $BootstrapperPath -Destination "$bootstrap.partial"}else{Invoke-WebRequest -Uri $BootstrapperUri -OutFile "$bootstrap.partial" -UseBasicParsing}
$signature=Get-AuthenticodeSignature "$bootstrap.partial"
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'){throw 'Downloaded bootstrapper has no valid Microsoft signature.'}
Move-Item "$bootstrap.partial" $bootstrap
if((Get-Item $bootstrap).VersionInfo.ProductMajorPart -ne 16){throw 'Downloaded bootstrapper is not SQL 2022.'}
$process=Start-Process $bootstrap -ArgumentList @('/ACTION=Download','/MEDIATYPE=Core','/QUIET','/ENU',('/MEDIAPATH="{0}"' -f $Destination)) -WindowStyle Hidden -PassThru -Wait
if($process.ExitCode -ne 0){throw "Media download failed: $($process.ExitCode). Use existing full media via menu Deploy if offline."}
$media=Join-Path $Destination 'SQLEXPR_x64_ENU.exe'
$signature=Get-AuthenticodeSignature $media
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation' -or (Get-Item $media).VersionInfo.ProductMajorPart -ne 16){throw 'Full media is not valid Microsoft SQL 2022 media.'}
Get-FileHash $media
Write-Host "Media ready: $media"
