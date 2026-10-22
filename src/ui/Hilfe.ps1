# Hilfe und Glossar. Alles Wissen steckt im Script, damit niemand im Internet suchen muss.
# Die Texte des Glossars stehen gleichlautend in docs/handbuch.md.

$script:NetGlossar = [ordered]@{
    'A-Eintrag'             = 'DNS-Eintrag, der einen Namen einer IPv4-Adresse zuordnet (pc01.ad.firma.ch -> 192.168.1.50). AAAA ist dasselbe fuer IPv6.'
    'Abhoer-IP-Adresse'     = 'Die Adressen des Servers, auf denen der DNS-Dienst Anfragen annimmt. Ueblich: alle festen IPv4-Adressen des Servers, keine APIPA-Adressen (169.254.x.x).'
    'Aging/Scavenging'      = 'Automatisches Aufraeumen alter, dynamisch eingetragener DNS-Eintraege. Aging merkt sich, wann ein Eintrag zuletzt erneuert wurde; Scavenging loescht Eintraege, die laenger als No-Refresh + Refresh nicht erneuert wurden. Ueblich: an, 7 + 7 Tage. Die Summe muss mindestens so lang sein wie die DHCP-Lease-Dauer.'
    'Ausschluss'            = 'Ein Adressbereich innerhalb eines DHCP-Scopes, den der DHCP-Server nie vergibt, z. B. fuer Drucker oder Server mit fester IP.'
    'Autorisierung'         = 'Eintrag des DHCP-Servers im Active Directory. Ein Windows-DHCP-Server in einer Domaene vergibt erst Adressen, wenn er autorisiert ist. Dafuer sind Rechte der Organisations-Admins (Enterprise Admins) noetig.'
    'Bindung'               = 'Legt fest, auf welcher Netzwerkkarte der DHCP-Server Anfragen beantwortet. Nur Karten mit fester IP im Netz der Clients sollten gebunden sein.'
    'CNAME'                 = 'Alias-Eintrag im DNS: ein zweiter Name zeigt auf einen vorhandenen Namen (intranet -> srv01).'
    'DHCP-Relay'            = 'Funktion im Router oder Layer-3-Switch (oft "IP Helper" genannt), die DHCP-Anfragen aus anderen Netzen (VLANs) an den DHCP-Server weiterleitet. Ohne Relay erreicht ein DHCP-Server nur das eigene Netz.'
    'DHCPv6'                = 'DHCP fuer IPv6. In den meisten Netzen nicht noetig, weil IPv6 sich per Router-Ankuendigung (SLAAC) selbst konfiguriert. In NetSetup unter "Erweitert".'
    'Dienstkonto'           = 'Ein eigenes AD-Benutzerkonto nur fuer einen Dienst, hier fuer die DNS-Eintraege des DHCP-Servers (Vorschlag svc-dhcpdns). Sein Kennwort muss gepflegt werden, sonst schlagen die Eintraege nach Ablauf fehl.'
    'DNSSEC'                = 'Digitale Signaturen fuer DNS-Zonen, damit Antworten nicht gefaelscht werden koennen. Erfordert Schluesselpflege; ein Fehler kann die Namensaufloesung stoeren. In NetSetup unter "Erweitert".'
    'Domaenencontroller'    = 'Server, der das Active Directory speichert und Anmeldungen prueft (kurz DC). Mindestens zwei DCs pro Domaene sind empfohlen.'
    'DSRM'                  = 'Verzeichnisdienst-Wiederherstellungsmodus (Directory Services Restore Mode). Notfall-Anmeldung an einem DC, wenn das AD nicht startet. Das DSRM-Kennwort wird bei der Heraufstufung festgelegt und muss sicher aufbewahrt werden.'
    'Dynamisches Update'    = 'Clients oder der DHCP-Server tragen ihre DNS-Eintraege selbst ein. "Sicher" (nur auf AD-integrierten Zonen) erlaubt das nur angemeldeten Domaenenmitgliedern und ist die empfohlene Einstellung.'
    'Failover'              = 'Zwei DHCP-Server teilen sich einen Scope. Lastverteilung: beide vergeben Adressen. Reserve (Hot-Standby): einer arbeitet, der andere springt bei Ausfall ein. Beide brauchen ein gemeinsames Geheimnis.'
    'Funktionsebene'        = 'Legt fest, welche AD-Funktionen genutzt werden koennen und welche Windows-Versionen als DC erlaubt sind. NetSetup schlaegt die hoechste Ebene vor, die das Betriebssystem kann.'
    'Gateway'               = 'Der Router, ueber den ein Netz andere Netze und das Internet erreicht (DHCP-Option 003).'
    'Gesamtstruktur'        = 'Englisch Forest. Die oberste Ebene im Active Directory, enthaelt eine oder mehrere Domaenen. Die erste Domaene ist die Stammdomaene der Gesamtstruktur.'
    'Lease'                 = 'Die zeitlich begrenzte Vergabe einer IP-Adresse an einen Client. Vor Ablauf erneuert der Client die Lease. Ueblich in Bueros: 8 Tage; in Gaeste- oder WLAN-Netzen kuerzer (z. B. 1 Tag).'
    'MX'                    = 'Mail-Exchanger-Eintrag im DNS: nennt den Mailserver einer Domaene mit einer Prioritaet (kleinere Zahl = bevorzugt).'
    'Namensschutz'          = 'DHCP-Einstellung (Name Protection): verhindert, dass ein Geraet den DNS-Namen eines anderen Geraets uebernimmt.'
    'NetBIOS-Name'          = 'Kurzer, alter Domaenenname (hoechstens 15 Zeichen, z. B. FIRMA), der bei der Anmeldung als FIRMA\benutzer erscheint.'
    'Option'                = 'Zusatzinformation, die der DHCP-Server mit der Adresse mitliefert, z. B. 003 Router, 006 DNS-Server, 015 DNS-Domaenenname, 042 NTP-Server, 066/067 PXE-Bootserver und Bootdatei, 119 DNS-Suchliste.'
    'Organisations-Admins'  = 'Englisch Enterprise Admins. AD-Gruppe mit Rechten fuer die ganze Gesamtstruktur, noetig z. B. fuer die DHCP-Autorisierung.'
    'Probelauf'             = 'Modus, in dem NetSetup alles prueft und anzeigt, aber nichts aendert (entspricht -WhatIf). In den Einstellungen umschaltbar.'
    'PTR'                   = 'Zeiger-Eintrag in einer Reverse-Zone: ordnet einer IP-Adresse einen Namen zu (192.168.1.50 -> pc01.ad.firma.ch).'
    'Reservierung'          = 'Feste Zuordnung einer IP-Adresse zu einem Geraet (ueber die MAC-Adresse). Das Geraet bekommt per DHCP immer dieselbe Adresse.'
    'Reverse-Zone'          = 'DNS-Zone fuer die Rueckwaertssuche von IP-Adresse zu Name, z. B. 1.168.192.in-addr.arpa fuer das Netz 192.168.1.0/24. Enthaelt PTR-Eintraege.'
    'Rueckgaengig'          = 'NetSetup merkt sich zu jeder Aenderung die Gegenaktion. Unter "Backup, Wiederherstellen, Rueckgaengig" laesst sich die letzte oder eine bestimmte Aenderung zuruecknehmen.'
    'Scope'                 = 'Adressbereich, aus dem der DHCP-Server Adressen vergibt, z. B. 192.168.1.100 bis 192.168.1.199 im Netz 192.168.1.0/24, mit eigenen Optionen.'
    'Server Core'           = 'Windows Server ohne Desktop-Oberflaeche. NetSetup laeuft dort genauso, nur ohne Auswahlfenster (Out-GridView).'
    'Split-Brain'           = 'DNS gibt je nach Fragesteller unterschiedliche Antworten, z. B. intern die interne und extern die oeffentliche Adresse. Umgesetzt mit Zonen-Scopes und Abfrage-Richtlinien.'
    'SRV'                   = 'Dienst-Eintrag im DNS: nennt Server fuer einen Dienst mit Port, Prioritaet und Gewichtung. Das AD findet DCs ueber SRV-Eintraege wie _ldap._tcp.dc._msdcs.<domaene>.'
    'Stammhinweise'         = 'Englisch Root Hints. Liste der DNS-Stammserver im Internet. Ohne Weiterleitung fragt der DNS-Server von dort aus selbst durch. Funktioniert nur mit Internetzugang ueber Port 53.'
    'Subnetzmaske'          = 'Legt fest, welcher Teil einer IP-Adresse das Netz ist. 255.255.255.0 entspricht /24 (254 nutzbare Adressen).'
    'Superscope'            = 'Zusammenfassung mehrerer DHCP-Scopes, die im selben physischen Netz liegen (mehrere logische Netze auf einem Kabel).'
    'SYSVOL'                = 'Freigegebener Ordner auf jedem DC mit Gruppenrichtlinien und Anmeldescripts. Die Freigaben SYSVOL und NETLOGON muessen auf jedem DC vorhanden sein.'
    'TXT'                   = 'Text-Eintrag im DNS, z. B. fuer SPF oder Domaenen-Nachweise.'
    'Weiterleitung'         = 'Englisch Forwarder. Der DNS-Server schickt Anfragen, die er nicht selbst beantworten kann, an einen anderen DNS-Server (z. B. 9.9.9.9 Quad9, 1.1.1.1 Cloudflare oder den Router). Eine bedingte Weiterleitung gilt nur fuer eine bestimmte Domaene.'
    'Zeitquelle'            = 'Von wem ein Server die Uhrzeit bezieht. In einer Domaene folgen alle dem PDC-Emulator, der seine Zeit von einer externen Quelle holen sollte. Mehr als 5 Minuten Abweichung verhindern die Anmeldung (Kerberos).'
    'Zone'                  = 'Ein Bereich des DNS-Namensraums, den ein DNS-Server verwaltet, z. B. ad.firma.ch. AD-integrierte Zonen werden mit dem AD auf alle DCs repliziert, dateibasierte Zonen liegen nur auf einem Server.'
}

