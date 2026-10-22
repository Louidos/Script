# Zentraler Ablauf fuer jede Aenderung am Server:
# Zusammenfassung -> Bestaetigung (je nach Stufe) -> Backup -> Ausfuehren -> Log -> Gegenaktion merken.
# Der Probelauf (Einstellung oder -WhatIf) zeigt nur an, was passieren wuerde.

# Module, deren Befehle als Gegenaktion in der Rueckgaengig-Liste stehen duerfen.
$script:NetUndoModule = @('DnsServer', 'DhcpServer', 'NetTCPIP', 'DnsClient', 'NetSecurity', 'ActiveDirectory', 'ServerManager', 'ScheduledTasks', 'Microsoft.PowerShell.Management')

function Format-NetValue {
    <#
    .SYNOPSIS
        Wandelt Werte fuer die Vorher/Nachher-Anzeige in Textzeilen um.
    #>
    param([AllowNull()][object]$Wert)
    if ($null -eq $Wert) { return @('(nichts)') }
    if ($Wert -is [string]) {
        if ($Wert -eq '') { return @('(leer)') }
        return @($Wert -split "`r?`n")
    }
    if ($Wert -is [System.Collections.IDictionary]) {
        $zeilen = @()
        foreach ($k in ($Wert.Keys | Sort-Object)) {
            $v = $Wert[$k]
            if (($v -is [System.Collections.IEnumerable]) -and ($v -isnot [string])) { $v = (@($v) | ForEach-Object { [string]$_ }) -join ', ' }
            if (($null -eq $v) -or ([string]$v -eq '')) { $v = '(leer)' }
            $zeilen += ('{0} = {1}' -f $k, $v)
        }
        if ($zeilen.Count -eq 0) { $zeilen = @('(nichts)') }
        return $zeilen
    }
    if ($Wert -is [System.Collections.IEnumerable]) {
        $zeilen = @($Wert | ForEach-Object { [string]$_ })
        if ($zeilen.Count -eq 0) { $zeilen = @('(nichts)') }
        return $zeilen
    }
    return @([string]$Wert)
}

function Test-NetDryRun {
    <#
    .SYNOPSIS
        Liefert $true, wenn der Probelauf aktiv ist (Einstellung oder -WhatIf).
    #>
    return ([bool]$script:NS.Probelauf -or [bool]$WhatIfPreference)
}

