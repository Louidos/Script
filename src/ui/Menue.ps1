# Menue-Baustein: Auswahl per Nummer, Hilfe mit ? und ?N, Glossar mit G.
# Ein Eintrag ist eine Hashtable: @{ Text = '...'; Aktion = 'Funktionsname' oder { ... }; Hilfe = '...' }
# Ist die Funktion (noch) nicht vorhanden, erscheint der Punkt als "kommt noch".

function Test-NetMenuEntry {
    <#
    .SYNOPSIS
        Prueft, ob ein Menuepunkt ausfuehrbar ist.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Eintrag)
    if ($Eintrag.ContainsKey('Bereit') -and -not $Eintrag.Bereit) { return $false }
    if ($Eintrag.Aktion -is [scriptblock]) { return $true }
    if ($Eintrag.Aktion -is [string] -and $Eintrag.Aktion) { return (Test-NetCommand -Name $Eintrag.Aktion) }
    return $false
}

function Invoke-NetMenuAction {
    <#
    .SYNOPSIS
        Fuehrt einen Menuepunkt aus. Fehler werden angezeigt, das Menue laeuft weiter.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Eintrag)
    try {
        if ($Eintrag.Aktion -is [scriptblock]) { & $Eintrag.Aktion }
        else { & $Eintrag.Aktion }
    }
    catch {
        Write-NetError -Fehler $_ -Titel $Eintrag.Text | Out-Null
    }
}

