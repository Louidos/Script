# DHCP traegt automatisch in DNS ein: jeder Client bekommt A- und PTR-Eintrag,
# abgelaufene Leases entfernen ihre Eintraege wieder. Mit Pruefung aller aktiven Leases.

$script:NetIntegrationHilfe = @'
Damit jeder DHCP-Client automatisch im DNS steht:
  - DHCP-Server: "immer aktualisieren" (Always), auch fuer aeltere Clients, und Eintraege beim
    Ablauf der Lease loeschen. Das gilt fuer den Server und jeden Scope.
  - DNS-Zonen: dynamische Updates an (auf DCs: nur sicher), Reverse-Zone fuer jeden Scope.
  - Zugangsdaten: der DHCP-Server traegt mit einem eigenen Dienstkonto ein (Vorschlag svc-dhcpdns).
    Laeuft DHCP auf einem DC ohne Dienstkonto, gehoeren die Eintraege dem DC-Computerkonto - das
    ist ein Sicherheitsrisiko und macht Probleme, wenn Eintraege spaeter aktualisiert werden.
  - Aufraeumen: No-Refresh + Refresh mindestens so lang wie die Lease-Dauer.
'@

function Get-NetDhcpDnsSettingInfo {
    param([string]$ScopeId)
    $e = $null
    if ($ScopeId) { $e = Get-NetSafe -Beschreibung "DNS-Einstellung $ScopeId" -Abfrage { Get-DhcpServerv4DnsSetting -ScopeId $ScopeId } }
    else { $e = Get-NetSafe -Beschreibung 'DNS-Einstellung Server' -Abfrage { Get-DhcpServerv4DnsSetting } }
    return (ConvertTo-NetDhcpDnsSetting -Einstellung $e)
}

function Test-NetDhcpDnsSettingOk {
    param([hashtable]$Einstellung)
    if (-not $Einstellung) { return $false }
    return (($Einstellung.DynamicUpdates -eq 'Always') -and $Einstellung.DeleteDnsRROnLeaseExpiry -and $Einstellung.UpdateDnsRRForOlderClients -and -not $Einstellung.DisableDnsPtrRRUpdate)
}

function Set-NetDhcpDnsSetting {
    <#
    .SYNOPSIS
        Setzt die DNS-Einstellungen des DHCP-Servers server- und scopeweit.
    #>
    param([Nullable[bool]]$Namensschutz = $null)
    if (-not (Test-NetDhcpReady)) { return $false }
    if ($null -eq $Namensschutz) {
        Write-NetText -Text 'Namensschutz verhindert, dass ein Geraet den DNS-Namen eines anderen uebernimmt. Nachteil: Geraete, die vorher selbst eingetragen waren, muessen ihre alten Eintraege erst verlieren. Fuer neue Netze empfohlen.'
        $Namensschutz = Read-NetYesNo -Frage 'Namensschutz einschalten?' -Vorschlag $false
    }
    $ziele = @(@{ ScopeId = ''; Name = 'Server' })
    foreach ($s in @(Get-NetDhcpScopeList)) { $ziele += @{ ScopeId = $s.ScopeId; Name = ('Scope ' + $s.ScopeId) } }
    $alleOk = $true
    foreach ($ziel in $ziele) {
        $alt = Get-NetDhcpDnsSettingInfo -ScopeId $ziel.ScopeId
        $soll = @{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = [bool]$Namensschutz; DisableDnsPtrRRUpdate = $false }
        if ($alt -and (Test-NetDhcpDnsSettingOk -Einstellung $alt) -and ([bool]$alt.NameProtection -eq [bool]$Namensschutz)) {
            Write-Log -Level OK -Message ('{0}: DNS-Einstellungen passen bereits.' -f $ziel.Name)
            continue
        }
        $p = @{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = [bool]$Namensschutz; DisableDnsPtrRRUpdate = $false }
        $rp = @{}
        if ($alt) { $rp = @{ DynamicUpdates = $alt.DynamicUpdates; DeleteDnsRROnLeaseExpiry = [bool]$alt.DeleteDnsRROnLeaseExpiry; UpdateDnsRRForOlderClients = [bool]$alt.UpdateDnsRRForOlderClients; NameProtection = [bool]$alt.NameProtection; DisableDnsPtrRRUpdate = [bool]$alt.DisableDnsPtrRRUpdate } }
        if ($ziel.ScopeId) { $p.ScopeId = $ziel.ScopeId; $rp.ScopeId = $ziel.ScopeId }
        $rueck = $null
        if ($alt) { $rueck = @{ Befehl = 'Set-DhcpServerv4DnsSetting'; Parameter = $rp } }
        $r = Invoke-NetChange -Titel ('DHCP-DNS-Einstellungen ({0})' -f $ziel.Name) -Stufe Bestaetigen -Vorher $alt -Nachher $soll -BackupBereich @('Dhcp') -Aktion {
            Set-DhcpServerv4DnsSetting @p
        } -Rueckgaengig $rueck
        if (-not $r.Erfolg -or $r.Probelauf) { $alleOk = $false }
    }
    return $alleOk
}

