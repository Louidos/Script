# Erweiterte Funktionen: DNSSEC, Split-Brain-DNS, DHCP-Richtlinien, DNS-Sperrliste, DHCPv6.
# Alles ist standardmaessig aus: erst nach dem Freischalten (pro Sitzung) nutzbar, jede Aenderung
# braucht eine Bestaetigung, Richtlinien und DHCPv6-Scopes werden ausgeschaltet angelegt und
# muessen aktiv eingeschaltet werden. Fuer jede Funktion gibt es eine Ruecknahme.

$script:NetErweitertWarnung = @'
ACHTUNG: Die Funktionen unter "Erweitert" sind fuer Fachleute gedacht.
  - Sie werden selten gebraucht und koennen bei falscher Anwendung die Namensaufloesung oder die
    Adressvergabe im ganzen Netz stoeren.
  - Nichts davon ist eingeschaltet, solange es hier nicht ausdruecklich angelegt UND aktiviert wird.
  - Jede Aenderung zeigt Vorher/Nachher, wird gesichert und laesst sich zuruecknehmen.
'@

$script:NetHilfeDnssec = @'
DNSSEC signiert eine Zone digital. DNS-Server, die DNSSEC pruefen, erkennen gefaelschte Antworten.
Folgen:
  - Die Zone wird deutlich groesser (Signaturen), Schluessel muessen gepflegt werden.
  - Clients pruefen nur, wenn per Gruppenrichtlinie (NRPT) eingestellt - sonst bringt es intern wenig.
  - Fehler bei Schluesseln oder Uhrzeit machen die Zone fuer pruefende Resolver unaufloesbar.
  - Die Signatur laesst sich wieder entfernen (Unsign).
'@

$script:NetHilfeSplitBrain = @'
Split-Brain: Ein Name liefert intern eine andere Adresse als extern (z. B. mail.firma.ch intern
192.168.1.20, extern die oeffentliche Adresse). Umsetzung mit einem Client-Subnetz, einem
Zonen-Scope mit den internen Eintraegen und einer Abfrage-Richtlinie.
Wichtig: Zonen-Scopes funktionieren nur bei dateibasierten Zonen, nicht bei AD-integrierten.
'@

$script:NetHilfeDhcpRichtlinie = @'
DHCP-Richtlinien geben bestimmten Geraeten andere Optionen (oder Bereiche), z. B. alle Geraete mit
MAC-Praefix 00-15-5D (Hyper-V) oder einer bestimmten Herstellerklasse (VoIP-Telefone) bekommen
einen anderen DNS-Server oder Router. Die Richtlinie wird ausgeschaltet angelegt und erst nach
Bestaetigung aktiviert.
'@

$script:NetHilfeSperrliste = @'
DNS-Sperrliste: Anfragen fuer bestimmte Domaenen (z. B. bekannte Werbe- oder Schadseiten) werden
vom DNS-Server ignoriert. Umgesetzt mit Abfrage-Richtlinien (Aktion IGNORE) auf Serverebene.
Die globale Sperrliste von Windows (Standard: wpad, isatap) gilt nur fuer Namen in eigenen Zonen.
'@

$script:NetHilfeDhcpv6 = @'
DHCPv6 vergibt IPv6-Adressen. In den meisten Netzen nicht noetig: IPv6 konfiguriert sich ueber
Router-Ankuendigungen (SLAAC). DHCPv6 braucht man, wenn der Router "Managed" (M-Flag) ankuendigt
oder Adressen zentral vergeben werden sollen. Der Scope wird inaktiv angelegt.
'@

function Assert-NetAdvancedMode {
    <#
    .SYNOPSIS
        Erweiterte Funktionen erst nach ausdruecklichem Freischalten (pro Sitzung) nutzen.
    #>
    if ($script:NS.ErweitertFrei) { return $true }
    Write-NetText -Text $script:NetErweitertWarnung -Farbe Yellow
    if (Read-NetYesNo -Frage 'Erweiterte Funktionen fuer diese Sitzung freischalten?' -Vorschlag $false) {
        $script:NS.ErweitertFrei = $true
        Write-Log -Message 'Erweiterte Funktionen fuer diese Sitzung freigeschaltet.'
        return $true
    }
    return $false
}

