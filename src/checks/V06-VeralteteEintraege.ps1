# Pruefung V06: Veraltete dynamische Eintraege bei ausgeschaltetem Aufraeumen.
Register-NetCheck @{
    Id            = 'V06'
    Kategorie     = 'DNS'
    Titel         = 'Veraltete Eintraege'
    Problem       = 'Veraltete dynamische Eintraege, Aufraeumen ist aus:'
    Erklaerung    = 'Alte Eintraege zeigen auf Adressen, die laengst anderen Geraeten gehoeren. Das Aufraeumen (Aging/Scavenging, Vorschlag 7 + 7 Tage) entfernt sie automatisch.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $an = $Z.Dns.Scavenging -and $Z.Dns.Scavenging.Aktiv
        $alt = @(Get-NetStaleDnsRecord -NoRefreshTage 7 -RefreshTage 7)
        if ($alt.Count -gt 0 -and -not $an) { return (New-NetCheckResult WARN ('{0} Eintraege aelter als 14 Tage' -f $alt.Count)) }
        if (-not $an) { return (New-NetCheckResult WARN 'Aufraeumen ist aus (noch keine veralteten Eintraege)') }
        New-NetCheckResult OK ('Aufraeumen an, {0} Eintraege stehen zur Loeschung an' -f $alt.Count)
    }
    Reparatur     = { Set-NetDnsScavenging | Out-Null }
}
