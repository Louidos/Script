<#
    NetSetup 0.0.0 (Build 2026-10-22 21:14)
    AD, DNS und DHCP auf Windows Server einrichten, verwalten und reparieren.
#
    So starten (PowerShell oder PowerShell ISE als Administrator):
      a) Den ganzen Text in die PowerShell-Konsole einfuegen und Enter druecken.
      b) In PowerShell ISE in ein neues Script einfuegen und F5 druecken.
      c) Als NetSetup.ps1 speichern und starten:
         powershell.exe -ExecutionPolicy Bypass -File NetSetup.ps1
    Ohne Menue: -Task Health | Report | Backup | Resume
#
    Diese Datei wird mit scripts/Build-NetSetup.ps1 aus src/ erzeugt.
    Nicht von Hand bearbeiten.
#>
$NetSetupCode = {
$script:NetSetupVersion = '0.0.0'
$script:NetSetupBuildDatum = '2026-10-22 21:14'
# ----------------------------------------------------------------------
# src/core/Zustand.ps1
# ----------------------------------------------------------------------
# Gemeinsamer Zustand der laufenden Sitzung.
# Alle Funktionen lesen und schreiben ueber $script:NS, damit beim Einfuegen
# in die Konsole ausser dieser einen Variable nichts liegen bleibt.
#
if (-not $script:NetSetupVersion) { $script:NetSetupVersion = '0.0.0-dev' }
if (-not $script:NetSetupBuildDatum) { $script:NetSetupBuildDatum = '' }
#
$script:NS = @{
    Version         = $script:NetSetupVersion
    BuildDatum      = $script:NetSetupBuildDatum
    StandardPfad    = 'C:\NetSetup'
    Datenpfad       = 'C:\NetSetup'
    RegistryPfad    = 'HKLM:\SOFTWARE\NetSetup'
    Unterordner     = @('Config', 'Logs', 'Backups', 'Berichte', 'Rueckgaengig', 'Vorlagen')
    Probelauf       = $false
    Interaktiv      = $true
    Config          = $null
    LogDatei        = $null
    TranscriptAktiv = $false
    Umgebung        = $null
    Zustand         = $null
    Checks          = New-Object System.Collections.ArrayList
    ErsterStart     = $false
}
# ----------------------------------------------------------------------
# src/core/Pfade.ps1
# ----------------------------------------------------------------------
# Pfade unter dem Datenordner (Standard C:\NetSetup) und Anlegen der Ordner.
#
function Get-NetPath {
    <#
    .SYNOPSIS
        Liefert einen Pfad unterhalb des Datenordners.
    #>
    param(
        [ValidateSet('Root', 'Config', 'Logs', 'Backups', 'Berichte', 'Rueckgaengig', 'Vorlagen',
            'ConfigDatei', 'Script', 'Fortsetzung', 'Verlauf')]
        [string]$Name = 'Root'
    )
    $root = $script:NS.Datenpfad
    switch ($Name) {
        'Root' { return $root }
        'ConfigDatei' { return (Join-Path -Path (Join-Path -Path $root -ChildPath 'Config') -ChildPath 'netsetup.json') }
        'Fortsetzung' { return (Join-Path -Path (Join-Path -Path $root -ChildPath 'Config') -ChildPath 'fortsetzung.json') }
        'Verlauf' { return (Join-Path -Path (Join-Path -Path $root -ChildPath 'Rueckgaengig') -ChildPath 'verlauf.json') }
        'Script' { return (Join-Path -Path $root -ChildPath 'NetSetup.ps1') }
        default { return (Join-Path -Path $root -ChildPath $Name) }
    }
}
#
function Test-NetIsWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}
#
function Get-NetDataRootPointer {
    <#
    .SYNOPSIS
        Liest den gespeicherten Datenordner aus der Registry (falls beim ersten Start geaendert).
    #>
    try {
        $wert = Get-ItemProperty -Path $script:NS.RegistryPfad -Name 'Datenpfad' -ErrorAction Stop
        if ($wert.Datenpfad) { return [string]$wert.Datenpfad }
    }
    catch {
        Write-Verbose 'Kein gespeicherter Datenordner, Standard wird verwendet.'
    }
    return $null
}
#
function Set-NetDataRootPointer {
    param([Parameter(Mandatory = $true)][string]$Pfad)
    try {
        if (-not (Test-Path -Path $script:NS.RegistryPfad)) {
            New-Item -Path $script:NS.RegistryPfad -Force | Out-Null
        }
        Set-ItemProperty -Path $script:NS.RegistryPfad -Name 'Datenpfad' -Value $Pfad -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log -Level Warn -Message "Datenordner konnte nicht in der Registry gemerkt werden: $($_.Exception.Message)"
        return $false
    }
}
#
function Protect-NetFolder {
    <#
    .SYNOPSIS
        Erlaubt den Datenordner nur Administratoren und SYSTEM.
    .DESCRIPTION
        Im Datenordner liegen das Script (RunOnce, geplante Aufgabe), Backups und die
        Rueckgaengig-Liste. Normale Benutzer duerfen dort nichts aendern koennen.
        Gruppen werden ueber SIDs angesprochen, damit es auf jedem Sprachpaket klappt.
    #>
    param([Parameter(Mandatory = $true)][string]$Pfad)
    if (-not (Test-NetIsWindows)) { return }
    try {
        $acl = Get-Acl -Path $Pfad -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($regel in @($acl.Access)) { [void]$acl.RemoveAccessRule($regel) }
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $regel = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($regel)
        }
        Set-Acl -Path $Pfad -AclObject $acl -ErrorAction Stop
    }
    catch {
        Write-Log -Level Warn -Message "Rechte auf $Pfad konnten nicht eingeschraenkt werden. Bitte pruefen, dass nur Administratoren Zugriff haben."
        Write-Log -Level Debug -Message $_.Exception.ToString()
    }
}
#
function Initialize-NetFolder {
    <#
    .SYNOPSIS
        Legt den Datenordner und alle Unterordner an (idempotent).
    #>
    $root = Get-NetPath -Name Root
    $neu = -not (Test-Path -Path $root)
    if ($neu) { New-Item -Path $root -ItemType Directory -Force | Out-Null }
    foreach ($ordner in $script:NS.Unterordner) {
        $pfad = Join-Path -Path $root -ChildPath $ordner
        if (-not (Test-Path -Path $pfad)) { New-Item -Path $pfad -ItemType Directory -Force | Out-Null }
    }
    if ($neu) { Protect-NetFolder -Pfad $root }
    return $neu
}
# ----------------------------------------------------------------------
# src/core/Log.ps1
# ----------------------------------------------------------------------
# Logging: jede Meldung in die Logdatei und farbig in die Konsole.
# Passwoerter werden nie uebergeben und deshalb nie geloggt.
#
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
#
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
#
function Write-NetTitle {
    param([Parameter(Mandatory = $true)][string]$Titel)
    $linie = '=' * ([Math]::Max(40, $Titel.Length + 8))
    Write-Host ''
    Write-Host $linie -ForegroundColor Cyan
    Write-Host ('    ' + $Titel) -ForegroundColor Cyan
    Write-Host $linie -ForegroundColor Cyan
}
#
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
#
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
#
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
#
function Stop-NetTranscript {
    if (-not $script:NS.TranscriptAktiv) { return }
    try { Stop-Transcript -ErrorAction Stop | Out-Null }
    catch { Write-Log -Level Debug -Message 'Transcript war bereits beendet.' }
    $script:NS.TranscriptAktiv = $false
}
# ----------------------------------------------------------------------
# src/core/Config.ps1
# ----------------------------------------------------------------------
# Konfiguration als JSON mit Schema-Version unter <Datenordner>\Config\netsetup.json.
# Passwoerter stehen nie in der Konfiguration.
#
$script:NetConfigSchemaVersion = 1
#
function Get-NetDefaultConfig {
    <#
    .SYNOPSIS
        Liefert die Standardkonfiguration mit allen Vorschlagswerten.
    #>
    return @{
        SchemaVersion = $script:NetConfigSchemaVersion
        Allgemein     = @{
            Probelauf          = $false
            AutoReparatur      = $true
            BackupAufbewahrung = 20
            GridView           = $true
            VerknuepfungGefragt = $false
        }
        Vorschlaege   = @{
            Weiterleitungen    = @('9.9.9.9', '1.1.1.1')
            ScavengingAktiv    = $true
            NoRefreshTage      = 7
            RefreshTage        = 7
            LeaseTage          = 8
            DnsDienstkonto     = 'svc-dhcpdns'
            AuslastungWarnung  = 80
            AuslastungFehler   = 90
        }
        AD            = @{
            Domaene  = ''
            NetBios  = ''
        }
        Dns           = @{
            Zonen           = @()
            Weiterleitungen = @()
            Scavenging      = @{}
        }
        Dhcp          = @{
            Scopes         = @()
            ServerOptionen = @{}
            DnsEinstellung = @{}
        }
        Erweitert     = @{
            Dnssec       = $false
            SplitBrain   = $false
            Richtlinien  = $false
            Sperrliste   = $false
            Dhcpv6       = $false
        }
    }
}
#
function ConvertTo-NetHashtable {
    <#
    .SYNOPSIS
        Wandelt das Ergebnis von ConvertFrom-Json (PSCustomObject) rekursiv in Hashtables um.
        Windows PowerShell 5.1 kennt kein ConvertFrom-Json -AsHashtable.
    #>
    param([Parameter(ValueFromPipeline = $true)][AllowNull()][object]$Objekt)
    process {
        if ($null -eq $Objekt) { return $null }
        if ($Objekt -is [System.Collections.IDictionary]) {
            $ht = @{}
            foreach ($k in @($Objekt.Keys)) { $ht[[string]$k] = ConvertTo-NetHashtable -Objekt $Objekt[$k] }
            return $ht
        }
        if ($Objekt -is [System.Management.Automation.PSCustomObject]) {
            $ht = @{}
            foreach ($p in $Objekt.PSObject.Properties) { $ht[$p.Name] = ConvertTo-NetHashtable -Objekt $p.Value }
            return $ht
        }
        if (($Objekt -is [System.Collections.IEnumerable]) -and ($Objekt -isnot [string])) {
            $liste = @()
            foreach ($e in $Objekt) { $liste += , (ConvertTo-NetHashtable -Objekt $e) }
            return , $liste
        }
        return $Objekt
    }
}
#
function Merge-NetHashtable {
    <#
    .SYNOPSIS
        Ergaenzt fehlende Schluessel in $Ziel aus $Vorlage (rekursiv). Vorhandene Werte bleiben.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Ziel, [Parameter(Mandatory = $true)][hashtable]$Vorlage)
    foreach ($k in @($Vorlage.Keys)) {
        if (-not $Ziel.ContainsKey($k)) {
            $Ziel[$k] = $Vorlage[$k]
        }
        elseif (($Ziel[$k] -is [hashtable]) -and ($Vorlage[$k] -is [hashtable])) {
            Merge-NetHashtable -Ziel $Ziel[$k] -Vorlage $Vorlage[$k] | Out-Null
        }
    }
    return $Ziel
}
#
function Test-NetConfig {
    <#
    .SYNOPSIS
        Prueft eine Konfiguration und liefert eine Liste von Problemen (leer = in Ordnung).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $probleme = @()
    if (-not $Config.ContainsKey('SchemaVersion')) {
        $probleme += 'SchemaVersion fehlt.'
    }
    elseif ([int]$Config.SchemaVersion -gt $script:NetConfigSchemaVersion) {
        $probleme += "Die Konfiguration stammt von einer neueren NetSetup-Version (Schema $($Config.SchemaVersion)). Bitte die neueste NetSetup-Version verwenden."
    }
    foreach ($bereich in @('Allgemein', 'Vorschlaege', 'AD', 'Dns', 'Dhcp', 'Erweitert')) {
        if (($Config.ContainsKey($bereich)) -and ($Config[$bereich] -isnot [hashtable])) {
            $probleme += "Bereich '$bereich' hat ein ungueltiges Format."
        }
    }
    if ($Config.Allgemein -is [hashtable]) {
        $anzahl = 0
        if (-not [int]::TryParse([string]$Config.Allgemein.BackupAufbewahrung, [ref]$anzahl) -or $anzahl -lt 1 -or $anzahl -gt 500) {
            $probleme += 'Allgemein.BackupAufbewahrung muss eine Zahl von 1 bis 500 sein.'
        }
    }
    if ($Config.Vorschlaege -is [hashtable]) {
        foreach ($ip in @($Config.Vorschlaege.Weiterleitungen)) {
            if ($ip -and -not (Test-NetIPv4Address -Text ([string]$ip))) {
                $probleme += "Vorschlaege.Weiterleitungen enthaelt eine ungueltige IP-Adresse: $ip"
            }
        }
        $lease = 0
        if (-not [int]::TryParse([string]$Config.Vorschlaege.LeaseTage, [ref]$lease) -or $lease -lt 1 -or $lease -gt 999) {
            $probleme += 'Vorschlaege.LeaseTage muss eine Zahl von 1 bis 999 sein.'
        }
    }
    return $probleme
}
#
function Import-NetConfig {
    <#
    .SYNOPSIS
        Laedt die Konfiguration, ergaenzt fehlende Werte und prueft sie.
        Fehlt die Datei, wird die Standardkonfiguration verwendet.
    #>
    $datei = Get-NetPath -Name ConfigDatei
    $standard = Get-NetDefaultConfig
    if (-not (Test-Path -Path $datei)) {
        $script:NS.Config = $standard
        return $script:NS.Config
    }
    try {
        $text = Get-Content -Path $datei -Raw -ErrorAction Stop
        $config = ConvertTo-NetHashtable -Objekt ($text | ConvertFrom-Json -ErrorAction Stop)
        if ($config -isnot [hashtable]) { throw 'Kein JSON-Objekt' }
    }
    catch {
        $kaputt = $datei + '.defekt_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item -Path $datei -Destination $kaputt -Force -ErrorAction SilentlyContinue
        Write-Log -Level Warn -Message "Die Konfiguration ist beschaedigt und wurde nach $kaputt gesichert. Es gelten die Standardwerte."
        Write-Log -Level Debug -Message $_.Exception.ToString()
        $script:NS.Config = $standard
        return $script:NS.Config
    }
    Merge-NetHashtable -Ziel $config -Vorlage $standard | Out-Null
    foreach ($problem in (Test-NetConfig -Config $config)) {
        Write-Log -Level Warn -Message "Konfiguration: $problem"
    }
    $script:NS.Config = $config
    $script:NS.Probelauf = [bool]$config.Allgemein.Probelauf -or $script:NS.Probelauf
    return $script:NS.Config
}
#
function Save-NetConfig {
    <#
    .SYNOPSIS
        Speichert die aktuelle Konfiguration als JSON (ohne Passwoerter).
    #>
    param([hashtable]$Config = $script:NS.Config)
    if ($null -eq $Config) { $Config = Get-NetDefaultConfig }
    $Config.SchemaVersion = $script:NetConfigSchemaVersion
    $datei = Get-NetPath -Name ConfigDatei
    $ordner = Split-Path -Path $datei -Parent
    if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
    $json = $Config | ConvertTo-Json -Depth 12
    Set-Content -Path $datei -Value $json -Encoding UTF8 -ErrorAction Stop
    $script:NS.Config = $Config
    Write-Log -Level Debug -Message "Konfiguration gespeichert: $datei"
}
#
function Get-NetConfigValue {
    <#
    .SYNOPSIS
        Liest einen Wert ueber einen Pfad wie 'Vorschlaege.LeaseTage', mit Rueckfallwert.
    #>
    param([Parameter(Mandatory = $true)][string]$Pfad, [object]$Standard = $null)
    $aktuell = $script:NS.Config
    if ($null -eq $aktuell) { $aktuell = Get-NetDefaultConfig }
    foreach ($teil in $Pfad.Split('.')) {
        if (($aktuell -is [hashtable]) -and $aktuell.ContainsKey($teil)) { $aktuell = $aktuell[$teil] }
        else { return $Standard }
    }
    if ($null -eq $aktuell) { return $Standard }
    return $aktuell
}
# ----------------------------------------------------------------------
# src/core/Fehler.ps1
# ----------------------------------------------------------------------
# Fehlerbehandlung: bekannte Fehler in deutsche Klartexte mit naechstem Schritt uebersetzen.
# Ausgewertet werden nur Typen, Fehlernummern und Kategorien, nie uebersetzte Meldungstexte.
#
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
#
function Get-NetErrorInfo {
    <#
    .SYNOPSIS
        Uebersetzt einen Fehler in Ursache und naechsten Schritt (Deutsch).
    .OUTPUTS
        PSCustomObject mit Ursache, NaechsterSchritt, Technisch, Code.
    #>
    param([Parameter(Mandatory = $true)][object]$Fehler)
#
    $record = $null
    $ex = $null
    if ($Fehler -is [System.Management.Automation.ErrorRecord]) { $record = $Fehler; $ex = $Fehler.Exception }
    elseif ($Fehler -is [System.Exception]) { $ex = $Fehler }
    else { $ex = New-Object System.Exception([string]$Fehler) }
#
    # Innerste Ursache bei verschachtelten Ausnahmen suchen
    $innen = $ex
    while (($innen -is [System.Management.Automation.RuntimeException]) -and $innen.InnerException) { $innen = $innen.InnerException }
    if (($null -eq $record) -and ($ex -is [System.Management.Automation.IContainsErrorRecord])) { $record = $ex.ErrorRecord }
#
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
#
    $ursache = 'Unerwarteter Fehler.'
    $schritt = 'Details stehen im Log (' + [string]$script:NS.LogDatei + '). Danach den Doktor im Hauptmenue ausfuehren.'
    $code = 'Unbekannt'
#
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
#
    $technisch = '{0}: {1} | FQID={2} | Kategorie={3} | Win32={4} | HResult=0x{5:X8}' -f $innen.GetType().FullName, $innen.Message, $fqid, $kategorie, $win32, $hresult
    if ($record -and $record.ScriptStackTrace) { $technisch += ' | ' + ($record.ScriptStackTrace -replace "`r?`n", ' <- ') }
#
    return [pscustomobject]@{
        Ursache          = $ursache
        NaechsterSchritt = $schritt
        Technisch        = $technisch
        Code             = $code
        Meldung          = $innen.Message
    }
}
#
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
#
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
    $ErrorActionPreference = 'Stop'
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
#
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
    try {
        return (& $Abfrage)
    }
    catch {
        Write-Log -Level Debug -Message ('{0} nicht moeglich: {1}' -f $Beschreibung, $_.Exception.Message)
        return $Standard
    }
}
#
function Test-NetCommand {
    <#
    .SYNOPSIS
        Prueft, ob ein Befehl (Cmdlet oder Funktion) vorhanden ist.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}