function Set-NetAdvancedFlag {
    param([Parameter(Mandatory = $true)][string]$Name, [bool]$Wert)
    if ($script:NS.Config -and $script:NS.Config.Erweitert) {
        $script:NS.Config.Erweitert[$Name] = $Wert
        Save-NetConfig
    }
}

# ---------------------------------------------------------------- DNSSEC

function Invoke-NetDnssecSign {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text $script:NetHilfeDnssec
    $z = Select-NetDnsZone -Art Forward -Titel 'Welche Zone signieren?'
    if (-not $z) { return $false }
    $name = $z.Name
    $info = Get-NetSafe -Beschreibung "Zone $name" -Abfrage { Get-DnsServerZone -Name $name }
    if ($info -and $info.IsSigned) { Write-Log -Level OK -Message "Die Zone $name ist bereits signiert."; return $true }
    $r = Invoke-NetChange -Titel "Zone $name mit DNSSEC signieren" -Stufe Gefaehrlich -Vorher 'unsigniert' -Nachher 'signiert (Standardschluessel, automatische Schluesselpflege)' -BackupBereich @('Dns') `
        -Hinweis 'Pruefende Resolver lehnen die Zone ab, wenn Schluessel oder Uhrzeit nicht stimmen.' -Aktion {
        Invoke-DnsServerZoneSign -ZoneName $name -SignWithDefault -Force
    } -Rueckgaengig @{ Befehl = 'Invoke-DnsServerZoneUnsign'; Parameter = @{ ZoneName = $name; Force = $true } }
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Dnssec' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Invoke-NetDnssecUnsign {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    $signiert = @(Get-NetSafe -Beschreibung 'Zonen' -Standard @() -Abfrage { Get-DnsServerZone } | Where-Object { $_ -and $_.IsSigned } | ForEach-Object { [string]$_.ZoneName })
    if ($signiert.Count -eq 0) { Write-Log -Message 'Keine Zone ist signiert.'; return $true }
    $name = Select-NetItem -Elemente $signiert -Titel 'Signatur welcher Zone entfernen?'
    if (-not $name) { return $false }
    $r = Invoke-NetChange -Titel "DNSSEC-Signatur der Zone $name entfernen" -Stufe Gefaehrlich -Vorher 'signiert' -Nachher 'unsigniert' -BackupBereich @('Dns') -Aktion {
        Invoke-DnsServerZoneUnsign -ZoneName $name -Force
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

# ---------------------------------------------------------------- Split-Brain

function New-NetSplitBrain {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text $script:NetHilfeSplitBrain
    $z = Select-NetDnsZone -Art Forward -Titel 'Fuer welche Zone?'
    if (-not $z) { return $false }
    if ($z.AdIntegriert) {
        Write-Log -Level Fehler -Message ('Die Zone {0} ist AD-integriert. Zonen-Scopes gehen nur bei dateibasierten Zonen.' -f $z.Name)
        Write-Log -Message 'Naechster Schritt: fuer die externe Domaene eine eigene dateibasierte Zone verwenden.'
        return $false
    }
    $netz = Read-NetSubnet -Frage 'Internes Netz, das die internen Antworten bekommt (z. B. 192.168.0.0/16)'
    if (-not $netz) { return $false }
    $eintrag = Read-NetText -Frage 'Name des Eintrags (z. B. mail)' -Pruefung { param($t) Test-NetDnsRecordName -Name $t }
    if (-not $eintrag) { return $false }
    $ip = Read-NetIPAddress -Frage 'Interne IP-Adresse fuer diesen Namen'
    if (-not $ip) { return $false }
    $aktiv = Read-NetYesNo -Frage 'Richtlinie sofort aktivieren? (Nein = ausgeschaltet anlegen)' -Vorschlag $false
    $zone = $z.Name
    $subnetz = 'NetSetup-Intern'
    $scope = 'intern'
    $richtlinie = 'NetSetup-SplitBrain-' + ($zone -replace '[^A-Za-z0-9]', '-')
    $netzText = $netz.Text
    $r = Invoke-NetChange -Titel "Split-Brain fuer $eintrag.$zone einrichten" -Stufe Bestaetigen -Vorher ("{0}.{1}: eine Antwort fuer alle" -f $eintrag, $zone) `
        -Nachher @{ 'Client-Subnetz' = "$subnetz = $netzText"; 'Zonen-Scope' = $scope; 'Interner Eintrag' = "$eintrag -> $ip"; Richtlinie = $richtlinie; Aktiv = $(if ($aktiv) { 'ja' } else { 'nein (ausgeschaltet)' }) } -BackupBereich @('Dns') -Aktion {
        if (-not (Get-DnsServerClientSubnet -Name $subnetz -ErrorAction SilentlyContinue)) { Add-DnsServerClientSubnet -Name $subnetz -IPv4Subnet $netzText }
        if (-not (@(Get-DnsServerZoneScope -ZoneName $zone -ErrorAction SilentlyContinue) | Where-Object { $_.ZoneScope -eq $scope })) { Add-DnsServerZoneScope -ZoneName $zone -Name $scope }
        Add-DnsServerResourceRecordA -ZoneName $zone -ZoneScope $scope -Name $eintrag -IPv4Address $ip
        if ($aktiv) { Add-DnsServerQueryResolutionPolicy -Name $richtlinie -Action ALLOW -ClientSubnet ('eq,' + $subnetz) -ZoneScope ($scope + ',1') -ZoneName $zone }
        else { Add-DnsServerQueryResolutionPolicy -Name $richtlinie -Action ALLOW -ClientSubnet ('eq,' + $subnetz) -ZoneScope ($scope + ',1') -ZoneName $zone -Disable }
    } -Rueckgaengig @(
        @{ Befehl = 'Remove-DnsServerQueryResolutionPolicy'; Parameter = @{ Name = $richtlinie; ZoneName = $zone; Force = $true } },
        @{ Befehl = 'Remove-DnsServerZoneScope'; Parameter = @{ ZoneName = $zone; Name = $scope; Force = $true } }
    )
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'SplitBrain' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Remove-NetSplitBrain {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return }
    $liste = @()
    foreach ($z in @(Get-NetDnsZoneInfo -Art Forward)) {
        $zn = $z.Name
        foreach ($p in @(Get-NetSafe -Beschreibung 'Richtlinien' -Standard @() -Abfrage { Get-DnsServerQueryResolutionPolicy -ZoneName $zn })) {
            if ($p -and [string]$p.Name -like 'NetSetup-SplitBrain-*') { $liste += [pscustomobject]@{ Name = [string]$p.Name; Zone = $zn } }
        }
    }
    $w = Select-NetItem -Elemente $liste -Titel 'Welche Split-Brain-Richtlinie entfernen?' -Eigenschaften @('Name', 'Zone')
    if (-not $w) { return }
    $zone = $w.Zone
    $name = $w.Name
    Invoke-NetChange -Titel "Split-Brain $name entfernen" -Stufe Bestaetigen -Vorher 'aktiv bzw. angelegt' -Nachher 'Richtlinie und Zonen-Scope intern entfernt' -BackupBereich @('Dns') -Aktion {
        Remove-DnsServerQueryResolutionPolicy -Name $name -ZoneName $zone -Force
        Remove-DnsServerZoneScope -ZoneName $zone -Name 'intern' -Force
    } | Out-Null
}

