# DNS-Zonen: anlegen (AD-integriert auf DCs, sonst dateibasiert), dynamische Updates,
# fehlende Reverse-Zonen vorschlagen, loeschen (Gefaehrlich).

function Test-NetIsDomainController {
    $z = $script:NS.Zustand
    if ($z -and $z.System) { return [bool]$z.System.IstDC }
    $cs = Get-NetSafe -Beschreibung 'DomainRole' -Abfrage { Get-CimInstance -ClassName Win32_ComputerSystem }
    return ($cs -and [int]$cs.DomainRole -ge 4)
}

function Read-NetDnsZoneStorage {
    <#
    .SYNOPSIS
        Fragt Speicherung und dynamische Updates fuer eine neue Zone ab.
    #>
    $ergebnis = @{ AdIntegriert = $false; Replikation = ''; Updates = 'None' }
    if (Test-NetIsDomainController) {
        $ergebnis.AdIntegriert = $true
        $i = Read-NetChoice -Frage 'Replikation der AD-integrierten Zone' -Optionen @(
            'Domain - auf alle DNS-Server der Domaene (ueblich)',
            'Forest - auf alle DNS-Server der Gesamtstruktur') -Vorschlag 1
        if ($i -lt 0) { return $null }
        $ergebnis.Replikation = @('Domain', 'Forest')[$i]
        $j = Read-NetChoice -Frage 'Dynamische Updates' -Optionen @(
            'Nur sicher (empfohlen: nur Domaenenmitglieder und der DHCP-Server duerfen eintragen)',
            'Sicher und unsicher (jedes Geraet darf eintragen - nicht empfohlen)',
            'Aus (nur manuelle Eintraege)') -Vorschlag 1
        if ($j -lt 0) { return $null }
        $ergebnis.Updates = @('Secure', 'NonsecureAndSecure', 'None')[$j]
    }
    else {
        Write-NetText -Text 'Ohne Domaenencontroller wird die Zone als Datei gespeichert. Sichere Updates gibt es dann nicht.'
        $j = Read-NetChoice -Frage 'Dynamische Updates' -Optionen @(
            'Sicher und unsicher (noetig, damit der DHCP-Server Clients eintragen kann)',
            'Aus (nur manuelle Eintraege)') -Vorschlag 1
        if ($j -lt 0) { return $null }
        $ergebnis.Updates = @('NonsecureAndSecure', 'None')[$j]
    }
    return $ergebnis
}

