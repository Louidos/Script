# DNS: Abhoer-IP-Adressen, Uebersicht, Einrichtungs-Assistent und Menue.

function Get-NetDnsListenAddress {
    $s = Get-NetSafe -Beschreibung 'Get-DnsServerSetting' -Abfrage { Get-DnsServerSetting -All }
    if (-not $s -or -not $s.ListeningIPAddress) { return @() }
    return @($s.ListeningIPAddress | ForEach-Object { ConvertTo-NetString -Wert $_ })
}

function Set-NetDnsListenAddress {
    <#
    .SYNOPSIS
        Setzt die Abhoer-IP-Adressen (leer = alle). Wird auch als Gegenaktion verwendet.
    #>
    param([AllowEmptyCollection()][string[]]$Adressen = @())
    $s = Get-DnsServerSetting -All
    $s.ListeningIPAddress = @($Adressen)
    Set-DnsServerSetting -InputObject $s
}

function Edit-NetDnsListenAddress {
    <#
    .SYNOPSIS
        Prueft und stellt ein, auf welchen Adressen der DNS-Server antwortet.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $z = Get-NetSetupState
    $eigene = @($z.Netzwerk.EigeneIPs)
    $alt = @(Get-NetDnsListenAddress)
    Write-NetTitle -Titel 'Abhoer-IP-Adressen des DNS-Servers'
    if ($alt.Count -eq 0) { Write-Log -Message 'Der DNS-Server antwortet auf allen Adressen des Servers (Standard).' }
    else { Write-Log -Message ('Der DNS-Server antwortet nur auf: ' + ($alt -join ', ')) }
    $fremd = @($alt | Where-Object { $eigene -notcontains $_ -and $_ -notmatch ':' })
    if ($fremd.Count -gt 0) { Write-Log -Level Warn -Message ('Diese Adressen gibt es auf dem Server nicht (mehr): ' + ($fremd -join ', ')) }
    if (@($alt | Where-Object { $_ -like '169.254.*' }).Count -gt 0) { Write-Log -Level Warn -Message 'Eine APIPA-Adresse (169.254.x.x) ist eingetragen. Das deutet auf eine falsch konfigurierte Netzwerkkarte hin.' }
    $i = Read-NetChoice -Frage 'Einstellung' -Optionen @('Alle Adressen des Servers (empfohlen)', 'Nur bestimmte Adressen waehlen', 'Nichts aendern') -Vorschlag 3
    if ($i -lt 0 -or $i -eq 2) { return }
    $neu = @()
    if ($i -eq 1) {
        $wahl = @(Select-NetItem -Elemente $eigene -Titel 'Auf welchen Adressen soll DNS antworten?' -Mehrfach)
        if ($wahl.Count -eq 0) { return }
        $neu = @($wahl | ForEach-Object { [string]$_ })
    }
    if (($alt -join ',') -eq ($neu -join ',')) { Write-Log -Level OK -Message 'Bereits so eingestellt.'; return }
    Invoke-NetChange -Titel 'Abhoer-IP-Adressen des DNS-Servers einstellen' -Stufe Bestaetigen -Vorher $(if ($alt.Count) { $alt -join ', ' } else { 'alle' }) -Nachher $(if ($neu.Count) { $neu -join ', ' } else { 'alle' }) -BackupBereich @('Dns') -Aktion {
        Set-NetDnsListenAddress -Adressen $neu
    } -Rueckgaengig @{ Befehl = 'Set-NetDnsListenAddress'; Parameter = @{ Adressen = $alt } } | Out-Null
}

function Show-NetDnsOverview {
    if (-not (Test-NetDnsReady)) { return }
    Show-NetDnsZone
    Write-Host ''
    $fw = @(Get-NetDnsForwarderList)
    Write-Host ('  Weiterleitungen : {0}' -f $(if ($fw.Count) { $fw -join ', ' } else { 'keine (Stammhinweise)' }))
    $sc = Get-NetSafe -Beschreibung 'Scavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc) { Write-Host ('  Aufraeumen      : {0}' -f $(if ($sc.ScavengingState) { 'an' } else { 'aus' })) }
    $abh = @(Get-NetDnsListenAddress)
    Write-Host ('  Abhoer-Adressen : {0}' -f $(if ($abh.Count) { $abh -join ', ' } else { 'alle' }))
    $fehlend = @(Get-NetMissingReverseZone)
    if ($fehlend.Count -gt 0) { Write-Log -Level Warn -Message ('Fehlende Reverse-Zonen: ' + (($fehlend | ForEach-Object { $_.Zone }) -join ', ')) }
}