# ---------------------------------------------------------------- DHCP-Richtlinien

function New-NetDhcpPolicy {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return $false }
    Write-NetText -Text $script:NetHilfeDhcpRichtlinie
    $s = Select-NetDhcpScope -Titel 'Fuer welchen Scope?'
    if (-not $s) { return $false }
    $art = Read-NetChoice -Frage 'Bedingung' -Optionen @('MAC-Praefix (z. B. 00-15-5D fuer Hyper-V)', 'Herstellerklasse (Vendor Class)', 'Benutzerklasse (User Class)') -Vorschlag 1
    if ($art -lt 0) { return $false }
    $bedingung = @{}
    $text = ''
    if ($art -eq 0) {
        $praefix = Read-NetText -Frage 'MAC-Praefix (6 Hex-Zeichen, z. B. 00-15-5D)' -Pruefung { param($t) if (($t -replace '[\s:.-]', '') -match '^[0-9A-Fa-f]{6}$') { $null } else { 'Bitte 6 Hex-Zeichen eingeben.' } }
        if (-not $praefix) { return $false }
        $roh = ($praefix -replace '[\s:.-]', '').ToUpper()
        $bedingung.MacAddress = @('EQ', ($roh + '*'))
        $text = 'MAC beginnt mit ' + $roh
    }
    else {
        $typ = 'Vendor'
        if ($art -eq 2) { $typ = 'User' }
        $klassen = @(Get-NetSafe -Beschreibung 'Klassen' -Standard @() -Abfrage { Get-DhcpServerv4Class -Type $typ } | Where-Object { $_ } | ForEach-Object { [string]$_.Name })
        $k = Select-NetItem -Elemente $klassen -Titel 'Welche Klasse?'
        if (-not $k) { return $false }
        if ($art -eq 1) { $bedingung.VendorClass = @('EQ', ($k + '*')) } else { $bedingung.UserClass = @('EQ', $k) }
        $text = "$typ-Klasse $k"
    }
    $optionNr = Read-NetChoice -Frage 'Welche Option soll fuer diese Geraete anders sein?' -Optionen @('003 Router', '006 DNS-Server', '015 DNS-Domaene', '042 NTP-Server') -Vorschlag 2
    if ($optionNr -lt 0) { return $false }
    $optionId = @(3, 6, 15, 42)[$optionNr]
    $wertText = Read-NetText -Frage ('Wert(e) fuer Option {0:000} (mehrere mit Komma)' -f $optionId)
    if (-not $wertText) { return $false }
    $werte = @($wertText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $name = Read-NetText -Frage 'Name der Richtlinie' -Vorschlag ('NetSetup-' + ($text -replace '[^A-Za-z0-9]', ''))
    if (-not $name) { return $false }
    $id = $s.ScopeId
    $aktiv = Read-NetYesNo -Frage 'Richtlinie sofort aktivieren? (Nein = ausgeschaltet anlegen)' -Vorschlag $false
    $p = @{ Name = $name; ScopeId = $id; Condition = 'OR'; Enabled = $false; Description = 'Angelegt von NetSetup' }
    foreach ($k in $bedingung.Keys) { $p[$k] = $bedingung[$k] }
    $r = Invoke-NetChange -Titel "DHCP-Richtlinie $name anlegen" -Stufe Bestaetigen -Vorher '(keine Richtlinie)' -Nachher @{ Scope = $id; Bedingung = $text; Option = ('{0:000} = {1}' -f $optionId, ($werte -join ', ')); Aktiv = $(if ($aktiv) { 'ja' } else { 'nein (ausgeschaltet)' }) } -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Policy @p
        Set-DhcpServerv4OptionValue -ScopeId $id -PolicyName $name -OptionId $optionId -Value $werte -Force
        if ($aktiv) { Set-DhcpServerv4Policy -Name $name -ScopeId $id -Enabled $true }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Policy'; Parameter = @{ Name = $name; ScopeId = $id } }
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Richtlinien' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Get-NetDhcpPolicyList {
    $liste = @()
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $id = $s.ScopeId
        foreach ($p in @(Get-NetSafe -Beschreibung 'Richtlinien' -Standard @() -Abfrage { Get-DhcpServerv4Policy -ScopeId $id })) {
            if ($p) { $liste += [pscustomobject]@{ Name = [string]$p.Name; ScopeId = $id; Aktiv = [bool]$p.Enabled } }
        }
    }
    return $liste
}

