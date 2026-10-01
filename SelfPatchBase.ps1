# Derived from zymbytskyi/sql-server-2022-express-self-patch commit c528b6d1e17bf3621549ac73e3685fb7cd1b1062.
# MIT license: see THIRD-PARTY-LICENSE.txt. Pure discovery/download/signature helpers; original executable entry point is not included.
function Get-LatestUpdate {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-WebRequest -Uri $downloadPage -UseBasicParsing
    $html = [Net.WebUtility]::HtmlDecode([string]$response.Content)
    $plain = [regex]::Replace($html, '<script[\s\S]*?</script>|<style[\s\S]*?</style>|<[^>]+>', ' ')
    $plain = [regex]::Replace($plain, '\s+', ' ')
    $fileMatch = [regex]::Match($plain, 'SQLServer2022-KB\d+-x64\.exe', 'IgnoreCase')
    $versionMatch = [regex]::Match($plain, 'Version:\s*(16\.0\.\d+\.\d+)', 'IgnoreCase')
    $cuMatch = [regex]::Match($plain, 'Cumulative Update Package\s+(\d+)\s+for SQL Server 2022\s+-\s+(KB\d+)', 'IgnoreCase')
    $urls = @($response.Links | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'href') { [string]$_.href }
    } | Where-Object { $_ -match '^https://download\.microsoft\.com/.*/SQLServer2022-KB\d+-x64\.exe(?:\?.*)?$' })
    if (-not $urls.Count) {
        $urlMatch = [regex]::Match($html, 'https://download\.microsoft\.com/[^"''\s<>]+/SQLServer2022-KB\d+-x64\.exe(?:\?[^"''\s<>]*)?', 'IgnoreCase')
        if ($urlMatch.Success) { $urls = @($urlMatch.Value) }
    }
    if (-not $fileMatch.Success -or -not $versionMatch.Success -or -not $cuMatch.Success -or -not $urls.Count) {
        throw 'Could not read the current SQL Server 2022 CU from Microsoft Download Center. Choose option 2 and use a downloaded Microsoft package.'
    }
    $uri = [uri]$urls[0]
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com') { throw "Microsoft Download Center returned an unexpected URL '$uri'." }
    [pscustomobject]@{
        Name = "CU$($cuMatch.Groups[1].Value)"
        KB = $cuMatch.Groups[2].Value.ToUpperInvariant()
        Version = $versionMatch.Groups[1].Value
        FileName = $fileMatch.Value
        Uri = $uri.AbsoluteUri
    }
}
function Get-LatestPackage {
    param($Update)
    if (-not (Test-Path -LiteralPath $packageRoot)) { New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null }
    $destination = Join-Path $packageRoot $Update.FileName
    if (Test-Path -LiteralPath $destination -PathType Leaf) { return $destination }
    $partial = $destination + '.download'
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Host "Downloading $($Update.Name) $($Update.KB) from Microsoft..."
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Update.Uri -Destination $partial -DisplayName 'SQL Server 2022 CU'
        }
        else {
            Invoke-WebRequest -Uri $Update.Uri -OutFile $partial -UseBasicParsing
        }
        Move-Item -LiteralPath $partial -Destination $destination
        return $destination
    }
    catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw
    }
}
function Test-UpdatePackage {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Update file '$Path' was not found." }
    if ([IO.Path]::GetFileName($Path) -notmatch '^SQLServer2022-KB\d+-x64\.exe$') { throw 'The file name must match SQLServer2022-KB<number>-x64.exe.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw "The update is not validly signed by Microsoft Corporation. Status=$($signature.Status)."
    }
    Write-Host "Microsoft signature: VALID" -ForegroundColor Green
    if (Get-Command Start-MpScan -ErrorAction SilentlyContinue) {
        Write-Host 'Running Microsoft Defender scan...'
        Start-MpScan -ScanType CustomScan -ScanPath $Path
    }
}
