# NetSetup

Ein einziges PowerShell-Script für Windows Server, das Active Directory, DNS und DHCP einrichtet,
DHCP mit DNS verbindet, Alltagsaufgaben per Menü erledigt und Fehler erkennt und repariert.
Das fertige Script ist `dist/NetSetup.ps1` – es wird auf dem Server einfach in PowerShell oder
PowerShell ISE eingefügt und gestartet. Es braucht kein Internet und keine Zusatzmodule.

## Projektstand

Im Aufbau. Die Funktionen entstehen in Gruppen, siehe [CHANGELOG.md](CHANGELOG.md).

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
