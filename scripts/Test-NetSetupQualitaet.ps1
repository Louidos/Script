<#
.SYNOPSIS
    Qualitaetspruefungen fuer src/ und dist/NetSetup.ps1 (lokal und in der CI).
.DESCRIPTION
    Prueft:
      - nur ASCII-Zeichen, keine Tabs
      - fehlerfrei parsbar mit [System.Management.Automation.Language.Parser]::ParseFile
      - keine Eintraege aus der Verbotsliste (Downloads, Module aus dem Internet, URLs, fremde DLLs,
        $PSScriptRoot, $MyInvocation.MyCommand.Path, #Requires)
      - dist: Scriptblock-Rahmen, kein param()-Block, keine leeren Zeilen
      - src: keine Here-Strings mit leeren Zeilen (der Build ersetzt leere Zeilen durch '#')
.PARAMETER Pfad
    Zu pruefende Dateien oder Ordner. Standard: src und dist/NetSetup.ps1.
.EXAMPLE
    ./scripts/Test-NetSetupQualitaet.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Pfad
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
if (-not $Pfad) { $Pfad = @((Join-Path -Path $root -ChildPath 'src'), (Join-Path -Path $root -ChildPath 'dist/NetSetup.ps1')) }

# Verbotsliste: im fertigen Script nur Bordmittel, kein Internet.
$verboten = [ordered]@{
    'Install-Module'                  = '\bInstall-Module\b'
    'Find-Module'                     = '\bFind-Module\b'
    'Save-Module'                     = '\bSave-Module\b'
    'Install-PackageProvider'         = '\bInstall-PackageProvider\b'
    'Invoke-WebRequest'               = '\bInvoke-WebRequest\b|\biwr\b'
    'Invoke-RestMethod'               = '\bInvoke-RestMethod\b|\birm\b'
    'Start-BitsTransfer'              = '\bStart-BitsTransfer\b'
    'Net.WebClient'                   = 'Net\.WebClient|\bWebClient\b'
    'HttpClient'                      = '\bHttpClient\b|\bHttpWebRequest\b|\bWebRequest\]'
    'Download'                        = '\.Download(String|File|Data)\b'
    'URL'                             = '(?i)\b(https?|ftp)://'
    'fremde DLL'                      = 'Add-Type\s+[^\r\n]*-Path|Add-Type\s+[^\r\n]*-AssemblyName\s+[^\r\n]*\.dll|::Load(From|File)\(|Import-Module\s+[^\r\n]*\.dll'
    '$PSScriptRoot'                   = '\$PSScriptRoot'
    '$MyInvocation.MyCommand.Path'    = '\$MyInvocation\.MyCommand\.Path'
    '#Requires'                       = '(?im)^\s*#requires'
}

$fehler = New-Object System.Collections.Generic.List[string]
$dateien = @()
foreach ($p in $Pfad) {
    if (Test-Path -Path $p -PathType Container) { $dateien += @(Get-ChildItem -Path $p -Recurse -File -Include '*.ps1', '*.psd1') }
    elseif (Test-Path -Path $p) { $dateien += @(Get-Item -Path $p) }
    else { $fehler.Add("Pfad nicht gefunden: $p") }
}

foreach ($datei in $dateien) {
    $name = $datei.FullName.Substring($root.Length).TrimStart('\', '/')
    $bytes = [System.IO.File]::ReadAllBytes($datei.FullName)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $zeilen = $text -split "`n"

    # ASCII und Tabs
    $zeile = 1
    $spalte = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 10) { $zeile++; $spalte = 0; continue }
        $spalte++
        if ($b -gt 127) { $fehler.Add(('{0}:{1}:{2} Nicht-ASCII-Zeichen (Byte 0x{3:X2}). Umlaute als ae/oe/ue schreiben.' -f $name, $zeile, $spalte, $b)) }
        if ($b -eq 9) { $fehler.Add(('{0}:{1}:{2} Tabulator gefunden. Nur Leerzeichen verwenden.' -f $name, $zeile, $spalte)) }
    }

    # Parsen
    $tokens = $null
    $parseFehler = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($datei.FullName, [ref]$tokens, [ref]$parseFehler)
    foreach ($pf in $parseFehler) {
        $fehler.Add(('{0}:{1}:{2} Parse-Fehler: {3}' -f $name, $pf.Extent.StartLineNumber, $pf.Extent.StartColumnNumber, $pf.Message))
    }

    # Verbotsliste (Kommentare eingeschlossen: auch Links in Hilfetexten sind verboten)
    for ($n = 0; $n -lt $zeilen.Count; $n++) {
        foreach ($k in $verboten.Keys) {
            if ($zeilen[$n] -match $verboten[$k]) {
                $fehler.Add(('{0}:{1} Verboten im Script: {2}' -f $name, ($n + 1), $k))
            }
        }
    }

    # Here-Strings ohne leere Zeilen (src)
    foreach ($t in $tokens) {
        if (($t.Kind -eq 'HereStringLiteral' -or $t.Kind -eq 'HereStringExpandable') -and ($t.Text -match "`n\s*`r?`n")) {
            $fehler.Add(('{0}:{1} Here-String mit leerer Zeile. Der Build ersetzt leere Zeilen durch #, bitte Zeile mit Inhalt fuellen.' -f $name, $t.Extent.StartLineNumber))
        }
    }

    # Besondere Regeln fuer die fertige Einzeldatei
    if ($datei.Name -eq 'NetSetup.ps1' -and $name -match '^dist') {
        if ($ast.ParamBlock) { $fehler.Add("${name}: param()-Block auf oberster Ebene ist nicht erlaubt.") }
        $anweisungen = @($ast.EndBlock.Statements)
        if ($anweisungen.Count -ne 2) {
            $fehler.Add("${name}: Erwartet genau zwei Anweisungen: `$NetSetupCode = { ... } und & `$NetSetupCode @args.")
        }
        else {
            if ($anweisungen[0].Extent.Text -notmatch '^\$NetSetupCode\s*=\s*\{') { $fehler.Add("${name}: Erste Anweisung muss `$NetSetupCode = { sein.") }
            if ($anweisungen[1].Extent.Text.Trim() -ne '& $NetSetupCode @args') { $fehler.Add("${name}: Letzte Anweisung muss & `$NetSetupCode @args sein.") }
        }
        for ($n = 0; $n -lt $zeilen.Count - 1; $n++) {
            if ($zeilen[$n].Trim() -eq '') { $fehler.Add(('{0}:{1} Leere Zeile in der Einzeldatei (stoert beim Einfuegen in die Konsole).' -f $name, ($n + 1))) }
        }
        if ($text -notmatch "NetSetupVersion = '") { $fehler.Add("${name}: `$script:NetSetupVersion fehlt.") }
    }
}

if ($fehler.Count -gt 0) {
    $fehler | ForEach-Object { Write-Host $_ }
    Write-Error ('{0} Problem(e) gefunden.' -f $fehler.Count)
    exit 1
}
Write-Host ('Qualitaetspruefung bestanden: {0} Datei(en) ohne Befund (ASCII, Tabs, Parser, Verbotsliste).' -f $dateien.Count)
exit 0
