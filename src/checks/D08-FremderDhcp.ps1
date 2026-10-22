# Pruefung D08: Kein fremder DHCP-Server im Netz (DHCPDISCOVER mit UdpClient).
Register-NetCheck @{
    Id            = 'D08'
    Kategorie     = 'DHCP'
    Titel         = 'Fremde DHCP-Server'
    Problem       = 'Ein fremder DHCP-Server antwortet im Netz:'
    Erklaerung    = 'Ein zweiter, unbekannter DHCP-Server (oft ein Router oder eine WLAN-Box mit eingeschaltetem DHCP) verteilt falsche Adressen, Gateways und DNS-Server. Dort DHCP ausschalten.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -or $Z.System.IstDC }
    Test          = {
        param($Z)
        $server = Find-NetForeignDhcpServer
        if ($null -eq $server) { return (New-NetCheckResult NA 'Suche nicht moeglich (UDP 68 belegt)') }
        $bekannt = Get-NetKnownDhcpServer -Zustand $Z
        $fremd = @($server | Where-Object { $bekannt -notcontains $_ })
        if ($fremd.Count -gt 0) { return (New-NetCheckResult FEHLER ($fremd -join ', ') $fremd) }
        New-NetCheckResult OK ('kein fremder Server ({0} Antwort(en))' -f @($server).Count)
    }
}