function Test-NetDhcpDnsZoneReady {
    <#
    .SYNOPSIS
        Prueft die Zonen fuer die DHCP-Eintraege (dynamische Updates) und bietet die Korrektur an.
    #>
    param([switch]$NurPruefen)
    $z = Get-NetSetupState
    $domaenen = @()
    foreach ($s in @($z.Dhcp.Scopes)) { if ($s.Optionen.ContainsKey('15')) { $domaenen += $s.Optionen['15'] } }
    if ($z.Dhcp.ServerOptionen.ContainsKey('15')) { $domaenen += $z.Dhcp.ServerOptionen['15'] }
    $ad = Get-NetDomainName -Zustand $z
    if ($ad) { $domaenen += $ad }
    $domaenen = @($domaenen | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower().TrimEnd('.') } | Select-Object -Unique)
    $ok = $true
    foreach ($d in $domaenen) {
        $zone = @($z.Dns.Zonen | Where-Object { $_.Name -eq $d }) | Select-Object -First 1
        if (-not $zone) {
            Write-Log -Level Warn -Message "Die Zone $d (Domaene der Clients) gibt es auf diesem DNS-Server nicht."
            $ok = $false
            if (-not $NurPruefen -and (Test-NetCommand -Name 'New-NetDnsZone') -and (Read-NetYesNo -Frage "Zone $d anlegen?" -Vorschlag $true)) { New-NetDnsZone -Name $d | Out-Null }
            continue
        }
        $soll = 'NonsecureAndSecure'
        if ($zone.AdIntegriert) { $soll = 'Secure' }
        if ($zone.DynUpdate -eq $soll -or ($zone.AdIntegriert -and $zone.DynUpdate -eq 'NonsecureAndSecure')) {
            if ($zone.AdIntegriert -and $zone.DynUpdate -ne 'Secure') { Write-Log -Level Warn -Message "Zone ${d}: unsichere Updates erlaubt. Empfohlen: nur sicher." }
            else { Write-Log -Level OK -Message ("Zone {0}: dynamische Updates {1}." -f $d, (ConvertTo-NetDnsUpdateText -Wert $zone.DynUpdate)) }
            continue
        }
        Write-Log -Level Warn -Message ("Zone {0}: dynamische Updates sind aus - DHCP kann keine Clients eintragen." -f $d)
        $ok = $false
        if (-not $NurPruefen) { Set-NetDnsZoneUpdate -Zone $d -Wert $soll | Out-Null }
    }
    $fehlend = @(Get-NetMissingReverseZone -Zustand $z | Where-Object { $_.Quelle -like 'DHCP-Scope*' })
    if ($fehlend.Count -gt 0) {
        $ok = $false
        Write-Log -Level Warn -Message ('Fuer diese Scopes fehlt die Reverse-Zone: ' + (($fehlend | ForEach-Object { $_.Netz }) -join ', '))
        if (-not $NurPruefen) {
            foreach ($f in $fehlend) {
                if (Read-NetYesNo -Frage ('Reverse-Zone {0} anlegen?' -f $f.Zone) -Vorschlag $true) { New-NetDnsZone -Name $f.Zone -Netz $f.Netz | Out-Null }
            }
        }
    }
    return $ok
}

