# Pruefung D01: DHCP-Server ist im AD autorisiert.
Register-NetCheck @{
    Id            = 'D01'
    Kategorie     = 'DHCP'
    Titel         = 'Autorisierung im AD'
    Problem       = 'Der DHCP-Server ist nicht im AD autorisiert und vergibt deshalb keine Adressen.'
    Erklaerung    = 'In einer Domaene muss jeder Windows-DHCP-Server autorisiert sein (Add-DhcpServerInDC). Dafuer braucht es Organisations-Admins.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and $Z.Dhcp.InDomaene }
    Test          = {
        param($Z)
        if ($Z.Dhcp.Autorisiert) { New-NetCheckResult OK 'autorisiert' }
        else { New-NetCheckResult FEHLER '' }
    }
    Reparatur     = { Add-NetDhcpAuthorization }
}
