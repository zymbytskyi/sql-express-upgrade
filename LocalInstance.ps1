# Local registry discovery and local shared-memory SQL connections only.
function Get-LocalExpressInstance {
    $key='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if(-not(Test-Path $key)){return}
    $registry=Get-ItemProperty $key
    foreach($entry in $registry.PSObject.Properties | Where-Object Name -NotLike 'PS*'){
        $name=$entry.Name
        $serviceName=if($name -eq 'MSSQLSERVER'){'MSSQLSERVER'}else{'MSSQL$'+$name}
        $service=Get-Service $serviceName -ErrorAction SilentlyContinue
        $setup=Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($entry.Value)\Setup"
        if($setup.Edition -notmatch 'Express'){continue}
        [pscustomobject]@{Instance=$name;InstanceId=$entry.Value;Edition=$setup.Edition;Version=$setup.Version;Service=$serviceName;Status=if($service){[string]$service.Status}else{'Missing'}}
    }
}
function Select-LocalExpressInstance {
    param([object[]]$Candidates,[string]$Requested,[switch]$Interactive)
    $eligible=@($Candidates | Where-Object {$_.Version -like '14.*' -and $_.Status -eq 'Running'})
    if($Requested){
        $match=@($eligible | Where-Object Instance -EQ $Requested)
        if($match.Count -ne 1){throw 'The requested instance is not a running local SQL 2017 Express instance.'}
        return $match[0]
    }
    if($eligible.Count -eq 0){throw 'No running local SQL 2017 Express instance found. Run this package ON the SQL server. Start the intended SQL service if stopped.'}
    if($eligible.Count -eq 1){return $eligible[0]}
    if(-not $Interactive){throw 'Multiple local SQL 2017 Express instances found. Specify -InstanceName or use the menu to select one.'}
    for($i=0;$i -lt $eligible.Count;$i++){Write-Host ('{0}: {1} ({2})' -f ($i+1),$eligible[$i].Instance,$eligible[$i].Version)}
    $choice=Read-Host 'Select the local instance number'
    $index=0
    if(-not[int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $eligible.Count){throw 'Invalid instance selection.'}
    $eligible[$index-1]
}
