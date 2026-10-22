# Berichte als HTML (alles inline: keine externen Links, Schriften oder Scripts) und CSV:
# Scope-Auslastung, freie IPs, Leases ohne DNS, Doktor-Ergebnis, Aenderungsverlauf.

$script:NetBerichtCss = @'
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; background: #fff; }
h1 { font-size: 22px; margin-bottom: 4px; }
h2 { font-size: 17px; margin-top: 28px; border-bottom: 2px solid #2b579a; padding-bottom: 4px; }
p.meta { color: #666; margin-top: 0; }
table { border-collapse: collapse; margin-top: 8px; width: 100%; }
th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; font-size: 13px; vertical-align: top; }
th { background: #eef2f8; }
tr:nth-child(even) td { background: #fafafa; }
.OK { color: #11722b; font-weight: bold; }
.WARN { color: #a35c00; font-weight: bold; }
.FEHLER { color: #b00020; font-weight: bold; }
.NA { color: #888; }
'@

function ConvertTo-NetHtmlText {
    param([AllowNull()][object]$Wert)
    if ($null -eq $Wert) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Wert)
}

function ConvertTo-NetHtmlTable {
    <#
    .SYNOPSIS
        Baut eine HTML-Tabelle aus Objekten. Spalte "Status" bekommt die Farbklasse.
    #>
    param([object[]]$Zeilen, [Parameter(Mandatory = $true)][string[]]$Spalten)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><tr>')
    foreach ($s in $Spalten) { [void]$sb.Append('<th>' + (ConvertTo-NetHtmlText $s) + '</th>') }
    [void]$sb.Append('</tr>')
    if (@($Zeilen).Count -eq 0) { [void]$sb.Append(('<tr><td colspan="{0}">keine Eintraege</td></tr>' -f $Spalten.Count)) }
    foreach ($z in @($Zeilen)) {
        [void]$sb.Append('<tr>')
        foreach ($s in $Spalten) {
            $w = $z.$s
            if (($w -is [System.Collections.IEnumerable]) -and ($w -isnot [string])) { $w = (@($w) | ForEach-Object { [string]$_ }) -join ', ' }
            $klasse = ''
            if ($s -eq 'Status') { $klasse = ' class="' + (ConvertTo-NetHtmlText $w) + '"' }
            [void]$sb.Append('<td' + $klasse + '>' + (ConvertTo-NetHtmlText $w) + '</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    return $sb.ToString()
}

function Get-NetFreeAddressRange {
    <#
    .SYNOPSIS
        Ermittelt die freien Adressen eines Scopes (Bereich minus Ausschluesse, Reservierungen, Leases)
        und fasst sie zu Bereichen zusammen.
    #>
    param([Parameter(Mandatory = $true)][string]$ScopeId, [Parameter(Mandatory = $true)][string]$Start, [Parameter(Mandatory = $true)][string]$Ende)
    $belegt = New-Object 'System.Collections.Generic.HashSet[uint32]'
    foreach ($a in @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $ScopeId })) {
        if (-not $a) { continue }
        $von = ConvertTo-NetIPv4UInt32 -IPAddress (ConvertTo-NetString $a.StartRange)
        $bis = ConvertTo-NetIPv4UInt32 -IPAddress (ConvertTo-NetString $a.EndRange)
        for ($x = $von; $x -le $bis; $x++) { [void]$belegt.Add([uint32]$x) }
    }
    foreach ($r in @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $ScopeId })) { if ($r) { [void]$belegt.Add((ConvertTo-NetIPv4UInt32 -IPAddress (ConvertTo-NetString $r.IPAddress))) } }
    foreach ($l in @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $ScopeId })) { if ($l) { [void]$belegt.Add((ConvertTo-NetIPv4UInt32 -IPAddress (ConvertTo-NetString $l.IPAddress))) } }
    $bereiche = @()
    $anfang = $null
    $s = ConvertTo-NetIPv4UInt32 -IPAddress $Start
    $e = ConvertTo-NetIPv4UInt32 -IPAddress $Ende
    $frei = 0
    for ($x = [int64]$s; $x -le [int64]$e; $x++) {
        if (-not $belegt.Contains([uint32]$x)) {
            $frei++
            if ($null -eq $anfang) { $anfang = $x }
        }
        elseif ($null -ne $anfang) {
            $bereiche += ('{0} - {1}' -f (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$anfang)), (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($x - 1))))
            $anfang = $null
        }
    }
    if ($null -ne $anfang) { $bereiche += ('{0} - {1}' -f (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$anfang)), (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$e))) }
    return [pscustomobject]@{ ScopeId = $ScopeId; Frei = $frei; Bereiche = $bereiche }
}

