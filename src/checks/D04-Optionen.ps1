# Pruefung D04: Optionen 003, 006 und 015 sind gesetzt und zeigen richtig.
Register-NetCheck @{
    Id            = 'D04'
    Kategorie     = 'DHCP'
    Titel         = 'Optionen 003/006/015'
    Problem       = 'Optionen fehlen oder zeigen falsch:'
    Erklaerung    = 'Ohne Router (003) kommen Clients nicht aus dem Netz, ohne DNS-Server (006) loesen sie keine Namen auf, ohne Domaene (015) fehlt der DNS-Suffix. In einer Domaene muss 006 auf die DCs zeigen.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $probleme = @()
        $fehler = $false
        $dcs = @()
        if ($Z.System.IstDC -or $Z.System.IstMitglied) { $dcs = @(Get-NetDcAddress -Zustand $Z) }
        foreach ($s in $Z.Dhcp.Scopes) {
            foreach ($nr in @('3', '6', '15')) {
                if (-not $s.Optionen.ContainsKey($nr) -and -not $Z.Dhcp.ServerOptionen.ContainsKey($nr)) { $probleme += ('{0}: {1} fehlt' -f $s.ScopeId, $nr); if ($nr -ne '15') { $fehler = $true } }
            }
            $router = @($s.Optionen['3'])
            if ($router.Count -gt 0 -and $router[0] -and $s.Prefix -gt 0 -and -not (Test-NetIPInSubnet -IPAddress $router[0] -NetworkAddress $s.ScopeId -PrefixLength $s.Prefix)) { $probleme += ('{0}: Router {1} liegt nicht im Netz' -f $s.ScopeId, $router[0]); $fehler = $true }
            $dns = @($s.Optionen['6'])
            if ($dns.Count -eq 0) { $dns = @($Z.Dhcp.ServerOptionen['6']) }
            if ($dcs.Count -gt 0 -and @($dns | Where-Object { $_ -and $dcs -notcontains $_ }).Count -gt 0) { $probleme += ('{0}: DNS {1} ist kein DC' -f $s.ScopeId, ((@($dns | Where-Object { $dcs -notcontains $_ })) -join ',')); $fehler = $true }
        }
        if ($probleme.Count -eq 0) { return (New-NetCheckResult OK 'vollstaendig') }
        if ($fehler) { return (New-NetCheckResult FEHLER ($probleme -join '; ')) }
        New-NetCheckResult WARN ($probleme -join '; ')
    }
    Reparatur     = { Set-NetDhcpStandardOption }
}
