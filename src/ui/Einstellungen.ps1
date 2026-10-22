# Einstellungen: Probelauf, Auto-Reparatur, Backups, Auswahlfenster, Datenordner, Vorschlagswerte.

function Switch-NetDryRun {
    $script:NS.Probelauf = -not $script:NS.Probelauf
    $script:NS.Config.Allgemein.Probelauf = $script:NS.Probelauf
    Save-NetConfig
    if ($script:NS.Probelauf) { Write-Log -Level OK -Message 'Probelauf ist jetzt AN: es wird nur angezeigt, nichts geaendert.' }
    else { Write-Log -Level OK -Message 'Probelauf ist jetzt AUS: Aenderungen werden nach Bestaetigung ausgefuehrt.' }
}

function Switch-NetAutoRepair {
    $neu = -not [bool]$script:NS.Config.Allgemein.AutoReparatur
    $script:NS.Config.Allgemein.AutoReparatur = $neu
    Save-NetConfig
    Write-Log -Level OK -Message ('Automatische Reparatur harmloser Fehler im Doktor: {0}' -f $(if ($neu) { 'AN' } else { 'AUS' }))
}

function Switch-NetGridView {
    $neu = -not [bool]$script:NS.Config.Allgemein.GridView
    $script:NS.Config.Allgemein.GridView = $neu
    Save-NetConfig
    Write-Log -Level OK -Message ('Auswahlfenster (Out-GridView): {0}' -f $(if ($neu) { 'AN' } else { 'AUS' }))
    if ($neu -and $script:NS.Umgebung -and -not $script:NS.Umgebung.HatGridView) {
        Write-Log -Level Warn -Message 'Auf diesem Server gibt es keine Auswahlfenster (Server Core). Es wird weiter die Nummernliste verwendet.'
    }
}

function Set-NetBackupRetention {
    $aktuell = [int](Get-NetConfigValue -Pfad 'Allgemein.BackupAufbewahrung' -Standard 20)
    $neu = Read-NetNumber -Frage 'Wie viele Backups aufbewahren?' -Minimum 1 -Maximum 500 -Vorschlag $aktuell
    if ($null -eq $neu) { return }
    $script:NS.Config.Allgemein.BackupAufbewahrung = $neu
    Save-NetConfig
    Write-Log -Level OK -Message "Es werden die letzten $neu Backups aufbewahrt."
}