function New-NetDnsZone {
    <#
    .SYNOPSIS
        Legt eine primaere Zone an (idempotent: existiert sie schon, passiert nichts).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Speicherung,
        [string]$Netz = ''
    )
    $Name = $Name.Trim().TrimEnd('.').ToLower()
    $vorhanden = Get-NetSafe -Beschreibung "Zone $Name" -Abfrage { Get-DnsServerZone -Name $Name }
    if ($vorhanden) {
        Write-Log -Level OK -Message ("Die Zone {0} existiert bereits ({1}). Nichts zu tun." -f $Name, [string]$vorhanden.ZoneType)
        return $true
    }
    if (-not $Speicherung) { $Speicherung = Read-NetDnsZoneStorage }
    if (-not $Speicherung) { return $false }
    $p = @{ Name = $Name; DynamicUpdate = $Speicherung.Updates }
    if ($Speicherung.AdIntegriert) { $p.ReplicationScope = $Speicherung.Replikation }
    else { $p.ZoneFile = $Name + '.dns' }
    $nachher = @{ Zone = $Name; Speicherung = $(if ($Speicherung.AdIntegriert) { 'AD (' + $Speicherung.Replikation + ')' } else { 'Datei ' + $p.ZoneFile }); Updates = (ConvertTo-NetDnsUpdateText -Wert $Speicherung.Updates) }
    if ($Netz) { $nachher.Netz = $Netz }
    $r = Invoke-NetChange -Titel "DNS-Zone $Name anlegen" -Stufe Bestaetigen -Vorher '(Zone nicht vorhanden)' -Nachher $nachher -BackupBereich @('Dns') -Aktion {
        Add-DnsServerPrimaryZone @p
    } -Rueckgaengig @{ Befehl = 'Remove-DnsServerZone'; Parameter = @{ Name = $Name; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function New-NetDnsForwardZone {
    <#
    .SYNOPSIS
        Menue: Forward-Zone anlegen (z. B. die Domaene oder eine interne Zone ohne AD).
    #>
    if (-not (Test-NetDnsReady)) { return }
    $vorschlag = Get-NetDomainName
    Write-NetText -Text 'Eine Forward-Zone loest Namen in Adressen auf. Auf einem DC gibt es die Zone der Domaene schon nach der Heraufstufung.'
    $name = Read-NetText -Frage 'Name der Zone (z. B. ad.firma.ch)' -Vorschlag $vorschlag -Pruefung { param($t) (Test-NetDomainName -Name $t).Fehler }
    if (-not $name) { return }
    New-NetDnsZone -Name $name | Out-Null
}

function New-NetDnsReverseZone {
    <#
    .SYNOPSIS
        Menue: Reverse-Zone(n) fuer ein Netz anlegen.
    #>
    param([string]$Netz)
    if (-not (Test-NetDnsReady)) { return }
    Write-NetText -Text 'Eine Reverse-Zone loest Adressen in Namen auf (PTR). Pro Netz wird eine Zone gebraucht, z. B. 1.168.192.in-addr.arpa fuer 192.168.1.0/24.'
    $s = $null
    if ($Netz) { $s = ConvertTo-NetSubnet -Text $Netz }
    else { $s = Read-NetSubnet -Frage 'Netz (z. B. 192.168.1.0/24)' }
    if (-not $s) { return }
    if ($s.Prefix -lt 8) { Write-Log -Level Fehler -Message 'Netze groesser als /8 werden nicht unterstuetzt.'; return }
    $speicherung = $null
    foreach ($zone in @(Get-NetReverseZoneName -NetworkAddress $s.Netz -PrefixLength $s.Prefix)) {
        $existiert = Get-NetSafe -Beschreibung "Zone $zone" -Abfrage { Get-DnsServerZone -Name $zone }
        if ($existiert) { Write-Log -Level OK -Message "Reverse-Zone $zone existiert bereits."; continue }
        if (-not $speicherung) { $speicherung = Read-NetDnsZoneStorage }
        if (-not $speicherung) { return }
        New-NetDnsZone -Name $zone -Speicherung $speicherung -Netz $s.Text | Out-Null
    }
}

function Get-NetMissingReverseZone {
    <#
    .SYNOPSIS
        Ermittelt fehlende Reverse-Zonen fuer das Server-Netz und alle DHCP-Scopes.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    $netze = @()
    foreach ($k in @($Zustand.Netzwerk.AktiveKarten)) {
        foreach ($a in @($k.Adressen)) {
            if ($a.IP -like '169.254.*') { continue }
            $netze += [pscustomobject]@{ Netz = (Get-NetNetworkAddress -IPAddress $a.IP -PrefixLength $a.Prefix); Prefix = [int]$a.Prefix; Quelle = ('Netzwerkkarte ' + $k.Name) }
        }
    }
    foreach ($sc in @($Zustand.Dhcp.Scopes)) {
        if ($sc.Prefix -gt 0) { $netze += [pscustomobject]@{ Netz = $sc.ScopeId; Prefix = [int]$sc.Prefix; Quelle = ('DHCP-Scope ' + $sc.Name) } }
    }
    $zonen = @($Zustand.Dns.Zonen | Where-Object { $_.Reverse } | ForEach-Object { $_.Name })
    $fehlend = @()
    $gesehen = @{}
    foreach ($n in $netze) {
        if ($n.Prefix -lt 8) { continue }
        foreach ($zone in @(Get-NetReverseZoneName -NetworkAddress $n.Netz -PrefixLength $n.Prefix)) {
            if ($gesehen.ContainsKey($zone)) { continue }
            $gesehen[$zone] = $true
            # Eine groessere Zone (z. B. 168.192.in-addr.arpa) deckt das Netz ebenfalls ab.
            $teile = $zone.Replace('.in-addr.arpa', '').Split('.')
            [Array]::Reverse($teile)
            $beispiel = (@($teile) + @('0', '0', '0', '1'))[0..3] -join '.'
            if (Find-NetReverseZone -IPAddress $beispiel -ZoneNames $zonen) { continue }
            $fehlend += [pscustomobject]@{ Zone = $zone; Netz = ('{0}/{1}' -f $n.Netz, $n.Prefix); Quelle = $n.Quelle }
        }
    }
    return $fehlend
}

function Add-NetMissingReverseZone {
    <#
    .SYNOPSIS
        Schlaegt fehlende Reverse-Zonen vor und legt die gewaehlten an.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $fehlend = @(Get-NetMissingReverseZone)
    if ($fehlend.Count -eq 0) {
        Write-Log -Level OK -Message 'Fuer alle Netze (Server und DHCP-Scopes) gibt es eine Reverse-Zone.'
        return
    }
    Write-Log -Level Warn -Message ('{0} Reverse-Zone(n) fehlen. Ohne sie gibt es keine PTR-Eintraege (Adresse -> Name).' -f $fehlend.Count)
    $wahl = @(Select-NetItem -Elemente $fehlend -Titel 'Welche Reverse-Zonen anlegen?' -Eigenschaften @('Zone', 'Netz', 'Quelle') -Mehrfach)
    if ($wahl.Count -eq 0) { return }
    $speicherung = Read-NetDnsZoneStorage
    if (-not $speicherung) { return }
    foreach ($f in $wahl) { New-NetDnsZone -Name $f.Zone -Speicherung $speicherung -Netz $f.Netz | Out-Null }
}

function Set-NetDnsZoneUpdate {
    <#
    .SYNOPSIS
        Stellt die dynamischen Updates einer Zone ein.
    #>
    param([string]$Zone, [ValidateSet('', 'Secure', 'NonsecureAndSecure', 'None')][string]$Wert = '')
    if (-not (Test-NetDnsReady)) { return $false }
    $z = $null
    if ($Zone) { $z = @(Get-NetDnsZoneInfo -Art Primaer | Where-Object { $_.Name -eq $Zone }) | Select-Object -First 1 }
    else { $z = Select-NetDnsZone -Art Primaer -Titel 'Zone fuer dynamische Updates waehlen' }
    if (-not $z) { return $false }
    if (-not $Wert) {
        $optionen = @('Nur sicher (empfohlen)', 'Sicher und unsicher', 'Aus')
        $werte = @('Secure', 'NonsecureAndSecure', 'None')
        if (-not $z.AdIntegriert) { $optionen = @('Sicher und unsicher', 'Aus'); $werte = @('NonsecureAndSecure', 'None') }
        $i = Read-NetChoice -Frage ('Dynamische Updates fuer {0} (aktuell: {1})' -f $z.Name, (ConvertTo-NetDnsUpdateText -Wert $z.Updates)) -Optionen $optionen -Vorschlag 1
        if ($i -lt 0) { return $false }
        $Wert = $werte[$i]
    }
    if ($Wert -eq 'Secure' -and -not $z.AdIntegriert) {
        Write-Log -Level Fehler -Message 'Sichere Updates gibt es nur bei AD-integrierten Zonen (auf einem DC).'
        return $false
    }
    if ($z.Updates -eq $Wert) { Write-Log -Level OK -Message ('Die Zone {0} ist bereits so eingestellt.' -f $z.Name); return $true }
    $name = $z.Name
    $r = Invoke-NetChange -Titel "Dynamische Updates der Zone $name einstellen" -Stufe Bestaetigen -Vorher (ConvertTo-NetDnsUpdateText -Wert $z.Updates) -Nachher (ConvertTo-NetDnsUpdateText -Wert $Wert) -BackupBereich @('Dns') -Aktion {
        Set-DnsServerPrimaryZone -Name $name -DynamicUpdate $Wert
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerPrimaryZone'; Parameter = @{ Name = $name; DynamicUpdate = $z.Updates } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Remove-NetDnsZone {
    <#
    .SYNOPSIS
        Loescht eine Zone (Stufe Gefaehrlich: vorher Backup, Servername eintippen).
    #>
    if (-not (Test-NetDnsReady)) { return }
    $z = Select-NetDnsZone -Art Alle -Titel 'Welche Zone loeschen?'
    if (-not $z) { return }
    $name = $z.Name
    if ($name -like '_msdcs.*' -or $name -eq (Get-NetDomainName)) {
        Write-Log -Level Warn -Message 'Diese Zone gehoert zum Active Directory. Ohne sie funktioniert die Anmeldung an der Domaene nicht mehr!'
    }
    $anzahl = @(Get-NetDnsRecord -Zone $name).Count
    $r = Invoke-NetChange -Titel "DNS-Zone $name loeschen" -Stufe Gefaehrlich -Vorher @{ Zone = $name; Eintraege = $anzahl; Typ = $z.Typ } -Nachher '(Zone geloescht)' -BackupBereich @('Dns') `
        -Hinweis 'Alle Eintraege der Zone gehen verloren. Sie lassen sich nur aus dem Backup (CSV) wiederherstellen.' -Aktion {
        Remove-DnsServerZone -Name $name -Force
    }
    if ($r.Erfolg -and -not $r.Probelauf) { Write-Log -Level OK -Message "Zone $name geloescht. Wiederherstellung ueber das Backup-Menue (DNS-Eintraege aus CSV)." }
}
