# Pruefung O07: Dienst einer installierten Rolle ist deaktiviert.
Register-NetCheck @{
    Id         = 'O07'
    Kategorie  = 'Rollen'
    Titel      = 'Deaktivierte Dienste'
    Problem    = 'Diese Dienste sind deaktiviert:'
    Erklaerung = 'Ein deaktivierter Dienst startet nie. Die Reparatur stellt den Starttyp auf Automatisch und startet ihn.'
    Stufe      = 'Bestaetigen'
    Test       = {
        param($Z)
        $namen = @('W32Time')
        if ($Z.Features['DNS'] -eq 'Installed') { $namen += 'DNS' }
        if ($Z.Features['DHCP'] -eq 'Installed') { $namen += 'DHCPServer' }
        if ($Z.System.IstDC) { $namen += @('NTDS', 'Netlogon') }
        $aus = @($namen | Where-Object { $Z.Dienste[$_] -and $Z.Dienste[$_].Vorhanden -and $Z.Dienste[$_].StartTyp -eq 'Disabled' })
        if ($aus.Count -gt 0) { return (New-NetCheckResult FEHLER ($aus -join ', ') $aus) }
        New-NetCheckResult OK 'keiner deaktiviert'
    }
    Reparatur  = { param($Z, $E) $null = $Z; foreach ($d in @($E.Daten)) { Set-Service -Name $d -StartupType Automatic; Start-Service -Name $d } }
}