function Invoke-NetChange {
    <#
    .SYNOPSIS
        Fuehrt eine Aenderung sicher aus (Bestaetigung, Backup, Log, Rueckgaengig, Probelauf).
    .PARAMETER Stufe
        Automatisch (harmlos, ohne Frage), Bestaetigen (J/N), Gefaehrlich (Backup + Servername eintippen).
    .PARAMETER Rueckgaengig
        Gegenaktion(en) als Hashtable oder Liste von Hashtables: @{ Befehl = '...'; Parameter = @{...} }.
    .PARAMETER BackupBereich
        Bereiche, die vorher gesichert werden: Dhcp, Dns, Config, Netzwerk, AD.
    .NOTES
        Der Aktion-Scriptblock sieht die Variablen des Aufrufers (dynamischer Gueltigkeitsbereich).
        Er darf deshalb keine Variablen mit den Parameternamen dieser Funktion verwenden
        (Titel, Stufe, Vorher, Nachher, Aktion, Rueckgaengig, BackupBereich, Hinweis).
    .OUTPUTS
        PSCustomObject mit Erfolg, Probelauf, Abgebrochen, Ergebnis, Fehler.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Titel,
        [ValidateSet('Automatisch', 'Bestaetigen', 'Gefaehrlich')][string]$Stufe = 'Bestaetigen',
        [AllowNull()][object]$Vorher,
        [AllowNull()][object]$Nachher,
        [Parameter(Mandatory = $true)][scriptblock]$Aktion,
        [object]$Rueckgaengig,
        [string[]]$BackupBereich = @(),
        [string]$Hinweis,
        [switch]$OhneRueckfrage
    )
    $ncErgebnis = [pscustomobject]@{ Erfolg = $false; Probelauf = $false; Abgebrochen = $false; Ergebnis = $null; Fehler = $null }
    $ncProbelauf = Test-NetDryRun

    # 1. Zusammenfassung und Bestaetigung
    if ($Stufe -eq 'Automatisch' -or $OhneRueckfrage) {
        Write-Log -Message ('Aenderung: ' + $Titel)
    }
    else {
        $ncOk = Confirm-NetChange -Titel $Titel -Vorher $Vorher -Nachher $Nachher -Hinweis $Hinweis -Stufe $Stufe
        if (-not $ncOk) {
            Write-Log -Level Warn -Message ('Abgebrochen: ' + $Titel)
            $ncErgebnis.Abgebrochen = $true
            return $ncErgebnis
        }
        if ($Stufe -eq 'Gefaehrlich' -and -not $ncProbelauf) {
            if (-not (Confirm-NetDangerous -Titel $Titel)) {
                Write-Log -Level Warn -Message ('Abgebrochen (Servername nicht bestaetigt): ' + $Titel)
                $ncErgebnis.Abgebrochen = $true
                return $ncErgebnis
            }
        }
    }

    # 2. Probelauf
    if ($ncProbelauf) {
        Write-Host ('[PROBELAUF] Wuerde ausfuehren: ' + $Titel) -ForegroundColor Magenta
        Write-Log -Level Debug -Message ('Probelauf, nicht ausgefuehrt: ' + $Titel)
        $ncErgebnis.Probelauf = $true
        $ncErgebnis.Erfolg = $true
        return $ncErgebnis
    }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $Titel)) {
        $ncErgebnis.Probelauf = $true
        return $ncErgebnis
    }

    # 3. Backup (Pflicht bei Gefaehrlich)
    $ncBereiche = @($BackupBereich)
    if ($Stufe -eq 'Gefaehrlich' -and $ncBereiche.Count -eq 0) { $ncBereiche = @('Config') }
    if ($ncBereiche.Count -gt 0) {
        $ncBackupOk = Invoke-NetBackupHook -Bereich $ncBereiche -Anlass $Titel
        if ((-not $ncBackupOk) -and $Stufe -eq 'Gefaehrlich') {
            Write-Log -Level Fehler -Message 'Das Backup ist fehlgeschlagen. Gefaehrliche Aenderungen werden ohne Backup nicht ausgefuehrt.'
            Write-Log -Message 'Naechster Schritt: Speicherplatz und Rechte im Datenordner pruefen, dann erneut versuchen.'
            $ncErgebnis.Abgebrochen = $true
            return $ncErgebnis
        }
    }

    # 4. Ausfuehren
    $ncSchritt = Invoke-NetStep -Titel $Titel -Aktion $Aktion
    $ncErgebnis.Erfolg = $ncSchritt.Erfolg
    $ncErgebnis.Ergebnis = $ncSchritt.Ergebnis
    $ncErgebnis.Fehler = $ncSchritt.Fehler

    # 5. Gegenaktion merken
    if ($ncSchritt.Erfolg -and $Rueckgaengig) {
        Add-NetUndoEntry -Titel $Titel -Schritte $Rueckgaengig | Out-Null
    }
    return $ncErgebnis
}

