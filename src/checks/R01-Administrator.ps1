# Pruefung R01: NetSetup laeuft mit Administratorrechten.
Register-NetCheck @{
    Id         = 'R01'
    Kategorie  = 'Rechte'
    Titel      = 'Administratorrechte'
    Problem    = 'NetSetup laeuft ohne Administratorrechte.'
    Erklaerung = 'Fast alle Aenderungen brauchen Administratorrechte. PowerShell bzw. ISE mit rechter Maustaste "Als Administrator ausfuehren" starten.'
    Stufe      = 'Bestaetigen'
    Test       = {
        param($Z)
        if ($Z.System.IstAdmin) { New-NetCheckResult OK 'als Administrator gestartet' }
        else { New-NetCheckResult FEHLER '' }
    }
}
