# Statusuebersicht: eine Zeile pro Bereich mit [OK], [WARN], [FEHLER] oder [--].

function New-NetSummaryLine {
    param([string]$Bereich, [ValidateSet('OK', 'WARN', 'FEHLER', 'NA', 'INFO')][string]$Status, [string]$Text)
    return [pscustomobject]@{ Bereich = $Bereich; Status = $Status; Text = $Text }
}

function Get-NetStateSummary {
    <#
    .SYNOPSIS
        Bewertet die Bestandsaufnahme pro Bereich (System, Neustart, AD, Netzwerk, DNS, DHCP, DHCP+DNS, Zeit).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Zustand)
    $zeilen = @()
    $s = $Zustand.System

    # System
    $art = 'Desktop'
    if ($s.IstCore) { $art = 'Server Core' }
    if (-not $s.IstAdmin) { $zeilen += New-NetSummaryLine -Bereich 'System' -Status 'WARN' -Text ('{0} ({1}) - ohne Administratorrechte' -f $s.OsName, $art) }
    else { $zeilen += New-NetSummaryLine -Bereich 'System' -Status 'OK' -Text ('{0} ({1}), Sprache {2}' -f $s.OsName, $art, $s.UiSprache) }

    # Neustart
    if ($Zustand.Neustart.Ausstehend) { $zeilen += New-NetSummaryLine -Bereich 'Neustart' -Status 'WARN' -Text ('Neustart ausstehend: ' + ($Zustand.Neustart.Gruende -join ', ')) }
    else { $zeilen += New-NetSummaryLine -Bereich 'Neustart' -Status 'OK' -Text 'kein Neustart ausstehend' }

    # Active Directory
    $adFeature = $Zustand.Features['AD-Domain-Services']
    if ($s.IstDC) {
        $ntds = $Zustand.Dienste['NTDS']
        if ($ntds -and $ntds.Vorhanden -and $ntds.Status -ne 'Running') { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'FEHLER' -Text ('Domaenencontroller, aber der Dienst NTDS laeuft nicht ({0})' -f $ntds.Status) }
        elseif ($Zustand.AD.ModulFehlt) { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'WARN' -Text ('Domaenencontroller fuer {0}, AD-Verwaltungstools fehlen (RSAT-AD-PowerShell)' -f $Zustand.AD.Domaene) }
        else { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'OK' -Text ('Domaenencontroller fuer {0} ({1})' -f $Zustand.AD.Domaene, $Zustand.AD.NetBios) }
    }
    elseif ($s.IstMitglied) {
        $text = 'Mitgliedsserver der Domaene ' + $s.Domaene
        if ($adFeature -eq 'Installed') { $text += ', Rolle AD DS installiert aber nicht heraufgestuft' }
        $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status $(if ($adFeature -eq 'Installed') { 'WARN' } else { 'INFO' }) -Text $text
    }
    elseif ($s.IstArbeitsgruppe) {
        $modus = Get-NetConfigValue -Pfad 'AD.Modus' -Standard ''
        if ($adFeature -eq 'Installed') { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'WARN' -Text 'Rolle AD DS installiert, aber der Server ist noch kein Domaenencontroller' }
        elseif ($modus -eq 'OhneAD') { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'NA' -Text 'bewusst ohne AD (Arbeitsgruppe)' }
        else { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'NA' -Text ('kein AD - Arbeitsgruppe {0}' -f $s.Arbeitsgruppe) }
    }
    else { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'WARN' -Text 'Rolle des Servers unbekannt' }

    # Netzwerk
    $n = $Zustand.Netzwerk
    if ($n.AktiveKarten.Count -eq 0) {
        $zeilen += New-NetSummaryLine -Bereich 'Netzwerk' -Status 'FEHLER' -Text 'keine aktive Netzwerkkarte mit IPv4-Adresse gefunden'
    }
    else {
        $k = $n.AktiveKarten[0]
        $ip = ($k.Adressen | Select-Object -First 1)
        $text = '{0}: {1}/{2}' -f $k.Name, $ip.IP, $ip.Prefix
        if ($k.Gateway.Count -gt 0) { $text += ', Gateway ' + $k.Gateway[0] }
        if ($k.DnsServer.Count -gt 0) { $text += ', DNS ' + ($k.DnsServer -join ' ') }
        $probleme = @()
        if (@($n.AktiveKarten | Where-Object { $_.Dhcp }).Count -gt 0) { $probleme += 'IP per DHCP (Server brauchen eine feste IP)' }
        if ($n.MehrereKarten) { $probleme += ('{0} aktive Netzwerkkarten' -f $n.AktiveKarten.Count) }
        if ($s.IstDC -and $k.DnsServer.Count -gt 0) {
            $eigene = @($n.EigeneIPs) + @('127.0.0.1')
            if (@($k.DnsServer | Where-Object { $eigene -contains $_ }).Count -eq 0) { $probleme += 'DC fragt nicht sich selbst als DNS' }
        }
        if ($probleme.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'Netzwerk' -Status 'WARN' -Text ($text + ' - ' + ($probleme -join ', ')) }
        else { $zeilen += New-NetSummaryLine -Bereich 'Netzwerk' -Status 'OK' -Text ($text + ', feste IP') }
    }

    # DNS
    $d = $Zustand.Dns
    $dnsFeature = $Zustand.Features['DNS']
    if (-not $d.Installiert -and -not ($Zustand.Dienste['DNS'] -and $Zustand.Dienste['DNS'].Vorhanden)) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'NA' -Text ('nicht installiert ({0})' -f (ConvertTo-NetFeatureText -Status $dnsFeature))
    }
    elseif (-not $d.Laeuft) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'FEHLER' -Text 'installiert, aber der DNS-Dienst laeuft nicht'
    }
    elseif (-not $d.Tools) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'WARN' -Text 'Dienst laeuft, Verwaltungstools fehlen (RSAT-DNS-Server)'
    }
    elseif (-not $d.Verfuegbar) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'WARN' -Text 'Zustand unbekannt (Abfrage fehlgeschlagen, Details im Log)'
    }
    else {
        $forward = @($d.Zonen | Where-Object { -not $_.Reverse })
        $reverse = @($d.Zonen | Where-Object { $_.Reverse })
        $text = '{0} Zone(n), {1} Reverse-Zone(n)' -f $forward.Count, $reverse.Count
        if ($d.Weiterleitungen.Count -gt 0) { $text += ', Weiterleitung ' + ($d.Weiterleitungen -join ' ') }
        else { $text += ', keine Weiterleitung' }
        $warn = @()
        if ($forward.Count -eq 0) { $warn += 'keine Zone' }
        if ($reverse.Count -eq 0) { $warn += 'keine Reverse-Zone' }
        if ($warn.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'WARN' -Text ($text + ' - ' + ($warn -join ', ')) }
        else { $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'OK' -Text $text }
    }

    # DHCP
    $h = $Zustand.Dhcp
    if (-not $h.Installiert -and -not ($Zustand.Dienste['DHCPServer'] -and $Zustand.Dienste['DHCPServer'].Vorhanden)) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'NA' -Text ('nicht installiert ({0})' -f (ConvertTo-NetFeatureText -Status $Zustand.Features['DHCP']))
    }
    elseif (-not $h.Laeuft) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'FEHLER' -Text 'installiert, aber der DHCP-Dienst laeuft nicht'
    }
    elseif (-not $h.Tools) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'WARN' -Text 'Dienst laeuft, Verwaltungstools fehlen (RSAT-DHCP)'
    }
    elseif (-not $h.Verfuegbar) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'WARN' -Text 'Zustand unbekannt (Abfrage fehlgeschlagen, Details im Log)'
    }
    else {
        $aktiv = @($h.Scopes | Where-Object { $_.Aktiv })
        $text = '{0} Scope(s), davon {1} aktiv' -f $h.Scopes.Count, $aktiv.Count
        $warn = @()
        $fehler = @()
        if (-not $h.Nachkonfiguriert) { $warn += 'Nachkonfiguration fehlt' }
        if ($h.InDomaene -and -not $h.Autorisiert) { $fehler += 'nicht im AD autorisiert' }
        if ($h.Scopes.Count -eq 0) { $warn += 'kein Scope' }
        $grenze = [int](Get-NetConfigValue -Pfad 'Vorschlaege.AuslastungWarnung' -Standard 80)
        foreach ($sc in $aktiv) {
            if ($sc.Auslastung -ge $grenze) { $warn += ('{0} zu {1:N0}% belegt' -f $sc.ScopeId, $sc.Auslastung) }
        }
        if ($fehler.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'FEHLER' -Text ($text + ' - ' + (($fehler + $warn) -join ', ')) }
        elseif ($warn.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'WARN' -Text ($text + ' - ' + ($warn -join ', ')) }
        else { $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'OK' -Text $text }
    }

    # DHCP + DNS
    if (-not $h.Verfuegbar) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP + DNS' -Status 'NA' -Text 'kein DHCP-Server auf diesem Server'
    }
    else {
        $warn = @()
        $e = $h.DnsEinstellung
        if (-not $e -or $e.DynamicUpdates -ne 'Always') { $warn += 'DNS-Eintraege nicht fuer alle Clients' }
        if (-not $e -or -not $e.DeleteDnsRROnLeaseExpiry) { $warn += 'alte Eintraege werden nicht entfernt' }
        if ($s.IstDC -and -not $h.DnsZugangsdaten.Gesetzt) { $warn += 'DHCP auf DC ohne DNS-Zugangsdaten' }
        if ($warn.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DHCP + DNS' -Status 'WARN' -Text ($warn -join ', ') }
        else { $zeilen += New-NetSummaryLine -Bereich 'DHCP + DNS' -Status 'OK' -Text ('Clients werden automatisch eingetragen (Konto {0})' -f $(if ($h.DnsZugangsdaten.Gesetzt) { $h.DnsZugangsdaten.Benutzer } else { 'Computerkonto' })) }
    }

    # Zeit
    $t = $Zustand.Zeit
    if (-not $t.Typ) { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'WARN' -Text 'Zeitdienst-Einstellung nicht lesbar' }
    elseif ($s.IstPdc -and $t.Typ -ne 'NTP') { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'WARN' -Text ('PDC-Emulator ohne externe Zeitquelle (Typ {0})' -f $t.Typ) }
    elseif ($s.IstPdc) { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'OK' -Text ('PDC holt die Zeit von {0}' -f $t.NtpServer) }
    elseif (($s.IstMitglied -or $s.IstDC) -and $t.Typ -ne 'NT5DS') { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'WARN' -Text ('Domaenenmitglied, folgt aber nicht der Domaenenhierarchie (Typ {0})' -f $t.Typ) }
    else { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'OK' -Text ('Zeitquelle: {0} {1}' -f $t.Typ, $t.NtpServer).Trim() }

    return $zeilen
}