function Get-NetReportData {
    <#
    .SYNOPSIS
        Sammelt die Daten aller Berichtsteile.
    #>
    param([object[]]$DoktorErgebnis)
    $z = Get-NetSetupState
    $auslastung = @($z.Dhcp.Scopes | ForEach-Object {
            $st = 'OK'
            if ($_.Auslastung -ge 90) { $st = 'FEHLER' } elseif ($_.Auslastung -ge 80) { $st = 'WARN' }
            [pscustomobject]@{ Scope = $_.ScopeId; Name = $_.Name; Bereich = ($_.Start + ' - ' + $_.Ende); Aktiv = $_.Aktiv; Belegt = $_.Belegt; Frei = $_.Frei; Prozent = ('{0:N0}' -f $_.Auslastung); Status = $st }
        })
    $frei = @($z.Dhcp.Scopes | ForEach-Object {
            $f = Get-NetFreeAddressRange -ScopeId $_.ScopeId -Start $_.Start -Ende $_.Ende
            [pscustomobject]@{ Scope = $f.ScopeId; Frei = $f.Frei; Bereiche = ($f.Bereiche -join '; ') }
        })
    $ohneDns = @()
    if ($z.Dhcp.Verfuegbar -and $z.Dns.Verfuegbar) {
        $ohneDns = @(Get-NetLeaseDnsCheck -Zustand $z | Where-Object { -not ($_.A -and $_.PTR) } | ForEach-Object { [pscustomobject]@{ IP = $_.IP; Name = $_.Name; A = $(if ($_.A) { 'ja' } else { 'fehlt' }); PTR = $(if ($_.PTR) { 'ja' } else { 'fehlt' }); Ursache = $_.Ursache } })
    }
    if (-not $DoktorErgebnis) { $DoktorErgebnis = @(Invoke-NetDoctor -NurPruefen -Still) }
    $doktor = @($DoktorErgebnis | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Kategorie = $_.Kategorie; Titel = $_.Titel; Status = $_.Status; Detail = $(if ($_.Status -eq 'OK' -or $_.Status -eq 'NA') { $_.Detail } else { ($_.Problem + ' ' + $_.Detail).Trim() }) } })
    $verlauf = @(Get-NetUndoEntry | Select-Object -First 200 | ForEach-Object { [pscustomobject]@{ Zeit = $_.Zeit; Aenderung = $_.Titel; Benutzer = $_.Benutzer; Status = $(if ($_.Status -eq 'Offen') { 'aktiv' } else { $_.Status }) } })
    return [pscustomobject]@{ Zustand = $z; Auslastung = $auslastung; Frei = $frei; OhneDns = $ohneDns; Doktor = $doktor; Verlauf = $verlauf }
}

