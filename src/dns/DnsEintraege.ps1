# DNS-Eintraege: A (optional mit PTR), AAAA, CNAME, MX, SRV, TXT, PTR anlegen, aendern, loeschen
# und suchen. Vor dem Anlegen wird auf Duplikate und Konflikte geprueft (idempotent).

$script:NetDnsTypen = @('A', 'AAAA', 'CNAME', 'MX', 'SRV', 'TXT', 'PTR')

function Test-NetIPv6Address {
    param([AllowEmptyString()][string]$Text)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Text, [ref]$ip)) { return $false }
    return ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6)
}

function Test-NetDnsRecordName {
    <#
    .SYNOPSIS
        Prueft einen relativen Namen ('@' fuer die Zone selbst). Liefert $null oder den Grund.
    #>
    param([string]$Name, [switch]$Srv)
    if ($Name -eq '@') { return $null }
    if (-not $Name) { return 'Bitte einen Namen eingeben (oder @ fuer die Zone selbst).' }
    foreach ($teil in $Name.TrimEnd('.').Split('.')) {
        if ($Srv -and $teil -match '^_[A-Za-z0-9-]+$') { continue }
        if ($teil -eq '*') { continue }
        if (-not (Test-NetDnsLabel -Label $teil)) { return "Der Teil '$teil' ist ungueltig (a-z, 0-9, Bindestrich; bei SRV z. B. _sip._tcp)." }
    }
    return $null
}

function Read-NetDnsRecordData {
    <#
    .SYNOPSIS
        Fragt die Daten eines Eintragstyps ab und liefert eine Hashtable (oder $null bei Abbruch).
    #>
    param([Parameter(Mandatory = $true)][string]$Typ, [hashtable]$Vorschlag = @{})
    $fqdn = { param($t) if ((Test-NetDomainName -Name $t).Gueltig -or $t -match '^[A-Za-z0-9-]+$') { $null } else { 'Bitte einen gueltigen Namen eingeben, z. B. srv01.ad.firma.ch' } }
    switch ($Typ) {
        'A' {
            $ip = Read-NetIPAddress -Frage 'IPv4-Adresse' -Vorschlag ([string]$Vorschlag.IPv4Address)
            if (-not $ip) { return $null }
            return @{ IPv4Address = $ip }
        }
        'AAAA' {
            $ip = Read-NetText -Frage 'IPv6-Adresse' -Vorschlag ([string]$Vorschlag.IPv6Address) -Pruefung { param($t) if (Test-NetIPv6Address -Text $t) { $null } else { 'Keine gueltige IPv6-Adresse.' } }
            if (-not $ip) { return $null }
            return @{ IPv6Address = $ip }
        }
        'CNAME' {
            $ziel = Read-NetText -Frage 'Ziel (vollstaendiger Name, z. B. srv01.ad.firma.ch)' -Vorschlag ([string]$Vorschlag.HostNameAlias) -Pruefung $fqdn
            if (-not $ziel) { return $null }
            return @{ HostNameAlias = $ziel }
        }
        'MX' {
            $mx = Read-NetText -Frage 'Mailserver (vollstaendiger Name)' -Vorschlag ([string]$Vorschlag.MailExchange) -Pruefung $fqdn
            if (-not $mx) { return $null }
            $pref = Read-NetNumber -Frage 'Prioritaet (kleiner = bevorzugt)' -Minimum 0 -Maximum 65535 -Vorschlag $(if ($Vorschlag.Preference) { [int]$Vorschlag.Preference } else { 10 })
            if ($null -eq $pref) { return $null }
            return @{ MailExchange = $mx; Preference = $pref }
        }
        'SRV' {
            $ziel = Read-NetText -Frage 'Zielserver (vollstaendiger Name)' -Vorschlag ([string]$Vorschlag.DomainName) -Pruefung $fqdn
            if (-not $ziel) { return $null }
            $prio = Read-NetNumber -Frage 'Prioritaet' -Minimum 0 -Maximum 65535 -Vorschlag $(if ($null -ne $Vorschlag.Priority) { [int]$Vorschlag.Priority } else { 0 })
            if ($null -eq $prio) { return $null }
            $gew = Read-NetNumber -Frage 'Gewichtung' -Minimum 0 -Maximum 65535 -Vorschlag $(if ($null -ne $Vorschlag.Weight) { [int]$Vorschlag.Weight } else { 100 })
            if ($null -eq $gew) { return $null }
            $port = Read-NetNumber -Frage 'Port' -Minimum 1 -Maximum 65535 -Vorschlag $(if ($Vorschlag.Port) { [int]$Vorschlag.Port } else { $null })
            if ($null -eq $port) { return $null }
            return @{ DomainName = $ziel; Priority = $prio; Weight = $gew; Port = $port }
        }
        'TXT' {
            $text = Read-NetText -Frage 'Text (z. B. v=spf1 mx -all)' -Vorschlag ([string]$Vorschlag.DescriptiveText) -Pruefung { param($t) if ($t.Length -gt 255) { 'Hoechstens 255 Zeichen pro Text.' } else { $null } }
            if (-not $text) { return $null }
            return @{ DescriptiveText = $text }
        }
        'PTR' {
            $ziel = Read-NetText -Frage 'Name, auf den die Adresse zeigt (z. B. pc01.ad.firma.ch)' -Vorschlag ([string]$Vorschlag.PtrDomainName) -Pruefung $fqdn
            if (-not $ziel) { return $null }
            return @{ PtrDomainName = $ziel }
        }
    }
    return $null
}