function Switch-NetDhcpPolicy {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpPolicyList) -Titel 'Welche Richtlinie ein-/ausschalten?' -Eigenschaften @('Name', 'ScopeId', 'Aktiv')
    if (-not $w) { return }
    $name = $w.Name
    $id = $w.ScopeId
    $neu = -not $w.Aktiv
    Invoke-NetChange -Titel ("DHCP-Richtlinie {0} {1}" -f $name, $(if ($neu) { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen -Vorher $(if ($w.Aktiv) { 'aktiv' } else { 'aus' }) -Nachher $(if ($neu) { 'aktiv' } else { 'aus' }) -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4Policy -Name $name -ScopeId $id -Enabled $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4Policy'; Parameter = @{ Name = $name; ScopeId = $id; Enabled = $w.Aktiv } } | Out-Null
}

function Remove-NetDhcpPolicy {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpPolicyList) -Titel 'Welche Richtlinie entfernen?' -Eigenschaften @('Name', 'ScopeId', 'Aktiv')
    if (-not $w) { return }
    $name = $w.Name
    $id = $w.ScopeId
    Invoke-NetChange -Titel "DHCP-Richtlinie $name entfernen" -Stufe Bestaetigen -Vorher $name -Nachher '(entfernt)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4Policy -Name $name -ScopeId $id
    } | Out-Null
}

