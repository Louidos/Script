# Pruefung N02: Der Server fragt die richtigen DNS-Server (DC: sich selbst bzw. andere DCs).
Register-NetCheck @{
    Id            = 'N02'
    Kategorie     = 'Netzwerk'
    Titel         = 'DNS-Client des Servers'
    Problem       = 'Der Server fragt fremde DNS-Server:'
    Erklaerung    = 'In einer Domaene muessen alle Rechner (auch Server und DCs) nur die DCs als DNS fragen. Oeffentliche Server wie 8.8.8.8 kennen die Domaene nicht - Anmeldung, Gruppenrichtlinien und Replikation scheitern. Internet-Namen loest der DC ueber Weiterleitungen auf.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) ($Z.System.IstDC -or $Z.System.IstMitglied) -and @($Z.Netzwerk.AktiveKarten).Count -gt 0 }
    Test          = {
        param($Z)
        $karte = @($Z.Netzwerk.AktiveKarten)[0]
        $erlaubt = @(Get-NetDcAddress -Zustand $Z) + @($Z.Netzwerk.EigeneIPs)
        if ($Z.System.IstDC) { $erlaubt += '127.0.0.1' }
        $dns = @($karte.DnsServer)
        if ($dns.Count -eq 0) { return (New-NetCheckResult FEHLER 'kein DNS-Server eingetragen' $karte) }
        $fremd = @($dns | Where-Object { $erlaubt -notcontains $_ })
        if ($fremd.Count -gt 0) { return (New-NetCheckResult FEHLER ($fremd -join ', ') $karte) }
        if ($Z.System.IstDC -and @($dns | Where-Object { $Z.Netzwerk.EigeneIPs -contains $_ -or $_ -eq '127.0.0.1' }).Count -eq 0) {
            return (New-NetCheckResult WARN '(der DC fragt sich selbst nicht)' $karte)
        }
        New-NetCheckResult OK ($dns -join ', ')
    }
    Reparatur     = {
        param($Z, $E)
        $soll = @(Get-NetDcAddress -Zustand $Z)
        if ($Z.System.IstDC) {
            $eigene = @($Z.Netzwerk.EigeneIPs)[0]
            $andere = @($soll | Where-Object { $Z.Netzwerk.EigeneIPs -notcontains $_ })
            $soll = @($andere | Select-Object -First 1) + @($eigene, '127.0.0.1')
        }
        Set-NetDnsClient -Karte $E.Daten -Server @($soll | Where-Object { $_ }) -Grund 'Nur DCs als DNS-Server verwenden.'
    }
}