function Test-NetDnsRecordConflict {
    <#
    .SYNOPSIS
        Prueft vor dem Anlegen auf Duplikat (gleiche Daten) und Konflikte (CNAME, andere Adresse).
    .OUTPUTS
        PSCustomObject mit Duplikat (bool), Konflikte (Liste), Vorhanden (Liste).
    #>
    param([Parameter(Mandatory = $true)][string]$Zone, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Typ, [Parameter(Mandatory = $true)][hashtable]$Daten)
    $vorhanden = @(Get-NetDnsRecord -Zone $Zone -Name $Name)
    $gleich = @($vorhanden | Where-Object { $_.Typ -eq $Typ -and (Test-NetDnsRecordEqual -A $Daten -B $_.Daten) })
    $konflikte = @()
    if ($Typ -eq 'CNAME') {
        $konflikte += @($vorhanden | Where-Object { $_.Typ -ne 'CNAME' -or -not (Test-NetDnsRecordEqual -A $Daten -B $_.Daten) } | ForEach-Object { '{0} {1} ist vorhanden - ein CNAME darf nicht neben anderen Eintraegen stehen.' -f $_.Typ, $_.Wert })
    }
    else {
        $konflikte += @($vorhanden | Where-Object { $_.Typ -eq 'CNAME' } | ForEach-Object { 'Der Name ist bereits ein CNAME auf {0}.' -f $_.Wert })
        if ($Typ -eq 'A' -or $Typ -eq 'AAAA' -or $Typ -eq 'PTR') {
            $konflikte += @($vorhanden | Where-Object { $_.Typ -eq $Typ -and -not (Test-NetDnsRecordEqual -A $Daten -B $_.Daten) } | ForEach-Object { 'Es gibt schon einen {0}-Eintrag mit {1}.' -f $_.Typ, $_.Wert })
        }
    }
    return [pscustomobject]@{ Duplikat = ($gleich.Count -gt 0); Konflikte = $konflikte; Vorhanden = $vorhanden }
}

