# Pruefung R03: Rechte fuer die DHCP-Autorisierung (Organisations-Admins).
Register-NetCheck @{
    Id            = 'R03'
    Kategorie     = 'Rechte'
    Titel         = 'Rechte fuer DHCP-Autorisierung'
    Problem       = 'Der DHCP-Server ist nicht autorisiert und das Konto ist nicht in der Gruppe Organisations-Admins.'
    Erklaerung    = 'Die Autorisierung im AD duerfen nur Organisations-Admins (Enterprise Admins) bzw. Konten mit delegiertem Recht. Mit einem solchen Konto anmelden oder einen Organisations-Admin bitten.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and $Z.Dhcp.InDomaene -and -not $Z.Dhcp.Autorisiert }
    Test          = {
        if (Test-NetEnterpriseAdmin) { New-NetCheckResult OK 'Konto ist Organisations-Admin' }
        else { New-NetCheckResult WARN '' }
    }
}
