# Shared, side-effect-free transport selection. HTTPS is opt-in and requires a
# certificate thumbprint obtained through a trusted out-of-band channel.
function Get-UpgradeGuestTransport {
    param([string]$VMName,[string]$Address,[string]$CertificateThumbprint)
    $ErrorActionPreference='Stop'
    if(-not $Address -and -not $CertificateThumbprint){return @{VMName=$VMName}}
    if(-not $Address -or $CertificateThumbprint -notmatch '^[0-9A-Fa-f]{40}$'){throw 'HTTPS requires an address and exact certificate thumbprint.'}
    $expected=$CertificateThumbprint.ToUpperInvariant()
    $tcp=New-Object Net.Sockets.TcpClient
    $ssl=$null
    try {
        $pending=$tcp.BeginConnect($Address,5986,$null,$null)
        if(-not $pending.AsyncWaitHandle.WaitOne(10000)){throw 'Guest HTTPS TCP connection timed out.'}
        $tcp.EndConnect($pending)
        $callback=[Net.Security.RemoteCertificateValidationCallback]{param($sender,$certificate,$chain,$errors) $certificate.GetCertHashString() -eq $expected}
        $ssl=New-Object Net.Security.SslStream($tcp.GetStream(),$false,$callback)
        $ssl.ReadTimeout=10000;$ssl.WriteTimeout=10000
        $ssl.AuthenticateAsClient($Address)
        if(-not $ssl.IsAuthenticated){throw 'Guest HTTPS certificate pin validation failed.'}
    }finally{if($ssl){$ssl.Dispose()};$tcp.Dispose()}
    @{ComputerName=$Address;UseSSL=$true;Authentication='Negotiate';SessionOption=(New-PSSessionOption -SkipCACheck -SkipCNCheck -OpenTimeout 30000)}
}