$script:NetHilfeAllgemein = @'
NetSetup richtet auf diesem Windows Server Active Directory, DNS und DHCP ein,
verbindet DHCP mit DNS und prueft und repariert die Einrichtung.
Bedienung:
  - Nummer eingeben und Enter druecken.
  - ? zeigt die Hilfe zum aktuellen Menue, ?3 die Hilfe zu Punkt 3, G das Glossar.
  - Bei Eingaben steht der Vorschlag in eckigen Klammern: Enter uebernimmt ihn.
  - ! bricht eine Eingabe ab, 0 geht ein Menue zurueck.
Sicherheitsregeln:
  - NetSetup schaut immer zuerst nach (Bestandsaufnahme) und aendert nie ungefragt.
  - Vor jeder Aenderung siehst du Vorher und Nachher und bestaetigst mit j.
  - Gefaehrliche Aenderungen (z. B. DC heraufstufen, Zone loeschen, IP aendern)
    erstellen vorher ein Backup und verlangen den Servernamen als Bestaetigung.
  - Jede Aenderung wird geloggt und kann rueckgaengig gemacht werden.
  - Im Probelauf (Einstellungen) wird nur angezeigt, nichts geaendert.
  - Kennwoerter werden nie gespeichert oder ins Log geschrieben.
Daten:
  - Alles liegt im Datenordner (Standard C:\NetSetup): Config, Logs, Backups,
    Berichte, Rueckgaengig, Vorlagen und das Script selbst (NetSetup.ps1).