function New-NetDhcpDnsCredential {
    <#
    .SYNOPSIS
        Legt (nach Bestaetigung) das Dienstkonto an und setzt es als DNS-Zugangsdaten des DHCP-Servers.
        Das Kennwort wird nur als SecureString verarbeitet und nie gespeichert.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    $z = Get-NetSetupState
    if (-not ($z.System.IstDC -or $z.System.IstMitglied)) {
        Write-Log -Message 'Ohne Domaene gibt es kein Dienstkonto. Bei dateibasierten Zonen traegt DHCP ohne Zugangsdaten ein.'
        return $true
    }
    if (-not (Test-NetCommand -Name 'Get-ADUser')) {
        Write-Log -Level Fehler -Message 'Das AD-PowerShell-Modul fehlt (RSAT-AD-PowerShell). Ohne es kann kein Dienstkonto angelegt werden.'
        return $false
    }
    Write-NetText -Text $script:NetIntegrationHilfe
    $kontoName = Read-NetText -Frage 'Name des Dienstkontos' -Vorschlag ([string](Get-NetConfigValue -Pfad 'Vorschlaege.DnsDienstkonto' -Standard 'svc-dhcpdns')) -Pruefung { param($t) if ($t -match '^[A-Za-z0-9._-]{1,20}$') { $null } else { '1 bis 20 Zeichen: Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.' } }
    if (-not $kontoName) { return $false }
    $vorhanden = Get-NetSafe -Beschreibung "Konto $kontoName" -Abfrage { Get-ADUser -Identity $kontoName -Properties PasswordNeverExpires, Enabled }
    $netbios = [string]$z.AD.NetBios
    if (-not $netbios) { $netbios = ([string](Get-NetDomainName -Zustand $z)).Split('.')[0].ToUpper() }
    if ($vorhanden) {
        Write-Log -Level OK -Message "Das Konto $kontoName gibt es bereits. Bitte sein Kennwort eingeben (es wird nicht gespeichert)."
        $kennwort = Read-NetSecret -Frage "Kennwort von $kontoName"
        if (-not $kennwort) { return $false }
    }
    else {
        Write-NetText -Text "Das Konto wird als normales Benutzerkonto ohne besondere Rechte angelegt. Ein Administrator vergibt das Kennwort.`nLaeuft das Kennwort ab, schlagen die DNS-Eintraege fehl - dann hier ein neues Kennwort setzen." -Farbe Yellow
        $kennwort = Read-NetSecret -Frage "Kennwort fuer das neue Konto $kontoName" -Bestaetigen -Komplex -MinLaenge 14
        if (-not $kennwort) { return $false }
        $nieAblaufen = Read-NetYesNo -Frage 'Kennwort laeuft nie ab? (sonst muss es hier regelmaessig erneuert werden)' -Vorschlag $true
        $r = Invoke-NetChange -Titel "Dienstkonto $kontoName im AD anlegen" -Stufe Bestaetigen -Vorher '(kein Konto)' -Nachher @{ Konto = "$netbios\$kontoName"; Rechte = 'normaler Benutzer'; 'Kennwort laeuft ab' = $(if ($nieAblaufen) { 'nie' } else { 'nach Domaenenrichtlinie' }) } -Aktion {
            New-ADUser -Name $kontoName -SamAccountName $kontoName -AccountPassword $kennwort -Enabled $true -PasswordNeverExpires $nieAblaufen -CannotChangePassword $true -Description 'DNS-Eintraege des DHCP-Servers (angelegt von NetSetup)'
        } -Rueckgaengig @{ Befehl = 'Remove-ADUser'; Parameter = @{ Identity = $kontoName; Confirm = $false } }
        if (-not $r.Erfolg -or $r.Probelauf) { return $false }
    }
    $cred = New-Object System.Management.Automation.PSCredential(("{0}\{1}" -f $netbios, $kontoName), $kennwort)
    $alt = $z.Dhcp.DnsZugangsdaten
    $r2 = Invoke-NetChange -Titel 'DNS-Zugangsdaten des DHCP-Servers setzen' -Stufe Bestaetigen -Vorher $(if ($alt.Gesetzt) { '{0}\{1}' -f $alt.Domaene, $alt.Benutzer } else { '(keine - Computerkonto)' }) -Nachher ("{0}\{1}" -f $netbios, $kontoName) -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerDnsCredential -Credential $cred
    }
    return [bool]($r2.Erfolg -and -not $r2.Probelauf)
}

