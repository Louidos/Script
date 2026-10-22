# Massenimport aus CSV fuer DNS-Eintraege und DHCP-Reservierungen.
# Jede Zeile wird vorher geprueft; bei einem Fehler wird nichts importiert (alles oder nichts).
# Vorlagen liegen im Ordner Vorlagen (Trennzeichen Semikolon).

$script:NetVorlageDns = @(
    'Zone;Name;Typ;Wert;Prioritaet;Gewicht;Port',
    'ad.firma.ch;drucker-buero;A;192.168.1.30;;;',
    'ad.firma.ch;intranet;CNAME;srv01.ad.firma.ch;;;',
    'ad.firma.ch;@;MX;mail.firma.ch;10;;',
    'ad.firma.ch;@;TXT;v=spf1 mx -all;;;',
    'ad.firma.ch;_sip._tcp;SRV;sip.ad.firma.ch;0;100;5060'
)
$script:NetVorlageReservierung = @(
    'ScopeId;IP;MAC;Name;Beschreibung',
    '192.168.1.0;192.168.1.150;00-15-5D-01-02-03;drucker-buero;Drucker im Buero',
    '192.168.1.0;192.168.1.151;00-15-5D-01-02-04;telefon-empfang;IP-Telefon'
)

function New-NetImportTemplate {
    <#
    .SYNOPSIS
        Legt die Beispiel-CSVs im Ordner Vorlagen an (vorhandene werden nicht ueberschrieben).
    #>
    $ordner = Get-NetPath -Name Vorlagen
    if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
    foreach ($v in @(@{ Datei = 'dns-eintraege.csv'; Inhalt = $script:NetVorlageDns }, @{ Datei = 'reservierungen.csv'; Inhalt = $script:NetVorlageReservierung })) {
        $pfad = Join-Path -Path $ordner -ChildPath $v.Datei
        if (Test-Path -Path $pfad) { Write-Log -Message ('Vorlage existiert bereits: ' + $pfad); continue }
        Set-Content -Path $pfad -Value $v.Inhalt -Encoding UTF8
        Write-Log -Level OK -Message ('Vorlage angelegt: ' + $pfad)
    }
}

function ConvertTo-NetDnsImportRow {
    <#
    .SYNOPSIS
        Prueft eine CSV-Zeile fuer DNS und liefert @{ Fehler; Eintrag } (Eintrag fuer Add-NetDnsRecordExact).
    #>
    param([Parameter(Mandatory = $true)][object]$Zeile, [string[]]$Zonen)
    $typ = ([string]$Zeile.Typ).Trim().ToUpper()
    $zone = ([string]$Zeile.Zone).Trim().ToLower().TrimEnd('.')
    $name = ([string]$Zeile.Name).Trim()
    $wert = ([string]$Zeile.Wert).Trim()
    if ($script:NetDnsTypen -notcontains $typ) { return @{ Fehler = "Typ '$typ' ist unbekannt (erlaubt: $($script:NetDnsTypen -join ', '))." } }
    if ($Zonen -notcontains $zone) { return @{ Fehler = "Zone '$zone' gibt es auf diesem DNS-Server nicht." } }
    $grund = Test-NetDnsRecordName -Name $name -Srv:($typ -eq 'SRV')
    if ($grund) { return @{ Fehler = $grund } }
    if (-not $wert) { return @{ Fehler = 'Wert fehlt.' } }
    $daten = @{}
    $fqdnOk = ((Test-NetDomainName -Name $wert).Gueltig -or $wert -match '^[A-Za-z0-9-]+$')
    switch ($typ) {
        'A' { if (-not (Test-NetIPv4Address -Text $wert)) { return @{ Fehler = "'$wert' ist keine gueltige IPv4-Adresse." } }; $daten.IPv4Address = $wert }
        'AAAA' { if (-not (Test-NetIPv6Address -Text $wert)) { return @{ Fehler = "'$wert' ist keine gueltige IPv6-Adresse." } }; $daten.IPv6Address = $wert }
        'CNAME' { if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }; $daten.HostNameAlias = $wert }
        'PTR' { if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }; $daten.PtrDomainName = $wert }
        'TXT' { if ($wert.Length -gt 255) { return @{ Fehler = 'Text ist laenger als 255 Zeichen.' } }; $daten.DescriptiveText = $wert }
        'MX' {
            if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }
            $prio = 0
            if (-not [int]::TryParse([string]$Zeile.Prioritaet, [ref]$prio) -or $prio -lt 0 -or $prio -gt 65535) { return @{ Fehler = 'Prioritaet muss eine Zahl von 0 bis 65535 sein.' } }
            $daten.MailExchange = $wert; $daten.Preference = $prio
        }
        'SRV' {
            if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }
            $prio = 0; $gew = 0; $port = 0
            if (-not [int]::TryParse([string]$Zeile.Prioritaet, [ref]$prio) -or -not [int]::TryParse([string]$Zeile.Gewicht, [ref]$gew) -or -not [int]::TryParse([string]$Zeile.Port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                return @{ Fehler = 'SRV braucht Prioritaet, Gewicht und Port (1-65535) als Zahlen.' }
            }
            $daten.DomainName = $wert; $daten.Priority = $prio; $daten.Weight = $gew; $daten.Port = $port
        }
    }
    return @{ Fehler = $null; Eintrag = @{ ZoneName = $zone; Name = $name; Typ = $typ; Daten = $daten } }
}