# ---------------------------------------------------------------- DNS-Sperrliste

function Get-NetDnsBlockList {
    return @(Get-NetSafe -Beschreibung 'Sperrliste' -Standard @() -Abfrage { Get-DnsServerQueryResolutionPolicy } | Where-Object { $_ -and [string]$_.Name -like 'NetSetup-Sperre-*' } | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Domaene = ([string]$_.Name).Substring(16); Aktiv = ([string]$_.IsEnabled -ne 'False') }
        })
}

function Add-NetDnsBlock {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text $script:NetHilfeSperrliste
    $text = Read-NetText -Frage 'Domaenen sperren (mit Komma, z. B. werbung.example)' -Pruefung {
        param($t)
        foreach ($d in $t.Split(',')) { $f = (Test-NetDomainName -Name $d.Trim()).Fehler; if ($f) { return $f } }
        return $null
    }
    if (-not $text) { return $false }
    $vorhanden = @(Get-NetDnsBlockList | ForEach-Object { $_.Domaene })
    $neu = @($text.Split(',') | ForEach-Object { $_.Trim().ToLower().TrimEnd('.') } | Where-Object { $_ -and $vorhanden -notcontains $_ } | Select-Object -Unique)
    if ($neu.Count -eq 0) { Write-Log -Level OK -Message 'Alle Domaenen sind bereits gesperrt.'; return $true }
    $aktiv = Read-NetYesNo -Frage 'Sperre sofort aktivieren? (Nein = ausgeschaltet anlegen)' -Vorschlag $false
    $rueck = @($neu | ForEach-Object { @{ Befehl = 'Remove-DnsServerQueryResolutionPolicy'; Parameter = @{ Name = ('NetSetup-Sperre-' + $_); Force = $true } } })
    $r = Invoke-NetChange -Titel ('{0} Domaene(n) im DNS sperren' -f $neu.Count) -Stufe Bestaetigen -Vorher ($(if ($vorhanden.Count) { $vorhanden -join ', ' } else { '(keine Sperren)' })) -Nachher (@($neu | ForEach-Object { $_ + $(if ($aktiv) { ' (aktiv)' } else { ' (aus)' }) })) -BackupBereich @('Dns') -Aktion {
        foreach ($d in $neu) {
            $fqdn = 'EQ,*.' + $d + ',' + $d
            if ($aktiv) { Add-DnsServerQueryResolutionPolicy -Name ('NetSetup-Sperre-' + $d) -Action IGNORE -Fqdn $fqdn }
            else { Add-DnsServerQueryResolutionPolicy -Name ('NetSetup-Sperre-' + $d) -Action IGNORE -Fqdn $fqdn -Disable }
        }
    } -Rueckgaengig $rueck
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Sperrliste' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Switch-NetDnsBlock {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDnsBlockList) -Titel 'Welche Sperre ein-/ausschalten?' -Eigenschaften @('Domaene', 'Aktiv')
    if (-not $w) { return }
    $name = $w.Name
    $neu = 'Enable'
    $alt = 'Disable'
    if ($w.Aktiv) { $neu = 'Disable'; $alt = 'Enable' }
    Invoke-NetChange -Titel ("Sperre {0} {1}" -f $w.Domaene, $(if ($neu -eq 'Enable') { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen -Vorher $alt -Nachher $neu -BackupBereich @('Dns') -Aktion {
        Set-DnsServerQueryResolutionPolicy -Name $name -State $neu
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerQueryResolutionPolicy'; Parameter = @{ Name = $name; State = $alt } } | Out-Null
}

function Remove-NetDnsBlock {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return }
    $wahl = @(Select-NetItem -Elemente @(Get-NetDnsBlockList) -Titel 'Welche Sperren aufheben?' -Eigenschaften @('Domaene', 'Aktiv') -Mehrfach)
    if ($wahl.Count -eq 0) { return }
    $namen = @($wahl | ForEach-Object { $_.Name })
    Invoke-NetChange -Titel ('{0} Sperre(n) aufheben' -f $namen.Count) -Stufe Bestaetigen -Vorher ($namen -join ', ') -Nachher '(aufgehoben)' -BackupBereich @('Dns') -Aktion {
        foreach ($n in $namen) { Remove-DnsServerQueryResolutionPolicy -Name $n -Force }
    } | Out-Null
}

function Show-NetDnsBlock {
    if (-not (Test-NetDnsReady)) { return }
    Write-NetTitle -Titel 'DNS-Sperrliste'
    $liste = @(Get-NetDnsBlockList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Keine Sperren von NetSetup.' }
    foreach ($b in $liste) { Write-NetStatus -Status $(if ($b.Aktiv) { 'OK' } else { 'NA' }) -Bereich $b.Domaene -Text $(if ($b.Aktiv) { 'gesperrt' } else { 'angelegt, ausgeschaltet' }) }
    $global = Get-NetSafe -Beschreibung 'Globale Sperrliste' -Abfrage { Get-DnsServerGlobalQueryBlockList }
    if ($global) { Write-Host ('  Globale Sperrliste von Windows ({0}): {1}' -f $(if ($global.Enable) { 'an' } else { 'aus' }), (@($global.List) -join ', ')) -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- DHCPv6

function New-NetDhcpv6Scope {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return $false }
    Write-NetText -Text $script:NetHilfeDhcpv6
    $praefix = Read-NetText -Frage 'IPv6-Praefix (/64), z. B. fd00:1234:5678:1::' -Pruefung {
        param($t)
        $x = $t -replace '/64$', ''
        if (-not (Test-NetIPv6Address -Text $x)) { return 'Bitte ein IPv6-Praefix wie fd00:1234:5678:1:: eingeben.' }
        return $null
    }
    if (-not $praefix) { return $false }
    $praefix = $praefix -replace '/64$', ''
    $vorhanden = @(Get-NetSafe -Beschreibung 'DHCPv6' -Standard @() -Abfrage { Get-DhcpServerv6Scope } | Where-Object { $_ -and (ConvertTo-NetString $_.Prefix) -eq $praefix })
    if ($vorhanden.Count -gt 0) { Write-Log -Level OK -Message "Den DHCPv6-Scope $praefix gibt es bereits."; return $true }
    $name = Read-NetText -Frage 'Name' -Vorschlag 'IPv6 LAN'
    if (-not $name) { return $false }
    $r = Invoke-NetChange -Titel "DHCPv6-Scope $praefix anlegen (inaktiv)" -Stufe Bestaetigen -Vorher '(kein DHCPv6-Scope)' -Nachher @{ Praefix = "$praefix/64"; Name = $name; Status = 'inaktiv - muss aktiv eingeschaltet werden' } -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv6Scope -Prefix $praefix -Name $name -State InActive
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv6Scope'; Parameter = @{ Prefix = $praefix; Force = $true } }
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Dhcpv6' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Get-NetDhcpv6ScopeList {
    return @(Get-NetSafe -Beschreibung 'DHCPv6' -Standard @() -Abfrage { Get-DhcpServerv6Scope } | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Praefix = (ConvertTo-NetString $_.Prefix); Name = [string]$_.Name; Status = [string]$_.State }
        })
}

function Switch-NetDhcpv6Scope {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpv6ScopeList) -Titel 'Welchen DHCPv6-Scope ein-/ausschalten?' -Eigenschaften @('Praefix', 'Name', 'Status')
    if (-not $w) { return }
    $praefix = $w.Praefix
    $alt = $w.Status
    $neu = 'Active'
    if ($alt -eq 'Active') { $neu = 'InActive' }
    Invoke-NetChange -Titel "DHCPv6-Scope $praefix $(if ($neu -eq 'Active') { 'aktivieren' } else { 'deaktivieren' })" -Stufe Bestaetigen -Vorher $alt -Nachher $neu -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv6Scope -Prefix $praefix -State $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv6Scope'; Parameter = @{ Prefix = $praefix; State = $alt } } | Out-Null
}

function Remove-NetDhcpv6Scope {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpv6ScopeList) -Titel 'Welchen DHCPv6-Scope loeschen?' -Eigenschaften @('Praefix', 'Name', 'Status')
    if (-not $w) { return }
    $praefix = $w.Praefix
    Invoke-NetChange -Titel "DHCPv6-Scope $praefix loeschen" -Stufe Gefaehrlich -Vorher ('{0} ({1})' -f $praefix, $w.Status) -Nachher '(geloescht)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv6Scope -Prefix $praefix -Force
    } | Out-Null
}