Ohne Menue (z. B. geplante Aufgabe):
  powershell.exe -ExecutionPolicy Bypass -File C:\NetSetup\NetSetup.ps1 -Task Health
  Moegliche Aufgaben: Health (Pruefung + Bericht), Report, Backup, Resume.
'@

function Show-NetGlossary {
    <#
    .SYNOPSIS
        Zeigt das Glossar, optional gefiltert nach einem Suchbegriff.
    #>
    param([string]$Suche)
    Write-NetTitle -Titel 'Glossar'
    $gefunden = 0
    foreach ($begriff in $script:NetGlossar.Keys) {
        $text = $script:NetGlossar[$begriff]
        if ($Suche -and ($begriff -notlike "*$Suche*") -and ($text -notlike "*$Suche*")) { continue }
        Write-Host ('  ' + $begriff) -ForegroundColor White
        Write-NetText -Text ('    ' + $text)
        $gefunden++
    }
    if ($gefunden -eq 0) { Write-Log -Level Warn -Message "Kein Begriff zu '$Suche' gefunden." }
}

function Find-NetGlossaryTerm {
    $suche = Read-NetText -Frage 'Suchbegriff (z. B. Lease)'
    if ($suche) { Show-NetGlossary -Suche $suche }
}

function Show-NetGeneralHelp {
    Write-NetTitle -Titel 'Bedienung und Sicherheitsregeln'
    Write-NetText -Text $script:NetHilfeAllgemein
}

function Show-NetAbout {
    Write-NetTitle -Titel 'Ueber NetSetup'
    $u = $script:NS.Umgebung
    Write-Host ('  Version        : {0} (Build {1})' -f $script:NS.Version, $script:NS.BuildDatum)
    Write-Host ('  Datenordner    : {0}' -f (Get-NetPath -Name Root))
    Write-Host ('  Logdatei       : {0}' -f $script:NS.LogDatei)
    if ($u) {
        Write-Host ('  Server         : {0}' -f $u.Computername)
        Write-Host ('  Windows        : {0} (Build {1}, {2})' -f $u.OsName, $u.Build, $(if ($u.IstCore) { 'Server Core' } else { 'Desktop' }))
        Write-Host ('  PowerShell     : {0} {1}' -f $u.PsVersion, $u.PsEdition)
        Write-Host ('  Sprache        : {0} (Oberflaeche {1})' -f $u.Sprache, $u.UiSprache)
        Write-Host ('  Umgebung       : {0}' -f $(if ($u.IstIse) { 'PowerShell ISE' } else { 'Konsole' }))
    }
}

function Show-NetHelpMenu {
    $eintraege = @(
        @{ Text = 'Bedienung und Sicherheitsregeln'; Aktion = 'Show-NetGeneralHelp'; Hilfe = 'Wie NetSetup bedient wird und welche Sicherheitsregeln immer gelten.' },
        @{ Text = 'Glossar anzeigen'; Aktion = 'Show-NetGlossary'; Hilfe = 'Alle Fachbegriffe (Lease, Scope, Zone, PTR, ...) in einfachen Worten.' },
        @{ Text = 'Begriff im Glossar suchen'; Aktion = 'Find-NetGlossaryTerm'; Hilfe = 'Sucht einen Begriff im Glossar.' },
        @{ Text = 'Ueber NetSetup (Version, Umgebung)'; Aktion = 'Show-NetAbout'; Hilfe = 'Zeigt Version, Datenordner, Logdatei und die erkannte Umgebung.' }
    )
    Show-NetMenu -Titel 'Hilfe' -Eintraege $eintraege -Einleitung 'Hilfe und Nachschlagewerk. Alles ist im Script enthalten, es braucht kein Internet.'
}
