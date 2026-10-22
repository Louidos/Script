# Changelog

Alle wichtigen Änderungen an NetSetup stehen in dieser Datei.
Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## Unveröffentlicht

## 0.1.0 – 2026-10-22

### Hinzugefügt
- Projektstruktur, README, Lizenz und automatische Prüfung (CI) für jede Änderung (#1)
- Einfügbares Script `dist/NetSetup.ps1` mit Hauptmenü, Hilfe zu jedem Punkt, Glossar, Logging und Probelauf; speichert sich selbst nach `C:\NetSetup`, prüft Adminrechte und Windows-Server-Version und bietet eine Desktop-Verknüpfung an (#2)
- Automatische Bestandsaufnahme beim Start mit einer Statuszeile pro Bereich (System, Neustart, AD, Netzwerk, DNS, DHCP, DHCP+DNS, Zeit), Detailansicht, „Vorhandene Konfiguration übernehmen“ und Ersteinrichtungs-Assistent, der Erledigtes überspringt (#3)
- AD einrichten: neue Gesamtstruktur, zusätzlicher DC oder Beitritt, mit Vorprüfungen (feste IP, Servername, DNS-Client, Zeit, Domänen- und NetBIOS-Name, DSRM-Kennwort), Windows-Vorprüfung Test-ADDS vor der Heraufstufung und automatischer Fortsetzung nach dem Neustart (#4)
- DNS verwalten: Zonen (AD-integriert oder dateibasiert), dynamische Updates, fehlende Reverse-Zonen, Einträge A/AAAA/CNAME/MX/SRV/TXT/PTR mit Duplikat- und Konfliktprüfung, Suche, Weiterleitungen (Quad9, Cloudflare, Router) und bedingte Weiterleitungen, Aufräumen alter Einträge mit „nur melden“, Abhör-IP-Adressen und DNS-Assistent (#5)
- DHCP verwalten: Rolle mit Nachkonfiguration, Autorisierung im AD, Bindungen, Scope-Assistent mit Prüfung der Bereiche und Hinweis auf DHCP-Relay, Superscopes, Zusatzoptionen (NTP, PXE, DNS-Suchliste nach RFC 3397), Reservierungen (auch aus einem Lease), Leases, Konflikterkennung und Failover-Assistent (#6)
- DHCP trägt Clients automatisch in DNS ein (A und PTR, Löschen bei Lease-Ablauf), mit Dienstkonto svc-dhcpdns, Zonen- und Aufräum-Prüfung, deutlicher Warnung bei DHCP auf DC ohne Zugangsdaten und Prüfung aller Leases gegen DNS mit Ursache und Nachtragen (#7)
- Doktor: erkennt falsch installierte Rollen, Netzwerk-, AD-, DNS- und DHCP-Fehler (39 Prüfungen, u. a. Rechte, Zeit, Dienste, Freigaben, SRV-Einträge, Firewall nach Port, fremde DHCP-Server, Auslastung, Optionen, Zugangsdaten) und repariert sie je nach Stufe; Harmloses automatisch (abschaltbar), alles andere einzeln, danach erneute Prüfung (#8)
- Backup (DHCP, DNS, Konfiguration, Netzwerk) automatisch vor jeder Änderung mit Aufbewahrung der letzten 20, Wiederherstellen, Rückgängig aus dem Verlauf, Serverumzug per Paket, CSV-Massenimport mit Vorprüfung (alles oder nichts), HTML- und CSV-Berichte ohne Internet und optionale tägliche Prüfung als geplante Aufgabe (#9)
- Menü „Erweitert“ mit DNSSEC, Split-Brain-DNS, DHCP-Richtlinien, DNS-Sperrliste und DHCPv6 – standardmässig aus, mit Hilfe, Warnung und Rücknahme (#10)
- Handbuch mit allen Menüpunkten, typischen Abläufen und Glossar (gleiche Texte wie im Script), Testplan für echte Server und ausführliche Anleitung zum Einfügen im README (#11)

### Behoben
- Fehler der Server-Cmdlets (DNS, DHCP, Netzwerk) werden immer abgefangen und verständlich gemeldet statt rot ausgegeben (#8)
- Eingaben brechen nach 25 ungültigen Versuchen ab statt endlos zu fragen (#9)
