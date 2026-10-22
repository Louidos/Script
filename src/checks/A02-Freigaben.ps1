# Pruefung A02: Freigaben SYSVOL und NETLOGON auf dem DC.
Register-NetCheck @{
    Id            = 'A02'
    Kategorie     = 'AD'
    Titel         = 'Freigaben SYSVOL und NETLOGON'
    Problem       = 'Freigaben fehlen:'
    Erklaerung    = 'Ohne SYSVOL/NETLOGON gibt es keine Gruppenrichtlinien und Anmeldescripts. Nach einer frischen Heraufstufung dauert es einige Minuten. Die Reparatur startet Netlogon neu; hilft das nicht, die SYSVOL-Replikation (DFSR) in der Ereignisanzeige pruefen.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.System.IstDC }
    Test          = {
        $fehlend = @(@('SYSVOL', 'NETLOGON') | Where-Object { $n = $_; -not (Get-NetSafe -Beschreibung "Freigabe $n" -Abfrage { Get-SmbShare -Name $n }) })
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult FEHLER ($fehlend -join ', ')) }
        New-NetCheckResult OK 'vorhanden'
    }
    Reparatur     = { Restart-Service -Name Netlogon -Force }
}
