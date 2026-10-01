#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination,[int]$SourceLanguage=1033,[uri]$BootstrapperUri,[string]$BootstrapperPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'MediaSupport.ps1')
Assert-SupportedLanguage $SourceLanguage
$Destination=[IO.Path]::GetFullPath($Destination)
if($Destination -eq $PSScriptRoot -or $Destination.StartsWith($PSScriptRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep media outside the package.'}
New-Item -ItemType Directory $Destination -Force|Out-Null
if($PSVersionTable.PSVersion.Major -le 5){[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}
$media=Join-Path $Destination 'SQLEXPR_x64_ENU.exe'
if(Test-Path $media){try{Assert-FullMedia $media $SourceLanguage;Write-Host "Reusing valid media: $media";return}catch{Write-Warning $_;Move-RejectedDownload $media}}
$bootstrap=if($BootstrapperPath){$BootstrapperPath}else{Join-Path $Destination 'SQL2022-SSEI-Expr.exe'}
if(Test-Path $bootstrap){
    $sig=Get-AuthenticodeSignature $bootstrap;$v=(Get-Item $bootstrap).VersionInfo
    if($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Microsoft Corporation' -and $v.ProductMajorPart -eq 16){
        Write-Host 'Reusing SQL 2022 bootstrapper with explicit /LANGUAGE=en-US.'
        $run=Join-Path $Destination ('Download-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $run|Out-Null
        $process=Start-Process $bootstrap -ArgumentList @('/ACTION=Download','/MEDIATYPE=Core','/QUIET','/LANGUAGE=en-US',('/MEDIAPATH="{0}"' -f $run)) -WindowStyle Hidden -PassThru -Wait
        $candidate=Join-Path $run 'SQLEXPR_x64_ENU.exe'
        if($process.ExitCode -eq 0 -and (Test-Path $candidate)){
            try{Assert-FullMedia $candidate $SourceLanguage;Move-Item $candidate $media;Write-Host "Media ready: $media";return}catch{Write-Warning $_}
        }
        Write-Warning "Bootstrapper did not produce validated ENU media. Retained results: $run. Using version-specific Microsoft fallback."
    }else{Write-Warning 'Invalid bootstrapper signature/version; it will not be executed.'}
}
$url='https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLEXPR_x64_ENU.exe'
for($attempt=1;$attempt -le 3;$attempt++){
    try{
        Write-Host "Downloading SQL 2022 Express x64 ENU, attempt $attempt/3: $url"
        if(Get-Command curl.exe -ErrorAction SilentlyContinue){
            & curl.exe --fail --location --retry 2 --continue-at - --output ($media+'.partial') $url
            if($LASTEXITCODE){throw "curl download failed: $LASTEXITCODE"}
        }else{Invoke-WebRequest $url -OutFile ($media+'.partial') -UseBasicParsing}
        Assert-FullMedia ($media+'.partial') $SourceLanguage
        Move-Item ($media+'.partial') $media
        Write-Host "Media ready: $media. Architecture/language layout checked again after extraction.";return
    }catch{if(Test-Path ($media+'.partial')){Move-RejectedDownload ($media+'.partial')};if($attempt -eq 3){throw};Write-Warning $_.Exception.Message}
}
