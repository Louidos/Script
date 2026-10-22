# Pruefung N04: Firewall erlaubt DNS (Port 53 UDP und TCP) eingehend.
Register-NetCheck @{
    Id            = 'N04'
    Kategorie     = 'Netzwerk'
    Titel         = 'Firewall DNS (Port 53)'
    Problem       = 'Die Firewall blockiert DNS eingehend:'
    Erklaerung    = 'Clients erreichen den DNS-Server nur, wenn UDP und TCP Port 53 eingehend erlaubt sind. Geprueft wird nach Port, nicht nach Regelnamen. Die Reparatur legt eine Regel "NetSetup DNS" an.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Features['DNS'] -eq 'Installed' }
    Test          = {
        $zu = @()
        if (-not (Test-NetFirewallPortOpen -Protokoll UDP -Port 53)) { $zu += 'UDP 53' }
        if (-not (Test-NetFirewallPortOpen -Protokoll TCP -Port 53)) { $zu += 'TCP 53' }
        if ($zu.Count -gt 0) { return (New-NetCheckResult FEHLER ($zu -join ', ') $zu) }
        New-NetCheckResult OK 'UDP und TCP 53 erlaubt'
    }
    Reparatur     = {
        param($Z, $E)
        $null = $Z
        foreach ($p in @($E.Daten)) { New-NetFirewallPortRule -Protokoll ($p.Split(' ')[0]) -Port 53 -Zweck 'DNS' }
    }
}
