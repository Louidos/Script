# Fehlerbehandlung: bekannte Fehler in deutsche Klartexte mit naechstem Schritt uebersetzen.
# Ausgewertet werden nur Typen, Fehlernummern und Kategorien, nie uebersetzte Meldungstexte.

function Get-NetFeatureForCommand {
    <#
    .SYNOPSIS
        Ordnet einem fehlenden Befehl die Windows-Funktion zu, die ihn mitbringt.
    #>
    param([string]$Befehl)
    if (-not $Befehl) { return $null }
    if ($Befehl -match '-ADDS') { return 'AD-Domain-Services' }
    if ($Befehl -match '-Dhcp') { return 'RSAT-DHCP' }
    if ($Befehl -match '-DnsServer') { return 'RSAT-DNS-Server' }
    if ($Befehl -match '-AD') { return 'RSAT-AD-PowerShell' }
    if ($Befehl -match '-WindowsFeature') { return 'ServerManager (nur auf Windows Server vorhanden)' }
    return $null
}

function Get-NetErrorInfo {
    <#
    .SYNOPSIS
        Uebersetzt einen Fehler in Ursache und naechsten Schritt (Deutsch).
    .OUTPUTS
        PSCustomObject mit Ursache, NaechsterSchritt, Technisch, Code.
    #>
    param([Parameter(Mandatory = $true)][object]$Fehler)

    $record = $null
    $ex = $null
    if ($Fehler -is [System.Management.Automation.ErrorRecord]) { $record = $Fehler; $ex = $Fehler.Exception }
    elseif ($Fehler -is [System.Exception]) { $ex = $Fehler }
    else { $ex = New-Object System.Exception([string]$Fehler) }

    # Innerste Ursache bei verschachtelten Ausnahmen suchen
    $innen = $ex
    while (($innen -is [System.Management.Automation.RuntimeException]) -and $innen.InnerException) { $innen = $innen.InnerException }
    if (($null -eq $record) -and ($ex -is [System.Management.Automation.IContainsErrorRecord])) { $record = $ex.ErrorRecord }

    $fqid = ''
    $kategorie = ''
    if ($record) {
        $fqid = [string]$record.FullyQualifiedErrorId
        $kategorie = [string]$record.CategoryInfo.Category
    }
    $hresult = 0
    try { $hresult = $innen.HResult } catch { $hresult = 0 }
    $win32 = 0
    if ($fqid -match 'WIN32 (\d+)') { $win32 = [int]$Matches[1] }
    elseif ($innen.PSObject.Properties['NativeErrorCode']) {
        try { $win32 = [int]$innen.NativeErrorCode } catch { $win32 = 0 }
    }
    if (($win32 -eq 0) -and $innen.PSObject.Properties['ErrorData'] -and $innen.ErrorData) {
        try { $win32 = [int]$innen.ErrorData.CimInstanceProperties['error_Code'].Value } catch { $win32 = 0 }
    }

    $ursache = 'Unerwarteter Fehler.'
    $schritt = 'Details stehen im Log (' + [string]$script:NS.LogDatei + '). Danach den Doktor im Hauptmenue ausfuehren.'
    $code = 'Unbekannt'

    if (($innen -is [System.Management.Automation.CommandNotFoundException]) -or ($fqid -like 'CommandNotFoundException*')) {
        $befehl = ''
        if ($innen.PSObject.Properties['CommandName']) { $befehl = [string]$innen.CommandName }
        if ((-not $befehl) -and $record -and $record.TargetObject) { $befehl = [string]$record.TargetObject }
        $feature = Get-NetFeatureForCommand -Befehl $befehl
        $ursache = "Der Befehl '$befehl' fehlt. Die zugehoerige Rolle oder die Verwaltungstools sind nicht installiert."
        if ($feature) { $schritt = "Die Funktion '$feature' installieren (im Menue der Rolle oder per Doktor) und NetSetup neu starten." }
        else { $schritt = 'Die passende Rolle mit Verwaltungstools installieren (Doktor ausfuehren).' }
        $code = 'BefehlFehlt'
    }
    elseif (($innen -is [System.UnauthorizedAccessException]) -or ($kategorie -eq 'PermissionDenied') -or ($win32 -eq 5) -or ($hresult -eq -2147024891)) {
        $ursache = 'Zugriff verweigert. Das angemeldete Konto hat fuer diese Aktion nicht genug Rechte.'
        $schritt = 'PowerShell als Administrator starten. Fuer AD-Aenderungen mit einem Domaenen-Admin anmelden, fuer die DHCP-Autorisierung mit einem Organisations-Admin.'
        $code = 'Zugriff'
    }
    elseif (($fqid -like 'NoServiceFoundForGivenName*') -or ($fqid -like '*ServiceNotFound*')) {
        $ursache = 'Der Dienst ist auf diesem Server nicht vorhanden. Die Rolle ist vermutlich nicht installiert.'
        $schritt = 'Die Rolle im passenden Menue installieren oder den Doktor ausfuehren.'
        $code = 'DienstFehlt'
    }
    elseif (($win32 -eq 1722) -or ($win32 -eq 1753) -or ($hresult -eq -2147023174) -or ($kategorie -eq 'ConnectionError')) {
        $ursache = 'Der Server oder Dienst ist nicht erreichbar (RPC-Fehler).'
        $schritt = 'Pruefen, ob der Dienst laeuft (Doktor), ob die Firewall die Verbindung erlaubt und ob der Name richtig aufgeloest wird.'
        $code = 'NichtErreichbar'
    }
    elseif (($win32 -eq 9601) -or ($win32 -eq 9714)) {
        $ursache = 'Die DNS-Zone oder der DNS-Name existiert nicht.'
        $schritt = 'Im DNS-Menue die Zonen anzeigen und den Namen pruefen, bei Bedarf die Zone anlegen.'
        $code = 'NichtGefunden'
    }
    elseif (($win32 -eq 9609) -or ($win32 -eq 9711) -or ($kategorie -eq 'ResourceExists')) {
        $ursache = 'Der Eintrag existiert bereits.'
        $schritt = 'Nichts zu tun, oder den vorhandenen Eintrag zuerst anzeigen und gezielt aendern.'
        $code = 'Existiert'
    }
    elseif (($kategorie -eq 'ObjectNotFound') -or ($innen -is [System.Management.Automation.ItemNotFoundException])) {
        $ursache = 'Das gesuchte Objekt wurde nicht gefunden.'
        $schritt = 'Namen bzw. Adresse pruefen und die Liste im Menue anzeigen lassen.'
        $code = 'NichtGefunden'
    }
    elseif (($kategorie -eq 'InvalidArgument') -or ($kategorie -eq 'InvalidData') -or ($innen -is [System.ArgumentException]) -or ($innen -is [System.FormatException])) {
        $ursache = 'Ein eingegebener Wert ist ungueltig.'
        $schritt = 'Eingabe pruefen (Format, Bereich, Schreibweise) und erneut versuchen.'
        $code = 'UngueltigerWert'
    }
    elseif (($innen -is [System.IO.IOException]) -or ($kategorie -eq 'WriteError') -or ($kategorie -eq 'ReadError')) {
        $ursache = 'Datei- oder Speicherfehler.'
        $schritt = 'Pruefen, ob der Datenordner existiert, genug Platz frei ist und keine andere Anwendung die Datei sperrt.'
        $code = 'Datei'
    }
    elseif ($innen -is [System.TimeoutException]) {
        $ursache = 'Zeitueberschreitung: die Gegenstelle hat nicht rechtzeitig geantwortet.'
        $schritt = 'Netzwerkverbindung und Firewall pruefen und spaeter erneut versuchen.'
        $code = 'Zeitueberschreitung'
    }

    $technisch = '{0}: {1} | FQID={2} | Kategorie={3} | Win32={4} | HResult=0x{5:X8}' -f $innen.GetType().FullName, $innen.Message, $fqid, $kategorie, $win32, $hresult
    if ($record -and $record.ScriptStackTrace) { $technisch += ' | ' + ($record.ScriptStackTrace -replace "`r?`n", ' <- ') }

    return [pscustomobject]@{
        Ursache          = $ursache
        NaechsterSchritt = $schritt
        Technisch        = $technisch
        Code             = $code
        Meldung          = $innen.Message
    }
}

