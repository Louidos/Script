# Pruefung V01: Die Zone der Domaene bzw. der Clients existiert.
Register-NetCheck @{
    Id            = 'V01'
    Kategorie     = 'DNS'
    Titel         = 'Forward-Zone'
    Problem       = 'Die Zone fehlt:'
    Erklaerung    = 'Ohne Zone der Domaene (bzw. der Client-Domaene aus Option 015) kann niemand eingetragen und gefunden werden. Die Reparatur legt die Zone an.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $soll = @()
        $d = Get-NetDomainName -Zustand $Z
        if ($d -and $Z.System.IstDC) { $soll += $d }
        foreach ($s in @($Z.Dhcp.Scopes)) { if ($s.Optionen.ContainsKey('15')) { $soll += @($s.Optionen['15']) } }
        $soll = @($soll | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() } | Select-Object -Unique)
        $vorhanden = @($Z.Dns.Zonen | ForEach-Object { $_.Name })
        $fehlend = @($soll | Where-Object { $vorhanden -notcontains $_ })
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult FEHLER ($fehlend -join ', ') $fehlend) }
        if (@($Z.Dns.Zonen | Where-Object { -not $_.Reverse }).Count -eq 0) { return (New-NetCheckResult WARN 'keine Forward-Zone vorhanden' @()) }
        New-NetCheckResult OK (($soll + @()) -join ', ')
    }
    Reparatur     = {
        param($Z, $E)
        $null = $Z
        if (@($E.Daten).Count -eq 0) { New-NetDnsForwardZone; return }
        foreach ($zone in @($E.Daten)) { New-NetDnsZone -Name $zone | Out-Null }
    }
}
