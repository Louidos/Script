# Doktor: Pruefungen ausfuehren, Ergebnis anzeigen, reparieren (je nach Stufe), erneut pruefen.
# Jede Pruefung ist eine eigene Datei in src/checks/ und meldet sich mit Register-NetCheck an.
#
# Aufbau einer Pruefung (Hashtable):
#   Id            eindeutige Kennung, z. B. 'N01'
#   Kategorie     Rechte, Rollen, AD, Netzwerk, DHCP, DNS
#   Titel         kurzer Name
#   Voraussetzung { param($Z) ... }  $true = Pruefung ist sinnvoll (sonst [--])
#   Test          { param($Z) ... }  liefert New-NetCheckResult
#   Problem       was falsch ist (Klartext)
#   Erklaerung    warum das wichtig ist und was die Reparatur tut
#   Reparatur     { param($Z, $E) ... }  oder $null
#   (param() kann entfallen, wenn Zustand bzw. Ergebnis nicht gebraucht werden)
#   Stufe         Automatisch, Bestaetigen, Gefaehrlich
#   Interaktiv    $true, wenn die Reparatur selbst fragt (nutzt intern Invoke-NetChange)
#   Backup        Bereiche fuer das Backup vor der Reparatur (optional)

$script:NetCheckKategorien = @('Rechte', 'Rollen', 'AD', 'Netzwerk', 'DHCP', 'DNS')

function New-NetCheckResult {
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidateSet('OK', 'WARN', 'FEHLER', 'NA')][string]$Status,
        [Parameter(Position = 1)][string]$Detail = '',
        [Parameter(Position = 2)][object]$Daten = $null
    )
    return @{ Status = $Status; Detail = $Detail; Daten = $Daten }
}

function Register-NetCheck {
    <#
    .SYNOPSIS
        Meldet eine Pruefung beim Doktor an (eine Datei pro Pruefung in src/checks/).
    #>
    param([Parameter(Mandatory = $true, Position = 0)][hashtable]$Pruefung)
    foreach ($pflicht in @('Id', 'Kategorie', 'Titel', 'Test', 'Problem', 'Erklaerung')) {
        if (-not $Pruefung.ContainsKey($pflicht) -or -not $Pruefung[$pflicht]) { throw "Pruefung ohne Pflichtfeld '$pflicht'." }
    }
    if (-not $Pruefung.ContainsKey('Stufe')) { $Pruefung.Stufe = 'Bestaetigen' }
    if (@('Automatisch', 'Bestaetigen', 'Gefaehrlich') -notcontains $Pruefung.Stufe) { throw ("Pruefung {0}: unbekannte Stufe {1}." -f $Pruefung.Id, $Pruefung.Stufe) }
    if ($script:NetCheckKategorien -notcontains $Pruefung.Kategorie) { throw ("Pruefung {0}: unbekannte Kategorie {1}." -f $Pruefung.Id, $Pruefung.Kategorie) }
    if (-not $Pruefung.ContainsKey('Interaktiv')) { $Pruefung.Interaktiv = $false }
    if (-not $Pruefung.ContainsKey('Reparatur')) { $Pruefung.Reparatur = $null }
    if (-not $Pruefung.ContainsKey('Voraussetzung')) { $Pruefung.Voraussetzung = $null }
    if (-not $Pruefung.ContainsKey('Backup')) { $Pruefung.Backup = @() }
    foreach ($alt in @($script:NS.Checks | Where-Object { $_.Id -eq $Pruefung.Id })) { [void]$script:NS.Checks.Remove($alt) }
    [void]$script:NS.Checks.Add($Pruefung)
}

function Get-NetCheck {
    param([string[]]$Kategorie, [string[]]$Id)
    $liste = @($script:NS.Checks)
    if ($Kategorie) { $liste = @($liste | Where-Object { $Kategorie -contains $_.Kategorie }) }
    if ($Id) { $liste = @($liste | Where-Object { $Id -contains $_.Id }) }
    return @($liste | Sort-Object -Property @{ Expression = { [array]::IndexOf($script:NetCheckKategorien, $_.Kategorie) } }, @{ Expression = { $_.Id } })
}

