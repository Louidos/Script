# NetSetup – Testplan für echte Server

Die automatischen Tests (Pester mit Stubs, CI auf Windows PowerShell 5.1) prüfen die Logik. Ob NetSetup auf
echten Servern richtig arbeitet, zeigt nur dieser manuelle Testplan auf virtuellen Maschinen (Hyper-V, VMware
o. ä.). Vor jedem Test einen **Snapshot** der VM anlegen, damit der Ausgangszustand wiederherstellbar ist.

## Testumgebung

| VM | Betriebssystem | Sprache | Oberfläche | Rolle zu Beginn |
|---|---|---|---|---|
| VM1 | Windows Server 2025 | Deutsch | Desktop | Arbeitsgruppe, IP per DHCP, keine Rollen |
| VM2 | Windows Server 2022 | Englisch | Desktop | DC mit DNS (ad.test.ch), kein DHCP |
| VM3 | Windows Server 2019 | Deutsch | Desktop | DC mit DNS und fertig eingerichtetem DHCP |
| VM4 | Windows Server 2016 | Englisch | Server Core | Arbeitsgruppe |
| VM5 | Windows Server 2022 | Deutsch | Desktop | Mitgliedsserver, Rolle AD-Domain-Services installiert, nicht heraufgestuft; DHCP ohne Nachkonfiguration |
| VM6 | Windows 11 | Deutsch | Desktop | Arbeitsplatz (Gegenprobe) |

Alle VMs in einem internen virtuellen Switch **ohne Internetzugang** (Test „ohne Internet“). Für die
Weiterleitungstests einmal zusätzlich mit Internetzugang.

Ergebnis pro Test: ✅ bestanden / ❌ Fehler (mit Logauszug aus `C:\NetSetup\Logs`) / ➖ nicht anwendbar.

## A. Einfügen und Start (auf VM1, VM4, VM6)

| Nr | Schritt | Erwartet |
|---|---|---|
| A1 | ISE als Administrator, Inhalt von `dist/NetSetup.ps1` einfügen, F5 | Titel, Datenordner-Frage, Bestandsaufnahme, Hauptmenü |
| A2 | Konsole als Administrator, Inhalt mit Strg+V einfügen, Enter | wie A1; keine Fehlermeldung beim Einfügen |
| A3 | Konsole, Einfügen per Rechtsklick (ohne PSReadLine: `Remove-Module PSReadLine` vorher) | wie A1 (leere Zeilen stören nicht) |
| A4 | Als Datei speichern, `powershell.exe -ExecutionPolicy Bypass -File …` | wie A1 |
| A5 | Ohne Adminrechte starten | Hinweis + Angebot UAC-Neustart; bei Nein verständliche Anleitung, kein roter Fehler |
| A6 | Auf VM6 (Windows 11) starten | verständlicher Abbruch „kein Windows Server“ |
| A7 | Erster Start: Datenordner `D:\NetSetupDaten` wählen, dann neu starten | Ordner wird gemerkt, `NetSetup.ps1` dort gespeichert, Rechte nur Administratoren/SYSTEM |
| A8 | Desktop-Verknüpfung anlegen und starten | startet als Administrator (UAC-Abfrage) |
| A9 | `-Task Health` aus einer normalen Konsole | läuft ohne Fragen, Bericht in `Berichte` |
| A10 | Hilfe `?`, `?3`, `G` in mehreren Menüs | Texte verständlich, ASCII, keine Fehler |

## B. Frischer Server in der Arbeitsgruppe (VM1, VM4)

| Nr | Schritt | Erwartet |
|---|---|---|
| B1 | Start | Übersicht: AD `[--]`, DNS `[--]`, DHCP `[--]`, Netzwerk `[WARN]` (IP per DHCP) |
| B2 | Ersteinrichtung starten | Plan mit 5 offenen Schritten |
| B3 | AD → neue Gesamtstruktur | Vorprüfung schlägt feste IP vor (Stufe Gefährlich, Warnung Remotedesktop) und Umbenennung (`WIN-…`) mit Neustart |
| B4 | Nach Neustart anmelden | NetSetup startet automatisch (RunOnce) und setzt fort |
| B5 | Domäne `test` eingeben | abgelehnt (Single-Label); `test.local` → Warnung; `ad.test.ch` akzeptiert |
| B6 | Test-ADDSForestInstallation | Ergebnis verständlich; nur bei Erfolg Frage nach Servername |
| B7 | Heraufstufen, Neustart | Fortsetzung: DNS-Client auf eigene IP + 127.0.0.1, Dienste `[OK]`, Angebot PDC-Zeitquelle |
| B8 | Assistent: DNS, DHCP, Verbindung, Doktor | alle Schritte `[OK]`; Doktor ohne Fehler (außer Weiterleitung ohne Internet `[WARN]`) |
| B9 | Ersteinrichtung erneut starten | alles erledigt, keine Änderungen, keine Duplikate |
| B10 | Variante „ohne AD weiter“ | DNS-Zonen dateibasiert, DHCP ohne Autorisierung, keine Fehler |

## C. DC nur mit DNS (VM2)

