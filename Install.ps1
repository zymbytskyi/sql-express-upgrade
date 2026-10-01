#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Destination='C:\Tools\SqlExpressUpgrade-v0.4.0-rc2',[switch]$NoLaunch)
$ErrorActionPreference='Stop'
$version='v0.4.0-rc2'
if(Test-Path -LiteralPath $Destination){
    $menu=Join-Path $Destination 'Start-SqlExpressUpgradeMenu.ps1'
    if(-not(Test-Path $menu -PathType Leaf)){throw "Incomplete destination: $Destination. Choose a new directory."}
    Write-Host "Package already installed: $Destination"
    if(-not $NoLaunch){& $menu}
    return
}
if($PSVersionTable.PSVersion.Major -le 5){[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}
$zip=Join-Path $env:TEMP ('SqlExpressUpgrade-'+[guid]::NewGuid().ToString('N')+'.zip')
try{
    $release=Invoke-RestMethod "https://api.github.com/repos/zymbytskyi/sql-express-upgrade/releases/tags/$version" -Headers @{'User-Agent'='SqlExpressUpgradeInstaller'}
    $asset=@($release.assets | Where-Object name -EQ "sql-express-upgrade-$version.zip")
    if($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$'){throw 'Missing release asset or published SHA-256 digest.'}
    $uri=[uri]$asset[0].browser_download_url
    if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -ne "/zymbytskyi/sql-express-upgrade/releases/download/$version/sql-express-upgrade-$version.zip"){throw 'Unexpected release URL.'}
    Invoke-WebRequest $uri.AbsoluteUri -OutFile $zip -UseBasicParsing
    if((Get-FileHash $zip -Algorithm SHA256).Hash -ne $asset[0].digest.Substring(7)){throw 'Release hash mismatch.'}
    Expand-Archive -LiteralPath $zip -DestinationPath $Destination
    Get-ChildItem $Destination -Recurse -File|Unblock-File
}finally{if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip -Force}}
Write-Host "Installed $version to $Destination. Run this package on the SQL server itself."
if(-not$NoLaunch){& (Join-Path $Destination 'Start-SqlExpressUpgradeMenu.ps1')}
