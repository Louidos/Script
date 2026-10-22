# Pruefung D06: IP-Konflikte (feste Adressen im Bereich, abgelehnte Adressen).
Register-NetCheck @{
    Id            = 'D06'
    Kategorie     = 'DHCP'
    Titel         = 'IP-Konflikte'
    Problem       = 'Moegliche IP-Konflikte:'
    Erklaerung    = 'Liegt eine feste Adresse (Server, Router) im DHCP-Bereich, kann sie doppelt vergeben werden. Die Reparatur traegt diese Adressen als Ausschluss ein. Abgelehnte Adressen (Declined) deuten auf Geraete mit fest eingetragener IP hin - Konflikterkennung einschalten.'
    Stufe         = 'Bestaetigen'
    Backup        = @('Dhcp')
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $fest = @($Z.Netzwerk.EigeneIPs)
        foreach ($k in @($Z.Netzwerk.AktiveKarten)) { $fest += @($k.Gateway) }
        $treffer = @()
        foreach ($s in $Z.Dhcp.Scopes) {
            foreach ($ip in @($fest | Where-Object { $_ } | Select-Object -Unique)) {
                if (-not (Test-NetIPInRange -IPAddress $ip -Start $s.Start -Ende $s.Ende)) { continue }
                $aus = @($s.Ausschluesse | Where-Object { Test-NetIPInRange -IPAddress $ip -Start $_.Start -Ende $_.Ende })
                $res = @($s.Reservierungen | Where-Object { $_.IP -eq $ip })
                if ($aus.Count -eq 0 -and $res.Count -eq 0) { $treffer += @{ ScopeId = $s.ScopeId; IP = $ip } }
            }
        }
        $abgelehnt = @()
        foreach ($s in $Z.Dhcp.Scopes) {
            $id = $s.ScopeId
            $abgelehnt += @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id } | Where-Object { $_ -and [string]$_.AddressState -like '*Declined*' } | ForEach-Object { ConvertTo-NetString $_.IPAddress })
        }
        if ($treffer.Count -gt 0) { return (New-NetCheckResult FEHLER (('feste Adresse im Bereich: ' + (($treffer | ForEach-Object { $_.IP }) -join ', ')) + $(if ($abgelehnt.Count) { '; abgelehnt: ' + ($abgelehnt -join ', ') } else { '' })) $treffer) }
        if ($abgelehnt.Count -gt 0) { return (New-NetCheckResult WARN ('abgelehnte Adressen: ' + ($abgelehnt -join ', '))) }
        New-NetCheckResult OK 'keine Konflikte gefunden'
    }
    Reparatur     = { param($Z, $E) $null = $Z; foreach ($t in @($E.Daten)) { if ($t.IP) { Add-DhcpServerv4ExclusionRange -ScopeId $t.ScopeId -StartRange $t.IP -EndRange $t.IP } } }
}
