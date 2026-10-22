# Pruefung V02: Reverse-Zonen fuer das Server-Netz und alle Scopes.
Register-NetCheck @{
    Id            = 'V02'
    Kategorie     = 'DNS'
    Titel         = 'Reverse-Zonen'
    Problem       = 'Reverse-Zonen fehlen:'
    Erklaerung    = 'Ohne Reverse-Zone gibt es keine PTR-Eintraege (Adresse -> Name). Viele Programme (Protokolle, Ueberwachung, Mailserver) brauchen das. Die Reparatur schlaegt die fehlenden Zonen vor.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $fehlend = @(Get-NetMissingReverseZone -Zustand $Z)
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult WARN (($fehlend | ForEach-Object { '{0} ({1})' -f $_.Zone, $_.Netz }) -join ', ')) }
        New-NetCheckResult OK 'fuer alle Netze vorhanden'
    }
    Reparatur     = { Add-NetMissingReverseZone }
}
