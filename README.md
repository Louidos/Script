# NetSetup

Ein einziges PowerShell-Script für Windows Server, das **Active Directory, DNS und DHCP** einrichtet,
DHCP mit DNS verbindet (jeder Client bekommt automatisch A- und PTR-Eintrag), Alltagsaufgaben per Menü
erledigt und Fehler erkennt und repariert. Es braucht **kein Internet und keine Zusatzmodule**:
Inhalt von [`dist/NetSetup.ps1`](dist/NetSetup.ps1) auf dem Server einfügen und starten.

## Was NetSetup kann

- **Bestandsaufnahme** beim Start: erkennt Rolle (Arbeitsgruppe, Mitgliedsserver, DC), Rollen, Dienste,
  Netzwerk, DNS, DHCP, Zeitquelle und zeigt pro Bereich `[OK]`, `[WARN]`, `[FEHLER]` oder `[--]`.
- **Ersteinrichtung** als Assistent: AD → DNS → DHCP → Verbindung → Test, Erledigtes wird übersprungen.
- **Active Directory**: neue Gesamtstruktur, zusätzlicher DC oder Beitritt – mit Vorprüfungen, Windows-Test
  (Test-ADDS…) und automatischer Fortsetzung nach dem Neustart.
- **DNS**: Zonen, Einträge (A, AAAA, CNAME, MX, SRV, TXT, PTR), Weiterleitungen, Aufräumen alter Einträge.
- **DHCP**: Scopes, Optionen, Reservierungen, Leases, mehrere Netze, Failover.
- **DHCP + DNS verbinden** mit Dienstkonto und Prüfung aller Leases.
- **Doktor**: 39 Prüfungen, verständliche Erklärung, Reparatur je nach Stufe.
- **Backup, Wiederherstellen, Rückgängig, Serverumzug, CSV-Import und Berichte** (HTML/CSV).
- **Erweitert** (standardmässig aus): DNSSEC, Split-Brain, DHCP-Richtlinien, DNS-Sperrliste, DHCPv6.
- **Hilfe zu jedem Menüpunkt** (`?`) und ein **Glossar** (`G`) – alles im Script, auf Deutsch.

## Einfügen – Schritt für Schritt

Voraussetzung: Windows Server 2016, 2019, 2022 oder 2025 (Desktop oder Server Core, Deutsch oder Englisch)
und ein Konto mit Administratorrechten.

### Variante 1: PowerShell ISE (empfohlen)

1. Auf dem Server das **Startmenü** öffnen und „**Windows PowerShell ISE**“ eintippen.
2. Mit der **rechten Maustaste** auf „Windows PowerShell ISE“ klicken → **Als Administrator ausführen** → Ja.
3. In der ISE oben **Datei → Neu** wählen (oder Strg+N). Es öffnet sich ein leeres, weisses Feld.
4. Hier auf GitHub die Datei [`dist/NetSetup.ps1`](dist/NetSetup.ps1) öffnen, oben rechts auf
   „Raw“ bzw. „Copy raw file“ klicken und **alles** kopieren (Strg+A, Strg+C).
5. In der ISE in das weisse Feld klicken und **einfügen** (Strg+V).
6. **F5** drücken (oder den grünen Pfeil). NetSetup startet unten im blauen Bereich.

### Variante 2: PowerShell-Konsole

1. „**Windows PowerShell**“ mit rechter Maustaste → **Als Administrator ausführen**
   (Server Core: im schwarzen Fenster `powershell` eingeben und Enter drücken).
2. Den kompletten Inhalt von `dist/NetSetup.ps1` kopieren.
3. Im PowerShell-Fenster **Strg+V** drücken (oder rechte Maustaste) und danach **Enter**.

### Variante 3: als Datei

1. Inhalt als `NetSetup.ps1` speichern, z. B. nach `C:\NetSetup\NetSetup.ps1`.
2. PowerShell als Administrator öffnen und eingeben:
   `powershell.exe -ExecutionPolicy Bypass -File C:\NetSetup\NetSetup.ps1`

Beim ersten Start fragt NetSetup nach dem Datenordner (Enter = `C:\NetSetup`), speichert sich dort selbst
und bietet eine **Desktop-Verknüpfung „NetSetup“** an – ab dann genügt ein Doppelklick.

Ohne Menü (z. B. für eine geplante Aufgabe): `… NetSetup.ps1 -Task Health` (bzw. `Report`, `Backup`, `Resume`).

## Sicherheitsregeln

- NetSetup **schaut zuerst nach** und ändert nie ungefragt; zweimal ausführen erzeugt keine Duplikate.
- Jede Änderung zeigt **Vorher/Nachher** und fragt `j/n`.
- **Gefährliches** (DC heraufstufen, Rolle entfernen, Zone/Scope löschen, IP ändern, Wiederherstellen) erstellt
  vorher ein Backup und verlangt den **Servernamen** als Bestätigung.
- Jede Änderung wird **geloggt** und kann **rückgängig** gemacht werden.
- **Probelauf** (Einstellungen oder `-WhatIf`): alles anzeigen, nichts ändern.
- **Kennwörter** werden nie gespeichert oder geloggt.

Mehr im [Handbuch](docs/handbuch.md) (alle Menüpunkte, typische Abläufe, Glossar) und im
[Testplan](docs/testplan.md).

## Projektstand

Alle geplanten Funktionen sind umgesetzt und automatisch getestet (Pester mit Stubs, CI auf Windows PowerShell 5.1,
inklusive Start des fertigen Scripts als Datei und als eingefügter Text). Tests auf echten Servern nach
[docs/testplan.md](docs/testplan.md) stehen noch aus. Änderungen: [CHANGELOG.md](CHANGELOG.md).

## Aufbau des Repos

| Ordner | Inhalt |
|---|---|
| `src/` | Quellcode, eine Datei pro Thema (core, ui, inventar, ad, dns, dhcp, integration, doktor, wartung, erweitert) |
| `src/checks/` | Prüfungen des Doktors, eine Datei pro Prüfung |
| `scripts/` | Build, Qualitätsprüfung, Handbuch-Aktualisierung, PSScriptAnalyzer-Einstellungen |
| `dist/` | `NetSetup.ps1` – die fertige Einzeldatei (nur per Build erzeugt) |
| `tests/` | Pester-Tests mit Stub-Funktionen für alle Server-Cmdlets |
| `docs/` | Handbuch und Testplan |
| `config/` | Beispiel-Konfiguration und Beispiel-CSVs |

## Entwicklung

```powershell
./scripts/Build-NetSetup.ps1            # baut dist/NetSetup.ps1 aus src/
./scripts/Build-NetSetup.ps1 -Check     # prüft, ob dist aktuell ist
./scripts/Test-NetSetupQualitaet.ps1    # ASCII, Tabs, Parser, Verbotsliste
./scripts/Update-Handbuch.ps1           # Menüpunkte und Glossar ins Handbuch übernehmen
Invoke-Pester -Path tests -CI
Invoke-ScriptAnalyzer -Path src -Recurse -Settings scripts/PSScriptAnalyzerSettings.psd1
```

`dist/NetSetup.ps1` wird nie von Hand bearbeitet. Eine neue Doktor-Prüfung ist eine neue Datei in `src/checks/`
(plus Testfälle in `tests/Doktor.Tests.ps1`).

## Lizenz

MIT, siehe [LICENSE](LICENSE).
