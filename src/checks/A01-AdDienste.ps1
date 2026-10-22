# Pruefung A01: NTDS und Netlogon laufen auf dem DC.
Register-NetCheck @{
    Id            = 'A01'
    Kategorie     = 'AD'
    Titel         = 'AD-Dienste (NTDS, Netlogon)'
    Problem       = 'AD-Dienste laufen nicht:'
    Erklaerung    = 'Ohne NTDS und Netlogon funktioniert die Anmeldung an der Domaene nicht. Die Reparatur startet die Dienste.'
    Stufe         = 'Automatisch'
    Voraussetzung = { param($Z) $Z.System.IstDC }
    Test          = {
        param($Z)
        $aus = @(@('NTDS', 'Netlogon') | Where-Object { -not $Z.Dienste[$_] -or $Z.Dienste[$_].Status -ne 'Running' })
        if ($aus.Count -gt 0) { return (New-NetCheckResult FEHLER ($aus -join ', ') $aus) }
        New-NetCheckResult OK 'NTDS und Netlogon laufen'
    }
    Reparatur     = { param($Z, $E) $null = $Z; foreach ($d in @($E.Daten)) { Start-Service -Name $d } }
}
