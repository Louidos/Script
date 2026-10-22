# Pruefung V07: Doppelte DNS-Eintraege (Name mit mehreren IPs, IP unter mehreren Namen).
Register-NetCheck @{
    Id            = 'V07'
    Kategorie     = 'DNS'
    Titel         = 'Doppelte Eintraege'
    Problem       = 'Doppelte dynamische Eintraege:'
    Erklaerung    = 'Doppelte Eintraege fuehren dazu, dass ein Name mal hier, mal dort landet. Ursache sind meist fehlendes Aufraeumen oder Geraete, die Namen bzw. Adressen wechseln. Abhilfe: Aufraeumen einschalten, Namensschutz im DHCP, falsche Eintraege im Menue DNS -> Eintraege loeschen.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $zonen = @($Z.Dns.Zonen | Where-Object { -not $_.Reverse -and $_.Typ -eq 'Primary' -and $_.Name -notlike '_msdcs.*' } | ForEach-Object { $_.Name })
        $doppelt = @(Get-NetDuplicateDnsRecord -Zonen $zonen)
        if ($doppelt.Count -gt 0) { return (New-NetCheckResult WARN (($doppelt | Select-Object -First 5 | ForEach-Object { '{0}: {1}' -f $_.Wert, $_.Liste }) -join '; ')) }
        New-NetCheckResult OK 'keine'
    }
}
