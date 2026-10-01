function Get-SourceLanguage([string]$Instance) {
    $map=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($map.$Instance)\Setup").Language
}
function Assert-SupportedLanguage([int]$Language) {
    if($Language -ne 1033){throw "Expected supported SQL language 1033 (English); detected $Language. Windows display language is irrelevant. Other source languages are not qualified; no files were renamed."}
}
function Get-BinaryLanguage([string]$Path) {
    # VersionInfo.Language is localized by Windows; compare numeric resource LCID instead.
    if(-not ('SqlUpgrade.VersionLanguage' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SqlUpgrade {
 public static class VersionLanguage {
  [DllImport("version.dll", CharSet=CharSet.Unicode)] static extern uint GetFileVersionInfoSize(string name, out uint handle);
  [DllImport("version.dll", CharSet=CharSet.Unicode)] static extern bool GetFileVersionInfo(string name, uint handle, uint size, byte[] data);
  [DllImport("version.dll", CharSet=CharSet.Unicode)] static extern bool VerQueryValue(byte[] data, string sub, out IntPtr value, out uint size);
  public static int Read(string path) {
   uint handle; uint size=GetFileVersionInfoSize(path,out handle);
   if(size==0) throw new InvalidOperationException("Missing version resource");
   byte[] data=new byte[size];
   if(!GetFileVersionInfo(path,0,size,data)) throw new InvalidOperationException("Cannot read version resource");
   IntPtr value; uint length;
   if(!VerQueryValue(data,"\\VarFileInfo\\Translation",out value,out length)||length<4) throw new InvalidOperationException("Missing resource language translation");
   return ((int)Marshal.ReadInt16(value)) & 65535;
  }
 }
}
'@
    }
    [SqlUpgrade.VersionLanguage]::Read([IO.Path]::GetFullPath($Path))
}
function Assert-FullMedia([string]$Path,[int]$Language=1033) {
    Assert-SupportedLanguage $Language
    $sig=Get-AuthenticodeSignature -LiteralPath $Path;$v=(Get-Item -LiteralPath $Path).VersionInfo
    $lcid=Get-BinaryLanguage $Path
    if($sig.Status -ne 'Valid' -or -not$sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)' -or $v.ProductMajorPart -ne 16 -or $v.ProductName -notmatch 'SQL Server 2022\s+Express' -or $lcid -ne $Language){
        throw "Expected Microsoft-signed SQL 2022 Express ENU (1033); detected product=$($v.ProductName), version=$($v.ProductVersion), language=$lcid ($($v.Language)), signature=$($sig.Status), path=$Path. Do not rename another language package."
    }
}
function Assert-ExtractedMedia([string]$Directory,[int]$Language=1033) {
    Assert-SupportedLanguage $Language
    $setup=Join-Path $Directory 'setup.exe';Assert-MicrosoftFile $setup
    if((Get-Item $setup).VersionInfo.ProductMajorPart -ne 16){throw 'Extracted Setup is not SQL 2022.'}
    [xml]$root=Get-Content (Join-Path $Directory 'MediaInfo.xml') -Raw
    $layout=@($root.MediaInfo.Properties.Property|Where-Object Id -eq 'MediaLayout')[0].Value
    $languages=@(Get-ChildItem $Directory -Directory -Filter '*_LP'|ForEach-Object {[xml]$xml=Get-Content (Join-Path $_.FullName 'MediaInfo.xml') -Raw;@($xml.MediaInfo.Properties.Property|Where-Object Id -eq 'Language')[0].Value})
    $msi=Join-Path $Directory 'x64\Setup\SQL_ENGINE_CORE_INST.MSI'
    if($layout -ne 'Core' -or $languages.Count -ne 1 -or [int]$languages[0] -ne $Language -or -not(Test-Path $msi)){throw "Expected Core x64 language $Language; detected layout=$layout languages=$($languages -join ','). Re-download correct media."}
    $installer=New-Object -ComObject WindowsInstaller.Installer;$db=$null;$summary=$null
    try{$db=$installer.OpenDatabase($msi,0);$summary=$db.SummaryInformation(0);$template=[string]$summary.Property(7);if($template -notmatch '^(x64|Intel64);'){throw "Expected x64 engine MSI; detected $template"}}
    finally{foreach($com in @($summary,$db,$installer)){if($com){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com)}}}
    Write-Host "Media verified: SQL 2022 Core, x64, language $Language, Microsoft-signed Setup."
}
function Move-RejectedDownload([string]$Path) {
    if(Test-Path -LiteralPath $Path){$target=$Path+'.rejected-'+[guid]::NewGuid().ToString('N');Move-Item -LiteralPath $Path -Destination $target;Write-Host "Retained rejected/interrupted file: $target"}
}
function Invoke-Prepare {
    $p=Read-Plan;Assert-Inventory (Get-Inventory $p.Instance)
    Assert-FullMedia $p.MediaSource (Get-SourceLanguage $p.Instance);Assert-Disk $WorkRoot 8GB
    $media=Join-Path $WorkRoot 'Media2022'
    if(Test-Path $media){try{Assert-ExtractedMedia $media (Get-SourceLanguage $p.Instance)|Out-Null}catch{Move-RejectedDownload $media}}
    if(-not(Test-Path $media)){
        New-Item -ItemType Directory $media|Out-Null
        $process=Start-Process $p.MediaSource -ArgumentList @('/q',('/x:"{0}"' -f $media)) -WindowStyle Hidden -PassThru -Wait
        if($process.ExitCode -ne 0){throw "Extraction failed: $($process.ExitCode). Retry Prepare; incomplete extraction is retained separately."}
    }
    Assert-ExtractedMedia $media (Get-SourceLanguage $p.Instance)
    $p.MediaFiles=@(Get-ChildItem $media -File -Recurse|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($media.Length+1);Sha256=(Get-FileHash $_.FullName).Hash}})
    $p.Prepared=$true;Save-Json $planPath $p
}
