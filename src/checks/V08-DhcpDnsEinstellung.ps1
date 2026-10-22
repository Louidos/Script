# Pruefung V08: Der DHCP-Server traegt alle Clients ein und raeumt beim Lease-Ablauf auf.
Register-NetCheck @{
    Id            = 'V08'
    Kategorie     = 'DNS'
    Titel         = 'DHCP traegt in DNS ein'
    Problem       = 'Die DHCP-DNS-Einstellung ist unvollstaendig:'
    Erklaerung    = 'Damit jeder Client automatisch A- und PTR-Eintrag bekommt, muss DHCP "immer" eintragen, auch fuer aeltere Clients, und bei Lease-Ablauf loeschen - fuer den Server und jeden Scope.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar }
    Test          = {
        param($Z)
        $falsch = @()
        if (-not (Test-NetDhcpDnsSettingOk -Einstellung $Z.Dhcp.DnsEinstellung)) { $falsch += 'Server' }
        foreach ($s in @($Z.Dhcp.Scopes)) { if ($s.DnsEinstellung -and -not (Test-NetDhcpDnsSettingOk -Einstellung $s.DnsEinstellung)) { $falsch += ('Scope ' + $s.ScopeId) } }
        if ($falsch.Count -gt 0) { return (New-NetCheckResult WARN ($falsch -join ', ')) }
        New-NetCheckResult OK 'Always, Loeschen bei Ablauf, aeltere Clients'
    }
    Reparatur     = { Set-NetDhcpDnsSetting | Out-Null }
}
