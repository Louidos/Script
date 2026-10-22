# Pruefung O03: Rolle AD-Domain-Services installiert, Server ist aber kein DC.
Register-NetCheck @{
    Id            = 'O03'
    Kategorie     = 'Rollen'
    Titel         = 'AD DS ohne Heraufstufung'
    Problem       = 'Die Rolle AD-Domain-Services ist installiert, der Server ist aber kein Domaenencontroller.'
    Erklaerung    = 'Entweder wurde die Heraufstufung nie gemacht oder ist fehlgeschlagen. Die Reparatur bietet an: jetzt heraufstufen (AD-Assistent) oder die ungewollte Rolle entfernen (gefaehrlich, mit Backup und Neustart).'
    Stufe         = 'Gefaehrlich'
    Interaktiv    = $true
    Voraussetzung = { param($Z) -not $Z.System.IstDC }
    Test          = {
        param($Z)
        if ($Z.Features['AD-Domain-Services'] -eq 'Installed') { New-NetCheckResult WARN '' }
        else { New-NetCheckResult OK 'nicht installiert' }
    }
    Reparatur     = {
        $wahl = Read-NetChoice -Frage 'Was soll passieren?' -Optionen @('Jetzt heraufstufen (AD-Assistent)', 'Rolle entfernen (gefaehrlich)', 'Nichts tun') -Vorschlag 3
        if ($wahl -eq 0) { Start-NetAdSetup }
        elseif ($wahl -eq 1) {
            $r = Invoke-NetChange -Titel 'Rolle AD-Domain-Services entfernen' -Stufe Gefaehrlich -Vorher 'AD-Domain-Services installiert (kein DC)' -Nachher 'Rolle entfernt (Neustart noetig)' -BackupBereich @('Config') -Aktion {
                Uninstall-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
            }
            if ($r.Erfolg -and -not $r.Probelauf) { Request-NetRestart -Grund 'Entfernen der Rolle AD-Domain-Services' }
        }
    }
}
