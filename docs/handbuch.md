# NetSetup – Handbuch

NetSetup richtet auf einem Windows Server Active Directory, DNS und DHCP ein, verbindet DHCP mit DNS,
erledigt Alltagsaufgaben per Menü und erkennt und repariert Fehler. Alles steckt in einer einzigen Datei
(`dist/NetSetup.ps1`); es braucht weder Internet noch Zusatzmodule.

Dieses Handbuch beschreibt Start, Bedienung, typische Abläufe, alle Menüpunkte und das Glossar.
Die Abschnitte **Menüpunkte** und **Glossar** werden mit `scripts/Update-Handbuch.ps1` direkt aus dem
Script übernommen – die Texte sind deshalb identisch mit der Hilfe (`?`) im Script. Wie im Script sind
Umlaute dort als ae/oe/ue geschrieben.

## Inhalt

1. [Starten](#1-starten)
2. [Bedienung](#2-bedienung)
3. [Sicherheit: Stufen, Probelauf, Backup, Rückgängig](#3-sicherheit-stufen-probelauf-backup-rückgängig)
4. [Typische Abläufe](#4-typische-abläufe)
5. [Ohne Menü: -Task](#5-ohne-menü--task)
6. [Daten und Dateien](#6-daten-und-dateien)
7. [Wenn etwas nicht klappt](#7-wenn-etwas-nicht-klappt)
8. [Menüpunkte](#8-menüpunkte)
9. [Glossar](#9-glossar)

## 1. Starten

Voraussetzungen: Windows Server 2016, 2019, 2022 oder 2025 (Desktop oder Server Core, Deutsch oder Englisch),
Windows PowerShell 5.1 (ist dabei), ein Konto mit Administratorrechten auf dem Server.

**a) PowerShell ISE (empfohlen)**

1. Startmenü → „Windows PowerShell ISE“ mit rechter Maustaste → **Als Administrator ausführen**.
2. Datei → Neu (Strg+N).
3. Den kompletten Inhalt von `dist/NetSetup.ps1` einfügen (Strg+V).
4. **F5** drücken.

**b) PowerShell-Konsole**

1. „Windows PowerShell“ mit rechter Maustaste → **Als Administrator ausführen**
   (auf Server Core: in der Eingabeaufforderung `powershell` eingeben).
2. Den kompletten Inhalt einfügen – **Strg+V** (schnell) oder Rechtsklick – und **Enter** drücken.

**c) Als Datei**

1. Inhalt als `NetSetup.ps1` speichern (z. B. `C:\NetSetup\NetSetup.ps1`).
2. In einer Administrator-Konsole: `powershell.exe -ExecutionPolicy Bypass -File C:\NetSetup\NetSetup.ps1`

**Beim ersten Start** fragt NetSetup nach dem Datenordner (Vorschlag `C:\NetSetup`), speichert sich selbst als
`C:\NetSetup\NetSetup.ps1` und bietet eine Desktop-Verknüpfung „NetSetup“ an, die als Administrator startet.
Danach zeigt es die **Bestandsaufnahme** (eine Zeile pro Bereich) und das **Hauptmenü**.

Ohne Administratorrechte bietet NetSetup an, sich per UAC neu zu starten. Auf Windows 10/11 bricht es mit
einer verständlichen Meldung ab (AD, DNS-Server und DHCP-Server gibt es nur auf Windows Server).

## 2. Bedienung

| Eingabe | Wirkung |
|---|---|
| Nummer + Enter | Menüpunkt ausführen |
| `?` | Hilfe zum ganzen Menü |
| `?3` | Hilfe zu Punkt 3 |
| `G` | Glossar |
| `0` | zurück bzw. beenden |
| Enter bei einer Frage | Vorschlag in `[eckigen Klammern]` übernehmen |
| `!` bei einer Frage | Eingabe abbrechen |
| `j` / `n` | Ja / Nein (`[J/n]` = Ja ist Vorschlag, `[j/N]` = Nein ist Vorschlag) |

Statusanzeigen: `[OK]` in Ordnung, `[WARN]` sollte angeschaut werden, `[FEHLER]` muss behoben werden,
`[--]` trifft hier nicht zu bzw. nicht installiert. Mit Desktop-Oberfläche erscheinen Listen auf Wunsch in einem
Auswahlfenster (Out-GridView), auf Server Core als Nummernliste.

## 3. Sicherheit: Stufen, Probelauf, Backup, Rückgängig

- **Zuerst erkennen, dann handeln**: Jeder Ablauf beginnt mit der Bestandsaufnahme. Vorhandenes wird nie
  stillschweigend überschrieben; zweimal ausführen erzeugt keine Duplikate.
- **Jede Änderung** zeigt Vorher und Nachher und fragt `Ausführen? [j/N]`.
- **Drei Stufen**
  - *Automatisch*: harmlos (z. B. gestoppten Dienst starten) – ohne Frage, nur im Doktor und abschaltbar.
  - *Bestätigen*: Vorher/Nachher und j/n.
  - *Gefährlich*: zusätzlich automatisches Backup und den **Servernamen eintippen**
    (z. B. DC heraufstufen, Rolle entfernen, Zone oder Scope löschen, feste IP setzen, Wiederherstellen).
    Bei IP-Änderungen warnt NetSetup, dass Remotedesktop getrennt werden kann.
- **Probelauf** (Einstellungen oder Start mit `-WhatIf`): alles wird geprüft und angezeigt, nichts geändert –
  auch nicht durch den Doktor.
- **Backup**: vor jeder Änderung automatisch (DHCP, DNS, Konfiguration, Netzwerk); die letzten 20 bleiben.
- **Rückgängig**: jede Änderung merkt sich ihre Gegenaktion (Menü Backup → Rückgängig).
- **Kennwörter** (DSRM, Dienstkonto, Failover-Geheimnis) werden nur verdeckt eingegeben, nie gespeichert
  und nie ins Log geschrieben.

## 4. Typische Abläufe

**Neuer Server, noch keine Domäne**

1. Hauptmenü → *Ersteinrichtung*. Der Assistent schlägt die Schritte vor und überspringt Erledigtes.
2. *Active Directory* → „Neue Gesamtstruktur“: feste IP, Servername (z. B. DC01, mit Neustart),
   Domänenname (z. B. `ad.firma.ch`), NetBIOS-Name, DSRM-Kennwort. Windows prüft mit Test-ADDSForestInstallation;
   erst dann wird nach Eingabe des Servernamens heraufgestuft. Nach dem Neustart setzt NetSetup automatisch fort.
3. *DNS*: Reverse-Zone für das Netz, Weiterleitungen (Quad9/Cloudflare/Router), Aufräumen 7 + 7 Tage.
4. *DHCP*: Rolle, Nachkonfiguration, Autorisierung, Scope (z. B. .100 bis .199, Lease 8 Tage, Router, DNS = DC).
5. *DHCP + DNS verbinden*: immer eintragen, Dienstkonto `svc-dhcpdns`.
6. *Doktor*: alles prüfen.

**DC mit DNS, DHCP soll dazukommen** – Ersteinrichtung starten: AD und DNS sind erledigt, es geht direkt mit DHCP weiter.

**Bestehende Umgebung prüfen** – *Doktor* → „Alles prüfen und reparieren“. Für einen Bericht ohne Änderungen
„Nur prüfen“ oder *Berichte* → „Gesamtbericht“.

**Viele Reservierungen oder DNS-Einträge** – *Backup …* → „Vorlagen anlegen“, CSV in `C:\NetSetup\Vorlagen`
ausfüllen, dann „CSV-Import“. Fehlerhafte Zeilen werden vorher gemeldet; dann wird nichts importiert.

**Server ersetzen** – auf dem alten Server *Backup …* → „Serverumzug: Paket exportieren“, Ordner auf den neuen
Server kopieren, dort „Paket importieren“. Danach den alten DHCP-Server abschalten und den Doktor ausführen.

**Etwas ging schief** – *Backup …* → *Rückgängig* → „Letzte Änderung rückgängig machen“ oder eine Änderung aus
dem Verlauf wählen. Bei größeren Problemen: DHCP bzw. DNS aus einem Backup wiederherstellen.

**Tägliche Prüfung** – *Backup …* → „Geplante Aufgabe: tägliche Prüfung einrichten“. Ergebnis als HTML im Ordner
`Berichte`.

## 5. Ohne Menü: -Task

```
powershell.exe -ExecutionPolicy Bypass -File C:\NetSetup\NetSetup.ps1 -Task Health
```

| Aufgabe | Wirkung |
|---|---|
| `Health` | Doktor ohne Änderungen, Bericht nach `Berichte` (für die geplante Aufgabe) |
| `Report` | Gesamtbericht (HTML + CSV) |
| `Backup` | Backup von DHCP, DNS, Konfiguration und Netzwerk |
| `Resume` | Fortsetzung nach einem Neustart (trägt NetSetup selbst in RunOnce ein) |

Zusätzlich: `-WhatIf` bzw. `-Probelauf` startet im Probelauf.

## 6. Daten und Dateien

Datenordner (Standard `C:\NetSetup`, nur für Administratoren und SYSTEM zugänglich):

| Ordner/Datei | Inhalt |
|---|---|
| `NetSetup.ps1` | gespeicherte Kopie des Scripts |
| `Config\netsetup.json` | Einstellungen (JSON mit Schema-Version, ohne Kennwörter) |
| `Config\fortsetzung.json` | Stand für die Fortsetzung nach einem Neustart |
| `Logs\` | Logdatei pro Tag und Transcript jeder Sitzung |
| `Backups\` | automatische und manuelle Backups, Umzugspakete |
| `Berichte\` | HTML- und CSV-Berichte |
| `Rueckgaengig\verlauf.json` | Änderungen mit Gegenaktion |
| `Vorlagen\` | Beispiel-CSVs für den Import |

## 7. Wenn etwas nicht klappt

- Jede Fehlermeldung nennt **Ursache** und **nächsten Schritt**; technische Details stehen im Log.
- „Der Befehl … fehlt“: Rolle oder Verwaltungstools sind nicht installiert → im Menü der Rolle installieren.
- „Zugriff verweigert“: PowerShell als Administrator starten; für AD-Änderungen als Domänen-Admin, für die
  DHCP-Autorisierung als Organisations-Admin anmelden.
- „Nicht erreichbar (RPC)“: Dienst, Firewall und Namensauflösung prüfen – der Doktor hilft.
- Nach dem Neustart geht es nicht weiter: NetSetup starten → es bietet die Fortsetzung an
  (oder *Active Directory* → „Unterbrochene Einrichtung fortsetzen“).

## 8. Menüpunkte

Diese Liste wird aus dem Script erzeugt (`scripts/Update-Handbuch.ps1`).

<!-- MENUES:START -->

### NetSetup - Hauptmenue

1. **Ersteinrichtung (Assistent)**
   Fuehrt Schritt fuer Schritt durch die komplette Einrichtung: AD -> DNS -> DHCP -> Verbindung DHCP/DNS -> Test.
   NetSetup erkennt, was schon erledigt ist, und ueberspringt es. Ideal fuer einen neuen Server.

2. **Bestandsaufnahme (Zustand des Servers)**
   Zeigt, was auf dem Server schon eingerichtet ist: Rolle, Funktionen, Dienste, Netzwerk, DNS, DHCP, Zeit.
   Nur lesend. Kann gefundene DNS-/DHCP-Einstellungen in die NetSetup-Konfiguration uebernehmen.

3. **Active Directory**
   Domaene anzeigen, neue Gesamtstruktur erstellen, Domaene beitreten oder zusaetzlicher Domaenencontroller werden.
   Mit Vorpruefungen (feste IP, Hostname, DNS, Zeit) und automatischer Fortsetzung nach dem Neustart.

4. **DNS**
   Zonen, Eintraege (A, AAAA, CNAME, MX, SRV, TXT, PTR), Weiterleitungen, Aufraeumen alter Eintraege (Aging/Scavenging) und Abhoer-Adressen verwalten.
   Ueblich: AD-integrierte Zone fuer die Domaene, Reverse-Zone fuer jedes Netz, Weiterleitung an Quad9 oder Cloudflare.

5. **DHCP**
   DHCP-Rolle einrichten, autorisieren, Scopes (Adressbereiche) mit Optionen anlegen, Reservierungen, Leases und Failover verwalten.
   Ueblich: Lease-Dauer 8 Tage, Router (003), DNS-Server = die DCs (006), Domaene (015).

6. **DHCP + DNS verbinden**
   Sorgt dafuer, dass jeder DHCP-Client automatisch einen A- und PTR-Eintrag im DNS bekommt und alte Eintraege wieder verschwinden.
   Richtet bei Bedarf ein Dienstkonto (svc-dhcpdns) ein und prueft, ob alle Leases im DNS stehen.

7. **Doktor (pruefen und reparieren)**
   Prueft Rechte, Rollen, AD, Netzwerk, DNS und DHCP und zeigt verstaendlich, was falsch ist.
   Harmloses wird automatisch repariert (abschaltbar), alles andere wird einzeln angeboten.

8. **Berichte**
   Erstellt HTML- und CSV-Berichte: Auslastung der Scopes, freie Adressen, Leases ohne DNS-Eintrag, Doktor-Ergebnis, Aenderungsverlauf.
   Die Berichte oeffnen sich ohne Internet.

9. **Backup, Wiederherstellen, Rueckgaengig**
   Sichert DHCP, DNS und die Konfiguration, stellt sie wieder her, nimmt Aenderungen zurueck, zieht die Konfiguration auf einen anderen Server um und importiert DNS-Eintraege und Reservierungen aus CSV.
   Vor jeder Aenderung wird automatisch gesichert.

10. **Erweitert**
   Fortgeschrittene Funktionen, standardmaessig aus: DNSSEC, Split-Brain-DNS, DHCP-Richtlinien, DNS-Sperrliste, DHCPv6.
   Nur verwenden, wenn man weiss, wofuer man sie braucht.

11. **Hilfe und Glossar**
   Bedienung, Sicherheitsregeln und alle Fachbegriffe in einfachen Worten.

12. **Einstellungen**
   Probelauf an/aus, automatische Reparatur, Anzahl aufbewahrter Backups, Auswahlfenster, Datenordner und Vorschlagswerte.
   Alles wird in Config\netsetup.json gespeichert (ohne Kennwoerter).

### Bestandsaufnahme

1. **Bestandsaufnahme neu erfassen (Uebersicht)**
   Liest den aktuellen Zustand des Servers neu ein (nur lesend) und zeigt pro Bereich eine Zeile mit [OK], [WARN], [FEHLER] oder [--].

2. **Bestandsaufnahme im Detail**
   Zeigt alles, was NetSetup erkannt hat: Rolle, Funktionen, Dienste, Netzwerkkarten, DNS-Zonen, DHCP-Scopes, Failover, Zeitquelle.

3. **Vorhandene Konfiguration uebernehmen**
   Schreibt die gefundenen DNS- und DHCP-Einstellungen in die NetSetup-Konfiguration (Config\netsetup.json).
   Am Server wird dabei nichts geaendert. Sinnvoll, wenn DNS/DHCP schon eingerichtet sind.

### Active Directory

1. **Domaene anzeigen**
   Zeigt Domaene, Gesamtstruktur, Funktionsebenen, FSMO-Rollen und alle Domaenencontroller.

2. **AD einrichten (passender Weg)**
   Erkennt die Ausgangslage und bietet den passenden Weg an:
   - Arbeitsgruppe: neue Gesamtstruktur, Beitritt + DC, nur Beitritt oder ohne AD
   - Mitgliedsserver: zusaetzlicher DC oder nur DNS/DHCP
   - DC: zeigt die Domaene
   Mit Vorpruefungen, Test-ADDS vor der Heraufstufung und Fortsetzung nach dem Neustart.

3. **Vorpruefungen anzeigen (ohne Aenderung)**
   Prueft feste IP, Servername, ausstehenden Neustart, DNS-Client, Rolle, Funktionsebene und Zeitquelle und zeigt das Ergebnis an.

4. **Feste IP-Adresse setzen**
   Server brauchen eine feste IP. Stufe gefaehrlich: Remotedesktop kann getrennt werden.
   Ueblich: eine Adresse ausserhalb des DHCP-Bereichs, Gateway = Router, DNS = die DCs.

5. **Server umbenennen**
   Benennt den Server um (z. B. DC01). Vor der Heraufstufung zum DC erledigen. Braucht einen Neustart.

6. **DNS-Client einstellen**
   Welche DNS-Server dieser Server selbst fragt. DC: eigene IP und 127.0.0.1. Mitglied: die DCs. Nie direkt 8.8.8.8 o. ae.

7. **Externe Zeitquelle (PDC) einstellen**
   Der PDC-Emulator gibt die Zeit fuer die ganze Domaene vor und sollte sie von einer externen Quelle (NTP) holen, z. B. ch.pool.ntp.org oder dem Router.

8. **Unterbrochene Einrichtung fortsetzen**
   Falls eine Einrichtung wegen eines Neustarts unterbrochen wurde und nicht automatisch weiterlief: hier fortsetzen oder verwerfen.

### DNS

1. **Uebersicht**
   Zonen, Weiterleitungen, Aufraeumen, Abhoer-Adressen und fehlende Reverse-Zonen auf einen Blick.

2. **DNS einrichten (Assistent)**
   Prueft Rolle, Forward-Zone, dynamische Updates, Reverse-Zonen, Weiterleitungen und Aufraeumen und bietet an, was fehlt. Erledigtes wird uebersprungen.

3. **Zonen**
   Zonen anzeigen, anlegen, dynamische Updates, fehlende Reverse-Zonen, loeschen.

4. **Eintraege**
   Eintraege anzeigen, suchen, anlegen, aendern, loeschen.

5. **Weiterleitungen**
   Weiterleitungen (Quad9, Cloudflare, Router) und bedingte Weiterleitungen. Erklaert auch den Unterschied zu den Stammhinweisen.

6. **Aufraeumen alter Eintraege (Aging/Scavenging)**
   Assistent mit Vorschlag 7 + 7 Tage, Erklaerung zur Lease-Dauer und Modus "nur melden".

7. **Abhoer-IP-Adressen**
   Auf welchen Adressen der DNS-Server antwortet. Empfohlen: alle festen Adressen des Servers.

8. **DNS-Rolle installieren / pruefen**
   Installiert die DNS-Server-Rolle und die Verwaltungstools aus dem lokalen Windows, falls sie fehlen.

### DNS - Zonen

1. **Zonen anzeigen**
   Alle Zonen mit Typ, Speicherung (AD oder Datei) und dynamischen Updates.

2. **Forward-Zone anlegen**
   Zone fuer Namen -> Adressen. Auf einem DC AD-integriert (Replikation Domain oder Forest), sonst als Datei.
   Existiert die Zone schon, passiert nichts.

3. **Reverse-Zone anlegen**
   Zone fuer Adressen -> Namen (PTR) eines Netzes, z. B. 1.168.192.in-addr.arpa fuer 192.168.1.0/24.

4. **Fehlende Reverse-Zonen vorschlagen**
   Prueft das Netz des Servers und alle DHCP-Scopes und schlaegt fehlende Reverse-Zonen vor.

5. **Dynamische Updates einstellen**
   Nur sicher (empfohlen, nur AD-Zonen), sicher und unsicher, oder aus.

6. **Zone loeschen (gefaehrlich)**
   Loescht eine Zone mit allen Eintraegen. Vorher wird automatisch gesichert; der Servername muss eingetippt werden.

### DNS - Eintraege

1. **Eintraege einer Zone anzeigen**
   Listet alle Eintraege einer Zone, mit statisch/dynamisch und Zeitstempel.

2. **Eintrag suchen**
   Sucht einen Namen oder eine Adresse in allen Zonen.

3. **Eintrag anlegen (A, AAAA, CNAME, MX, SRV, TXT, PTR)**
   Legt einen Eintrag an. Vorher wird geprueft, ob es ihn schon gibt (dann passiert nichts) oder ob er mit einem anderen kollidiert.
   A-Eintraege koennen gleich den passenden PTR bekommen.

4. **Eintrag aendern**
   Aendert die Daten eines Eintrags (z. B. neue IP). Vorher/Nachher wird angezeigt, rueckgaengig moeglich.

5. **Eintrag loeschen**
   Loescht genau einen Eintrag. Die Gegenaktion (wieder anlegen) wird gemerkt.

### DNS - Weiterleitungen

1. **Weiterleitungen anzeigen und testen**
   Zeigt die Weiterleitungen und prueft, ob sie antworten. Ohne Internet antworten externe Server nicht - das ist dann normal.

2. **Weiterleitungen setzen**
   Vorschlaege: Quad9 (9.9.9.9), Cloudflare (1.1.1.1) oder der Router.
   Vorher/Nachher wird angezeigt, die alte Einstellung kann rueckgaengig gemacht werden.

3. **Bedingte Weiterleitung anlegen**
   Nur fuer eine bestimmte Domaene an bestimmte DNS-Server weiterleiten (z. B. Partnerfirma).

4. **Bedingte Weiterleitung entfernen**
   Entfernt eine bedingte Weiterleitung (gefaehrlich: vorher Backup, Servername eintippen).

5. **Erklaerung: Weiterleitung oder Stammhinweise?**
   Erklaert den Unterschied zwischen Weiterleitung, Stammhinweisen und bedingter Weiterleitung.

### DNS - Aufraeumen alter Eintraege

1. **Einstellungen anzeigen**
   Zeigt Aging/Scavenging auf Server- und Zonenebene und vergleicht mit der DHCP-Lease-Dauer.

2. **Assistent (Vorschlag: an, 7 + 7 Tage)**
   Aging/Scavenging raeumt alte, automatisch eingetragene DNS-Eintraege auf (z. B. von Laptops,
   die laengst weg sind). Statische Eintraege werden nie geloescht.
     - No-Refresh-Intervall: so lange wird ein frischer Eintrag nicht erneut gestempelt.
     - Refresh-Intervall: danach darf der Client ihn erneuern. Wer in No-Refresh + Refresh nicht
       erneuert, gilt als veraltet und wird beim naechsten Aufraeumen geloescht.
     - Vorschlag: an, 7 + 7 Tage, Aufraeumen alle 7 Tage.
     - Wichtig: No-Refresh + Refresh muss mindestens so lang sein wie die DHCP-Lease-Dauer,
       sonst werden Eintraege aktiver Clients geloescht. Bei 8 Tagen Lease passen 7 + 7 Tage.
     - "Nur melden" zeigt, was geloescht wuerde, ohne etwas zu loeschen.

3. **Nur melden: veraltete Eintraege auflisten**
   Zeigt, welche dynamischen Eintraege beim Aufraeumen geloescht wuerden, und speichert die Liste als CSV. Es wird nichts geloescht.

4. **Aging einer einzelnen Zone**
   Schaltet Aging nur fuer eine Zone ein oder aus.

### DHCP

1. **Uebersicht**
   Autorisierung, Nachkonfiguration, Konflikterkennung, alle Scopes und Failover auf einen Blick.

2. **DHCP einrichten (Assistent)**
   Rolle, Nachkonfiguration, Autorisierung, Bindungen, erster Scope und Optionen - Erledigtes wird uebersprungen.

3. **Rolle installieren und nachkonfigurieren**
   Installiert die DHCP-Rolle aus dem lokalen Windows und fuehrt die Nachkonfiguration aus (Sicherheitsgruppen, ConfigurationState = 2, Dienstneustart).

4. **Im AD autorisieren**
   In einer Domaene vergibt ein DHCP-Server erst nach der Autorisierung Adressen. Dafuer braucht es Organisations-Admins (Enterprise Admins). Ohne Domaene wird uebersprungen.

5. **Bindungen anzeigen**
   Auf welchen Netzwerkkarten der DHCP-Server antwortet.

6. **Bindungen einstellen**
   Nur Karten im Netz der Clients binden.

7. **Scopes**
   Scopes anzeigen, anlegen, Ausschluesse, Optionen, aktivieren/deaktivieren, Superscope, loeschen.

8. **Zusatzoptionen (NTP, PXE, Suchliste)**
   Optionen 042, 066/067 und 119 - standardmaessig aus, auf Server- oder Scope-Ebene.

9. **Reservierungen und Leases**
   Reservierungen anlegen (auch aus einem Lease), pruefen, loeschen; Leases anzeigen, suchen, loeschen; Konflikterkennung.

10. **Failover**
   Zweiter DHCP-Server fuer Ausfallsicherheit: Lastverteilung oder Reserve, Status, Replikation.

### DHCP - Scopes

1. **Scopes anzeigen**
   Alle Scopes mit Bereich, Status, Lease-Dauer, Auslastung, Optionen 003/006/015 und Ausschluessen.

2. **Neuer Scope (Assistent)**
   Name, Netz, Bereich, Ausschluesse, Lease-Dauer (Vorschlag 8 Tage), Router (003), DNS-Server (006, Vorschlag: die DCs), Domaene (015).
   Ungueltige Bereiche werden abgelehnt; fuer andere Netze (VLANs) Hinweis auf DHCP-Relay am Router.

3. **Ausschluss hinzufuegen**
   Adressen im Bereich, die nie vergeben werden (Drucker, Server, Router mit fester IP).

4. **Optionen 003/006/015 aendern**
   Router, DNS-Server und Domaene eines Scopes aendern.

5. **Scope aktivieren/deaktivieren**
   Ein deaktivierter Scope vergibt keine Adressen mehr.

6. **Superscope anlegen**
   Mehrere Scopes im selben physischen Netz zusammenfassen. Fuer getrennte VLANs nicht noetig.

7. **Scope loeschen (gefaehrlich)**
   Loescht einen Scope mit allen Leases und Reservierungen. Vorher automatisches Backup, Servername eintippen.

### DHCP - Zusatzoptionen

1. **Zusatzoption setzen (042, 066, 067, 119)**
   Alle Zusatzoptionen sind standardmaessig aus und nur bei Bedarf noetig.
   042 NTP-Server, 066/067 PXE-Netzwerkboot, 119 DNS-Suchliste (wird bei Bedarf definiert und nach RFC 3397 kodiert).

2. **Zusatzoption entfernen**
   Entfernt eine gesetzte Zusatzoption auf Server- oder Scope-Ebene (rueckgaengig moeglich).

### DHCP - Reservierungen und Leases

1. **Reservierungen anzeigen**
   Alle Reservierungen pro Scope; Reservierungen ausserhalb des Bereichs werden markiert.

2. **Reservierung anlegen**
   Feste Adresse fuer ein Geraet (MAC). Vorher wird geprueft: im Bereich, nicht im Ausschluss, nicht an ein anderes Geraet vergeben.
   Auf Wunsch wird gleich der DNS-Eintrag (A + PTR) angelegt.

3. **Reservierung aus bestehendem Lease**
   Ein Geraet behaelt seine aktuelle Adresse dauerhaft - in einem Schritt.

4. **Reservierung loeschen**
   Loescht eine Reservierung (rueckgaengig moeglich).

5. **Leases anzeigen**
   Alle vergebenen Adressen mit MAC, Name, Status und Ablauf.

6. **Lease suchen**
   Sucht nach Teil von IP, MAC oder Name.

7. **Lease loeschen**
   Gibt eine Adresse frei. Das Geraet holt sich beim naechsten Erneuern eine neue Adresse.

8. **Konflikterkennung einstellen**
   Der Server pingt eine Adresse vor der Vergabe (Vorschlag: 1 Versuch), um Doppelvergaben zu vermeiden.

### DHCP - Failover

1. **Status anzeigen**
   Zeigt alle Failover-Beziehungen mit Partner, Modus, Zustand (Normal = in Ordnung) und Scopes.

2. **Failover einrichten (Assistent)**
   Prueft zuerst den Partner (Name, TCP 647, DHCP-Rolle, Autorisierung) und bricht sauber ab, wenn er nicht bereit ist.
   Dann Lastverteilung oder Reserve waehlen und ein gemeinsames Geheimnis verdeckt eingeben.

3. **Replikation ausloesen**
   Nach Aenderungen an Optionen, Reservierungen oder Ausschluessen: Einstellungen zum Partner uebertragen.

### DHCP + DNS verbinden

1. **Stand anzeigen**
   Zeigt DHCP-DNS-Einstellungen (Server und Scopes), Zugangsdaten, Zonen und Aufraeumen. Warnt deutlich, wenn DHCP auf einem DC ohne Zugangsdaten laeuft.

2. **Assistent: DHCP mit DNS verbinden**
   Damit jeder DHCP-Client automatisch im DNS steht:
     - DHCP-Server: "immer aktualisieren" (Always), auch fuer aeltere Clients, und Eintraege beim
       Ablauf der Lease loeschen. Das gilt fuer den Server und jeden Scope.
     - DNS-Zonen: dynamische Updates an (auf DCs: nur sicher), Reverse-Zone fuer jeden Scope.
     - Zugangsdaten: der DHCP-Server traegt mit einem eigenen Dienstkonto ein (Vorschlag svc-dhcpdns).
       Laeuft DHCP auf einem DC ohne Dienstkonto, gehoeren die Eintraege dem DC-Computerkonto - das
       ist ein Sicherheitsrisiko und macht Probleme, wenn Eintraege spaeter aktualisiert werden.
     - Aufraeumen: No-Refresh + Refresh mindestens so lang wie die Lease-Dauer.

3. **DHCP-DNS-Einstellungen setzen**
   Immer eintragen (Always), alte Eintraege beim Lease-Ablauf loeschen, auch fuer aeltere Clients; Namensschutz waehlbar. Server und alle Scopes.

4. **Dienstkonto einrichten (svc-dhcpdns)**
   Legt nach Bestaetigung ein eigenes AD-Konto an (oder nutzt ein vorhandenes) und setzt es als DNS-Zugangsdaten des DHCP-Servers. Das Kennwort wird nicht gespeichert.

5. **Pruefen: Leases ohne DNS-Eintrag**
   Gleicht alle aktiven Leases mit A- und PTR-Eintraegen ab, nennt die wahrscheinliche Ursache und bietet das Nachtragen an.

### Doktor

1. **Alles pruefen und reparieren**
   Fuehrt alle passenden Pruefungen aus und zeigt [OK]/[WARN]/[FEHLER].
   Harmloses (Stufe Automatisch, z. B. gestoppten Dienst starten) wird sofort repariert - abschaltbar in den Einstellungen.
   Alles andere wird einzeln angeboten; danach wird erneut geprueft. Der Probelauf gilt auch hier.

2. **Nur pruefen (nichts aendern)**
   Zeigt den Zustand, ohne etwas zu reparieren.

3. **Eine Kategorie pruefen**
   Rechte, Rollen, AD, Netzwerk, DHCP oder DNS einzeln pruefen.

4. **Pruefkatalog anzeigen**
   Alle Pruefungen mit Problem, Erklaerung und Reparaturstufe.

5. **dcdiag anzeigen (unveraendert)**
   Startet das Windows-Werkzeug dcdiag und zeigt dessen Ausgabe 1:1 (nur auf DCs).

6. **Fremde DHCP-Server im Netz suchen**
   Schickt eine DHCP-Anfrage (DHCPDISCOVER) ins Netz und zeigt alle antwortenden Server. Fremde Server (z. B. ein Router mit eingeschaltetem DHCP) verteilen falsche Adressen.

### Berichte

1. **Gesamtbericht erstellen (HTML + CSV)**
   Scope-Auslastung, freie IPs, Leases ohne DNS, Doktor-Ergebnis und Aenderungsverlauf in einer HTML-Datei (ohne Internet lesbar) und je Teil als CSV im Ordner Berichte.

2. **Freie IP-Adressen anzeigen**
   Bereich minus Ausschluesse, Reservierungen und Leases, zusammengefasst zu Bereichen.

3. **Leases ohne DNS-Eintrag**
   Prueft alle aktiven Leases auf A- und PTR-Eintrag (mit Ursache).

4. **Aenderungsverlauf**
   Alle Aenderungen, die NetSetup gemacht hat, mit Zeit und Status (aktiv/rueckgaengig).

5. **Ordner Berichte anzeigen**
   Listet die neuesten Berichte.

### Backup, Wiederherstellen, Rueckgaengig

1. **Backup jetzt erstellen**
   Sichert DHCP (Datenbank + Export mit Leases), DNS (jede Zone + alle Eintraege als CSV), Konfiguration und Netzwerk.
   Vor jeder Aenderung sichert NetSetup automatisch; die letzten 20 Backups werden aufbewahrt (Einstellungen).

2. **Backups anzeigen**
   Liste aller Backups mit Zeit, Anlass und Inhalt.

3. **DHCP wiederherstellen (gefaehrlich)**
   Datenbank zuruecksetzen (Restore-DhcpServer) oder Konfiguration importieren (Import-DhcpServer). Vorher wird der aktuelle Stand gesichert, Servername eintippen.

4. **DNS-Eintraege wiederherstellen (gefaehrlich)**
   Legt fehlende Eintraege (und Zonen) aus der CSV eines Backups neu an. Vorhandene Eintraege bleiben unveraendert.

5. **Rueckgaengig**
   Letzte Aenderung oder eine Aenderung aus dem Verlauf zuruecknehmen.

6. **Serverumzug: Paket exportieren**
   Packt DHCP (mit Leases), DNS-Zonen und -Eintraege und die Konfiguration in einen Ordner (optional ZIP) fuer den neuen Server.

7. **Serverumzug: Paket importieren**
   Importiert ein Paket auf diesem Server: Bestandsaufnahme, Vorher/Nachher, vorhandene Scopes und Zonen werden nicht ueberschrieben.

8. **CSV-Import (DNS-Eintraege oder Reservierungen)**
   Prueft jede Zeile vorher und zeigt das Ergebnis. Bei einem Fehler wird nichts importiert (alles oder nichts).
   Vorlagen: Menuepunkt 'Vorlagen anlegen'.

9. **Vorlagen anlegen**
   Legt Beispiel-CSVs fuer DNS-Eintraege und Reservierungen im Ordner Vorlagen an.

10. **Geplante Aufgabe: taegliche Pruefung einrichten**
   Optional: taeglich NetSetup -Task Health als SYSTEM. Prueft nur und schreibt einen Bericht nach Berichte.

11. **Geplante Aufgabe entfernen**
   Entfernt die geplante Gesundheitspruefung wieder.

### Rueckgaengig

1. **Letzte Aenderung rueckgaengig machen**
   Fuehrt die gemerkte Gegenaktion der letzten Aenderung aus (mit Vorher/Nachher und Bestaetigung).

2. **Aenderung aus dem Verlauf waehlen**
   Waehlt eine bestimmte Aenderung aus dem Verlauf und nimmt sie zurueck.

3. **Verlauf anzeigen**
   Alle Aenderungen mit Zeit und Status.

### Erweitert (Fachleute)

1. **DNSSEC: Zone signieren**
   DNSSEC signiert eine Zone digital. DNS-Server, die DNSSEC pruefen, erkennen gefaelschte Antworten.
   Folgen:
     - Die Zone wird deutlich groesser (Signaturen), Schluessel muessen gepflegt werden.
     - Clients pruefen nur, wenn per Gruppenrichtlinie (NRPT) eingestellt - sonst bringt es intern wenig.
     - Fehler bei Schluesseln oder Uhrzeit machen die Zone fuer pruefende Resolver unaufloesbar.
     - Die Signatur laesst sich wieder entfernen (Unsign).

2. **DNSSEC: Signatur entfernen**
   Entfernt die DNSSEC-Signatur einer Zone wieder (gefaehrlich, mit Backup).

3. **Split-Brain einrichten**
   Split-Brain: Ein Name liefert intern eine andere Adresse als extern (z. B. mail.firma.ch intern
   192.168.1.20, extern die oeffentliche Adresse). Umsetzung mit einem Client-Subnetz, einem
   Zonen-Scope mit den internen Eintraegen und einer Abfrage-Richtlinie.
   Wichtig: Zonen-Scopes funktionieren nur bei dateibasierten Zonen, nicht bei AD-integrierten.

4. **Split-Brain entfernen**
   Entfernt Richtlinie und Zonen-Scope "intern" wieder.

5. **DHCP-Richtlinie anlegen**
   DHCP-Richtlinien geben bestimmten Geraeten andere Optionen (oder Bereiche), z. B. alle Geraete mit
   MAC-Praefix 00-15-5D (Hyper-V) oder einer bestimmten Herstellerklasse (VoIP-Telefone) bekommen
   einen anderen DNS-Server oder Router. Die Richtlinie wird ausgeschaltet angelegt und erst nach
   Bestaetigung aktiviert.

6. **DHCP-Richtlinie ein-/ausschalten**
   Schaltet eine Richtlinie ein oder aus (rueckgaengig moeglich).

7. **DHCP-Richtlinie entfernen**
   Entfernt eine DHCP-Richtlinie.

8. **DNS-Sperrliste anzeigen**
   Zeigt die von NetSetup angelegten Sperren und die globale Sperrliste von Windows.

9. **Domaenen sperren**
   DNS-Sperrliste: Anfragen fuer bestimmte Domaenen (z. B. bekannte Werbe- oder Schadseiten) werden
   vom DNS-Server ignoriert. Umgesetzt mit Abfrage-Richtlinien (Aktion IGNORE) auf Serverebene.
   Die globale Sperrliste von Windows (Standard: wpad, isatap) gilt nur fuer Namen in eigenen Zonen.

10. **Sperre ein-/ausschalten**
   Schaltet eine Sperre ein oder aus.

11. **Sperren aufheben**
   Entfernt Sperren wieder.

12. **DHCPv6-Scopes anzeigen**
   Listet die DHCPv6-Scopes.

13. **DHCPv6-Scope anlegen (inaktiv)**
   DHCPv6 vergibt IPv6-Adressen. In den meisten Netzen nicht noetig: IPv6 konfiguriert sich ueber
   Router-Ankuendigungen (SLAAC). DHCPv6 braucht man, wenn der Router "Managed" (M-Flag) ankuendigt
   oder Adressen zentral vergeben werden sollen. Der Scope wird inaktiv angelegt.

14. **DHCPv6-Scope aktivieren/deaktivieren**
   Erst hier wird ein DHCPv6-Scope wirksam.

15. **DHCPv6-Scope loeschen**
   Loescht einen DHCPv6-Scope (gefaehrlich, mit Backup).

### Hilfe

1. **Bedienung und Sicherheitsregeln**
   Wie NetSetup bedient wird und welche Sicherheitsregeln immer gelten.

2. **Glossar anzeigen**
   Alle Fachbegriffe (Lease, Scope, Zone, PTR, ...) in einfachen Worten.

3. **Begriff im Glossar suchen**
   Sucht einen Begriff im Glossar.

4. **Ueber NetSetup (Version, Umgebung)**
   Zeigt Version, Datenordner, Logdatei und die erkannte Umgebung.

### Einstellungen

1. **Probelauf an/aus**
   Im Probelauf zeigt NetSetup alle geplanten Aenderungen, fuehrt aber nichts aus (wie -WhatIf). Gut zum Ausprobieren.

2. **Automatische Reparatur an/aus**
   Wenn an, repariert der Doktor harmlose Fehler (Stufe Automatisch, z. B. gestoppten Dienst starten) ohne Rueckfrage. Alles andere wird immer gefragt.

3. **Anzahl aufbewahrter Backups**
   Aeltere automatische Backups werden geloescht, sobald mehr als diese Anzahl vorhanden ist. Vorschlag: 20.

4. **Auswahlfenster (Out-GridView) an/aus**
   Mit Desktop-Oberflaeche koennen Listen in einem Fenster mit Suche angezeigt werden. Aus = immer Nummernliste in der Konsole.

5. **Vorschlagswerte bearbeiten**
   Weiterleitungen (Vorschlag 9.9.9.9 und 1.1.1.1), Lease-Dauer (8 Tage), Scavenging (7 + 7 Tage) und Name des Dienstkontos (svc-dhcpdns).

6. **Datenordner aendern**
   Ort fuer Konfiguration, Logs, Backups, Berichte, Rueckgaengig und Vorlagen. Standard: C:\NetSetup.

7. **Konfiguration anzeigen und pruefen**
   Zeigt die gespeicherte Konfiguration (JSON) und prueft sie auf Fehler.

8. **Script neu speichern**
   Speichert die laufende Version von NetSetup als NetSetup.ps1 in den Datenordner.

9. **Desktop-Verknuepfung anlegen**
   Legt auf dem Desktop eine Verknuepfung "NetSetup" an, die NetSetup als Administrator startet (nur mit Desktop-Oberflaeche).

<!-- MENUES:ENDE -->

## 9. Glossar

Diese Liste wird aus dem Script erzeugt und ist identisch mit dem Glossar im Script (Taste `G`).

<!-- GLOSSAR:START -->

**A-Eintrag**
: DNS-Eintrag, der einen Namen einer IPv4-Adresse zuordnet (pc01.ad.firma.ch -> 192.168.1.50). AAAA ist dasselbe fuer IPv6.

**Abhoer-IP-Adresse**
: Die Adressen des Servers, auf denen der DNS-Dienst Anfragen annimmt. Ueblich: alle festen IPv4-Adressen des Servers, keine APIPA-Adressen (169.254.x.x).

**Aging/Scavenging**
: Automatisches Aufraeumen alter, dynamisch eingetragener DNS-Eintraege. Aging merkt sich, wann ein Eintrag zuletzt erneuert wurde; Scavenging loescht Eintraege, die laenger als No-Refresh + Refresh nicht erneuert wurden. Ueblich: an, 7 + 7 Tage. Die Summe muss mindestens so lang sein wie die DHCP-Lease-Dauer.

**Ausschluss**
: Ein Adressbereich innerhalb eines DHCP-Scopes, den der DHCP-Server nie vergibt, z. B. fuer Drucker oder Server mit fester IP.

**Autorisierung**
: Eintrag des DHCP-Servers im Active Directory. Ein Windows-DHCP-Server in einer Domaene vergibt erst Adressen, wenn er autorisiert ist. Dafuer sind Rechte der Organisations-Admins (Enterprise Admins) noetig.

**Bindung**
: Legt fest, auf welcher Netzwerkkarte der DHCP-Server Anfragen beantwortet. Nur Karten mit fester IP im Netz der Clients sollten gebunden sein.

**CNAME**
: Alias-Eintrag im DNS: ein zweiter Name zeigt auf einen vorhandenen Namen (intranet -> srv01).

**DHCP-Relay**
: Funktion im Router oder Layer-3-Switch (oft "IP Helper" genannt), die DHCP-Anfragen aus anderen Netzen (VLANs) an den DHCP-Server weiterleitet. Ohne Relay erreicht ein DHCP-Server nur das eigene Netz.

**DHCPv6**
: DHCP fuer IPv6. In den meisten Netzen nicht noetig, weil IPv6 sich per Router-Ankuendigung (SLAAC) selbst konfiguriert. In NetSetup unter "Erweitert".

**Dienstkonto**
: Ein eigenes AD-Benutzerkonto nur fuer einen Dienst, hier fuer die DNS-Eintraege des DHCP-Servers (Vorschlag svc-dhcpdns). Sein Kennwort muss gepflegt werden, sonst schlagen die Eintraege nach Ablauf fehl.

**DNSSEC**
: Digitale Signaturen fuer DNS-Zonen, damit Antworten nicht gefaelscht werden koennen. Erfordert Schluesselpflege; ein Fehler kann die Namensaufloesung stoeren. In NetSetup unter "Erweitert".

**Domaenencontroller**
: Server, der das Active Directory speichert und Anmeldungen prueft (kurz DC). Mindestens zwei DCs pro Domaene sind empfohlen.

**DSRM**
: Verzeichnisdienst-Wiederherstellungsmodus (Directory Services Restore Mode). Notfall-Anmeldung an einem DC, wenn das AD nicht startet. Das DSRM-Kennwort wird bei der Heraufstufung festgelegt und muss sicher aufbewahrt werden.

**Dynamisches Update**
: Clients oder der DHCP-Server tragen ihre DNS-Eintraege selbst ein. "Sicher" (nur auf AD-integrierten Zonen) erlaubt das nur angemeldeten Domaenenmitgliedern und ist die empfohlene Einstellung.

**Failover**
: Zwei DHCP-Server teilen sich einen Scope. Lastverteilung: beide vergeben Adressen. Reserve (Hot-Standby): einer arbeitet, der andere springt bei Ausfall ein. Beide brauchen ein gemeinsames Geheimnis.

**Funktionsebene**
: Legt fest, welche AD-Funktionen genutzt werden koennen und welche Windows-Versionen als DC erlaubt sind. NetSetup schlaegt die hoechste Ebene vor, die das Betriebssystem kann.

**Gateway**
: Der Router, ueber den ein Netz andere Netze und das Internet erreicht (DHCP-Option 003).

**Gesamtstruktur**
: Englisch Forest. Die oberste Ebene im Active Directory, enthaelt eine oder mehrere Domaenen. Die erste Domaene ist die Stammdomaene der Gesamtstruktur.

**Lease**
: Die zeitlich begrenzte Vergabe einer IP-Adresse an einen Client. Vor Ablauf erneuert der Client die Lease. Ueblich in Bueros: 8 Tage; in Gaeste- oder WLAN-Netzen kuerzer (z. B. 1 Tag).

**MX**
: Mail-Exchanger-Eintrag im DNS: nennt den Mailserver einer Domaene mit einer Prioritaet (kleinere Zahl = bevorzugt).

**Namensschutz**
: DHCP-Einstellung (Name Protection): verhindert, dass ein Geraet den DNS-Namen eines anderen Geraets uebernimmt.

**NetBIOS-Name**
: Kurzer, alter Domaenenname (hoechstens 15 Zeichen, z. B. FIRMA), der bei der Anmeldung als FIRMA\benutzer erscheint.

**Option**
: Zusatzinformation, die der DHCP-Server mit der Adresse mitliefert, z. B. 003 Router, 006 DNS-Server, 015 DNS-Domaenenname, 042 NTP-Server, 066/067 PXE-Bootserver und Bootdatei, 119 DNS-Suchliste.

**Organisations-Admins**
: Englisch Enterprise Admins. AD-Gruppe mit Rechten fuer die ganze Gesamtstruktur, noetig z. B. fuer die DHCP-Autorisierung.

**Probelauf**
: Modus, in dem NetSetup alles prueft und anzeigt, aber nichts aendert (entspricht -WhatIf). In den Einstellungen umschaltbar.

**PTR**
: Zeiger-Eintrag in einer Reverse-Zone: ordnet einer IP-Adresse einen Namen zu (192.168.1.50 -> pc01.ad.firma.ch).

**Reservierung**
: Feste Zuordnung einer IP-Adresse zu einem Geraet (ueber die MAC-Adresse). Das Geraet bekommt per DHCP immer dieselbe Adresse.

**Reverse-Zone**
: DNS-Zone fuer die Rueckwaertssuche von IP-Adresse zu Name, z. B. 1.168.192.in-addr.arpa fuer das Netz 192.168.1.0/24. Enthaelt PTR-Eintraege.

**Rueckgaengig**
: NetSetup merkt sich zu jeder Aenderung die Gegenaktion. Unter "Backup, Wiederherstellen, Rueckgaengig" laesst sich die letzte oder eine bestimmte Aenderung zuruecknehmen.

**Scope**
: Adressbereich, aus dem der DHCP-Server Adressen vergibt, z. B. 192.168.1.100 bis 192.168.1.199 im Netz 192.168.1.0/24, mit eigenen Optionen.

**Server Core**
: Windows Server ohne Desktop-Oberflaeche. NetSetup laeuft dort genauso, nur ohne Auswahlfenster (Out-GridView).

**Split-Brain**
: DNS gibt je nach Fragesteller unterschiedliche Antworten, z. B. intern die interne und extern die oeffentliche Adresse. Umgesetzt mit Zonen-Scopes und Abfrage-Richtlinien.

**SRV**
: Dienst-Eintrag im DNS: nennt Server fuer einen Dienst mit Port, Prioritaet und Gewichtung. Das AD findet DCs ueber SRV-Eintraege wie _ldap._tcp.dc._msdcs.<domaene>.

**Stammhinweise**
: Englisch Root Hints. Liste der DNS-Stammserver im Internet. Ohne Weiterleitung fragt der DNS-Server von dort aus selbst durch. Funktioniert nur mit Internetzugang ueber Port 53.

**Subnetzmaske**
: Legt fest, welcher Teil einer IP-Adresse das Netz ist. 255.255.255.0 entspricht /24 (254 nutzbare Adressen).

**Superscope**
: Zusammenfassung mehrerer DHCP-Scopes, die im selben physischen Netz liegen (mehrere logische Netze auf einem Kabel).

**SYSVOL**
: Freigegebener Ordner auf jedem DC mit Gruppenrichtlinien und Anmeldescripts. Die Freigaben SYSVOL und NETLOGON muessen auf jedem DC vorhanden sein.

**TXT**
: Text-Eintrag im DNS, z. B. fuer SPF oder Domaenen-Nachweise.

**Weiterleitung**
: Englisch Forwarder. Der DNS-Server schickt Anfragen, die er nicht selbst beantworten kann, an einen anderen DNS-Server (z. B. 9.9.9.9 Quad9, 1.1.1.1 Cloudflare oder den Router). Eine bedingte Weiterleitung gilt nur fuer eine bestimmte Domaene.

**Zeitquelle**
: Von wem ein Server die Uhrzeit bezieht. In einer Domaene folgen alle dem PDC-Emulator, der seine Zeit von einer externen Quelle holen sollte. Mehr als 5 Minuten Abweichung verhindern die Anmeldung (Kerberos).

**Zone**
: Ein Bereich des DNS-Namensraums, den ein DNS-Server verwaltet, z. B. ad.firma.ch. AD-integrierte Zonen werden mit dem AD auf alle DCs repliziert, dateibasierte Zonen liegen nur auf einem Server.

<!-- GLOSSAR:ENDE -->
