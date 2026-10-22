# Pruefung N05: Firewall erlaubt DHCP (Port 67 UDP) eingehend.
Register-NetCheck @{
    Id            = 'N05'
    Kategorie     = 'Netzwerk'
    Titel         = 'Firewall DHCP (Port 67)'
    Problem       = 'Die Firewall blockiert DHCP-Anfragen (UDP 67 eingehend).'
    Erklaerung    = 'Ohne offenen UDP-Port 67 erreichen DHCP-Anfragen den Server nicht. Geprueft wird nach Port, nicht nach Regelnamen. Die Reparatur legt eine Regel "NetSetup DHCP" an.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Features['DHCP'] -eq 'Installed' }
    Test          = {
        if (Test-NetFirewallPortOpen -Protokoll UDP -Port 67) { New-NetCheckResult OK 'UDP 67 erlaubt' }
        else { New-NetCheckResult FEHLER '' }
    }
    Reparatur     = { New-NetFirewallPortRule -Protokoll UDP -Port 67 -Zweck 'DHCP' }
}