function Show-NetDhcpv6Scope {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCPv6-Scopes'
    $liste = @(Get-NetDhcpv6ScopeList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Keine DHCPv6-Scopes (Standard).' }
    foreach ($s in $liste) { Write-Host ('  {0,-28} {1,-20} {2}' -f ($s.Praefix + '/64'), $s.Name, $s.Status) }
}

# ---------------------------------------------------------------- Menue

function Show-NetAdvancedMenu {
    $eintraege = @(
        @{ Text = 'DNSSEC: Zone signieren'; Aktion = { Invoke-NetDnssecSign | Out-Null }; Hilfe = $script:NetHilfeDnssec },
        @{ Text = 'DNSSEC: Signatur entfernen'; Aktion = { Invoke-NetDnssecUnsign | Out-Null }; Hilfe = 'Entfernt die DNSSEC-Signatur einer Zone wieder (gefaehrlich, mit Backup).' },
        @{ Text = 'Split-Brain einrichten'; Aktion = { New-NetSplitBrain | Out-Null }; Hilfe = $script:NetHilfeSplitBrain },
        @{ Text = 'Split-Brain entfernen'; Aktion = 'Remove-NetSplitBrain'; Hilfe = 'Entfernt Richtlinie und Zonen-Scope "intern" wieder.' },
        @{ Text = 'DHCP-Richtlinie anlegen'; Aktion = { New-NetDhcpPolicy | Out-Null }; Hilfe = $script:NetHilfeDhcpRichtlinie },
        @{ Text = 'DHCP-Richtlinie ein-/ausschalten'; Aktion = 'Switch-NetDhcpPolicy'; Hilfe = 'Schaltet eine Richtlinie ein oder aus (rueckgaengig moeglich).' },
        @{ Text = 'DHCP-Richtlinie entfernen'; Aktion = 'Remove-NetDhcpPolicy'; Hilfe = 'Entfernt eine DHCP-Richtlinie.' },
        @{ Text = 'DNS-Sperrliste anzeigen'; Aktion = 'Show-NetDnsBlock'; Hilfe = 'Zeigt die von NetSetup angelegten Sperren und die globale Sperrliste von Windows.' },
        @{ Text = 'Domaenen sperren'; Aktion = { Add-NetDnsBlock | Out-Null }; Hilfe = $script:NetHilfeSperrliste },
        @{ Text = 'Sperre ein-/ausschalten'; Aktion = 'Switch-NetDnsBlock'; Hilfe = 'Schaltet eine Sperre ein oder aus.' },
        @{ Text = 'Sperren aufheben'; Aktion = 'Remove-NetDnsBlock'; Hilfe = 'Entfernt Sperren wieder.' },
        @{ Text = 'DHCPv6-Scopes anzeigen'; Aktion = 'Show-NetDhcpv6Scope'; Hilfe = 'Listet die DHCPv6-Scopes.' },
        @{ Text = 'DHCPv6-Scope anlegen (inaktiv)'; Aktion = { New-NetDhcpv6Scope | Out-Null }; Hilfe = $script:NetHilfeDhcpv6 },
        @{ Text = 'DHCPv6-Scope aktivieren/deaktivieren'; Aktion = 'Switch-NetDhcpv6Scope'; Hilfe = 'Erst hier wird ein DHCPv6-Scope wirksam.' },
        @{ Text = 'DHCPv6-Scope loeschen'; Aktion = 'Remove-NetDhcpv6Scope'; Hilfe = 'Loescht einen DHCPv6-Scope (gefaehrlich, mit Backup).' }
    )
    Show-NetMenu -Titel 'Erweitert (Fachleute)' -Eintraege $eintraege -Einleitung $script:NetErweitertWarnung -Kopf {
        Write-Host ('  Freigeschaltet: {0}' -f $(if ($script:NS.ErweitertFrei) { 'ja (diese Sitzung)' } else { 'nein - beim ersten Punkt wird gefragt' })) -ForegroundColor Yellow
    }
}
