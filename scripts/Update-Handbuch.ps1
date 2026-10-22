<#
.SYNOPSIS
    Schreibt die Menuepunkte (mit Hilfetexten) und das Glossar aus dem Script in docs/handbuch.md.
.DESCRIPTION
    Die Texte stehen nur einmal im Script (src/). Dieses Hilfsskript uebernimmt sie zwischen die
    Markierungen <!-- MENUES:START --> / <!-- MENUES:ENDE --> und <!-- GLOSSAR:START --> /
    <!-- GLOSSAR:ENDE --> im Handbuch. So stimmen Handbuch und Script immer ueberein.
.PARAMETER Check
    Aendert nichts und schlaegt fehl, wenn das Handbuch nicht aktuell ist (fuer Tests/CI).
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$handbuch = Join-Path -Path $root -ChildPath 'docs/handbuch.md'

# Quelldateien laden, ohne etwas auszufuehren (nur Funktionsdefinitionen und Texte).
$projekt = Import-PowerShellDataFile -Path (Join-Path -Path $root -ChildPath 'build.psd1')
foreach ($eintrag in $projekt.Dateien) {
    if ($eintrag -eq '@checks') {
        foreach ($c in (Get-ChildItem -Path (Join-Path -Path $root -ChildPath 'src/checks') -Filter '*.ps1' | Sort-Object -Property Name)) { . $c.FullName }
    }
    else { . (Join-Path -Path $root -ChildPath $eintrag) }
}

# Show-NetMenu ersetzen: statt anzuzeigen werden Titel und Eintraege gesammelt.
$script:gesammelt = New-Object System.Collections.Generic.List[object]
function Show-NetMenu {
    param([string]$Titel, [object[]]$Eintraege, [scriptblock]$Kopf, [string]$Einleitung, [string]$ZurueckText)
    $null = $Kopf, $Einleitung, $ZurueckText
    $script:gesammelt.Add([pscustomobject]@{ Titel = $Titel; Eintraege = $Eintraege })
}
$menues = @(
    'Show-NetMainMenu', 'Show-NetInventoryMenu', 'Show-NetAdMenu', 'Show-NetDnsMenu', 'Show-NetDnsZoneMenu', 'Show-NetDnsRecordMenu',
    'Show-NetDnsForwarderMenu', 'Show-NetDnsAgingMenu', 'Show-NetDhcpMenu', 'Show-NetDhcpScopeMenu', 'Show-NetDhcpExtraOptionMenu',
    'Show-NetDhcpReservationMenu', 'Show-NetDhcpFailoverMenu', 'Show-NetIntegrationMenu', 'Show-NetDoctorMenu', 'Show-NetReportMenu',
    'Show-NetMaintenanceMenu', 'Show-NetUndoMenu', 'Show-NetAdvancedMenu', 'Show-NetHelpMenu', 'Show-NetSettingsMenu'
)
$script:NS.Config = Get-NetDefaultConfig
foreach ($m in $menues) { & $m }

$nl = "`n"
$menueText = New-Object System.Text.StringBuilder
foreach ($menue in $script:gesammelt) {
    [void]$menueText.Append('### ' + $menue.Titel + $nl + $nl)
    $nr = 0
    foreach ($e in $menue.Eintraege) {
        $nr++
        $hilfe = ([string]$e.Hilfe -replace "`r", '').Trim()
        [void]$menueText.Append(('{0}. **{1}**' -f $nr, $e.Text) + $nl)
        foreach ($zeile in ($hilfe -split "`n")) { [void]$menueText.Append('   ' + $zeile.TrimEnd() + $nl) }
        [void]$menueText.Append($nl)
    }
}
$glossarText = New-Object System.Text.StringBuilder
foreach ($begriff in $script:NetGlossar.Keys) {
    [void]$glossarText.Append('**' + $begriff + '**' + $nl + ': ' + $script:NetGlossar[$begriff] + $nl + $nl)
}

function Set-NetBlock {
    param([string]$Text, [string]$Marke, [string]$Inhalt)
    $start = "<!-- $($Marke):START -->"
    $ende = "<!-- $($Marke):ENDE -->"
    $a = $Text.IndexOf($start)
    $b = $Text.IndexOf($ende)
    if ($a -lt 0 -or $b -lt $a) { throw "Markierung $Marke fehlt in docs/handbuch.md." }
    return $Text.Substring(0, $a + $start.Length) + $nl + $nl + $Inhalt.TrimEnd() + $nl + $nl + $Text.Substring($b)
}

$alt = [System.IO.File]::ReadAllText($handbuch) -replace "`r`n", "`n"
$neu = Set-NetBlock -Text $alt -Marke 'MENUES' -Inhalt $menueText.ToString()
$neu = Set-NetBlock -Text $neu -Marke 'GLOSSAR' -Inhalt $glossarText.ToString()
if ($Check) {
    if ($alt -ne $neu) { Write-Error 'docs/handbuch.md ist nicht aktuell. Bitte ./scripts/Update-Handbuch.ps1 ausfuehren und committen.'; exit 1 }
    Write-Host 'docs/handbuch.md ist aktuell.'
    exit 0
}
[System.IO.File]::WriteAllText($handbuch, $neu, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('docs/handbuch.md aktualisiert: {0} Menues, {1} Glossarbegriffe.' -f $script:gesammelt.Count, $script:NetGlossar.Count)
