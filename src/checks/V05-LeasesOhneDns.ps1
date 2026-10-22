# Pruefung V05: Alle aktiven Leases haben A- und PTR-Eintrag.
Register-NetCheck @{
    Id            = 'V05'
    Kategorie     = 'DNS'
    Titel         = 'Leases ohne DNS-Eintrag'
    Problem       = 'Aktive Leases ohne vollstaendigen DNS-Eintrag:'
    Erklaerung    = 'Clients ohne A- oder PTR-Eintrag sind per Name nicht erreichbar. Die Reparatur zeigt jede Lease mit Ursache und bietet das Nachtragen an; dauerhaft hilft der Assistent "DHCP + DNS verbinden".'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and $Z.Dns.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $liste = @(Get-NetLeaseDnsCheck -Zustand $Z)
        $fehlend = @($liste | Where-Object { $_.Name -and -not ($_.A -and $_.PTR) })
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult WARN ('{0} von {1}' -f $fehlend.Count, $liste.Count)) }
        New-NetCheckResult OK ('{0} aktive Lease(s) vollstaendig' -f $liste.Count)
    }
    Reparatur     = { Show-NetLeaseDnsCheck | Out-Null }
}
