# Ersteinrichtungs-Assistent: entscheidet anhand der Bestandsaufnahme die noetigen Schritte
# (AD -> DNS -> DHCP -> Verbindung -> Test), ueberspringt Erledigtes und ruft die Funktionen
# der einzelnen Bereiche auf. Fehlende Bereiche erscheinen als "kommt noch".

function Get-NetFirstSetupStep {
    <#
    .SYNOPSIS
        Liefert die Schritte der Ersteinrichtung mit Status (erledigt oder offen).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Zustand)
    $s = $Zustand.System
    $modus = [string](Get-NetConfigValue -Pfad 'AD.Modus' -Standard '')
    $forward = @($Zustand.Dns.Zonen | Where-Object { -not $_.Reverse -and $_.Typ -eq 'Primary' })
    $reverse = @($Zustand.Dns.Zonen | Where-Object { $_.Reverse })
    $aktiveScopes = @($Zustand.Dhcp.Scopes | Where-Object { $_.Aktiv })
    $e = $Zustand.Dhcp.DnsEinstellung

    $adText = 'Domaenencontroller einrichten oder Domaene beitreten'
    if ($s.IstDC) { $adText = 'Domaenencontroller fuer ' + $Zustand.AD.Domaene }
    elseif ($modus -eq 'OhneAD') { $adText = 'bewusst ohne AD' }
    elseif ($modus -eq 'Mitglied') { $adText = 'Mitgliedsserver, nur DNS/DHCP' }

    $dnsErledigt = $Zustand.Dns.Verfuegbar -and $Zustand.Dns.Laeuft -and ($forward.Count -gt 0) -and ($reverse.Count -gt 0)
    $dhcpErledigt = $Zustand.Dhcp.Verfuegbar -and $Zustand.Dhcp.Laeuft -and $Zustand.Dhcp.Nachkonfiguriert -and
        ((-not $Zustand.Dhcp.InDomaene) -or $Zustand.Dhcp.Autorisiert) -and ($aktiveScopes.Count -gt 0)
    $verbindungErledigt = $Zustand.Dhcp.Verfuegbar -and $e -and ($e.DynamicUpdates -eq 'Always') -and $e.DeleteDnsRROnLeaseExpiry -and
        ((-not $s.IstDC) -or $Zustand.Dhcp.DnsZugangsdaten.Gesetzt)

    return @(
        [pscustomobject]@{ Nr = 1; Name = 'Active Directory'; Funktion = 'Start-NetAdSetup'; Erledigt = [bool]($s.IstDC -or $modus -eq 'OhneAD' -or $modus -eq 'Mitglied'); Text = $adText },
        [pscustomobject]@{ Nr = 2; Name = 'DNS'; Funktion = 'Start-NetDnsSetup'; Erledigt = [bool]$dnsErledigt; Text = ('{0} Zone(n), {1} Reverse-Zone(n)' -f $forward.Count, $reverse.Count) },
        [pscustomobject]@{ Nr = 3; Name = 'DHCP'; Funktion = 'Start-NetDhcpSetup'; Erledigt = [bool]$dhcpErledigt; Text = ('{0} aktive(r) Scope(s)' -f $aktiveScopes.Count) },
        [pscustomobject]@{ Nr = 4; Name = 'DHCP + DNS verbinden'; Funktion = 'Start-NetIntegrationSetup'; Erledigt = [bool]$verbindungErledigt; Text = 'Clients automatisch mit A- und PTR-Eintrag' },
        [pscustomobject]@{ Nr = 5; Name = 'Test (Doktor)'; Funktion = 'Invoke-NetDoctor'; Erledigt = $false; Text = 'alles pruefen und Fehler beheben' }
    )
}

function Show-NetFirstSetupPlan {
    param([Parameter(Mandatory = $true)][object[]]$Schritte)
    foreach ($s in $Schritte) {
        if ($s.Erledigt) { Write-NetStatus -Status OK -Bereich ('{0}. {1}' -f $s.Nr, $s.Name) -Text ('erledigt - ' + $s.Text) }
        elseif (-not (Test-NetCommand -Name $s.Funktion)) { Write-NetStatus -Status NA -Bereich ('{0}. {1}' -f $s.Nr, $s.Name) -Text 'offen - kommt in einer spaeteren Version' }
        else { Write-NetStatus -Status WARN -Bereich ('{0}. {1}' -f $s.Nr, $s.Name) -Text ('offen - ' + $s.Text) }
    }
}

function Start-NetFirstSetup {
    <#
    .SYNOPSIS
        Fuehrt durch die komplette Einrichtung und ueberspringt bereits Erledigtes.
    #>
    Write-NetTitle -Titel 'Ersteinrichtung'
    Write-NetText -Text "Der Assistent prueft den Server und fuehrt nur die noch offenen Schritte aus:`n  1. Active Directory  2. DNS  3. DHCP  4. DHCP + DNS verbinden  5. Test`nJeder Schritt zeigt vorher, was er aendert, und fragt nach." -Farbe White
    $uebersprungen = @()
    $versuche = @{}
    while ($true) {
        $zustand = Get-NetSetupState
        $schritte = @(Get-NetFirstSetupStep -Zustand $zustand)
        Write-Host ''
        Show-NetFirstSetupPlan -Schritte $schritte
        $naechster = $schritte | Where-Object { -not $_.Erledigt -and ($uebersprungen -notcontains $_.Nr) } | Select-Object -First 1
        if (-not $naechster) {
            Write-Log -Level OK -Message 'Die Ersteinrichtung ist abgeschlossen (bzw. alle offenen Schritte wurden uebersprungen).'
            return
        }
        if (-not (Test-NetCommand -Name $naechster.Funktion)) {
            Write-Log -Level Warn -Message ('Schritt {0} ({1}) kommt in einer spaeteren Version und wird uebersprungen.' -f $naechster.Nr, $naechster.Name)
            $uebersprungen += $naechster.Nr
            continue
        }
        $versuche[$naechster.Nr] = 1 + [int]$versuche[$naechster.Nr]
        if ($versuche[$naechster.Nr] -gt 1) {
            Write-Log -Level Warn -Message ('Schritt {0} ({1}) ist noch nicht abgeschlossen.' -f $naechster.Nr, $naechster.Name)
            $wahl = Read-NetChoice -Frage 'Wie weiter?' -Optionen @('Schritt erneut ausfuehren', 'Schritt ueberspringen', 'Assistent beenden') -Vorschlag 1
            if ($wahl -eq 1) { $uebersprungen += $naechster.Nr; continue }
            if ($wahl -ne 0) { return }
        }
        elseif (-not (Read-NetYesNo -Frage ('Naechster Schritt: {0}. {1}. Jetzt ausfuehren?' -f $naechster.Nr, $naechster.Name) -Vorschlag $true)) {
            Write-Log -Message 'Assistent beendet. Er kann jederzeit erneut gestartet werden und macht dort weiter.'
            return
        }
        $script:NS.AssistentAktiv = $true
        try { & $naechster.Funktion }
        catch { Write-NetError -Fehler $_ -Titel $naechster.Name | Out-Null }
        finally { $script:NS.AssistentAktiv = $false }
        if ($naechster.Nr -eq 5) { $uebersprungen += 5 }
        if ($script:NS.NeustartGeplant) {
            Write-Log -Message 'Nach dem Neustart setzt NetSetup den Assistenten automatisch fort.'
            return
        }
    }
}
