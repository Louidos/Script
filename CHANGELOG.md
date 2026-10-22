# Changelog

Alle wichtigen Änderungen an NetSetup stehen in dieser Datei.
Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionen nach [Semantic Versioning](https://semver.org/lang/de/).

## Unveröffentlicht

### Hinzugefügt
- Projektstruktur, README, Lizenz und automatische Prüfung (CI) für jede Änderung (#1)
- Einfügbares Script `dist/NetSetup.ps1` mit Hauptmenü, Hilfe zu jedem Punkt, Glossar, Logging und Probelauf; speichert sich selbst nach `C:\NetSetup`, prüft Adminrechte und Windows-Server-Version und bietet eine Desktop-Verknüpfung an (#2)
- Automatische Bestandsaufnahme beim Start mit einer Statuszeile pro Bereich (System, Neustart, AD, Netzwerk, DNS, DHCP, DHCP+DNS, Zeit), Detailansicht, „Vorhandene Konfiguration übernehmen“ und Ersteinrichtungs-Assistent, der Erledigtes überspringt (#3)
- AD einrichten: neue Gesamtstruktur, zusätzlicher DC oder Beitritt, mit Vorprüfungen (feste IP, Servername, DNS-Client, Zeit, Domänen- und NetBIOS-Name, DSRM-Kennwort), Windows-Vorprüfung Test-ADDS vor der Heraufstufung und automatischer Fortsetzung nach dem Neustart (#4)