# ----------------------------------------------------------------------
# src/core/IpHilfe.ps1
# ----------------------------------------------------------------------
# Hilfsfunktionen fuer IPv4-Adressen, Subnetze, Reverse-Zonen und Namen.
# Reine Rechenfunktionen ohne Zugriff auf den Server.
#
function Test-NetIPv4Address {
    <#
    .SYNOPSIS
        Prueft, ob ein Text eine gueltige IPv4-Adresse in Punktschreibweise ist.
    #>
    param([AllowEmptyString()][string]$Text)
    if ($Text -notmatch '^\s*(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\s*$') { return $false }
    foreach ($i in 1..4) {
        if ([int]$Matches[$i] -gt 255) { return $false }
        if (($Matches[$i].Length -gt 1) -and $Matches[$i].StartsWith('0')) { return $false }
    }
    return $true
}
#
function ConvertTo-NetIPv4UInt32 {
    param([Parameter(Mandatory = $true)][string]$IPAddress)
    $bytes = ([System.Net.IPAddress]::Parse($IPAddress.Trim())).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}
#
function ConvertFrom-NetIPv4UInt32 {
    param([Parameter(Mandatory = $true)][uint32]$Wert)
    $bytes = [BitConverter]::GetBytes($Wert)
    [Array]::Reverse($bytes)
    return ($bytes -join '.')
}
#
function ConvertTo-NetSubnetMask {
    <#
    .SYNOPSIS
        Praefixlaenge (z. B. 24) in Subnetzmaske (255.255.255.0) umrechnen.
    #>
    param([Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    if ($PrefixLength -eq 0) { return '0.0.0.0' }
    [uint32]$maske = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $PrefixLength))
    return (ConvertFrom-NetIPv4UInt32 -Wert $maske)
}
#
function ConvertTo-NetPrefixLength {
    <#
    .SYNOPSIS
        Subnetzmaske in Praefixlaenge umrechnen. Liefert -1 bei ungueltiger Maske.
    #>
    param([Parameter(Mandatory = $true)][string]$SubnetMask)
    if (-not (Test-NetIPv4Address -Text $SubnetMask)) { return -1 }
    $wert = ConvertTo-NetIPv4UInt32 -IPAddress $SubnetMask
    $bits = [Convert]::ToString([int64]$wert, 2).PadLeft(32, '0')
    if ($bits -notmatch '^1*0*$') { return -1 }
    return ($bits.TrimEnd('0')).Length
}
#
function Get-NetNetworkAddress {
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    $ip = ConvertTo-NetIPv4UInt32 -IPAddress $IPAddress
    $maske = ConvertTo-NetIPv4UInt32 -IPAddress (ConvertTo-NetSubnetMask -PrefixLength $PrefixLength)
    return (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($ip -band $maske)))
}
#
function Get-NetBroadcastAddress {
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    $netz = ConvertTo-NetIPv4UInt32 -IPAddress (Get-NetNetworkAddress -IPAddress $IPAddress -PrefixLength $PrefixLength)
    $host_anzahl = [uint32]([Math]::Pow(2, 32 - $PrefixLength) - 1)
    return (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($netz + $host_anzahl)))
}
#
function Test-NetIPInSubnet {
    <#
    .SYNOPSIS
        Prueft, ob eine Adresse im angegebenen Netz liegt.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][string]$NetworkAddress,
        [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength
    )
    if (-not (Test-NetIPv4Address -Text $IPAddress) -or -not (Test-NetIPv4Address -Text $NetworkAddress)) { return $false }
    return ((Get-NetNetworkAddress -IPAddress $IPAddress -PrefixLength $PrefixLength) -eq (Get-NetNetworkAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength))
}
#
function Test-NetIPRange {
    <#
    .SYNOPSIS
        Prueft einen Adressbereich fuer einen Scope. Liefert $null wenn gueltig, sonst den Grund.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Start,
        [Parameter(Mandatory = $true)][string]$Ende,
        [Parameter(Mandatory = $true)][string]$NetworkAddress,
        [Parameter(Mandatory = $true)][ValidateRange(1, 32)][int]$PrefixLength
    )
    if (-not (Test-NetIPv4Address -Text $Start)) { return "Startadresse '$Start' ist keine gueltige IPv4-Adresse." }
    if (-not (Test-NetIPv4Address -Text $Ende)) { return "Endadresse '$Ende' ist keine gueltige IPv4-Adresse." }
    if ($PrefixLength -gt 30) { return 'Das Netz ist zu klein fuer DHCP (mindestens /30).' }
    if (-not (Test-NetIPInSubnet -IPAddress $Start -NetworkAddress $NetworkAddress -PrefixLength $PrefixLength)) { return "Startadresse $Start liegt nicht im Netz $NetworkAddress/$PrefixLength." }
    if (-not (Test-NetIPInSubnet -IPAddress $Ende -NetworkAddress $NetworkAddress -PrefixLength $PrefixLength)) { return "Endadresse $Ende liegt nicht im Netz $NetworkAddress/$PrefixLength." }
    $s = ConvertTo-NetIPv4UInt32 -IPAddress $Start
    $e = ConvertTo-NetIPv4UInt32 -IPAddress $Ende
    if ($s -ge $e) { return 'Die Startadresse muss kleiner als die Endadresse sein.' }
    $netz = ConvertTo-NetIPv4UInt32 -IPAddress (Get-NetNetworkAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength)
    $bc = ConvertTo-NetIPv4UInt32 -IPAddress (Get-NetBroadcastAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength)
    if ($s -eq $netz) { return 'Die Startadresse darf nicht die Netzadresse sein.' }
    if ($e -eq $bc) { return 'Die Endadresse darf nicht die Broadcast-Adresse sein.' }
    return $null
}
#
function Test-NetIPInRange {
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][string]$Start, [Parameter(Mandatory = $true)][string]$Ende)
    if (-not ((Test-NetIPv4Address -Text $IPAddress) -and (Test-NetIPv4Address -Text $Start) -and (Test-NetIPv4Address -Text $Ende))) { return $false }
    $ip = ConvertTo-NetIPv4UInt32 -IPAddress $IPAddress
    return (($ip -ge (ConvertTo-NetIPv4UInt32 -IPAddress $Start)) -and ($ip -le (ConvertTo-NetIPv4UInt32 -IPAddress $Ende)))
}
#
function Get-NetRangeSize {
    param([Parameter(Mandatory = $true)][string]$Start, [Parameter(Mandatory = $true)][string]$Ende)
    return [int64](ConvertTo-NetIPv4UInt32 -IPAddress $Ende) - [int64](ConvertTo-NetIPv4UInt32 -IPAddress $Start) + 1
}
#
function Get-NetReverseZoneName {
    <#
    .SYNOPSIS
        Liefert die Namen der Reverse-Zonen (in-addr.arpa) fuer ein Netz.
    .DESCRIPTION
        /24 und kleiner: eine Zone mit drei Oktetten. /17 bis /23: je eine /24-Zone.
        /16 und /9 bis /15 entsprechend mit zwei bzw. einem Oktett.
    #>
    param([Parameter(Mandatory = $true)][string]$NetworkAddress, [Parameter(Mandatory = $true)][ValidateRange(8, 32)][int]$PrefixLength)
    $netz = Get-NetNetworkAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength
    $o = $netz.Split('.')
    if ($PrefixLength -ge 24) { return @("$($o[2]).$($o[1]).$($o[0]).in-addr.arpa") }
    if ($PrefixLength -eq 16) { return @("$($o[1]).$($o[0]).in-addr.arpa") }
    if ($PrefixLength -eq 8) { return @("$($o[0]).in-addr.arpa") }
    if ($PrefixLength -gt 16) {
        $anzahl = [int][Math]::Pow(2, 24 - $PrefixLength)
        $liste = @()
        for ($i = 0; $i -lt $anzahl; $i++) { $liste += "$([int]$o[2] + $i).$($o[1]).$($o[0]).in-addr.arpa" }
        return $liste
    }
    $anzahl = [int][Math]::Pow(2, 16 - $PrefixLength)
    $liste = @()
    for ($i = 0; $i -lt $anzahl; $i++) { $liste += "$([int]$o[1] + $i).$($o[0]).in-addr.arpa" }
    return $liste
}
#
function Get-NetPtrName {
    <#
    .SYNOPSIS
        Liefert den relativen PTR-Namen einer Adresse innerhalb einer Reverse-Zone.
        Liegt die Adresse nicht in der Zone, wird $null geliefert.
    #>
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][string]$ZoneName)
    $o = $IPAddress.Split('.')
    $umgekehrt = @($o[3], $o[2], $o[1], $o[0])
    $zone = $ZoneName.ToLower() -replace '\.in-addr\.arpa\.?$', ''
    $zonenTeile = @($zone.Split('.'))
    $anzahl = $zonenTeile.Count
    if (($anzahl -lt 1) -or ($anzahl -gt 3)) { return $null }
    $erwartet = ($umgekehrt[(4 - $anzahl)..3]) -join '.'
    if ($erwartet -ne $zone) { return $null }
    return (($umgekehrt[0..(3 - $anzahl)]) -join '.')
}
#
function Find-NetReverseZone {
    <#
    .SYNOPSIS
        Sucht aus einer Liste von Zonennamen die passendste Reverse-Zone fuer eine Adresse.
    #>
    param([Parameter(Mandatory = $true)][string]$IPAddress, [string[]]$ZoneNames = @())
    $best = $null
    $bestLaenge = 0
    foreach ($zone in $ZoneNames) {
        if ($zone -notmatch 'in-addr\.arpa\.?$') { continue }
        $name = Get-NetPtrName -IPAddress $IPAddress -ZoneName $zone
        if ($null -ne $name) {
            $laenge = $zone.Split('.').Count
            if ($laenge -gt $bestLaenge) { $best = $zone; $bestLaenge = $laenge }
        }
    }
    return $best
}
#
function Test-NetHostName {
    <#
    .SYNOPSIS
        Prueft einen Computernamen (NetBIOS-tauglich). Liefert $null wenn gueltig, sonst den Grund.
    #>
    param([AllowEmptyString()][string]$Name)
    if (-not $Name) { return 'Der Name darf nicht leer sein.' }
    if ($Name.Length -gt 15) { return 'Der Name darf hoechstens 15 Zeichen lang sein (NetBIOS-Grenze).' }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'Erlaubt sind nur Buchstaben A-Z, Ziffern und Bindestrich.' }
    if ($Name -match '^-|-$') { return 'Der Name darf nicht mit einem Bindestrich beginnen oder enden.' }
    if ($Name -match '^\d+$') { return 'Der Name darf nicht nur aus Ziffern bestehen.' }
    return $null
}
#
function Test-NetDnsLabel {
    param([AllowEmptyString()][string]$Label)
    return ($Label -match '^[A-Za-z0-9_]([A-Za-z0-9-_]{0,61}[A-Za-z0-9])?$')
}
#
function Test-NetDomainName {
    <#
    .SYNOPSIS
        Prueft einen DNS-Domaenennamen fuer AD. Liefert Gueltig, Fehler und Warnungen.
    #>
    param([AllowEmptyString()][string]$Name)
    $fehler = $null
    $warnungen = @()
    $n = ([string]$Name).Trim().TrimEnd('.').ToLower()
    if (-not $n) { $fehler = 'Der Domaenenname darf nicht leer sein.' }
    elseif ($n.Length -gt 253) { $fehler = 'Der Domaenenname ist zu lang (hoechstens 253 Zeichen).' }
    elseif ($n -notmatch '\.') { $fehler = 'Ein einteiliger Name (Single-Label wie "firma") ist nicht erlaubt. Beispiel: ad.firma.ch' }
    else {
        foreach ($label in $n.Split('.')) {
            if (-not (Test-NetDnsLabel -Label $label) -or $label.Contains('_')) {
                $fehler = "Der Teil '$label' ist ungueltig (nur a-z, 0-9 und Bindestrich, nicht am Anfang oder Ende, hoechstens 63 Zeichen)."
                break
            }
        }
        if ((-not $fehler) -and ($n.Split('.')[-1] -match '^\d+$')) { $fehler = 'Die letzte Stelle darf nicht nur aus Ziffern bestehen.' }
    }
    if (-not $fehler) {
        if ($n -match '\.local$') { $warnungen += '.local ist fuer Multicast-DNS (Bonjour) reserviert und macht Probleme mit Apple-Geraeten und Zertifikaten. Besser eine Subdomain der eigenen Domain verwenden, z. B. ad.firma.ch.' }
        if ($n.Split('.').Count -eq 2) { $warnungen += 'Empfohlen ist eine Subdomain der eigenen Internet-Domain (z. B. ad.firma.ch statt firma.ch), damit interne und externe Namen nicht kollidieren.' }
    }
    return [pscustomobject]@{ Gueltig = (-not $fehler); Fehler = $fehler; Warnungen = $warnungen; Name = $n }
}
#
function Get-NetNetBiosSuggestion {
    <#
    .SYNOPSIS
        Schlaegt einen NetBIOS-Domaenennamen aus dem DNS-Namen vor (erster Teil, max. 15 Zeichen).
    #>
    param([Parameter(Mandatory = $true)][string]$DomainName)
    $teile = $DomainName.Split('.')
    $basis = $teile[0]
    if ((($basis -eq 'ad') -or ($basis -eq 'corp') -or ($basis -eq 'intern')) -and ($teile.Count -gt 2)) { $basis = $teile[1] }
    $basis = ($basis -replace '[^A-Za-z0-9-]', '').ToUpper()
    if ($basis.Length -gt 15) { $basis = $basis.Substring(0, 15) }
    return $basis
}
# ----------------------------------------------------------------------
# src/core/Aenderung.ps1
# ----------------------------------------------------------------------
# Zentraler Ablauf fuer jede Aenderung am Server:
# Zusammenfassung -> Bestaetigung (je nach Stufe) -> Backup -> Ausfuehren -> Log -> Gegenaktion merken.
# Der Probelauf (Einstellung oder -WhatIf) zeigt nur an, was passieren wuerde.
#
# Module, deren Befehle als Gegenaktion in der Rueckgaengig-Liste stehen duerfen.
$script:NetUndoModule = @('DnsServer', 'DhcpServer', 'NetTCPIP', 'DnsClient', 'NetSecurity', 'ActiveDirectory', 'ServerManager', 'ScheduledTasks', 'Microsoft.PowerShell.Management')
#
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
#
function Test-NetDryRun {
    <#
    .SYNOPSIS
        Liefert $true, wenn der Probelauf aktiv ist (Einstellung oder -WhatIf).
    #>
    return ([bool]$script:NS.Probelauf -or [bool]$WhatIfPreference)
}
#
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
#
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
#
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
#
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
#
    # 4. Ausfuehren
    $ncSchritt = Invoke-NetStep -Titel $Titel -Aktion $Aktion
    $ncErgebnis.Erfolg = $ncSchritt.Erfolg
    $ncErgebnis.Ergebnis = $ncSchritt.Ergebnis
    $ncErgebnis.Fehler = $ncSchritt.Fehler