function Invoke-NetBackupHook {
    <#
    .SYNOPSIS
        Ruft das automatische Backup auf (Wartungsmodul). Liefert $true bei Erfolg.
    #>
    param([string[]]$Bereich = @('Config'), [string]$Anlass = '')
    if (Test-NetCommand -Name 'Backup-NetSetupData') {
        try {
            $r = Backup-NetSetupData -Bereich $Bereich -Anlass $Anlass -Automatisch
            return [bool]$r
        }
        catch {
            Write-NetError -Fehler $_ -Titel 'Automatisches Backup' | Out-Null
            return $false
        }
    }
    # Ohne Wartungsmodul: wenigstens die Konfiguration sichern
    try {
        $datei = Get-NetPath -Name ConfigDatei
        if (Test-Path -Path $datei) {
            $ziel = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('netsetup_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -Path $datei -Destination $ziel -Force -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-NetError -Fehler $_ -Titel 'Sicherung der Konfiguration' | Out-Null
        return $false
    }
}

function ConvertTo-NetUndoStep {
    param([Parameter(Mandatory = $true)][object]$Schritte)
    $liste = @()
    foreach ($s in @($Schritte)) {
        if ($null -eq $s) { continue }
        $h = ConvertTo-NetHashtable -Objekt $s
        if (-not $h.Befehl) { continue }
        if ($null -eq $h.Parameter) { $h.Parameter = @{} }
        $liste += , $h
    }
    return $liste
}

function Get-NetUndoEntry {
    <#
    .SYNOPSIS
        Liest die Rueckgaengig-Liste (neueste zuerst).
    #>
    param([switch]$NurOffen)
    $datei = Get-NetPath -Name Verlauf
    if (-not (Test-Path -Path $datei)) { return @() }
    try {
        $daten = ConvertTo-NetHashtable -Objekt (Get-Content -Path $datei -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Log -Level Warn -Message 'Die Rueckgaengig-Liste ist beschaedigt und kann nicht gelesen werden.'
        return @()
    }
    $liste = @($daten | Where-Object { $_ -is [hashtable] })
    if ($NurOffen) { $liste = @($liste | Where-Object { $_.Status -eq 'Offen' }) }
    return @($liste | Sort-Object -Property { $_.Zeit } -Descending)
}

function Save-NetUndoList {
    param([object[]]$Liste)
    $datei = Get-NetPath -Name Verlauf
    $ordner = Split-Path -Path $datei -Parent
    if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Liste) -Depth 10
    Set-Content -Path $datei -Value $json -Encoding UTF8 -ErrorAction Stop
}

function Add-NetUndoEntry {
    <#
    .SYNOPSIS
        Merkt eine Aenderung mit ihrer Gegenaktion in der Rueckgaengig-Liste.
    #>
    param([Parameter(Mandatory = $true)][string]$Titel, [Parameter(Mandatory = $true)][object]$Schritte)
    try {
        $eintrag = @{
            Id       = [guid]::NewGuid().ToString()
            Zeit     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Titel    = $Titel
            Benutzer = [Environment]::UserName
            Schritte = @(ConvertTo-NetUndoStep -Schritte $Schritte)
            Status   = 'Offen'
        }
        $liste = @(Get-NetUndoEntry)
        $liste = @($eintrag) + $liste
        Save-NetUndoList -Liste $liste
        Write-Log -Level Debug -Message ('Gegenaktion gemerkt: ' + $Titel)
        return $eintrag
    }
    catch {
        Write-Log -Level Warn -Message ('Die Gegenaktion fuer "' + $Titel + '" konnte nicht gespeichert werden. Rueckgaengig ist dafuer nicht moeglich.')
        Write-Log -Level Debug -Message $_.Exception.ToString()
        return $null
    }
}

function Test-NetUndoCommand {
    <#
    .SYNOPSIS
        Erlaubt als Gegenaktion nur Befehle aus bekannten Windows-Modulen oder NetSetup-Funktionen.
    #>
    param([Parameter(Mandatory = $true)][string]$Befehl)
    $cmd = Get-Command -Name $Befehl -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    if ($cmd.CommandType -eq 'Function' -and $Befehl -match '^[A-Za-z]+-Net') { return $true }
    return ($script:NetUndoModule -contains [string]$cmd.ModuleName)
}

function Undo-NetChange {
    <#
    .SYNOPSIS
        Fuehrt die Gegenaktion eines Eintrags der Rueckgaengig-Liste aus.
    #>
    param([Parameter(Mandatory = $true)][string]$Id)
    $liste = @(Get-NetUndoEntry)
    $eintrag = $liste | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $eintrag) { Write-Log -Level Fehler -Message 'Eintrag nicht gefunden.'; return $false }
    if ($eintrag.Status -ne 'Offen') { Write-Log -Level Warn -Message 'Diese Aenderung wurde bereits rueckgaengig gemacht.'; return $false }
    $schritte = @(ConvertTo-NetUndoStep -Schritte $eintrag.Schritte)
    $beschreibung = @($schritte | ForEach-Object { $_.Befehl + ' ' + (($_.Parameter.Keys | Sort-Object | ForEach-Object { '-' + $_ }) -join ' ') })
    foreach ($s in $schritte) {
        if (-not (Test-NetUndoCommand -Befehl $s.Befehl)) {
            Write-Log -Level Fehler -Message ("Der Befehl '{0}' ist als Gegenaktion nicht erlaubt oder nicht vorhanden." -f $s.Befehl)
            return $false
        }
    }
    $aktion = {
        foreach ($s in $schritte) {
            $p = $s.Parameter
            & $s.Befehl @p
        }
    }
    $r = Invoke-NetChange -Titel ('Rueckgaengig: ' + $eintrag.Titel) -Stufe Bestaetigen -Vorher ('Aenderung vom ' + $eintrag.Zeit) -Nachher $beschreibung -Aktion $aktion -BackupBereich @('Config')
    if ($r.Erfolg -and -not $r.Probelauf) {
        foreach ($e in $liste) { if ($e.Id -eq $Id) { $e.Status = 'Rueckgaengig'; $e.RueckgaengigAm = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
        Save-NetUndoList -Liste $liste
        return $true
    }
    return $false
}