function Invoke-NetCheck {
    <#
    .SYNOPSIS
        Fuehrt eine Pruefung aus. Fehler in der Pruefung selbst fuehren zu [WARN], nie zum Absturz.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Pruefung, [Parameter(Mandatory = $true)][hashtable]$Zustand)
    $ergebnis = [pscustomobject]@{
        Id = $Pruefung.Id; Kategorie = $Pruefung.Kategorie; Titel = $Pruefung.Titel; Status = 'NA'; Detail = ''
        Problem = $Pruefung.Problem; Erklaerung = $Pruefung.Erklaerung; Stufe = $Pruefung.Stufe
        KannReparieren = [bool]$Pruefung.Reparatur; Daten = $null
    }
    try {
        if ($Pruefung.Voraussetzung -and -not (& $Pruefung.Voraussetzung $Zustand)) {
            $ergebnis.Detail = 'trifft hier nicht zu'
            return $ergebnis
        }
        $r = & $Pruefung.Test $Zustand
        if ($r -is [bool]) { $r = @{ Status = $(if ($r) { 'OK' } else { 'FEHLER' }); Detail = '' } }
        if ($r -isnot [hashtable] -or -not $r.Status) { throw 'Die Pruefung hat kein gueltiges Ergebnis geliefert.' }
        $ergebnis.Status = $r.Status
        $ergebnis.Detail = [string]$r.Detail
        $ergebnis.Daten = $r.Daten
    }
    catch {
        $ergebnis.Status = 'WARN'
        $ergebnis.Detail = 'Pruefung nicht moeglich: ' + $_.Exception.Message
        $ergebnis.KannReparieren = $false
        Write-Log -Level Debug -Message ('Pruefung {0}: {1}' -f $Pruefung.Id, $_.Exception.ToString())
    }
    return $ergebnis
}

function Show-NetCheckResult {
    param([object[]]$Ergebnisse)
    $kategorie = ''
    foreach ($e in $Ergebnisse) {
        if ($e.Kategorie -ne $kategorie) {
            $kategorie = $e.Kategorie
            Write-Host ''
            Write-Host ('  ' + $kategorie) -ForegroundColor White
        }
        $text = $e.Detail
        if ($e.Status -ne 'OK' -and $e.Status -ne 'NA' -and $e.Problem) { $text = $e.Problem + ' ' + $e.Detail }
        Write-NetStatus -Status $e.Status -Bereich ('{0} {1}' -f $e.Id, $e.Titel) -Text $text.Trim()
    }
}

function Get-NetCheckSummary {
    param([object[]]$Ergebnisse)
    $ok = @($Ergebnisse | Where-Object { $_.Status -eq 'OK' }).Count
    $warn = @($Ergebnisse | Where-Object { $_.Status -eq 'WARN' }).Count
    $fehler = @($Ergebnisse | Where-Object { $_.Status -eq 'FEHLER' }).Count
    $na = @($Ergebnisse | Where-Object { $_.Status -eq 'NA' }).Count
    return [pscustomobject]@{ OK = $ok; WARN = $warn; FEHLER = $fehler; NA = $na; Text = ('{0} OK, {1} Warnung(en), {2} Fehler, {3} nicht zutreffend' -f $ok, $warn, $fehler, $na) }
}