function Test-NetAgingVsLease {
    param([switch]$NurPruefen)
    $z = Get-NetSetupState
    $lease = Get-NetMaxLeaseDuration -Zustand $z
    if ($lease -le 0) { return $true }
    $sc = $z.Dns.Scavenging
    if (-not $sc -or -not $sc.Aktiv) {
        Write-Log -Level Warn -Message 'Das Aufraeumen alter DNS-Eintraege ist aus: Eintraege von Geraeten, die nicht mehr da sind, bleiben liegen.'
        if (-not $NurPruefen -and (Test-NetCommand -Name 'Set-NetDnsScavenging') -and (Read-NetYesNo -Frage 'Aufraeumen mit 7 + 7 Tagen einschalten?' -Vorschlag $true)) { Set-NetDnsScavenging -Aktiv $true | Out-Null }
        return $false
    }
    $summe = (ConvertTo-NetTimeSpan $sc.NoRefresh).TotalDays + (ConvertTo-NetTimeSpan $sc.Refresh).TotalDays
    if ($summe -lt $lease) {
        Write-Log -Level Warn -Message ('No-Refresh + Refresh ({0} Tage) ist kuerzer als die Lease-Dauer ({1} Tage): Eintraege aktiver Clients koennten geloescht werden.' -f $summe, $lease)
        if (-not $NurPruefen -and (Read-NetYesNo -Frage 'Aufraeumen passend einstellen?' -Vorschlag $true)) {
            $tage = [int][Math]::Ceiling($lease / 2)
            Set-NetDnsScavenging -Aktiv $true -NoRefreshTage ([Math]::Max(7, $tage)) -RefreshTage ([Math]::Max(7, $tage)) | Out-Null
        }
        return $false
    }
    Write-Log -Level OK -Message ('Aufraeumen passt zur Lease-Dauer ({0} >= {1} Tage).' -f $summe, $lease)
    return $true
}

function Get-NetLeaseDnsCheck {
    <#
    .SYNOPSIS
        Gleicht alle aktiven Leases mit A- und PTR-Eintraegen ab und nennt die wahrscheinliche Ursache.
    .OUTPUTS
        Liste von Objekten: IP, Name, Zone, A, PTR, Ursache.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    $ergebnis = @()
    $zonenNamen = @($Zustand.Dns.Zonen | ForEach-Object { $_.Name })
    $reverseNamen = @($Zustand.Dns.Zonen | Where-Object { $_.Reverse } | ForEach-Object { $_.Name })
    $adDomaene = Get-NetDomainName -Zustand $Zustand
    $ohneZugang = $Zustand.System.IstDC -and -not $Zustand.Dhcp.DnsZugangsdaten.Gesetzt
    foreach ($scope in @($Zustand.Dhcp.Scopes)) {
        $id = $scope.ScopeId
        $leases = @(Get-NetSafe -Beschreibung "Leases $id" -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id })
        $domaene = $adDomaene
        if ($scope.Optionen.ContainsKey('15')) { $domaene = [string]$scope.Optionen['15'][0] }
        elseif ($Zustand.Dhcp.ServerOptionen.ContainsKey('15')) { $domaene = [string]$Zustand.Dhcp.ServerOptionen['15'][0] }
        $einst = $scope.DnsEinstellung
        if (-not $einst) { $einst = $Zustand.Dhcp.DnsEinstellung }
        foreach ($l in $leases) {
            if ($null -eq $l -or ([string]$l.AddressState) -notlike 'Active*') { continue }
            $ip = ConvertTo-NetString $l.IPAddress
            $hostName = ([string]$l.HostName).TrimEnd('.')
            $zone = $domaene
            $label = $hostName
            if ($hostName -match '^([^.]+)\.(.+)$') { $label = $Matches[1]; $zone = $Matches[2].ToLower() }
            $zeile = [pscustomobject]@{ IP = $ip; Name = $hostName; Label = $label; Zone = $zone; ReverseZone = ''; A = $false; PTR = $false; Ursache = '' }
            $ursachen = @()
            if (-not $hostName) {
                $zeile.Ursache = 'Der Client hat keinen Namen gemeldet (z. B. Drucker oder IoT-Geraet).'
                $ergebnis += $zeile
                continue
            }
            if (-not $zone -or $zonenNamen -notcontains $zone) { $ursachen += "Zone '$zone' gibt es auf diesem DNS-Server nicht." }
            else {
                $zi = @($Zustand.Dns.Zonen | Where-Object { $_.Name -eq $zone }) | Select-Object -First 1
                $a = @(Get-NetSafe -Beschreibung "A $hostName" -Standard @() -Abfrage { Get-DnsServerResourceRecord -ZoneName $zone -Name $label -RRType A })
                $ips = @($a | Where-Object { $_ } | ForEach-Object { ConvertTo-NetString $_.RecordData.IPv4Address })
                $zeile.A = ($ips -contains $ip)
                if (-not $zeile.A) {
                    if ($ips.Count -gt 0) { $ursachen += ('Der Name zeigt auf {0} (veralteter Eintrag oder Namensschutz).' -f ($ips -join ', ')) }
                    elseif ($zi -and $zi.DynUpdate -eq 'None') { $ursachen += "Dynamische Updates in Zone $zone sind aus." }
                }
            }
            $rz = Find-NetReverseZone -IPAddress $ip -ZoneNames $reverseNamen
            if (-not $rz) { $ursachen += 'Reverse-Zone fuer dieses Netz fehlt.' }
            else {
                $zeile.ReverseZone = $rz
                $ptrName = Get-NetPtrName -IPAddress $ip -ZoneName $rz
                $ptr = @(Get-NetSafe -Beschreibung "PTR $ip" -Standard @() -Abfrage { Get-DnsServerResourceRecord -ZoneName $rz -Name $ptrName -RRType PTR })
                $zeile.PTR = (@($ptr | Where-Object { $_ }).Count -gt 0)
            }
            if (-not ($zeile.A -and $zeile.PTR)) {
                if ($einst -and $einst.DynamicUpdates -ne 'Always') { $ursachen += ('DHCP traegt nur auf Wunsch des Clients ein ({0}).' -f $einst.DynamicUpdates) }
                if ($einst -and $einst.DisableDnsPtrRRUpdate -and -not $zeile.PTR) { $ursachen += 'PTR-Aktualisierung ist im DHCP abgeschaltet.' }
                if ($ohneZugang) { $ursachen += 'DHCP auf DC ohne DNS-Zugangsdaten.' }
                if ($ursachen.Count -eq 0) { $ursachen += 'Unklar - evtl. wurde die Lease gerade erst vergeben oder die AD-Replikation steht noch aus.' }
                $zeile.Ursache = ($ursachen -join ' ')
            }
            $ergebnis += $zeile
        }
    }
    return $ergebnis
}