function Start-NetDnsSetup {
    <#
    .SYNOPSIS
        Assistent: DNS einrichten (Rolle, Forward-Zone, Reverse-Zonen, Weiterleitungen, Aufraeumen).
        Ueberspringt alles, was schon passt.
    #>
    Write-NetTitle -Titel 'DNS einrichten'
    if (-not (Test-NetDnsReady)) { return }
    $z = Get-NetSetupState
    $forward = @($z.Dns.Zonen | Where-Object { -not $_.Reverse -and $_.Typ -eq 'Primary' -and $_.Name -notlike '_msdcs.*' })
    if ($forward.Count -eq 0) {
        Write-Log -Level Warn -Message 'Es gibt noch keine Forward-Zone.'
        if (Read-NetYesNo -Frage 'Jetzt eine Forward-Zone anlegen?' -Vorschlag $true) { New-NetDnsForwardZone }
    }
    else { Write-Log -Level OK -Message ('Forward-Zone(n): ' + (($forward | ForEach-Object { $_.Name }) -join ', ')) }
    foreach ($f in $forward) {
        if ($f.DynUpdate -eq 'None') {
            Write-Log -Level Warn -Message ('In der Zone {0} sind dynamische Updates aus. Clients und DHCP koennen sich dann nicht eintragen.' -f $f.Name)
            if (Read-NetYesNo -Frage 'Dynamische Updates einschalten?' -Vorschlag $true) {
                $wert = 'NonsecureAndSecure'
                if ($f.AdIntegriert) { $wert = 'Secure' }
                Set-NetDnsZoneUpdate -Zone $f.Name -Wert $wert | Out-Null
            }
        }
    }
    $fehlend = @(Get-NetMissingReverseZone -Zustand (Get-NetSetupState))
    if ($fehlend.Count -gt 0) { Add-NetMissingReverseZone }
    else { Write-Log -Level OK -Message 'Reverse-Zonen fuer alle Netze vorhanden.' }
    if (@(Get-NetDnsForwarderList).Count -eq 0) {
        Write-Log -Level Warn -Message 'Es ist keine Weiterleitung eingestellt.'
        if (Read-NetYesNo -Frage 'Jetzt Weiterleitungen einstellen?' -Vorschlag $true) { Set-NetDnsForwarder | Out-Null }
    }
    else { Write-Log -Level OK -Message ('Weiterleitungen: ' + (@(Get-NetDnsForwarderList) -join ', ')) }
    $sc = Get-NetSafe -Beschreibung 'Scavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc -and -not $sc.ScavengingState) {
        Write-Log -Level Warn -Message 'Das Aufraeumen alter Eintraege (Scavenging) ist aus.'
        if (Read-NetYesNo -Frage 'Mit Vorschlag 7 + 7 Tage einschalten?' -Vorschlag $true) { Set-NetDnsScavenging -Aktiv $true | Out-Null }
    }
    Write-Log -Level OK -Message 'DNS-Einrichtung abgeschlossen.'
}

function Show-NetDnsZoneMenu {
    $eintraege = @(
        @{ Text = 'Zonen anzeigen'; Aktion = 'Show-NetDnsZone'; Hilfe = 'Alle Zonen mit Typ, Speicherung (AD oder Datei) und dynamischen Updates.' },
        @{ Text = 'Forward-Zone anlegen'; Aktion = 'New-NetDnsForwardZone'; Hilfe = "Zone fuer Namen -> Adressen. Auf einem DC AD-integriert (Replikation Domain oder Forest), sonst als Datei.`nExistiert die Zone schon, passiert nichts." },
        @{ Text = 'Reverse-Zone anlegen'; Aktion = { New-NetDnsReverseZone }; Hilfe = 'Zone fuer Adressen -> Namen (PTR) eines Netzes, z. B. 1.168.192.in-addr.arpa fuer 192.168.1.0/24.' },
        @{ Text = 'Fehlende Reverse-Zonen vorschlagen'; Aktion = 'Add-NetMissingReverseZone'; Hilfe = 'Prueft das Netz des Servers und alle DHCP-Scopes und schlaegt fehlende Reverse-Zonen vor.' },
        @{ Text = 'Dynamische Updates einstellen'; Aktion = { Set-NetDnsZoneUpdate | Out-Null }; Hilfe = 'Nur sicher (empfohlen, nur AD-Zonen), sicher und unsicher, oder aus.' },
        @{ Text = 'Zone loeschen (gefaehrlich)'; Aktion = 'Remove-NetDnsZone'; Hilfe = 'Loescht eine Zone mit allen Eintraegen. Vorher wird automatisch gesichert; der Servername muss eingetippt werden.' }
    )
    Show-NetMenu -Titel 'DNS - Zonen' -Eintraege $eintraege
}

