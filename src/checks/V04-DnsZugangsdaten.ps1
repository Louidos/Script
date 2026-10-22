# Pruefung V04: DNS-Zugangsdaten des DHCP-Servers gesetzt und gueltig.
Register-NetCheck @{
    Id            = 'V04'
    Kategorie     = 'DNS'
    Titel         = 'DNS-Zugangsdaten des DHCP-Servers'
    Problem       = 'Die DNS-Zugangsdaten fehlen oder sind ungueltig:'
    Erklaerung    = 'Laeuft DHCP auf einem DC ohne eigenes Dienstkonto, gehoeren alle Client-Eintraege dem DC (Sicherheitsrisiko, Aktualisierungsprobleme). Ein abgelaufenes Kennwort laesst alle Eintraege scheitern. Die Reparatur richtet das Dienstkonto ein bzw. setzt ein neues Kennwort.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and ($Z.System.IstDC -or $Z.System.IstMitglied) }
    Test          = {
        param($Z)
        $zd = $Z.Dhcp.DnsZugangsdaten
        if (-not $zd.Gesetzt) {
            if ($Z.System.IstDC) { return (New-NetCheckResult FEHLER 'DHCP laeuft auf einem DC ohne Zugangsdaten') }
            return (New-NetCheckResult WARN 'keine Zugangsdaten gesetzt')
        }
        $konto = Get-NetDnsCredentialAccountState -Benutzer $zd.Benutzer
        if ($konto -and $konto.Problem) { return (New-NetCheckResult FEHLER $konto.Problem) }
        New-NetCheckResult OK ('{0}\{1}' -f $zd.Domaene, $zd.Benutzer)
    }
    Reparatur     = { New-NetDhcpDnsCredential }
}
