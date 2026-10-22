# DHCP: Uebersicht, Einrichtungs-Assistent und Menue.

function Show-NetDhcpOverview {
    if (-not (Test-NetDhcpReady)) { return }
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'DHCP-Uebersicht'
    $auth = Test-NetDhcpAuthorized
    if ($null -eq $auth) { Write-NetStatus -Status NA -Bereich 'Autorisierung' -Text 'keine Domaene - nicht noetig' }
    elseif ($auth) { Write-NetStatus -Status OK -Bereich 'Autorisierung' -Text 'im AD autorisiert' }
    else { Write-NetStatus -Status FEHLER -Bereich 'Autorisierung' -Text 'NICHT autorisiert - der Server vergibt keine Adressen' }
    if ($z.Dhcp.Nachkonfiguriert) { Write-NetStatus -Status OK -Bereich 'Nachkonfiguration' -Text 'erledigt' }
    else { Write-NetStatus -Status WARN -Bereich 'Nachkonfiguration' -Text 'fehlt (Server-Manager meldet "Konfiguration erforderlich")' }
    Write-NetStatus -Status INFO -Bereich 'Konflikterkennung' -Text ('{0} Versuch(e)' -f $z.Dhcp.KonfliktErkennung)
    Show-NetDhcpScope
    if (@($z.Dhcp.Failover).Count -gt 0) { Show-NetDhcpFailover }
}

function Start-NetDhcpSetup {
    <#
    .SYNOPSIS
        Assistent: Rolle, Nachkonfiguration, Autorisierung, Bindungen, erster Scope, Optionen.
        Ueberspringt alles, was schon passt.
    #>
    Write-NetTitle -Titel 'DHCP einrichten'
    $z = Get-NetSetupState
    $andererServer = @($z.Netzwerk.AktiveKarten | Where-Object { $_.Dhcp })
    if ($andererServer.Count -gt 0) {
        Write-Log -Level Warn -Message 'Dieser Server bezieht seine eigene Adresse per DHCP. Ein DHCP-Server braucht eine feste IP (sonst bindet er nicht).'
        if (Read-NetYesNo -Frage 'Jetzt eine feste IP setzen?' -Vorschlag $true) { Set-NetStaticAddress -Karte $andererServer[0] | Out-Null }
    }
    if (-not ($z.Dhcp.Installiert -and $z.Dhcp.Tools)) {
        if (-not (Install-NetDhcpRole)) { return }
    }
    elseif (-not $z.Dhcp.Nachkonfiguriert) { Complete-NetDhcpPostInstall | Out-Null }
    else { Write-Log -Level OK -Message 'DHCP-Rolle installiert und nachkonfiguriert.' }
    if (-not (Test-NetDhcpReady)) { return }
    $auth = Test-NetDhcpAuthorized
    if ($auth -eq $false) { Add-NetDhcpAuthorization | Out-Null }
    elseif ($null -eq $auth) { Write-Log -Message 'Keine Domaene: Autorisierung nicht noetig.' }
    else { Write-Log -Level OK -Message 'Im AD autorisiert.' }
    $z = Get-NetSetupState
    if (@($z.Dhcp.Bindungen | Where-Object { $_.Aktiv }).Count -eq 0 -and @($z.Dhcp.Bindungen).Count -gt 0) {
        Write-Log -Level Warn -Message 'Der DHCP-Server ist an keine Netzwerkkarte gebunden.'
        Set-NetDhcpBinding
    }
    if (@($z.Dhcp.Scopes).Count -eq 0) {
        Write-Log -Message 'Es gibt noch keinen Scope. Der Scope-Assistent startet.'
        New-NetDhcpScope | Out-Null
    }
    else {
        Write-Log -Level OK -Message (('{0} Scope(s) vorhanden: ' -f @($z.Dhcp.Scopes).Count) + (($z.Dhcp.Scopes | ForEach-Object { $_.ScopeId }) -join ', '))
        foreach ($s in @($z.Dhcp.Scopes)) {
            $fehlt = @(@('3', '6', '15') | Where-Object { -not $s.Optionen.ContainsKey($_) -and -not $z.Dhcp.ServerOptionen.ContainsKey($_) })
            if ($fehlt.Count -gt 0) { Write-Log -Level Warn -Message ('Im Scope {0} fehlen die Optionen {1}. Im Menue Scopes -> Optionen 003/006/015 ergaenzen.' -f $s.ScopeId, ($fehlt -join ', ')) }
            if (-not $s.Aktiv) { Write-Log -Level Warn -Message ('Der Scope {0} ist nicht aktiv.' -f $s.ScopeId) }
        }
        if (Read-NetYesNo -Frage 'Einen weiteren Scope (z. B. fuer ein anderes VLAN) anlegen?' -Vorschlag $false) { New-NetDhcpScope | Out-Null }
    }
    if ($z.Dhcp.KonfliktErkennung -eq 0 -and (Read-NetYesNo -Frage 'Konflikterkennung einschalten (1 Ping vor jeder Vergabe)?' -Vorschlag $true)) {
        Set-NetDhcpConflictDetection -Versuche 1 | Out-Null
    }
    Write-Log -Level OK -Message 'DHCP-Einrichtung abgeschlossen.'
}

