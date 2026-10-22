# Pruefung V03: Dynamische Updates in den Zonen sind eingeschaltet.
Register-NetCheck @{
    Id            = 'V03'
    Kategorie     = 'DNS'
    Titel         = 'Dynamische Updates'
    Problem       = 'In diesen Zonen sind dynamische Updates aus:'
    Erklaerung    = 'Dann koennen sich weder Clients noch der DHCP-Server eintragen. Auf DCs ist "nur sicher" richtig, bei dateibasierten Zonen "sicher und unsicher".'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar -and @($Z.Dns.Zonen | Where-Object { $_.Typ -eq 'Primary' }).Count -gt 0 }
    Test          = {
        param($Z)
        $aus = @($Z.Dns.Zonen | Where-Object { $_.Typ -eq 'Primary' -and $_.DynUpdate -eq 'None' -and $_.Name -notlike '*.ip6.arpa' } | ForEach-Object { $_.Name })
        $unsicher = @($Z.Dns.Zonen | Where-Object { $_.AdIntegriert -and $_.DynUpdate -eq 'NonsecureAndSecure' } | ForEach-Object { $_.Name })
        if ($aus.Count -gt 0) { return (New-NetCheckResult WARN ($aus -join ', ') $aus) }
        if ($unsicher.Count -gt 0) { return (New-NetCheckResult WARN ('unsichere Updates erlaubt in: ' + ($unsicher -join ', ')) $unsicher) }
        New-NetCheckResult OK 'eingeschaltet'
    }
    Reparatur     = {
        param($Z, $E)
        foreach ($zone in @($E.Daten)) {
            $info = @($Z.Dns.Zonen | Where-Object { $_.Name -eq $zone }) | Select-Object -First 1
            $wert = 'NonsecureAndSecure'
            if ($info -and $info.AdIntegriert) { $wert = 'Secure' }
            Set-NetDnsZoneUpdate -Zone $zone -Wert $wert | Out-Null
        }
    }
}
