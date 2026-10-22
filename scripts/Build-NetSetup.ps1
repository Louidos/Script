<#
.SYNOPSIS
    Baut dist/NetSetup.ps1 aus den Quelldateien in src/.
.DESCRIPTION
    Fuegt die Dateien in der Reihenfolge aus build.psd1 in den Scriptblock-Rahmen ein
    ($NetSetupCode = { ... } und am Ende & $NetSetupCode @args), schreibt Version und
    Builddatum in den Kommentarkopf und in $script:NetSetupVersion.
    Der Eintrag '@checks' in build.psd1 steht fuer alle Dateien in src/checks (alphabetisch).
    Leere Zeilen werden durch '#' ersetzt, damit das Einfuegen in die Konsole
    (auch ohne PSReadLine) nicht vorzeitig ausfuehrt.
.PARAMETER Check
    Baut nur im Speicher und schlaegt fehl, wenn dist/NetSetup.ps1 nicht aktuell ist.
.EXAMPLE
    ./scripts/Build-NetSetup.ps1
.EXAMPLE
    ./scripts/Build-NetSetup.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$projekt = Import-PowerShellDataFile -Path (Join-Path -Path $root -ChildPath 'build.psd1')
$ziel = Join-Path -Path (Join-Path -Path $root -ChildPath 'dist') -ChildPath 'NetSetup.ps1'

function Get-NetBuildSourceFile {
    param([string]$Root, [object[]]$Liste)
    $dateien = @()
    foreach ($eintrag in $Liste) {
        if ($eintrag -eq '@checks') {
            $ordner = Join-Path -Path $Root -ChildPath 'src/checks'
            $dateien += @(Get-ChildItem -Path $ordner -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
                    Sort-Object -Property Name |
                    ForEach-Object { 'src/checks/' + $_.Name })
        }
        else { $dateien += [string]$eintrag }
    }
    return $dateien
}

function ConvertTo-NetBuildLine {
    param([string]$Text)
    $zeilen = @()
    foreach ($zeile in ($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n").Split("`n")) {
        if ($zeile.Trim() -eq '') { $zeilen += '#' }
        else { $zeilen += $zeile.TrimEnd() }
    }
    return $zeilen
}

$version = [string]$projekt.Version
$buildDatum = Get-Date -Format 'yyyy-MM-dd HH:mm'
if ($Check -and (Test-Path -Path $ziel)) {
    $alt = [System.IO.File]::ReadAllText($ziel)
    if ($alt -match "NetSetupBuildDatum = '([^']*)'") { $buildDatum = $Matches[1] }
}

$quellen = Get-NetBuildSourceFile -Root $root -Liste $projekt.Dateien
$zeilen = New-Object System.Collections.Generic.List[string]
foreach ($z in @(
        '<#',
        ('    NetSetup {0} (Build {1})' -f $version, $buildDatum),
        '    AD, DNS und DHCP auf Windows Server einrichten, verwalten und reparieren.',
        '',
        '    So starten (PowerShell oder PowerShell ISE als Administrator):',
        '      a) Den ganzen Text in die PowerShell-Konsole einfuegen und Enter druecken.',
        '      b) In PowerShell ISE in ein neues Script einfuegen und F5 druecken.',
        '      c) Als NetSetup.ps1 speichern und starten:',
        '         powershell.exe -ExecutionPolicy Bypass -File NetSetup.ps1',
        '    Ohne Menue: -Task Health | Report | Backup | Resume',
        '',
        '    Diese Datei wird mit scripts/Build-NetSetup.ps1 aus src/ erzeugt.',
        '    Nicht von Hand bearbeiten.',
        '#>',
        '$NetSetupCode = {',
        ("`$script:NetSetupVersion = '{0}'" -f $version),
        ("`$script:NetSetupBuildDatum = '{0}'" -f $buildDatum)
    )) {
    if ($z -eq '') { $zeilen.Add('#') } else { $zeilen.Add($z) }
}
foreach ($quelle in $quellen) {
    $pfad = Join-Path -Path $root -ChildPath $quelle
    if (-not (Test-Path -Path $pfad)) { throw "Quelldatei fehlt: $quelle (siehe build.psd1)" }
    $zeilen.Add('# ' + ('-' * 70))
    $zeilen.Add('# ' + $quelle)
    $zeilen.Add('# ' + ('-' * 70))
    foreach ($z in (ConvertTo-NetBuildLine -Text ([System.IO.File]::ReadAllText($pfad)))) { $zeilen.Add($z) }
}
$zeilen.Add('# ' + ('-' * 70))
$zeilen.Add('Start-NetSetup -Argumente $args')
$zeilen.Add('}')
$zeilen.Add('& $NetSetupCode @args')
$inhalt = ($zeilen -join "`r`n") + "`r`n"

if ($Check) {
    if (-not (Test-Path -Path $ziel)) {
        Write-Error 'dist/NetSetup.ps1 fehlt. Bitte ./scripts/Build-NetSetup.ps1 ausfuehren und committen.'
        exit 1
    }
    $vorhanden = [System.IO.File]::ReadAllText($ziel) -replace "`r`n", "`n"
    if ($vorhanden -ne ($inhalt -replace "`r`n", "`n")) {
        Write-Error 'dist/NetSetup.ps1 ist nicht aktuell. Bitte ./scripts/Build-NetSetup.ps1 ausfuehren und das Ergebnis committen.'
        exit 1
    }
    Write-Host ('dist/NetSetup.ps1 ist aktuell (Version {0}, {1} Quelldateien, {2} Zeilen).' -f $version, $quellen.Count, $zeilen.Count)
    exit 0
}

$distOrdner = Split-Path -Path $ziel -Parent
if (-not (Test-Path -Path $distOrdner)) { New-Item -Path $distOrdner -ItemType Directory | Out-Null }
[System.IO.File]::WriteAllText($ziel, $inhalt, (New-Object System.Text.ASCIIEncoding))
Write-Host ('dist/NetSetup.ps1 gebaut: Version {0}, {1} Quelldateien, {2} Zeilen.' -f $version, $quellen.Count, $zeilen.Count)
