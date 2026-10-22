@{
    # Projektdatei von NetSetup: Version und Reihenfolge der Quelldateien.
    # scripts/Build-NetSetup.ps1 baut daraus dist/NetSetup.ps1.
    Name    = 'NetSetup'
    Version = '0.0.0'

    # Reihenfolge der Quelldateien (relativ zum Hauptordner).
    # Der Eintrag '@checks' steht fuer alle Dateien in src/checks (alphabetisch).
    Dateien = @(
        'src/core/Zustand.ps1'
        'src/core/Pfade.ps1'
        'src/core/Log.ps1'
        'src/core/Config.ps1'
        'src/core/Fehler.ps1'
        'src/core/IpHilfe.ps1'
        'src/core/Aenderung.ps1'
        'src/core/Umgebung.ps1'
        'src/core/Fortsetzung.ps1'
        'src/ui/Eingabe.ps1'
        'src/ui/Menue.ps1'
        'src/ui/Hilfe.ps1'
        'src/ui/Einstellungen.ps1'
        'src/inventar/Bestandsaufnahme.ps1'
        'src/inventar/Uebersicht.ps1'
        'src/inventar/Uebernehmen.ps1'
        'src/ad/Netzwerk.ps1'
        'src/ad/AdEinrichtung.ps1'
        'src/dns/DnsBasis.ps1'
        'src/dns/DnsZonen.ps1'
        'src/dns/DnsEintraege.ps1'
        'src/dns/DnsWeiterleitung.ps1'
        'src/dns/DnsAging.ps1'
        'src/dns/DnsMenue.ps1'
        'src/ui/Ersteinrichtung.ps1'
        'src/ui/Hauptmenue.ps1'
        'src/core/Start.ps1'
    )
}
