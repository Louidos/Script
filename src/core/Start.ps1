# Einstieg: Argumente lesen, Voraussetzungen pruefen, Datenordner, Log, Config,
# Script speichern, dann Hauptmenue oder eine Aufgabe ohne Menue (-Task).

$script:NetTasks = @('Health', 'Report', 'Backup', 'Resume')

function ConvertFrom-NetArgument {
    <#
    .SYNOPSIS
        Liest die Argumente aus $args: -Task <Name>, -Probelauf bzw. -WhatIf.
    #>
    param([object[]]$Argumente = @())
    $opt = @{ Task = $null; Probelauf = $false; Unbekannt = @(); Fehler = $null }
    $liste = @($Argumente)
    for ($i = 0; $i -lt $liste.Count; $i++) {
        $a = [string]$liste[$i]
        if ($a -match '^-(Task|Aufgabe):(.+)$') { $opt.Task = $Matches[2] }
        elseif ($a -match '^-(Task|Aufgabe)$') {
            if ($i + 1 -lt $liste.Count) { $opt.Task = [string]$liste[$i + 1]; $i++ }
            else { $opt.Fehler = '-Task braucht einen Namen: ' + ($script:NetTasks -join ', ') }
        }
        elseif ($a -match '^-(WhatIf|Probelauf)(:\$?true)?$') { $opt.Probelauf = $true }
        elseif ($a) { $opt.Unbekannt += $a }
    }
    if ($opt.Task) {
        $treffer = $script:NetTasks | Where-Object { $_ -ieq $opt.Task.Trim() } | Select-Object -First 1
        if ($treffer) { $opt.Task = $treffer }
        else { $opt.Fehler = "Unbekannte Aufgabe '$($opt.Task)'. Moeglich sind: " + ($script:NetTasks -join ', ') }
    }
    return $opt
}

function Initialize-NetDataRoot {
    <#
    .SYNOPSIS
        Bestimmt den Datenordner. Beim ersten Start kann er geaendert werden.
    #>
    $zeiger = Get-NetDataRootPointer
    if ($zeiger) { $script:NS.Datenpfad = $zeiger }
    if (Test-Path -Path (Get-NetPath -Name ConfigDatei)) { return }
    $script:NS.ErsterStart = $true
    if (-not $script:NS.Interaktiv) { return }
    Write-Host ''
    Write-Log -Message 'Erster Start: NetSetup speichert Konfiguration, Logs, Backups und Berichte in einem Ordner.'
    $pfad = Read-NetText -Frage 'Datenordner' -Vorschlag $script:NS.Datenpfad -Pruefung {
        param($t)
        if ($t -notmatch '^[A-Za-z]:\\') { return 'Bitte einen lokalen Pfad mit Laufwerk angeben, z. B. C:\NetSetup.' }
        if ($t -match '[<>"|?*]') { return 'Der Pfad enthaelt unerlaubte Zeichen.' }
        return $null
    }
    if ($pfad) {
        $pfad = $pfad.TrimEnd('\')
        if ($pfad -ne $script:NS.StandardPfad) { Set-NetDataRootPointer -Pfad $pfad | Out-Null }
        $script:NS.Datenpfad = $pfad
    }
}

function Invoke-NetTask {
    <#
    .SYNOPSIS
        Fuehrt eine Aufgabe ohne Menue aus (geplante Aufgabe, RunOnce).
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Log -Message ('Aufgabe ohne Menue: ' + $Name)
    $funktion = @{
        Health = 'Invoke-NetHealthTask'
        Report = 'Invoke-NetReportTask'
        Backup = 'Invoke-NetBackupTask'
        Resume = 'Resume-NetSetup'
    }[$Name]
    if (-not (Test-NetCommand -Name $funktion)) {
        Write-Log -Level Warn -Message "Die Aufgabe '$Name' kommt in einer spaeteren Version von NetSetup."
        return
    }
    try { & $funktion }
    catch { Write-NetError -Fehler $_ -Titel ('Aufgabe ' + $Name) | Out-Null }
}

function Start-NetSetup {
    <#
    .SYNOPSIS
        Startpunkt von NetSetup. Stuerzt nie ab: unbekannte Zustaende werden gemeldet und geloggt.
    #>
    param([object[]]$Argumente = @())
    $opt = ConvertFrom-NetArgument -Argumente $Argumente
    if ($opt.Probelauf) { $script:NS.Probelauf = $true }
    if ($opt.Task -and $opt.Task -ne 'Resume') { $script:NS.Interaktiv = $false }
    try {
        Write-NetTitle -Titel ('NetSetup {0} - AD, DNS und DHCP fuer Windows Server' -f $script:NS.Version)
        if ($opt.Fehler) {
            Write-Log -Level Fehler -Message $opt.Fehler
            return
        }
        foreach ($u in $opt.Unbekannt) { Write-Log -Level Warn -Message "Unbekanntes Argument wird ignoriert: $u" }

        $umgebung = Get-NetEnvironment
        $vor = Test-NetPrerequisite -Umgebung $umgebung
        if ($vor -ne 'OK') { return }

        Initialize-NetDataRoot
        Initialize-NetFolder | Out-Null
        Initialize-NetLog
        Start-NetTranscript
        Import-NetConfig | Out-Null
        if ($opt.Probelauf) { $script:NS.Probelauf = $true }
        if ($script:NS.ErsterStart) { Save-NetConfig }
        Write-Log -Level Debug -Message ('Umgebung: ' + (($umgebung.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; '))
        Save-NetSelf | Out-Null

        if ($opt.Task) {
            Invoke-NetTask -Name $opt.Task
            return
        }

        if ($umgebung.IstCore) { Write-Log -Message 'Server Core erkannt: Listen erscheinen als Nummernliste.' }
        if (-not $umgebung.IstCore -and -not $script:NS.Config.Allgemein.VerknuepfungGefragt) {
            $script:NS.Config.Allgemein.VerknuepfungGefragt = $true
            Save-NetConfig
            if (Read-NetYesNo -Frage 'Desktop-Verknuepfung "NetSetup" anlegen (startet als Administrator)?' -Vorschlag $true) {
                New-NetDesktopShortcut | Out-Null
            }
        }
        if (Test-NetCommand -Name 'Show-NetStartOverview') { Show-NetStartOverview }
        if (Test-NetCommand -Name 'Invoke-NetResumeCheck') { Invoke-NetResumeCheck }
        Show-NetMainMenu
    }
    catch {
        Write-NetError -Fehler $_ -Titel 'NetSetup' | Out-Null
        Write-Log -Message 'NetSetup wurde sicher beendet. Bitte erneut starten; Details stehen im Log.'
    }
    finally {
        Stop-NetTranscript
    }
}