function Add-NetDnsRecord {
    <#
    .SYNOPSIS
        Legt einen DNS-Eintrag an (mit Duplikat- und Konfliktpruefung, optional PTR zum A-Eintrag).
    #>
    param(
        [string]$Zone,
        [string]$Name,
        [ValidateSet('', 'A', 'AAAA', 'CNAME', 'MX', 'SRV', 'TXT', 'PTR')][string]$Typ = '',
        [hashtable]$Daten,
        [Nullable[bool]]$MitPtr = $null
    )
    if (-not (Test-NetDnsReady)) { return $false }
    if (-not $Typ) {
        $i = Read-NetChoice -Frage 'Welcher Eintragstyp?' -Optionen @(
            'A - Name zu IPv4-Adresse (optional mit PTR)', 'AAAA - Name zu IPv6-Adresse', 'CNAME - Alias auf einen anderen Namen',
            'MX - Mailserver', 'SRV - Dienst mit Port', 'TXT - Text (z. B. SPF)', 'PTR - Adresse zu Name') -Vorschlag 1
        if ($i -lt 0) { return $false }
        $Typ = $script:NetDnsTypen[$i]
    }
    if (-not $Zone) {
        $art = 'Forward'
        if ($Typ -eq 'PTR') { $art = 'Reverse' }
        $z = Select-NetDnsZone -Art $art -Titel 'In welche Zone?'
        if (-not $z) { return $false }
        $Zone = $z.Name
    }
    if (-not $Name) {
        $frage = 'Name (relativ zur Zone, @ = Zone selbst)'
        if ($Typ -eq 'PTR') { $frage = 'Letzte(s) Oktett(e) der Adresse in umgekehrter Reihenfolge (z. B. 50 fuer .50)' }
        if ($Typ -eq 'SRV') { $frage = 'Name, z. B. _sip._tcp' }
        $istSrv = ($Typ -eq 'SRV')
        $Name = Read-NetText -Frage $frage -Pruefung { param($t) Test-NetDnsRecordName -Name $t -Srv:$istSrv }
        if (-not $Name) { return $false }
    }
    if (-not $Daten) { $Daten = Read-NetDnsRecordData -Typ $Typ }
    if (-not $Daten) { return $false }

    $pruef = Test-NetDnsRecordConflict -Zone $Zone -Name $Name -Typ $Typ -Daten $Daten
    if ($pruef.Duplikat) {
        Write-Log -Level OK -Message ('Der Eintrag {0} {1} {2} existiert bereits in {3}. Nichts zu tun.' -f $Name, $Typ, (($Daten.Values | ForEach-Object { [string]$_ }) -join ' '), $Zone)
        return $true
    }
    foreach ($k in $pruef.Konflikte) { Write-Log -Level Warn -Message $k }
    if ($pruef.Konflikte.Count -gt 0 -and -not (Read-NetYesNo -Frage 'Trotzdem zusaetzlich anlegen?' -Vorschlag $false)) { return $false }

    $ptr = $false
    if ($Typ -eq 'A') {
        $reverse = Find-NetReverseZone -IPAddress $Daten.IPv4Address -ZoneNames @(Get-NetDnsZoneInfo -Art Reverse | ForEach-Object { $_.Name })
        if ($null -eq $MitPtr) {
            if ($reverse) { $MitPtr = Read-NetYesNo -Frage ('Passenden PTR-Eintrag in {0} mit anlegen?' -f $reverse) -Vorschlag $true }
            else { Write-Log -Level Warn -Message ('Fuer {0} gibt es keine Reverse-Zone, deshalb kein PTR. Tipp: DNS-Menue -> Zonen -> Fehlende Reverse-Zonen.' -f $Daten.IPv4Address); $MitPtr = $false }
        }
        $ptr = [bool]$MitPtr -and [bool]$reverse
    }
    $zoneName = $Zone
    $eintragName = $Name
    $eintragTyp = $Typ
    $eintragDaten = $Daten
    $rueck = @(@{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $eintragDaten } })
    if ($ptr) {
        $rz = Find-NetReverseZone -IPAddress $Daten.IPv4Address -ZoneNames @(Get-NetDnsZoneInfo -Art Reverse | ForEach-Object { $_.Name })
        $voll = $Name
        if ($Name -eq '@') { $voll = $Zone } else { $voll = $Name + '.' + $Zone }
        $rueck += @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $rz; Name = (Get-NetPtrName -IPAddress $Daten.IPv4Address -ZoneName $rz); Typ = 'PTR'; Daten = @{ PtrDomainName = $voll + '.' } } }
    }
    $anzeige = @{ Zone = $Zone; Name = $Name; Typ = $Typ; Wert = (($Daten.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Daten[$_] }) -join ', ') }
    if ($Typ -eq 'A') { $anzeige.PTR = $(if ($ptr) { 'ja' } else { 'nein' }) }
    $r = Invoke-NetChange -Titel ('DNS-Eintrag {0} ({1}) in {2} anlegen' -f $Name, $Typ, $Zone) -Stufe Bestaetigen -Vorher @($pruef.Vorhanden | ForEach-Object { '{0} {1}' -f $_.Typ, $_.Wert }) -Nachher $anzeige -BackupBereich @('Dns') -Aktion {
        Add-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $eintragDaten -CreatePtr:$ptr
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Select-NetDnsRecord {
    param([string]$Titel = 'Eintrag waehlen')
    $z = Select-NetDnsZone -Art Alle -Titel 'Zone waehlen'
    if (-not $z) { return $null }
    $filter = Read-NetText -Frage 'Nur Namen mit diesem Text zeigen (leer = alle)' -LeerErlaubt
    if ($null -eq $filter) { return $null }
    $liste = @(Get-NetDnsRecord -Zone $z.Name | Where-Object { $script:NetDnsTypen -contains $_.Typ -and (-not $filter -or $_.Name -like "*$filter*" -or $_.Wert -like "*$filter*") })
    return (Select-NetItem -Elemente $liste -Titel $Titel -Eigenschaften @('Name', 'Typ', 'Wert', 'Statisch'))
}

function Show-NetDnsRecord {
    if (-not (Test-NetDnsReady)) { return }
    $z = Select-NetDnsZone -Art Alle -Titel 'Eintraege welcher Zone anzeigen?'
    if (-not $z) { return }
    $liste = @(Get-NetDnsRecord -Zone $z.Name)
    Write-NetTitle -Titel ('Eintraege in {0} ({1})' -f $z.Name, $liste.Count)
    foreach ($e in ($liste | Sort-Object -Property Typ, Name)) {
        $alter = 'statisch'
        if (-not $e.Statisch) { $alter = 'dynamisch ' + $e.Zeitstempel.ToString('yyyy-MM-dd') }
        Write-Host ('  {0,-30} {1,-6} {2,-40} {3}' -f $e.Name, $e.Typ, $e.Wert, $alter)
    }
}

function Find-NetDnsRecord {
    <#
    .SYNOPSIS
        Sucht einen Namen oder eine Adresse in allen Zonen.
    #>
    param([string]$Suche)
    if (-not (Test-NetDnsReady)) { return }
    if (-not $Suche) { $Suche = Read-NetText -Frage 'Suchbegriff (Teil eines Namens oder einer Adresse)' }
    if (-not $Suche) { return }
    $treffer = @()
    foreach ($z in @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -ne 'Forwarder' })) {
        $treffer += @(Get-NetDnsRecord -Zone $z.Name | Where-Object { $_.Name -like "*$Suche*" -or $_.Wert -like "*$Suche*" })
    }
    Write-NetTitle -Titel ("Suche nach '{0}': {1} Treffer" -f $Suche, $treffer.Count)
    foreach ($e in $treffer) { Write-Host ('  {0,-28} {1,-25} {2,-6} {3}' -f $e.Zone, $e.Name, $e.Typ, $e.Wert) }
    return $treffer
}