function Test-NetDnsImport {
    <#
    .SYNOPSIS
        Prueft alle Zeilen einer DNS-CSV. Liefert Fehler (pro Zeile), Neu und Vorhanden.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Zeilen)
    $zonen = @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -eq 'Primary' } | ForEach-Object { $_.Name })
    $fehler = @()
    $neu = @()
    $vorhanden = @()
    $gesehen = @{}
    $nr = 1
    foreach ($z in $Zeilen) {
        $nr++
        $r = ConvertTo-NetDnsImportRow -Zeile $z -Zonen $zonen
        if ($r.Fehler) { $fehler += ('Zeile {0}: {1}' -f $nr, $r.Fehler); continue }
        $e = $r.Eintrag
        $schluessel = ('{0}|{1}|{2}|{3}' -f $e.ZoneName, $e.Name, $e.Typ, (($e.Daten.Keys | Sort-Object | ForEach-Object { $e.Daten[$_] }) -join ',')).ToLower()
        if ($gesehen.ContainsKey($schluessel)) { $fehler += ('Zeile {0}: doppelt in der Datei (wie Zeile {1}).' -f $nr, $gesehen[$schluessel]); continue }
        $gesehen[$schluessel] = $nr
        $pruef = Test-NetDnsRecordConflict -Zone $e.ZoneName -Name $e.Name -Typ $e.Typ -Daten $e.Daten
        if ($pruef.Duplikat) { $vorhanden += $e; continue }
        if ($pruef.Konflikte.Count -gt 0) { $fehler += ('Zeile {0}: Konflikt - {1}' -f $nr, ($pruef.Konflikte -join ' ')); continue }
        $neu += $e
    }
    return [pscustomobject]@{ Fehler = $fehler; Neu = $neu; Vorhanden = $vorhanden }
}

