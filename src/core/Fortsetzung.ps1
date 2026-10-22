# Neustart und Fortsetzung: der Stand wird im Datenordner gespeichert, ein RunOnce-Eintrag
# startet nach der Anmeldung die gespeicherte Datei mit -Task Resume.
# In der Fortsetzungsdatei stehen nie Kennwoerter.

$script:NetRunOncePfad = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

function Get-NetResumeState {
    $datei = Get-NetPath -Name Fortsetzung
    if (-not (Test-Path -Path $datei)) { return $null }
    try { return (ConvertTo-NetHashtable -Objekt (Get-Content -Path $datei -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)) }
    catch {
        Write-Log -Level Warn -Message 'Die Fortsetzungsdatei ist beschaedigt und wird ignoriert.'
        return $null
    }
}

function Save-NetResumeState {
    <#
    .SYNOPSIS
        Merkt den naechsten Schritt nach einem Neustart und traegt NetSetup in RunOnce ein.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Schritt,
        [hashtable]$Daten = @{},
        [string]$Beschreibung = ''
    )
    $stand = @{
        Schritt      = $Schritt
        Daten        = $Daten
        Beschreibung = $Beschreibung
        Zeit         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Assistent    = [bool]$script:NS.AssistentAktiv
        Version      = $script:NS.Version
    }
    $datei = Get-NetPath -Name Fortsetzung
    Set-Content -Path $datei -Value ($stand | ConvertTo-Json -Depth 8) -Encoding UTF8 -ErrorAction Stop
    $scriptDatei = Save-NetSelf
    if (-not $scriptDatei) { $scriptDatei = Get-NetPath -Name Script }
    $befehl = '"{0}" -NoProfile -ExecutionPolicy Bypass -NoExit -File "{1}" -Task Resume' -f (Get-NetPowerShellExe), $scriptDatei
    try {
        if (-not (Test-Path -Path $script:NetRunOncePfad)) { New-Item -Path $script:NetRunOncePfad -Force | Out-Null }
        Set-ItemProperty -Path $script:NetRunOncePfad -Name 'NetSetup' -Value $befehl -ErrorAction Stop
        Write-Log -Level OK -Message ('Fortsetzung nach dem Neustart vorbereitet: ' + $Beschreibung)
    }
    catch {
        Write-Log -Level Warn -Message 'Der automatische Start nach dem Neustart konnte nicht eingetragen werden.'
        Write-Log -Message ('Naechster Schritt: nach dem Neustart NetSetup von Hand starten: ' + $befehl)
    }
}

function Clear-NetResumeState {
    $datei = Get-NetPath -Name Fortsetzung
    if (Test-Path -Path $datei) { Remove-Item -Path $datei -Force -ErrorAction SilentlyContinue }
    try { Remove-ItemProperty -Path $script:NetRunOncePfad -Name 'NetSetup' -ErrorAction Stop }
    catch { Write-Log -Level Debug -Message 'Kein RunOnce-Eintrag vorhanden.' }
}

function Request-NetRestart {
    <#
    .SYNOPSIS
        Bietet den Neustart an. Die Fortsetzung muss vorher mit Save-NetResumeState gespeichert sein.
    #>
    param([Parameter(Mandatory = $true)][string]$Grund)
    $script:NS.NeustartGeplant = $true
    Write-Host ''
    Write-Log -Level Warn -Message ('Ein Neustart ist noetig: ' + $Grund)
    Write-Log -Message 'Nach der Anmeldung als Administrator startet NetSetup automatisch und macht an der richtigen Stelle weiter.'
    $r = Invoke-NetChange -Titel 'Server jetzt neu starten' -Stufe Bestaetigen -Hinweis 'Alle Verbindungen (auch Remotedesktop) werden getrennt.' -Aktion {
        Stop-NetTranscript
        Restart-Computer -Force
    }
    if (-not $r.Erfolg -or $r.Probelauf) {
        Write-Log -Message 'Kein Neustart. Bitte spaeter neu starten; NetSetup setzt danach automatisch fort.'
    }
}

function Resume-NetSetup {
    <#
    .SYNOPSIS
        Wird nach dem Neustart mit -Task Resume gestartet und setzt beim gespeicherten Schritt fort.
    #>
    $stand = Get-NetResumeState
    if (-not $stand) {
        Write-Log -Message 'Es gibt keine unterbrochene Einrichtung. Das Hauptmenue wird geoeffnet.'
    }
    else {
        Write-NetTitle -Titel 'Fortsetzung nach dem Neustart'
        Write-Log -Message ('Gespeicherter Schritt: {0} ({1}, {2})' -f $stand.Schritt, $stand.Beschreibung, $stand.Zeit)
        Invoke-NetResumeStep -Stand $stand
    }
    if (Test-NetCommand -Name 'Show-NetStartOverview') { Show-NetStartOverview }
    if ($stand -and $stand.Assistent -and -not $script:NS.NeustartGeplant -and (Test-NetCommand -Name 'Start-NetFirstSetup')) {
        if (Read-NetYesNo -Frage 'Den Ersteinrichtungs-Assistenten fortsetzen?' -Vorschlag $true) { Start-NetFirstSetup }
    }
    if (-not $script:NS.NeustartGeplant) { Show-NetMainMenu }
}

function Invoke-NetResumeStep {
    <#
    .SYNOPSIS
        Fuehrt den gespeicherten Schritt aus. Die Funktion des Schritts heisst Complete-Net<Schritt>.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Stand)
    $funktion = 'Complete-Net' + $Stand.Schritt
    Clear-NetResumeState
    if (-not (Test-NetCommand -Name $funktion)) {
        Write-Log -Level Warn -Message ("Der Schritt '{0}' ist in dieser Version unbekannt. Bitte im Menue von Hand fortfahren." -f $Stand.Schritt)
        return
    }
    $daten = $Stand.Daten
    if ($null -eq $daten) { $daten = @{} }
    $script:NS.AssistentAktiv = [bool]$Stand.Assistent
    try { & $funktion -Daten $daten }
    catch { Write-NetError -Fehler $_ -Titel ('Fortsetzung ' + $Stand.Schritt) | Out-Null }
}

function Invoke-NetResumeCheck {
    <#
    .SYNOPSIS
        Beim normalen Start: auf eine unterbrochene Einrichtung hinweisen und Fortsetzung anbieten.
    #>
    $stand = Get-NetResumeState
    if (-not $stand) { return }
    Write-Host ''
    Write-Log -Level Warn -Message ('Es gibt eine unterbrochene Einrichtung: {0} (gespeichert {1}).' -f $stand.Beschreibung, $stand.Zeit)
    if (Read-NetYesNo -Frage 'Jetzt fortsetzen?' -Vorschlag $true) {
        Invoke-NetResumeStep -Stand $stand
    }
    elseif (Read-NetYesNo -Frage 'Die gespeicherte Fortsetzung verwerfen?' -Vorschlag $false) {
        Clear-NetResumeState
        Write-Log -Level OK -Message 'Fortsetzung verworfen.'
    }
}
