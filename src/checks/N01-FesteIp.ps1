# Pruefung N01: Der Server hat eine feste IP-Adresse.
Register-NetCheck @{
    Id         = 'N01'
    Kategorie  = 'Netzwerk'
    Titel      = 'Feste IP-Adresse'
    Problem    = 'Der Server bezieht seine IP per DHCP:'
    Erklaerung = 'DCs, DNS- und DHCP-Server brauchen eine feste IP, sonst finden Clients sie nach einer Aenderung nicht mehr (und der DHCP-Server bindet nicht). Die Reparatur setzt eine feste IP (gefaehrlich: Remotedesktop kann getrennt werden).'
    Stufe      = 'Gefaehrlich'
    Interaktiv = $true
    Test       = {
        param($Z)
        $karten = @($Z.Netzwerk.AktiveKarten)
        if ($karten.Count -eq 0) { return (New-NetCheckResult FEHLER 'keine aktive Netzwerkkarte') }
        $dhcp = @($karten | Where-Object { $_.Dhcp })
        if ($dhcp.Count -eq 0) { return (New-NetCheckResult OK 'statisch') }
        $status = 'WARN'
        if ($Z.System.IstDC -or $Z.Dns.Installiert -or $Z.Dhcp.Installiert) { $status = 'FEHLER' }
        New-NetCheckResult $status (($dhcp | ForEach-Object { $_.Name }) -join ', ') $dhcp[0]
    }
    Reparatur  = { param($Z, $E) $null = $Z; Set-NetStaticAddress -Karte $E.Daten }
}