function Test-NetReservationImport {
    <#
    .SYNOPSIS
        Prueft alle Zeilen einer Reservierungs-CSV (Scope, Bereich, Ausschluss, belegt, MAC, Name).
    #>
    param([Parameter(Mandatory = $true)][object[]]$Zeilen)
    $scopes = @(Get-NetDhcpScopeList)
    $fehler = @()
    $neu = @()
    $vorhanden = @()
    $ipGesehen = @{}
    $macGesehen = @{}
    $cache = @{}
    $nr = 1
    foreach ($z in $Zeilen) {
        $nr++
        $id = ([string]$z.ScopeId).Trim()
        $ip = ([string]$z.IP).Trim()
        $mac = ConvertTo-NetMacAddress -Text ([string]$z.MAC)
        $name = ([string]$z.Name).Trim()
        $scope = @($scopes | Where-Object { $_.ScopeId -eq $id }) | Select-Object -First 1
        if (-not $scope) { $fehler += ("Zeile {0}: Scope '{1}' gibt es nicht." -f $nr, $id); continue }
        if (-not (Test-NetIPv4Address -Text $ip)) { $fehler += ("Zeile {0}: '{1}' ist keine gueltige IPv4-Adresse." -f $nr, $ip); continue }
        if (-not $mac) { $fehler += ("Zeile {0}: '{1}' ist keine gueltige MAC-Adresse." -f $nr, $z.MAC); continue }
        $grund = Test-NetDnsRecordName -Name $name
        if (-not $name -or $grund) { $fehler += ('Zeile {0}: Name ungueltig ({1}).' -f $nr, $grund); continue }
        if ($ipGesehen.ContainsKey($ip)) { $fehler += ('Zeile {0}: IP {1} kommt schon in Zeile {2} vor.' -f $nr, $ip, $ipGesehen[$ip]); continue }
        if ($macGesehen.ContainsKey($mac)) { $fehler += ('Zeile {0}: MAC {1} kommt schon in Zeile {2} vor.' -f $nr, $mac, $macGesehen[$mac]); continue }
        $ipGesehen[$ip] = $nr
        $macGesehen[$mac] = $nr
        if (-not $cache.ContainsKey($id)) {
            $cache[$id] = @{
                Aus  = @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id })
                Res  = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })
                Leas = @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id })
            }
        }
        $c = $cache[$id]
        $gleich = @($c.Res | Where-Object { $_ -and (ConvertTo-NetString $_.IPAddress) -eq $ip -and (ConvertTo-NetMacAddress -Text ([string]$_.ClientId)) -eq $mac })
        if ($gleich.Count -gt 0) { $vorhanden += @{ ScopeId = $id; IP = $ip }; continue }
        $probleme = @(Test-NetDhcpReservation -Scope $scope -IPAddress $ip -Mac $mac -Ausschluesse $c.Aus -Reservierungen $c.Res -Leases $c.Leas)
        if ($probleme.Count -gt 0) { $fehler += ('Zeile {0}: {1}' -f $nr, ($probleme -join ' ')); continue }
        $neu += @{ ScopeId = $id; IPAddress = $ip; ClientId = $mac; Name = $name; Description = ([string]$z.Beschreibung) }
    }
    return [pscustomobject]@{ Fehler = $fehler; Neu = $neu; Vorhanden = $vorhanden }
}

