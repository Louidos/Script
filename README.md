# NetSetup

Ein einziges PowerShell-Script für Windows Server, das Active Directory, DNS und DHCP einrichtet,
DHCP mit DNS verbindet, Alltagsaufgaben per Menü erledigt und Fehler erkennt und repariert.
Das fertige Script ist `dist/NetSetup.ps1` – es wird auf dem Server einfach in PowerShell oder
PowerShell ISE eingefügt und gestartet. Es braucht kein Internet und keine Zusatzmodule.

## Schnellstart

1. Auf dem Server **Windows PowerShell ISE** (oder Windows PowerShell) mit rechter Maustaste
   → **Als Administrator ausführen** öffnen.
2. Den kompletten Inhalt von [`dist/NetSetup.ps1`](dist/NetSetup.ps1) kopieren.
3. In ISE: in ein neues Script einfügen und **F5** drücken.
   In der Konsole: einfügen (Strg+V oder Rechtsklick) und **Enter** drücken.
4. NetSetup speichert sich beim ersten Start selbst nach `C:\NetSetup\NetSetup.ps1`
   und bietet eine Desktop-Verknüpfung an.

Ohne Menü (z. B. für eine geplante Aufgabe):
`powershell.exe -ExecutionPolicy Bypass -File C:\NetSetup\NetSetup.ps1 -Task Health`

## Projektstand

Im Aufbau. Fertig: Grundgerüst mit Hauptmenü, Hilfe, Glossar, Logging, Probelauf und
Einstellungen; Bestandsaufnahme mit Statusübersicht beim Start; Ersteinrichtungs-Assistent;
Active Directory (neue Gesamtstruktur, zusätzlicher DC, Beitritt) mit Fortsetzung nach Neustart;
DNS (Zonen, Einträge, Weiterleitungen, Aufräumen, Abhör-Adressen);
DHCP (Scopes, Optionen, Reservierungen, Leases, Failover); DHCP trägt automatisch in DNS ein;
Doktor mit Prüfkatalog und Reparatur, `-Task Health` für geplante Prüfungen;
Backup, Wiederherstellen, Rückgängig, Serverumzug, CSV-Import und Berichte;
Erweitert (DNSSEC, Split-Brain, DHCP-Richtlinien, Sperrliste, DHCPv6).
Die übrigen Menüpunkte sind als „kommt noch“ markiert.
Details siehe [CHANGELOG.md](CHANGELOG.md).

## Entwicklung

```powershell
./scripts/Build-NetSetup.ps1            # baut dist/NetSetup.ps1 aus src/
./scripts/Build-NetSetup.ps1 -Check     # prüft, ob dist aktuell ist
./scripts/Test-NetSetupQualitaet.ps1    # ASCII, Tabs, Parser, Verbotsliste
Invoke-Pester -Path tests -CI
Invoke-ScriptAnalyzer -Path src -Recurse -Settings scripts/PSScriptAnalyzerSettings.psd1
```

`dist/NetSetup.ps1` wird nie von Hand bearbeitet, sondern immer per Build erzeugt und committet.

## Aufbau des Repos

| Ordner | Inhalt |
|---|---|
| `src/` | Quellcode, eine Datei pro Thema |
| `src/checks/` | Prüfungen des Doktors, eine Datei pro Prüfung |
| `scripts/` | Build und Hilfsskripte |
| `dist/` | `NetSetup.ps1` – die fertige Einzeldatei (nur per Build erzeugt) |
| `tests/` | Pester-Tests mit Stub-Funktionen |
| `docs/` | Handbuch, Glossar, Testplan |
| `config/` | Beispiel-Konfiguration und Beispiel-CSVs |

## Lizenz

MIT, siehe [LICENSE](LICENSE).
