# Pruefung R02: In einer Domaene mit einem Domaenenkonto angemeldet.
Register-NetCheck @{
    Id            = 'R02'
    Kategorie     = 'Rechte'
    Titel         = 'Domaenenkonto'
    Problem       = 'Angemeldet mit einem lokalen Konto.'
    Erklaerung    = 'Fuer AD-, DNS- und DHCP-Aenderungen in der Domaene (z. B. Autorisierung, Dienstkonto) wird ein Domaenenkonto mit passenden Rechten gebraucht. Abmelden und als DOMAENE\Administrator anmelden.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.System.IstMitglied }
    Test          = {
        $konto = Get-NetCurrentAccount
        if ($konto.IstLokal) { New-NetCheckResult WARN ('(' + $konto.Name + ')') }
        else { New-NetCheckResult OK $konto.Name }
    }
}