#
    # 5. Gegenaktion merken
    if ($ncSchritt.Erfolg -and $Rueckgaengig) {
        Add-NetUndoEntry -Titel $Titel -Schritte $Rueckgaengig | Out-Null
    }
    return $ncErgebnis
}
#
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
#
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
#
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
#
function Save-NetUndoList {
    param([object[]]$Liste)
    $datei = Get-NetPath -Name Verlauf
    $ordner = Split-Path -Path $datei -Parent
    if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Liste) -Depth 10
    Set-Content -Path $datei -Value $json -Encoding UTF8 -ErrorAction Stop
}
#
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
#
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
#
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
# ----------------------------------------------------------------------
# src/core/Umgebung.ps1
# ----------------------------------------------------------------------
# Umgebung erkennen (Administrator, Windows Server, PowerShell-Version, Server Core, Sprache),
# Script selbst speichern, Desktop-Verknuepfung und Neustart mit Adminrechten.
#
function Test-NetIsAdmin {
    if (-not (Test-NetIsWindows)) { return $false }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}
#
function Get-NetEnvironment {
    <#
    .SYNOPSIS
        Erkennt die Umgebung, in der NetSetup laeuft (nur lesend).
    #>
    $os = Get-NetSafe -Beschreibung 'Win32_OperatingSystem' -Abfrage { Get-CimInstance -ClassName Win32_OperatingSystem }
    $installationsTyp = Get-NetSafe -Beschreibung 'InstallationType' -Abfrage {
        (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType).InstallationType
    }
    $edition = Get-NetSafe -Beschreibung 'EditionID' -Abfrage {
        (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
    }
    $istIse = ($null -ne (Get-Variable -Name psISE -Scope Global -ErrorAction SilentlyContinue)) -or ($Host.Name -eq 'Windows PowerShell ISE Host')
    $istCore = ([string]$installationsTyp -eq 'Server Core')
    $productType = 0
    if ($os) { $productType = [int]$os.ProductType }
    $umgebung = [pscustomobject]@{
        IstWindows   = (Test-NetIsWindows)
        IstAdmin     = (Test-NetIsAdmin)
        ProductType  = $productType
        IstServer    = ($productType -eq 2 -or $productType -eq 3)
        OsName       = $(if ($os) { [string]$os.Caption } else { 'unbekannt' })
        OsVersion    = $(if ($os) { [string]$os.Version } else { '' })
        Build        = $(if ($os) { [string]$os.BuildNumber } else { '' })
        OsSprache    = $(if ($os) { [int]$os.OSLanguage } else { 0 })
        Edition      = [string]$edition
        IstCore      = $istCore
        PsVersion    = $PSVersionTable.PSVersion
        PsEdition    = $(if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' })
        Sprache      = (Get-Culture).Name
        UiSprache    = (Get-UICulture).Name
        IstIse       = $istIse
        HatGridView  = ((-not $istCore) -and [bool](Get-Command -Name Out-GridView -ErrorAction SilentlyContinue))
        Computername = [Environment]::MachineName
    }
    $script:NS.Umgebung = $umgebung
    return $umgebung
}
#
function Test-NetPrerequisite {
    <#
    .SYNOPSIS
        Prueft die Voraussetzungen. Liefert 'OK', 'Abbruch' oder 'NeuGestartet'.
    #>
    param([Parameter(Mandatory = $true)][object]$Umgebung)
#
    if (-not $Umgebung.IstWindows) {
        Write-Log -Level Fehler -Message 'NetSetup laeuft nur auf Windows Server.'
        return 'Abbruch'
    }
    if ($Umgebung.PsVersion.Major -lt 5 -or ($Umgebung.PsVersion.Major -eq 5 -and $Umgebung.PsVersion.Minor -lt 1)) {
        Write-Log -Level Fehler -Message ('NetSetup braucht Windows PowerShell 5.1, gefunden: {0}.' -f $Umgebung.PsVersion)
        Write-Log -Message 'Naechster Schritt: Windows Management Framework 5.1 installieren (bei Server 2016 und neuer schon enthalten).'
        return 'Abbruch'
    }
    if ($Umgebung.PsEdition -eq 'Core') {
        Write-Log -Level Warn -Message ('Gestartet in PowerShell {0}. NetSetup ist fuer Windows PowerShell 5.1 gebaut (powershell.exe), manche Server-Module laufen nur dort.' -f $Umgebung.PsVersion)
        if ($script:NS.Interaktiv -and -not (Read-NetYesNo -Frage 'Trotzdem fortfahren?' -Vorschlag $false)) { return 'Abbruch' }
    }
    if ($Umgebung.ProductType -eq 1) {
        Write-Log -Level Fehler -Message ('Dies ist kein Windows Server, sondern {0}.' -f $Umgebung.OsName)
        Write-Log -Message 'AD, DNS-Server und DHCP-Server gibt es nur auf Windows Server. Bitte NetSetup auf dem Server ausfuehren, der diese Rollen bekommen soll.'
        return 'Abbruch'
    }
    if ($Umgebung.ProductType -eq 0) {
        Write-Log -Level Warn -Message 'Die Windows-Version konnte nicht erkannt werden. NetSetup versucht es trotzdem.'
    }
    if (-not $Umgebung.IstAdmin) {
        Write-Log -Level Warn -Message 'NetSetup laeuft ohne Administratorrechte. Fast alle Aufgaben brauchen diese Rechte.'
        if (-not $script:NS.Interaktiv) { return 'Abbruch' }
        if (Read-NetYesNo -Frage 'Jetzt mit Administratorrechten neu starten (Windows fragt nach)?' -Vorschlag $true) {
            if (Request-NetElevation) { return 'NeuGestartet' }
        }
        Write-Log -Message 'So geht es von Hand: Startmenue -> "Windows PowerShell ISE" oder "Windows PowerShell" mit rechter Maustaste -> "Als Administrator ausfuehren", dann das Script erneut einfuegen.'
        return 'Abbruch'
    }
    return 'OK'
}
#
function Get-NetSelfContent {
    <#
    .SYNOPSIS
        Liefert den vollstaendigen Script-Text zum Speichern (aus dem laufenden Scriptblock).
    #>
    $block = Get-Variable -Name NetSetupCode -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $block) { return $null }
    $kopf = @(
        '<#',
        ('    NetSetup {0} (Build {1})' -f $script:NS.Version, $script:NS.BuildDatum),
        '    AD, DNS und DHCP auf Windows Server einrichten, verwalten und reparieren.',
        '    Gespeichert von NetSetup. Start: powershell.exe -ExecutionPolicy Bypass -File NetSetup.ps1',
        '    Ohne Menue: -Task Health | Report | Backup | Resume',
        '#>'
    ) -join "`r`n"
    return ($kopf + "`r`n`$NetSetupCode = {" + $block.ToString() + "}`r`n& `$NetSetupCode @args`r`n")
}
#
function Save-NetSelf {
    <#
    .SYNOPSIS
        Speichert das laufende Script als Datei (Standard: <Datenordner>\NetSetup.ps1).
    #>
    param([string]$Ziel = (Get-NetPath -Name Script))
    $inhalt = Get-NetSelfContent
    if (-not $inhalt) {
        Write-Log -Level Debug -Message 'Script-Text nicht verfuegbar (Scriptblock fehlt), Speichern uebersprungen.'
        return $null
    }
    try {
        $ordner = Split-Path -Path $Ziel -Parent
        if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
        $alt = $null
        if (Test-Path -Path $Ziel) { $alt = Get-Content -Path $Ziel -Raw -ErrorAction SilentlyContinue }
        if ($alt -ne $inhalt) {
            [System.IO.File]::WriteAllText($Ziel, $inhalt, (New-Object System.Text.ASCIIEncoding))
            Write-Log -Level OK -Message ('Script gespeichert: ' + $Ziel)
        }
        return $Ziel
    }
    catch {
        Write-NetError -Fehler $_ -Titel 'Script speichern' | Out-Null
        return $null
    }
}
#
function Get-NetPowerShellExe {
    return (Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe')
}
#
function Request-NetElevation {
    <#
    .SYNOPSIS
        Speichert eine Kopie nach %TEMP% und startet sie per UAC mit Administratorrechten.
    #>
    $ziel = Join-Path -Path $env:TEMP -ChildPath 'NetSetup.ps1'
    $gespeichert = Save-NetSelf -Ziel $ziel
    if (-not $gespeichert) {
        Write-Log -Level Warn -Message 'Die Kopie fuer den Neustart konnte nicht gespeichert werden.'
        return $false
    }
    try {
        $argumente = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $ziel))
        Start-Process -FilePath (Get-NetPowerShellExe) -ArgumentList $argumente -Verb RunAs -ErrorAction Stop | Out-Null
        Write-Log -Level OK -Message 'NetSetup wurde in einem neuen Fenster mit Administratorrechten gestartet. Dieses Fenster kann geschlossen werden.'
        return $true
    }
    catch {
        Write-Log -Level Warn -Message 'Der Start mit Administratorrechten wurde abgelehnt oder ist fehlgeschlagen.'
        Write-Log -Level Debug -Message $_.Exception.ToString()
        return $false
    }
}
#
function New-NetDesktopShortcut {
    <#
    .SYNOPSIS
        Legt eine Desktop-Verknuepfung "NetSetup" an, die als Administrator startet.
    #>
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -Path $desktop)) {
        Write-Log -Level Warn -Message 'Kein Desktop gefunden (z. B. Server Core). Verknuepfung wird nicht angelegt.'
        return $false
    }
    $lnk = Join-Path -Path $desktop -ChildPath 'NetSetup.lnk'
    $script_pfad = Get-NetPath -Name Script
    $r = Invoke-NetChange -Titel 'Desktop-Verknuepfung NetSetup anlegen' -Stufe Automatisch -Aktion {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($lnk)
        $link.TargetPath = (Get-NetPowerShellExe)
        $link.Arguments = ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $script_pfad)
        $link.WorkingDirectory = (Get-NetPath -Name Root)
        $link.Description = 'NetSetup: AD, DNS und DHCP einrichten und pruefen'
        $link.Save()
        # Flag "Als Administrator ausfuehren" (Bit 0x20 in Byte 0x15 der .lnk-Datei)
        $bytes = [System.IO.File]::ReadAllBytes($lnk)
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [System.IO.File]::WriteAllBytes($lnk, $bytes)
    } -Rueckgaengig @{ Befehl = 'Remove-Item'; Parameter = @{ Path = $lnk; Force = $true } }
    return $r.Erfolg
}
# ----------------------------------------------------------------------
# src/ui/Eingabe.ps1
# ----------------------------------------------------------------------
# Eingaben mit sofortiger Pruefung und Vorschlagswerten.
# Leere Eingabe = Vorschlag uebernehmen, "!" = abbrechen (Rueckgabe $null).
#
function Read-NetInput {
    <#
    .SYNOPSIS
        Einzige Stelle, die Read-Host aufruft (in Tests leicht zu ersetzen).
    #>
    param([Parameter(Mandatory = $true)][string]$Prompt, [switch]$Geheim)
    if (-not $script:NS.Interaktiv) { return $null }
    if ($Geheim) { return (Read-Host -Prompt $Prompt -AsSecureString) }
    return (Read-Host -Prompt $Prompt)
}
#
function Wait-NetKey {
    if (-not $script:NS.Interaktiv) { return }
    Read-NetInput -Prompt 'Weiter mit Enter' | Out-Null
}
#
function Read-NetText {
    <#
    .SYNOPSIS
        Fragt einen Text ab. Die Pruefung liefert $null (gueltig) oder einen Fehlertext.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [string]$Vorschlag = '',
        [scriptblock]$Pruefung,
        [switch]$LeerErlaubt
    )
    while ($true) {
        $prompt = $Frage
        if ($Vorschlag) { $prompt += " [$Vorschlag]" }
        $antwort = Read-NetInput -Prompt $prompt
        if ($null -eq $antwort) { return $null }
        $antwort = ([string]$antwort).Trim()
        if ($antwort -eq '!') { Write-Log -Message 'Eingabe abgebrochen.'; return $null }
        if ($antwort -eq '') {
            if ($Vorschlag) { $antwort = $Vorschlag }
            elseif ($LeerErlaubt) { return '' }
            else { Write-Host '[WARN]   Bitte einen Wert eingeben (oder ! zum Abbrechen).' -ForegroundColor Yellow; continue }
        }
        if ($Pruefung) {
            $fehler = & $Pruefung $antwort
            if ($fehler) { Write-Host ('[WARN]   ' + $fehler) -ForegroundColor Yellow; continue }
        }
        return $antwort
    }
}
#
function Read-NetYesNo {
    <#
    .SYNOPSIS
        Ja/Nein-Frage. Leere Eingabe = Vorschlag. Ohne Benutzer (Task) gilt der Vorschlag.
    #>
    param([Parameter(Mandatory = $true)][string]$Frage, [bool]$Vorschlag = $true)
    if (-not $script:NS.Interaktiv) { return $Vorschlag }
    $auswahl = '[j/N]'
    if ($Vorschlag) { $auswahl = '[J/n]' }
    while ($true) {
        $antwort = Read-NetInput -Prompt ("$Frage $auswahl")
        if ($null -eq $antwort) { return $Vorschlag }
        $a = ([string]$antwort).Trim().ToLower()
        if ($a -eq '') { return $Vorschlag }
        if (@('j', 'ja', 'y', 'yes') -contains $a) { return $true }
        if (@('n', 'nein', 'no', '!') -contains $a) { return $false }
        Write-Host '[WARN]   Bitte j oder n eingeben.' -ForegroundColor Yellow
    }
}
#
function Read-NetNumber {
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [int]$Minimum = 0,
        [int]$Maximum = [int]::MaxValue,
        [Nullable[int]]$Vorschlag = $null
    )
    $vor = ''
    if ($null -ne $Vorschlag) { $vor = [string]$Vorschlag }
    $grenzeMin = $Minimum
    $grenzeMax = $Maximum
    $text = Read-NetText -Frage $Frage -Vorschlag $vor -Pruefung {
        param($t)
        $z = 0
        if (-not [int]::TryParse($t, [ref]$z)) { return 'Bitte eine ganze Zahl eingeben.' }
        if ($z -lt $grenzeMin -or $z -gt $grenzeMax) { return "Erlaubt ist $grenzeMin bis $grenzeMax." }
        return $null
    }
    if ($null -eq $text) { return $null }
    return [int]$text
}
#
function Read-NetIPAddress {
    <#
    .SYNOPSIS
        Fragt eine IPv4-Adresse ab, optional muss sie in einem Netz liegen.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [string]$Vorschlag = '',
        [string]$Netz,
        [int]$Prefix = 0,
        [switch]$LeerErlaubt
    )
    $pruefNetz = $Netz
    $pruefPrefix = $Prefix
    $pruefung = {
        param($t)
        if (-not (Test-NetIPv4Address -Text $t)) { return "'$t' ist keine gueltige IPv4-Adresse (Beispiel: 192.168.1.10)." }
        if ($pruefNetz -and $pruefPrefix -gt 0 -and -not (Test-NetIPInSubnet -IPAddress $t -NetworkAddress $pruefNetz -PrefixLength $pruefPrefix)) {
            return "Die Adresse liegt nicht im Netz $pruefNetz/$pruefPrefix."
        }
        return $null
    }
    return (Read-NetText -Frage $Frage -Vorschlag $Vorschlag -Pruefung $pruefung -LeerErlaubt:$LeerErlaubt)
}
#
function ConvertTo-NetSubnet {
    <#
    .SYNOPSIS
        Wandelt "192.168.1.0/24" oder "192.168.1.0 255.255.255.0" in ein Subnetz-Objekt.
        Liefert $null bei ungueltiger Eingabe.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $t = $Text.Trim()
    $ip = $null
    $prefix = -1
    if ($t -match '^(\S+)\s*/\s*(\d{1,2})$') { $ip = $Matches[1]; $prefix = [int]$Matches[2] }
    elseif ($t -match '^(\S+)\s+(\S+)$') { $ip = $Matches[1]; $prefix = ConvertTo-NetPrefixLength -SubnetMask $Matches[2] }
    else { return $null }
    if (-not (Test-NetIPv4Address -Text $ip) -or $prefix -lt 1 -or $prefix -gt 32) { return $null }
    $netz = Get-NetNetworkAddress -IPAddress $ip -PrefixLength $prefix
    return [pscustomobject]@{
        Netz        = $netz
        Prefix      = $prefix
        Maske       = (ConvertTo-NetSubnetMask -PrefixLength $prefix)
        Text        = "$netz/$prefix"
        HostBitsGesetzt = ($netz -ne $ip)
    }
}
#
function Read-NetSubnet {
    <#
    .SYNOPSIS
        Fragt ein Netz ab (192.168.1.0/24 oder 192.168.1.0 255.255.255.0).
    #>
    param([Parameter(Mandatory = $true)][string]$Frage, [string]$Vorschlag = '')
    $text = Read-NetText -Frage $Frage -Vorschlag $Vorschlag -Pruefung {
        param($t)
        $s = ConvertTo-NetSubnet -Text $t
        if ($null -eq $s) { return 'Bitte im Format 192.168.1.0/24 oder 192.168.1.0 255.255.255.0 eingeben (Maske muss gueltig sein).' }
        if ($s.Prefix -gt 30) { return 'Das Netz ist zu klein (hoechstens /30).' }
        return $null
    }
    if ($null -eq $text) { return $null }
    $s = ConvertTo-NetSubnet -Text $text
    if ($s.HostBitsGesetzt) { Write-Log -Message ('Hinweis: Als Netzadresse wird {0} verwendet.' -f $s.Text) }
    return $s
}
#
function Read-NetChoice {
    <#
    .SYNOPSIS
        Auswahl aus einer Liste per Nummer. Liefert den Index (ab 0) oder -1 bei Abbruch.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [Parameter(Mandatory = $true)][string[]]$Optionen,
        [int]$Vorschlag = 1
    )
    if (-not $script:NS.Interaktiv) { return ($Vorschlag - 1) }
    Write-Host ''
    Write-Host ('  ' + $Frage) -ForegroundColor White
    for ($i = 0; $i -lt $Optionen.Count; $i++) {
        Write-Host ('   [{0}] {1}' -f ($i + 1), $Optionen[$i])
    }
    $anzahl = $Optionen.Count
    $t = Read-NetText -Frage 'Nummer' -Vorschlag ([string]$Vorschlag) -Pruefung {
        param($x)
        $z = 0
        if (-not [int]::TryParse($x, [ref]$z) -or $z -lt 1 -or $z -gt $anzahl) { return "Bitte eine Nummer von 1 bis $anzahl eingeben." }
        return $null
    }
    if ($null -eq $t) { return -1 }
    return ([int]$t - 1)
}
#
function ConvertFrom-NetSecureString {
    <#
    .SYNOPSIS
        Gibt den Klartext einer SecureString nur kurz im Speicher zurueck (fuer Pruefungen und
        Cmdlets, die Klartext verlangen). Nie speichern, nie loggen.
    #>
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Geheim)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Geheim)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
#
function Test-NetSecretComplexity {
    <#
    .SYNOPSIS
        Prueft ein Kennwort auf Windows-Komplexitaet. Liefert $null wenn ok, sonst den Grund.
    #>
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Geheim, [int]$MinLaenge = 8)
    $klar = ConvertFrom-NetSecureString -Geheim $Geheim
    try {
        if ($klar.Length -lt $MinLaenge) { return "Das Kennwort muss mindestens $MinLaenge Zeichen haben." }
        $klassen = 0
        if ($klar -cmatch '[A-Z]') { $klassen++ }
        if ($klar -cmatch '[a-z]') { $klassen++ }
        if ($klar -match '\d') { $klassen++ }
        if ($klar -match '[^A-Za-z0-9]') { $klassen++ }
        if ($klassen -lt 3) { return 'Das Kennwort braucht mindestens 3 von 4 Arten: Grossbuchstaben, Kleinbuchstaben, Ziffern, Sonderzeichen.' }
        return $null
    }
    finally { $klar = $null }
}
#
function Test-NetSecretEqual {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Erstes, [Parameter(Mandatory = $true)][System.Security.SecureString]$Zweites)
    $a = ConvertFrom-NetSecureString -Geheim $Erstes
    $b = ConvertFrom-NetSecureString -Geheim $Zweites
    try { return ($a -ceq $b) }
    finally { $a = $null; $b = $null }
}
#
function Read-NetSecret {
    <#
    .SYNOPSIS
        Fragt ein Kennwort verdeckt als SecureString ab, optional zweimal und mit Komplexitaetspruefung.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [switch]$Bestaetigen,
        [switch]$Komplex,
        [int]$MinLaenge = 8
    )
    for ($versuch = 1; $versuch -le 5; $versuch++) {
        $erstes = Read-NetInput -Prompt $Frage -Geheim
        if ($null -eq $erstes) { return $null }
        if ($erstes.Length -eq 0) { Write-Host '[WARN]   Leere Eingabe. Abbruch.' -ForegroundColor Yellow; return $null }
        if ($Komplex) {
            $grund = Test-NetSecretComplexity -Geheim $erstes -MinLaenge $MinLaenge
            if ($grund) { Write-Host ('[WARN]   ' + $grund) -ForegroundColor Yellow; continue }
        }
        if ($Bestaetigen) {
            $zweites = Read-NetInput -Prompt 'Zur Kontrolle wiederholen' -Geheim
            if (($null -eq $zweites) -or -not (Test-NetSecretEqual -Erstes $erstes -Zweites $zweites)) {
                Write-Host '[WARN]   Die Eingaben stimmen nicht ueberein.' -ForegroundColor Yellow
                continue
            }
        }
        return $erstes
    }
    Write-Log -Level Warn -Message 'Zu viele Fehlversuche, Eingabe abgebrochen.'
    return $null
}
#
function Confirm-NetChange {
    <#
    .SYNOPSIS
        Zeigt Vorher/Nachher einer geplanten Aenderung und fragt J/N (Vorschlag: Nein).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Titel,
        [AllowNull()][object]$Vorher,
        [AllowNull()][object]$Nachher,
        [string]$Hinweis,
        [string]$Stufe = 'Bestaetigen'
    )
    Write-Host ''
    Write-Host ('--- Geplante Aenderung: ' + $Titel + ' ---') -ForegroundColor Yellow
    if ($PSBoundParameters.ContainsKey('Vorher')) {
        Write-Host '  Vorher:' -ForegroundColor DarkYellow
        foreach ($z in (Format-NetValue -Wert $Vorher)) { Write-Host ('    ' + $z) }
    }
    if ($PSBoundParameters.ContainsKey('Nachher')) {
        Write-Host '  Nachher:' -ForegroundColor Green
        foreach ($z in (Format-NetValue -Wert $Nachher)) { Write-Host ('    ' + $z) }
    }
    if ($Hinweis) { Write-NetText -Text $Hinweis -Farbe Yellow }
    if ($Stufe -eq 'Gefaehrlich') { Write-Host '  Stufe: GEFAEHRLICH (vorher wird automatisch ein Backup erstellt)' -ForegroundColor Red }
    if (Test-NetDryRun) { Write-Host '  Probelauf ist aktiv: es wird nichts geaendert.' -ForegroundColor Magenta }
    if (-not $script:NS.Interaktiv) { return $false }
    return (Read-NetYesNo -Frage 'Ausfuehren?' -Vorschlag $false)
}
#
function Confirm-NetDangerous {
    <#
    .SYNOPSIS
        Zweite Sicherheitsstufe: der Servername muss eingetippt werden.
    #>
    param([Parameter(Mandatory = $true)][string]$Titel, [string]$Hinweis)
    if (-not $script:NS.Interaktiv) { return $false }
    $name = [Environment]::MachineName
    Write-Host ''
    Write-Host '!!! ACHTUNG: Diese Aenderung ist gefaehrlich und kann den Betrieb stoeren !!!' -ForegroundColor Red
    Write-Host ('    ' + $Titel) -ForegroundColor Red
    if ($Hinweis) { Write-NetText -Text $Hinweis -Farbe Red }
    $eingabe = Read-NetInput -Prompt ("Zum Bestaetigen den Servernamen eintippen ($name)")
    if (($null -ne $eingabe) -and (([string]$eingabe).Trim() -ieq $name)) { return $true }
    Write-Log -Level Warn -Message 'Der Servername stimmt nicht. Es wird nichts geaendert.'
    return $false
}
# ----------------------------------------------------------------------
# src/ui/Menue.ps1
# ----------------------------------------------------------------------
# Menue-Baustein: Auswahl per Nummer, Hilfe mit ? und ?N, Glossar mit G.
# Ein Eintrag ist eine Hashtable: @{ Text = '...'; Aktion = 'Funktionsname' oder { ... }; Hilfe = '...' }
# Ist die Funktion (noch) nicht vorhanden, erscheint der Punkt als "kommt noch".
#
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
#
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
#
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
#
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
#
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
#
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
#
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
#
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
#
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
# ----------------------------------------------------------------------
# src/ui/Hilfe.ps1
# ----------------------------------------------------------------------
# Hilfe und Glossar. Alles Wissen steckt im Script, damit niemand im Internet suchen muss.
# Die Texte des Glossars stehen gleichlautend in docs/handbuch.md.
#
$script:NetGlossar = [ordered]@{
    'A-Eintrag'             = 'DNS-Eintrag, der einen Namen einer IPv4-Adresse zuordnet (pc01.ad.firma.ch -> 192.168.1.50). AAAA ist dasselbe fuer IPv6.'
    'Abhoer-IP-Adresse'     = 'Die Adressen des Servers, auf denen der DNS-Dienst Anfragen annimmt. Ueblich: alle festen IPv4-Adressen des Servers, keine APIPA-Adressen (169.254.x.x).'
    'Aging/Scavenging'      = 'Automatisches Aufraeumen alter, dynamisch eingetragener DNS-Eintraege. Aging merkt sich, wann ein Eintrag zuletzt erneuert wurde; Scavenging loescht Eintraege, die laenger als No-Refresh + Refresh nicht erneuert wurden. Ueblich: an, 7 + 7 Tage. Die Summe muss mindestens so lang sein wie die DHCP-Lease-Dauer.'
    'Ausschluss'            = 'Ein Adressbereich innerhalb eines DHCP-Scopes, den der DHCP-Server nie vergibt, z. B. fuer Drucker oder Server mit fester IP.'
    'Autorisierung'         = 'Eintrag des DHCP-Servers im Active Directory. Ein Windows-DHCP-Server in einer Domaene vergibt erst Adressen, wenn er autorisiert ist. Dafuer sind Rechte der Organisations-Admins (Enterprise Admins) noetig.'
    'Bindung'               = 'Legt fest, auf welcher Netzwerkkarte der DHCP-Server Anfragen beantwortet. Nur Karten mit fester IP im Netz der Clients sollten gebunden sein.'
    'CNAME'                 = 'Alias-Eintrag im DNS: ein zweiter Name zeigt auf einen vorhandenen Namen (intranet -> srv01).'
    'DHCP-Relay'            = 'Funktion im Router oder Layer-3-Switch (oft "IP Helper" genannt), die DHCP-Anfragen aus anderen Netzen (VLANs) an den DHCP-Server weiterleitet. Ohne Relay erreicht ein DHCP-Server nur das eigene Netz.'
    'DHCPv6'                = 'DHCP fuer IPv6. In den meisten Netzen nicht noetig, weil IPv6 sich per Router-Ankuendigung (SLAAC) selbst konfiguriert. In NetSetup unter "Erweitert".'
    'Dienstkonto'           = 'Ein eigenes AD-Benutzerkonto nur fuer einen Dienst, hier fuer die DNS-Eintraege des DHCP-Servers (Vorschlag svc-dhcpdns). Sein Kennwort muss gepflegt werden, sonst schlagen die Eintraege nach Ablauf fehl.'
    'DNSSEC'                = 'Digitale Signaturen fuer DNS-Zonen, damit Antworten nicht gefaelscht werden koennen. Erfordert Schluesselpflege; ein Fehler kann die Namensaufloesung stoeren. In NetSetup unter "Erweitert".'
    'Domaenencontroller'    = 'Server, der das Active Directory speichert und Anmeldungen prueft (kurz DC). Mindestens zwei DCs pro Domaene sind empfohlen.'
    'DSRM'                  = 'Verzeichnisdienst-Wiederherstellungsmodus (Directory Services Restore Mode). Notfall-Anmeldung an einem DC, wenn das AD nicht startet. Das DSRM-Kennwort wird bei der Heraufstufung festgelegt und muss sicher aufbewahrt werden.'
    'Dynamisches Update'    = 'Clients oder der DHCP-Server tragen ihre DNS-Eintraege selbst ein. "Sicher" (nur auf AD-integrierten Zonen) erlaubt das nur angemeldeten Domaenenmitgliedern und ist die empfohlene Einstellung.'
    'Failover'              = 'Zwei DHCP-Server teilen sich einen Scope. Lastverteilung: beide vergeben Adressen. Reserve (Hot-Standby): einer arbeitet, der andere springt bei Ausfall ein. Beide brauchen ein gemeinsames Geheimnis.'
    'Funktionsebene'        = 'Legt fest, welche AD-Funktionen genutzt werden koennen und welche Windows-Versionen als DC erlaubt sind. NetSetup schlaegt die hoechste Ebene vor, die das Betriebssystem kann.'
    'Gateway'               = 'Der Router, ueber den ein Netz andere Netze und das Internet erreicht (DHCP-Option 003).'
    'Gesamtstruktur'        = 'Englisch Forest. Die oberste Ebene im Active Directory, enthaelt eine oder mehrere Domaenen. Die erste Domaene ist die Stammdomaene der Gesamtstruktur.'
    'Lease'                 = 'Die zeitlich begrenzte Vergabe einer IP-Adresse an einen Client. Vor Ablauf erneuert der Client die Lease. Ueblich in Bueros: 8 Tage; in Gaeste- oder WLAN-Netzen kuerzer (z. B. 1 Tag).'
    'MX'                    = 'Mail-Exchanger-Eintrag im DNS: nennt den Mailserver einer Domaene mit einer Prioritaet (kleinere Zahl = bevorzugt).'
    'Namensschutz'          = 'DHCP-Einstellung (Name Protection): verhindert, dass ein Geraet den DNS-Namen eines anderen Geraets uebernimmt.'
    'NetBIOS-Name'          = 'Kurzer, alter Domaenenname (hoechstens 15 Zeichen, z. B. FIRMA), der bei der Anmeldung als FIRMA\benutzer erscheint.'
    'Option'                = 'Zusatzinformation, die der DHCP-Server mit der Adresse mitliefert, z. B. 003 Router, 006 DNS-Server, 015 DNS-Domaenenname, 042 NTP-Server, 066/067 PXE-Bootserver und Bootdatei, 119 DNS-Suchliste.'
    'Organisations-Admins'  = 'Englisch Enterprise Admins. AD-Gruppe mit Rechten fuer die ganze Gesamtstruktur, noetig z. B. fuer die DHCP-Autorisierung.'
    'Probelauf'             = 'Modus, in dem NetSetup alles prueft und anzeigt, aber nichts aendert (entspricht -WhatIf). In den Einstellungen umschaltbar.'
    'PTR'                   = 'Zeiger-Eintrag in einer Reverse-Zone: ordnet einer IP-Adresse einen Namen zu (192.168.1.50 -> pc01.ad.firma.ch).'
    'Reservierung'          = 'Feste Zuordnung einer IP-Adresse zu einem Geraet (ueber die MAC-Adresse). Das Geraet bekommt per DHCP immer dieselbe Adresse.'
    'Reverse-Zone'          = 'DNS-Zone fuer die Rueckwaertssuche von IP-Adresse zu Name, z. B. 1.168.192.in-addr.arpa fuer das Netz 192.168.1.0/24. Enthaelt PTR-Eintraege.'
    'Rueckgaengig'          = 'NetSetup merkt sich zu jeder Aenderung die Gegenaktion. Unter "Backup, Wiederherstellen, Rueckgaengig" laesst sich die letzte oder eine bestimmte Aenderung zuruecknehmen.'
    'Scope'                 = 'Adressbereich, aus dem der DHCP-Server Adressen vergibt, z. B. 192.168.1.100 bis 192.168.1.199 im Netz 192.168.1.0/24, mit eigenen Optionen.'
    'Server Core'           = 'Windows Server ohne Desktop-Oberflaeche. NetSetup laeuft dort genauso, nur ohne Auswahlfenster (Out-GridView).'
    'Split-Brain'           = 'DNS gibt je nach Fragesteller unterschiedliche Antworten, z. B. intern die interne und extern die oeffentliche Adresse. Umgesetzt mit Zonen-Scopes und Abfrage-Richtlinien.'
    'SRV'                   = 'Dienst-Eintrag im DNS: nennt Server fuer einen Dienst mit Port, Prioritaet und Gewichtung. Das AD findet DCs ueber SRV-Eintraege wie _ldap._tcp.dc._msdcs.<domaene>.'
    'Stammhinweise'         = 'Englisch Root Hints. Liste der DNS-Stammserver im Internet. Ohne Weiterleitung fragt der DNS-Server von dort aus selbst durch. Funktioniert nur mit Internetzugang ueber Port 53.'
    'Subnetzmaske'          = 'Legt fest, welcher Teil einer IP-Adresse das Netz ist. 255.255.255.0 entspricht /24 (254 nutzbare Adressen).'
    'Superscope'            = 'Zusammenfassung mehrerer DHCP-Scopes, die im selben physischen Netz liegen (mehrere logische Netze auf einem Kabel).'
    'SYSVOL'                = 'Freigegebener Ordner auf jedem DC mit Gruppenrichtlinien und Anmeldescripts. Die Freigaben SYSVOL und NETLOGON muessen auf jedem DC vorhanden sein.'
    'TXT'                   = 'Text-Eintrag im DNS, z. B. fuer SPF oder Domaenen-Nachweise.'
    'Weiterleitung'         = 'Englisch Forwarder. Der DNS-Server schickt Anfragen, die er nicht selbst beantworten kann, an einen anderen DNS-Server (z. B. 9.9.9.9 Quad9, 1.1.1.1 Cloudflare oder den Router). Eine bedingte Weiterleitung gilt nur fuer eine bestimmte Domaene.'
    'Zeitquelle'            = 'Von wem ein Server die Uhrzeit bezieht. In einer Domaene folgen alle dem PDC-Emulator, der seine Zeit von einer externen Quelle holen sollte. Mehr als 5 Minuten Abweichung verhindern die Anmeldung (Kerberos).'
    'Zone'                  = 'Ein Bereich des DNS-Namensraums, den ein DNS-Server verwaltet, z. B. ad.firma.ch. AD-integrierte Zonen werden mit dem AD auf alle DCs repliziert, dateibasierte Zonen liegen nur auf einem Server.'
}
#
$script:NetHilfeAllgemein = @'
NetSetup richtet auf diesem Windows Server Active Directory, DNS und DHCP ein,
verbindet DHCP mit DNS und prueft und repariert die Einrichtung.
Bedienung:
  - Nummer eingeben und Enter druecken.
  - ? zeigt die Hilfe zum aktuellen Menue, ?3 die Hilfe zu Punkt 3, G das Glossar.
  - Bei Eingaben steht der Vorschlag in eckigen Klammern: Enter uebernimmt ihn.
  - ! bricht eine Eingabe ab, 0 geht ein Menue zurueck.
