# Pruefung O06: Dienst einer installierten Rolle ist gestoppt (DNS, DHCP, Zeitdienst).
Register-NetCheck @{
    Id         = 'O06'
    Kategorie  = 'Rollen'
    Titel      = 'Gestoppte Dienste'
    Problem    = 'Diese Dienste laufen nicht:'
    Erklaerung = 'Ein gestoppter Dienst ist harmlos zu starten. Bei Stufe Automatisch startet der Doktor ihn sofort (abschaltbar in den Einstellungen).'
    Stufe      = 'Automatisch'
    Test       = {
        param($Z)
        $namen = @('W32Time')
        if ($Z.Features['DNS'] -eq 'Installed') { $namen += 'DNS' }
        if ($Z.Features['DHCP'] -eq 'Installed') { $namen += 'DHCPServer' }
        $gestoppt = @($namen | Where-Object { $Z.Dienste[$_] -and $Z.Dienste[$_].Vorhanden -and $Z.Dienste[$_].Status -ne 'Running' -and $Z.Dienste[$_].StartTyp -ne 'Disabled' })
        if ($gestoppt.Count -gt 0) { return (New-NetCheckResult FEHLER ($gestoppt -join ', ') $gestoppt) }
        New-NetCheckResult OK (($namen -join ', ') + ' laufen')
    }
    Reparatur  = { param($Z, $E) $null = $Z; foreach ($d in @($E.Daten)) { Start-Service -Name $d } }
}