function Show-NetMenuHelp {
    param([Parameter(Mandatory = $true)][string]$Titel, [object[]]$Eintraege, [string]$Einleitung, [int]$StartNummer = 1)
    Write-NetTitle -Titel ('Hilfe: ' + $Titel)
    if ($Einleitung) { Write-NetText -Text $Einleitung -Farbe White; Write-Host '' }
    for ($i = 0; $i -lt $Eintraege.Count; $i++) {
        $e = $Eintraege[$i]
        Write-Host ('  [{0}] {1}' -f ($i + $StartNummer), $e.Text) -ForegroundColor White
        $hilfe = [string]$e.Hilfe
        if (-not $hilfe) { $hilfe = 'Keine Hilfe hinterlegt.' }
        Write-NetText -Text ('    ' + ($hilfe -replace "`n", "`n    "))
        if (-not (Test-NetMenuEntry -Eintrag $e)) { Write-Host '      (kommt noch: in dieser Version noch nicht verfuegbar)' -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-NetText -Text 'Bedienung: Nummer eingeben und Enter. ?3 zeigt die Hilfe zu Punkt 3, G das Glossar, 0 geht zurueck.' -Farbe DarkCyan
}

function Show-NetMenu {
    <#
    .SYNOPSIS
        Zeigt ein Menue in einer Schleife, bis 0 gewaehlt wird.
    .PARAMETER Kopf
        Scriptblock, der vor den Menuepunkten Statusinformationen ausgibt.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Titel,
        [Parameter(Mandatory = $true)][object[]]$Eintraege,
        [scriptblock]$Kopf,
        [string]$Einleitung,
        [string]$ZurueckText = 'Zurueck'
    )
    while ($true) {
        Write-NetTitle -Titel $Titel
        if (Test-NetDryRun) { Write-Host '  [PROBELAUF AKTIV] Es wird nichts geaendert.' -ForegroundColor Magenta }
        if ($Kopf) {
            try { & $Kopf }
            catch { Write-NetError -Fehler $_ -Titel 'Statusanzeige' | Out-Null }
        }
        for ($i = 0; $i -lt $Eintraege.Count; $i++) {
            $e = $Eintraege[$i]
            if (Test-NetMenuEntry -Eintrag $e) {
                Write-Host ('  [{0,2}] {1}' -f ($i + 1), $e.Text)
            }
            else {
                Write-Host ('  [{0,2}] {1}  (kommt noch)' -f ($i + 1), $e.Text) -ForegroundColor DarkGray
            }
        }
        Write-Host ('  [ 0] {0}' -f $ZurueckText)
        Write-Host '  ?  = Hilfe   ?N = Hilfe zu Punkt N   G = Glossar' -ForegroundColor DarkCyan
        $eingabe = Read-NetInput -Prompt 'Auswahl'
        if ($null -eq $eingabe) { return }
        $eingabe = ([string]$eingabe).Trim()
        if ($eingabe -eq '') { continue }
        if ($eingabe -eq '0') { return }
        if ($eingabe -eq '?') {
            Show-NetMenuHelp -Titel $Titel -Eintraege $Eintraege -Einleitung $Einleitung
            Wait-NetKey
            continue
        }
        if ($eingabe -match '^\?\s*(\d+)$') {
            $nr = [int]$Matches[1]
            if ($nr -ge 1 -and $nr -le $Eintraege.Count) {
                Show-NetMenuHelp -Titel $Titel -Eintraege @($Eintraege[$nr - 1]) -StartNummer $nr
            }
            else { Write-Host '[WARN]   Diese Nummer gibt es nicht.' -ForegroundColor Yellow }
            Wait-NetKey
            continue
        }
        if ($eingabe -match '^[gG]$') {
            Show-NetGlossary
            Wait-NetKey
            continue
        }
        $nummer = 0
        if ([int]::TryParse($eingabe, [ref]$nummer) -and $nummer -ge 1 -and $nummer -le $Eintraege.Count) {
            $e = $Eintraege[$nummer - 1]
            if (-not (Test-NetMenuEntry -Eintrag $e)) {
                Write-Host ('[--]     "{0}" kommt in einer spaeteren Version.' -f $e.Text) -ForegroundColor DarkGray
                if ($e.Hilfe) { Write-NetText -Text $e.Hilfe }
                Wait-NetKey
                continue
            }
            Write-Log -Level Debug -Message ('Menue {0}: {1}' -f $Titel, $e.Text)
            Invoke-NetMenuAction -Eintrag $e
            if (-not $e.OhnePause) { Wait-NetKey }
            continue
        }
        Write-Host '[WARN]   Unbekannte Eingabe. Bitte eine Nummer, ? oder G eingeben.' -ForegroundColor Yellow
    }
}

function Select-NetItem {
    <#
    .SYNOPSIS
        Auswahl aus einer Liste: mit Desktop-Oberflaeche per Out-GridView, sonst per Nummernliste.
    .PARAMETER Eigenschaften
        Angezeigte Eigenschaften. Ohne Angabe wird der Text des Elements gezeigt.
    .OUTPUTS
        Das gewaehlte Element (bzw. die Elemente bei -Mehrfach) oder $null bei Abbruch.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Elemente = @(),
        [string]$Titel = 'Auswahl',
        [string[]]$Eigenschaften,
        [switch]$Mehrfach,
        [switch]$OhneGridView
    )
    $liste = @($Elemente | Where-Object { $null -ne $_ })
    if ($liste.Count -eq 0) {
        Write-Log -Level Warn -Message ('{0}: keine Eintraege vorhanden.' -f $Titel)
        return $null
    }
    if (-not $script:NS.Interaktiv) { return $null }

    $anzeige = @()
    for ($i = 0; $i -lt $liste.Count; $i++) {
        $e = $liste[$i]
        $zeile = [ordered]@{ Nr = $i + 1 }
        if ($Eigenschaften) {
            foreach ($p in $Eigenschaften) {
                $wert = $e.$p
                if (($wert -is [System.Collections.IEnumerable]) -and ($wert -isnot [string])) { $wert = (@($wert) | ForEach-Object { [string]$_ }) -join ', ' }
                $zeile[$p] = $wert
            }
        }
        else { $zeile['Eintrag'] = [string]$e }
        $anzeige += [pscustomobject]$zeile
    }

    $grid = (-not $OhneGridView) -and $script:NS.Umgebung -and $script:NS.Umgebung.HatGridView -and [bool](Get-NetConfigValue -Pfad 'Allgemein.GridView' -Standard $true)
    if ($grid) {
        try {
            $modus = 'Single'
            if ($Mehrfach) { $modus = 'Multiple' }
            $gewaehlt = @($anzeige | Out-GridView -Title $Titel -OutputMode $modus)
            if ($gewaehlt.Count -eq 0) { return $null }
            $treffer = @($gewaehlt | ForEach-Object { $liste[$_.Nr - 1] })
            if ($Mehrfach) { return $treffer }
            return $treffer[0]
        }
        catch {
            Write-Log -Level Debug -Message 'Out-GridView nicht nutzbar, Nummernliste wird verwendet.'
        }
    }

    Write-Host ''
    Write-Host ('  ' + $Titel) -ForegroundColor White
    $text = ($anzeige | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
    foreach ($z in ($text -split "`r?`n")) { Write-Host ('  ' + $z) }
    $frage = 'Nummer (0 = abbrechen)'
    if ($Mehrfach) { $frage = 'Nummern, z. B. 1,3-5 oder * fuer alle (0 = abbrechen)' }
    $anzahl = $liste.Count
    $eingabe = Read-NetText -Frage $frage -Pruefung {
        param($t)
        if ($t -eq '0') { return $null }
        if (ConvertTo-NetNumberList -Text $t -Maximum $anzahl -Mehrfach:$Mehrfach) { return $null }
        return "Ungueltige Auswahl. Erlaubt sind Nummern von 1 bis $anzahl."
    }
    if (($null -eq $eingabe) -or ($eingabe -eq '0')) { return $null }
    $nummern = ConvertTo-NetNumberList -Text $eingabe -Maximum $anzahl -Mehrfach:$Mehrfach
    $treffer = @($nummern | ForEach-Object { $liste[$_ - 1] })
    if ($Mehrfach) { return $treffer }
    return $treffer[0]
}

function ConvertTo-NetNumberList {
    <#
    .SYNOPSIS
        Wandelt "1,3-5" oder "*" in eine Liste von Nummern. Liefert $null bei ungueltiger Eingabe.
    #>
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Maximum, [switch]$Mehrfach)
    $t = $Text.Trim()
    if ($t -eq '*') {
        if (-not $Mehrfach) { return $null }
        return @(1..$Maximum)
    }
    $nummern = @()
    foreach ($teil in $t.Split(',')) {
        $teil = $teil.Trim()
        if ($teil -match '^(\d+)$') { $nummern += [int]$Matches[1] }
        elseif ($Mehrfach -and $teil -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { return $null }
            $nummern += @($a..$b)
        }
        else { return $null }
    }
    $nummern = @($nummern | Select-Object -Unique)
    if ($nummern.Count -eq 0) { return $null }
    if ((-not $Mehrfach) -and $nummern.Count -ne 1) { return $null }
    foreach ($n in $nummern) { if ($n -lt 1 -or $n -gt $Maximum) { return $null } }
    return $nummern
}
