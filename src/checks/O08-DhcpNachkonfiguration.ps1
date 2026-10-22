# Pruefung O08: DHCP-Nachkonfiguration fehlt.
Register-NetCheck @{
    Id            = 'O08'
    Kategorie     = 'Rollen'
    Titel         = 'DHCP-Nachkonfiguration'
    Problem       = 'Die DHCP-Nachkonfiguration fehlt (Server-Manager meldet "Konfiguration erforderlich").'
    Erklaerung    = 'Nach der Installation muessen die Sicherheitsgruppen angelegt und der Abschluss im Server-Manager vermerkt werden (ConfigurationState = 2).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Features['DHCP'] -eq 'Installed' }
    Test          = {
        param($Z)
        if ($Z.Dhcp.Nachkonfiguriert) { New-NetCheckResult OK 'erledigt' }
        else { New-NetCheckResult WARN '' }
    }
    Reparatur     = { Complete-NetDhcpPostInstall }
}
