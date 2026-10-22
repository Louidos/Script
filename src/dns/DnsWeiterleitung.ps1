# Weiterleitungen (Forwarder) und bedingte Weiterleitungen. Erreichbarkeit wird mit
# Resolve-DnsName -Server getestet; ohne Internet gibt es nur eine Warnung.

$script:NetWeiterleitungHilfe = @'
Weiterleitung oder Stammhinweise?
  - Weiterleitung (Forwarder): Der DNS-Server fragt fuer alle fremden Namen einen bestimmten
    anderen DNS-Server, z. B. Quad9 (9.9.9.9, filtert Schadseiten), Cloudflare (1.1.1.1)
    oder den Router. Schnell und einfach; ueblich in kleinen und mittleren Netzen.
  - Stammhinweise (Root Hints): Ohne Weiterleitung fragt der DNS-Server selbst bei den
    Stammservern des Internets nach und hangelt sich durch. Braucht freien Zugang ueber Port 53.
  - Bedingte Weiterleitung: gilt nur fuer eine bestimmte Domaene, z. B. partner.local -> 10.1.1.10.
Wichtig: Clients und Mitgliedsserver fragen immer die DCs, nie direkt 8.8.8.8 o. ae.
'@

function Get-NetDnsForwarderList {
    $fw = Get-NetSafe -Beschreibung 'Get-DnsServerForwarder' -Abfrage { Get-DnsServerForwarder }
    if (-not $fw) { return @() }
    return @($fw.IPAddress | Where-Object { $_ } | ForEach-Object { ConvertTo-NetString -Wert $_ })
}

function Test-NetDnsForwarder {
    <#
    .SYNOPSIS
        Prueft, ob ein DNS-Server antwortet (Abfrage der Stammzone). Liefert $true/$false.
    #>
    param([Parameter(Mandatory = $true)][string]$Server)
    $antwort = Get-NetSafe -Beschreibung "Weiterleitung $Server" -Abfrage { Resolve-DnsName -Name '.' -Type NS -Server $Server -DnsOnly -QuickTimeout }
    return [bool]$antwort
}

function Show-NetDnsForwarder {
    if (-not (Test-NetDnsReady)) { return }
    Write-NetTitle -Titel 'Weiterleitungen'
    $liste = @(Get-NetDnsForwarderList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Keine Weiterleitung eingestellt: der Server verwendet die Stammhinweise.' }
    foreach ($ip in $liste) {
        if (Test-NetDnsForwarder -Server $ip) { Write-NetStatus -Status OK -Bereich $ip -Text 'antwortet' }
        else { Write-NetStatus -Status WARN -Bereich $ip -Text 'antwortet nicht (ohne Internet normal)' }
    }
    $bedingt = @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -eq 'Forwarder' })
    if ($bedingt.Count -gt 0) {
        Write-Host '  Bedingte Weiterleitungen:'
        foreach ($b in $bedingt) { Write-Host ('    {0}' -f $b.Name) }
    }
}

