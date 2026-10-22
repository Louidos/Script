# Pruefung O04: DHCP-Rolle installiert, aber ungenutzt (kein Scope) - evtl. auf dem falschen Server.
Register-NetCheck @{
    Id            = 'O04'
    Kategorie     = 'Rollen'
    Titel         = 'Ungenutzte DHCP-Rolle'
    Problem       = 'Die DHCP-Rolle ist installiert, hat aber keinen Scope.'
    Erklaerung    = 'Vielleicht wurde DHCP auf dem falschen Server installiert. Die Reparatur bietet an: Scope anlegen (DHCP-Assistent) oder die Rolle entfernen (gefaehrlich, mit Backup).'
    Stufe         = 'Gefaehrlich'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar }
    Test          = {
        param($Z)
        if (@($Z.Dhcp.Scopes).Count -eq 0) { New-NetCheckResult WARN '' }
        else { New-NetCheckResult OK ('{0} Scope(s)' -f @($Z.Dhcp.Scopes).Count) }
    }
    Reparatur     = {
        $wahl = Read-NetChoice -Frage 'Was soll passieren?' -Optionen @('DHCP hier einrichten (Assistent)', 'DHCP-Rolle entfernen (gefaehrlich)', 'Nichts tun') -Vorschlag 3
        if ($wahl -eq 0) { Start-NetDhcpSetup }
        elseif ($wahl -eq 1) {
            Invoke-NetChange -Titel 'DHCP-Rolle entfernen' -Stufe Gefaehrlich -Vorher 'DHCP installiert (ohne Scope)' -Nachher 'DHCP-Rolle entfernt' -BackupBereich @('Dhcp', 'Config') -Aktion {
                Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
            } | Out-Null
        }
    }
}
