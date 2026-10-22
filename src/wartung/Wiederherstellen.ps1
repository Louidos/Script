# Wiederherstellen (Stufe Gefaehrlich) und Rueckgaengig.
# DHCP: Restore-DhcpServer (Datenbank) oder Import-DhcpServer (Export-Datei).
# DNS: Eintraege aus der CSV neu anlegen (vorhandene bleiben, nichts wird doppelt angelegt).

function Select-NetBackup {
    param([Parameter(Mandatory = $true)][string]$Bereich, [string]$Titel = 'Backup waehlen')
    $liste = @(Get-NetBackupList | Where-Object { $_.Bereiche -contains $Bereich })
    if ($liste.Count -eq 0) { Write-Log -Level Warn -Message "Es gibt kein Backup mit dem Bereich $Bereich."; return $null }
    return (Select-NetItem -Elemente $liste -Titel $Titel -Eigenschaften @('Zeit', 'Anlass', 'Bereiche', 'Server'))
}

function Restore-NetDhcpBackup {
    <#
    .SYNOPSIS
        Stellt DHCP aus einem Backup wieder her (Gefaehrlich: vorher wird der aktuelle Stand gesichert).
    #>
    if (-not (Test-NetCommand -Name 'Restore-DhcpServer')) { Write-Log -Level Fehler -Message 'Die DHCP-Verwaltungstools fehlen (RSAT-DHCP).'; return $false }
    $b = Select-NetBackup -Bereich 'Dhcp' -Titel 'Aus welchem Backup wiederherstellen?'
    if (-not $b) { return $false }
    $art = Read-NetChoice -Frage 'Wie wiederherstellen?' -Optionen @(
        'Datenbank zuruecksetzen (Restore-DhcpServer) - alles wie zum Zeitpunkt des Backups, Dienst wird neu gestartet',
        'Konfiguration importieren (Import-DhcpServer) - Scopes, Optionen, Reservierungen und Leases werden ueberschrieben') -Vorschlag 1
    if ($art -lt 0) { return $false }
    $quelle = Join-Path -Path $b.Pfad -ChildPath 'Dhcp'
    $datenbank = Join-Path -Path $quelle -ChildPath 'Datenbank'
    $export = Join-Path -Path $quelle -ChildPath 'dhcp-export.xml'
    $r = Invoke-NetChange -Titel ('DHCP aus dem Backup vom {0} wiederherstellen' -f $b.Zeit) -Stufe Gefaehrlich -Vorher 'aktueller DHCP-Stand (wird vorher gesichert)' -Nachher ('Stand vom {0} ({1})' -f $b.Zeit, $b.Anlass) -BackupBereich @('Dhcp') `
        -Hinweis 'Alle Aenderungen seit dem Backup gehen verloren. Clients behalten ihre Adressen bis zur naechsten Erneuerung.' -Aktion {
        if ($art -eq 0) {
            $dienstOrdner = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupRestore'
            if (Test-Path -Path $dienstOrdner) { Remove-Item -Path $dienstOrdner -Recurse -Force }
            Copy-Item -Path $datenbank -Destination $dienstOrdner -Recurse -Force
            Restore-DhcpServer -Path $dienstOrdner -Force
            Restart-Service -Name DHCPServer -Force
        }
        else {
            $arbeit = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupImport'
            Import-DhcpServer -File $export -BackupPath $arbeit -Leases -ScopeOverwrite -Force
        }
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Get-NetDnsBackupRecord {
    param([Parameter(Mandatory = $true)][string]$Pfad)
    $datei = Join-Path -Path (Join-Path -Path $Pfad -ChildPath 'Dns') -ChildPath 'eintraege.csv'
    if (-not (Test-Path -Path $datei)) { return @() }
    $liste = @()
    foreach ($z in @(Import-Csv -Path $datei -Delimiter ';')) {
        $daten = @{}
        if ($z.Daten) { try { $daten = ConvertTo-NetHashtable -Objekt ($z.Daten | ConvertFrom-Json) } catch { $daten = @{} } }
        $liste += [pscustomobject]@{ Zone = $z.Zone; Name = $z.Name; Typ = $z.Typ; Wert = $z.Wert; Daten = $daten; Statisch = ($z.Statisch -eq 'True') }
    }
    return $liste
}

function Restore-NetDnsBackup {
    <#
    .SYNOPSIS
        Legt DNS-Eintraege aus der CSV eines Backups neu an (nur fehlende; fehlende Zonen auf Wunsch).
    #>
    if (-not (Test-NetDnsReady)) { return $false }
    $b = Select-NetBackup -Bereich 'Dns' -Titel 'Aus welchem Backup wiederherstellen?'
    if (-not $b) { return $false }
    $alle = @(Get-NetDnsBackupRecord -Pfad $b.Pfad | Where-Object { $script:NetDnsTypen -contains $_.Typ })
    $zonen = @($alle | ForEach-Object { $_.Zone } | Select-Object -Unique)
    $wahl = @(Select-NetItem -Elemente $zonen -Titel 'Welche Zonen wiederherstellen?' -Mehrfach)
    if ($wahl.Count -eq 0) { return $false }
    $vorhandeneZonen = @(Get-NetDnsZoneInfo | ForEach-Object { $_.Name })
    $plan = @()
    $neueZonen = @()
    foreach ($zone in $wahl) {
        if ($vorhandeneZonen -notcontains $zone) { $neueZonen += $zone }
        $jetzt = @()
        if ($vorhandeneZonen -contains $zone) { $jetzt = @(Get-NetDnsRecord -Zone $zone) }
        foreach ($e in @($alle | Where-Object { $_.Zone -eq $zone })) {
            $gleich = @($jetzt | Where-Object { $_.Name -eq $e.Name -and $_.Typ -eq $e.Typ -and (Test-NetDnsRecordEqual -A $e.Daten -B $_.Daten) })
            if ($gleich.Count -eq 0 -and $e.Daten.Count -gt 0) { $plan += $e }
        }
    }
    if ($plan.Count -eq 0 -and $neueZonen.Count -eq 0) { Write-Log -Level OK -Message 'Alle Eintraege aus dem Backup sind vorhanden. Nichts zu tun.'; return $true }
    $speicherung = $null
    if ($neueZonen.Count -gt 0) {
        Write-Log -Message ('Diese Zonen fehlen und werden angelegt: ' + ($neueZonen -join ', '))
        $speicherung = Read-NetDnsZoneStorage
        if (-not $speicherung) { return $false }
    }
    $rueck = @($plan | ForEach-Object { @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $_.Zone; Name = $_.Name; Typ = $_.Typ; Daten = $_.Daten } } })
    $r = Invoke-NetChange -Titel ('DNS aus dem Backup vom {0} wiederherstellen' -f $b.Zeit) -Stufe Gefaehrlich -Vorher ('{0} Eintraege fehlen' -f $plan.Count) -Nachher (@($neueZonen | ForEach-Object { 'Zone ' + $_ }) + @($plan | Select-Object -First 30 | ForEach-Object { '{0} {1} {2} in {3}' -f $_.Name, $_.Typ, $_.Wert, $_.Zone })) -BackupBereich @('Dns') -Aktion {
        foreach ($zone in $neueZonen) {
            $p = @{ Name = $zone; DynamicUpdate = $speicherung.Updates }
            if ($speicherung.AdIntegriert) { $p.ReplicationScope = $speicherung.Replikation } else { $p.ZoneFile = $zone + '.dns' }
            Add-DnsServerPrimaryZone @p
        }
        foreach ($e in $plan) { Add-NetDnsRecordExact -ZoneName $e.Zone -Name $e.Name -Typ $e.Typ -Daten $e.Daten }
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Undo-NetLastChange {
    $offen = @(Get-NetUndoEntry -NurOffen)
    if ($offen.Count -eq 0) { Write-Log -Message 'Es gibt keine Aenderung, die rueckgaengig gemacht werden kann.'; return }
    Write-Log -Message ('Letzte Aenderung: {0} ({1})' -f $offen[0].Titel, $offen[0].Zeit)
    Undo-NetChange -Id $offen[0].Id | Out-Null
}

function Undo-NetSelectedChange {
    $offen = @(Get-NetUndoEntry -NurOffen | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Zeit = $_.Zeit; Titel = $_.Titel; Benutzer = $_.Benutzer } })
    $w = Select-NetItem -Elemente $offen -Titel 'Welche Aenderung rueckgaengig machen?' -Eigenschaften @('Zeit', 'Titel', 'Benutzer')
    if ($w) {
        $spaeter = @($offen | Where-Object { $_.Zeit -gt $w.Zeit })
        if ($spaeter.Count -gt 0) { Write-Log -Level Warn -Message ('Danach gab es {0} weitere Aenderung(en). Diese bleiben bestehen und koennten von der alten Einstellung abhaengen.' -f $spaeter.Count) }
        Undo-NetChange -Id $w.Id | Out-Null
    }
}

function Show-NetChangeHistory {
    Write-NetTitle -Titel 'Aenderungsverlauf'
    $liste = @(Get-NetUndoEntry)
    if ($liste.Count -eq 0) { Write-Log -Message 'Noch keine Aenderungen.'; return }
    foreach ($e in $liste) {
        $farbe = 'Gray'
        if ($e.Status -ne 'Offen') { $farbe = 'DarkGray' }
        Write-Host ('  {0}  {1,-12} {2}' -f $e.Zeit, $e.Status, $e.Titel) -ForegroundColor $farbe
    }
}
