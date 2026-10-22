# Pruefung N06: Die DNS-Weiterleitungen antworten.
Register-NetCheck @{
    Id            = 'N06'
    Kategorie     = 'Netzwerk'
    Titel         = 'DNS-Weiterleitungen'
    Problem       = 'Keine Weiterleitung antwortet:'
    Erklaerung    = 'Ohne erreichbare Weiterleitung koennen Clients keine Internet-Namen aufloesen. Ohne Internetzugang ist das normal. Die Reparatur bietet andere Weiterleitungen an (Quad9, Cloudflare, Router).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar -and @($Z.Dns.Weiterleitungen).Count -gt 0 }
    Test          = {
        param($Z)
        $ok = @($Z.Dns.Weiterleitungen | Where-Object { Test-NetDnsForwarder -Server $_ })
        if ($ok.Count -gt 0) { return (New-NetCheckResult OK (($ok -join ', ') + ' antworten')) }
        New-NetCheckResult WARN ($Z.Dns.Weiterleitungen -join ', ')
    }
    Reparatur     = { Set-NetDnsForwarder }
}