Sicherheitsregeln:
  - NetSetup schaut immer zuerst nach (Bestandsaufnahme) und aendert nie ungefragt.
  - Vor jeder Aenderung siehst du Vorher und Nachher und bestaetigst mit j.
  - Gefaehrliche Aenderungen (z. B. DC heraufstufen, Zone loeschen, IP aendern)
    erstellen vorher ein Backup und verlangen den Servernamen als Bestaetigung.
  - Jede Aenderung wird geloggt und kann rueckgaengig gemacht werden.
  - Im Probelauf (Einstellungen) wird nur angezeigt, nichts geaendert.
  - Kennwoerter werden nie gespeichert oder ins Log geschrieben.
Daten:
  - Alles liegt im Datenordner (Standard C:\NetSetup): Config, Logs, Backups,
    Berichte, Rueckgaengig, Vorlagen und das Script selbst (NetSetup.ps1).
Ohne Menue (z. B. geplante Aufgabe):
  powershell.exe -ExecutionPolicy Bypass -File C:\NetSetup\NetSetup.ps1 -Task Health
  Moegliche Aufgaben: Health (Pruefung + Bericht), Report, Backup, Resume.
'@
#
function Show-NetGlossary {
    <#
    .SYNOPSIS
        Zeigt das Glossar, optional gefiltert nach einem Suchbegriff.
    #>
    param([string]$Suche)
    Write-NetTitle -Titel 'Glossar'
    $gefunden = 0
    foreach ($begriff in $script:NetGlossar.Keys) {
        $text = $script:NetGlossar[$begriff]
        if ($Suche -and ($begriff -notlike "*$Suche*") -and ($text -notlike "*$Suche*")) { continue }
        Write-Host ('  ' + $begriff) -ForegroundColor White
        Write-NetText -Text ('    ' + $text)
        $gefunden++
    }
    if ($gefunden -eq 0) { Write-Log -Level Warn -Message "Kein Begriff zu '$Suche' gefunden." }
}
#
function Find-NetGlossaryTerm {
    $suche = Read-NetText -Frage 'Suchbegriff (z. B. Lease)'
    if ($suche) { Show-NetGlossary -Suche $suche }
}
#
function Show-NetGeneralHelp {
    Write-NetTitle -Titel 'Bedienung und Sicherheitsregeln'
    Write-NetText -Text $script:NetHilfeAllgemein
}
#
function Show-NetAbout {
    Write-NetTitle -Titel 'Ueber NetSetup'
    $u = $script:NS.Umgebung
    Write-Host ('  Version        : {0} (Build {1})' -f $script:NS.Version, $script:NS.BuildDatum)
    Write-Host ('  Datenordner    : {0}' -f (Get-NetPath -Name Root))
    Write-Host ('  Logdatei       : {0}' -f $script:NS.LogDatei)
    if ($u) {
        Write-Host ('  Server         : {0}' -f $u.Computername)
        Write-Host ('  Windows        : {0} (Build {1}, {2})' -f $u.OsName, $u.Build, $(if ($u.IstCore) { 'Server Core' } else { 'Desktop' }))
        Write-Host ('  PowerShell     : {0} {1}' -f $u.PsVersion, $u.PsEdition)
        Write-Host ('  Sprache        : {0} (Oberflaeche {1})' -f $u.Sprache, $u.UiSprache)
        Write-Host ('  Umgebung       : {0}' -f $(if ($u.IstIse) { 'PowerShell ISE' } else { 'Konsole' }))
    }
}
#
function Show-NetHelpMenu {
    $eintraege = @(
        @{ Text = 'Bedienung und Sicherheitsregeln'; Aktion = 'Show-NetGeneralHelp'; Hilfe = 'Wie NetSetup bedient wird und welche Sicherheitsregeln immer gelten.' },
        @{ Text = 'Glossar anzeigen'; Aktion = 'Show-NetGlossary'; Hilfe = 'Alle Fachbegriffe (Lease, Scope, Zone, PTR, ...) in einfachen Worten.' },
        @{ Text = 'Begriff im Glossar suchen'; Aktion = 'Find-NetGlossaryTerm'; Hilfe = 'Sucht einen Begriff im Glossar.' },
        @{ Text = 'Ueber NetSetup (Version, Umgebung)'; Aktion = 'Show-NetAbout'; Hilfe = 'Zeigt Version, Datenordner, Logdatei und die erkannte Umgebung.' }
    )
    Show-NetMenu -Titel 'Hilfe' -Eintraege $eintraege -Einleitung 'Hilfe und Nachschlagewerk. Alles ist im Script enthalten, es braucht kein Internet.'
}
# ----------------------------------------------------------------------
# src/ui/Einstellungen.ps1
# ----------------------------------------------------------------------
# Einstellungen: Probelauf, Auto-Reparatur, Backups, Auswahlfenster, Datenordner, Vorschlagswerte.
#
function Switch-NetDryRun {
    $script:NS.Probelauf = -not $script:NS.Probelauf
    $script:NS.Config.Allgemein.Probelauf = $script:NS.Probelauf
    Save-NetConfig
    if ($script:NS.Probelauf) { Write-Log -Level OK -Message 'Probelauf ist jetzt AN: es wird nur angezeigt, nichts geaendert.' }
    else { Write-Log -Level OK -Message 'Probelauf ist jetzt AUS: Aenderungen werden nach Bestaetigung ausgefuehrt.' }
}
#
function Switch-NetAutoRepair {
    $neu = -not [bool]$script:NS.Config.Allgemein.AutoReparatur
    $script:NS.Config.Allgemein.AutoReparatur = $neu
    Save-NetConfig
    Write-Log -Level OK -Message ('Automatische Reparatur harmloser Fehler im Doktor: {0}' -f $(if ($neu) { 'AN' } else { 'AUS' }))
}
#
function Switch-NetGridView {
    $neu = -not [bool]$script:NS.Config.Allgemein.GridView
    $script:NS.Config.Allgemein.GridView = $neu
    Save-NetConfig
    Write-Log -Level OK -Message ('Auswahlfenster (Out-GridView): {0}' -f $(if ($neu) { 'AN' } else { 'AUS' }))
    if ($neu -and $script:NS.Umgebung -and -not $script:NS.Umgebung.HatGridView) {
        Write-Log -Level Warn -Message 'Auf diesem Server gibt es keine Auswahlfenster (Server Core). Es wird weiter die Nummernliste verwendet.'
    }
}
#
function Set-NetBackupRetention {
    $aktuell = [int](Get-NetConfigValue -Pfad 'Allgemein.BackupAufbewahrung' -Standard 20)
    $neu = Read-NetNumber -Frage 'Wie viele Backups aufbewahren?' -Minimum 1 -Maximum 500 -Vorschlag $aktuell
    if ($null -eq $neu) { return }
    $script:NS.Config.Allgemein.BackupAufbewahrung = $neu
    Save-NetConfig
    Write-Log -Level OK -Message "Es werden die letzten $neu Backups aufbewahrt."
}
#
function Set-NetSuggestion {
    <#
    .SYNOPSIS
        Vorschlagswerte bearbeiten (Weiterleitungen, Lease-Dauer, Scavenging, Dienstkonto).
    #>
    $v = $script:NS.Config.Vorschlaege
    $text = Read-NetText -Frage 'DNS-Weiterleitungen (mit Komma getrennt)' -Vorschlag ((@($v.Weiterleitungen)) -join ',') -Pruefung {
        param($t)
        foreach ($ip in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $ip.Trim())) { return "'$ip' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if ($null -eq $text) { return }
    $lease = Read-NetNumber -Frage 'Lease-Dauer in Tagen' -Minimum 1 -Maximum 999 -Vorschlag ([int]$v.LeaseTage)
    if ($null -eq $lease) { return }
    $noRefresh = Read-NetNumber -Frage 'Scavenging: No-Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag ([int]$v.NoRefreshTage)
    if ($null -eq $noRefresh) { return }
    $refresh = Read-NetNumber -Frage 'Scavenging: Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag ([int]$v.RefreshTage)
    if ($null -eq $refresh) { return }
    $konto = Read-NetText -Frage 'Name des Dienstkontos fuer DHCP-DNS-Eintraege' -Vorschlag ([string]$v.DnsDienstkonto) -Pruefung {
        param($t)
        if ($t -notmatch '^[A-Za-z0-9._-]{1,20}$') { return 'Erlaubt sind 1 bis 20 Zeichen: Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.' }
        return $null
    }
    if ($null -eq $konto) { return }
    $v.Weiterleitungen = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $v.LeaseTage = $lease
    $v.NoRefreshTage = $noRefresh
    $v.RefreshTage = $refresh
    $v.DnsDienstkonto = $konto
    if (($noRefresh + $refresh) -lt $lease) {
        Write-Log -Level Warn -Message 'No-Refresh + Refresh ist kuerzer als die Lease-Dauer. Dann koennten Eintraege aktiver Clients geloescht werden. Empfehlung: Summe mindestens so lang wie die Lease-Dauer.'
    }
    Save-NetConfig
    Write-Log -Level OK -Message 'Vorschlagswerte gespeichert.'
}
#
function Set-NetDataRoot {
    <#
    .SYNOPSIS
        Datenordner aendern. Konfiguration und Script werden in den neuen Ordner kopiert.
    #>
    $alt = Get-NetPath -Name Root
    $neu = Read-NetText -Frage 'Neuer Datenordner' -Vorschlag $alt -Pruefung {
        param($t)
        if ($t -notmatch '^[A-Za-z]:\\') { return 'Bitte einen lokalen Pfad mit Laufwerk angeben, z. B. D:\NetSetup.' }
        if ($t -match '[<>"|?*]') { return 'Der Pfad enthaelt unerlaubte Zeichen.' }
        return $null
    }
    if (($null -eq $neu) -or ($neu.TrimEnd('\') -eq $alt.TrimEnd('\'))) { return }
    $neu = $neu.TrimEnd('\')
    $r = Invoke-NetChange -Titel 'Datenordner aendern' -Stufe Bestaetigen -Vorher $alt -Nachher $neu -Hinweis 'Logs und Backups bleiben im alten Ordner liegen. Konfiguration und Script werden kopiert.' -Aktion {
        $script:NS.Datenpfad = $neu
        Initialize-NetFolder | Out-Null
        Save-NetConfig
        Set-NetDataRootPointer -Pfad $neu | Out-Null
        Initialize-NetLog
        Save-NetSelf | Out-Null
    }
    if (-not $r.Erfolg -or $r.Probelauf) { $script:NS.Datenpfad = $alt }
}
#
function Show-NetConfig {
    Write-NetTitle -Titel 'Aktuelle Konfiguration'
    Write-Host ('  Datei: {0}' -f (Get-NetPath -Name ConfigDatei)) -ForegroundColor DarkCyan
    $json = $script:NS.Config | ConvertTo-Json -Depth 12
    foreach ($z in ($json -split "`r?`n")) { Write-Host ('  ' + $z) }
    $probleme = Test-NetConfig -Config $script:NS.Config
    if ($probleme.Count -eq 0) { Write-Log -Level OK -Message 'Die Konfiguration ist gueltig.' }
    foreach ($p in $probleme) { Write-Log -Level Warn -Message $p }
}
#
function Show-NetSettingsMenu {
    $kopf = {
        $a = $script:NS.Config.Allgemein
        Write-Host ('  Probelauf            : {0}' -f $(if ($script:NS.Probelauf) { 'AN' } else { 'aus' }))
        Write-Host ('  Auto-Reparatur      : {0}' -f $(if ($a.AutoReparatur) { 'an' } else { 'AUS' }))
        Write-Host ('  Backups aufbewahren : {0}' -f $a.BackupAufbewahrung)
        Write-Host ('  Auswahlfenster      : {0}' -f $(if ($a.GridView) { 'an' } else { 'aus' }))
        Write-Host ('  Datenordner         : {0}' -f (Get-NetPath -Name Root))
        Write-Host ''
    }
    $eintraege = @(
        @{ Text = 'Probelauf an/aus'; Aktion = 'Switch-NetDryRun'; OhnePause = $true; Hilfe = 'Im Probelauf zeigt NetSetup alle geplanten Aenderungen, fuehrt aber nichts aus (wie -WhatIf). Gut zum Ausprobieren.' },
        @{ Text = 'Automatische Reparatur an/aus'; Aktion = 'Switch-NetAutoRepair'; OhnePause = $true; Hilfe = 'Wenn an, repariert der Doktor harmlose Fehler (Stufe Automatisch, z. B. gestoppten Dienst starten) ohne Rueckfrage. Alles andere wird immer gefragt.' },
        @{ Text = 'Anzahl aufbewahrter Backups'; Aktion = 'Set-NetBackupRetention'; Hilfe = 'Aeltere automatische Backups werden geloescht, sobald mehr als diese Anzahl vorhanden ist. Vorschlag: 20.' },
        @{ Text = 'Auswahlfenster (Out-GridView) an/aus'; Aktion = 'Switch-NetGridView'; OhnePause = $true; Hilfe = 'Mit Desktop-Oberflaeche koennen Listen in einem Fenster mit Suche angezeigt werden. Aus = immer Nummernliste in der Konsole.' },
        @{ Text = 'Vorschlagswerte bearbeiten'; Aktion = 'Set-NetSuggestion'; Hilfe = 'Weiterleitungen (Vorschlag 9.9.9.9 und 1.1.1.1), Lease-Dauer (8 Tage), Scavenging (7 + 7 Tage) und Name des Dienstkontos (svc-dhcpdns).' },
        @{ Text = 'Datenordner aendern'; Aktion = 'Set-NetDataRoot'; Hilfe = 'Ort fuer Konfiguration, Logs, Backups, Berichte, Rueckgaengig und Vorlagen. Standard: C:\NetSetup.' },
        @{ Text = 'Konfiguration anzeigen und pruefen'; Aktion = 'Show-NetConfig'; Hilfe = 'Zeigt die gespeicherte Konfiguration (JSON) und prueft sie auf Fehler.' },
        @{ Text = 'Script neu speichern'; Aktion = { Save-NetSelf | Out-Null }; Hilfe = 'Speichert die laufende Version von NetSetup als NetSetup.ps1 in den Datenordner.' },
        @{ Text = 'Desktop-Verknuepfung anlegen'; Aktion = 'New-NetDesktopShortcut'; Hilfe = 'Legt auf dem Desktop eine Verknuepfung "NetSetup" an, die NetSetup als Administrator startet (nur mit Desktop-Oberflaeche).' }
    )
    Show-NetMenu -Titel 'Einstellungen' -Eintraege $eintraege -Kopf $kopf
}
# ----------------------------------------------------------------------
# src/ui/Hauptmenue.ps1
# ----------------------------------------------------------------------
# Hauptmenue mit allen geplanten Punkten. Noch nicht gebaute Punkte erscheinen als "kommt noch".
#
function Get-NetMainMenuEntry {
    return @(
        @{
            Text   = 'Ersteinrichtung (Assistent)'
            Aktion = 'Start-NetFirstSetup'
            Hilfe  = "Fuehrt Schritt fuer Schritt durch die komplette Einrichtung: AD -> DNS -> DHCP -> Verbindung DHCP/DNS -> Test.`nNetSetup erkennt, was schon erledigt ist, und ueberspringt es. Ideal fuer einen neuen Server."
        },
        @{
            Text   = 'Active Directory'
            Aktion = 'Show-NetAdMenu'
            Hilfe  = "Domaene anzeigen, neue Gesamtstruktur erstellen, Domaene beitreten oder zusaetzlicher Domaenencontroller werden.`nMit Vorpruefungen (feste IP, Hostname, DNS, Zeit) und automatischer Fortsetzung nach dem Neustart."
        },
        @{
            Text   = 'DNS'
            Aktion = 'Show-NetDnsMenu'
            Hilfe  = "Zonen, Eintraege (A, AAAA, CNAME, MX, SRV, TXT, PTR), Weiterleitungen, Aufraeumen alter Eintraege (Aging/Scavenging) und Abhoer-Adressen verwalten.`nUeblich: AD-integrierte Zone fuer die Domaene, Reverse-Zone fuer jedes Netz, Weiterleitung an Quad9 oder Cloudflare."
        },
        @{
            Text   = 'DHCP'
            Aktion = 'Show-NetDhcpMenu'
            Hilfe  = "DHCP-Rolle einrichten, autorisieren, Scopes (Adressbereiche) mit Optionen anlegen, Reservierungen, Leases und Failover verwalten.`nUeblich: Lease-Dauer 8 Tage, Router (003), DNS-Server = die DCs (006), Domaene (015)."
        },
        @{
            Text   = 'DHCP + DNS verbinden'
            Aktion = 'Show-NetIntegrationMenu'
            Hilfe  = "Sorgt dafuer, dass jeder DHCP-Client automatisch einen A- und PTR-Eintrag im DNS bekommt und alte Eintraege wieder verschwinden.`nRichtet bei Bedarf ein Dienstkonto (svc-dhcpdns) ein und prueft, ob alle Leases im DNS stehen."
        },
        @{
            Text   = 'Doktor (pruefen und reparieren)'
            Aktion = 'Show-NetDoctorMenu'
            Hilfe  = "Prueft Rechte, Rollen, AD, Netzwerk, DNS und DHCP und zeigt verstaendlich, was falsch ist.`nHarmloses wird automatisch repariert (abschaltbar), alles andere wird einzeln angeboten."
        },
        @{
            Text   = 'Berichte'
            Aktion = 'Show-NetReportMenu'
            Hilfe  = "Erstellt HTML- und CSV-Berichte: Auslastung der Scopes, freie Adressen, Leases ohne DNS-Eintrag, Doktor-Ergebnis, Aenderungsverlauf.`nDie Berichte oeffnen sich ohne Internet."
        },
        @{
            Text   = 'Backup, Wiederherstellen, Rueckgaengig'
            Aktion = 'Show-NetMaintenanceMenu'
            Hilfe  = "Sichert DHCP, DNS und die Konfiguration, stellt sie wieder her, nimmt Aenderungen zurueck, zieht die Konfiguration auf einen anderen Server um und importiert DNS-Eintraege und Reservierungen aus CSV.`nVor jeder Aenderung wird automatisch gesichert."
        },
        @{
            Text   = 'Erweitert'
            Aktion = 'Show-NetAdvancedMenu'
            Hilfe  = "Fortgeschrittene Funktionen, standardmaessig aus: DNSSEC, Split-Brain-DNS, DHCP-Richtlinien, DNS-Sperrliste, DHCPv6.`nNur verwenden, wenn man weiss, wofuer man sie braucht."
        },
        @{
            Text   = 'Hilfe und Glossar'
            Aktion = 'Show-NetHelpMenu'
            Hilfe  = 'Bedienung, Sicherheitsregeln und alle Fachbegriffe in einfachen Worten.'
        },
        @{
            Text   = 'Einstellungen'
            Aktion = 'Show-NetSettingsMenu'
            Hilfe  = "Probelauf an/aus, automatische Reparatur, Anzahl aufbewahrter Backups, Auswahlfenster, Datenordner und Vorschlagswerte.`nAlles wird in Config\netsetup.json gespeichert (ohne Kennwoerter)."
        }
    )
}
#
function Show-NetMainMenu {
    $kopf = {
        $u = $script:NS.Umgebung
        if ($u) {
            $art = 'Desktop'
            if ($u.IstCore) { $art = 'Server Core' }
            Write-Host ('  Server: {0}   Windows: {1} ({2})   NetSetup {3}' -f $u.Computername, $u.OsName, $art, $script:NS.Version) -ForegroundColor DarkCyan
        }
        if (Test-NetCommand -Name 'Show-NetStatusLine') { Show-NetStatusLine }
        Write-Host ''
    }
    Show-NetMenu -Titel 'NetSetup - Hauptmenue' -Eintraege (Get-NetMainMenuEntry) -Kopf $kopf -ZurueckText 'Beenden' -Einleitung $script:NetHilfeAllgemein
    Write-Log -Message 'NetSetup beendet. Das Log liegt im Ordner Logs.'
}
# ----------------------------------------------------------------------
# src/core/Start.ps1
# ----------------------------------------------------------------------
# Einstieg: Argumente lesen, Voraussetzungen pruefen, Datenordner, Log, Config,
# Script speichern, dann Hauptmenue oder eine Aufgabe ohne Menue (-Task).
#
$script:NetTasks = @('Health', 'Report', 'Backup', 'Resume')
#
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
#
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
#
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
#
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
#
        $umgebung = Get-NetEnvironment
        $vor = Test-NetPrerequisite -Umgebung $umgebung
        if ($vor -ne 'OK') { return }
#
        Initialize-NetDataRoot
        Initialize-NetFolder | Out-Null
        Initialize-NetLog
        Start-NetTranscript
        Import-NetConfig | Out-Null
        if ($opt.Probelauf) { $script:NS.Probelauf = $true }
        if ($script:NS.ErsterStart) { Save-NetConfig }
        Write-Log -Level Debug -Message ('Umgebung: ' + (($umgebung.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; '))
        Save-NetSelf | Out-Null
#
        if ($opt.Task) {
            Invoke-NetTask -Name $opt.Task
            return
        }
#
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
# ----------------------------------------------------------------------
Start-NetSetup -Argumente $args
}
& $NetSetupCode @args