function Show-NetLeaseDnsCheck {
    <#
    .SYNOPSIS
        Prueft alle aktiven Leases auf A- und PTR-Eintrag, zeigt fehlende mit Ursache und bietet das Nachtragen an.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    if (-not (Test-NetDnsReady -Still)) { Write-Log -Level Warn -Message 'Der DNS-Server laeuft nicht auf diesem Server. Die Pruefung braucht DNS lokal.'; return }
    $liste = @(Get-NetLeaseDnsCheck)
    $fehlend = @($liste | Where-Object { -not ($_.A -and $_.PTR) })
    Write-NetTitle -Titel ('Leases und DNS: {0} aktiv, {1} ohne vollstaendigen Eintrag' -f $liste.Count, $fehlend.Count)
    foreach ($f in $fehlend) {
        Write-Host ('  {0,-15} {1,-30} A:{2,-4} PTR:{3,-4} {4}' -f $f.IP, $f.Name, $(if ($f.A) { 'ok' } else { 'fehlt' }), $(if ($f.PTR) { 'ok' } else { 'fehlt' }), $f.Ursache) -ForegroundColor Yellow
    }
    if ($fehlend.Count -eq 0) { Write-Log -Level OK -Message 'Alle aktiven Leases haben einen A- und einen PTR-Eintrag.'; return $liste }
    $nachtragbar = @($fehlend | Where-Object { $_.Name -and $_.Zone -and ((-not $_.A) -or ((-not $_.PTR) -and $_.ReverseZone)) })
    if ($nachtragbar.Count -eq 0) { return $liste }
    if (-not (Read-NetYesNo -Frage ('{0} fehlende Eintraege jetzt nachtragen?' -f $nachtragbar.Count) -Vorschlag $false)) { return $liste }
    $wahl = @(Select-NetItem -Elemente $nachtragbar -Titel 'Welche nachtragen?' -Eigenschaften @('IP', 'Name', 'A', 'PTR') -Mehrfach)
    if ($wahl.Count -eq 0) { return $liste }
    $schritte = @()
    $rueck = @()
    foreach ($w in $wahl) {
        if (-not $w.A) {
            $schritte += @{ ZoneName = $w.Zone; Name = $w.Label; Typ = 'A'; Daten = @{ IPv4Address = $w.IP } }
            $rueck += @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $w.Zone; Name = $w.Label; Typ = 'A'; Daten = @{ IPv4Address = $w.IP } } }
        }
        if (-not $w.PTR -and $w.ReverseZone) {
            $ptrDaten = @{ PtrDomainName = ('{0}.{1}.' -f $w.Label, $w.Zone) }
            $ptrName = Get-NetPtrName -IPAddress $w.IP -ZoneName $w.ReverseZone
            $schritte += @{ ZoneName = $w.ReverseZone; Name = $ptrName; Typ = 'PTR'; Daten = $ptrDaten }
            $rueck += @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $w.ReverseZone; Name = $ptrName; Typ = 'PTR'; Daten = $ptrDaten } }
        }
    }
    $anzeige = @($schritte | ForEach-Object { '{0} {1} in {2}: {3}' -f $_.Name, $_.Typ, $_.ZoneName, (@($_.Daten.Values) -join '') })
    Invoke-NetChange -Titel ('{0} fehlende DNS-Eintraege nachtragen' -f $schritte.Count) -Stufe Bestaetigen -Vorher '(fehlen)' -Nachher $anzeige -BackupBereich @('Dns') `
        -Hinweis 'Von Hand nachgetragene Eintraege sind statisch und werden nicht automatisch aufgeraeumt. Besser die Ursache beheben (Assistent), dann traegt DHCP beim naechsten Erneuern selbst ein.' -Aktion {
        foreach ($s in $schritte) { Add-NetDnsRecordExact -ZoneName $s.ZoneName -Name $s.Name -Typ $s.Typ -Daten $s.Daten }
    } -Rueckgaengig $rueck | Out-Null
    return $liste
}

function Show-NetIntegrationStatus {
    <#
    .SYNOPSIS
        Zeigt den Stand der DHCP-DNS-Verbindung; warnt deutlich bei DHCP auf DC ohne Zugangsdaten.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'DHCP + DNS: Stand'
    if (-not $z.Dhcp.Verfuegbar) { Write-NetStatus -Status NA -Bereich 'DHCP' -Text 'kein DHCP-Server auf diesem Server'; return }
    if (Test-NetDhcpDnsSettingOk -Einstellung $z.Dhcp.DnsEinstellung) { Write-NetStatus -Status OK -Bereich 'Server-Einstellung' -Text 'immer eintragen, alte Eintraege loeschen, auch fuer aeltere Clients' }
    else { Write-NetStatus -Status WARN -Bereich 'Server-Einstellung' -Text 'nicht vollstaendig (Assistent ausfuehren)' }
    foreach ($s in @($z.Dhcp.Scopes)) {
        if (Test-NetDhcpDnsSettingOk -Einstellung $s.DnsEinstellung) { Write-NetStatus -Status OK -Bereich ('Scope ' + $s.ScopeId) -Text 'DNS-Einstellung passt' }
        else { Write-NetStatus -Status WARN -Bereich ('Scope ' + $s.ScopeId) -Text 'DNS-Einstellung unvollstaendig' }
    }
    if ($z.Dhcp.DnsZugangsdaten.Gesetzt) { Write-NetStatus -Status OK -Bereich 'Zugangsdaten' -Text ('{0}\{1}' -f $z.Dhcp.DnsZugangsdaten.Domaene, $z.Dhcp.DnsZugangsdaten.Benutzer) }
    elseif ($z.System.IstDC) {
        Write-NetStatus -Status FEHLER -Bereich 'Zugangsdaten' -Text 'DHCP LAEUFT AUF EINEM DC OHNE DNS-ZUGANGSDATEN!'
        Write-NetText -Text "Ohne eigenes Dienstkonto traegt der DHCP-Server mit dem Computerkonto des DCs ein. Die Eintraege gehoeren dann dem DC,`nund ueber die Gruppe DnsUpdateProxy liesse sich das ausnutzen. Abhilfe: 'Dienstkonto einrichten' im Menue DHCP + DNS." -Farbe Red
    }
    elseif ($z.System.IstMitglied) { Write-NetStatus -Status WARN -Bereich 'Zugangsdaten' -Text 'keine - empfohlen ist ein eigenes Dienstkonto' }
    else { Write-NetStatus -Status NA -Bereich 'Zugangsdaten' -Text 'ohne Domaene nicht noetig' }
    Test-NetDhcpDnsZoneReady -NurPruefen | Out-Null
    Test-NetAgingVsLease -NurPruefen | Out-Null
}