function ConvertTo-NetFeatureText {
    param([string]$Status)
    switch ($Status) {
        'Installed' { return 'installiert' }
        'Available' { return 'verfuegbar' }
        'Removed' { return 'Dateien entfernt' }
        'InstallPending' { return 'Installation wartet auf Neustart' }
        'UninstallPending' { return 'Deinstallation wartet auf Neustart' }
        default { return 'unbekannt' }
    }
}

function Show-NetStartOverview {
    <#
    .SYNOPSIS
        Bestandsaufnahme beim Start mit einer Zeile pro Bereich.
    #>
    Write-Log -Message 'Bestandsaufnahme laeuft (nur lesend) ...'
    $zustand = Get-NetSetupState
    $zeilen = Get-NetStateSummary -Zustand $zustand
    $script:NS.Zusammenfassung = $zeilen
    Write-NetTitle -Titel ('Bestandsaufnahme {0} ({1})' -f $zustand.System.Hostname, $zustand.System.RolleText)
    foreach ($z in $zeilen) { Write-NetStatus -Status $z.Status -Bereich $z.Bereich -Text $z.Text }
    $probleme = @($zeilen | Where-Object { $_.Status -eq 'FEHLER' -or $_.Status -eq 'WARN' })
    if ($probleme.Count -gt 0) {
        Write-Host ''
        Write-Log -Message 'Tipp: Der Doktor im Hauptmenue erklaert und repariert die markierten Punkte.'
    }
}