function Invoke-NetCheckRepair {
    <#
    .SYNOPSIS
        Repariert ein Ergebnis gemaess Stufe und Probelauf. Liefert $true, wenn repariert wurde.
    #>
    param([Parameter(Mandatory = $true)][object]$Ergebnis, [Parameter(Mandatory = $true)][hashtable]$Zustand, [switch]$Automatisch)
    $chkPruefung = @(Get-NetCheck -Id $Ergebnis.Id) | Select-Object -First 1
    if (-not $chkPruefung -or -not $chkPruefung.Reparatur) { return $false }
    $chkReparatur = $chkPruefung.Reparatur
    $chkZustand = $Zustand
    $chkErgebnis = $Ergebnis
    if ($chkPruefung.Interaktiv) {
        if ($Automatisch) { return $false }
        Write-Host ''
        Write-Host ('--- {0} {1} ---' -f $chkPruefung.Id, $chkPruefung.Titel) -ForegroundColor Yellow
        Write-NetText -Text ($chkPruefung.Problem + ' ' + $Ergebnis.Detail) -Farbe Yellow
        Write-NetText -Text $chkPruefung.Erklaerung
        if (-not (Read-NetYesNo -Frage 'Reparatur starten?' -Vorschlag $true)) { return $false }
        try { & $chkReparatur $chkZustand $chkErgebnis | Out-Null; return $true }
        catch { Write-NetError -Fehler $_ -Titel ('Reparatur ' + $chkPruefung.Id) | Out-Null; return $false }
    }
    $stufe = $chkPruefung.Stufe
    if ($Automatisch -and $stufe -ne 'Automatisch') { return $false }
    # Ohne automatische Reparatur wird auch Harmloses einzeln bestaetigt.
    if (-not $Automatisch -and $stufe -eq 'Automatisch') { $stufe = 'Bestaetigen' }
    $backup = @($chkPruefung.Backup)
    if ($stufe -eq 'Gefaehrlich' -and $backup.Count -eq 0) { $backup = @('Config', 'Dhcp', 'Dns') }
    $r = Invoke-NetChange -Titel ('Reparatur {0}: {1}' -f $chkPruefung.Id, $chkPruefung.Titel) -Stufe $stufe -Vorher ($chkPruefung.Problem + ' ' + $Ergebnis.Detail).Trim() -Nachher 'behoben' -Hinweis $chkPruefung.Erklaerung -BackupBereich $backup -Aktion {
        & $chkReparatur $chkZustand $chkErgebnis
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Invoke-NetDoctor {
    <#
    .SYNOPSIS
        Alle passenden Pruefungen ausfuehren, anzeigen, harmlose Fehler automatisch reparieren
        (abschaltbar), weitere einzeln anbieten, danach erneut pruefen.
    #>
    param([string[]]$Kategorie, [switch]$NurPruefen, [switch]$Still)
    Write-NetTitle -Titel 'Doktor: pruefen und reparieren'
    Write-Log -Message 'Bestandsaufnahme ...'
    $zustand = Get-NetSetupState
    $pruefungen = @(Get-NetCheck -Kategorie $Kategorie)
    Write-Log -Message ('{0} Pruefung(en) laufen ...' -f $pruefungen.Count)
    $ergebnisse = @($pruefungen | ForEach-Object { Invoke-NetCheck -Pruefung $_ -Zustand $zustand })
    if (-not $Still) { Show-NetCheckResult -Ergebnisse $ergebnisse }
    $summe = Get-NetCheckSummary -Ergebnisse $ergebnisse
    Write-Host ''
    Write-Log -Message ('Ergebnis: ' + $summe.Text)
    $script:NS.LetzterDoktor = $ergebnisse
    if ($NurPruefen) { return $ergebnisse }

    $offen = @($ergebnisse | Where-Object { ($_.Status -eq 'FEHLER' -or $_.Status -eq 'WARN') -and $_.KannReparieren })
    if ($offen.Count -eq 0) {
        if ($summe.FEHLER + $summe.WARN -gt 0) { Write-Log -Message 'Fuer die gemeldeten Punkte gibt es keine automatische Reparatur. Die Erklaerung steht oben bzw. im Pruefkatalog.' }
        return $ergebnisse
    }
    $repariert = @()
    if ([bool](Get-NetConfigValue -Pfad 'Allgemein.AutoReparatur' -Standard $true)) {
        foreach ($e in @($offen | Where-Object { $_.Stufe -eq 'Automatisch' })) {
            if (Invoke-NetCheckRepair -Ergebnis $e -Zustand $zustand -Automatisch) { $repariert += $e.Id }
        }
    }
    else { Write-Log -Message 'Automatische Reparatur ist in den Einstellungen ausgeschaltet.' }
    $rest = @($offen | Where-Object { $repariert -notcontains $_.Id })
    if ($rest.Count -gt 0 -and $script:NS.Interaktiv) {
        Write-Host ''
        Write-Log -Message ('{0} Punkt(e) koennen repariert werden. Jeder wird einzeln angeboten.' -f $rest.Count)
        foreach ($e in $rest) {
            if (Invoke-NetCheckRepair -Ergebnis $e -Zustand $zustand) { $repariert += $e.Id }
        }
    }
    if ($repariert.Count -gt 0 -and -not (Test-NetDryRun)) {
        Write-Log -Message 'Erneute Pruefung der reparierten Punkte ...'
        $neuZustand = Get-NetSetupState
        $nachher = @(Get-NetCheck -Id $repariert | ForEach-Object { Invoke-NetCheck -Pruefung $_ -Zustand $neuZustand })
        Show-NetCheckResult -Ergebnisse $nachher
        foreach ($n in $nachher) {
            for ($i = 0; $i -lt $ergebnisse.Count; $i++) { if ($ergebnisse[$i].Id -eq $n.Id) { $ergebnisse[$i] = $n } }
        }
        Write-Log -Message ('Ergebnis nach der Reparatur: ' + (Get-NetCheckSummary -Ergebnisse $ergebnisse).Text)
    }
    $script:NS.LetzterDoktor = $ergebnisse
    return $ergebnisse
}

function Show-NetCheckCatalog {
    Write-NetTitle -Titel 'Pruefkatalog des Doktors'
    foreach ($p in (Get-NetCheck)) {
        Write-Host ('  {0} [{1}] {2}' -f $p.Id, $p.Kategorie, $p.Titel) -ForegroundColor White
        Write-NetText -Text ('    Problem   : ' + $p.Problem)
        Write-NetText -Text ('    Erklaerung: ' + $p.Erklaerung)
        $rep = 'keine automatische Reparatur'
        if ($p.Reparatur) { $rep = 'Reparatur moeglich, Stufe ' + $p.Stufe }
        Write-NetText -Text ('    Reparatur : ' + $rep) -Farbe DarkGray
    }
}

function Show-NetDcdiag {
    <#
    .SYNOPSIS
        Fuehrt dcdiag aus und zeigt die Ausgabe unveraendert an (wird nicht ausgewertet).
    #>
    if (-not (Test-NetCommand -Name 'dcdiag.exe')) { Write-Log -Level Warn -Message 'dcdiag ist nicht vorhanden (nur auf DCs bzw. mit RSAT-ADDS).'; return }
    Write-Log -Message 'dcdiag laeuft (das kann eine Minute dauern) ...'
    $ausgabe = & dcdiag.exe /q 2>&1 | Out-String
    if (-not $ausgabe.Trim()) { Write-Log -Level OK -Message 'dcdiag /q hat keine Fehler gemeldet.' }
    else { Write-Host $ausgabe }
    if (Read-NetYesNo -Frage 'Ausfuehrliche Ausgabe (dcdiag /v) anzeigen?' -Vorschlag $false) { & dcdiag.exe /v 2>&1 | Out-String | Write-Host }
}

function Invoke-NetDoctorCategory {
    $i = Read-NetChoice -Frage 'Welche Kategorie?' -Optionen $script:NetCheckKategorien -Vorschlag 1
    if ($i -lt 0) { return }
    Invoke-NetDoctor -Kategorie $script:NetCheckKategorien[$i] | Out-Null
}

function Invoke-NetHealthTask {
    <#
    .SYNOPSIS
        Aufgabe ohne Menue (-Task Health): alles pruefen, nichts aendern, Bericht ablegen.
    #>
    $ergebnisse = @(Invoke-NetDoctor -NurPruefen -Still)
    if (Test-NetCommand -Name 'New-NetHealthReport') {
        New-NetHealthReport -Ergebnisse $ergebnisse | Out-Null
    }
    else {
        $datei = Join-Path -Path (Get-NetPath -Name Berichte) -ChildPath ('Doktor_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $ergebnisse | Select-Object -Property Id, Kategorie, Titel, Status, Detail, Problem | Export-Csv -Path $datei -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Log -Level OK -Message ('Ergebnis gespeichert: ' + $datei)
    }
    $s = Get-NetCheckSummary -Ergebnisse $ergebnisse
    if ($s.FEHLER -gt 0) { Write-Log -Level Fehler -Message ('Gesundheitspruefung: ' + $s.Text) }
    elseif ($s.WARN -gt 0) { Write-Log -Level Warn -Message ('Gesundheitspruefung: ' + $s.Text) }
    else { Write-Log -Level OK -Message ('Gesundheitspruefung: ' + $s.Text) }
}

function Show-NetDoctorMenu {
    $eintraege = @(
        @{ Text = 'Alles pruefen und reparieren'; Aktion = { Invoke-NetDoctor | Out-Null }; Hilfe = "Fuehrt alle passenden Pruefungen aus und zeigt [OK]/[WARN]/[FEHLER].`nHarmloses (Stufe Automatisch, z. B. gestoppten Dienst starten) wird sofort repariert - abschaltbar in den Einstellungen.`nAlles andere wird einzeln angeboten; danach wird erneut geprueft. Der Probelauf gilt auch hier." },
        @{ Text = 'Nur pruefen (nichts aendern)'; Aktion = { Invoke-NetDoctor -NurPruefen | Out-Null }; Hilfe = 'Zeigt den Zustand, ohne etwas zu reparieren.' },
        @{ Text = 'Eine Kategorie pruefen'; Aktion = 'Invoke-NetDoctorCategory'; Hilfe = 'Rechte, Rollen, AD, Netzwerk, DHCP oder DNS einzeln pruefen.' },
        @{ Text = 'Pruefkatalog anzeigen'; Aktion = 'Show-NetCheckCatalog'; Hilfe = 'Alle Pruefungen mit Problem, Erklaerung und Reparaturstufe.' },
        @{ Text = 'dcdiag anzeigen (unveraendert)'; Aktion = 'Show-NetDcdiag'; Hilfe = 'Startet das Windows-Werkzeug dcdiag und zeigt dessen Ausgabe 1:1 (nur auf DCs).' },
        @{ Text = 'Fremde DHCP-Server im Netz suchen'; Aktion = 'Show-NetForeignDhcpServer'; Hilfe = 'Schickt eine DHCP-Anfrage (DHCPDISCOVER) ins Netz und zeigt alle antwortenden Server. Fremde Server (z. B. ein Router mit eingeschaltetem DHCP) verteilen falsche Adressen.' }
    )
    Show-NetMenu -Titel 'Doktor' -Eintraege $eintraege
}