function Import-NetCsv {
    <#
    .SYNOPSIS
        Massenimport (DNS oder Reservierungen): pruefen, Ergebnis zeigen (wie im Probelauf),
        nach Bestaetigung alles importieren. Bei einem Fehler waehrend des Imports wird das
        bereits Angelegte wieder entfernt - nichts wird halb importiert.
    #>
    param([ValidateSet('Dns', 'Reservierung')][string]$Art, [string]$Datei)
    if (-not $Art) {
        $i = Read-NetChoice -Frage 'Was importieren?' -Optionen @('DNS-Eintraege', 'DHCP-Reservierungen') -Vorschlag 1
        if ($i -lt 0) { return $false }
        $Art = @('Dns', 'Reservierung')[$i]
    }
    if ($Art -eq 'Dns' -and -not (Test-NetDnsReady)) { return $false }
    if ($Art -eq 'Reservierung' -and -not (Test-NetDhcpReady)) { return $false }
    if (-not $Datei) {
        $vorlage = Join-Path -Path (Get-NetPath -Name Vorlagen) -ChildPath $(if ($Art -eq 'Dns') { 'dns-eintraege.csv' } else { 'reservierungen.csv' })
        Write-NetText -Text ('Format siehe Vorlage: ' + $vorlage + ' (Trennzeichen Semikolon, erste Zeile = Spaltennamen).')
        $Datei = Read-NetText -Frage 'Pfad zur CSV-Datei' -Vorschlag $vorlage -Pruefung { param($t) if (Test-Path -Path $t -PathType Leaf) { $null } else { 'Die Datei existiert nicht.' } }
        if (-not $Datei) { return $false }
    }
    $zeilen = @(Import-Csv -Path $Datei -Delimiter ';' -Encoding UTF8)
    if ($zeilen.Count -eq 0) { Write-Log -Level Warn -Message 'Die Datei enthaelt keine Zeilen.'; return $false }
    $pflicht = @('Zone', 'Name', 'Typ', 'Wert')
    if ($Art -eq 'Reservierung') { $pflicht = @('ScopeId', 'IP', 'MAC', 'Name') }
    $spalten = @($zeilen[0].PSObject.Properties | ForEach-Object { $_.Name })
    $fehlt = @($pflicht | Where-Object { $spalten -notcontains $_ })
    if ($fehlt.Count -gt 0) { Write-Log -Level Fehler -Message ('Spalten fehlen: ' + ($fehlt -join ', ') + '. Trennzeichen muss ein Semikolon sein.'); return $false }

    $ergebnis = $null
    if ($Art -eq 'Dns') { $ergebnis = Test-NetDnsImport -Zeilen $zeilen } else { $ergebnis = Test-NetReservationImport -Zeilen $zeilen }
    Write-NetTitle -Titel ('Pruefung der Datei: {0} Zeilen' -f $zeilen.Count)
    Write-NetStatus -Status OK -Bereich 'neu anzulegen' -Text ([string]@($ergebnis.Neu).Count)
    Write-NetStatus -Status NA -Bereich 'schon vorhanden' -Text ([string]@($ergebnis.Vorhanden).Count)
    if (@($ergebnis.Fehler).Count -gt 0) {
        Write-NetStatus -Status FEHLER -Bereich 'fehlerhafte Zeilen' -Text ([string]@($ergebnis.Fehler).Count)
        foreach ($f in $ergebnis.Fehler) { Write-Host ('    ' + $f) -ForegroundColor Red }
        Write-Log -Level Fehler -Message 'Es wird nichts importiert. Bitte die Zeilen korrigieren und erneut starten.'
        return $false
    }
    $neu = @($ergebnis.Neu)
    if ($neu.Count -eq 0) { Write-Log -Level OK -Message 'Alles aus der Datei ist schon vorhanden. Nichts zu tun.'; return $true }
    $anzeige = @()
    $rueck = @()
    if ($Art -eq 'Dns') {
        $anzeige = @($neu | ForEach-Object { '{0} {1} {2} in {3}' -f $_.Name, $_.Typ, (($_.Daten.Values | ForEach-Object { [string]$_ }) -join ' '), $_.ZoneName })
        $rueck = @($neu | ForEach-Object { @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $_.ZoneName; Name = $_.Name; Typ = $_.Typ; Daten = $_.Daten } } })
    }
    else {
        $anzeige = @($neu | ForEach-Object { '{0} {1} {2} (Scope {3})' -f $_.IPAddress, $_.ClientId, $_.Name, $_.ScopeId })
        $rueck = @($neu | ForEach-Object { @{ Befehl = 'Remove-DhcpServerv4Reservation'; Parameter = @{ IPAddress = $_.IPAddress } } })
    }
    $importArt = $Art
    $r = Invoke-NetChange -Titel ('{0} {1} aus CSV importieren' -f $neu.Count, $(if ($Art -eq 'Dns') { 'DNS-Eintraege' } else { 'Reservierungen' })) -Stufe Bestaetigen -Vorher ('{0} vorhanden' -f @($ergebnis.Vorhanden).Count) -Nachher $anzeige -BackupBereich @($(if ($Art -eq 'Dns') { 'Dns' } else { 'Dhcp' })) -Aktion {
        $angelegt = New-Object System.Collections.ArrayList
        try {
            foreach ($e in $neu) {
                if ($importArt -eq 'Dns') { Add-NetDnsRecordExact -ZoneName $e.ZoneName -Name $e.Name -Typ $e.Typ -Daten $e.Daten }
                else { Add-DhcpServerv4Reservation -ScopeId $e.ScopeId -IPAddress $e.IPAddress -ClientId $e.ClientId -Name $e.Name -Description $e.Description }
                [void]$angelegt.Add($e)
            }
        }
        catch {
            $fehlerText = $_.Exception.Message
            Write-Log -Level Warn -Message ('Fehler beim Import ({0}). {1} bereits angelegte Eintraege werden wieder entfernt.' -f $fehlerText, $angelegt.Count)
            for ($i = $angelegt.Count - 1; $i -ge 0; $i--) {
                $x = $angelegt[$i]
                try {
                    if ($importArt -eq 'Dns') { Remove-NetDnsRecordExact -ZoneName $x.ZoneName -Name $x.Name -Typ $x.Typ -Daten $x.Daten }
                    else { Remove-DhcpServerv4Reservation -IPAddress $x.IPAddress }
                }
                catch { Write-Log -Level Fehler -Message ('Konnte {0} nicht zuruecknehmen: {1}' -f $x.Name, $_.Exception.Message) }
            }
            throw
        }
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