function New-NetReport {
    <#
    .SYNOPSIS
        Erstellt einen HTML-Bericht (alles inline) und je Teil eine CSV-Datei im Ordner Berichte.
    #>
    param([object[]]$DoktorErgebnis, [string]$Name = 'Bericht')
    $daten = Get-NetReportData -DoktorErgebnis $DoktorErgebnis
    $zeit = Get-Date
    $basis = Join-Path -Path (Get-NetPath -Name Berichte) -ChildPath ('{0}_{1}' -f $Name, $zeit.ToString('yyyyMMdd_HHmmss'))
    $teile = [ordered]@{
        'Scope-Auslastung'       = @{ Daten = $daten.Auslastung; Spalten = @('Scope', 'Name', 'Bereich', 'Aktiv', 'Belegt', 'Frei', 'Prozent', 'Status') }
        'Freie IP-Adressen'      = @{ Daten = $daten.Frei; Spalten = @('Scope', 'Frei', 'Bereiche') }
        'Leases ohne DNS-Eintrag' = @{ Daten = $daten.OhneDns; Spalten = @('IP', 'Name', 'A', 'PTR', 'Ursache') }
        'Doktor-Ergebnis'        = @{ Daten = $daten.Doktor; Spalten = @('Id', 'Kategorie', 'Titel', 'Status', 'Detail') }
        'Aenderungsverlauf'      = @{ Daten = $daten.Verlauf; Spalten = @('Zeit', 'Aenderung', 'Benutzer', 'Status') }
    }
    $s = $daten.Zustand.System
    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>NetSetup-Bericht ' + (ConvertTo-NetHtmlText $s.Hostname) + '</title><style>' + $script:NetBerichtCss + '</style></head><body>')
    [void]$html.Append('<h1>NetSetup-Bericht ' + (ConvertTo-NetHtmlText $s.Hostname) + '</h1>')
    [void]$html.Append('<p class="meta">' + (ConvertTo-NetHtmlText ('{0} - {1} - {2} - NetSetup {3}' -f $zeit.ToString('yyyy-MM-dd HH:mm'), $s.RolleText, $s.OsName, $script:NS.Version)) + '</p>')
    $summe = Get-NetCheckSummary -Ergebnisse $daten.Doktor
    [void]$html.Append('<p>Doktor: <span class="OK">' + $summe.OK + ' OK</span>, <span class="WARN">' + $summe.WARN + ' Warnungen</span>, <span class="FEHLER">' + $summe.FEHLER + ' Fehler</span></p>')
    $nr = 0
    foreach ($titel in $teile.Keys) {
        $nr++
        $t = $teile[$titel]
        [void]$html.Append('<h2>' + (ConvertTo-NetHtmlText $titel) + '</h2>')
        [void]$html.Append((ConvertTo-NetHtmlTable -Zeilen $t.Daten -Spalten $t.Spalten))
        $csv = '{0}_{1}_{2}.csv' -f $basis, $nr, ($titel -replace '[^A-Za-z0-9]+', '')
        @($t.Daten) | Select-Object -Property $t.Spalten | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
    [void]$html.Append('</body></html>')
    $datei = $basis + '.html'
    [System.IO.File]::WriteAllText($datei, $html.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-Log -Level OK -Message ('Bericht erstellt: ' + $datei)
    return $datei
}

function New-NetHealthReport {
    <#
    .SYNOPSIS
        Bericht fuer die geplante Gesundheitspruefung (-Task Health).
    #>
    param([object[]]$Ergebnisse)
    return (New-NetReport -DoktorErgebnis $Ergebnisse -Name 'Gesundheit')
}

function Invoke-NetReportTask {
    New-NetReport | Out-Null
}

function Show-NetReport {
    $datei = New-NetReport
    if ($datei -and $script:NS.Umgebung -and -not $script:NS.Umgebung.IstCore -and (Read-NetYesNo -Frage 'Bericht jetzt im Browser oeffnen?' -Vorschlag $true)) {
        Invoke-Item -Path $datei
    }
}

function Show-NetFreeAddress {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'Freie IP-Adressen'
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $f = Get-NetFreeAddressRange -ScopeId $s.ScopeId -Start $s.Start -Ende $s.Ende
        Write-Host ('  {0} ({1}): {2} frei' -f $s.ScopeId, $s.Name, $f.Frei) -ForegroundColor White
        foreach ($b in ($f.Bereiche | Select-Object -First 20)) { Write-Host ('    ' + $b) }
    }
}

function Show-NetReportMenu {
    $eintraege = @(
        @{ Text = 'Gesamtbericht erstellen (HTML + CSV)'; Aktion = 'Show-NetReport'; Hilfe = "Scope-Auslastung, freie IPs, Leases ohne DNS, Doktor-Ergebnis und Aenderungsverlauf in einer HTML-Datei (ohne Internet lesbar) und je Teil als CSV im Ordner Berichte." },
        @{ Text = 'Freie IP-Adressen anzeigen'; Aktion = 'Show-NetFreeAddress'; Hilfe = 'Bereich minus Ausschluesse, Reservierungen und Leases, zusammengefasst zu Bereichen.' },
        @{ Text = 'Leases ohne DNS-Eintrag'; Aktion = { if (Test-NetCommand -Name 'Show-NetLeaseDnsCheck') { Show-NetLeaseDnsCheck | Out-Null } }; Hilfe = 'Prueft alle aktiven Leases auf A- und PTR-Eintrag (mit Ursache).' },
        @{ Text = 'Aenderungsverlauf'; Aktion = 'Show-NetChangeHistory'; Hilfe = 'Alle Aenderungen, die NetSetup gemacht hat, mit Zeit und Status (aktiv/rueckgaengig).' },
        @{ Text = 'Ordner Berichte anzeigen'; Aktion = { Write-Log -Message ('Berichte: ' + (Get-NetPath -Name Berichte)); Get-ChildItem -Path (Get-NetPath -Name Berichte) | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 15 | ForEach-Object { Write-Host ('  ' + $_.Name) } }; Hilfe = 'Listet die neuesten Berichte.' }
    )
    Show-NetMenu -Titel 'Berichte' -Eintraege $eintraege
}