| Nr | Schritt | Erwartet |
|---|---|---|
| C1 | Start | AD `[OK]`, DNS `[OK]`/`[WARN]`, DHCP `[--]` |
| C2 | Bestandsaufnahme → „Vorhandene Konfiguration übernehmen“ | nur `Config\netsetup.json` ändert sich |
| C3 | Ersteinrichtung | AD und DNS übersprungen, DHCP-Assistent startet |
| C4 | Scope mit Bereich .200–.100 | abgelehnt, erneute Eingabe |
| C5 | Scope .100–.199, Lease 8, Router, DNS = DC | Scope aktiv, Optionen 003/006/015 gesetzt |
| C6 | DHCP + DNS verbinden, Dienstkonto anlegen | Konto `svc-dhcpdns`, Zugangsdaten gesetzt; Übersicht `DHCP + DNS [OK]` |
| C7 | Client-VM per DHCP starten | Lease, A- und PTR-Eintrag im DNS; Prüfung „Leases ohne DNS“ leer |
| C8 | DNS-Einträge A/CNAME/MX/SRV/TXT anlegen, zweimal | beim zweiten Mal „existiert bereits“ |
| C9 | Weiterleitungen setzen (ohne Internet) | Warnung „antwortet nicht“, Einstellung trotzdem gesetzt |
| C10 | Aging-Assistent „nur melden“ | Liste/CSV, nichts gelöscht |

## D. DC mit fertigem DHCP (VM3)

| Nr | Schritt | Erwartet |
|---|---|---|
| D1 | Start | alle Bereiche korrekt erkannt (Scopes, Optionen, Reservierungen, Auslastung) |
| D2 | Doktor „Nur prüfen“ | keine Änderungen, plausible Ergebnisse |
| D3 | Reservierung aus Lease | in einem Schritt, optional DNS-Eintrag |
| D4 | Reservierung im Ausschluss | abgelehnt mit Begründung |
| D5 | Backup, Scope löschen (Gefährlich), DHCP wiederherstellen | Scope wieder da |
| D6 | Änderung rückgängig machen | alter Zustand |
| D7 | CSV-Import mit einer fehlerhaften Zeile | Fehler gemeldet, nichts importiert |
| D8 | Gesamtbericht | HTML öffnet ohne Internet korrekt, CSV-Dateien vorhanden |
| D9 | Failover zu nicht vorhandenem Partner | sauberer Abbruch, keine Änderung |
| D10 | Serverumzug: Export auf VM3, Import auf VM2 | Scopes/Zonen übernommen, vorhandene nicht überschrieben |
| D11 | Geplante Aufgabe einrichten, Aufgabe von Hand starten | Bericht in `Berichte` |

## E. Falsch installierte Rollen (VM5)

| Nr | Schritt | Erwartet |
|---|---|---|
| E1 | Start | AD `[WARN]` „installiert, aber nicht heraufgestuft“, DHCP `[WARN]` Nachkonfiguration fehlt |
| E2 | Doktor | O03 und O08 gemeldet; Reparatur O08 setzt ConfigurationState = 2 (Server-Manager zeigt keine Warnung mehr) |
| E3 | Reparatur O03 → Rolle entfernen | Backup, Servername, Entfernen, Neustart-Angebot |
| E4 | DNS-Dienst stoppen, Doktor | automatisch gestartet (Stufe Automatisch) |
| E5 | Auto-Reparatur in den Einstellungen aus, Dienst stoppen, Doktor | einzeln angeboten, nicht automatisch |
| E6 | Probelauf an, Doktor mit Fehlern | „[PROBELAUF] Würde ausführen“, nichts geändert |
| E7 | DNS-Client auf 8.8.8.8 stellen, Doktor | N02 `[FEHLER]`, Reparatur stellt DCs ein |
| E8 | Firewall-Regeln für DNS deaktivieren | N04 meldet Port 53 (Prüfung nach Port), Reparatur legt Regel „NetSetup DNS“ an |
| E9 | Zweiten DHCP-Server (z. B. Router-VM) ins Netz | D08 meldet den fremden Server |

## F. Server Core (VM4)

| Nr | Schritt | Erwartet |
|---|---|---|
| F1 | Start in `powershell` | Hinweis Server Core, keine Desktop-Verknüpfung angeboten |
| F2 | Auswahl in Listen | Nummernliste statt Out-GridView |
| F3 | Kompletter Ablauf B2–B8 | wie auf Desktop |

## G. Sprachen und Versionen

| Nr | Schritt | Erwartet |
|---|---|---|
| G1 | Alle Tests auf deutschem und englischem Windows | gleiche Ergebnisse (keine Auswertung übersetzter Texte) |
| G2 | Server 2016 | höchste Funktionsebene „Windows Server 2016“ |
| G3 | Server 2025 | höchste Funktionsebene „Windows Server 2025“ |
| G4 | Ohne Internet: alle Abläufe | keine Downloads, nur Warnungen bei Weiterleitungen |

## Abschluss

- Logs (`C:\NetSetup\Logs`) auf `[FEHLER]` und Kennwörter durchsuchen (es dürfen keine Kennwörter vorkommen).
- Gefundene Fehler als Issue mit der Vorlage „Fehler melden“ anlegen (Version, Server, Sprache, Logauszug).
