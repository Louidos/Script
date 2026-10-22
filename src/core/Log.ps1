# Logging: jede Meldung in die Logdatei und farbig in die Konsole.
# Passwoerter werden nie uebergeben und deshalb nie geloggt.

function Write-Log {
    <#
    .SYNOPSIS
        Schreibt eine Meldung in die Logdatei und farbig in die Konsole.
    .PARAMETER Level
        Info, OK, Warn, Fehler, Debug (nur Datei), Titel.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Write-Log gibt es in Windows PowerShell 5.1 nicht; der Name ist vorgegeben.')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'OK', 'Warn', 'Fehler', 'Debug', 'Titel')][string]$Level = 'Info',
        [switch]$NurDatei
    )
    $zeit = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($script:NS.LogDatei) {
        try {
            Add-Content -Path $script:NS.LogDatei -Value ('{0} [{1}] {2}' -f $zeit, $Level.ToUpper(), $Message) -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            $script:NS.LogDatei = $null
            Write-Host '[WARN]   Logdatei nicht beschreibbar, ab jetzt nur Konsolenausgabe.' -ForegroundColor Yellow
        }
    }
    if ($NurDatei -or $Level -eq 'Debug') { return }
    switch ($Level) {
        'OK' { Write-Host ('[OK]     ' + $Message) -ForegroundColor Green }
        'Warn' { Write-Host ('[WARN]   ' + $Message) -ForegroundColor Yellow }
        'Fehler' { Write-Host ('[FEHLER] ' + $Message) -ForegroundColor Red }
        'Titel' { Write-Host ''; Write-Host ('=== ' + $Message + ' ===') -ForegroundColor Cyan }
        default { Write-Host ('         ' + $Message) }
    }
}

function Write-NetStatus {
    <#
    .SYNOPSIS
        Zeigt eine Statuszeile mit [OK], [WARN], [FEHLER] oder [--].
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'WARN', 'FEHLER', 'NA', 'INFO')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Bereich,
        [string]$Text = ''
    )
    $marke = @{ OK = '[OK]    '; WARN = '[WARN]  '; FEHLER = '[FEHLER]'; NA = '[--]    '; INFO = '[INFO]  ' }[$Status]
    $farbe = @{ OK = 'Green'; WARN = 'Yellow'; FEHLER = 'Red'; NA = 'DarkGray'; INFO = 'Cyan' }[$Status]
    Write-Host ('{0} {1,-22} {2}' -f $marke, $Bereich, $Text) -ForegroundColor $farbe
    Write-Log -Level Debug -Message ('Status {0} {1}: {2}' -f $Status, $Bereich, $Text)
}

function Write-NetTitle {
    param([Parameter(Mandatory = $true)][string]$Titel)
    $linie = '=' * ([Math]::Max(40, $Titel.Length + 8))
    Write-Host ''
    Write-Host $linie -ForegroundColor Cyan
    Write-Host ('    ' + $Titel) -ForegroundColor Cyan
    Write-Host $linie -ForegroundColor Cyan
}

function Write-NetText {
    <#
    .SYNOPSIS
        Gibt einen mehrzeiligen Text eingerueckt aus (Hilfe, Erklaerungen).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [string]$Farbe = 'Gray')
    foreach ($zeile in ($Text -split "`r?`n")) {
        Write-Host ('  ' + $zeile) -ForegroundColor $Farbe
    }
}

function Initialize-NetLog {
    <#
    .SYNOPSIS
        Setzt die Logdatei des Tages im Ordner Logs.
    #>
    $ordner = Get-NetPath -Name Logs
    if (Test-Path -Path $ordner) {
        $script:NS.LogDatei = Join-Path -Path $ordner -ChildPath ('NetSetup_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Write-Log -Level Debug -Message ('--- NetSetup {0} gestartet als {1} auf {2} ---' -f $script:NS.Version, [Environment]::UserName, [Environment]::MachineName)
    }
}

function Start-NetTranscript {
    <#
    .SYNOPSIS
        Startet ein Transcript der Sitzung (Konsole und ISE), Fehler werden ignoriert.
    #>
    if ($script:NS.TranscriptAktiv) { return }
    $ordner = Get-NetPath -Name Logs
    if (-not (Test-Path -Path $ordner)) { return }
    $datei = Join-Path -Path $ordner -ChildPath ('Transcript_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        Start-Transcript -Path $datei -Append -ErrorAction Stop | Out-Null
        $script:NS.TranscriptAktiv = $true
    }
    catch {
        Write-Log -Level Debug -Message "Transcript nicht moeglich: $($_.Exception.Message)"
    }
}

function Stop-NetTranscript {
    if (-not $script:NS.TranscriptAktiv) { return }
    try { Stop-Transcript -ErrorAction Stop | Out-Null }
    catch { Write-Log -Level Debug -Message 'Transcript war bereits beendet.' }
    $script:NS.TranscriptAktiv = $false
}