function Write-NetError {
    <#
    .SYNOPSIS
        Zeigt einen Fehler verstaendlich an und schreibt die Details ins Log.
    #>
    param([Parameter(Mandatory = $true)][object]$Fehler, [string]$Titel = 'Aktion')
    $info = Get-NetErrorInfo -Fehler $Fehler
    Write-Log -Level Fehler -Message ('{0}: {1}' -f $Titel, $info.Ursache)
    if ($info.Code -eq 'Unbekannt' -and $info.Meldung) { Write-Log -Message ('Meldung von Windows: ' + $info.Meldung) }
    Write-Log -Message ('Naechster Schritt: ' + $info.NaechsterSchritt)
    Write-Log -Level Debug -Message $info.Technisch
    return $info
}

function Invoke-NetStep {
    <#
    .SYNOPSIS
        Fuehrt einen Schritt mit try/catch aus. Fehler werden uebersetzt, nie wird abgestuerzt.
    .OUTPUTS
        PSCustomObject mit Erfolg, Ergebnis, Fehler.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Titel,
        [Parameter(Mandatory = $true)][scriptblock]$Aktion,
        [switch]$Still
    )
    # CDXML-Cmdlets (DnsServer, DhcpServer, NetTCPIP) beachten $ErrorActionPreference des Aufrufers
    # nicht. Mit -ErrorAction Stop als Standard wird jeder Fehler zuverlaessig abgefangen.
    $ErrorActionPreference = 'Stop'
    $PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }
    try {
        $nsErgebnis = & $Aktion
        if (-not $Still) { Write-Log -Level OK -Message $Titel }
        else { Write-Log -Level Debug -Message ('OK: ' + $Titel) }
        return [pscustomobject]@{ Erfolg = $true; Ergebnis = $nsErgebnis; Fehler = $null }
    }
    catch {
        $nsInfo = Write-NetError -Fehler $_ -Titel $Titel
        return [pscustomobject]@{ Erfolg = $false; Ergebnis = $null; Fehler = $nsInfo }
    }
}

function Get-NetSafe {
    <#
    .SYNOPSIS
        Fuehrt eine nur lesende Abfrage aus und liefert bei Fehler den Rueckfallwert.
        Fuer die Bestandsaufnahme: fehlende Module oder Rollen fuehren nie zum Absturz.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Abfrage,
        [object]$Standard = $null,
        [string]$Beschreibung = 'Abfrage'
    )
    $ErrorActionPreference = 'Stop'
    $PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }
    try {
        return (& $Abfrage)
    }
    catch {
        Write-Log -Level Debug -Message ('{0} nicht moeglich: {1}' -f $Beschreibung, $_.Exception.Message)
        return $Standard
    }
}

function Test-NetCommand {
    <#
    .SYNOPSIS
        Prueft, ob ein Befehl (Cmdlet oder Funktion) vorhanden ist.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}