function Start-NetIntegrationSetup {
    <#
    .SYNOPSIS
        Assistent: DHCP mit DNS verbinden. Danach erscheint der Bereich beim Start als [OK].
    #>
    Write-NetTitle -Titel 'DHCP + DNS verbinden'
    Write-NetText -Text $script:NetIntegrationHilfe
    if (-not (Test-NetDhcpReady)) { return }
    Set-NetDhcpDnsSetting | Out-Null
    if (Test-NetDnsReady -Still) { Test-NetDhcpDnsZoneReady | Out-Null }
    else { Write-Log -Level Warn -Message 'DNS laeuft nicht auf diesem Server: Zonen bitte auf dem DNS-Server pruefen.' }
    $z = Get-NetSetupState
    if (($z.System.IstDC -or $z.System.IstMitglied) -and -not $z.Dhcp.DnsZugangsdaten.Gesetzt) {
        if ($z.System.IstDC) { Write-Log -Level Warn -Message 'DHCP laeuft auf einem DC ohne DNS-Zugangsdaten. Ein Dienstkonto wird dringend empfohlen.' }
        if (Read-NetYesNo -Frage 'Dienstkonto fuer die DNS-Eintraege einrichten?' -Vorschlag $true) { New-NetDhcpDnsCredential | Out-Null }
    }
    if (Test-NetDnsReady -Still) { Test-NetAgingVsLease | Out-Null }
    $script:NS.Zusammenfassung = Get-NetStateSummary -Zustand (Get-NetSetupState)
    $zeile = @($script:NS.Zusammenfassung | Where-Object { $_.Bereich -eq 'DHCP + DNS' }) | Select-Object -First 1
    if ($zeile) { Write-NetStatus -Status $zeile.Status -Bereich $zeile.Bereich -Text $zeile.Text }
}