function Show-NetDnsRecordMenu {
    $eintraege = @(
        @{ Text = 'Eintraege einer Zone anzeigen'; Aktion = 'Show-NetDnsRecord'; Hilfe = 'Listet alle Eintraege einer Zone, mit statisch/dynamisch und Zeitstempel.' },
        @{ Text = 'Eintrag suchen'; Aktion = { Find-NetDnsRecord | Out-Null }; Hilfe = 'Sucht einen Namen oder eine Adresse in allen Zonen.' },
        @{ Text = 'Eintrag anlegen (A, AAAA, CNAME, MX, SRV, TXT, PTR)'; Aktion = { Add-NetDnsRecord | Out-Null }; Hilfe = "Legt einen Eintrag an. Vorher wird geprueft, ob es ihn schon gibt (dann passiert nichts) oder ob er mit einem anderen kollidiert.`nA-Eintraege koennen gleich den passenden PTR bekommen." },
        @{ Text = 'Eintrag aendern'; Aktion = { Edit-NetDnsRecord | Out-Null }; Hilfe = 'Aendert die Daten eines Eintrags (z. B. neue IP). Vorher/Nachher wird angezeigt, rueckgaengig moeglich.' },
        @{ Text = 'Eintrag loeschen'; Aktion = { Remove-NetDnsRecord | Out-Null }; Hilfe = 'Loescht genau einen Eintrag. Die Gegenaktion (wieder anlegen) wird gemerkt.' }
    )
    Show-NetMenu -Titel 'DNS - Eintraege' -Eintraege $eintraege
}

function Show-NetDnsMenu {
    $eintraege = @(
        @{ Text = 'Uebersicht'; Aktion = 'Show-NetDnsOverview'; Hilfe = 'Zonen, Weiterleitungen, Aufraeumen, Abhoer-Adressen und fehlende Reverse-Zonen auf einen Blick.' },
        @{ Text = 'DNS einrichten (Assistent)'; Aktion = 'Start-NetDnsSetup'; Hilfe = 'Prueft Rolle, Forward-Zone, dynamische Updates, Reverse-Zonen, Weiterleitungen und Aufraeumen und bietet an, was fehlt. Erledigtes wird uebersprungen.' },
        @{ Text = 'Zonen'; Aktion = 'Show-NetDnsZoneMenu'; OhnePause = $true; Hilfe = 'Zonen anzeigen, anlegen, dynamische Updates, fehlende Reverse-Zonen, loeschen.' },
        @{ Text = 'Eintraege'; Aktion = 'Show-NetDnsRecordMenu'; OhnePause = $true; Hilfe = 'Eintraege anzeigen, suchen, anlegen, aendern, loeschen.' },
        @{ Text = 'Weiterleitungen'; Aktion = 'Show-NetDnsForwarderMenu'; OhnePause = $true; Hilfe = 'Weiterleitungen (Quad9, Cloudflare, Router) und bedingte Weiterleitungen. Erklaert auch den Unterschied zu den Stammhinweisen.' },
        @{ Text = 'Aufraeumen alter Eintraege (Aging/Scavenging)'; Aktion = 'Show-NetDnsAgingMenu'; OhnePause = $true; Hilfe = 'Assistent mit Vorschlag 7 + 7 Tage, Erklaerung zur Lease-Dauer und Modus "nur melden".' },
        @{ Text = 'Abhoer-IP-Adressen'; Aktion = 'Edit-NetDnsListenAddress'; Hilfe = 'Auf welchen Adressen der DNS-Server antwortet. Empfohlen: alle festen Adressen des Servers.' },
        @{ Text = 'DNS-Rolle installieren / pruefen'; Aktion = { Install-NetDnsRole | Out-Null }; Hilfe = 'Installiert die DNS-Server-Rolle und die Verwaltungstools aus dem lokalen Windows, falls sie fehlen.' }
    )
    Show-NetMenu -Titel 'DNS' -Eintraege $eintraege
}