function Set-NetSuggestion {
    <#
    .SYNOPSIS
        Vorschlagswerte bearbeiten (Weiterleitungen, Lease-Dauer, Scavenging, Dienstkonto).
    #>
    $v = $script:NS.Config.Vorschlaege
    $text = Read-NetText -Frage 'DNS-Weiterleitungen (mit Komma getrennt)' -Vorschlag ((@($v.Weiterleitungen)) -join ',') -Pruefung {
        param($t)
        foreach ($ip in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $ip.Trim())) { return "'$ip' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if ($null -eq $text) { return }
    $lease = Read-NetNumber -Frage 'Lease-Dauer in Tagen' -Minimum 1 -Maximum 999 -Vorschlag ([int]$v.LeaseTage)
    if ($null -eq $lease) { return }
    $noRefresh = Read-NetNumber -Frage 'Scavenging: No-Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag ([int]$v.NoRefreshTage)
    if ($null -eq $noRefresh) { return }
    $refresh = Read-NetNumber -Frage 'Scavenging: Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag ([int]$v.RefreshTage)
    if ($null -eq $refresh) { return }
    $konto = Read-NetText -Frage 'Name des Dienstkontos fuer DHCP-DNS-Eintraege' -Vorschlag ([string]$v.DnsDienstkonto) -Pruefung {
        param($t)
        if ($t -notmatch '^[A-Za-z0-9._-]{1,20}$') { return 'Erlaubt sind 1 bis 20 Zeichen: Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.' }
        return $null
    }
    if ($null -eq $konto) { return }
    $v.Weiterleitungen = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $v.LeaseTage = $lease
    $v.NoRefreshTage = $noRefresh
    $v.RefreshTage = $refresh
    $v.DnsDienstkonto = $konto
    if (($noRefresh + $refresh) -lt $lease) {
        Write-Log -Level Warn -Message 'No-Refresh + Refresh ist kuerzer als die Lease-Dauer. Dann koennten Eintraege aktiver Clients geloescht werden. Empfehlung: Summe mindestens so lang wie die Lease-Dauer.'
    }
    Save-NetConfig
    Write-Log -Level OK -Message 'Vorschlagswerte gespeichert.'
}

function Set-NetDataRoot {
    <#
    .SYNOPSIS
        Datenordner aendern. Konfiguration und Script werden in den neuen Ordner kopiert.
    #>
    $alt = Get-NetPath -Name Root
    $neu = Read-NetText -Frage 'Neuer Datenordner' -Vorschlag $alt -Pruefung {
        param($t)
        if ($t -notmatch '^[A-Za-z]:\\') { return 'Bitte einen lokalen Pfad mit Laufwerk angeben, z. B. D:\NetSetup.' }
        if ($t -match '[<>"|?*]') { return 'Der Pfad enthaelt unerlaubte Zeichen.' }
        return $null
    }
    if (($null -eq $neu) -or ($neu.TrimEnd('\') -eq $alt.TrimEnd('\'))) { return }
    $neu = $neu.TrimEnd('\')
    $r = Invoke-NetChange -Titel 'Datenordner aendern' -Stufe Bestaetigen -Vorher $alt -Nachher $neu -Hinweis 'Logs und Backups bleiben im alten Ordner liegen. Konfiguration und Script werden kopiert.' -Aktion {
        $script:NS.Datenpfad = $neu
        Initialize-NetFolder | Out-Null
        Save-NetConfig
        Set-NetDataRootPointer -Pfad $neu | Out-Null
        Initialize-NetLog
        Save-NetSelf | Out-Null
    }
    if (-not $r.Erfolg -or $r.Probelauf) { $script:NS.Datenpfad = $alt }
}

function Show-NetConfig {
    Write-NetTitle -Titel 'Aktuelle Konfiguration'
    Write-Host ('  Datei: {0}' -f (Get-NetPath -Name ConfigDatei)) -ForegroundColor DarkCyan
    $json = $script:NS.Config | ConvertTo-Json -Depth 12
    foreach ($z in ($json -split "`r?`n")) { Write-Host ('  ' + $z) }
    $probleme = Test-NetConfig -Config $script:NS.Config
    if ($probleme.Count -eq 0) { Write-Log -Level OK -Message 'Die Konfiguration ist gueltig.' }
    foreach ($p in $probleme) { Write-Log -Level Warn -Message $p }
}

function Show-NetSettingsMenu {
    $kopf = {
        $a = $script:NS.Config.Allgemein
        Write-Host ('  Probelauf            : {0}' -f $(if ($script:NS.Probelauf) { 'AN' } else { 'aus' }))
        Write-Host ('  Auto-Reparatur      : {0}' -f $(if ($a.AutoReparatur) { 'an' } else { 'AUS' }))
        Write-Host ('  Backups aufbewahren : {0}' -f $a.BackupAufbewahrung)
        Write-Host ('  Auswahlfenster      : {0}' -f $(if ($a.GridView) { 'an' } else { 'aus' }))
        Write-Host ('  Datenordner         : {0}' -f (Get-NetPath -Name Root))
        Write-Host ''
    }
    $eintraege = @(
        @{ Text = 'Probelauf an/aus'; Aktion = 'Switch-NetDryRun'; OhnePause = $true; Hilfe = 'Im Probelauf zeigt NetSetup alle geplanten Aenderungen, fuehrt aber nichts aus (wie -WhatIf). Gut zum Ausprobieren.' },
        @{ Text = 'Automatische Reparatur an/aus'; Aktion = 'Switch-NetAutoRepair'; OhnePause = $true; Hilfe = 'Wenn an, repariert der Doktor harmlose Fehler (Stufe Automatisch, z. B. gestoppten Dienst starten) ohne Rueckfrage. Alles andere wird immer gefragt.' },
        @{ Text = 'Anzahl aufbewahrter Backups'; Aktion = 'Set-NetBackupRetention'; Hilfe = 'Aeltere automatische Backups werden geloescht, sobald mehr als diese Anzahl vorhanden ist. Vorschlag: 20.' },
        @{ Text = 'Auswahlfenster (Out-GridView) an/aus'; Aktion = 'Switch-NetGridView'; OhnePause = $true; Hilfe = 'Mit Desktop-Oberflaeche koennen Listen in einem Fenster mit Suche angezeigt werden. Aus = immer Nummernliste in der Konsole.' },
        @{ Text = 'Vorschlagswerte bearbeiten'; Aktion = 'Set-NetSuggestion'; Hilfe = 'Weiterleitungen (Vorschlag 9.9.9.9 und 1.1.1.1), Lease-Dauer (8 Tage), Scavenging (7 + 7 Tage) und Name des Dienstkontos (svc-dhcpdns).' },
        @{ Text = 'Datenordner aendern'; Aktion = 'Set-NetDataRoot'; Hilfe = 'Ort fuer Konfiguration, Logs, Backups, Berichte, Rueckgaengig und Vorlagen. Standard: C:\NetSetup.' },
        @{ Text = 'Konfiguration anzeigen und pruefen'; Aktion = 'Show-NetConfig'; Hilfe = 'Zeigt die gespeicherte Konfiguration (JSON) und prueft sie auf Fehler.' },
        @{ Text = 'Script neu speichern'; Aktion = { Save-NetSelf | Out-Null }; Hilfe = 'Speichert die laufende Version von NetSetup als NetSetup.ps1 in den Datenordner.' },
        @{ Text = 'Desktop-Verknuepfung anlegen'; Aktion = 'New-NetDesktopShortcut'; Hilfe = 'Legt auf dem Desktop eine Verknuepfung "NetSetup" an, die NetSetup als Administrator startet (nur mit Desktop-Oberflaeche).' }
    )
    Show-NetMenu -Titel 'Einstellungen' -Eintraege $eintraege -Kopf $kopf
}