function Show-NetStatusLine {
    <#
    .SYNOPSIS
        Kurze Statuszeile fuer den Kopf des Hauptmenues (aus der letzten Bestandsaufnahme).
    #>
    $zeilen = $script:NS.Zusammenfassung
    if (-not $zeilen) { return }
    $teile = @()
    foreach ($z in $zeilen) {
        if (@('Active Directory', 'DNS', 'DHCP', 'DHCP + DNS', 'Netzwerk') -notcontains $z.Bereich) { continue }
        $marke = @{ OK = 'OK'; WARN = 'WARN'; FEHLER = 'FEHLER'; NA = '--'; INFO = 'i' }[$z.Status]
        $teile += ('{0} [{1}]' -f $z.Bereich, $marke)
    }
    Write-Host ('  Status: ' + ($teile -join '  ')) -ForegroundColor DarkCyan
}

function Show-NetStateDetail {
    <#
    .SYNOPSIS
        Zeigt die komplette Bestandsaufnahme ausfuehrlich an.
    #>
    $z = Get-NetSetupState
    $script:NS.Zusammenfassung = Get-NetStateSummary -Zustand $z
    Write-NetTitle -Titel 'Bestandsaufnahme im Detail'
    Write-Host ('  Server       : {0} - {1}' -f $z.System.Hostname, $z.System.RolleText)
    Write-Host ('  Windows      : {0} {1} Build {2}, {3}' -f $z.System.OsName, $z.System.Edition, $z.System.Build, $(if ($z.System.IstCore) { 'Server Core' } else { 'Desktop' }))
    Write-Host ('  Sprache      : {0} / Oberflaeche {1}' -f $z.System.Sprache, $z.System.UiSprache)
    if ($z.AD.Domaene) { Write-Host ('  Domaene      : {0} (NetBIOS {1}), Gesamtstruktur {2}, Ebene {3}' -f $z.AD.Domaene, $z.AD.NetBios, $z.AD.Gesamtstruktur, $z.AD.DomainMode) }
    Write-Host '  Funktionen   :'
    foreach ($f in ($z.Features.Keys | Sort-Object)) { Write-Host ('    {0,-22} {1}' -f $f, (ConvertTo-NetFeatureText -Status $z.Features[$f])) }
    Write-Host '  Dienste      :'
    foreach ($d in ($z.Dienste.Keys | Sort-Object)) {
        $x = $z.Dienste[$d]
        if ($x.Vorhanden) { Write-Host ('    {0,-22} {1} (Start: {2})' -f $d, $x.Status, $x.StartTyp) }
        else { Write-Host ('    {0,-22} nicht vorhanden' -f $d) -ForegroundColor DarkGray }
    }
    Write-Host '  Netzwerk     :'
    foreach ($k in $z.Netzwerk.Karten) {
        $ips = ($k.Adressen | ForEach-Object { '{0}/{1}' -f $_.IP, $_.Prefix }) -join ', '
        Write-Host ('    [{0}] {1} ({2}) {3} {4} GW {5} DNS {6}' -f $k.Index, $k.Name, $k.Status, $(if ($k.Dhcp) { 'DHCP' } else { 'statisch' }), $ips, ($k.Gateway -join ' '), ($k.DnsServer -join ' '))
    }
    if ($z.Dns.Verfuegbar) {
        Write-Host '  DNS-Zonen    :'
        foreach ($zone in $z.Dns.Zonen) {
            Write-Host ('    {0,-35} {1,-9} {2,-12} Updates: {3}' -f $zone.Name, $zone.Typ, $(if ($zone.AdIntegriert) { 'AD (' + $zone.Replikation + ')' } else { 'Datei' }), $zone.DynUpdate)
        }
        Write-Host ('  Weiterleitung: {0}' -f $(if ($z.Dns.Weiterleitungen.Count) { $z.Dns.Weiterleitungen -join ', ' } else { 'keine (Stammhinweise)' }))
        if ($z.Dns.Scavenging) { Write-Host ('  Scavenging   : {0}, No-Refresh {1}, Refresh {2}' -f $(if ($z.Dns.Scavenging.Aktiv) { 'an' } else { 'aus' }), $z.Dns.Scavenging.NoRefresh, $z.Dns.Scavenging.Refresh) }
    }
    if ($z.Dhcp.Verfuegbar) {
        Write-Host ('  DHCP         : autorisiert {0}, nachkonfiguriert {1}, Konflikterkennung {2}' -f $z.Dhcp.Autorisiert, $z.Dhcp.Nachkonfiguriert, $z.Dhcp.KonfliktErkennung)
        foreach ($sc in $z.Dhcp.Scopes) {
            Write-Host ('    {0,-15} {1,-20} {2} - {3} /{4} {5} Lease {6:N1} Tage, belegt {7:N0}%' -f $sc.ScopeId, $sc.Name, $sc.Start, $sc.Ende, $sc.Prefix, $sc.Status, $sc.LeaseTage, $sc.Auslastung)
            $opt = @()
            foreach ($id in @('3', '6', '15')) { if ($sc.Optionen.ContainsKey($id)) { $opt += ('{0}={1}' -f $id, ($sc.Optionen[$id] -join ',')) } }
            if ($opt.Count) { Write-Host ('      Optionen: ' + ($opt -join '; ')) -ForegroundColor DarkGray }
        }
        foreach ($f in $z.Dhcp.Failover) { Write-Host ('    Failover {0} mit {1}: {2}, {3}' -f $f.Name, $f.Partner, $f.Modus, $f.Status) }
    }
    Write-Host ('  Zeit         : Typ {0}, Server {1}' -f $z.Zeit.Typ, $z.Zeit.NtpServer)
    if ($z.Neustart.Ausstehend) { Write-Host ('  Neustart     : ausstehend ({0})' -f ($z.Neustart.Gruende -join ', ')) -ForegroundColor Yellow }
    Write-Host ''
    foreach ($zeile in $script:NS.Zusammenfassung) { Write-NetStatus -Status $zeile.Status -Bereich $zeile.Bereich -Text $zeile.Text }
}