function Remove-NetDnsRecord {
    <#
    .SYNOPSIS
        Loescht einen gewaehlten Eintrag (Gegenaktion: wieder anlegen).
    #>
    param([object]$Eintrag)
    if (-not (Test-NetDnsReady)) { return $false }
    if (-not $Eintrag) { $Eintrag = Select-NetDnsRecord -Titel 'Welchen Eintrag loeschen?' }
    if (-not $Eintrag) { return $false }
    if ($script:NetDnsTypen -notcontains $Eintrag.Typ) { Write-Log -Level Warn -Message 'Dieser Eintragstyp wird von Windows verwaltet und hier nicht geloescht.'; return $false }
    $zoneName = $Eintrag.Zone
    $eintragName = $Eintrag.Name
    $eintragTyp = $Eintrag.Typ
    $eintragDaten = $Eintrag.Daten
    $r = Invoke-NetChange -Titel ('DNS-Eintrag {0} ({1}) aus {2} loeschen' -f $eintragName, $eintragTyp, $zoneName) -Stufe Bestaetigen -Vorher ('{0} {1} {2}' -f $eintragName, $eintragTyp, $Eintrag.Wert) -Nachher '(geloescht)' -BackupBereich @('Dns') -Aktion {
        Remove-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $eintragDaten
    } -Rueckgaengig @{ Befehl = 'Add-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $eintragDaten } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Edit-NetDnsRecord {
    <#
    .SYNOPSIS
        Aendert die Daten eines Eintrags (alter Eintrag wird ersetzt, Gegenaktion stellt ihn wieder her).
    #>
    if (-not (Test-NetDnsReady)) { return $false }
    $alt = Select-NetDnsRecord -Titel 'Welchen Eintrag aendern?'
    if (-not $alt) { return $false }
    if ($script:NetDnsTypen -notcontains $alt.Typ) { Write-Log -Level Warn -Message 'Dieser Eintragstyp wird von Windows verwaltet und hier nicht geaendert.'; return $false }
    $neu = Read-NetDnsRecordData -Typ $alt.Typ -Vorschlag $alt.Daten
    if (-not $neu) { return $false }
    if (Test-NetDnsRecordEqual -A $neu -B $alt.Daten) { Write-Log -Level OK -Message 'Keine Aenderung.'; return $true }
    $zoneName = $alt.Zone
    $eintragName = $alt.Name
    $eintragTyp = $alt.Typ
    $altDaten = $alt.Daten
    $neuDaten = $neu
    $r = Invoke-NetChange -Titel ('DNS-Eintrag {0} ({1}) in {2} aendern' -f $eintragName, $eintragTyp, $zoneName) -Stufe Bestaetigen -Vorher $altDaten -Nachher $neuDaten -BackupBereich @('Dns') -Aktion {
        Add-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $neuDaten
        Remove-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $altDaten
    } -Rueckgaengig @(
        @{ Befehl = 'Add-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $altDaten } },
        @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $neuDaten } }
    )
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