function Show-NetIntegrationMenu {
    $eintraege = @(
        @{ Text = 'Stand anzeigen'; Aktion = 'Show-NetIntegrationStatus'; Hilfe = 'Zeigt DHCP-DNS-Einstellungen (Server und Scopes), Zugangsdaten, Zonen und Aufraeumen. Warnt deutlich, wenn DHCP auf einem DC ohne Zugangsdaten laeuft.' },
        @{ Text = 'Assistent: DHCP mit DNS verbinden'; Aktion = 'Start-NetIntegrationSetup'; Hilfe = $script:NetIntegrationHilfe },
        @{ Text = 'DHCP-DNS-Einstellungen setzen'; Aktion = { Set-NetDhcpDnsSetting | Out-Null }; Hilfe = 'Immer eintragen (Always), alte Eintraege beim Lease-Ablauf loeschen, auch fuer aeltere Clients; Namensschutz waehlbar. Server und alle Scopes.' },
        @{ Text = 'Dienstkonto einrichten (svc-dhcpdns)'; Aktion = { New-NetDhcpDnsCredential | Out-Null }; Hilfe = 'Legt nach Bestaetigung ein eigenes AD-Konto an (oder nutzt ein vorhandenes) und setzt es als DNS-Zugangsdaten des DHCP-Servers. Das Kennwort wird nicht gespeichert.' },
        @{ Text = 'Pruefen: Leases ohne DNS-Eintrag'; Aktion = { Show-NetLeaseDnsCheck | Out-Null }; Hilfe = 'Gleicht alle aktiven Leases mit A- und PTR-Eintraegen ab, nennt die wahrscheinliche Ursache und bietet das Nachtragen an.' }
    )
    Show-NetMenu -Titel 'DHCP + DNS verbinden' -Eintraege $eintraege -Einleitung $script:NetIntegrationHilfe
}