function Show-NetDhcpScopeMenu {
    $eintraege = @(
        @{ Text = 'Scopes anzeigen'; Aktion = 'Show-NetDhcpScope'; Hilfe = 'Alle Scopes mit Bereich, Status, Lease-Dauer, Auslastung, Optionen 003/006/015 und Ausschluessen.' },
        @{ Text = 'Neuer Scope (Assistent)'; Aktion = { New-NetDhcpScope | Out-Null }; Hilfe = "Name, Netz, Bereich, Ausschluesse, Lease-Dauer (Vorschlag 8 Tage), Router (003), DNS-Server (006, Vorschlag: die DCs), Domaene (015).`nUngueltige Bereiche werden abgelehnt; fuer andere Netze (VLANs) Hinweis auf DHCP-Relay am Router." },
        @{ Text = 'Ausschluss hinzufuegen'; Aktion = 'Add-NetDhcpExclusion'; Hilfe = 'Adressen im Bereich, die nie vergeben werden (Drucker, Server, Router mit fester IP).' },
        @{ Text = 'Optionen 003/006/015 aendern'; Aktion = 'Set-NetDhcpStandardOption'; Hilfe = 'Router, DNS-Server und Domaene eines Scopes aendern.' },
        @{ Text = 'Scope aktivieren/deaktivieren'; Aktion = 'Switch-NetDhcpScopeState'; Hilfe = 'Ein deaktivierter Scope vergibt keine Adressen mehr.' },
        @{ Text = 'Superscope anlegen'; Aktion = 'New-NetDhcpSuperscope'; Hilfe = 'Mehrere Scopes im selben physischen Netz zusammenfassen. Fuer getrennte VLANs nicht noetig.' },
        @{ Text = 'Scope loeschen (gefaehrlich)'; Aktion = 'Remove-NetDhcpScope'; Hilfe = 'Loescht einen Scope mit allen Leases und Reservierungen. Vorher automatisches Backup, Servername eintippen.' }
    )
    Show-NetMenu -Titel 'DHCP - Scopes' -Eintraege $eintraege
}

function Show-NetDhcpMenu {
    $eintraege = @(
        @{ Text = 'Uebersicht'; Aktion = 'Show-NetDhcpOverview'; Hilfe = 'Autorisierung, Nachkonfiguration, Konflikterkennung, alle Scopes und Failover auf einen Blick.' },
        @{ Text = 'DHCP einrichten (Assistent)'; Aktion = 'Start-NetDhcpSetup'; Hilfe = 'Rolle, Nachkonfiguration, Autorisierung, Bindungen, erster Scope und Optionen - Erledigtes wird uebersprungen.' },
        @{ Text = 'Rolle installieren und nachkonfigurieren'; Aktion = { Install-NetDhcpRole | Out-Null }; Hilfe = 'Installiert die DHCP-Rolle aus dem lokalen Windows und fuehrt die Nachkonfiguration aus (Sicherheitsgruppen, ConfigurationState = 2, Dienstneustart).' },
        @{ Text = 'Im AD autorisieren'; Aktion = { Add-NetDhcpAuthorization | Out-Null }; Hilfe = 'In einer Domaene vergibt ein DHCP-Server erst nach der Autorisierung Adressen. Dafuer braucht es Organisations-Admins (Enterprise Admins). Ohne Domaene wird uebersprungen.' },
        @{ Text = 'Bindungen anzeigen'; Aktion = 'Show-NetDhcpBinding'; Hilfe = 'Auf welchen Netzwerkkarten der DHCP-Server antwortet.' },
        @{ Text = 'Bindungen einstellen'; Aktion = 'Set-NetDhcpBinding'; Hilfe = 'Nur Karten im Netz der Clients binden.' },
        @{ Text = 'Scopes'; Aktion = 'Show-NetDhcpScopeMenu'; OhnePause = $true; Hilfe = 'Scopes anzeigen, anlegen, Ausschluesse, Optionen, aktivieren/deaktivieren, Superscope, loeschen.' },
        @{ Text = 'Zusatzoptionen (NTP, PXE, Suchliste)'; Aktion = 'Show-NetDhcpExtraOptionMenu'; OhnePause = $true; Hilfe = 'Optionen 042, 066/067 und 119 - standardmaessig aus, auf Server- oder Scope-Ebene.' },
        @{ Text = 'Reservierungen und Leases'; Aktion = 'Show-NetDhcpReservationMenu'; OhnePause = $true; Hilfe = 'Reservierungen anlegen (auch aus einem Lease), pruefen, loeschen; Leases anzeigen, suchen, loeschen; Konflikterkennung.' },
        @{ Text = 'Failover'; Aktion = 'Show-NetDhcpFailoverMenu'; OhnePause = $true; Hilfe = 'Zweiter DHCP-Server fuer Ausfallsicherheit: Lastverteilung oder Reserve, Status, Replikation.' }
    )
    Show-NetMenu -Titel 'DHCP' -Eintraege $eintraege
}
