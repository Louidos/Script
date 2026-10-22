# "Vorhandene Konfiguration uebernehmen": schreibt gefundene AD-, DNS- und DHCP-Einstellungen
# in die NetSetup-Konfiguration. Am Server wird dabei nichts geaendert.

function ConvertTo-NetConfigFromState {
    <#
    .SYNOPSIS
        Baut aus der Bestandsaufnahme die Bereiche AD, Dns und Dhcp der Konfiguration.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Zustand)
    $ad = @{ Domaene = [string]$Zustand.AD.Domaene; NetBios = [string]$Zustand.AD.NetBios }
    $dns = @{
        Zonen           = @($Zustand.Dns.Zonen | ForEach-Object {
                @{ Name = $_.Name; Typ = $_.Typ; AdIntegriert = $_.AdIntegriert; Reverse = $_.Reverse; DynUpdate = $_.DynUpdate; Replikation = $_.Replikation }
            })
        Weiterleitungen = @($Zustand.Dns.Weiterleitungen)
        Scavenging      = $(if ($Zustand.Dns.Scavenging) { $Zustand.Dns.Scavenging } else { @{} })
    }
    $dhcp = @{
        Scopes         = @($Zustand.Dhcp.Scopes | ForEach-Object {
                @{
                    ScopeId        = $_.ScopeId
                    Name           = $_.Name
                    Start          = $_.Start
                    Ende           = $_.Ende
                    Maske          = $_.Maske
                    LeaseTage      = $_.LeaseTage
                    Aktiv          = $_.Aktiv
                    Optionen       = $_.Optionen
                    Ausschluesse   = @($_.Ausschluesse)
                    Reservierungen = @($_.Reservierungen)
                }
            })
        ServerOptionen = $Zustand.Dhcp.ServerOptionen
        DnsEinstellung = $(if ($Zustand.Dhcp.DnsEinstellung) { $Zustand.Dhcp.DnsEinstellung } else { @{} })
    }
    return @{ AD = $ad; Dns = $dns; Dhcp = $dhcp }
}

function Import-NetExistingConfig {
    <#
    .SYNOPSIS
        Menuepunkt "Vorhandene Konfiguration uebernehmen" (nur Config, keine Aenderung am Server).
    #>
    $zustand = Get-NetSetupState
    $neu = ConvertTo-NetConfigFromState -Zustand $zustand
    $alt = $script:NS.Config
    $vorher = @{
        'AD-Domaene'          = [string]$alt.AD.Domaene
        'DNS-Zonen'           = @($alt.Dns.Zonen).Count
        'DNS-Weiterleitungen' = (@($alt.Dns.Weiterleitungen) -join ', ')
        'DHCP-Scopes'         = @($alt.Dhcp.Scopes).Count
    }
    $nachher = @{
        'AD-Domaene'          = $neu.AD.Domaene
        'DNS-Zonen'           = @($neu.Dns.Zonen).Count
        'DNS-Weiterleitungen' = (@($neu.Dns.Weiterleitungen) -join ', ')
        'DHCP-Scopes'         = @($neu.Dhcp.Scopes).Count
    }
    if (-not $zustand.Dns.Verfuegbar -and -not $zustand.Dhcp.Verfuegbar -and -not $neu.AD.Domaene) {
        Write-Log -Level Warn -Message 'Es wurde keine vorhandene AD-, DNS- oder DHCP-Konfiguration gefunden. Es gibt nichts zu uebernehmen.'
        return
    }
    $r = Invoke-NetChange -Titel 'Vorhandene Konfiguration in die NetSetup-Konfiguration uebernehmen' -Stufe Bestaetigen -Vorher $vorher -Nachher $nachher `
        -Hinweis 'Am Server wird dabei nichts geaendert. Nur die Datei Config\netsetup.json wird aktualisiert.' -BackupBereich @('Config') -Aktion {
        $c = $script:NS.Config
        $c.AD.Domaene = $neu.AD.Domaene
        $c.AD.NetBios = $neu.AD.NetBios
        $c.Dns = $neu.Dns
        $c.Dhcp = $neu.Dhcp
        Save-NetConfig -Config $c
    }
    if ($r.Erfolg -and -not $r.Probelauf) { Write-Log -Level OK -Message 'Konfiguration uebernommen.' }
}

function Show-NetInventoryMenu {
    $eintraege = @(
        @{ Text = 'Bestandsaufnahme neu erfassen (Uebersicht)'; Aktion = 'Show-NetStartOverview'; Hilfe = 'Liest den aktuellen Zustand des Servers neu ein (nur lesend) und zeigt pro Bereich eine Zeile mit [OK], [WARN], [FEHLER] oder [--].' },
        @{ Text = 'Bestandsaufnahme im Detail'; Aktion = 'Show-NetStateDetail'; Hilfe = 'Zeigt alles, was NetSetup erkannt hat: Rolle, Funktionen, Dienste, Netzwerkkarten, DNS-Zonen, DHCP-Scopes, Failover, Zeitquelle.' },
        @{ Text = 'Vorhandene Konfiguration uebernehmen'; Aktion = 'Import-NetExistingConfig'; Hilfe = "Schreibt die gefundenen DNS- und DHCP-Einstellungen in die NetSetup-Konfiguration (Config\netsetup.json).`nAm Server wird dabei nichts geaendert. Sinnvoll, wenn DNS/DHCP schon eingerichtet sind." }
    )
    Show-NetMenu -Titel 'Bestandsaufnahme' -Eintraege $eintraege
}
