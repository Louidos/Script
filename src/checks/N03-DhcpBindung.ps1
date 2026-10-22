# Pruefung N03: Der DHCP-Server ist an die richtige Netzwerkkarte gebunden.
Register-NetCheck @{
    Id            = 'N03'
    Kategorie     = 'Netzwerk'
    Titel         = 'DHCP-Bindung'
    Problem       = 'Der DHCP-Server ist an die falsche oder keine Netzwerkkarte gebunden:'
    Erklaerung    = 'Der DHCP-Server antwortet nur auf gebundenen Karten. Gebunden sein sollten die Karten im Netz der Clients (bzw. die Karte, an die das DHCP-Relay weiterleitet).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Bindungen).Count -gt 0 }
    Test          = {
        param($Z)
        $aktiv = @($Z.Dhcp.Bindungen | Where-Object { $_.Aktiv })
        if ($aktiv.Count -eq 0) { return (New-NetCheckResult FEHLER 'keine Karte gebunden') }
        $probleme = @()
        foreach ($b in $Z.Dhcp.Bindungen) {
            $karte = @($Z.Netzwerk.Karten | Where-Object { $_.Name -eq $b.Karte }) | Select-Object -First 1
            if (-not $karte -or -not $b.IP) { continue }
            $adr = @($karte.Adressen | Where-Object { $_.IP -eq $b.IP }) | Select-Object -First 1
            if (-not $adr) { continue }
            $hatScope = @($Z.Dhcp.Scopes | Where-Object { $_.Prefix -gt 0 -and (Test-NetIPInSubnet -IPAddress $b.IP -NetworkAddress $_.ScopeId -PrefixLength $_.Prefix) }).Count -gt 0
            if ($hatScope -and -not $b.Aktiv) { $probleme += ('{0} hat einen Scope, ist aber nicht gebunden' -f $b.Karte) }
        }
        if ($probleme.Count -gt 0) { return (New-NetCheckResult WARN ($probleme -join '; ')) }
        New-NetCheckResult OK (($aktiv | ForEach-Object { $_.Karte }) -join ', ')
    }
    Reparatur     = { Set-NetDhcpBinding }
}
