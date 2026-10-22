# DHCP-Failover: Partner pruefen (Rolle, autorisiert, erreichbar), Lastverteilung oder Reserve,
# gemeinsames Geheimnis verdeckt, Status anzeigen, Replikation ausloesen.

function Test-NetTcpPort {
    <#
    .SYNOPSIS
        Prueft, ob ein TCP-Port erreichbar ist (nur .NET-Bordmittel, mit Zeitlimit).
    #>
    param([Parameter(Mandatory = $true)][string]$Ziel, [Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Ziel, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($ar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Test-NetDhcpFailoverPartner {
    <#
    .SYNOPSIS
        Prueft den Failover-Partner. Liefert eine Liste von Problemen (leer = bereit).
    #>
    param([Parameter(Mandatory = $true)][string]$Partner)
    $probleme = @()
    $aufgeloest = Get-NetSafe -Beschreibung "Aufloesung $Partner" -Abfrage { Resolve-DnsName -Name $Partner -Type A -DnsOnly -QuickTimeout }
    if (-not $aufgeloest) { $probleme += "Der Name $Partner laesst sich im DNS nicht aufloesen." }
    if (-not (Test-NetTcpPort -Ziel $Partner -Port 647)) { $probleme += "$Partner ist auf TCP-Port 647 (DHCP-Failover) nicht erreichbar: DHCP-Dienst aus, Firewall oder falscher Name." }
    $einst = Get-NetSafe -Beschreibung "DHCP auf $Partner" -Abfrage { Get-DhcpServerSetting -ComputerName $Partner }
    if (-not $einst) { $probleme += "Auf $Partner ist kein DHCP-Server erreichbar (Rolle fehlt oder keine Rechte)." }
    elseif ($einst.IsDomainJoined -and -not $einst.IsAuthorized) { $probleme += "$Partner ist nicht im AD autorisiert." }
    return $probleme
}

function Show-NetDhcpFailover {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCP-Failover'
    $liste = @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover })
    if (@($liste | Where-Object { $_ }).Count -eq 0) { Write-Log -Message 'Kein Failover eingerichtet.'; return }
    foreach ($f in @($liste | Where-Object { $_ })) {
        $status = 'OK'
        if ([string]$f.State -ne 'Normal') { $status = 'WARN' }
        Write-NetStatus -Status $status -Bereich ([string]$f.Name) -Text ('Partner {0}, Modus {1}, Zustand {2}, Scopes {3}' -f $f.PartnerServer, $f.Mode, $f.State, ((@($f.ScopeId) | ForEach-Object { ConvertTo-NetString $_ }) -join ', '))
    }
}

function New-NetDhcpFailover {
    <#
    .SYNOPSIS
        Failover-Assistent. Bricht sauber ab, wenn der Partner nicht bereit ist.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    Write-NetTitle -Titel 'DHCP-Failover einrichten'
    Write-NetText -Text "Zwei DHCP-Server teilen sich Scopes. Lastverteilung: beide vergeben je die Haelfte. Reserve (Hot-Standby): einer arbeitet,`nder andere haelt einige Prozent zurueck und uebernimmt bei Ausfall. Der Partner braucht die DHCP-Rolle, muss autorisiert und ueber TCP 647 erreichbar sein."
    $partner = Read-NetText -Frage 'Name des Partner-DHCP-Servers (z. B. dc02.ad.firma.ch)' -Pruefung { param($t) if ($t -match '^[A-Za-z0-9.-]+$') { $null } else { 'Ungueltiger Name.' } }
    if (-not $partner) { return $false }
    Write-Log -Message "Pruefe den Partner $partner ..."
    $probleme = @(Test-NetDhcpFailoverPartner -Partner $partner)
    if ($probleme.Count -gt 0) {
        foreach ($p in $probleme) { Write-Log -Level Fehler -Message $p }
        Write-Log -Message 'Der Partner ist nicht bereit. Es wurde nichts geaendert. Naechster Schritt: auf dem Partner NetSetup ausfuehren (DHCP-Rolle installieren, autorisieren) und Firewall pruefen.'
        return $false
    }
    Write-Log -Level OK -Message "Der Partner $partner ist bereit."
    $vorhanden = @(Get-NetSafe -Beschreibung 'Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover } | Where-Object { $_ } | ForEach-Object { @($_.ScopeId | ForEach-Object { ConvertTo-NetString $_ }) })
    $frei = @(Get-NetDhcpScopeList | Where-Object { $vorhanden -notcontains $_.ScopeId })
    if ($frei.Count -eq 0) { Write-Log -Level Warn -Message 'Alle Scopes sind bereits in einer Failover-Beziehung (oder es gibt keine).'; return $false }
    $wahl = @(Select-NetItem -Elemente $frei -Titel 'Welche Scopes sollen ausfallsicher werden?' -Eigenschaften @('ScopeId', 'Name', 'Start', 'Ende') -Mehrfach)
    if ($wahl.Count -eq 0) { return $false }
    $modus = Read-NetChoice -Frage 'Modus' -Optionen @('Lastverteilung 50/50 (empfohlen)', 'Reserve / Hot-Standby (dieser Server aktiv, Partner haelt 5 % zurueck)') -Vorschlag 1
    if ($modus -lt 0) { return $false }
    Write-NetText -Text 'Das gemeinsame Geheimnis sichert die Verbindung der beiden Server. Es wird nicht gespeichert.'
    $geheim = Read-NetSecret -Frage 'Gemeinsames Geheimnis' -Bestaetigen -MinLaenge 8
    if (-not $geheim) { return $false }
    $name = Read-NetText -Frage 'Name der Failover-Beziehung' -Vorschlag (('{0}-{1}' -f [Environment]::MachineName, $partner.Split('.')[0]).ToUpper())
    if (-not $name) { return $false }
    $ids = @($wahl | ForEach-Object { $_.ScopeId })
    $art = 'Lastverteilung 50 %'
    if ($modus -eq 1) { $art = 'Reserve (Hot-Standby), 5 % Reserve' }
    $r = Invoke-NetChange -Titel "DHCP-Failover $name mit $partner einrichten" -Stufe Bestaetigen -Vorher '(kein Failover)' -Nachher @{ Name = $name; Partner = $partner; Modus = $art; Scopes = ($ids -join ', '); Geheimnis = '(verdeckt)' } -BackupBereich @('Dhcp') -Aktion {
        $klar = ConvertFrom-NetSecureString -Geheim $geheim
        try {
            if ($modus -eq 0) { Add-DhcpServerv4Failover -Name $name -PartnerServer $partner -ScopeId $ids -LoadBalancePercent 50 -SharedSecret $klar -Force }
            else { Add-DhcpServerv4Failover -Name $name -PartnerServer $partner -ScopeId $ids -ServerRole Active -ReservePercent 5 -SharedSecret $klar -Force }
        }
        finally { $klar = $null }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Failover'; Parameter = @{ Name = $name; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Sync-NetDhcpFailover {
    <#
    .SYNOPSIS
        Repliziert die Scope-Einstellungen zum Partner (Optionen, Reservierungen, Ausschluesse).
    #>
    if (-not (Test-NetDhcpReady)) { return }
    $liste = @(Get-NetSafe -Beschreibung 'Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover } | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Partner = [string]$_.PartnerServer; Zustand = [string]$_.State } })
    $f = Select-NetItem -Elemente $liste -Titel 'Welche Failover-Beziehung replizieren?' -Eigenschaften @('Name', 'Partner', 'Zustand')
    if (-not $f) { return }
    $name = $f.Name
    Invoke-NetChange -Titel "Einstellungen von $name zum Partner replizieren" -Stufe Bestaetigen -Vorher 'Partner hat evtl. veraltete Einstellungen' -Nachher 'Partner hat die Einstellungen dieses Servers' -Hinweis 'Die Einstellungen dieses Servers ueberschreiben die des Partners fuer die betroffenen Scopes.' -BackupBereich @('Dhcp') -Aktion {
        Invoke-DhcpServerv4FailoverReplication -Name $name -Force | Out-Null
    } | Out-Null
}

function Show-NetDhcpFailoverMenu {
    $eintraege = @(
        @{ Text = 'Status anzeigen'; Aktion = 'Show-NetDhcpFailover'; Hilfe = 'Zeigt alle Failover-Beziehungen mit Partner, Modus, Zustand (Normal = in Ordnung) und Scopes.' },
        @{ Text = 'Failover einrichten (Assistent)'; Aktion = { New-NetDhcpFailover | Out-Null }; Hilfe = "Prueft zuerst den Partner (Name, TCP 647, DHCP-Rolle, Autorisierung) und bricht sauber ab, wenn er nicht bereit ist.`nDann Lastverteilung oder Reserve waehlen und ein gemeinsames Geheimnis verdeckt eingeben." },
        @{ Text = 'Replikation ausloesen'; Aktion = 'Sync-NetDhcpFailover'; Hilfe = 'Nach Aenderungen an Optionen, Reservierungen oder Ausschluessen: Einstellungen zum Partner uebertragen.' }
    )
    Show-NetMenu -Titel 'DHCP - Failover' -Eintraege $eintraege
}
