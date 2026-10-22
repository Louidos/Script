# Hauptmenue mit allen geplanten Punkten. Noch nicht gebaute Punkte erscheinen als "kommt noch".

function Get-NetMainMenuEntry {
    return @(
        @{
            Text   = 'Ersteinrichtung (Assistent)'
            Aktion = 'Start-NetFirstSetup'
            Hilfe  = "Fuehrt Schritt fuer Schritt durch die komplette Einrichtung: AD -> DNS -> DHCP -> Verbindung DHCP/DNS -> Test.`nNetSetup erkennt, was schon erledigt ist, und ueberspringt es. Ideal fuer einen neuen Server."
        },
        @{
            Text   = 'Bestandsaufnahme (Zustand des Servers)'
            Aktion = 'Show-NetInventoryMenu'
            Hilfe  = "Zeigt, was auf dem Server schon eingerichtet ist: Rolle, Funktionen, Dienste, Netzwerk, DNS, DHCP, Zeit.`nNur lesend. Kann gefundene DNS-/DHCP-Einstellungen in die NetSetup-Konfiguration uebernehmen."
        },
        @{
            Text   = 'Active Directory'
            Aktion = 'Show-NetAdMenu'
            Hilfe  = "Domaene anzeigen, neue Gesamtstruktur erstellen, Domaene beitreten oder zusaetzlicher Domaenencontroller werden.`nMit Vorpruefungen (feste IP, Hostname, DNS, Zeit) und automatischer Fortsetzung nach dem Neustart."
        },
        @{
            Text   = 'DNS'
            Aktion = 'Show-NetDnsMenu'
            Hilfe  = "Zonen, Eintraege (A, AAAA, CNAME, MX, SRV, TXT, PTR), Weiterleitungen, Aufraeumen alter Eintraege (Aging/Scavenging) und Abhoer-Adressen verwalten.`nUeblich: AD-integrierte Zone fuer die Domaene, Reverse-Zone fuer jedes Netz, Weiterleitung an Quad9 oder Cloudflare."
        },
        @{
            Text   = 'DHCP'
            Aktion = 'Show-NetDhcpMenu'
            Hilfe  = "DHCP-Rolle einrichten, autorisieren, Scopes (Adressbereiche) mit Optionen anlegen, Reservierungen, Leases und Failover verwalten.`nUeblich: Lease-Dauer 8 Tage, Router (003), DNS-Server = die DCs (006), Domaene (015)."
        },
        @{
            Text   = 'DHCP + DNS verbinden'
            Aktion = 'Show-NetIntegrationMenu'
            Hilfe  = "Sorgt dafuer, dass jeder DHCP-Client automatisch einen A- und PTR-Eintrag im DNS bekommt und alte Eintraege wieder verschwinden.`nRichtet bei Bedarf ein Dienstkonto (svc-dhcpdns) ein und prueft, ob alle Leases im DNS stehen."
        },
        @{
            Text   = 'Doktor (pruefen und reparieren)'
            Aktion = 'Show-NetDoctorMenu'
            Hilfe  = "Prueft Rechte, Rollen, AD, Netzwerk, DNS und DHCP und zeigt verstaendlich, was falsch ist.`nHarmloses wird automatisch repariert (abschaltbar), alles andere wird einzeln angeboten."
        },
        @{
            Text   = 'Berichte'
            Aktion = 'Show-NetReportMenu'
            Hilfe  = "Erstellt HTML- und CSV-Berichte: Auslastung der Scopes, freie Adressen, Leases ohne DNS-Eintrag, Doktor-Ergebnis, Aenderungsverlauf.`nDie Berichte oeffnen sich ohne Internet."
        },
        @{
            Text   = 'Backup, Wiederherstellen, Rueckgaengig'
            Aktion = 'Show-NetMaintenanceMenu'
            Hilfe  = "Sichert DHCP, DNS und die Konfiguration, stellt sie wieder her, nimmt Aenderungen zurueck, zieht die Konfiguration auf einen anderen Server um und importiert DNS-Eintraege und Reservierungen aus CSV.`nVor jeder Aenderung wird automatisch gesichert."
        },
        @{
            Text   = 'Erweitert'
            Aktion = 'Show-NetAdvancedMenu'
            Hilfe  = "Fortgeschrittene Funktionen, standardmaessig aus: DNSSEC, Split-Brain-DNS, DHCP-Richtlinien, DNS-Sperrliste, DHCPv6.`nNur verwenden, wenn man weiss, wofuer man sie braucht."
        },
        @{
            Text   = 'Hilfe und Glossar'
            Aktion = 'Show-NetHelpMenu'
            Hilfe  = 'Bedienung, Sicherheitsregeln und alle Fachbegriffe in einfachen Worten.'
        },
        @{
            Text   = 'Einstellungen'
            Aktion = 'Show-NetSettingsMenu'
            Hilfe  = "Probelauf an/aus, automatische Reparatur, Anzahl aufbewahrter Backups, Auswahlfenster, Datenordner und Vorschlagswerte.`nAlles wird in Config\netsetup.json gespeichert (ohne Kennwoerter)."
        }
    )
}

function Show-NetMainMenu {
    $kopf = {
        $u = $script:NS.Umgebung
        if ($u) {
            $art = 'Desktop'
            if ($u.IstCore) { $art = 'Server Core' }
            Write-Host ('  Server: {0}   Windows: {1} ({2})   NetSetup {3}' -f $u.Computername, $u.OsName, $art, $script:NS.Version) -ForegroundColor DarkCyan
        }
        if (Test-NetCommand -Name 'Show-NetStatusLine') { Show-NetStatusLine }
        Write-Host ''
    }
    Show-NetMenu -Titel 'NetSetup - Hauptmenue' -Eintraege (Get-NetMainMenuEntry) -Kopf $kopf -ZurueckText 'Beenden' -Einleitung $script:NetHilfeAllgemein
    Write-Log -Message 'NetSetup beendet. Das Log liegt im Ordner Logs.'
}