function Set-NetDnsForwarder {
    <#
    .SYNOPSIS
        Setzt die Weiterleitungen (Vorschlaege: Quad9, Cloudflare, Router oder eigene).
    #>
    param([string[]]$Adressen)
    if (-not (Test-NetDnsReady)) { return $false }
    $alt = @(Get-NetDnsForwarderList)
    if (-not $Adressen) {
        Write-NetText -Text $script:NetWeiterleitungHilfe
        $router = ''
        $z = Get-NetSetupState
        $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1
        if ($karte -and $karte.Gateway.Count -gt 0) { $router = $karte.Gateway[0] }
        $vorschlag = @(Get-NetConfigValue -Pfad 'Vorschlaege.Weiterleitungen' -Standard @('9.9.9.9', '1.1.1.1'))
        $optionen = @(
            ('Vorschlag aus den Einstellungen: ' + ($vorschlag -join ', ')),
            'Quad9: 9.9.9.9 und 149.112.112.112 (filtert bekannte Schadseiten)',
            'Cloudflare: 1.1.1.1 und 1.0.0.1')
        if ($router) { $optionen += ('Router: ' + $router) }
        $optionen += 'Eigene Adressen eingeben'
        $optionen += 'Alle Weiterleitungen entfernen (Stammhinweise verwenden)'
        $i = Read-NetChoice -Frage ('Weiterleitungen (aktuell: {0})' -f $(if ($alt.Count) { $alt -join ', ' } else { 'keine' })) -Optionen $optionen -Vorschlag 1
        if ($i -lt 0) { return $false }
        $text = $optionen[$i]
        if ($text -like 'Vorschlag*') { $Adressen = $vorschlag }
        elseif ($text -like 'Quad9*') { $Adressen = @('9.9.9.9', '149.112.112.112') }
        elseif ($text -like 'Cloudflare*') { $Adressen = @('1.1.1.1', '1.0.0.1') }
        elseif ($text -like 'Router*') { $Adressen = @($router) }
        elseif ($text -like 'Alle*') { $Adressen = @() }
        else {
            $eingabe = Read-NetText -Frage 'DNS-Server (mit Komma getrennt)' -Pruefung {
                param($t)
                foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
                return $null
            }
            if (-not $eingabe) { return $false }
            $Adressen = @($eingabe.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    $neu = @($Adressen)
    if (($alt -join ',') -eq ($neu -join ',')) { Write-Log -Level OK -Message 'Die Weiterleitungen sind bereits so eingestellt.'; return $true }
    foreach ($ip in $neu) {
        if (Test-NetDnsForwarder -Server $ip) { Write-NetStatus -Status OK -Bereich $ip -Text 'antwortet' }
        else { Write-NetStatus -Status WARN -Bereich $ip -Text 'antwortet nicht - ohne Internetzugang ist das normal, die Einstellung kann trotzdem gesetzt werden' }
    }
    if ($neu.Count -eq 0) {
        $r = Invoke-NetChange -Titel 'Alle Weiterleitungen entfernen' -Stufe Bestaetigen -Vorher ($alt -join ', ') -Nachher '(Stammhinweise)' -BackupBereich @('Dns') -Aktion {
            Remove-DnsServerForwarder -IPAddress $alt -Force
        } -Rueckgaengig @{ Befehl = 'Set-DnsServerForwarder'; Parameter = @{ IPAddress = $alt } }
    }
    else {
        $rueck = @{ Befehl = 'Set-DnsServerForwarder'; Parameter = @{ IPAddress = $alt } }
        if ($alt.Count -eq 0) { $rueck = @{ Befehl = 'Remove-DnsServerForwarder'; Parameter = @{ IPAddress = $neu; Force = $true } } }
        $r = Invoke-NetChange -Titel 'Weiterleitungen setzen' -Stufe Bestaetigen -Vorher $(if ($alt.Count) { $alt -join ', ' } else { '(keine - Stammhinweise)' }) -Nachher ($neu -join ', ') -BackupBereich @('Dns') -Aktion {
            Set-DnsServerForwarder -IPAddress $neu
        } -Rueckgaengig $rueck
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Add-NetDnsConditionalForwarder {
    if (-not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text 'Bedingte Weiterleitung: Anfragen fuer eine bestimmte Domaene gehen an bestimmte DNS-Server (z. B. Partnerfirma, zweite Gesamtstruktur).'
    $name = Read-NetText -Frage 'Domaene (z. B. partner.local)' -Pruefung { param($t) if ($t -match '^[A-Za-z0-9.-]+$' -and $t.Contains('.')) { $null } else { 'Bitte einen Domaenennamen wie partner.local eingeben.' } }
    if (-not $name) { return $false }
    $name = $name.ToLower().TrimEnd('.')
    if (Get-NetSafe -Beschreibung "Zone $name" -Abfrage { Get-DnsServerZone -Name $name }) {
        Write-Log -Level Warn -Message "Fuer $name gibt es bereits eine Zone oder Weiterleitung. Nichts zu tun."
        return $true
    }
    $text = Read-NetText -Frage 'DNS-Server dieser Domaene (mit Komma getrennt)' -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $text) { return $false }
    $server = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($ip in $server) {
        if (-not (Test-NetDnsForwarder -Server $ip)) { Write-Log -Level Warn -Message "$ip antwortet nicht. Die Weiterleitung wird trotzdem angelegt." }
    }
    $p = @{ Name = $name; MasterServers = $server }
    if (Test-NetIsDomainController) { $p.ReplicationScope = 'Domain' }
    $r = Invoke-NetChange -Titel "Bedingte Weiterleitung fuer $name anlegen" -Stufe Bestaetigen -Vorher '(keine)' -Nachher @{ Domaene = $name; Server = ($server -join ', ') } -BackupBereich @('Dns') -Aktion {
        Add-DnsServerConditionalForwarderZone @p
    } -Rueckgaengig @{ Befehl = 'Remove-DnsServerZone'; Parameter = @{ Name = $name; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Remove-NetDnsConditionalForwarder {
    if (-not (Test-NetDnsReady)) { return }
    $liste = @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -eq 'Forwarder' })
    $z = Select-NetItem -Elemente $liste -Titel 'Welche bedingte Weiterleitung entfernen?' -Eigenschaften @('Name', 'Replikation')
    if (-not $z) { return }
    $name = $z.Name
    Invoke-NetChange -Titel "Bedingte Weiterleitung $name entfernen" -Stufe Gefaehrlich -Vorher $name -Nachher '(entfernt)' -BackupBereich @('Dns') -Aktion {
        Remove-DnsServerZone -Name $name -Force
    } | Out-Null
}

function Show-NetDnsForwarderMenu {
    $eintraege = @(
        @{ Text = 'Weiterleitungen anzeigen und testen'; Aktion = 'Show-NetDnsForwarder'; Hilfe = 'Zeigt die Weiterleitungen und prueft, ob sie antworten. Ohne Internet antworten externe Server nicht - das ist dann normal.' },
        @{ Text = 'Weiterleitungen setzen'; Aktion = { Set-NetDnsForwarder | Out-Null }; Hilfe = "Vorschlaege: Quad9 (9.9.9.9), Cloudflare (1.1.1.1) oder der Router.`nVorher/Nachher wird angezeigt, die alte Einstellung kann rueckgaengig gemacht werden." },
        @{ Text = 'Bedingte Weiterleitung anlegen'; Aktion = { Add-NetDnsConditionalForwarder | Out-Null }; Hilfe = 'Nur fuer eine bestimmte Domaene an bestimmte DNS-Server weiterleiten (z. B. Partnerfirma).' },
        @{ Text = 'Bedingte Weiterleitung entfernen'; Aktion = 'Remove-NetDnsConditionalForwarder'; Hilfe = 'Entfernt eine bedingte Weiterleitung (gefaehrlich: vorher Backup, Servername eintippen).' },
        @{ Text = 'Erklaerung: Weiterleitung oder Stammhinweise?'; Aktion = { Write-NetText -Text $script:NetWeiterleitungHilfe }; Hilfe = 'Erklaert den Unterschied zwischen Weiterleitung, Stammhinweisen und bedingter Weiterleitung.' }
    )
    Show-NetMenu -Titel 'DNS - Weiterleitungen' -Eintraege $eintraege -Einleitung $script:NetWeiterleitungHilfe
}
