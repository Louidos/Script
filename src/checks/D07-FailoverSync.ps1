# Pruefung D07: DHCP-Failover ist im Zustand Normal.
Register-NetCheck @{
    Id            = 'D07'
    Kategorie     = 'DHCP'
    Titel         = 'Failover-Zustand'
    Problem       = 'Failover ist nicht synchron:'
    Erklaerung    = 'Normal ist der Zustand "Normal". CommunicationInterrupted bedeutet, dass der Partner nicht erreichbar ist (Netz, Dienst, Firewall TCP 647). Nach Aenderungen an Optionen oder Reservierungen die Replikation ausloesen.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Failover).Count -gt 0 }
    Test          = {
        param($Z)
        $nicht = @($Z.Dhcp.Failover | Where-Object { $_.Status -ne 'Normal' })
        if ($nicht.Count -gt 0) { return (New-NetCheckResult WARN (($nicht | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Status }) -join ', ')) }
        New-NetCheckResult OK 'Normal'
    }
    Reparatur     = { Sync-NetDhcpFailover }
}
