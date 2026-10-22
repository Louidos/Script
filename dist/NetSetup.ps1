<#
    NetSetup 0.0.0 (Build 2026-10-22 21:45)
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
$script:NetSetupBuildDatum = '2026-10-22 21:45'
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
    Zusammenfassung = $null
    AssistentAktiv  = $false
    NeustartGeplant = $false
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
            Modus    = ''
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
    $windows = $env:SystemRoot
    if (-not $windows) { $windows = 'C:\Windows' }
    return (Join-Path -Path $windows -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe')
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
# src/core/Fortsetzung.ps1
# ----------------------------------------------------------------------
# Neustart und Fortsetzung: der Stand wird im Datenordner gespeichert, ein RunOnce-Eintrag
# startet nach der Anmeldung die gespeicherte Datei mit -Task Resume.
# In der Fortsetzungsdatei stehen nie Kennwoerter.
#
$script:NetRunOncePfad = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
#
function Get-NetResumeState {
    $datei = Get-NetPath -Name Fortsetzung
    if (-not (Test-Path -Path $datei)) { return $null }
    try { return (ConvertTo-NetHashtable -Objekt (Get-Content -Path $datei -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)) }
    catch {
        Write-Log -Level Warn -Message 'Die Fortsetzungsdatei ist beschaedigt und wird ignoriert.'
        return $null
    }
}
#
function Save-NetResumeState {
    <#
    .SYNOPSIS
        Merkt den naechsten Schritt nach einem Neustart und traegt NetSetup in RunOnce ein.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Schritt,
        [hashtable]$Daten = @{},
        [string]$Beschreibung = ''
    )
    $stand = @{
        Schritt      = $Schritt
        Daten        = $Daten
        Beschreibung = $Beschreibung
        Zeit         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Assistent    = [bool]$script:NS.AssistentAktiv
        Version      = $script:NS.Version
    }
    $datei = Get-NetPath -Name Fortsetzung
    Set-Content -Path $datei -Value ($stand | ConvertTo-Json -Depth 8) -Encoding UTF8 -ErrorAction Stop
    $scriptDatei = Save-NetSelf
    if (-not $scriptDatei) { $scriptDatei = Get-NetPath -Name Script }
    $befehl = '"{0}" -NoProfile -ExecutionPolicy Bypass -NoExit -File "{1}" -Task Resume' -f (Get-NetPowerShellExe), $scriptDatei
    try {
        if (-not (Test-Path -Path $script:NetRunOncePfad)) { New-Item -Path $script:NetRunOncePfad -Force | Out-Null }
        Set-ItemProperty -Path $script:NetRunOncePfad -Name 'NetSetup' -Value $befehl -ErrorAction Stop
        Write-Log -Level OK -Message ('Fortsetzung nach dem Neustart vorbereitet: ' + $Beschreibung)
    }
    catch {
        Write-Log -Level Warn -Message 'Der automatische Start nach dem Neustart konnte nicht eingetragen werden.'
        Write-Log -Message ('Naechster Schritt: nach dem Neustart NetSetup von Hand starten: ' + $befehl)
    }
}
#
function Clear-NetResumeState {
    $datei = Get-NetPath -Name Fortsetzung
    if (Test-Path -Path $datei) { Remove-Item -Path $datei -Force -ErrorAction SilentlyContinue }
    try { Remove-ItemProperty -Path $script:NetRunOncePfad -Name 'NetSetup' -ErrorAction Stop }
    catch { Write-Log -Level Debug -Message 'Kein RunOnce-Eintrag vorhanden.' }
}
#
function Request-NetRestart {
    <#
    .SYNOPSIS
        Bietet den Neustart an. Die Fortsetzung muss vorher mit Save-NetResumeState gespeichert sein.
    #>
    param([Parameter(Mandatory = $true)][string]$Grund)
    $script:NS.NeustartGeplant = $true
    Write-Host ''
    Write-Log -Level Warn -Message ('Ein Neustart ist noetig: ' + $Grund)
    Write-Log -Message 'Nach der Anmeldung als Administrator startet NetSetup automatisch und macht an der richtigen Stelle weiter.'
    $r = Invoke-NetChange -Titel 'Server jetzt neu starten' -Stufe Bestaetigen -Hinweis 'Alle Verbindungen (auch Remotedesktop) werden getrennt.' -Aktion {
        Stop-NetTranscript
        Restart-Computer -Force
    }
    if (-not $r.Erfolg -or $r.Probelauf) {
        Write-Log -Message 'Kein Neustart. Bitte spaeter neu starten; NetSetup setzt danach automatisch fort.'
    }
}
#
function Resume-NetSetup {
    <#
    .SYNOPSIS
        Wird nach dem Neustart mit -Task Resume gestartet und setzt beim gespeicherten Schritt fort.
    #>
    $stand = Get-NetResumeState
    if (-not $stand) {
        Write-Log -Message 'Es gibt keine unterbrochene Einrichtung. Das Hauptmenue wird geoeffnet.'
    }
    else {
        Write-NetTitle -Titel 'Fortsetzung nach dem Neustart'
        Write-Log -Message ('Gespeicherter Schritt: {0} ({1}, {2})' -f $stand.Schritt, $stand.Beschreibung, $stand.Zeit)
        Invoke-NetResumeStep -Stand $stand
    }
    if (Test-NetCommand -Name 'Show-NetStartOverview') { Show-NetStartOverview }
    if ($stand -and $stand.Assistent -and -not $script:NS.NeustartGeplant -and (Test-NetCommand -Name 'Start-NetFirstSetup')) {
        if (Read-NetYesNo -Frage 'Den Ersteinrichtungs-Assistenten fortsetzen?' -Vorschlag $true) { Start-NetFirstSetup }
    }
    if (-not $script:NS.NeustartGeplant) { Show-NetMainMenu }
}
#
function Invoke-NetResumeStep {
    <#
    .SYNOPSIS
        Fuehrt den gespeicherten Schritt aus. Die Funktion des Schritts heisst Complete-Net<Schritt>.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Stand)
    $funktion = 'Complete-Net' + $Stand.Schritt
    Clear-NetResumeState
    if (-not (Test-NetCommand -Name $funktion)) {
        Write-Log -Level Warn -Message ("Der Schritt '{0}' ist in dieser Version unbekannt. Bitte im Menue von Hand fortfahren." -f $Stand.Schritt)
        return
    }
    $daten = $Stand.Daten
    if ($null -eq $daten) { $daten = @{} }
    $script:NS.AssistentAktiv = [bool]$Stand.Assistent
    try { & $funktion -Daten $daten }
    catch { Write-NetError -Fehler $_ -Titel ('Fortsetzung ' + $Stand.Schritt) | Out-Null }
}
#
function Invoke-NetResumeCheck {
    <#
    .SYNOPSIS
        Beim normalen Start: auf eine unterbrochene Einrichtung hinweisen und Fortsetzung anbieten.
    #>
    $stand = Get-NetResumeState
    if (-not $stand) { return }
    Write-Host ''
    Write-Log -Level Warn -Message ('Es gibt eine unterbrochene Einrichtung: {0} (gespeichert {1}).' -f $stand.Beschreibung, $stand.Zeit)
    if (Read-NetYesNo -Frage 'Jetzt fortsetzen?' -Vorschlag $true) {
        Invoke-NetResumeStep -Stand $stand
    }
    elseif (Read-NetYesNo -Frage 'Die gespeicherte Fortsetzung verwerfen?' -Vorschlag $false) {
        Clear-NetResumeState
        Write-Log -Level OK -Message 'Fortsetzung verworfen.'
    }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Dangerous ist ein Adjektiv, kein Plural; der Name ist vorgegeben.')]
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
# src/inventar/Bestandsaufnahme.ps1
# ----------------------------------------------------------------------
# Bestandsaufnahme: erfasst den kompletten Zustand des Servers.
# NUR LESEND: hier werden ausschliesslich Get-*-Cmdlets, Test-Path und Get-ItemProperty verwendet.
# Fehlende Module oder Rollen fuehren zu "nicht installiert" bzw. "Unbekannt", nie zum Absturz.
#
$script:NetFeatureNamen = @('AD-Domain-Services', 'DNS', 'DHCP', 'RSAT-AD-PowerShell', 'RSAT-ADDS', 'RSAT-DNS-Server', 'RSAT-DHCP')
$script:NetDienstNamen = @('NTDS', 'Netlogon', 'DNS', 'DHCPServer', 'W32Time')
$script:NetDomainRoleText = @{
    0 = 'Eigenstaendige Arbeitsstation'
    1 = 'Mitglied-Arbeitsstation'
    2 = 'Eigenstaendiger Server (Arbeitsgruppe)'
    3 = 'Mitgliedsserver einer Domaene'
    4 = 'Domaenencontroller'
    5 = 'Domaenencontroller (PDC-Emulator)'
}
#
function ConvertTo-NetString {
    <#
    .SYNOPSIS
        Wandelt IP-Objekte, Enums und Listen sicher in Text bzw. Textlisten um.
    #>
    param([AllowNull()][object]$Wert)
    if ($null -eq $Wert) { return '' }
    if ($Wert -is [System.Net.IPAddress]) { return $Wert.IPAddressToString }
    return [string]$Wert
}
#
function Get-NetSystemState {
    $cs = Get-NetSafe -Beschreibung 'Win32_ComputerSystem' -Abfrage { Get-CimInstance -ClassName Win32_ComputerSystem }
    $os = Get-NetSafe -Beschreibung 'Win32_OperatingSystem' -Abfrage { Get-CimInstance -ClassName Win32_OperatingSystem }
    $installationsTyp = Get-NetSafe -Beschreibung 'InstallationType' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType).InstallationType }
    $edition = Get-NetSafe -Beschreibung 'EditionID' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID }
    $rolle = -1
    if ($cs) { $rolle = [int]$cs.DomainRole }
    $rolleText = 'Unbekannt'
    if ($script:NetDomainRoleText.ContainsKey($rolle)) { $rolleText = $script:NetDomainRoleText[$rolle] }
    $hostname = [Environment]::MachineName
    if ($cs -and $cs.Name) { $hostname = [string]$cs.Name }
    return @{
        Hostname     = $hostname
        OsName       = $(if ($os) { [string]$os.Caption } else { 'Unbekannt' })
        OsVersion    = $(if ($os) { [string]$os.Version } else { '' })
        Build        = $(if ($os) { [string]$os.BuildNumber } else { '' })
        ProductType  = $(if ($os) { [int]$os.ProductType } else { 0 })
        Edition      = [string]$edition
        IstCore      = ([string]$installationsTyp -eq 'Server Core')
        Sprache      = (Get-Culture).Name
        UiSprache    = (Get-UICulture).Name
        OsSprache    = $(if ($os) { [int]$os.OSLanguage } else { 0 })
        DomainRole   = $rolle
        RolleText    = $rolleText
        IstDC        = ($rolle -ge 4)
        IstPdc       = ($rolle -eq 5)
        IstMitglied  = ($rolle -eq 1 -or $rolle -eq 3)
        IstArbeitsgruppe = ($rolle -eq 0 -or $rolle -eq 2)
        Domaene      = $(if ($cs -and $cs.PartOfDomain) { [string]$cs.Domain } else { '' })
        Arbeitsgruppe = $(if ($cs -and -not $cs.PartOfDomain) { [string]$cs.Domain } else { '' })
        IstAdmin     = (Test-NetIsAdmin)
    }
}
#
function Get-NetAdState {
    param([Parameter(Mandatory = $true)][hashtable]$System)
    $ad = @{ Verfuegbar = $false; Domaene = ''; NetBios = ''; Gesamtstruktur = ''; DomainMode = ''; ForestMode = ''; Pdc = ''; ModulFehlt = $false }
    if (-not ($System.IstDC -or $System.IstMitglied)) { return $ad }
    if (-not (Test-NetCommand -Name 'Get-ADDomain')) {
        $ad.ModulFehlt = $true
        $ad.Domaene = $System.Domaene
        return $ad
    }
    $domaene = Get-NetSafe -Beschreibung 'Get-ADDomain' -Abfrage { Get-ADDomain }
    $forest = Get-NetSafe -Beschreibung 'Get-ADForest' -Abfrage { Get-ADForest }
    if ($domaene) {
        $ad.Verfuegbar = $true
        $ad.Domaene = [string]$domaene.DNSRoot
        $ad.NetBios = [string]$domaene.NetBIOSName
        $ad.DomainMode = [string]$domaene.DomainMode
        $ad.Pdc = [string]$domaene.PDCEmulator
    }
    else { $ad.Domaene = $System.Domaene }
    if ($forest) {
        $ad.Gesamtstruktur = [string]$forest.Name
        $ad.ForestMode = [string]$forest.ForestMode
    }
    return $ad
}
#
function Get-NetFeatureState {
    <#
    .SYNOPSIS
        Liefert pro Windows-Funktion den InstallState (Installed, Available, Removed, InstallPending, Unbekannt).
    #>
    $ergebnis = @{}
    foreach ($n in $script:NetFeatureNamen) { $ergebnis[$n] = 'Unbekannt' }
    if (-not (Test-NetCommand -Name 'Get-WindowsFeature')) { return $ergebnis }
    $features = Get-NetSafe -Beschreibung 'Get-WindowsFeature' -Abfrage { Get-WindowsFeature -Name $script:NetFeatureNamen }
    foreach ($f in @($features)) {
        if ($f -and $f.Name) { $ergebnis[[string]$f.Name] = [string]$f.InstallState }
    }
    return $ergebnis
}
#
function Get-NetServiceState {
    $ergebnis = @{}
    foreach ($n in $script:NetDienstNamen) {
        $dienst = Get-NetSafe -Beschreibung "Dienst $n" -Abfrage { Get-Service -Name $n }
        if ($dienst) {
            $ergebnis[$n] = @{ Vorhanden = $true; Status = [string]$dienst.Status; StartTyp = [string]$dienst.StartType }
        }
        else {
            $ergebnis[$n] = @{ Vorhanden = $false; Status = 'Fehlt'; StartTyp = '' }
        }
    }
    return $ergebnis
}
#
function Get-NetPendingReboot {
    <#
    .SYNOPSIS
        Prueft, ob ein Neustart aussteht (CBS, Windows Update, PendingFileRenameOperations, Umbenennung).
    #>
    $gruende = @()
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $gruende += 'Windows-Komponenten (CBS)' }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $gruende += 'Windows Update' }
    $pfro = Get-NetSafe -Beschreibung 'PendingFileRenameOperations' -Abfrage {
        (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations).PendingFileRenameOperations
    }
    if ($pfro) { $gruende += 'Dateien warten auf Austausch (PendingFileRenameOperations)' }
    $aktiv = Get-NetSafe -Beschreibung 'ActiveComputerName' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName).ComputerName }
    $neu = Get-NetSafe -Beschreibung 'ComputerName' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName).ComputerName }
    if ($aktiv -and $neu -and ($aktiv -ne $neu)) { $gruende += "Umbenennung in $neu" }
    return @{ Ausstehend = ($gruende.Count -gt 0); Gruende = $gruende }
}
#
function Get-NetNetworkState {
    $karten = @()
    $adapter = @(Get-NetSafe -Beschreibung 'Get-NetAdapter' -Standard @() -Abfrage { Get-NetAdapter })
    foreach ($a in $adapter) {
        if ($null -eq $a) { continue }
        $index = [int]$a.ifIndex
        $ipif = Get-NetSafe -Beschreibung 'Get-NetIPInterface' -Abfrage { Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 }
        $ips = @(Get-NetSafe -Beschreibung 'Get-NetIPAddress' -Standard @() -Abfrage { Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 })
        $routen = @(Get-NetSafe -Beschreibung 'Get-NetRoute' -Standard @() -Abfrage { Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' })
        $dns = Get-NetSafe -Beschreibung 'Get-DnsClientServerAddress' -Abfrage { Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 }
        $adressen = @()
        foreach ($ip in $ips) {
            if ($null -eq $ip -or -not $ip.IPAddress) { continue }
            $adressen += @{ IP = [string]$ip.IPAddress; Prefix = [int]$ip.PrefixLength; Herkunft = [string]$ip.PrefixOrigin }
        }
        $karten += @{
            Index        = $index
            Name         = [string]$a.Name
            Beschreibung = [string]$a.InterfaceDescription
            Mac          = [string]$a.MacAddress
            Status       = [string]$a.Status
            Dhcp         = ($ipif -and ([string]$ipif.Dhcp -eq 'Enabled'))
            Adressen     = $adressen
            Gateway      = @($routen | Where-Object { $_ } | ForEach-Object { [string]$_.NextHop })
            DnsServer    = $(if ($dns) { @($dns.ServerAddresses | ForEach-Object { [string]$_ }) } else { @() })
        }
    }
    $aktiv = @($karten | Where-Object { $_.Status -eq 'Up' -and $_.Adressen.Count -gt 0 })
    return @{
        Karten         = $karten
        AktiveKarten   = $aktiv
        MehrereKarten  = ($aktiv.Count -gt 1)
        EigeneIPs      = @($aktiv | ForEach-Object { $_.Adressen } | Where-Object { $_.IP -notlike '169.254.*' } | ForEach-Object { $_.IP })
    }
}
#
function Get-NetDnsState {
    param([hashtable]$Features, [hashtable]$Dienste)
    $dns = @{
        Installiert     = ($Features['DNS'] -eq 'Installed')
        Tools           = (Test-NetCommand -Name 'Get-DnsServerZone')
        Laeuft          = ($Dienste['DNS'] -and $Dienste['DNS'].Status -eq 'Running')
        Verfuegbar      = $false
        Zonen           = @()
        Weiterleitungen = @()
        Scavenging      = $null
        AbhoerIPs       = @()
    }
    if (-not ($dns.Tools -and $Dienste['DNS'] -and $Dienste['DNS'].Vorhanden)) { return $dns }
    $zonen = Get-NetSafe -Beschreibung 'Get-DnsServerZone' -Abfrage { Get-DnsServerZone }
    if ($null -eq $zonen) { return $dns }
    $dns.Verfuegbar = $true
    foreach ($z in @($zonen)) {
        if ($null -eq $z) { continue }
        $name = [string]$z.ZoneName
        if ($name -eq 'TrustAnchors' -or $z.IsAutoCreated) { continue }
        $aging = $null
        if ([string]$z.ZoneType -eq 'Primary') {
            $alter = Get-NetSafe -Beschreibung "Get-DnsServerZoneAging $name" -Abfrage { Get-DnsServerZoneAging -Name $name }
            if ($alter) { $aging = @{ Aktiv = [bool]$alter.AgingEnabled; NoRefresh = [string]$alter.NoRefreshInterval; Refresh = [string]$alter.RefreshInterval } }
        }
        $dns.Zonen += @{
            Name          = $name
            Typ           = [string]$z.ZoneType
            AdIntegriert  = [bool]$z.IsDsIntegrated
            Reverse       = [bool]$z.IsReverseLookupZone
            DynUpdate     = [string]$z.DynamicUpdate
            Replikation   = [string]$z.ReplicationScope
            Signiert      = [bool]$z.IsSigned
            Aging         = $aging
        }
    }
    $fw = Get-NetSafe -Beschreibung 'Get-DnsServerForwarder' -Abfrage { Get-DnsServerForwarder }
    if ($fw) { $dns.Weiterleitungen = @($fw.IPAddress | Where-Object { $_ } | ForEach-Object { ConvertTo-NetString -Wert $_ }) }
    $sc = Get-NetSafe -Beschreibung 'Get-DnsServerScavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc) {
        $dns.Scavenging = @{
            Aktiv     = [bool]$sc.ScavengingState
            Intervall = [string]$sc.ScavengingInterval
            NoRefresh = [string]$sc.NoRefreshInterval
            Refresh   = [string]$sc.RefreshInterval
        }
    }
    $einst = Get-NetSafe -Beschreibung 'Get-DnsServerSetting' -Abfrage { Get-DnsServerSetting -All }
    if ($einst -and $einst.ListeningIPAddress) { $dns.AbhoerIPs = @($einst.ListeningIPAddress | ForEach-Object { ConvertTo-NetString -Wert $_ }) }
    return $dns
}
#
function Get-NetDhcpScopeState {
    param([Parameter(Mandatory = $true)][object]$Scope)
    $id = ConvertTo-NetString -Wert $Scope.ScopeId
    $optionen = @{}
    foreach ($o in @(Get-NetSafe -Beschreibung "Optionen $id" -Standard @() -Abfrage { Get-DhcpServerv4OptionValue -ScopeId $id })) {
        if ($o) { $optionen[[string][int]$o.OptionId] = @($o.Value | ForEach-Object { [string]$_ }) }
    }
    $ausschluesse = @()
    foreach ($a in @(Get-NetSafe -Beschreibung "Ausschluesse $id" -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id })) {
        if ($a) { $ausschluesse += @{ Start = (ConvertTo-NetString -Wert $a.StartRange); Ende = (ConvertTo-NetString -Wert $a.EndRange) } }
    }
    $reservierungen = @()
    foreach ($r in @(Get-NetSafe -Beschreibung "Reservierungen $id" -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })) {
        if ($r) { $reservierungen += @{ IP = (ConvertTo-NetString -Wert $r.IPAddress); ClientId = [string]$r.ClientId; Name = [string]$r.Name; Beschreibung = [string]$r.Description } }
    }
    $stat = Get-NetSafe -Beschreibung "Statistik $id" -Abfrage { Get-DhcpServerv4ScopeStatistics -ScopeId $id }
    $dnsSetting = Get-NetSafe -Beschreibung "DNS-Einstellung $id" -Abfrage { Get-DhcpServerv4DnsSetting -ScopeId $id }
    $maske = ConvertTo-NetString -Wert $Scope.SubnetMask
    return @{
        ScopeId        = $id
        Name           = [string]$Scope.Name
        Start          = (ConvertTo-NetString -Wert $Scope.StartRange)
        Ende           = (ConvertTo-NetString -Wert $Scope.EndRange)
        Maske          = $maske
        Prefix         = (ConvertTo-NetPrefixLength -SubnetMask $maske)
        Status         = [string]$Scope.State
        Aktiv          = ([string]$Scope.State -eq 'Active')
        LeaseDauer     = [string]$Scope.LeaseDuration
        LeaseTage      = $(if ($Scope.LeaseDuration -is [TimeSpan]) { [double]$Scope.LeaseDuration.TotalDays } else { 0 })
        Superscope     = [string]$Scope.SuperscopeName
        Optionen       = $optionen
        Ausschluesse   = $ausschluesse
        Reservierungen = $reservierungen
        Auslastung     = $(if ($stat) { [double]$stat.PercentageInUse } else { -1 })
        Frei           = $(if ($stat) { [int]$stat.Free } else { -1 })
        Belegt         = $(if ($stat) { [int]$stat.InUse } else { -1 })
        DnsEinstellung = (ConvertTo-NetDhcpDnsSetting -Einstellung $dnsSetting)
    }
}
#
function ConvertTo-NetDhcpDnsSetting {
    param([AllowNull()][object]$Einstellung)
    if ($null -eq $Einstellung) { return $null }
    return @{
        DynamicUpdates             = [string]$Einstellung.DynamicUpdates
        DeleteDnsRROnLeaseExpiry   = [bool]$Einstellung.DeleteDnsRROnLeaseExpiry
        UpdateDnsRRForOlderClients = [bool]$Einstellung.UpdateDnsRRForOlderClients
        NameProtection             = [bool]$Einstellung.NameProtection
        DisableDnsPtrRRUpdate      = [bool]$Einstellung.DisableDnsPtrRRUpdate
    }
}
#
function Get-NetDhcpState {
    param([hashtable]$Features, [hashtable]$Dienste)
    $dhcp = @{
        Installiert      = ($Features['DHCP'] -eq 'Installed')
        Tools            = (Test-NetCommand -Name 'Get-DhcpServerv4Scope')
        Laeuft           = ($Dienste['DHCPServer'] -and $Dienste['DHCPServer'].Status -eq 'Running')
        Verfuegbar       = $false
        Nachkonfiguriert = $false
        Autorisiert      = $null
        InDomaene        = $false
        Bindungen        = @()
        Scopes           = @()
        ServerOptionen   = @{}
        Failover         = @()
        DnsEinstellung   = $null
        DnsZugangsdaten  = @{ Gesetzt = $false; Benutzer = ''; Domaene = '' }
        KonfliktErkennung = 0
    }
    $status = Get-NetSafe -Beschreibung 'DHCP ConfigurationState' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState).ConfigurationState }
    $dhcp.Nachkonfiguriert = ([int]$status -eq 2)
    if (-not ($dhcp.Tools -and $Dienste['DHCPServer'] -and $Dienste['DHCPServer'].Vorhanden)) { return $dhcp }
    $einst = Get-NetSafe -Beschreibung 'Get-DhcpServerSetting' -Abfrage { Get-DhcpServerSetting }
    if ($null -eq $einst) { return $dhcp }
    $dhcp.Verfuegbar = $true
    $dhcp.Autorisiert = [bool]$einst.IsAuthorized
    $dhcp.InDomaene = [bool]$einst.IsDomainJoined
    $dhcp.KonfliktErkennung = [int]$einst.ConflictDetectionAttempts
    foreach ($b in @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Binding' -Standard @() -Abfrage { Get-DhcpServerv4Binding })) {
        if ($b) { $dhcp.Bindungen += @{ Karte = [string]$b.InterfaceAlias; IP = (ConvertTo-NetString -Wert $b.IPAddress); Aktiv = [bool]$b.BindingState } }
    }
    foreach ($s in @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Scope' -Standard @() -Abfrage { Get-DhcpServerv4Scope })) {
        if ($s) { $dhcp.Scopes += (Get-NetDhcpScopeState -Scope $s) }
    }
    foreach ($o in @(Get-NetSafe -Beschreibung 'Serveroptionen' -Standard @() -Abfrage { Get-DhcpServerv4OptionValue })) {
        if ($o) { $dhcp.ServerOptionen[[string][int]$o.OptionId] = @($o.Value | ForEach-Object { [string]$_ }) }
    }
    foreach ($f in @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover })) {
        if ($f) {
            $dhcp.Failover += @{
                Name    = [string]$f.Name
                Partner = [string]$f.PartnerServer
                Modus   = [string]$f.Mode
                Status  = [string]$f.State
                Scopes  = @($f.ScopeId | ForEach-Object { ConvertTo-NetString -Wert $_ })
            }
        }
    }
    $dhcp.DnsEinstellung = ConvertTo-NetDhcpDnsSetting -Einstellung (Get-NetSafe -Beschreibung 'DHCP DNS-Einstellung' -Abfrage { Get-DhcpServerv4DnsSetting })
    $cred = Get-NetSafe -Beschreibung 'Get-DhcpServerDnsCredential' -Abfrage { Get-DhcpServerDnsCredential }
    if ($cred -and $cred.UserName) {
        $dhcp.DnsZugangsdaten = @{ Gesetzt = $true; Benutzer = [string]$cred.UserName; Domaene = [string]$cred.DomainName }
    }
    return $dhcp
}
#
function Get-NetTimeState {
    $param = Get-NetSafe -Beschreibung 'W32Time Parameter' -Abfrage { Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' }
    $typ = ''
    $ntp = ''
    if ($param) { $typ = [string]$param.Type; $ntp = [string]$param.NtpServer }
    return @{ Typ = $typ; NtpServer = $ntp }
}
#
function Get-NetSetupState {
    <#
    .SYNOPSIS
        Erfasst den kompletten Zustand des Servers (nur lesend) und merkt ihn in $script:NS.Zustand.
    #>
    $system = Get-NetSystemState
    $features = Get-NetFeatureState
    $dienste = Get-NetServiceState
    $zustand = @{
        Zeitpunkt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        System    = $system
        AD        = (Get-NetAdState -System $system)
        Features  = $features
        Dienste   = $dienste
        Neustart  = (Get-NetPendingReboot)
        Netzwerk  = (Get-NetNetworkState)
        Dns       = (Get-NetDnsState -Features $features -Dienste $dienste)
        Dhcp      = (Get-NetDhcpState -Features $features -Dienste $dienste)
        Zeit      = (Get-NetTimeState)
    }
    $script:NS.Zustand = $zustand
    return $zustand
}
#
function Get-NetDomainName {
    <#
    .SYNOPSIS
        Liefert den DNS-Namen der Domaene aus dem Zustand (oder aus der Config).
    #>
    param([hashtable]$Zustand = $script:NS.Zustand)
    if ($Zustand -and $Zustand.AD -and $Zustand.AD.Domaene) { return [string]$Zustand.AD.Domaene }
    if ($Zustand -and $Zustand.System -and $Zustand.System.Domaene) { return [string]$Zustand.System.Domaene }
    return [string](Get-NetConfigValue -Pfad 'AD.Domaene' -Standard '')
}
# ----------------------------------------------------------------------
# src/inventar/Uebersicht.ps1
# ----------------------------------------------------------------------
# Statusuebersicht: eine Zeile pro Bereich mit [OK], [WARN], [FEHLER] oder [--].
#
function New-NetSummaryLine {
    param([string]$Bereich, [ValidateSet('OK', 'WARN', 'FEHLER', 'NA', 'INFO')][string]$Status, [string]$Text)
    return [pscustomobject]@{ Bereich = $Bereich; Status = $Status; Text = $Text }
}
#
function Get-NetStateSummary {
    <#
    .SYNOPSIS
        Bewertet die Bestandsaufnahme pro Bereich (System, Neustart, AD, Netzwerk, DNS, DHCP, DHCP+DNS, Zeit).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Zustand)
    $zeilen = @()
    $s = $Zustand.System
#
    # System
    $art = 'Desktop'
    if ($s.IstCore) { $art = 'Server Core' }
    if (-not $s.IstAdmin) { $zeilen += New-NetSummaryLine -Bereich 'System' -Status 'WARN' -Text ('{0} ({1}) - ohne Administratorrechte' -f $s.OsName, $art) }
    else { $zeilen += New-NetSummaryLine -Bereich 'System' -Status 'OK' -Text ('{0} ({1}), Sprache {2}' -f $s.OsName, $art, $s.UiSprache) }
#
    # Neustart
    if ($Zustand.Neustart.Ausstehend) { $zeilen += New-NetSummaryLine -Bereich 'Neustart' -Status 'WARN' -Text ('Neustart ausstehend: ' + ($Zustand.Neustart.Gruende -join ', ')) }
    else { $zeilen += New-NetSummaryLine -Bereich 'Neustart' -Status 'OK' -Text 'kein Neustart ausstehend' }
#
    # Active Directory
    $adFeature = $Zustand.Features['AD-Domain-Services']
    if ($s.IstDC) {
        $ntds = $Zustand.Dienste['NTDS']
        if ($ntds -and $ntds.Vorhanden -and $ntds.Status -ne 'Running') { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'FEHLER' -Text ('Domaenencontroller, aber der Dienst NTDS laeuft nicht ({0})' -f $ntds.Status) }
        elseif ($Zustand.AD.ModulFehlt) { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'WARN' -Text ('Domaenencontroller fuer {0}, AD-Verwaltungstools fehlen (RSAT-AD-PowerShell)' -f $Zustand.AD.Domaene) }
        else { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'OK' -Text ('Domaenencontroller fuer {0} ({1})' -f $Zustand.AD.Domaene, $Zustand.AD.NetBios) }
    }
    elseif ($s.IstMitglied) {
        $text = 'Mitgliedsserver der Domaene ' + $s.Domaene
        if ($adFeature -eq 'Installed') { $text += ', Rolle AD DS installiert aber nicht heraufgestuft' }
        $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status $(if ($adFeature -eq 'Installed') { 'WARN' } else { 'INFO' }) -Text $text
    }
    elseif ($s.IstArbeitsgruppe) {
        $modus = Get-NetConfigValue -Pfad 'AD.Modus' -Standard ''
        if ($adFeature -eq 'Installed') { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'WARN' -Text 'Rolle AD DS installiert, aber der Server ist noch kein Domaenencontroller' }
        elseif ($modus -eq 'OhneAD') { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'NA' -Text 'bewusst ohne AD (Arbeitsgruppe)' }
        else { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'NA' -Text ('kein AD - Arbeitsgruppe {0}' -f $s.Arbeitsgruppe) }
    }
    else { $zeilen += New-NetSummaryLine -Bereich 'Active Directory' -Status 'WARN' -Text 'Rolle des Servers unbekannt' }
#
    # Netzwerk
    $n = $Zustand.Netzwerk
    if ($n.AktiveKarten.Count -eq 0) {
        $zeilen += New-NetSummaryLine -Bereich 'Netzwerk' -Status 'FEHLER' -Text 'keine aktive Netzwerkkarte mit IPv4-Adresse gefunden'
    }
    else {
        $k = $n.AktiveKarten[0]
        $ip = ($k.Adressen | Select-Object -First 1)
        $text = '{0}: {1}/{2}' -f $k.Name, $ip.IP, $ip.Prefix
        if ($k.Gateway.Count -gt 0) { $text += ', Gateway ' + $k.Gateway[0] }
        if ($k.DnsServer.Count -gt 0) { $text += ', DNS ' + ($k.DnsServer -join ' ') }
        $probleme = @()
        if (@($n.AktiveKarten | Where-Object { $_.Dhcp }).Count -gt 0) { $probleme += 'IP per DHCP (Server brauchen eine feste IP)' }
        if ($n.MehrereKarten) { $probleme += ('{0} aktive Netzwerkkarten' -f $n.AktiveKarten.Count) }
        if ($s.IstDC -and $k.DnsServer.Count -gt 0) {
            $eigene = @($n.EigeneIPs) + @('127.0.0.1')
            if (@($k.DnsServer | Where-Object { $eigene -contains $_ }).Count -eq 0) { $probleme += 'DC fragt nicht sich selbst als DNS' }
        }
        if ($probleme.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'Netzwerk' -Status 'WARN' -Text ($text + ' - ' + ($probleme -join ', ')) }
        else { $zeilen += New-NetSummaryLine -Bereich 'Netzwerk' -Status 'OK' -Text ($text + ', feste IP') }
    }
#
    # DNS
    $d = $Zustand.Dns
    $dnsFeature = $Zustand.Features['DNS']
    if (-not $d.Installiert -and -not ($Zustand.Dienste['DNS'] -and $Zustand.Dienste['DNS'].Vorhanden)) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'NA' -Text ('nicht installiert ({0})' -f (ConvertTo-NetFeatureText -Status $dnsFeature))
    }
    elseif (-not $d.Laeuft) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'FEHLER' -Text 'installiert, aber der DNS-Dienst laeuft nicht'
    }
    elseif (-not $d.Tools) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'WARN' -Text 'Dienst laeuft, Verwaltungstools fehlen (RSAT-DNS-Server)'
    }
    elseif (-not $d.Verfuegbar) {
        $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'WARN' -Text 'Zustand unbekannt (Abfrage fehlgeschlagen, Details im Log)'
    }
    else {
        $forward = @($d.Zonen | Where-Object { -not $_.Reverse })
        $reverse = @($d.Zonen | Where-Object { $_.Reverse })
        $text = '{0} Zone(n), {1} Reverse-Zone(n)' -f $forward.Count, $reverse.Count
        if ($d.Weiterleitungen.Count -gt 0) { $text += ', Weiterleitung ' + ($d.Weiterleitungen -join ' ') }
        else { $text += ', keine Weiterleitung' }
        $warn = @()
        if ($forward.Count -eq 0) { $warn += 'keine Zone' }
        if ($reverse.Count -eq 0) { $warn += 'keine Reverse-Zone' }
        if ($warn.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'WARN' -Text ($text + ' - ' + ($warn -join ', ')) }
        else { $zeilen += New-NetSummaryLine -Bereich 'DNS' -Status 'OK' -Text $text }
    }
#
    # DHCP
    $h = $Zustand.Dhcp
    if (-not $h.Installiert -and -not ($Zustand.Dienste['DHCPServer'] -and $Zustand.Dienste['DHCPServer'].Vorhanden)) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'NA' -Text ('nicht installiert ({0})' -f (ConvertTo-NetFeatureText -Status $Zustand.Features['DHCP']))
    }
    elseif (-not $h.Laeuft) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'FEHLER' -Text 'installiert, aber der DHCP-Dienst laeuft nicht'
    }
    elseif (-not $h.Tools) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'WARN' -Text 'Dienst laeuft, Verwaltungstools fehlen (RSAT-DHCP)'
    }
    elseif (-not $h.Verfuegbar) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'WARN' -Text 'Zustand unbekannt (Abfrage fehlgeschlagen, Details im Log)'
    }
    else {
        $aktiv = @($h.Scopes | Where-Object { $_.Aktiv })
        $text = '{0} Scope(s), davon {1} aktiv' -f $h.Scopes.Count, $aktiv.Count
        $warn = @()
        $fehler = @()
        if (-not $h.Nachkonfiguriert) { $warn += 'Nachkonfiguration fehlt' }
        if ($h.InDomaene -and -not $h.Autorisiert) { $fehler += 'nicht im AD autorisiert' }
        if ($h.Scopes.Count -eq 0) { $warn += 'kein Scope' }
        $grenze = [int](Get-NetConfigValue -Pfad 'Vorschlaege.AuslastungWarnung' -Standard 80)
        foreach ($sc in $aktiv) {
            if ($sc.Auslastung -ge $grenze) { $warn += ('{0} zu {1:N0}% belegt' -f $sc.ScopeId, $sc.Auslastung) }
        }
        if ($fehler.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'FEHLER' -Text ($text + ' - ' + (($fehler + $warn) -join ', ')) }
        elseif ($warn.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'WARN' -Text ($text + ' - ' + ($warn -join ', ')) }
        else { $zeilen += New-NetSummaryLine -Bereich 'DHCP' -Status 'OK' -Text $text }
    }
#
    # DHCP + DNS
    if (-not $h.Verfuegbar) {
        $zeilen += New-NetSummaryLine -Bereich 'DHCP + DNS' -Status 'NA' -Text 'kein DHCP-Server auf diesem Server'
    }
    else {
        $warn = @()
        $e = $h.DnsEinstellung
        if (-not $e -or $e.DynamicUpdates -ne 'Always') { $warn += 'DNS-Eintraege nicht fuer alle Clients' }
        if (-not $e -or -not $e.DeleteDnsRROnLeaseExpiry) { $warn += 'alte Eintraege werden nicht entfernt' }
        if ($s.IstDC -and -not $h.DnsZugangsdaten.Gesetzt) { $warn += 'DHCP auf DC ohne DNS-Zugangsdaten' }
        if ($warn.Count -gt 0) { $zeilen += New-NetSummaryLine -Bereich 'DHCP + DNS' -Status 'WARN' -Text ($warn -join ', ') }
        else { $zeilen += New-NetSummaryLine -Bereich 'DHCP + DNS' -Status 'OK' -Text ('Clients werden automatisch eingetragen (Konto {0})' -f $(if ($h.DnsZugangsdaten.Gesetzt) { $h.DnsZugangsdaten.Benutzer } else { 'Computerkonto' })) }
    }
#
    # Zeit
    $t = $Zustand.Zeit
    if (-not $t.Typ) { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'WARN' -Text 'Zeitdienst-Einstellung nicht lesbar' }
    elseif ($s.IstPdc -and $t.Typ -ne 'NTP') { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'WARN' -Text ('PDC-Emulator ohne externe Zeitquelle (Typ {0})' -f $t.Typ) }
    elseif ($s.IstPdc) { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'OK' -Text ('PDC holt die Zeit von {0}' -f $t.NtpServer) }
    elseif (($s.IstMitglied -or $s.IstDC) -and $t.Typ -ne 'NT5DS') { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'WARN' -Text ('Domaenenmitglied, folgt aber nicht der Domaenenhierarchie (Typ {0})' -f $t.Typ) }
    else { $zeilen += New-NetSummaryLine -Bereich 'Zeit' -Status 'OK' -Text ('Zeitquelle: {0} {1}' -f $t.Typ, $t.NtpServer).Trim() }
#
    return $zeilen
}
#
function ConvertTo-NetFeatureText {
    param([string]$Status)
    switch ($Status) {
        'Installed' { return 'installiert' }
        'Available' { return 'verfuegbar' }
        'Removed' { return 'Dateien entfernt' }
        'InstallPending' { return 'Installation wartet auf Neustart' }
        'UninstallPending' { return 'Deinstallation wartet auf Neustart' }
        default { return 'unbekannt' }
    }
}
#
function Show-NetStartOverview {
    <#
    .SYNOPSIS
        Bestandsaufnahme beim Start mit einer Zeile pro Bereich.
    #>
    Write-Log -Message 'Bestandsaufnahme laeuft (nur lesend) ...'
    $zustand = Get-NetSetupState
    $zeilen = Get-NetStateSummary -Zustand $zustand
    $script:NS.Zusammenfassung = $zeilen
    Write-NetTitle -Titel ('Bestandsaufnahme {0} ({1})' -f $zustand.System.Hostname, $zustand.System.RolleText)
    foreach ($z in $zeilen) { Write-NetStatus -Status $z.Status -Bereich $z.Bereich -Text $z.Text }
    $probleme = @($zeilen | Where-Object { $_.Status -eq 'FEHLER' -or $_.Status -eq 'WARN' })
    if ($probleme.Count -gt 0) {
        Write-Host ''
        Write-Log -Message 'Tipp: Der Doktor im Hauptmenue erklaert und repariert die markierten Punkte.'
    }
}
#
function Show-NetStatusLine {
    <#
    .SYNOPSIS
        Kurze Statuszeile fuer den Kopf des Hauptmenues (aus der letzten Bestandsaufnahme).
    #>
    $zeilen = $script:NS.Zusammenfassung
    if (-not $zeilen) { return }
    $teile = @()
    foreach ($z in $zeilen) {
        if (@('Active Directory', 'DNS', 'DHCP', 'DHCP + DNS', 'Netzwerk') -notcontains $z.Bereich) { continue }
        $marke = @{ OK = 'OK'; WARN = 'WARN'; FEHLER = 'FEHLER'; NA = '--'; INFO = 'i' }[$z.Status]
        $teile += ('{0} [{1}]' -f $z.Bereich, $marke)
    }
    Write-Host ('  Status: ' + ($teile -join '  ')) -ForegroundColor DarkCyan
}
#
function Show-NetStateDetail {
    <#
    .SYNOPSIS
        Zeigt die komplette Bestandsaufnahme ausfuehrlich an.
    #>
    $z = Get-NetSetupState
    $script:NS.Zusammenfassung = Get-NetStateSummary -Zustand $z
    Write-NetTitle -Titel 'Bestandsaufnahme im Detail'
    Write-Host ('  Server       : {0} - {1}' -f $z.System.Hostname, $z.System.RolleText)
    Write-Host ('  Windows      : {0} {1} Build {2}, {3}' -f $z.System.OsName, $z.System.Edition, $z.System.Build, $(if ($z.System.IstCore) { 'Server Core' } else { 'Desktop' }))
    Write-Host ('  Sprache      : {0} / Oberflaeche {1}' -f $z.System.Sprache, $z.System.UiSprache)
    if ($z.AD.Domaene) { Write-Host ('  Domaene      : {0} (NetBIOS {1}), Gesamtstruktur {2}, Ebene {3}' -f $z.AD.Domaene, $z.AD.NetBios, $z.AD.Gesamtstruktur, $z.AD.DomainMode) }
    Write-Host '  Funktionen   :'
    foreach ($f in ($z.Features.Keys | Sort-Object)) { Write-Host ('    {0,-22} {1}' -f $f, (ConvertTo-NetFeatureText -Status $z.Features[$f])) }
    Write-Host '  Dienste      :'
    foreach ($d in ($z.Dienste.Keys | Sort-Object)) {
        $x = $z.Dienste[$d]
        if ($x.Vorhanden) { Write-Host ('    {0,-22} {1} (Start: {2})' -f $d, $x.Status, $x.StartTyp) }
        else { Write-Host ('    {0,-22} nicht vorhanden' -f $d) -ForegroundColor DarkGray }
    }
    Write-Host '  Netzwerk     :'
    foreach ($k in $z.Netzwerk.Karten) {
        $ips = ($k.Adressen | ForEach-Object { '{0}/{1}' -f $_.IP, $_.Prefix }) -join ', '
        Write-Host ('    [{0}] {1} ({2}) {3} {4} GW {5} DNS {6}' -f $k.Index, $k.Name, $k.Status, $(if ($k.Dhcp) { 'DHCP' } else { 'statisch' }), $ips, ($k.Gateway -join ' '), ($k.DnsServer -join ' '))
    }
    if ($z.Dns.Verfuegbar) {
        Write-Host '  DNS-Zonen    :'
        foreach ($zone in $z.Dns.Zonen) {
            Write-Host ('    {0,-35} {1,-9} {2,-12} Updates: {3}' -f $zone.Name, $zone.Typ, $(if ($zone.AdIntegriert) { 'AD (' + $zone.Replikation + ')' } else { 'Datei' }), $zone.DynUpdate)
        }
        Write-Host ('  Weiterleitung: {0}' -f $(if ($z.Dns.Weiterleitungen.Count) { $z.Dns.Weiterleitungen -join ', ' } else { 'keine (Stammhinweise)' }))
        if ($z.Dns.Scavenging) { Write-Host ('  Scavenging   : {0}, No-Refresh {1}, Refresh {2}' -f $(if ($z.Dns.Scavenging.Aktiv) { 'an' } else { 'aus' }), $z.Dns.Scavenging.NoRefresh, $z.Dns.Scavenging.Refresh) }
    }
    if ($z.Dhcp.Verfuegbar) {
        Write-Host ('  DHCP         : autorisiert {0}, nachkonfiguriert {1}, Konflikterkennung {2}' -f $z.Dhcp.Autorisiert, $z.Dhcp.Nachkonfiguriert, $z.Dhcp.KonfliktErkennung)
        foreach ($sc in $z.Dhcp.Scopes) {
            Write-Host ('    {0,-15} {1,-20} {2} - {3} /{4} {5} Lease {6:N1} Tage, belegt {7:N0}%' -f $sc.ScopeId, $sc.Name, $sc.Start, $sc.Ende, $sc.Prefix, $sc.Status, $sc.LeaseTage, $sc.Auslastung)
            $opt = @()
            foreach ($id in @('3', '6', '15')) { if ($sc.Optionen.ContainsKey($id)) { $opt += ('{0}={1}' -f $id, ($sc.Optionen[$id] -join ',')) } }
            if ($opt.Count) { Write-Host ('      Optionen: ' + ($opt -join '; ')) -ForegroundColor DarkGray }
        }
        foreach ($f in $z.Dhcp.Failover) { Write-Host ('    Failover {0} mit {1}: {2}, {3}' -f $f.Name, $f.Partner, $f.Modus, $f.Status) }
    }
    Write-Host ('  Zeit         : Typ {0}, Server {1}' -f $z.Zeit.Typ, $z.Zeit.NtpServer)
    if ($z.Neustart.Ausstehend) { Write-Host ('  Neustart     : ausstehend ({0})' -f ($z.Neustart.Gruende -join ', ')) -ForegroundColor Yellow }
    Write-Host ''
    foreach ($zeile in $script:NS.Zusammenfassung) { Write-NetStatus -Status $zeile.Status -Bereich $zeile.Bereich -Text $zeile.Text }
}
# ----------------------------------------------------------------------
# src/inventar/Uebernehmen.ps1
# ----------------------------------------------------------------------
# "Vorhandene Konfiguration uebernehmen": schreibt gefundene AD-, DNS- und DHCP-Einstellungen
# in die NetSetup-Konfiguration. Am Server wird dabei nichts geaendert.
#
function ConvertTo-NetConfigFromState {
    <#
    .SYNOPSIS
        Baut aus der Bestandsaufnahme die Bereiche AD, Dns und Dhcp der Konfiguration.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Zustand)
    $ad = @{ Domaene = [string]$Zustand.AD.Domaene; NetBios = [string]$Zustand.AD.NetBios }
    $dns = @{
        Zonen           = @($Zustand.Dns.Zonen | ForEach-Object {
                @{ Name = $_.Name; Typ = $_.Typ; AdIntegriert = $_.AdIntegriert; Reverse = $_.Reverse; DynUpdate = $_.DynUpdate; Replikation = $_.Replikation }
            })
        Weiterleitungen = @($Zustand.Dns.Weiterleitungen)
        Scavenging      = $(if ($Zustand.Dns.Scavenging) { $Zustand.Dns.Scavenging } else { @{} })
    }
    $dhcp = @{
        Scopes         = @($Zustand.Dhcp.Scopes | ForEach-Object {
                @{
                    ScopeId        = $_.ScopeId
                    Name           = $_.Name
                    Start          = $_.Start
                    Ende           = $_.Ende
                    Maske          = $_.Maske
                    LeaseTage      = $_.LeaseTage
                    Aktiv          = $_.Aktiv
                    Optionen       = $_.Optionen
                    Ausschluesse   = @($_.Ausschluesse)
                    Reservierungen = @($_.Reservierungen)
                }
            })
        ServerOptionen = $Zustand.Dhcp.ServerOptionen
        DnsEinstellung = $(if ($Zustand.Dhcp.DnsEinstellung) { $Zustand.Dhcp.DnsEinstellung } else { @{} })
    }
    return @{ AD = $ad; Dns = $dns; Dhcp = $dhcp }
}
#
function Import-NetExistingConfig {
    <#
    .SYNOPSIS
        Menuepunkt "Vorhandene Konfiguration uebernehmen" (nur Config, keine Aenderung am Server).
    #>
    $zustand = Get-NetSetupState
    $neu = ConvertTo-NetConfigFromState -Zustand $zustand
    $alt = $script:NS.Config
    $vorher = @{
        'AD-Domaene'          = [string]$alt.AD.Domaene
        'DNS-Zonen'           = @($alt.Dns.Zonen).Count
        'DNS-Weiterleitungen' = (@($alt.Dns.Weiterleitungen) -join ', ')
        'DHCP-Scopes'         = @($alt.Dhcp.Scopes).Count
    }
    $nachher = @{
        'AD-Domaene'          = $neu.AD.Domaene
        'DNS-Zonen'           = @($neu.Dns.Zonen).Count
        'DNS-Weiterleitungen' = (@($neu.Dns.Weiterleitungen) -join ', ')
        'DHCP-Scopes'         = @($neu.Dhcp.Scopes).Count
    }
    if (-not $zustand.Dns.Verfuegbar -and -not $zustand.Dhcp.Verfuegbar -and -not $neu.AD.Domaene) {
        Write-Log -Level Warn -Message 'Es wurde keine vorhandene AD-, DNS- oder DHCP-Konfiguration gefunden. Es gibt nichts zu uebernehmen.'
        return
    }
    $r = Invoke-NetChange -Titel 'Vorhandene Konfiguration in die NetSetup-Konfiguration uebernehmen' -Stufe Bestaetigen -Vorher $vorher -Nachher $nachher `
        -Hinweis 'Am Server wird dabei nichts geaendert. Nur die Datei Config\netsetup.json wird aktualisiert.' -BackupBereich @('Config') -Aktion {
        $c = $script:NS.Config
        $c.AD.Domaene = $neu.AD.Domaene
        $c.AD.NetBios = $neu.AD.NetBios
        $c.Dns = $neu.Dns
        $c.Dhcp = $neu.Dhcp
        Save-NetConfig -Config $c
    }
    if ($r.Erfolg -and -not $r.Probelauf) { Write-Log -Level OK -Message 'Konfiguration uebernommen.' }
}
#
function Show-NetInventoryMenu {
    $eintraege = @(
        @{ Text = 'Bestandsaufnahme neu erfassen (Uebersicht)'; Aktion = 'Show-NetStartOverview'; Hilfe = 'Liest den aktuellen Zustand des Servers neu ein (nur lesend) und zeigt pro Bereich eine Zeile mit [OK], [WARN], [FEHLER] oder [--].' },
        @{ Text = 'Bestandsaufnahme im Detail'; Aktion = 'Show-NetStateDetail'; Hilfe = 'Zeigt alles, was NetSetup erkannt hat: Rolle, Funktionen, Dienste, Netzwerkkarten, DNS-Zonen, DHCP-Scopes, Failover, Zeitquelle.' },
        @{ Text = 'Vorhandene Konfiguration uebernehmen'; Aktion = 'Import-NetExistingConfig'; Hilfe = "Schreibt die gefundenen DNS- und DHCP-Einstellungen in die NetSetup-Konfiguration (Config\netsetup.json).`nAm Server wird dabei nichts geaendert. Sinnvoll, wenn DNS/DHCP schon eingerichtet sind." }
    )
    Show-NetMenu -Titel 'Bestandsaufnahme' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/ad/Netzwerk.ps1
# ----------------------------------------------------------------------
# Netzwerk-Grundlagen fuer AD, DNS und DHCP: feste IP, DNS-Client, Servername, Zeit.
# Alle Aenderungen laufen ueber Invoke-NetChange (Vorher/Nachher, Backup, Rueckgaengig).
#
function Select-NetActiveAdapter {
    <#
    .SYNOPSIS
        Waehlt die Netzwerkkarte, um die es geht (bei mehreren wird gefragt).
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    $karten = @($Zustand.Netzwerk.AktiveKarten)
    if ($karten.Count -eq 0) {
        Write-Log -Level Fehler -Message 'Keine aktive Netzwerkkarte mit IPv4-Adresse gefunden.'
        Write-Log -Message 'Naechster Schritt: Netzwerkkabel bzw. virtuellen Switch pruefen und die Karte aktivieren.'
        return $null
    }
    if ($karten.Count -eq 1) { return $karten[0] }
    Write-Log -Level Warn -Message 'Es sind mehrere Netzwerkkarten aktiv. Bitte die Karte im Netz der Clients waehlen.'
    $anzeige = @($karten | ForEach-Object { [pscustomobject]@{ Index = $_.Index; Name = $_.Name; IP = (($_.Adressen | ForEach-Object { $_.IP + '/' + $_.Prefix }) -join ', '); Art = $(if ($_.Dhcp) { 'DHCP' } else { 'statisch' }) } })
    $wahl = Select-NetItem -Elemente $anzeige -Titel 'Netzwerkkarte waehlen' -Eigenschaften @('Index', 'Name', 'IP', 'Art')
    if (-not $wahl) { return $null }
    return ($karten | Where-Object { $_.Index -eq $wahl.Index } | Select-Object -First 1)
}
#
function Set-NetStaticAddress {
    <#
    .SYNOPSIS
        Setzt eine feste IPv4-Adresse (Stufe Gefaehrlich: Remotedesktop kann getrennt werden).
    #>
    param([hashtable]$Karte)
    if (-not $Karte) { $Karte = Select-NetActiveAdapter }
    if (-not $Karte) { return $false }
    $aktuell = $Karte.Adressen | Select-Object -First 1
    $vorschlagGw = ''
    if ($Karte.Gateway.Count -gt 0) { $vorschlagGw = $Karte.Gateway[0] }
    Write-NetText -Text ('Netzwerkkarte {0}: zurzeit {1}/{2} ({3}).' -f $Karte.Name, $aktuell.IP, $aktuell.Prefix, $(if ($Karte.Dhcp) { 'per DHCP' } else { 'statisch' })) -Farbe White
    Write-NetText -Text 'Ein Server braucht eine feste IP. Ueblich ist eine Adresse ausserhalb des DHCP-Bereichs, z. B. .10 bis .20.'
    $ip = Read-NetIPAddress -Frage 'Feste IP-Adresse' -Vorschlag $aktuell.IP
    if (-not $ip) { return $false }
    $netz = Read-NetSubnet -Frage 'Netz (Praefix oder Maske)' -Vorschlag ('{0}/{1}' -f (Get-NetNetworkAddress -IPAddress $ip -PrefixLength $aktuell.Prefix), $aktuell.Prefix)
    if (-not $netz) { return $false }
    if (-not (Test-NetIPInSubnet -IPAddress $ip -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix)) {
        Write-Log -Level Fehler -Message "Die Adresse $ip liegt nicht im Netz $($netz.Text)."
        return $false
    }
    $gw = Read-NetIPAddress -Frage 'Gateway (Router)' -Vorschlag $vorschlagGw -Netz $netz.Netz -Prefix $netz.Prefix -LeerErlaubt
    if ($null -eq $gw) { return $false }
    $dnsVorschlag = ($Karte.DnsServer -join ',')
    $dnsText = Read-NetText -Frage 'DNS-Server (mit Komma getrennt)' -Vorschlag $dnsVorschlag -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $dnsText) { return $false }
    $dnsListe = @($dnsText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $index = [int]$Karte.Index
    $prefix = [int]$netz.Prefix
    $vorher = @{ Karte = $Karte.Name; IP = ('{0}/{1}' -f $aktuell.IP, $aktuell.Prefix); Art = $(if ($Karte.Dhcp) { 'DHCP' } else { 'statisch' }); Gateway = ($Karte.Gateway -join ', '); DNS = ($Karte.DnsServer -join ', ') }
    $nachher = @{ Karte = $Karte.Name; IP = ('{0}/{1}' -f $ip, $prefix); Art = 'statisch'; Gateway = $gw; DNS = ($dnsListe -join ', ') }
    $rueck = @(
        @{ Befehl = 'Remove-NetIPAddress'; Parameter = @{ InterfaceIndex = $index; IPAddress = $ip; Confirm = $false } },
        @{ Befehl = 'Set-NetIPInterface'; Parameter = @{ InterfaceIndex = $index; Dhcp = 'Enabled' } },
        @{ Befehl = 'Set-DnsClientServerAddress'; Parameter = @{ InterfaceIndex = $index; ResetServerAddresses = $true } }
    )
    if (-not $Karte.Dhcp) {
        $rueck = @(
            @{ Befehl = 'Remove-NetIPAddress'; Parameter = @{ InterfaceIndex = $index; IPAddress = $ip; Confirm = $false } },
            @{ Befehl = 'New-NetIPAddress'; Parameter = @{ InterfaceIndex = $index; IPAddress = $aktuell.IP; PrefixLength = [int]$aktuell.Prefix } }
        )
    }
    $r = Invoke-NetChange -Titel ('Feste IP-Adresse {0}/{1} auf {2} setzen' -f $ip, $prefix, $Karte.Name) -Stufe Gefaehrlich -Vorher $vorher -Nachher $nachher -BackupBereich @('Netzwerk') `
        -Hinweis 'ACHTUNG: Waehrend der Umstellung wird die Verbindung kurz unterbrochen. Eine Remotedesktop-Sitzung wird getrennt, wenn sich die Adresse aendert - danach mit der neuen Adresse neu verbinden.' -Aktion {
        Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false
        Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
        if ($gw) { New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw | Out-Null }
        else { New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $ip -PrefixLength $prefix | Out-Null }
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dnsListe
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Set-NetDnsClient {
    <#
    .SYNOPSIS
        Stellt die DNS-Server ein, die dieser Server selbst fragt (DNS-Client).
    #>
    param([hashtable]$Karte, [string[]]$Server, [string]$Grund = '')
    if (-not $Karte) { $Karte = Select-NetActiveAdapter }
    if (-not $Karte) { return $false }
    if (-not $Server) {
        Write-NetText -Text 'Ein Domaenencontroller fragt sich selbst (eigene IP, dann 127.0.0.1). Mitgliedsserver fragen die DCs, nie direkt einen Internet-DNS wie 8.8.8.8.'
        $text = Read-NetText -Frage 'DNS-Server (mit Komma getrennt)' -Vorschlag ($Karte.DnsServer -join ',') -Pruefung {
            param($t)
            foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
            return $null
        }
        if (-not $text) { return $false }
        $Server = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $alt = @($Karte.DnsServer)
    if (($alt -join ',') -eq ($Server -join ',')) {
        Write-Log -Level OK -Message ('DNS-Client ist bereits richtig eingestellt: ' + ($Server -join ', '))
        return $true
    }
    $index = [int]$Karte.Index
    $neu = @($Server)
    $rueck = @{ Befehl = 'Set-DnsClientServerAddress'; Parameter = @{ InterfaceIndex = $index; ServerAddresses = $alt } }
    if ($alt.Count -eq 0) { $rueck = @{ Befehl = 'Set-DnsClientServerAddress'; Parameter = @{ InterfaceIndex = $index; ResetServerAddresses = $true } } }
    $r = Invoke-NetChange -Titel ('DNS-Client von {0} einstellen' -f $Karte.Name) -Stufe Bestaetigen -Vorher ($alt -join ', ') -Nachher ($neu -join ', ') -Hinweis $Grund -BackupBereich @('Netzwerk') -Aktion {
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $neu
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Rename-NetServer {
    <#
    .SYNOPSIS
        Benennt den Server um (vor der Heraufstufung zum DC). Danach ist ein Neustart noetig.
    #>
    param([string]$NeuerName, [string]$WeiterMit = '', [hashtable]$WeiterDaten = @{})
    $alt = [Environment]::MachineName
    if (-not $NeuerName) {
        Write-NetText -Text 'Der Name muss vor der Heraufstufung zum DC feststehen; danach ist eine Umbenennung aufwendig. Beispiele: DC01, SRV-DC01.'
        $NeuerName = Read-NetText -Frage 'Neuer Servername' -Vorschlag 'DC01' -Pruefung { param($t) Test-NetHostName -Name $t }
        if (-not $NeuerName) { return $false }
    }
    if ($NeuerName -ieq $alt) { Write-Log -Level OK -Message 'Der Server heisst bereits so.'; return $true }
    $neu = $NeuerName.ToUpper()
    $r = Invoke-NetChange -Titel "Server umbenennen in $neu" -Stufe Bestaetigen -Vorher $alt -Nachher $neu -Hinweis 'Die Umbenennung wird erst nach einem Neustart wirksam.' -Aktion {
        Rename-Computer -NewName $neu -Force
    } -Rueckgaengig @{ Befehl = 'Rename-Computer'; Parameter = @{ NewName = $alt; Force = $true } }
    if ($r.Erfolg -and -not $r.Probelauf) {
        Save-NetResumeState -Schritt 'AdNachUmbenennung' -Daten @{ WeiterMit = $WeiterMit; WeiterDaten = $WeiterDaten } -Beschreibung "Umbenennung in $neu"
        Request-NetRestart -Grund "Umbenennung in $neu"
        return $true
    }
    return $false
}
#
function Get-NetTimeOffset {
    <#
    .SYNOPSIS
        Misst die Zeitabweichung zu einem NTP-Server (SNTP ueber UDP 123, nur .NET-Bordmittel).
    .OUTPUTS
        Abweichung in Sekunden (positiv = Server geht vor) oder $null, wenn keine Antwort kam.
    #>
    param([Parameter(Mandatory = $true)][string]$Server, [int]$TimeoutMs = 3000)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $anfrage = New-Object byte[] 48
        $anfrage[0] = 0x1B
        $udp.Connect($Server, 123)
        $t1 = [DateTime]::UtcNow
        [void]$udp.Send($anfrage, $anfrage.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $antwort = $udp.Receive([ref]$ep)
        $t4 = [DateTime]::UtcNow
        if ($antwort.Length -lt 48) { return $null }
        $sek = [uint64](([uint32]$antwort[40] -shl 24) -bor ([uint32]$antwort[41] -shl 16) -bor ([uint32]$antwort[42] -shl 8) -bor [uint32]$antwort[43])
        $bruch = [uint64](([uint32]$antwort[44] -shl 24) -bor ([uint32]$antwort[45] -shl 16) -bor ([uint32]$antwort[46] -shl 8) -bor [uint32]$antwort[47])
        $basis = New-Object DateTime(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $serverZeit = $basis.AddSeconds([double]$sek + ([double]$bruch / 4294967296.0))
        $mitte = $t1.AddTicks([long](($t4 - $t1).Ticks / 2))
        return [Math]::Round(($serverZeit - $mitte).TotalSeconds, 2)
    }
    catch {
        Write-Log -Level Debug -Message ('Zeitabfrage bei {0} fehlgeschlagen: {1}' -f $Server, $_.Exception.Message)
        return $null
    }
    finally {
        if ($udp) { $udp.Close() }
    }
}
#
function Invoke-NetW32tm {
    <#
    .SYNOPSIS
        Ruft w32tm.exe auf. Ausgewertet wird nur der Exitcode, nie der (uebersetzte) Text.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Argumente)
    $ausgabe = & w32tm.exe @Argumente 2>&1
    Write-Log -Level Debug -Message ('w32tm ' + ($Argumente -join ' ') + ' -> ' + $LASTEXITCODE + ': ' + (($ausgabe | Out-String).Trim()))
    if ($LASTEXITCODE -ne 0) { throw ('w32tm meldet Fehlercode {0}.' -f $LASTEXITCODE) }
}
#
function Set-NetPdcTimeSource {
    <#
    .SYNOPSIS
        Stellt die externe Zeitquelle fuer den PDC-Emulator (bzw. einen Server ohne Domaene) ein.
    #>
    param([string]$NtpServer)
    if (-not $NtpServer) {
        Write-NetText -Text "Der PDC-Emulator ist die Zeitquelle der ganzen Domaene. Er sollte die Zeit von einer externen Quelle holen,`nz. B. ch.pool.ntp.org, de.pool.ntp.org, time.windows.com oder der Router. Ohne Internet: den Router oder eine interne Zeitquelle angeben."
        $NtpServer = Read-NetText -Frage 'NTP-Server (mehrere mit Leerzeichen)' -Vorschlag 'ch.pool.ntp.org' -Pruefung {
            param($t)
            foreach ($x in $t.Split(' ')) { if ($x -and $x -notmatch '^[A-Za-z0-9.-]+$') { return "'$x' ist kein gueltiger Name bzw. keine IP." } }
            return $null
        }
        if (-not $NtpServer) { return $false }
    }
    $zeit = Get-NetTimeState
    $liste = ($NtpServer.Split(' ') | Where-Object { $_ } | ForEach-Object { $_ + ',0x8' }) -join ' '
    $r = Invoke-NetChange -Titel 'Externe Zeitquelle einstellen' -Stufe Bestaetigen -Vorher @{ Typ = $zeit.Typ; Server = $zeit.NtpServer } -Nachher @{ Typ = 'NTP'; Server = $liste } -Aktion {
        Invoke-NetW32tm -Argumente @('/config', ('/manualpeerlist:' + $liste), '/syncfromflags:manual', '/reliable:yes', '/update')
        Restart-Service -Name W32Time -Force
        try { Invoke-NetW32tm -Argumente @('/resync', '/force') } catch { Write-Log -Level Warn -Message 'Die erste Synchronisierung ist fehlgeschlagen (Quelle nicht erreichbar?). Windows versucht es automatisch erneut.' }
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Sync-NetTimeWithDc {
    <#
    .SYNOPSIS
        Synchronisiert die Uhr mit einem Domaenencontroller (vor Beitritt oder Heraufstufung).
    #>
    param([Parameter(Mandatory = $true)][string]$Dc)
    $r = Invoke-NetChange -Titel "Uhrzeit mit $Dc abgleichen" -Stufe Bestaetigen -Hinweis 'Mehr als 5 Minuten Abweichung verhindern die Anmeldung an der Domaene (Kerberos).' -Aktion {
        Invoke-NetW32tm -Argumente @('/config', ('/manualpeerlist:' + $Dc), '/syncfromflags:manual', '/update')
        Restart-Service -Name W32Time -Force
        Invoke-NetW32tm -Argumente @('/resync', '/force')
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
# ----------------------------------------------------------------------
# src/ad/AdEinrichtung.ps1
# ----------------------------------------------------------------------
# Active Directory einrichten: Entscheidungsbaum, Vorpruefungen, Heraufstufung, Beitritt,
# Neustart mit Fortsetzung. Zugangsdaten nur per Get-Credential, DSRM-Kennwort nur als SecureString.
#
# Reihenfolge der Funktionsebenen, hoechste zuerst (Namen der ADDSDeployment-Enums).
$script:NetFunktionsebenen = @('Win2025', 'WinThreshold', 'Win2012R2', 'Win2012', 'Win2008R2', 'Win2008')
$script:NetFunktionsebeneText = @{
    Win2025      = 'Windows Server 2025'
    WinThreshold = 'Windows Server 2016 (gilt auch fuer 2019 und 2022)'
    Win2012R2    = 'Windows Server 2012 R2'
    Win2012      = 'Windows Server 2012'
    Win2008R2    = 'Windows Server 2008 R2'
    Win2008      = 'Windows Server 2008'
}
#
function Get-NetAvailableFunctionLevel {
    <#
    .SYNOPSIS
        Liefert die Funktionsebenen, die dieses Betriebssystem kann (hoechste zuerst).
        Ermittelt ueber den Parametertyp von Install-ADDSForest, nicht ueber Versionsnummern.
    #>
    $namen = @()
    $cmd = Get-Command -Name Install-ADDSForest -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Parameters.ContainsKey('ForestMode')) {
        $typ = $cmd.Parameters['ForestMode'].ParameterType
        if ($typ.IsEnum) { $namen = [Enum]::GetNames($typ) }
    }
    $ergebnis = @($script:NetFunktionsebenen | Where-Object { $namen -contains $_ })
    if ($ergebnis.Count -eq 0) { $ergebnis = @('WinThreshold') }
    return $ergebnis
}
#
function Show-NetAdInfo {
    <#
    .SYNOPSIS
        Zeigt Domaene, Gesamtstruktur, Funktionsebenen, FSMO-Rollen und Domaenencontroller.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'Active Directory'
    Write-Host ('  Dieser Server : {0} ({1})' -f $z.System.Hostname, $z.System.RolleText)
    if (-not ($z.System.IstDC -or $z.System.IstMitglied)) {
        Write-Log -Message 'Der Server ist in keiner Domaene (Arbeitsgruppe). Im AD-Menue "AD einrichten" waehlen.'
        return
    }
    if ($z.AD.ModulFehlt) {
        Write-Log -Level Warn -Message ('Domaene {0}, aber das AD-PowerShell-Modul fehlt (RSAT-AD-PowerShell).' -f $z.System.Domaene)
        return
    }
    $d = Get-NetSafe -Beschreibung 'Get-ADDomain' -Abfrage { Get-ADDomain }
    $f = Get-NetSafe -Beschreibung 'Get-ADForest' -Abfrage { Get-ADForest }
    if (-not $d) { Write-Log -Level Warn -Message 'Die Domaene ist nicht erreichbar. Details im Log; Doktor ausfuehren.'; return }
    Write-Host ('  Domaene       : {0} (NetBIOS {1})' -f $d.DNSRoot, $d.NetBIOSName)
    Write-Host ('  Ebene Domaene : {0}' -f $d.DomainMode)
    if ($f) {
        Write-Host ('  Gesamtstruktur: {0}, Ebene {1}' -f $f.Name, $f.ForestMode)
        Write-Host ('  Schema-Master : {0}   Namensmaster: {1}' -f $f.SchemaMaster, $f.DomainNamingMaster)
    }
    Write-Host ('  PDC-Emulator  : {0}   RID-Master: {1}   Infrastruktur: {2}' -f $d.PDCEmulator, $d.RIDMaster, $d.InfrastructureMaster)
    $dcs = @(Get-NetSafe -Beschreibung 'Get-ADDomainController' -Standard @() -Abfrage { Get-ADDomainController -Filter * })
    Write-Host ('  Domaenencontroller ({0}):' -f $dcs.Count)
    foreach ($dc in $dcs) { Write-Host ('    {0,-30} {1,-15} Standort {2}' -f $dc.HostName, $dc.IPv4Address, $dc.Site) }
    if ($dcs.Count -eq 1) { Write-Log -Level Warn -Message 'Nur ein Domaenencontroller. Empfohlen sind mindestens zwei, damit die Anmeldung auch bei einem Ausfall funktioniert.' }
}
#
function Install-NetAdRole {
    <#
    .SYNOPSIS
        Installiert die Rolle AD-Domain-Services mit Verwaltungstools (falls noetig).
    #>
    $f = Get-NetFeatureState
    if ($f['AD-Domain-Services'] -eq 'Installed' -and $f['RSAT-AD-PowerShell'] -eq 'Installed') {
        Write-Log -Level OK -Message 'Die Rolle AD-Domain-Services ist installiert.'
        return $true
    }
    if ($f['AD-Domain-Services'] -eq 'Removed') {
        Write-Log -Level Fehler -Message 'Die Installationsdateien der Rolle wurden vom Server entfernt (Removed).'
        Write-Log -Message 'Naechster Schritt: Windows-Installationsmedium einlegen und Install-WindowsFeature AD-Domain-Services -Source <Laufwerk>:\sources\sxs ausfuehren.'
        return $false
    }
    $r = Invoke-NetChange -Titel 'Rolle AD-Domain-Services mit Verwaltungstools installieren' -Stufe Bestaetigen `
        -Vorher ('AD-Domain-Services: ' + (ConvertTo-NetFeatureText -Status $f['AD-Domain-Services'])) -Nachher 'AD-Domain-Services: installiert (noch kein DC)' -Aktion {
        $erg = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        if ($erg -and ($erg.PSObject.Properties['Success']) -and -not $erg.Success) { throw 'Die Installation der Rolle ist fehlgeschlagen.' }
    } -Rueckgaengig @{ Befehl = 'Uninstall-WindowsFeature'; Parameter = @{ Name = 'AD-Domain-Services' } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Show-NetAddsTestResult {
    <#
    .SYNOPSIS
        Zeigt das Ergebnis von Test-ADDS*Installation verstaendlich an. Liefert $true, wenn kein Fehler dabei ist.
    #>
    param([object[]]$Ergebnis)
    $ok = $true
    $liste = @($Ergebnis | Where-Object { $null -ne $_ })
    if ($liste.Count -eq 0) {
        Write-Log -Level Fehler -Message 'Die Vorpruefung von Windows hat kein Ergebnis geliefert.'
        return $false
    }
    foreach ($e in $liste) {
        $status = [string]$e.Status
        $text = ([string]$e.Message).Trim()
        if (-not $text) { continue }
        if ($status -eq 'Error') { $ok = $false; Write-Log -Level Fehler -Message $text }
        elseif ($status -eq 'Warning') { Write-Log -Level Warn -Message $text }
        else { Write-Log -Message $text }
    }
    if ($ok) { Write-Log -Level OK -Message 'Die Vorpruefung von Windows (Test-ADDS) war erfolgreich.' }
    else { Write-Log -Message 'Naechster Schritt: die markierten Fehler beheben (Doktor hilft) und erneut starten.' }
    return $ok
}
#
function Test-NetAdNetworkReady {
    <#
    .SYNOPSIS
        Vorpruefung: feste IP. Bietet die Reparatur an. Liefert die Netzwerkkarte oder $null.
    #>
    param([hashtable]$Zustand)
    $karte = Select-NetActiveAdapter -Zustand $Zustand
    if (-not $karte) { return $null }
    if ($karte.Dhcp) {
        Write-Log -Level Warn -Message ('Die Netzwerkkarte {0} bezieht ihre IP per DHCP. Ein Domaenencontroller braucht eine feste IP.' -f $karte.Name)
        if (-not (Read-NetYesNo -Frage 'Jetzt eine feste IP setzen?' -Vorschlag $true)) { return $null }
        if (-not (Set-NetStaticAddress -Karte $karte)) { return $null }
        $karte = Select-NetActiveAdapter -Zustand (Get-NetSetupState)
    }
    else { Write-Log -Level OK -Message ('Feste IP: {0}' -f (($karte.Adressen | ForEach-Object { $_.IP + '/' + $_.Prefix }) -join ', ')) }
    return $karte
}
#
function Test-NetAdNameReady {
    <#
    .SYNOPSIS
        Vorpruefung: Servername. Ein automatisch vergebener Name (WIN-...) sollte vorher geaendert werden.
        Liefert 'OK', 'Neustart' (Umbenennung laeuft) oder 'Abbruch'.
    #>
    param([hashtable]$Zustand, [string]$WeiterMit, [hashtable]$WeiterDaten = @{})
    if ($Zustand.Neustart.Ausstehend) {
        Write-Log -Level Warn -Message ('Ein Neustart steht aus: ' + ($Zustand.Neustart.Gruende -join ', '))
        Write-Log -Message 'Vor der Einrichtung von AD muss der Server neu gestartet werden.'
        if (Read-NetYesNo -Frage 'Jetzt neu starten und danach automatisch weitermachen?' -Vorschlag $true) {
            Save-NetResumeState -Schritt 'AdNachUmbenennung' -Daten @{ WeiterMit = $WeiterMit; WeiterDaten = $WeiterDaten } -Beschreibung 'Neustart vor der AD-Einrichtung'
            Request-NetRestart -Grund 'ausstehender Neustart vor der AD-Einrichtung'
            return 'Neustart'
        }
        return 'Abbruch'
    }
    $name = $Zustand.System.Hostname
    $grund = Test-NetHostName -Name $name
    if ($name -match '^WIN-[A-Z0-9]{8,}$' -or $grund) {
        if ($grund) { Write-Log -Level Warn -Message ("Der Servername '{0}' ist ungeeignet: {1}" -f $name, $grund) }
        else { Write-Log -Level Warn -Message ("Der Servername '{0}' wurde automatisch vergeben." -f $name) }
        if (Read-NetYesNo -Frage 'Den Server jetzt umbenennen (mit Neustart, danach geht es automatisch weiter)?' -Vorschlag $true) {
            if (Rename-NetServer -WeiterMit $WeiterMit -WeiterDaten $WeiterDaten) { return 'Neustart' }
            return 'Abbruch'
        }
        if (-not (Read-NetYesNo -Frage "Mit dem Namen '$name' weitermachen?" -Vorschlag $false)) { return 'Abbruch' }
    }
    else { Write-Log -Level OK -Message ('Servername: ' + $name) }
    return 'OK'
}
#
function Read-NetDsrmPassword {
    Write-NetText -Text "Das DSRM-Kennwort (Verzeichnisdienst-Wiederherstellungsmodus) braucht man im Notfall, wenn das AD nicht startet.`nEs wird nicht gespeichert. Bitte sicher aufbewahren (z. B. im Passwort-Safe)."
    return (Read-NetSecret -Frage 'DSRM-Kennwort' -Bestaetigen -Komplex)
}
#
function New-NetForest {
    <#
    .SYNOPSIS
        Neue Gesamtstruktur erstellen: Vorpruefungen, Test-ADDSForestInstallation, Install-ADDSForest.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    Write-NetTitle -Titel 'Neue Gesamtstruktur erstellen (erster Domaenencontroller)'
    $karte = Test-NetAdNetworkReady -Zustand $Zustand
    if (-not $karte) { return }
    $name = Test-NetAdNameReady -Zustand $Zustand -WeiterMit 'Forest'
    if ($name -ne 'OK') { return }
#
    Write-NetText -Text "Der Domaenenname ist der DNS-Name des AD. Empfohlen: eine Subdomain der eigenen Internet-Domain,`nz. B. ad.firma.ch (nicht .local und kein einteiliger Name)."
    $vorschlag = [string](Get-NetConfigValue -Pfad 'AD.Domaene' -Standard '')
    while ($true) {
        $domaene = Read-NetText -Frage 'Domaenenname (z. B. ad.firma.ch)' -Vorschlag $vorschlag -Pruefung { param($t) (Test-NetDomainName -Name $t).Fehler }
        if (-not $domaene) { return }
        $pruef = Test-NetDomainName -Name $domaene
        $domaene = $pruef.Name
        foreach ($w in $pruef.Warnungen) { Write-Log -Level Warn -Message $w }
        if ($pruef.Warnungen.Count -eq 0 -or (Read-NetYesNo -Frage "Trotzdem '$domaene' verwenden?" -Vorschlag $false)) { break }
        $vorschlag = ''
    }
    $netbios = Read-NetText -Frage 'NetBIOS-Name der Domaene' -Vorschlag (Get-NetNetBiosSuggestion -DomainName $domaene) -Pruefung {
        param($t)
        if ($t.Length -gt 15) { return 'Hoechstens 15 Zeichen.' }
        if ($t -notmatch '^[A-Za-z0-9-]+$') { return 'Nur Buchstaben, Ziffern und Bindestrich.' }
        if ($t -match '^\d+$') { return 'Nicht nur Ziffern.' }
        return $null
    }
    if (-not $netbios) { return }
    $netbios = $netbios.ToUpper()
#
    $ebenen = @(Get-NetAvailableFunctionLevel)
    $ebene = $ebenen[0]
    Write-Log -Message ('Funktionsebene: {0} - die hoechste, die dieses Windows kann.' -f $script:NetFunktionsebeneText[$ebene])
    if ($ebenen.Count -gt 1 -and (Read-NetYesNo -Frage 'Eine niedrigere Funktionsebene waehlen (nur noetig fuer aeltere DCs)?' -Vorschlag $false)) {
        $i = Read-NetChoice -Frage 'Funktionsebene' -Optionen @($ebenen | ForEach-Object { $script:NetFunktionsebeneText[$_] }) -Vorschlag 1
        if ($i -lt 0) { return }
        $ebene = $ebenen[$i]
    }
#
    $dsrm = Read-NetDsrmPassword
    if (-not $dsrm) { return }
    if (-not (Install-NetAdRole)) { return }
#
    $parameter = @{
        DomainName                    = $domaene
        DomainNetbiosName             = $netbios
        ForestMode                    = $ebene
        DomainMode                    = $ebene
        InstallDns                    = $true
        SafeModeAdministratorPassword = $dsrm
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Write-Log -Message 'Windows prueft die Heraufstufung (Test-ADDSForestInstallation) ...'
    $test = Invoke-NetStep -Titel 'Vorpruefung Test-ADDSForestInstallation' -Aktion { Test-ADDSForestInstallation @parameter -WarningAction SilentlyContinue }
    if (-not $test.Erfolg -or -not (Show-NetAddsTestResult -Ergebnis $test.Ergebnis)) {
        Write-Log -Level Fehler -Message 'Die Heraufstufung wird nicht gestartet, weil die Vorpruefung nicht erfolgreich war.'
        return
    }
    $script:NS.Config.AD.Domaene = $domaene
    $script:NS.Config.AD.NetBios = $netbios
    Save-NetConfig
    $r = Invoke-NetChange -Titel "Server zum ersten Domaenencontroller der neuen Gesamtstruktur $domaene heraufstufen" -Stufe Gefaehrlich -BackupBereich @('Config', 'Netzwerk') `
        -Vorher @{ Rolle = $Zustand.System.RolleText; Domaene = '(keine)' } `
        -Nachher @{ Rolle = 'Domaenencontroller mit DNS'; Domaene = $domaene; NetBIOS = $netbios; Funktionsebene = $script:NetFunktionsebeneText[$ebene] } `
        -Hinweis 'Danach ist ein Neustart noetig. NetSetup setzt nach der Anmeldung automatisch fort (DNS-Client, Pruefung).' -Aktion {
        Install-ADDSForest @parameter -WarningAction SilentlyContinue | Out-Null
    }
    if ($r.Erfolg -and -not $r.Probelauf) {
        Save-NetResumeState -Schritt 'AdNachHeraufstufung' -Daten @{ Art = 'Forest'; Domaene = $domaene; KarteIndex = [int]$karte.Index } -Beschreibung "Heraufstufung zum DC von $domaene"
        Request-NetRestart -Grund 'Abschluss der Heraufstufung zum Domaenencontroller'
    }
}
#
function Read-NetExistingDc {
    <#
    .SYNOPSIS
        Fragt Domaene und die IP eines bestehenden DCs ab und prueft die Erreichbarkeit (DNS-SRV).
    #>
    param([hashtable]$Zustand)
    $domaene = Read-NetText -Frage 'Name der bestehenden Domaene (z. B. ad.firma.ch)' -Vorschlag ([string]$Zustand.System.Domaene) -Pruefung { param($t) (Test-NetDomainName -Name $t).Fehler }
    if (-not $domaene) { return $null }
    $domaene = $domaene.ToLower()
    $dcVorschlag = ''
    $karte = @($Zustand.Netzwerk.AktiveKarten) | Select-Object -First 1
    if ($karte -and $karte.DnsServer.Count -gt 0) { $dcVorschlag = $karte.DnsServer[0] }
    $dcIp = Read-NetIPAddress -Frage 'IP-Adresse eines bestehenden Domaenencontrollers' -Vorschlag $dcVorschlag
    if (-not $dcIp) { return $null }
    $srv = '_ldap._tcp.dc._msdcs.' + $domaene
    $antwort = Get-NetSafe -Beschreibung "SRV $srv" -Abfrage { Resolve-DnsName -Name $srv -Type SRV -Server $dcIp -DnsOnly -QuickTimeout }
    if (-not $antwort) {
        Write-Log -Level Fehler -Message ("Der DC {0} kennt die Domaene {1} nicht (kein Eintrag {2})." -f $dcIp, $domaene, $srv)
        Write-Log -Message 'Naechster Schritt: Domaenenname und DC-Adresse pruefen; Firewall (Port 53) und Netzwerkverbindung pruefen.'
        return $null
    }
    Write-Log -Level OK -Message ("Der DC {0} ist erreichbar und kennt die Domaene {1}." -f $dcIp, $domaene)
    $abw = Get-NetTimeOffset -Server $dcIp
    if ($null -eq $abw) { Write-Log -Level Warn -Message 'Die Uhrzeit des DCs konnte nicht abgefragt werden (UDP 123).' }
    elseif ([Math]::Abs($abw) -gt 120) {
        Write-Log -Level Warn -Message ('Die Uhr weicht {0:N0} Sekunden vom DC ab. Ab 5 Minuten schlaegt die Anmeldung fehl.' -f $abw)
        if (Read-NetYesNo -Frage 'Uhrzeit jetzt mit dem DC abgleichen?' -Vorschlag $true) { Sync-NetTimeWithDc -Dc $dcIp | Out-Null }
    }
    else { Write-Log -Level OK -Message ('Zeitabweichung zum DC: {0} Sekunden.' -f $abw) }
    if ($karte -and (@($karte.DnsServer) -notcontains $dcIp)) {
        Write-Log -Level Warn -Message 'Dieser Server fragt nicht den DC als DNS-Server. Ohne das findet er die Domaene nicht.'
        Set-NetDnsClient -Karte $karte -Server @($dcIp) -Grund 'Fuer den Beitritt muss der Server den DC als DNS-Server verwenden.' | Out-Null
    }
    return @{ Domaene = $domaene; DcIp = $dcIp }
}
#
function Join-NetDomain {
    <#
    .SYNOPSIS
        Tritt einer bestehenden Domaene bei. Danach ist ein Neustart noetig.
    .PARAMETER DanachDc
        Nach dem Neustart direkt mit "zusaetzlicher DC werden" weitermachen.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState), [switch]$DanachDc)
    Write-NetTitle -Titel 'Domaene beitreten'
    $karte = Test-NetAdNetworkReady -Zustand $Zustand
    if (-not $karte) { return }
    $weiter = 'Join'
    if ($DanachDc) { $weiter = 'JoinDc' }
    if ((Test-NetAdNameReady -Zustand $Zustand -WeiterMit $weiter) -ne 'OK') { return }
    $ziel = Read-NetExistingDc -Zustand $Zustand
    if (-not $ziel) { return }
    Write-NetText -Text 'Jetzt die Zugangsdaten eines Kontos eingeben, das Computer in die Domaene aufnehmen darf (z. B. FIRMA\Administrator). Sie werden nicht gespeichert.'
    $cred = Get-Credential -Message ('Konto fuer den Beitritt zu {0}' -f $ziel.Domaene)
    if (-not $cred) { Write-Log -Level Warn -Message 'Keine Zugangsdaten eingegeben. Abbruch.'; return }
    $domaene = $ziel.Domaene
    $r = Invoke-NetChange -Titel "Domaene $domaene beitreten" -Stufe Bestaetigen -Vorher ('Arbeitsgruppe ' + $Zustand.System.Arbeitsgruppe) -Nachher ('Mitglied der Domaene ' + $domaene) -BackupBereich @('Config') -Hinweis 'Danach ist ein Neustart noetig.' -Aktion {
        Add-Computer -DomainName $domaene -Credential $cred -Force
    }
    if ($r.Erfolg -and -not $r.Probelauf) {
        $schritt = 'Mitglied'
        if ($DanachDc) { $schritt = 'Dc' }
        Save-NetResumeState -Schritt 'AdNachBeitritt' -Daten @{ Ziel = $schritt; Domaene = $domaene } -Beschreibung "Beitritt zu $domaene"
        Request-NetRestart -Grund "Beitritt zur Domaene $domaene"
    }
}
#
function Add-NetDomainController {
    <#
    .SYNOPSIS
        Diesen Mitgliedsserver zu einem zusaetzlichen DC der bestehenden Domaene machen.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    Write-NetTitle -Titel 'Zusaetzlicher Domaenencontroller'
    if (-not $Zustand.System.IstMitglied) {
        Write-Log -Level Fehler -Message 'Der Server muss zuerst Mitglied der Domaene sein.'
        return
    }
    $karte = Test-NetAdNetworkReady -Zustand $Zustand
    if (-not $karte) { return }
    if ((Test-NetAdNameReady -Zustand $Zustand -WeiterMit 'Dc') -ne 'OK') { return }
    $domaene = $Zustand.System.Domaene
    Write-NetText -Text ('Zugangsdaten eines Domaenen-Admins von {0} eingeben (z. B. {1}\Administrator). Sie werden nicht gespeichert.' -f $domaene, ($domaene.Split('.')[0].ToUpper()))
    $cred = Get-Credential -Message ('Domaenen-Admin fuer {0}' -f $domaene)
    if (-not $cred) { Write-Log -Level Warn -Message 'Keine Zugangsdaten eingegeben. Abbruch.'; return }
    $dsrm = Read-NetDsrmPassword
    if (-not $dsrm) { return }
    if (-not (Install-NetAdRole)) { return }
    $parameter = @{
        DomainName                    = $domaene
        Credential                    = $cred
        InstallDns                    = $true
        SafeModeAdministratorPassword = $dsrm
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Write-Log -Message 'Windows prueft die Heraufstufung (Test-ADDSDomainControllerInstallation) ...'
    $test = Invoke-NetStep -Titel 'Vorpruefung Test-ADDSDomainControllerInstallation' -Aktion { Test-ADDSDomainControllerInstallation @parameter -WarningAction SilentlyContinue }
    if (-not $test.Erfolg -or -not (Show-NetAddsTestResult -Ergebnis $test.Ergebnis)) {
        Write-Log -Level Fehler -Message 'Die Heraufstufung wird nicht gestartet, weil die Vorpruefung nicht erfolgreich war.'
        return
    }
    $r = Invoke-NetChange -Titel "Server zum zusaetzlichen Domaenencontroller von $domaene heraufstufen" -Stufe Gefaehrlich -BackupBereich @('Config', 'Netzwerk') `
        -Vorher @{ Rolle = $Zustand.System.RolleText } -Nachher @{ Rolle = 'Domaenencontroller mit DNS'; Domaene = $domaene } `
        -Hinweis 'Die AD-Daten werden vom bestehenden DC kopiert (Replikation). Danach ist ein Neustart noetig.' -Aktion {
        Install-ADDSDomainController @parameter -WarningAction SilentlyContinue | Out-Null
    }
    if ($r.Erfolg -and -not $r.Probelauf) {
        Save-NetResumeState -Schritt 'AdNachHeraufstufung' -Daten @{ Art = 'Dc'; Domaene = $domaene; KarteIndex = [int]$karte.Index } -Beschreibung "Heraufstufung zum zusaetzlichen DC von $domaene"
        Request-NetRestart -Grund 'Abschluss der Heraufstufung zum Domaenencontroller'
    }
}
#
function Complete-NetAdNachHeraufstufung {
    <#
    .SYNOPSIS
        Fortsetzung nach der Heraufstufung: Dienste pruefen, DNS-Client auf sich selbst stellen.
    #>
    param([hashtable]$Daten = @{})
    $z = Get-NetSetupState
    if (-not $z.System.IstDC) {
        Write-Log -Level Fehler -Message 'Der Server ist nach dem Neustart kein Domaenencontroller. Die Heraufstufung ist vermutlich fehlgeschlagen.'
        Write-Log -Message 'Naechster Schritt: Ereignisanzeige (Directory Service, DNS Server) und C:\Windows\debug\dcpromo.log pruefen, dann erneut versuchen.'
        return
    }
    Write-Log -Level OK -Message ('Der Server ist jetzt Domaenencontroller von {0}.' -f $z.AD.Domaene)
    foreach ($d in @('NTDS', 'Netlogon', 'DNS')) {
        $x = $z.Dienste[$d]
        if ($x -and $x.Status -eq 'Running') { Write-Log -Level OK -Message "Dienst $d laeuft." }
        else { Write-Log -Level Warn -Message "Dienst $d laeuft nicht. Der Doktor kann ihn starten." }
    }
    $karte = @($z.Netzwerk.AktiveKarten | Where-Object { $_.Index -eq [int]$Daten.KarteIndex }) | Select-Object -First 1
    if (-not $karte) { $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1 }
    if ($karte) {
        $eigene = ($karte.Adressen | Select-Object -First 1).IP
        $soll = @($eigene, '127.0.0.1')
        if ($Daten.Art -eq 'Dc') {
            $andere = @($karte.DnsServer | Where-Object { $_ -ne $eigene -and $_ -ne '127.0.0.1' }) | Select-Object -First 1
            if ($andere) { $soll = @($andere, $eigene, '127.0.0.1') }
        }
        Set-NetDnsClient -Karte $karte -Server $soll -Grund 'Ein DC fragt sich selbst (und ggf. einen weiteren DC). So findet er die Domaene immer.' | Out-Null
    }
    if ($z.System.IstPdc -and $z.Zeit.Typ -ne 'NTP') {
        Write-Log -Level Warn -Message 'Dieser DC ist PDC-Emulator und hat noch keine externe Zeitquelle.'
        if (Read-NetYesNo -Frage 'Jetzt eine externe Zeitquelle einstellen?' -Vorschlag $true) { Set-NetPdcTimeSource | Out-Null }
    }
    $script:NS.Config.AD.Modus = ''
    Save-NetConfig
}
#
function Complete-NetAdNachBeitritt {
    param([hashtable]$Daten = @{})
    $z = Get-NetSetupState
    if (-not $z.System.IstMitglied -and -not $z.System.IstDC) {
        Write-Log -Level Fehler -Message 'Der Server ist nach dem Neustart nicht in der Domaene.'
        Write-Log -Message 'Naechster Schritt: DNS-Client (muss auf den DC zeigen), Zeit und Zugangsdaten pruefen, dann erneut beitreten.'
        return
    }
    Write-Log -Level OK -Message ('Der Server ist jetzt Mitglied der Domaene {0}.' -f $z.System.Domaene)
    if ($Daten.Ziel -eq 'Dc') {
        Write-Log -Message 'Weiter mit der Heraufstufung zum zusaetzlichen Domaenencontroller.'
        Add-NetDomainController -Zustand $z
    }
    else {
        $script:NS.Config.AD.Modus = 'Mitglied'
        Save-NetConfig
    }
}
#
function Complete-NetAdNachUmbenennung {
    param([hashtable]$Daten = @{})
    Write-Log -Level OK -Message ('Der Server heisst jetzt {0}.' -f [Environment]::MachineName)
    switch ([string]$Daten.WeiterMit) {
        'Forest' { New-NetForest }
        'Join' { Join-NetDomain }
        'JoinDc' { Join-NetDomain -DanachDc }
        'Dc' { Add-NetDomainController }
        default { Write-Log -Message 'Weiter im Menue.' }
    }
}
#
function Set-NetAdMode {
    param([ValidateSet('OhneAD', 'Mitglied', '')][string]$Modus)
    $script:NS.Config.AD.Modus = $Modus
    Save-NetConfig
}
#
function Start-NetAdSetup {
    <#
    .SYNOPSIS
        Entscheidungsbaum: bietet je nach Ausgangslage den passenden Weg an.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'Active Directory einrichten'
    Write-Log -Message ('Ausgangslage: {0} ({1})' -f $z.System.RolleText, $z.System.Hostname)
    if ($z.System.IstDC) {
        Write-Log -Level OK -Message ('Dieser Server ist bereits Domaenencontroller von {0}. Nichts zu tun.' -f $z.AD.Domaene)
        Show-NetAdInfo
        return
    }
    if ($z.Features['AD-Domain-Services'] -eq 'Installed') {
        Write-Log -Level Warn -Message 'Die Rolle AD-Domain-Services ist installiert, der Server ist aber noch kein DC (Heraufstufung fehlt oder ist fehlgeschlagen).'
    }
    if ($z.System.IstMitglied) {
        $wahl = Read-NetChoice -Frage ('Der Server ist Mitglied der Domaene {0}. Was soll er werden?' -f $z.System.Domaene) -Optionen @(
            'Zusaetzlicher Domaenencontroller (empfohlen fuer Ausfallsicherheit)',
            'Kein DC - nur DNS und/oder DHCP auf diesem Server',
            'Abbrechen') -Vorschlag 2
        switch ($wahl) {
            0 { Add-NetDomainController -Zustand $z }
            1 { Set-NetAdMode -Modus 'Mitglied'; Write-Log -Level OK -Message 'Gemerkt: Mitgliedsserver ohne DC-Rolle. Weiter mit DNS bzw. DHCP.' }
            default { return }
        }
        return
    }
    $wahl = Read-NetChoice -Frage 'Der Server ist in einer Arbeitsgruppe (kein AD). Was soll passieren?' -Optionen @(
        'Neue Gesamtstruktur erstellen (dieser Server wird der erste DC)',
        'Bestehender Domaene beitreten und zusaetzlicher DC werden',
        'Bestehender Domaene nur beitreten (Mitgliedsserver)',
        'Ohne AD weiter (DHCP ohne Autorisierung, DNS dateibasiert)',
        'Abbrechen') -Vorschlag 1
    switch ($wahl) {
        0 { New-NetForest -Zustand $z }
        1 { Join-NetDomain -Zustand $z -DanachDc }
        2 { Join-NetDomain -Zustand $z }
        3 {
            Write-NetText -Text "Ohne AD: DHCP braucht keine Autorisierung, DNS-Zonen werden als Datei gespeichert`n(nur dieser Server, keine sicheren dynamischen Updates). Das kann spaeter jederzeit geaendert werden." -Farbe Yellow
            Set-NetAdMode -Modus 'OhneAD'
            Write-Log -Level OK -Message 'Gemerkt: ohne AD. Weiter mit DNS bzw. DHCP.'
        }
        default { return }
    }
}
#
function Invoke-NetAdPrecheck {
    <#
    .SYNOPSIS
        Zeigt alle AD-Vorpruefungen an, ohne etwas zu aendern.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'AD-Vorpruefungen (nur anzeigen)'
    $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1
    if (-not $karte) { Write-NetStatus -Status FEHLER -Bereich 'Netzwerk' -Text 'keine aktive Netzwerkkarte' }
    elseif ($karte.Dhcp) { Write-NetStatus -Status WARN -Bereich 'Feste IP' -Text ('{0} bezieht die IP per DHCP' -f $karte.Name) }
    else { Write-NetStatus -Status OK -Bereich 'Feste IP' -Text (($karte.Adressen | ForEach-Object { $_.IP + '/' + $_.Prefix }) -join ', ') }
    if ($z.Netzwerk.MehrereKarten) { Write-NetStatus -Status WARN -Bereich 'Netzwerkkarten' -Text 'mehrere aktive Karten - DCs sollten nur in einem Netz registriert sein' }
    $grund = Test-NetHostName -Name $z.System.Hostname
    if ($grund) { Write-NetStatus -Status FEHLER -Bereich 'Servername' -Text $grund }
    elseif ($z.System.Hostname -match '^WIN-[A-Z0-9]{8,}$') { Write-NetStatus -Status WARN -Bereich 'Servername' -Text ('{0} ist automatisch vergeben, besser umbenennen' -f $z.System.Hostname) }
    else { Write-NetStatus -Status OK -Bereich 'Servername' -Text $z.System.Hostname }
    if ($z.Neustart.Ausstehend) { Write-NetStatus -Status WARN -Bereich 'Neustart' -Text ($z.Neustart.Gruende -join ', ') }
    else { Write-NetStatus -Status OK -Bereich 'Neustart' -Text 'kein Neustart ausstehend' }
    if ($karte -and $karte.DnsServer.Count -gt 0) { Write-NetStatus -Status INFO -Bereich 'DNS-Client' -Text ($karte.DnsServer -join ', ') }
    Write-NetStatus -Status INFO -Bereich 'Rolle AD DS' -Text (ConvertTo-NetFeatureText -Status $z.Features['AD-Domain-Services'])
    Write-NetStatus -Status INFO -Bereich 'Funktionsebene' -Text ('hoechste moegliche: ' + $script:NetFunktionsebeneText[(@(Get-NetAvailableFunctionLevel))[0]])
    Write-NetStatus -Status INFO -Bereich 'Zeit' -Text ('{0} {1}' -f $z.Zeit.Typ, $z.Zeit.NtpServer)
}
#
function Show-NetAdMenu {
    $eintraege = @(
        @{ Text = 'Domaene anzeigen'; Aktion = 'Show-NetAdInfo'; Hilfe = 'Zeigt Domaene, Gesamtstruktur, Funktionsebenen, FSMO-Rollen und alle Domaenencontroller.' },
        @{ Text = 'AD einrichten (passender Weg)'; Aktion = 'Start-NetAdSetup'; Hilfe = "Erkennt die Ausgangslage und bietet den passenden Weg an:`n- Arbeitsgruppe: neue Gesamtstruktur, Beitritt + DC, nur Beitritt oder ohne AD`n- Mitgliedsserver: zusaetzlicher DC oder nur DNS/DHCP`n- DC: zeigt die Domaene`nMit Vorpruefungen, Test-ADDS vor der Heraufstufung und Fortsetzung nach dem Neustart." },
        @{ Text = 'Vorpruefungen anzeigen (ohne Aenderung)'; Aktion = 'Invoke-NetAdPrecheck'; Hilfe = 'Prueft feste IP, Servername, ausstehenden Neustart, DNS-Client, Rolle, Funktionsebene und Zeitquelle und zeigt das Ergebnis an.' },
        @{ Text = 'Feste IP-Adresse setzen'; Aktion = { Set-NetStaticAddress | Out-Null }; Hilfe = "Server brauchen eine feste IP. Stufe gefaehrlich: Remotedesktop kann getrennt werden.`nUeblich: eine Adresse ausserhalb des DHCP-Bereichs, Gateway = Router, DNS = die DCs." },
        @{ Text = 'Server umbenennen'; Aktion = { Rename-NetServer | Out-Null }; Hilfe = 'Benennt den Server um (z. B. DC01). Vor der Heraufstufung zum DC erledigen. Braucht einen Neustart.' },
        @{ Text = 'DNS-Client einstellen'; Aktion = { Set-NetDnsClient | Out-Null }; Hilfe = 'Welche DNS-Server dieser Server selbst fragt. DC: eigene IP und 127.0.0.1. Mitglied: die DCs. Nie direkt 8.8.8.8 o. ae.' },
        @{ Text = 'Externe Zeitquelle (PDC) einstellen'; Aktion = { Set-NetPdcTimeSource | Out-Null }; Hilfe = 'Der PDC-Emulator gibt die Zeit fuer die ganze Domaene vor und sollte sie von einer externen Quelle (NTP) holen, z. B. ch.pool.ntp.org oder dem Router.' },
        @{ Text = 'Unterbrochene Einrichtung fortsetzen'; Aktion = 'Invoke-NetResumeCheck'; Hilfe = 'Falls eine Einrichtung wegen eines Neustarts unterbrochen wurde und nicht automatisch weiterlief: hier fortsetzen oder verwerfen.' }
    )
    Show-NetMenu -Titel 'Active Directory' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/dns/DnsBasis.ps1
# ----------------------------------------------------------------------
# DNS-Grundlagen: Rolle pruefen/installieren, Zonen auswaehlen, Eintraege lesen und vergleichen.
#
function Install-NetDnsRole {
    <#
    .SYNOPSIS
        Installiert die DNS-Server-Rolle und/oder die Verwaltungstools, falls sie fehlen.
    #>
    $f = Get-NetFeatureState
    if ($f['DNS'] -eq 'Installed' -and $f['RSAT-DNS-Server'] -eq 'Installed' -and (Test-NetCommand -Name 'Get-DnsServerZone')) {
        Write-Log -Level OK -Message 'DNS-Server-Rolle und Verwaltungstools sind installiert.'
        return $true
    }
    $namen = @()
    if ($f['DNS'] -ne 'Installed') { $namen += 'DNS' }
    if ($f['RSAT-DNS-Server'] -ne 'Installed') { $namen += 'RSAT-DNS-Server' }
    if ($namen.Count -eq 0) { $namen = @('RSAT-DNS-Server') }
    $r = Invoke-NetChange -Titel ('Windows-Funktion(en) installieren: ' + ($namen -join ', ')) -Stufe Bestaetigen `
        -Vorher @{ DNS = (ConvertTo-NetFeatureText -Status $f['DNS']); 'RSAT-DNS-Server' = (ConvertTo-NetFeatureText -Status $f['RSAT-DNS-Server']) } `
        -Nachher @{ DNS = 'installiert'; 'RSAT-DNS-Server' = 'installiert' } -Aktion {
        $erg = Install-WindowsFeature -Name $namen -IncludeManagementTools
        if ($erg -and $erg.PSObject.Properties['Success'] -and -not $erg.Success) { throw 'Die Installation ist fehlgeschlagen.' }
        Import-Module DnsServer -ErrorAction SilentlyContinue
    } -Rueckgaengig @{ Befehl = 'Uninstall-WindowsFeature'; Parameter = @{ Name = $namen } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Test-NetDnsReady {
    <#
    .SYNOPSIS
        Prueft, ob DNS verwaltet werden kann. Bietet sonst die Installation an.
    #>
    param([switch]$Still)
    $dienst = Get-NetSafe -Beschreibung 'Dienst DNS' -Abfrage { Get-Service -Name DNS }
    if ((Test-NetCommand -Name 'Get-DnsServerZone') -and $dienst) {
        if ([string]$dienst.Status -ne 'Running') {
            Write-Log -Level Warn -Message 'Der DNS-Dienst laeuft nicht.'
            if (-not $Still -and (Read-NetYesNo -Frage 'DNS-Dienst jetzt starten?' -Vorschlag $true)) {
                $r = Invoke-NetChange -Titel 'DNS-Dienst starten' -Stufe Automatisch -Aktion { Start-Service -Name DNS }
                return [bool]$r.Erfolg
            }
            return $false
        }
        return $true
    }
    if ($Still) { return $false }
    Write-Log -Level Warn -Message 'Der DNS-Server ist auf diesem Server nicht (vollstaendig) installiert.'
    if (Read-NetYesNo -Frage 'DNS-Server-Rolle jetzt installieren?' -Vorschlag $true) { return (Install-NetDnsRole) }
    return $false
}
#
function Get-NetDnsZoneInfo {
    <#
    .SYNOPSIS
        Liefert die Zonen (ohne automatisch erzeugte und TrustAnchors) als einfache Objekte.
    #>
    param([ValidateSet('Alle', 'Forward', 'Reverse', 'Primaer')][string]$Art = 'Alle')
    $liste = @()
    foreach ($z in @(Get-NetSafe -Beschreibung 'Get-DnsServerZone' -Standard @() -Abfrage { Get-DnsServerZone })) {
        if ($null -eq $z -or $z.IsAutoCreated -or [string]$z.ZoneName -eq 'TrustAnchors') { continue }
        $o = [pscustomobject]@{
            Name         = [string]$z.ZoneName
            Typ          = [string]$z.ZoneType
            AdIntegriert = [bool]$z.IsDsIntegrated
            Reverse      = [bool]$z.IsReverseLookupZone
            Updates      = [string]$z.DynamicUpdate
            Replikation  = [string]$z.ReplicationScope
        }
        switch ($Art) {
            'Forward' { if (-not $o.Reverse -and $o.Typ -ne 'Forwarder') { $liste += $o } }
            'Reverse' { if ($o.Reverse) { $liste += $o } }
            'Primaer' { if ($o.Typ -eq 'Primary') { $liste += $o } }
            default { $liste += $o }
        }
    }
    return $liste
}
#
function Select-NetDnsZone {
    param([ValidateSet('Alle', 'Forward', 'Reverse', 'Primaer')][string]$Art = 'Alle', [string]$Titel = 'Zone waehlen')
    $zonen = @(Get-NetDnsZoneInfo -Art $Art | Where-Object { $_.Typ -eq 'Primary' -or $Art -eq 'Alle' })
    if ($zonen.Count -eq 0) {
        Write-Log -Level Warn -Message 'Es gibt keine passende Zone. Zuerst eine Zone anlegen.'
        return $null
    }
    if ($zonen.Count -eq 1) { return $zonen[0] }
    return (Select-NetItem -Elemente $zonen -Titel $Titel -Eigenschaften @('Name', 'Typ', 'Updates', 'Replikation'))
}
#
function Show-NetDnsZone {
    Write-NetTitle -Titel 'DNS-Zonen'
    $zonen = @(Get-NetDnsZoneInfo)
    if ($zonen.Count -eq 0) { Write-Log -Level Warn -Message 'Keine Zonen vorhanden.'; return }
    Write-Host ('  {0,-38} {1,-10} {2,-16} {3}' -f 'Zone', 'Typ', 'Speicherung', 'Dynamische Updates')
    foreach ($z in $zonen) {
        $art = 'Datei'
        if ($z.AdIntegriert) { $art = 'AD (' + $z.Replikation + ')' }
        $farbe = 'Gray'
        if ($z.Typ -eq 'Primary' -and $z.Updates -eq 'None' -and -not $z.Reverse) { $farbe = 'Yellow' }
        Write-Host ('  {0,-38} {1,-10} {2,-16} {3}' -f $z.Name, $z.Typ, $art, (ConvertTo-NetDnsUpdateText -Wert $z.Updates)) -ForegroundColor $farbe
    }
}
#
function ConvertTo-NetDnsUpdateText {
    param([string]$Wert)
    switch ($Wert) {
        'Secure' { return 'nur sicher (empfohlen)' }
        'NonsecureAndSecure' { return 'sicher und unsicher' }
        'None' { return 'aus' }
        default { return $Wert }
    }
}
#
function ConvertTo-NetDnsRecord {
    <#
    .SYNOPSIS
        Wandelt einen DNS-Eintrag in ein einfaches Objekt mit Typ, Daten (Hashtable) und Anzeigetext.
    #>
    param([Parameter(Mandatory = $true)][object]$Eintrag, [string]$Zone = '')
    $typ = [string]$Eintrag.RecordType
    $rd = $Eintrag.RecordData
    $daten = @{}
    $text = ''
    switch ($typ) {
        'A' { $daten.IPv4Address = ConvertTo-NetString -Wert $rd.IPv4Address; $text = $daten.IPv4Address }
        'AAAA' { $daten.IPv6Address = ConvertTo-NetString -Wert $rd.IPv6Address; $text = $daten.IPv6Address }
        'CNAME' { $daten.HostNameAlias = [string]$rd.HostNameAlias; $text = $daten.HostNameAlias }
        'MX' { $daten.MailExchange = [string]$rd.MailExchange; $daten.Preference = [int]$rd.Preference; $text = '{0} {1}' -f $daten.Preference, $daten.MailExchange }
        'SRV' { $daten.DomainName = [string]$rd.DomainName; $daten.Priority = [int]$rd.Priority; $daten.Weight = [int]$rd.Weight; $daten.Port = [int]$rd.Port; $text = '{0} {1} {2} {3}' -f $daten.Priority, $daten.Weight, $daten.Port, $daten.DomainName }
        'TXT' { $daten.DescriptiveText = [string]$rd.DescriptiveText; $text = $daten.DescriptiveText }
        'PTR' { $daten.PtrDomainName = [string]$rd.PtrDomainName; $text = $daten.PtrDomainName }
        'NS' { $text = [string]$rd.NameServer }
        'SOA' { $text = [string]$rd.PrimaryServer }
        default { $text = '(' + $typ + ')' }
    }
    $zeit = $null
    if ($Eintrag.Timestamp) { $zeit = [datetime]$Eintrag.Timestamp }
    return [pscustomobject]@{
        Zone       = $Zone
        Name       = [string]$Eintrag.HostName
        Typ        = $typ
        Wert       = $text
        Daten      = $daten
        Zeitstempel = $zeit
        Statisch   = ($null -eq $zeit)
        Ttl        = [string]$Eintrag.TimeToLive
    }
}
#
function Get-NetDnsRecord {
    <#
    .SYNOPSIS
        Liest Eintraege einer Zone (optional nach Name und Typ gefiltert).
    #>
    param([Parameter(Mandatory = $true)][string]$Zone, [string]$Name, [string]$Typ)
    $p = @{ ZoneName = $Zone }
    if ($Name) { $p.Name = $Name }
    if ($Typ) { $p.RRType = $Typ }
    $liste = @()
    foreach ($e in @(Get-NetSafe -Beschreibung "Eintraege $Zone" -Standard @() -Abfrage { Get-DnsServerResourceRecord @p })) {
        if ($e) { $liste += (ConvertTo-NetDnsRecord -Eintrag $e -Zone $Zone) }
    }
    return $liste
}
#
function Test-NetDnsRecordEqual {
    param([hashtable]$A, [hashtable]$B)
    foreach ($k in $A.Keys) {
        if ([string]$A[$k] -ne [string]$B[$k]) {
            $x = ([string]$A[$k]).TrimEnd('.')
            $y = ([string]$B[$k]).TrimEnd('.')
            if ($x -ne $y) { return $false }
        }
    }
    return $true
}
#
function Add-NetDnsRecordExact {
    <#
    .SYNOPSIS
        Legt genau einen Eintrag an. Wird auch als Gegenaktion in der Rueckgaengig-Liste verwendet.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('A', 'AAAA', 'CNAME', 'MX', 'SRV', 'TXT', 'PTR')][string]$Typ,
        [Parameter(Mandatory = $true)][hashtable]$Daten,
        [switch]$CreatePtr
    )
    switch ($Typ) {
        'A' {
            if ($CreatePtr) { Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $Name -IPv4Address $Daten.IPv4Address -CreatePtr }
            else { Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $Name -IPv4Address $Daten.IPv4Address }
        }
        'AAAA' { Add-DnsServerResourceRecordAAAA -ZoneName $ZoneName -Name $Name -IPv6Address $Daten.IPv6Address }
        'CNAME' { Add-DnsServerResourceRecordCName -ZoneName $ZoneName -Name $Name -HostNameAlias $Daten.HostNameAlias }
        'MX' { Add-DnsServerResourceRecordMX -ZoneName $ZoneName -Name $Name -MailExchange $Daten.MailExchange -Preference ([uint16]$Daten.Preference) }
        'SRV' { Add-DnsServerResourceRecord -Srv -ZoneName $ZoneName -Name $Name -DomainName $Daten.DomainName -Priority ([uint16]$Daten.Priority) -Weight ([uint16]$Daten.Weight) -Port ([uint16]$Daten.Port) }
        'TXT' { Add-DnsServerResourceRecord -Txt -ZoneName $ZoneName -Name $Name -DescriptiveText $Daten.DescriptiveText }
        'PTR' { Add-DnsServerResourceRecordPtr -ZoneName $ZoneName -Name $Name -PtrDomainName $Daten.PtrDomainName }
    }
}
#
function Remove-NetDnsRecordExact {
    <#
    .SYNOPSIS
        Loescht genau den Eintrag mit diesen Daten (andere Eintraege gleichen Namens bleiben).
        Wird auch als Gegenaktion in der Rueckgaengig-Liste verwendet.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Typ,
        [Parameter(Mandatory = $true)][hashtable]$Daten
    )
    $treffer = 0
    foreach ($e in @(Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $Name -RRType $Typ -ErrorAction SilentlyContinue)) {
        if ($null -eq $e) { continue }
        $o = ConvertTo-NetDnsRecord -Eintrag $e -Zone $ZoneName
        if (Test-NetDnsRecordEqual -A $Daten -B $o.Daten) {
            $e | Remove-DnsServerResourceRecord -ZoneName $ZoneName -Force
            $treffer++
        }
    }
    if ($treffer -eq 0) { Write-Log -Level Warn -Message ('Eintrag {0} ({1}) in {2} war nicht (mehr) vorhanden.' -f $Name, $Typ, $ZoneName) }
}
# ----------------------------------------------------------------------
# src/dns/DnsZonen.ps1
# ----------------------------------------------------------------------
# DNS-Zonen: anlegen (AD-integriert auf DCs, sonst dateibasiert), dynamische Updates,
# fehlende Reverse-Zonen vorschlagen, loeschen (Gefaehrlich).
#
function Test-NetIsDomainController {
    $z = $script:NS.Zustand
    if ($z -and $z.System) { return [bool]$z.System.IstDC }
    $cs = Get-NetSafe -Beschreibung 'DomainRole' -Abfrage { Get-CimInstance -ClassName Win32_ComputerSystem }
    return ($cs -and [int]$cs.DomainRole -ge 4)
}
#
function Read-NetDnsZoneStorage {
    <#
    .SYNOPSIS
        Fragt Speicherung und dynamische Updates fuer eine neue Zone ab.
    #>
    $ergebnis = @{ AdIntegriert = $false; Replikation = ''; Updates = 'None' }
    if (Test-NetIsDomainController) {
        $ergebnis.AdIntegriert = $true
        $i = Read-NetChoice -Frage 'Replikation der AD-integrierten Zone' -Optionen @(
            'Domain - auf alle DNS-Server der Domaene (ueblich)',
            'Forest - auf alle DNS-Server der Gesamtstruktur') -Vorschlag 1
        if ($i -lt 0) { return $null }
        $ergebnis.Replikation = @('Domain', 'Forest')[$i]
        $j = Read-NetChoice -Frage 'Dynamische Updates' -Optionen @(
            'Nur sicher (empfohlen: nur Domaenenmitglieder und der DHCP-Server duerfen eintragen)',
            'Sicher und unsicher (jedes Geraet darf eintragen - nicht empfohlen)',
            'Aus (nur manuelle Eintraege)') -Vorschlag 1
        if ($j -lt 0) { return $null }
        $ergebnis.Updates = @('Secure', 'NonsecureAndSecure', 'None')[$j]
    }
    else {
        Write-NetText -Text 'Ohne Domaenencontroller wird die Zone als Datei gespeichert. Sichere Updates gibt es dann nicht.'
        $j = Read-NetChoice -Frage 'Dynamische Updates' -Optionen @(
            'Sicher und unsicher (noetig, damit der DHCP-Server Clients eintragen kann)',
            'Aus (nur manuelle Eintraege)') -Vorschlag 1
        if ($j -lt 0) { return $null }
        $ergebnis.Updates = @('NonsecureAndSecure', 'None')[$j]
    }
    return $ergebnis
}
#
function New-NetDnsZone {
    <#
    .SYNOPSIS
        Legt eine primaere Zone an (idempotent: existiert sie schon, passiert nichts).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Speicherung,
        [string]$Netz = ''
    )
    $Name = $Name.Trim().TrimEnd('.').ToLower()
    $vorhanden = Get-NetSafe -Beschreibung "Zone $Name" -Abfrage { Get-DnsServerZone -Name $Name }
    if ($vorhanden) {
        Write-Log -Level OK -Message ("Die Zone {0} existiert bereits ({1}). Nichts zu tun." -f $Name, [string]$vorhanden.ZoneType)
        return $true
    }
    if (-not $Speicherung) { $Speicherung = Read-NetDnsZoneStorage }
    if (-not $Speicherung) { return $false }
    $p = @{ Name = $Name; DynamicUpdate = $Speicherung.Updates }
    if ($Speicherung.AdIntegriert) { $p.ReplicationScope = $Speicherung.Replikation }
    else { $p.ZoneFile = $Name + '.dns' }
    $nachher = @{ Zone = $Name; Speicherung = $(if ($Speicherung.AdIntegriert) { 'AD (' + $Speicherung.Replikation + ')' } else { 'Datei ' + $p.ZoneFile }); Updates = (ConvertTo-NetDnsUpdateText -Wert $Speicherung.Updates) }
    if ($Netz) { $nachher.Netz = $Netz }
    $r = Invoke-NetChange -Titel "DNS-Zone $Name anlegen" -Stufe Bestaetigen -Vorher '(Zone nicht vorhanden)' -Nachher $nachher -BackupBereich @('Dns') -Aktion {
        Add-DnsServerPrimaryZone @p
    } -Rueckgaengig @{ Befehl = 'Remove-DnsServerZone'; Parameter = @{ Name = $Name; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function New-NetDnsForwardZone {
    <#
    .SYNOPSIS
        Menue: Forward-Zone anlegen (z. B. die Domaene oder eine interne Zone ohne AD).
    #>
    if (-not (Test-NetDnsReady)) { return }
    $vorschlag = Get-NetDomainName
    Write-NetText -Text 'Eine Forward-Zone loest Namen in Adressen auf. Auf einem DC gibt es die Zone der Domaene schon nach der Heraufstufung.'
    $name = Read-NetText -Frage 'Name der Zone (z. B. ad.firma.ch)' -Vorschlag $vorschlag -Pruefung { param($t) (Test-NetDomainName -Name $t).Fehler }
    if (-not $name) { return }
    New-NetDnsZone -Name $name | Out-Null
}
#
function New-NetDnsReverseZone {
    <#
    .SYNOPSIS
        Menue: Reverse-Zone(n) fuer ein Netz anlegen.
    #>
    param([string]$Netz)
    if (-not (Test-NetDnsReady)) { return }
    Write-NetText -Text 'Eine Reverse-Zone loest Adressen in Namen auf (PTR). Pro Netz wird eine Zone gebraucht, z. B. 1.168.192.in-addr.arpa fuer 192.168.1.0/24.'
    $s = $null
    if ($Netz) { $s = ConvertTo-NetSubnet -Text $Netz }
    else { $s = Read-NetSubnet -Frage 'Netz (z. B. 192.168.1.0/24)' }
    if (-not $s) { return }
    if ($s.Prefix -lt 8) { Write-Log -Level Fehler -Message 'Netze groesser als /8 werden nicht unterstuetzt.'; return }
    $speicherung = $null
    foreach ($zone in @(Get-NetReverseZoneName -NetworkAddress $s.Netz -PrefixLength $s.Prefix)) {
        $existiert = Get-NetSafe -Beschreibung "Zone $zone" -Abfrage { Get-DnsServerZone -Name $zone }
        if ($existiert) { Write-Log -Level OK -Message "Reverse-Zone $zone existiert bereits."; continue }
        if (-not $speicherung) { $speicherung = Read-NetDnsZoneStorage }
        if (-not $speicherung) { return }
        New-NetDnsZone -Name $zone -Speicherung $speicherung -Netz $s.Text | Out-Null
    }
}
#
function Get-NetMissingReverseZone {
    <#
    .SYNOPSIS
        Ermittelt fehlende Reverse-Zonen fuer das Server-Netz und alle DHCP-Scopes.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    $netze = @()
    foreach ($k in @($Zustand.Netzwerk.AktiveKarten)) {
        foreach ($a in @($k.Adressen)) {
            if ($a.IP -like '169.254.*') { continue }
            $netze += [pscustomobject]@{ Netz = (Get-NetNetworkAddress -IPAddress $a.IP -PrefixLength $a.Prefix); Prefix = [int]$a.Prefix; Quelle = ('Netzwerkkarte ' + $k.Name) }
        }
    }
    foreach ($sc in @($Zustand.Dhcp.Scopes)) {
        if ($sc.Prefix -gt 0) { $netze += [pscustomobject]@{ Netz = $sc.ScopeId; Prefix = [int]$sc.Prefix; Quelle = ('DHCP-Scope ' + $sc.Name) } }
    }
    $zonen = @($Zustand.Dns.Zonen | Where-Object { $_.Reverse } | ForEach-Object { $_.Name })
    $fehlend = @()
    $gesehen = @{}
    foreach ($n in $netze) {
        if ($n.Prefix -lt 8) { continue }
        foreach ($zone in @(Get-NetReverseZoneName -NetworkAddress $n.Netz -PrefixLength $n.Prefix)) {
            if ($gesehen.ContainsKey($zone)) { continue }
            $gesehen[$zone] = $true
            # Eine groessere Zone (z. B. 168.192.in-addr.arpa) deckt das Netz ebenfalls ab.
            $teile = $zone.Replace('.in-addr.arpa', '').Split('.')
            [Array]::Reverse($teile)
            $beispiel = (@($teile) + @('0', '0', '0', '1'))[0..3] -join '.'
            if (Find-NetReverseZone -IPAddress $beispiel -ZoneNames $zonen) { continue }
            $fehlend += [pscustomobject]@{ Zone = $zone; Netz = ('{0}/{1}' -f $n.Netz, $n.Prefix); Quelle = $n.Quelle }
        }
    }
    return $fehlend
}
#
function Add-NetMissingReverseZone {
    <#
    .SYNOPSIS
        Schlaegt fehlende Reverse-Zonen vor und legt die gewaehlten an.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $fehlend = @(Get-NetMissingReverseZone)
    if ($fehlend.Count -eq 0) {
        Write-Log -Level OK -Message 'Fuer alle Netze (Server und DHCP-Scopes) gibt es eine Reverse-Zone.'
        return
    }
    Write-Log -Level Warn -Message ('{0} Reverse-Zone(n) fehlen. Ohne sie gibt es keine PTR-Eintraege (Adresse -> Name).' -f $fehlend.Count)
    $wahl = @(Select-NetItem -Elemente $fehlend -Titel 'Welche Reverse-Zonen anlegen?' -Eigenschaften @('Zone', 'Netz', 'Quelle') -Mehrfach)
    if ($wahl.Count -eq 0) { return }
    $speicherung = Read-NetDnsZoneStorage
    if (-not $speicherung) { return }
    foreach ($f in $wahl) { New-NetDnsZone -Name $f.Zone -Speicherung $speicherung -Netz $f.Netz | Out-Null }
}
#
function Set-NetDnsZoneUpdate {
    <#
    .SYNOPSIS
        Stellt die dynamischen Updates einer Zone ein.
    #>
    param([string]$Zone, [ValidateSet('', 'Secure', 'NonsecureAndSecure', 'None')][string]$Wert = '')
    if (-not (Test-NetDnsReady)) { return $false }
    $z = $null
    if ($Zone) { $z = @(Get-NetDnsZoneInfo -Art Primaer | Where-Object { $_.Name -eq $Zone }) | Select-Object -First 1 }
    else { $z = Select-NetDnsZone -Art Primaer -Titel 'Zone fuer dynamische Updates waehlen' }
    if (-not $z) { return $false }
    if (-not $Wert) {
        $optionen = @('Nur sicher (empfohlen)', 'Sicher und unsicher', 'Aus')
        $werte = @('Secure', 'NonsecureAndSecure', 'None')
        if (-not $z.AdIntegriert) { $optionen = @('Sicher und unsicher', 'Aus'); $werte = @('NonsecureAndSecure', 'None') }
        $i = Read-NetChoice -Frage ('Dynamische Updates fuer {0} (aktuell: {1})' -f $z.Name, (ConvertTo-NetDnsUpdateText -Wert $z.Updates)) -Optionen $optionen -Vorschlag 1
        if ($i -lt 0) { return $false }
        $Wert = $werte[$i]
    }
    if ($Wert -eq 'Secure' -and -not $z.AdIntegriert) {
        Write-Log -Level Fehler -Message 'Sichere Updates gibt es nur bei AD-integrierten Zonen (auf einem DC).'
        return $false
    }
    if ($z.Updates -eq $Wert) { Write-Log -Level OK -Message ('Die Zone {0} ist bereits so eingestellt.' -f $z.Name); return $true }
    $name = $z.Name
    $r = Invoke-NetChange -Titel "Dynamische Updates der Zone $name einstellen" -Stufe Bestaetigen -Vorher (ConvertTo-NetDnsUpdateText -Wert $z.Updates) -Nachher (ConvertTo-NetDnsUpdateText -Wert $Wert) -BackupBereich @('Dns') -Aktion {
        Set-DnsServerPrimaryZone -Name $name -DynamicUpdate $Wert
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerPrimaryZone'; Parameter = @{ Name = $name; DynamicUpdate = $z.Updates } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Remove-NetDnsZone {
    <#
    .SYNOPSIS
        Loescht eine Zone (Stufe Gefaehrlich: vorher Backup, Servername eintippen).
    #>
    if (-not (Test-NetDnsReady)) { return }
    $z = Select-NetDnsZone -Art Alle -Titel 'Welche Zone loeschen?'
    if (-not $z) { return }
    $name = $z.Name
    if ($name -like '_msdcs.*' -or $name -eq (Get-NetDomainName)) {
        Write-Log -Level Warn -Message 'Diese Zone gehoert zum Active Directory. Ohne sie funktioniert die Anmeldung an der Domaene nicht mehr!'
    }
    $anzahl = @(Get-NetDnsRecord -Zone $name).Count
    $r = Invoke-NetChange -Titel "DNS-Zone $name loeschen" -Stufe Gefaehrlich -Vorher @{ Zone = $name; Eintraege = $anzahl; Typ = $z.Typ } -Nachher '(Zone geloescht)' -BackupBereich @('Dns') `
        -Hinweis 'Alle Eintraege der Zone gehen verloren. Sie lassen sich nur aus dem Backup (CSV) wiederherstellen.' -Aktion {
        Remove-DnsServerZone -Name $name -Force
    }
    if ($r.Erfolg -and -not $r.Probelauf) { Write-Log -Level OK -Message "Zone $name geloescht. Wiederherstellung ueber das Backup-Menue (DNS-Eintraege aus CSV)." }
}
# ----------------------------------------------------------------------
# src/dns/DnsEintraege.ps1
# ----------------------------------------------------------------------
# DNS-Eintraege: A (optional mit PTR), AAAA, CNAME, MX, SRV, TXT, PTR anlegen, aendern, loeschen
# und suchen. Vor dem Anlegen wird auf Duplikate und Konflikte geprueft (idempotent).
#
$script:NetDnsTypen = @('A', 'AAAA', 'CNAME', 'MX', 'SRV', 'TXT', 'PTR')
#
function Test-NetIPv6Address {
    param([AllowEmptyString()][string]$Text)
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Text, [ref]$ip)) { return $false }
    return ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6)
}
#
function Test-NetDnsRecordName {
    <#
    .SYNOPSIS
        Prueft einen relativen Namen ('@' fuer die Zone selbst). Liefert $null oder den Grund.
    #>
    param([string]$Name, [switch]$Srv)
    if ($Name -eq '@') { return $null }
    if (-not $Name) { return 'Bitte einen Namen eingeben (oder @ fuer die Zone selbst).' }
    foreach ($teil in $Name.TrimEnd('.').Split('.')) {
        if ($Srv -and $teil -match '^_[A-Za-z0-9-]+$') { continue }
        if ($teil -eq '*') { continue }
        if (-not (Test-NetDnsLabel -Label $teil)) { return "Der Teil '$teil' ist ungueltig (a-z, 0-9, Bindestrich; bei SRV z. B. _sip._tcp)." }
    }
    return $null
}
#
function Read-NetDnsRecordData {
    <#
    .SYNOPSIS
        Fragt die Daten eines Eintragstyps ab und liefert eine Hashtable (oder $null bei Abbruch).
    #>
    param([Parameter(Mandatory = $true)][string]$Typ, [hashtable]$Vorschlag = @{})
    $fqdn = { param($t) if ((Test-NetDomainName -Name $t).Gueltig -or $t -match '^[A-Za-z0-9-]+$') { $null } else { 'Bitte einen gueltigen Namen eingeben, z. B. srv01.ad.firma.ch' } }
    switch ($Typ) {
        'A' {
            $ip = Read-NetIPAddress -Frage 'IPv4-Adresse' -Vorschlag ([string]$Vorschlag.IPv4Address)
            if (-not $ip) { return $null }
            return @{ IPv4Address = $ip }
        }
        'AAAA' {
            $ip = Read-NetText -Frage 'IPv6-Adresse' -Vorschlag ([string]$Vorschlag.IPv6Address) -Pruefung { param($t) if (Test-NetIPv6Address -Text $t) { $null } else { 'Keine gueltige IPv6-Adresse.' } }
            if (-not $ip) { return $null }
            return @{ IPv6Address = $ip }
        }
        'CNAME' {
            $ziel = Read-NetText -Frage 'Ziel (vollstaendiger Name, z. B. srv01.ad.firma.ch)' -Vorschlag ([string]$Vorschlag.HostNameAlias) -Pruefung $fqdn
            if (-not $ziel) { return $null }
            return @{ HostNameAlias = $ziel }
        }
        'MX' {
            $mx = Read-NetText -Frage 'Mailserver (vollstaendiger Name)' -Vorschlag ([string]$Vorschlag.MailExchange) -Pruefung $fqdn
            if (-not $mx) { return $null }
            $pref = Read-NetNumber -Frage 'Prioritaet (kleiner = bevorzugt)' -Minimum 0 -Maximum 65535 -Vorschlag $(if ($Vorschlag.Preference) { [int]$Vorschlag.Preference } else { 10 })
            if ($null -eq $pref) { return $null }
            return @{ MailExchange = $mx; Preference = $pref }
        }
        'SRV' {
            $ziel = Read-NetText -Frage 'Zielserver (vollstaendiger Name)' -Vorschlag ([string]$Vorschlag.DomainName) -Pruefung $fqdn
            if (-not $ziel) { return $null }
            $prio = Read-NetNumber -Frage 'Prioritaet' -Minimum 0 -Maximum 65535 -Vorschlag $(if ($null -ne $Vorschlag.Priority) { [int]$Vorschlag.Priority } else { 0 })
            if ($null -eq $prio) { return $null }
            $gew = Read-NetNumber -Frage 'Gewichtung' -Minimum 0 -Maximum 65535 -Vorschlag $(if ($null -ne $Vorschlag.Weight) { [int]$Vorschlag.Weight } else { 100 })
            if ($null -eq $gew) { return $null }
            $port = Read-NetNumber -Frage 'Port' -Minimum 1 -Maximum 65535 -Vorschlag $(if ($Vorschlag.Port) { [int]$Vorschlag.Port } else { $null })
            if ($null -eq $port) { return $null }
            return @{ DomainName = $ziel; Priority = $prio; Weight = $gew; Port = $port }
        }
        'TXT' {
            $text = Read-NetText -Frage 'Text (z. B. v=spf1 mx -all)' -Vorschlag ([string]$Vorschlag.DescriptiveText) -Pruefung { param($t) if ($t.Length -gt 255) { 'Hoechstens 255 Zeichen pro Text.' } else { $null } }
            if (-not $text) { return $null }
            return @{ DescriptiveText = $text }
        }
        'PTR' {
            $ziel = Read-NetText -Frage 'Name, auf den die Adresse zeigt (z. B. pc01.ad.firma.ch)' -Vorschlag ([string]$Vorschlag.PtrDomainName) -Pruefung $fqdn
            if (-not $ziel) { return $null }
            return @{ PtrDomainName = $ziel }
        }
    }
    return $null
}
#
function Test-NetDnsRecordConflict {
    <#
    .SYNOPSIS
        Prueft vor dem Anlegen auf Duplikat (gleiche Daten) und Konflikte (CNAME, andere Adresse).
    .OUTPUTS
        PSCustomObject mit Duplikat (bool), Konflikte (Liste), Vorhanden (Liste).
    #>
    param([Parameter(Mandatory = $true)][string]$Zone, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Typ, [Parameter(Mandatory = $true)][hashtable]$Daten)
    $vorhanden = @(Get-NetDnsRecord -Zone $Zone -Name $Name)
    $gleich = @($vorhanden | Where-Object { $_.Typ -eq $Typ -and (Test-NetDnsRecordEqual -A $Daten -B $_.Daten) })
    $konflikte = @()
    if ($Typ -eq 'CNAME') {
        $konflikte += @($vorhanden | Where-Object { $_.Typ -ne 'CNAME' -or -not (Test-NetDnsRecordEqual -A $Daten -B $_.Daten) } | ForEach-Object { '{0} {1} ist vorhanden - ein CNAME darf nicht neben anderen Eintraegen stehen.' -f $_.Typ, $_.Wert })
    }
    else {
        $konflikte += @($vorhanden | Where-Object { $_.Typ -eq 'CNAME' } | ForEach-Object { 'Der Name ist bereits ein CNAME auf {0}.' -f $_.Wert })
        if ($Typ -eq 'A' -or $Typ -eq 'AAAA' -or $Typ -eq 'PTR') {
            $konflikte += @($vorhanden | Where-Object { $_.Typ -eq $Typ -and -not (Test-NetDnsRecordEqual -A $Daten -B $_.Daten) } | ForEach-Object { 'Es gibt schon einen {0}-Eintrag mit {1}.' -f $_.Typ, $_.Wert })
        }
    }
    return [pscustomobject]@{ Duplikat = ($gleich.Count -gt 0); Konflikte = $konflikte; Vorhanden = $vorhanden }
}
#
function Add-NetDnsRecord {
    <#
    .SYNOPSIS
        Legt einen DNS-Eintrag an (mit Duplikat- und Konfliktpruefung, optional PTR zum A-Eintrag).
    #>
    param(
        [string]$Zone,
        [string]$Name,
        [ValidateSet('', 'A', 'AAAA', 'CNAME', 'MX', 'SRV', 'TXT', 'PTR')][string]$Typ = '',
        [hashtable]$Daten,
        [Nullable[bool]]$MitPtr = $null
    )
    if (-not (Test-NetDnsReady)) { return $false }
    if (-not $Typ) {
        $i = Read-NetChoice -Frage 'Welcher Eintragstyp?' -Optionen @(
            'A - Name zu IPv4-Adresse (optional mit PTR)', 'AAAA - Name zu IPv6-Adresse', 'CNAME - Alias auf einen anderen Namen',
            'MX - Mailserver', 'SRV - Dienst mit Port', 'TXT - Text (z. B. SPF)', 'PTR - Adresse zu Name') -Vorschlag 1
        if ($i -lt 0) { return $false }
        $Typ = $script:NetDnsTypen[$i]
    }
    if (-not $Zone) {
        $art = 'Forward'
        if ($Typ -eq 'PTR') { $art = 'Reverse' }
        $z = Select-NetDnsZone -Art $art -Titel 'In welche Zone?'
        if (-not $z) { return $false }
        $Zone = $z.Name
    }
    if (-not $Name) {
        $frage = 'Name (relativ zur Zone, @ = Zone selbst)'
        if ($Typ -eq 'PTR') { $frage = 'Letzte(s) Oktett(e) der Adresse in umgekehrter Reihenfolge (z. B. 50 fuer .50)' }
        if ($Typ -eq 'SRV') { $frage = 'Name, z. B. _sip._tcp' }
        $istSrv = ($Typ -eq 'SRV')
        $Name = Read-NetText -Frage $frage -Pruefung { param($t) Test-NetDnsRecordName -Name $t -Srv:$istSrv }
        if (-not $Name) { return $false }
    }
    if (-not $Daten) { $Daten = Read-NetDnsRecordData -Typ $Typ }
    if (-not $Daten) { return $false }
#
    $pruef = Test-NetDnsRecordConflict -Zone $Zone -Name $Name -Typ $Typ -Daten $Daten
    if ($pruef.Duplikat) {
        Write-Log -Level OK -Message ('Der Eintrag {0} {1} {2} existiert bereits in {3}. Nichts zu tun.' -f $Name, $Typ, (($Daten.Values | ForEach-Object { [string]$_ }) -join ' '), $Zone)
        return $true
    }
    foreach ($k in $pruef.Konflikte) { Write-Log -Level Warn -Message $k }
    if ($pruef.Konflikte.Count -gt 0 -and -not (Read-NetYesNo -Frage 'Trotzdem zusaetzlich anlegen?' -Vorschlag $false)) { return $false }
#
    $ptr = $false
    if ($Typ -eq 'A') {
        $reverse = Find-NetReverseZone -IPAddress $Daten.IPv4Address -ZoneNames @(Get-NetDnsZoneInfo -Art Reverse | ForEach-Object { $_.Name })
        if ($null -eq $MitPtr) {
            if ($reverse) { $MitPtr = Read-NetYesNo -Frage ('Passenden PTR-Eintrag in {0} mit anlegen?' -f $reverse) -Vorschlag $true }
            else { Write-Log -Level Warn -Message ('Fuer {0} gibt es keine Reverse-Zone, deshalb kein PTR. Tipp: DNS-Menue -> Zonen -> Fehlende Reverse-Zonen.' -f $Daten.IPv4Address); $MitPtr = $false }
        }
        $ptr = [bool]$MitPtr -and [bool]$reverse
    }
    $zoneName = $Zone
    $eintragName = $Name
    $eintragTyp = $Typ
    $eintragDaten = $Daten
    $rueck = @(@{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $eintragDaten } })
    if ($ptr) {
        $rz = Find-NetReverseZone -IPAddress $Daten.IPv4Address -ZoneNames @(Get-NetDnsZoneInfo -Art Reverse | ForEach-Object { $_.Name })
        $voll = $Name
        if ($Name -eq '@') { $voll = $Zone } else { $voll = $Name + '.' + $Zone }
        $rueck += @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $rz; Name = (Get-NetPtrName -IPAddress $Daten.IPv4Address -ZoneName $rz); Typ = 'PTR'; Daten = @{ PtrDomainName = $voll + '.' } } }
    }
    $anzeige = @{ Zone = $Zone; Name = $Name; Typ = $Typ; Wert = (($Daten.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Daten[$_] }) -join ', ') }
    if ($Typ -eq 'A') { $anzeige.PTR = $(if ($ptr) { 'ja' } else { 'nein' }) }
    $r = Invoke-NetChange -Titel ('DNS-Eintrag {0} ({1}) in {2} anlegen' -f $Name, $Typ, $Zone) -Stufe Bestaetigen -Vorher @($pruef.Vorhanden | ForEach-Object { '{0} {1}' -f $_.Typ, $_.Wert }) -Nachher $anzeige -BackupBereich @('Dns') -Aktion {
        Add-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $eintragDaten -CreatePtr:$ptr
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Select-NetDnsRecord {
    param([string]$Titel = 'Eintrag waehlen')
    $z = Select-NetDnsZone -Art Alle -Titel 'Zone waehlen'
    if (-not $z) { return $null }
    $filter = Read-NetText -Frage 'Nur Namen mit diesem Text zeigen (leer = alle)' -LeerErlaubt
    if ($null -eq $filter) { return $null }
    $liste = @(Get-NetDnsRecord -Zone $z.Name | Where-Object { $script:NetDnsTypen -contains $_.Typ -and (-not $filter -or $_.Name -like "*$filter*" -or $_.Wert -like "*$filter*") })
    return (Select-NetItem -Elemente $liste -Titel $Titel -Eigenschaften @('Name', 'Typ', 'Wert', 'Statisch'))
}
#
function Show-NetDnsRecord {
    if (-not (Test-NetDnsReady)) { return }
    $z = Select-NetDnsZone -Art Alle -Titel 'Eintraege welcher Zone anzeigen?'
    if (-not $z) { return }
    $liste = @(Get-NetDnsRecord -Zone $z.Name)
    Write-NetTitle -Titel ('Eintraege in {0} ({1})' -f $z.Name, $liste.Count)
    foreach ($e in ($liste | Sort-Object -Property Typ, Name)) {
        $alter = 'statisch'
        if (-not $e.Statisch) { $alter = 'dynamisch ' + $e.Zeitstempel.ToString('yyyy-MM-dd') }
        Write-Host ('  {0,-30} {1,-6} {2,-40} {3}' -f $e.Name, $e.Typ, $e.Wert, $alter)
    }
}
#
function Find-NetDnsRecord {
    <#
    .SYNOPSIS
        Sucht einen Namen oder eine Adresse in allen Zonen.
    #>
    param([string]$Suche)
    if (-not (Test-NetDnsReady)) { return }
    if (-not $Suche) { $Suche = Read-NetText -Frage 'Suchbegriff (Teil eines Namens oder einer Adresse)' }
    if (-not $Suche) { return }
    $treffer = @()
    foreach ($z in @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -ne 'Forwarder' })) {
        $treffer += @(Get-NetDnsRecord -Zone $z.Name | Where-Object { $_.Name -like "*$Suche*" -or $_.Wert -like "*$Suche*" })
    }
    Write-NetTitle -Titel ("Suche nach '{0}': {1} Treffer" -f $Suche, $treffer.Count)
    foreach ($e in $treffer) { Write-Host ('  {0,-28} {1,-25} {2,-6} {3}' -f $e.Zone, $e.Name, $e.Typ, $e.Wert) }
    return $treffer
}
#
function Remove-NetDnsRecord {
    <#
    .SYNOPSIS
        Loescht einen gewaehlten Eintrag (Gegenaktion: wieder anlegen).
    #>
    param([object]$Eintrag)
    if (-not (Test-NetDnsReady)) { return $false }
    if (-not $Eintrag) { $Eintrag = Select-NetDnsRecord -Titel 'Welchen Eintrag loeschen?' }
    if (-not $Eintrag) { return $false }
    if ($script:NetDnsTypen -notcontains $Eintrag.Typ) { Write-Log -Level Warn -Message 'Dieser Eintragstyp wird von Windows verwaltet und hier nicht geloescht.'; return $false }
    $zoneName = $Eintrag.Zone
    $eintragName = $Eintrag.Name
    $eintragTyp = $Eintrag.Typ
    $eintragDaten = $Eintrag.Daten
    $r = Invoke-NetChange -Titel ('DNS-Eintrag {0} ({1}) aus {2} loeschen' -f $eintragName, $eintragTyp, $zoneName) -Stufe Bestaetigen -Vorher ('{0} {1} {2}' -f $eintragName, $eintragTyp, $Eintrag.Wert) -Nachher '(geloescht)' -BackupBereich @('Dns') -Aktion {
        Remove-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $eintragDaten
    } -Rueckgaengig @{ Befehl = 'Add-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $eintragDaten } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Edit-NetDnsRecord {
    <#
    .SYNOPSIS
        Aendert die Daten eines Eintrags (alter Eintrag wird ersetzt, Gegenaktion stellt ihn wieder her).
    #>
    if (-not (Test-NetDnsReady)) { return $false }
    $alt = Select-NetDnsRecord -Titel 'Welchen Eintrag aendern?'
    if (-not $alt) { return $false }
    if ($script:NetDnsTypen -notcontains $alt.Typ) { Write-Log -Level Warn -Message 'Dieser Eintragstyp wird von Windows verwaltet und hier nicht geaendert.'; return $false }
    $neu = Read-NetDnsRecordData -Typ $alt.Typ -Vorschlag $alt.Daten
    if (-not $neu) { return $false }
    if (Test-NetDnsRecordEqual -A $neu -B $alt.Daten) { Write-Log -Level OK -Message 'Keine Aenderung.'; return $true }
    $zoneName = $alt.Zone
    $eintragName = $alt.Name
    $eintragTyp = $alt.Typ
    $altDaten = $alt.Daten
    $neuDaten = $neu
    $r = Invoke-NetChange -Titel ('DNS-Eintrag {0} ({1}) in {2} aendern' -f $eintragName, $eintragTyp, $zoneName) -Stufe Bestaetigen -Vorher $altDaten -Nachher $neuDaten -BackupBereich @('Dns') -Aktion {
        Add-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $neuDaten
        Remove-NetDnsRecordExact -ZoneName $zoneName -Name $eintragName -Typ $eintragTyp -Daten $altDaten
    } -Rueckgaengig @(
        @{ Befehl = 'Add-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $altDaten } },
        @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $zoneName; Name = $eintragName; Typ = $eintragTyp; Daten = $neuDaten } }
    )
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
# ----------------------------------------------------------------------
# src/dns/DnsWeiterleitung.ps1
# ----------------------------------------------------------------------
# Weiterleitungen (Forwarder) und bedingte Weiterleitungen. Erreichbarkeit wird mit
# Resolve-DnsName -Server getestet; ohne Internet gibt es nur eine Warnung.
#
$script:NetWeiterleitungHilfe = @'
Weiterleitung oder Stammhinweise?
  - Weiterleitung (Forwarder): Der DNS-Server fragt fuer alle fremden Namen einen bestimmten
    anderen DNS-Server, z. B. Quad9 (9.9.9.9, filtert Schadseiten), Cloudflare (1.1.1.1)
    oder den Router. Schnell und einfach; ueblich in kleinen und mittleren Netzen.
  - Stammhinweise (Root Hints): Ohne Weiterleitung fragt der DNS-Server selbst bei den
    Stammservern des Internets nach und hangelt sich durch. Braucht freien Zugang ueber Port 53.
  - Bedingte Weiterleitung: gilt nur fuer eine bestimmte Domaene, z. B. partner.local -> 10.1.1.10.
Wichtig: Clients und Mitgliedsserver fragen immer die DCs, nie direkt 8.8.8.8 o. ae.
'@
#
function Get-NetDnsForwarderList {
    $fw = Get-NetSafe -Beschreibung 'Get-DnsServerForwarder' -Abfrage { Get-DnsServerForwarder }
    if (-not $fw) { return @() }
    return @($fw.IPAddress | Where-Object { $_ } | ForEach-Object { ConvertTo-NetString -Wert $_ })
}
#
function Test-NetDnsForwarder {
    <#
    .SYNOPSIS
        Prueft, ob ein DNS-Server antwortet (Abfrage der Stammzone). Liefert $true/$false.
    #>
    param([Parameter(Mandatory = $true)][string]$Server)
    $antwort = Get-NetSafe -Beschreibung "Weiterleitung $Server" -Abfrage { Resolve-DnsName -Name '.' -Type NS -Server $Server -DnsOnly -QuickTimeout }
    return [bool]$antwort
}
#
function Show-NetDnsForwarder {
    if (-not (Test-NetDnsReady)) { return }
    Write-NetTitle -Titel 'Weiterleitungen'
    $liste = @(Get-NetDnsForwarderList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Keine Weiterleitung eingestellt: der Server verwendet die Stammhinweise.' }
    foreach ($ip in $liste) {
        if (Test-NetDnsForwarder -Server $ip) { Write-NetStatus -Status OK -Bereich $ip -Text 'antwortet' }
        else { Write-NetStatus -Status WARN -Bereich $ip -Text 'antwortet nicht (ohne Internet normal)' }
    }
    $bedingt = @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -eq 'Forwarder' })
    if ($bedingt.Count -gt 0) {
        Write-Host '  Bedingte Weiterleitungen:'
        foreach ($b in $bedingt) { Write-Host ('    {0}' -f $b.Name) }
    }
}
#
function Set-NetDnsForwarder {
    <#
    .SYNOPSIS
        Setzt die Weiterleitungen (Vorschlaege: Quad9, Cloudflare, Router oder eigene).
    #>
    param([string[]]$Adressen)
    if (-not (Test-NetDnsReady)) { return $false }
    $alt = @(Get-NetDnsForwarderList)
    if (-not $Adressen) {
        Write-NetText -Text $script:NetWeiterleitungHilfe
        $router = ''
        $z = Get-NetSetupState
        $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1
        if ($karte -and $karte.Gateway.Count -gt 0) { $router = $karte.Gateway[0] }
        $vorschlag = @(Get-NetConfigValue -Pfad 'Vorschlaege.Weiterleitungen' -Standard @('9.9.9.9', '1.1.1.1'))
        $optionen = @(
            ('Vorschlag aus den Einstellungen: ' + ($vorschlag -join ', ')),
            'Quad9: 9.9.9.9 und 149.112.112.112 (filtert bekannte Schadseiten)',
            'Cloudflare: 1.1.1.1 und 1.0.0.1')
        if ($router) { $optionen += ('Router: ' + $router) }
        $optionen += 'Eigene Adressen eingeben'
        $optionen += 'Alle Weiterleitungen entfernen (Stammhinweise verwenden)'
        $i = Read-NetChoice -Frage ('Weiterleitungen (aktuell: {0})' -f $(if ($alt.Count) { $alt -join ', ' } else { 'keine' })) -Optionen $optionen -Vorschlag 1
        if ($i -lt 0) { return $false }
        $text = $optionen[$i]
        if ($text -like 'Vorschlag*') { $Adressen = $vorschlag }
        elseif ($text -like 'Quad9*') { $Adressen = @('9.9.9.9', '149.112.112.112') }
        elseif ($text -like 'Cloudflare*') { $Adressen = @('1.1.1.1', '1.0.0.1') }
        elseif ($text -like 'Router*') { $Adressen = @($router) }
        elseif ($text -like 'Alle*') { $Adressen = @() }
        else {
            $eingabe = Read-NetText -Frage 'DNS-Server (mit Komma getrennt)' -Pruefung {
                param($t)
                foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
                return $null
            }
            if (-not $eingabe) { return $false }
            $Adressen = @($eingabe.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    $neu = @($Adressen)
    if (($alt -join ',') -eq ($neu -join ',')) { Write-Log -Level OK -Message 'Die Weiterleitungen sind bereits so eingestellt.'; return $true }
    foreach ($ip in $neu) {
        if (Test-NetDnsForwarder -Server $ip) { Write-NetStatus -Status OK -Bereich $ip -Text 'antwortet' }
        else { Write-NetStatus -Status WARN -Bereich $ip -Text 'antwortet nicht - ohne Internetzugang ist das normal, die Einstellung kann trotzdem gesetzt werden' }
    }
    if ($neu.Count -eq 0) {
        $r = Invoke-NetChange -Titel 'Alle Weiterleitungen entfernen' -Stufe Bestaetigen -Vorher ($alt -join ', ') -Nachher '(Stammhinweise)' -BackupBereich @('Dns') -Aktion {
            Remove-DnsServerForwarder -IPAddress $alt -Force
        } -Rueckgaengig @{ Befehl = 'Set-DnsServerForwarder'; Parameter = @{ IPAddress = $alt } }
    }
    else {
        $rueck = @{ Befehl = 'Set-DnsServerForwarder'; Parameter = @{ IPAddress = $alt } }
        if ($alt.Count -eq 0) { $rueck = @{ Befehl = 'Remove-DnsServerForwarder'; Parameter = @{ IPAddress = $neu; Force = $true } } }
        $r = Invoke-NetChange -Titel 'Weiterleitungen setzen' -Stufe Bestaetigen -Vorher $(if ($alt.Count) { $alt -join ', ' } else { '(keine - Stammhinweise)' }) -Nachher ($neu -join ', ') -BackupBereich @('Dns') -Aktion {
            Set-DnsServerForwarder -IPAddress $neu
        } -Rueckgaengig $rueck
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Add-NetDnsConditionalForwarder {
    if (-not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text 'Bedingte Weiterleitung: Anfragen fuer eine bestimmte Domaene gehen an bestimmte DNS-Server (z. B. Partnerfirma, zweite Gesamtstruktur).'
    $name = Read-NetText -Frage 'Domaene (z. B. partner.local)' -Pruefung { param($t) if ($t -match '^[A-Za-z0-9.-]+$' -and $t.Contains('.')) { $null } else { 'Bitte einen Domaenennamen wie partner.local eingeben.' } }
    if (-not $name) { return $false }
    $name = $name.ToLower().TrimEnd('.')
    if (Get-NetSafe -Beschreibung "Zone $name" -Abfrage { Get-DnsServerZone -Name $name }) {
        Write-Log -Level Warn -Message "Fuer $name gibt es bereits eine Zone oder Weiterleitung. Nichts zu tun."
        return $true
    }
    $text = Read-NetText -Frage 'DNS-Server dieser Domaene (mit Komma getrennt)' -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $text) { return $false }
    $server = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($ip in $server) {
        if (-not (Test-NetDnsForwarder -Server $ip)) { Write-Log -Level Warn -Message "$ip antwortet nicht. Die Weiterleitung wird trotzdem angelegt." }
    }
    $p = @{ Name = $name; MasterServers = $server }
    if (Test-NetIsDomainController) { $p.ReplicationScope = 'Domain' }
    $r = Invoke-NetChange -Titel "Bedingte Weiterleitung fuer $name anlegen" -Stufe Bestaetigen -Vorher '(keine)' -Nachher @{ Domaene = $name; Server = ($server -join ', ') } -BackupBereich @('Dns') -Aktion {
        Add-DnsServerConditionalForwarderZone @p
    } -Rueckgaengig @{ Befehl = 'Remove-DnsServerZone'; Parameter = @{ Name = $name; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Remove-NetDnsConditionalForwarder {
    if (-not (Test-NetDnsReady)) { return }
    $liste = @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -eq 'Forwarder' })
    $z = Select-NetItem -Elemente $liste -Titel 'Welche bedingte Weiterleitung entfernen?' -Eigenschaften @('Name', 'Replikation')
    if (-not $z) { return }
    $name = $z.Name
    Invoke-NetChange -Titel "Bedingte Weiterleitung $name entfernen" -Stufe Gefaehrlich -Vorher $name -Nachher '(entfernt)' -BackupBereich @('Dns') -Aktion {
        Remove-DnsServerZone -Name $name -Force
    } | Out-Null
}
#
function Show-NetDnsForwarderMenu {
    $eintraege = @(
        @{ Text = 'Weiterleitungen anzeigen und testen'; Aktion = 'Show-NetDnsForwarder'; Hilfe = 'Zeigt die Weiterleitungen und prueft, ob sie antworten. Ohne Internet antworten externe Server nicht - das ist dann normal.' },
        @{ Text = 'Weiterleitungen setzen'; Aktion = { Set-NetDnsForwarder | Out-Null }; Hilfe = "Vorschlaege: Quad9 (9.9.9.9), Cloudflare (1.1.1.1) oder der Router.`nVorher/Nachher wird angezeigt, die alte Einstellung kann rueckgaengig gemacht werden." },
        @{ Text = 'Bedingte Weiterleitung anlegen'; Aktion = { Add-NetDnsConditionalForwarder | Out-Null }; Hilfe = 'Nur fuer eine bestimmte Domaene an bestimmte DNS-Server weiterleiten (z. B. Partnerfirma).' },
        @{ Text = 'Bedingte Weiterleitung entfernen'; Aktion = 'Remove-NetDnsConditionalForwarder'; Hilfe = 'Entfernt eine bedingte Weiterleitung (gefaehrlich: vorher Backup, Servername eintippen).' },
        @{ Text = 'Erklaerung: Weiterleitung oder Stammhinweise?'; Aktion = { Write-NetText -Text $script:NetWeiterleitungHilfe }; Hilfe = 'Erklaert den Unterschied zwischen Weiterleitung, Stammhinweisen und bedingter Weiterleitung.' }
    )
    Show-NetMenu -Titel 'DNS - Weiterleitungen' -Eintraege $eintraege -Einleitung $script:NetWeiterleitungHilfe
}
# ----------------------------------------------------------------------
# src/dns/DnsAging.ps1
# ----------------------------------------------------------------------
# Aging und Scavenging: alte, dynamisch eingetragene DNS-Eintraege automatisch entfernen.
# Assistent mit Vorschlag "an, 7 + 7 Tage" und Modus "nur melden" (veraltete Eintraege auflisten).
#
$script:NetAgingHilfe = @'
Aging/Scavenging raeumt alte, automatisch eingetragene DNS-Eintraege auf (z. B. von Laptops,
die laengst weg sind). Statische Eintraege werden nie geloescht.
  - No-Refresh-Intervall: so lange wird ein frischer Eintrag nicht erneut gestempelt.
  - Refresh-Intervall: danach darf der Client ihn erneuern. Wer in No-Refresh + Refresh nicht
    erneuert, gilt als veraltet und wird beim naechsten Aufraeumen geloescht.
  - Vorschlag: an, 7 + 7 Tage, Aufraeumen alle 7 Tage.
  - Wichtig: No-Refresh + Refresh muss mindestens so lang sein wie die DHCP-Lease-Dauer,
    sonst werden Eintraege aktiver Clients geloescht. Bei 8 Tagen Lease passen 7 + 7 Tage.
  - "Nur melden" zeigt, was geloescht wuerde, ohne etwas zu loeschen.
'@
#
function ConvertTo-NetTimeSpan {
    param([AllowNull()][object]$Wert)
    if ($null -eq $Wert) { return [TimeSpan]::Zero }
    if ($Wert -is [TimeSpan]) { return $Wert }
    $ts = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse([string]$Wert, [ref]$ts)) { return $ts }
    return [TimeSpan]::Zero
}
#
function Get-NetMaxLeaseDuration {
    param([hashtable]$Zustand = $script:NS.Zustand)
    $max = 0
    if ($Zustand -and $Zustand.Dhcp) {
        foreach ($s in @($Zustand.Dhcp.Scopes)) { if ($s.LeaseTage -gt $max) { $max = [double]$s.LeaseTage } }
    }
    return $max
}
#
function Show-NetDnsAging {
    if (-not (Test-NetDnsReady)) { return }
    Write-NetTitle -Titel 'Aging und Scavenging'
    $sc = Get-NetSafe -Beschreibung 'Get-DnsServerScavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc) {
        Write-Host ('  Server: Aufraeumen {0}, alle {1} Tage, No-Refresh {2} Tage, Refresh {3} Tage' -f $(if ($sc.ScavengingState) { 'AN' } else { 'aus' }), (ConvertTo-NetTimeSpan $sc.ScavengingInterval).TotalDays, (ConvertTo-NetTimeSpan $sc.NoRefreshInterval).TotalDays, (ConvertTo-NetTimeSpan $sc.RefreshInterval).TotalDays)
        if ($sc.LastScavengeTime) { Write-Host ('  Zuletzt aufgeraeumt: {0}' -f $sc.LastScavengeTime) }
    }
    foreach ($z in @(Get-NetDnsZoneInfo -Art Primaer)) {
        $name = $z.Name
        $a = Get-NetSafe -Beschreibung "Aging $name" -Abfrage { Get-DnsServerZoneAging -Name $name }
        if ($a) { Write-Host ('  Zone {0,-35} Aging {1,-4} No-Refresh {2,4} Tage, Refresh {3,4} Tage' -f $name, $(if ($a.AgingEnabled) { 'an' } else { 'aus' }), (ConvertTo-NetTimeSpan $a.NoRefreshInterval).TotalDays, (ConvertTo-NetTimeSpan $a.RefreshInterval).TotalDays) }
    }
    $lease = Get-NetMaxLeaseDuration -Zustand (Get-NetSetupState)
    if ($lease -gt 0 -and $sc -and ((ConvertTo-NetTimeSpan $sc.NoRefreshInterval).TotalDays + (ConvertTo-NetTimeSpan $sc.RefreshInterval).TotalDays) -lt $lease) {
        Write-Log -Level Warn -Message ('No-Refresh + Refresh ist kuerzer als die laengste Lease-Dauer ({0} Tage).' -f $lease)
    }
}
#
function Get-NetStaleDnsRecord {
    <#
    .SYNOPSIS
        Listet veraltete dynamische Eintraege (aelter als No-Refresh + Refresh), ohne etwas zu loeschen.
    #>
    param([int]$NoRefreshTage = 7, [int]$RefreshTage = 7)
    $grenze = (Get-Date).AddDays( - ($NoRefreshTage + $RefreshTage))
    $liste = @()
    foreach ($z in @(Get-NetDnsZoneInfo -Art Primaer)) {
        $liste += @(Get-NetDnsRecord -Zone $z.Name | Where-Object { -not $_.Statisch -and $_.Zeitstempel -lt $grenze -and @('A', 'AAAA', 'PTR', 'CNAME') -contains $_.Typ })
    }
    return $liste
}
#
function Show-NetStaleDnsRecord {
    <#
    .SYNOPSIS
        Modus "nur melden": zeigt veraltete Eintraege und speichert sie als CSV im Ordner Berichte.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $nr = [int](Get-NetConfigValue -Pfad 'Vorschlaege.NoRefreshTage' -Standard 7)
    $rf = [int](Get-NetConfigValue -Pfad 'Vorschlaege.RefreshTage' -Standard 7)
    $liste = @(Get-NetStaleDnsRecord -NoRefreshTage $nr -RefreshTage $rf)
    Write-NetTitle -Titel ('Veraltete Eintraege (aelter als {0} Tage) - es wird nichts geloescht' -f ($nr + $rf))
    if ($liste.Count -eq 0) { Write-Log -Level OK -Message 'Keine veralteten dynamischen Eintraege gefunden.'; return }
    foreach ($e in $liste) { Write-Host ('  {0,-28} {1,-25} {2,-6} {3,-18} zuletzt {4}' -f $e.Zone, $e.Name, $e.Typ, $e.Wert, $e.Zeitstempel.ToString('yyyy-MM-dd')) }
    $datei = Join-Path -Path (Get-NetPath -Name Berichte) -ChildPath ('DNS_veraltet_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $liste | Select-Object -Property Zone, Name, Typ, Wert, Zeitstempel | Export-Csv -Path $datei -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Log -Level OK -Message ('{0} veraltete Eintraege, Liste gespeichert: {1}' -f $liste.Count, $datei)
    }
    catch { Write-NetError -Fehler $_ -Titel 'Liste speichern' | Out-Null }
}
#
function Set-NetDnsScavenging {
    <#
    .SYNOPSIS
        Assistent: Aging/Scavenging auf Server- und Zonenebene einstellen.
    #>
    param([Nullable[bool]]$Aktiv = $null, [int]$NoRefreshTage = 0, [int]$RefreshTage = 0)
    if (-not (Test-NetDnsReady)) { return $false }
    if ($null -eq $Aktiv) {
        Write-NetText -Text $script:NetAgingHilfe
        $i = Read-NetChoice -Frage 'Was soll passieren?' -Optionen @(
            'Aufraeumen einschalten (Server und alle Zonen) - Vorschlag',
            'Nur melden: veraltete Eintraege auflisten, nichts loeschen',
            'Aufraeumen ausschalten') -Vorschlag 1
        if ($i -lt 0) { return $false }
        if ($i -eq 1) { Show-NetStaleDnsRecord; return $true }
        $Aktiv = ($i -eq 0)
    }
    $vorNr = [int](Get-NetConfigValue -Pfad 'Vorschlaege.NoRefreshTage' -Standard 7)
    $vorRf = [int](Get-NetConfigValue -Pfad 'Vorschlaege.RefreshTage' -Standard 7)
    if ($Aktiv -and $NoRefreshTage -le 0) {
        $NoRefreshTage = Read-NetNumber -Frage 'No-Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag $vorNr
        if ($null -eq $NoRefreshTage) { return $false }
        $RefreshTage = Read-NetNumber -Frage 'Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag $vorRf
        if ($null -eq $RefreshTage) { return $false }
    }
    if ($NoRefreshTage -le 0) { $NoRefreshTage = $vorNr }
    if ($RefreshTage -le 0) { $RefreshTage = $vorRf }
    $lease = Get-NetMaxLeaseDuration -Zustand (Get-NetSetupState)
    if ($Aktiv -and $lease -gt 0 -and ($NoRefreshTage + $RefreshTage) -lt $lease) {
        Write-Log -Level Warn -Message ('No-Refresh + Refresh ({0} Tage) ist kuerzer als die Lease-Dauer ({1} Tage). Dann wuerden Eintraege aktiver Clients geloescht.' -f ($NoRefreshTage + $RefreshTage), $lease)
        if (-not (Read-NetYesNo -Frage 'Trotzdem so einstellen?' -Vorschlag $false)) { return $false }
    }
    $alt = Get-NetSafe -Beschreibung 'Get-DnsServerScavenging' -Abfrage { Get-DnsServerScavenging }
    $altZustand = @{ Aktiv = $false; Intervall = '7.00:00:00'; NoRefresh = '7.00:00:00'; Refresh = '7.00:00:00' }
    if ($alt) {
        $altZustand = @{ Aktiv = [bool]$alt.ScavengingState; Intervall = (ConvertTo-NetTimeSpan $alt.ScavengingInterval).ToString(); NoRefresh = (ConvertTo-NetTimeSpan $alt.NoRefreshInterval).ToString(); Refresh = (ConvertTo-NetTimeSpan $alt.RefreshInterval).ToString() }
    }
    $nr = [TimeSpan]::FromDays($NoRefreshTage)
    $rf = [TimeSpan]::FromDays($RefreshTage)
    $intervall = [TimeSpan]::FromDays(7)
    $neuAktiv = [bool]$Aktiv
    if ($altZustand.Aktiv -eq $neuAktiv -and $altZustand.NoRefresh -eq $nr.ToString() -and $altZustand.Refresh -eq $rf.ToString() -and (-not $neuAktiv -or $altZustand.Intervall -eq $intervall.ToString())) {
        Write-Log -Level OK -Message 'Aging/Scavenging ist bereits so eingestellt.'
        return $true
    }
    $zonen = @(Get-NetDnsZoneInfo -Art Primaer | Where-Object { $_.Updates -ne 'None' } | ForEach-Object { $_.Name })
    $r = Invoke-NetChange -Titel ('Aging/Scavenging {0}' -f $(if ($neuAktiv) { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen `
        -Vorher @{ Aufraeumen = $(if ($altZustand.Aktiv) { 'an' } else { 'aus' }); 'No-Refresh' = $altZustand.NoRefresh; Refresh = $altZustand.Refresh } `
        -Nachher @{ Aufraeumen = $(if ($neuAktiv) { 'an, alle 7 Tage' } else { 'aus' }); 'No-Refresh' = $nr.ToString(); Refresh = $rf.ToString(); Zonen = ($zonen -join ', ') } -BackupBereich @('Dns') -Aktion {
        if ($neuAktiv) {
            Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval $intervall -NoRefreshInterval $nr -RefreshInterval $rf -ApplyOnAllZones
            foreach ($zone in $zonen) { Set-DnsServerZoneAging -Name $zone -Aging $true -NoRefreshInterval $nr -RefreshInterval $rf }
        }
        else {
            Set-DnsServerScavenging -ScavengingState $false
        }
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerScavenging'; Parameter = @{ ScavengingState = $altZustand.Aktiv; ScavengingInterval = $altZustand.Intervall; NoRefreshInterval = $altZustand.NoRefresh; RefreshInterval = $altZustand.Refresh } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Set-NetDnsZoneAgingOne {
    <#
    .SYNOPSIS
        Aging fuer eine einzelne Zone ein- oder ausschalten.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $z = Select-NetDnsZone -Art Primaer -Titel 'Aging fuer welche Zone?'
    if (-not $z) { return }
    $name = $z.Name
    $alt = Get-NetSafe -Beschreibung "Aging $name" -Abfrage { Get-DnsServerZoneAging -Name $name }
    $altAn = $false
    if ($alt) { $altAn = [bool]$alt.AgingEnabled }
    $an = Read-NetYesNo -Frage ("Aging fuer {0} einschalten? (aktuell {1})" -f $name, $(if ($altAn) { 'an' } else { 'aus' })) -Vorschlag $true
    if ($an -eq $altAn) { Write-Log -Level OK -Message 'Keine Aenderung noetig.'; return }
    $nr = [TimeSpan]::FromDays([int](Get-NetConfigValue -Pfad 'Vorschlaege.NoRefreshTage' -Standard 7))
    $rf = [TimeSpan]::FromDays([int](Get-NetConfigValue -Pfad 'Vorschlaege.RefreshTage' -Standard 7))
    Invoke-NetChange -Titel "Aging der Zone $name $(if ($an) { 'einschalten' } else { 'ausschalten' })" -Stufe Bestaetigen -Vorher $(if ($altAn) { 'an' } else { 'aus' }) -Nachher $(if ($an) { 'an' } else { 'aus' }) -BackupBereich @('Dns') -Aktion {
        if ($an) { Set-DnsServerZoneAging -Name $name -Aging $true -NoRefreshInterval $nr -RefreshInterval $rf }
        else { Set-DnsServerZoneAging -Name $name -Aging $false }
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerZoneAging'; Parameter = @{ Name = $name; Aging = $altAn } } | Out-Null
}
#
function Show-NetDnsAgingMenu {
    $eintraege = @(
        @{ Text = 'Einstellungen anzeigen'; Aktion = 'Show-NetDnsAging'; Hilfe = 'Zeigt Aging/Scavenging auf Server- und Zonenebene und vergleicht mit der DHCP-Lease-Dauer.' },
        @{ Text = 'Assistent (Vorschlag: an, 7 + 7 Tage)'; Aktion = { Set-NetDnsScavenging | Out-Null }; Hilfe = $script:NetAgingHilfe },
        @{ Text = 'Nur melden: veraltete Eintraege auflisten'; Aktion = 'Show-NetStaleDnsRecord'; Hilfe = 'Zeigt, welche dynamischen Eintraege beim Aufraeumen geloescht wuerden, und speichert die Liste als CSV. Es wird nichts geloescht.' },
        @{ Text = 'Aging einer einzelnen Zone'; Aktion = 'Set-NetDnsZoneAgingOne'; Hilfe = 'Schaltet Aging nur fuer eine Zone ein oder aus.' }
    )
    Show-NetMenu -Titel 'DNS - Aufraeumen alter Eintraege' -Eintraege $eintraege -Einleitung $script:NetAgingHilfe
}
# ----------------------------------------------------------------------
# src/dns/DnsMenue.ps1
# ----------------------------------------------------------------------
# DNS: Abhoer-IP-Adressen, Uebersicht, Einrichtungs-Assistent und Menue.
#
function Get-NetDnsListenAddress {
    $s = Get-NetSafe -Beschreibung 'Get-DnsServerSetting' -Abfrage { Get-DnsServerSetting -All }
    if (-not $s -or -not $s.ListeningIPAddress) { return @() }
    return @($s.ListeningIPAddress | ForEach-Object { ConvertTo-NetString -Wert $_ })
}
#
function Set-NetDnsListenAddress {
    <#
    .SYNOPSIS
        Setzt die Abhoer-IP-Adressen (leer = alle). Wird auch als Gegenaktion verwendet.
    #>
    param([AllowEmptyCollection()][string[]]$Adressen = @())
    $s = Get-DnsServerSetting -All
    $s.ListeningIPAddress = @($Adressen)
    Set-DnsServerSetting -InputObject $s
}
#
function Edit-NetDnsListenAddress {
    <#
    .SYNOPSIS
        Prueft und stellt ein, auf welchen Adressen der DNS-Server antwortet.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $z = Get-NetSetupState
    $eigene = @($z.Netzwerk.EigeneIPs)
    $alt = @(Get-NetDnsListenAddress)
    Write-NetTitle -Titel 'Abhoer-IP-Adressen des DNS-Servers'
    if ($alt.Count -eq 0) { Write-Log -Message 'Der DNS-Server antwortet auf allen Adressen des Servers (Standard).' }
    else { Write-Log -Message ('Der DNS-Server antwortet nur auf: ' + ($alt -join ', ')) }
    $fremd = @($alt | Where-Object { $eigene -notcontains $_ -and $_ -notmatch ':' })
    if ($fremd.Count -gt 0) { Write-Log -Level Warn -Message ('Diese Adressen gibt es auf dem Server nicht (mehr): ' + ($fremd -join ', ')) }
    if (@($alt | Where-Object { $_ -like '169.254.*' }).Count -gt 0) { Write-Log -Level Warn -Message 'Eine APIPA-Adresse (169.254.x.x) ist eingetragen. Das deutet auf eine falsch konfigurierte Netzwerkkarte hin.' }
    $i = Read-NetChoice -Frage 'Einstellung' -Optionen @('Alle Adressen des Servers (empfohlen)', 'Nur bestimmte Adressen waehlen', 'Nichts aendern') -Vorschlag 3
    if ($i -lt 0 -or $i -eq 2) { return }
    $neu = @()
    if ($i -eq 1) {
        $wahl = @(Select-NetItem -Elemente $eigene -Titel 'Auf welchen Adressen soll DNS antworten?' -Mehrfach)
        if ($wahl.Count -eq 0) { return }
        $neu = @($wahl | ForEach-Object { [string]$_ })
    }
    if (($alt -join ',') -eq ($neu -join ',')) { Write-Log -Level OK -Message 'Bereits so eingestellt.'; return }
    Invoke-NetChange -Titel 'Abhoer-IP-Adressen des DNS-Servers einstellen' -Stufe Bestaetigen -Vorher $(if ($alt.Count) { $alt -join ', ' } else { 'alle' }) -Nachher $(if ($neu.Count) { $neu -join ', ' } else { 'alle' }) -BackupBereich @('Dns') -Aktion {
        Set-NetDnsListenAddress -Adressen $neu
    } -Rueckgaengig @{ Befehl = 'Set-NetDnsListenAddress'; Parameter = @{ Adressen = $alt } } | Out-Null
}
#
function Show-NetDnsOverview {
    if (-not (Test-NetDnsReady)) { return }
    Show-NetDnsZone
    Write-Host ''
    $fw = @(Get-NetDnsForwarderList)
    Write-Host ('  Weiterleitungen : {0}' -f $(if ($fw.Count) { $fw -join ', ' } else { 'keine (Stammhinweise)' }))
    $sc = Get-NetSafe -Beschreibung 'Scavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc) { Write-Host ('  Aufraeumen      : {0}' -f $(if ($sc.ScavengingState) { 'an' } else { 'aus' })) }
    $abh = @(Get-NetDnsListenAddress)
    Write-Host ('  Abhoer-Adressen : {0}' -f $(if ($abh.Count) { $abh -join ', ' } else { 'alle' }))
    $fehlend = @(Get-NetMissingReverseZone)
    if ($fehlend.Count -gt 0) { Write-Log -Level Warn -Message ('Fehlende Reverse-Zonen: ' + (($fehlend | ForEach-Object { $_.Zone }) -join ', ')) }
}
#
function Start-NetDnsSetup {
    <#
    .SYNOPSIS
        Assistent: DNS einrichten (Rolle, Forward-Zone, Reverse-Zonen, Weiterleitungen, Aufraeumen).
        Ueberspringt alles, was schon passt.
    #>
    Write-NetTitle -Titel 'DNS einrichten'
    if (-not (Test-NetDnsReady)) { return }
    $z = Get-NetSetupState
    $forward = @($z.Dns.Zonen | Where-Object { -not $_.Reverse -and $_.Typ -eq 'Primary' -and $_.Name -notlike '_msdcs.*' })
    if ($forward.Count -eq 0) {
        Write-Log -Level Warn -Message 'Es gibt noch keine Forward-Zone.'
        if (Read-NetYesNo -Frage 'Jetzt eine Forward-Zone anlegen?' -Vorschlag $true) { New-NetDnsForwardZone }
    }
    else { Write-Log -Level OK -Message ('Forward-Zone(n): ' + (($forward | ForEach-Object { $_.Name }) -join ', ')) }
    foreach ($f in $forward) {
        if ($f.DynUpdate -eq 'None') {
            Write-Log -Level Warn -Message ('In der Zone {0} sind dynamische Updates aus. Clients und DHCP koennen sich dann nicht eintragen.' -f $f.Name)
            if (Read-NetYesNo -Frage 'Dynamische Updates einschalten?' -Vorschlag $true) {
                $wert = 'NonsecureAndSecure'
                if ($f.AdIntegriert) { $wert = 'Secure' }
                Set-NetDnsZoneUpdate -Zone $f.Name -Wert $wert | Out-Null
            }
        }
    }
    $fehlend = @(Get-NetMissingReverseZone -Zustand (Get-NetSetupState))
    if ($fehlend.Count -gt 0) { Add-NetMissingReverseZone }
    else { Write-Log -Level OK -Message 'Reverse-Zonen fuer alle Netze vorhanden.' }
    if (@(Get-NetDnsForwarderList).Count -eq 0) {
        Write-Log -Level Warn -Message 'Es ist keine Weiterleitung eingestellt.'
        if (Read-NetYesNo -Frage 'Jetzt Weiterleitungen einstellen?' -Vorschlag $true) { Set-NetDnsForwarder | Out-Null }
    }
    else { Write-Log -Level OK -Message ('Weiterleitungen: ' + (@(Get-NetDnsForwarderList) -join ', ')) }
    $sc = Get-NetSafe -Beschreibung 'Scavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc -and -not $sc.ScavengingState) {
        Write-Log -Level Warn -Message 'Das Aufraeumen alter Eintraege (Scavenging) ist aus.'
        if (Read-NetYesNo -Frage 'Mit Vorschlag 7 + 7 Tage einschalten?' -Vorschlag $true) { Set-NetDnsScavenging -Aktiv $true | Out-Null }
    }
    Write-Log -Level OK -Message 'DNS-Einrichtung abgeschlossen.'
}
#
function Show-NetDnsZoneMenu {
    $eintraege = @(
        @{ Text = 'Zonen anzeigen'; Aktion = 'Show-NetDnsZone'; Hilfe = 'Alle Zonen mit Typ, Speicherung (AD oder Datei) und dynamischen Updates.' },
        @{ Text = 'Forward-Zone anlegen'; Aktion = 'New-NetDnsForwardZone'; Hilfe = "Zone fuer Namen -> Adressen. Auf einem DC AD-integriert (Replikation Domain oder Forest), sonst als Datei.`nExistiert die Zone schon, passiert nichts." },
        @{ Text = 'Reverse-Zone anlegen'; Aktion = { New-NetDnsReverseZone }; Hilfe = 'Zone fuer Adressen -> Namen (PTR) eines Netzes, z. B. 1.168.192.in-addr.arpa fuer 192.168.1.0/24.' },
        @{ Text = 'Fehlende Reverse-Zonen vorschlagen'; Aktion = 'Add-NetMissingReverseZone'; Hilfe = 'Prueft das Netz des Servers und alle DHCP-Scopes und schlaegt fehlende Reverse-Zonen vor.' },
        @{ Text = 'Dynamische Updates einstellen'; Aktion = { Set-NetDnsZoneUpdate | Out-Null }; Hilfe = 'Nur sicher (empfohlen, nur AD-Zonen), sicher und unsicher, oder aus.' },
        @{ Text = 'Zone loeschen (gefaehrlich)'; Aktion = 'Remove-NetDnsZone'; Hilfe = 'Loescht eine Zone mit allen Eintraegen. Vorher wird automatisch gesichert; der Servername muss eingetippt werden.' }
    )
    Show-NetMenu -Titel 'DNS - Zonen' -Eintraege $eintraege
}
#
function Show-NetDnsRecordMenu {
    $eintraege = @(
        @{ Text = 'Eintraege einer Zone anzeigen'; Aktion = 'Show-NetDnsRecord'; Hilfe = 'Listet alle Eintraege einer Zone, mit statisch/dynamisch und Zeitstempel.' },
        @{ Text = 'Eintrag suchen'; Aktion = { Find-NetDnsRecord | Out-Null }; Hilfe = 'Sucht einen Namen oder eine Adresse in allen Zonen.' },
        @{ Text = 'Eintrag anlegen (A, AAAA, CNAME, MX, SRV, TXT, PTR)'; Aktion = { Add-NetDnsRecord | Out-Null }; Hilfe = "Legt einen Eintrag an. Vorher wird geprueft, ob es ihn schon gibt (dann passiert nichts) oder ob er mit einem anderen kollidiert.`nA-Eintraege koennen gleich den passenden PTR bekommen." },
        @{ Text = 'Eintrag aendern'; Aktion = { Edit-NetDnsRecord | Out-Null }; Hilfe = 'Aendert die Daten eines Eintrags (z. B. neue IP). Vorher/Nachher wird angezeigt, rueckgaengig moeglich.' },
        @{ Text = 'Eintrag loeschen'; Aktion = { Remove-NetDnsRecord | Out-Null }; Hilfe = 'Loescht genau einen Eintrag. Die Gegenaktion (wieder anlegen) wird gemerkt.' }
    )
    Show-NetMenu -Titel 'DNS - Eintraege' -Eintraege $eintraege
}
#
function Show-NetDnsMenu {
    $eintraege = @(
        @{ Text = 'Uebersicht'; Aktion = 'Show-NetDnsOverview'; Hilfe = 'Zonen, Weiterleitungen, Aufraeumen, Abhoer-Adressen und fehlende Reverse-Zonen auf einen Blick.' },
        @{ Text = 'DNS einrichten (Assistent)'; Aktion = 'Start-NetDnsSetup'; Hilfe = 'Prueft Rolle, Forward-Zone, dynamische Updates, Reverse-Zonen, Weiterleitungen und Aufraeumen und bietet an, was fehlt. Erledigtes wird uebersprungen.' },
        @{ Text = 'Zonen'; Aktion = 'Show-NetDnsZoneMenu'; OhnePause = $true; Hilfe = 'Zonen anzeigen, anlegen, dynamische Updates, fehlende Reverse-Zonen, loeschen.' },
        @{ Text = 'Eintraege'; Aktion = 'Show-NetDnsRecordMenu'; OhnePause = $true; Hilfe = 'Eintraege anzeigen, suchen, anlegen, aendern, loeschen.' },
        @{ Text = 'Weiterleitungen'; Aktion = 'Show-NetDnsForwarderMenu'; OhnePause = $true; Hilfe = 'Weiterleitungen (Quad9, Cloudflare, Router) und bedingte Weiterleitungen. Erklaert auch den Unterschied zu den Stammhinweisen.' },
        @{ Text = 'Aufraeumen alter Eintraege (Aging/Scavenging)'; Aktion = 'Show-NetDnsAgingMenu'; OhnePause = $true; Hilfe = 'Assistent mit Vorschlag 7 + 7 Tage, Erklaerung zur Lease-Dauer und Modus "nur melden".' },
        @{ Text = 'Abhoer-IP-Adressen'; Aktion = 'Edit-NetDnsListenAddress'; Hilfe = 'Auf welchen Adressen der DNS-Server antwortet. Empfohlen: alle festen Adressen des Servers.' },
        @{ Text = 'DNS-Rolle installieren / pruefen'; Aktion = { Install-NetDnsRole | Out-Null }; Hilfe = 'Installiert die DNS-Server-Rolle und die Verwaltungstools aus dem lokalen Windows, falls sie fehlen.' }
    )
    Show-NetMenu -Titel 'DNS' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/dhcp/DhcpBasis.ps1
# ----------------------------------------------------------------------
# DHCP-Grundlagen: Rolle installieren und nachkonfigurieren, Autorisierung im AD, Bindungen.
#
function Test-NetEnterpriseAdmin {
    <#
    .SYNOPSIS
        Prueft ueber die SID (endet auf -519), ob das Konto Mitglied der Organisations-Admins ist.
    #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        foreach ($g in $id.Groups) { if ($g.Value -match '^S-1-5-21-\d+-\d+-\d+-519$') { return $true } }
    }
    catch { Write-Log -Level Debug -Message 'Gruppenmitgliedschaften nicht lesbar.' }
    return $false
}
#
function Get-NetServerFqdn {
    $domaene = Get-NetDomainName
    if ($domaene) { return ('{0}.{1}' -f [Environment]::MachineName, $domaene).ToLower() }
    return [Environment]::MachineName.ToLower()
}
#
function Complete-NetDhcpPostInstall {
    <#
    .SYNOPSIS
        Nachkonfiguration nach der Rolleninstallation: Sicherheitsgruppen, ConfigurationState = 2,
        Dienst neu starten (ersetzt den Assistenten im Server-Manager).
    #>
    $status = Get-NetSafe -Beschreibung 'ConfigurationState' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState).ConfigurationState }
    if ([int]$status -eq 2) {
        Write-Log -Level OK -Message 'Die DHCP-Nachkonfiguration ist bereits erledigt.'
        return $true
    }
    $r = Invoke-NetChange -Titel 'DHCP-Nachkonfiguration abschliessen' -Stufe Bestaetigen -Vorher ('ConfigurationState = {0} (Server-Manager zeigt "Konfiguration erforderlich")' -f $(if ($null -ne $status) { $status } else { 'fehlt' })) `
        -Nachher 'Sicherheitsgruppen DHCP-Administratoren/DHCP-Benutzer angelegt, ConfigurationState = 2, Dienst neu gestartet' -Aktion {
        Add-DhcpServerSecurityGroup
        if (-not (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12')) { New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Force | Out-Null }
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2
        Restart-Service -Name DHCPServer -Force
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Install-NetDhcpRole {
    <#
    .SYNOPSIS
        Installiert die DHCP-Rolle mit Tools (falls noetig) und fuehrt die Nachkonfiguration aus.
    #>
    $f = Get-NetFeatureState
    if (-not ($f['DHCP'] -eq 'Installed' -and $f['RSAT-DHCP'] -eq 'Installed' -and (Test-NetCommand -Name 'Get-DhcpServerv4Scope'))) {
        $namen = @()
        if ($f['DHCP'] -ne 'Installed') { $namen += 'DHCP' }
        if ($f['RSAT-DHCP'] -ne 'Installed') { $namen += 'RSAT-DHCP' }
        if ($namen.Count -eq 0) { $namen = @('RSAT-DHCP') }
        $r = Invoke-NetChange -Titel ('Windows-Funktion(en) installieren: ' + ($namen -join ', ')) -Stufe Bestaetigen `
            -Vorher @{ DHCP = (ConvertTo-NetFeatureText -Status $f['DHCP']); 'RSAT-DHCP' = (ConvertTo-NetFeatureText -Status $f['RSAT-DHCP']) } -Nachher @{ DHCP = 'installiert'; 'RSAT-DHCP' = 'installiert' } -Aktion {
            $erg = Install-WindowsFeature -Name $namen -IncludeManagementTools
            if ($erg -and $erg.PSObject.Properties['Success'] -and -not $erg.Success) { throw 'Die Installation ist fehlgeschlagen.' }
            Import-Module DhcpServer -ErrorAction SilentlyContinue
        } -Rueckgaengig @{ Befehl = 'Uninstall-WindowsFeature'; Parameter = @{ Name = $namen } }
        if (-not $r.Erfolg -or $r.Probelauf) { return $false }
    }
    else { Write-Log -Level OK -Message 'DHCP-Rolle und Verwaltungstools sind installiert.' }
    return (Complete-NetDhcpPostInstall)
}
#
function Test-NetDhcpReady {
    <#
    .SYNOPSIS
        Prueft, ob DHCP verwaltet werden kann; bietet sonst Installation bzw. Dienststart an.
    #>
    param([switch]$Still)
    $dienst = Get-NetSafe -Beschreibung 'Dienst DHCPServer' -Abfrage { Get-Service -Name DHCPServer }
    if ((Test-NetCommand -Name 'Get-DhcpServerv4Scope') -and $dienst) {
        if ([string]$dienst.Status -ne 'Running') {
            Write-Log -Level Warn -Message 'Der DHCP-Dienst laeuft nicht.'
            if (-not $Still -and (Read-NetYesNo -Frage 'DHCP-Dienst jetzt starten?' -Vorschlag $true)) {
                $r = Invoke-NetChange -Titel 'DHCP-Dienst starten' -Stufe Automatisch -Aktion { Start-Service -Name DHCPServer }
                return [bool]$r.Erfolg
            }
            return $false
        }
        return $true
    }
    if ($Still) { return $false }
    Write-Log -Level Warn -Message 'Der DHCP-Server ist auf diesem Server nicht (vollstaendig) installiert.'
    if (Read-NetYesNo -Frage 'DHCP-Rolle jetzt installieren?' -Vorschlag $true) { return (Install-NetDhcpRole) }
    return $false
}
#
function Test-NetDhcpAuthorized {
    <#
    .SYNOPSIS
        Liefert $true (autorisiert), $false (nicht autorisiert) oder $null (keine Domaene).
    #>
    $einst = Get-NetSafe -Beschreibung 'Get-DhcpServerSetting' -Abfrage { Get-DhcpServerSetting }
    if (-not $einst) { return $null }
    if (-not $einst.IsDomainJoined) { return $null }
    return [bool]$einst.IsAuthorized
}
#
function Add-NetDhcpAuthorization {
    <#
    .SYNOPSIS
        Autorisiert den DHCP-Server im AD (Add-DhcpServerInDC). Ohne Domaene wird uebersprungen.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    $status = Test-NetDhcpAuthorized
    if ($null -eq $status) {
        Write-Log -Message 'Der Server ist in keiner Domaene: eine Autorisierung ist nicht noetig und wird uebersprungen.'
        return $true
    }
    if ($status) { Write-Log -Level OK -Message 'Der DHCP-Server ist im AD autorisiert.'; return $true }
    if (-not (Test-NetEnterpriseAdmin)) {
        Write-Log -Level Warn -Message 'Das angemeldete Konto ist nicht in der Gruppe Organisations-Admins (Enterprise Admins).'
        Write-NetText -Text "Die Autorisierung schreibt in den Konfigurationsbereich der Gesamtstruktur. Das duerfen nur Organisations-Admins`n(oder Konten, denen das Recht delegiert wurde). Moeglichkeiten:`n  - mit einem Konto aus Organisations-Admins anmelden und NetSetup erneut starten, oder`n  - einen Organisations-Admin bitten, auf einem DC auszufuehren:`n      Add-DhcpServerInDC -DnsName $(Get-NetServerFqdn) -IPAddress <IP dieses Servers>" -Farbe Yellow
        if (-not (Read-NetYesNo -Frage 'Trotzdem versuchen (falls das Recht delegiert ist)?' -Vorschlag $false)) { return $false }
    }
    $fqdn = Get-NetServerFqdn
    $karte = @((Get-NetSetupState).Netzwerk.AktiveKarten) | Select-Object -First 1
    $ip = ''
    if ($karte) { $ip = ($karte.Adressen | Select-Object -First 1).IP }
    $r = Invoke-NetChange -Titel "DHCP-Server $fqdn im AD autorisieren" -Stufe Bestaetigen -Vorher 'nicht autorisiert (vergibt keine Adressen)' -Nachher ('autorisiert: {0} ({1})' -f $fqdn, $ip) -Aktion {
        if ($ip) { Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ip } else { Add-DhcpServerInDC -DnsName $fqdn }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerInDC'; Parameter = @{ DnsName = $fqdn; IPAddress = $ip } }
    if ($r.Erfolg -and -not $r.Probelauf) { Write-Log -Message 'Hinweis: Es kann einige Minuten dauern, bis der Dienst die Autorisierung bemerkt.' }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Show-NetDhcpBinding {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCP-Bindungen (auf welchen Netzwerkkarten DHCP antwortet)'
    $z = Get-NetSetupState
    foreach ($b in @($z.Dhcp.Bindungen)) {
        $karte = @($z.Netzwerk.Karten | Where-Object { $_.Name -eq $b.Karte }) | Select-Object -First 1
        $hinweis = ''
        if ($karte -and $karte.Dhcp) { $hinweis = ' - Karte hat eine DHCP-Adresse, darauf bindet der DHCP-Server nicht!' }
        if ($b.Aktiv) { Write-NetStatus -Status OK -Bereich $b.Karte -Text ('gebunden ({0}){1}' -f $b.IP, $hinweis) }
        else { Write-NetStatus -Status NA -Bereich $b.Karte -Text ('nicht gebunden ({0}){1}' -f $b.IP, $hinweis) }
    }
}
#
function Set-NetDhcpBinding {
    <#
    .SYNOPSIS
        Legt fest, auf welchen Netzwerkkarten der DHCP-Server antwortet.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    $bindungen = @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Binding' -Standard @() -Abfrage { Get-DhcpServerv4Binding } | ForEach-Object {
            [pscustomobject]@{ Karte = [string]$_.InterfaceAlias; IP = (ConvertTo-NetString -Wert $_.IPAddress); Aktiv = [bool]$_.BindingState }
        })
    if ($bindungen.Count -eq 0) { Write-Log -Level Warn -Message 'Keine Netzwerkkarte mit fester IPv4-Adresse fuer DHCP gefunden.'; return }
    Write-NetText -Text 'Nur Karten im Netz der Clients (bzw. mit DHCP-Relay) sollten gebunden sein. Karten fuer Speicher-, Backup- oder Internetnetze nicht binden.'
    $wahl = @(Select-NetItem -Elemente $bindungen -Titel 'Welche Karten sollen gebunden sein?' -Eigenschaften @('Karte', 'IP', 'Aktiv') -Mehrfach)
    if ($wahl.Count -eq 0) { return }
    $soll = @($wahl | ForEach-Object { $_.Karte })
    foreach ($b in $bindungen) {
        $neu = $soll -contains $b.Karte
        if ($neu -eq $b.Aktiv) { continue }
        $karte = $b.Karte
        $alt = $b.Aktiv
        Invoke-NetChange -Titel ("DHCP-Bindung fuer {0} {1}" -f $karte, $(if ($neu) { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen -Vorher $(if ($alt) { 'gebunden' } else { 'nicht gebunden' }) -Nachher $(if ($neu) { 'gebunden' } else { 'nicht gebunden' }) -BackupBereich @('Dhcp') -Aktion {
            Set-DhcpServerv4Binding -InterfaceAlias $karte -BindingState $neu
        } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4Binding'; Parameter = @{ InterfaceAlias = $karte; BindingState = $alt } } | Out-Null
    }
}
#
function Set-NetDhcpConflictDetection {
    <#
    .SYNOPSIS
        Konflikterkennung: der Server pingt eine Adresse vor der Vergabe (0 = aus, Vorschlag 1).
    #>
    param([Nullable[int]]$Versuche = $null)
    if (-not (Test-NetDhcpReady)) { return $false }
    $einst = Get-NetSafe -Beschreibung 'Get-DhcpServerSetting' -Abfrage { Get-DhcpServerSetting }
    $alt = 0
    if ($einst) { $alt = [int]$einst.ConflictDetectionAttempts }
    if ($null -eq $Versuche) {
        Write-NetText -Text 'Bei eingeschalteter Konflikterkennung pingt der DHCP-Server eine Adresse, bevor er sie vergibt. So werden Doppelvergaben (z. B. Geraete mit fest eingetragener IP) vermieden. Jeder Versuch verzoegert die Vergabe um etwa eine Sekunde. Vorschlag: 1.'
        $Versuche = Read-NetNumber -Frage ('Anzahl Pingversuche (0-5, aktuell {0})' -f $alt) -Minimum 0 -Maximum 5 -Vorschlag 1
        if ($null -eq $Versuche) { return $false }
    }
    if ($Versuche -eq $alt) { Write-Log -Level OK -Message 'Die Konflikterkennung ist bereits so eingestellt.'; return $true }
    $neu = [int]$Versuche
    $r = Invoke-NetChange -Titel 'DHCP-Konflikterkennung einstellen' -Stufe Bestaetigen -Vorher ('{0} Versuch(e)' -f $alt) -Nachher ('{0} Versuch(e)' -f $neu) -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerSetting -ConflictDetectionAttempts $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerSetting'; Parameter = @{ ConflictDetectionAttempts = $alt } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
# ----------------------------------------------------------------------
# src/dhcp/DhcpScope.ps1
# ----------------------------------------------------------------------
# DHCP-Scopes: Assistent (Name, Bereich, Maske, Ausschluesse, Lease, 003/006/015),
# mehrere Netze mit Hinweis auf DHCP-Relay, Superscopes, aktivieren/deaktivieren, loeschen.
#
function Get-NetDhcpScopeList {
    $liste = @()
    foreach ($s in @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Scope' -Standard @() -Abfrage { Get-DhcpServerv4Scope })) {
        if ($null -eq $s) { continue }
        $maske = ConvertTo-NetString -Wert $s.SubnetMask
        $liste += [pscustomobject]@{
            ScopeId    = ConvertTo-NetString -Wert $s.ScopeId
            Name       = [string]$s.Name
            Start      = ConvertTo-NetString -Wert $s.StartRange
            Ende       = ConvertTo-NetString -Wert $s.EndRange
            Maske      = $maske
            Prefix     = ConvertTo-NetPrefixLength -SubnetMask $maske
            Status     = [string]$s.State
            LeaseTage  = $(if ($s.LeaseDuration -is [TimeSpan]) { [Math]::Round($s.LeaseDuration.TotalDays, 2) } else { 0 })
            Superscope = [string]$s.SuperscopeName
        }
    }
    return $liste
}
#
function Select-NetDhcpScope {
    param([string]$Titel = 'Scope waehlen')
    $liste = @(Get-NetDhcpScopeList)
    if ($liste.Count -eq 0) { Write-Log -Level Warn -Message 'Es gibt noch keinen Scope. Zuerst einen Scope anlegen.'; return $null }
    if ($liste.Count -eq 1) { return $liste[0] }
    return (Select-NetItem -Elemente $liste -Titel $Titel -Eigenschaften @('ScopeId', 'Name', 'Start', 'Ende', 'Status'))
}
#
function Get-NetDhcpScopeOption {
    <#
    .SYNOPSIS
        Liefert die Optionen eines Scopes (oder des Servers ohne ScopeId) als Hashtable OptionId -> Werte.
    #>
    param([string]$ScopeId)
    $ergebnis = @{}
    $werte = @()
    if ($ScopeId) { $werte = @(Get-NetSafe -Beschreibung "Optionen $ScopeId" -Standard @() -Abfrage { Get-DhcpServerv4OptionValue -ScopeId $ScopeId }) }
    else { $werte = @(Get-NetSafe -Beschreibung 'Serveroptionen' -Standard @() -Abfrage { Get-DhcpServerv4OptionValue }) }
    foreach ($o in $werte) { if ($o) { $ergebnis[[int]$o.OptionId] = @($o.Value | ForEach-Object { [string]$_ }) } }
    return $ergebnis
}
#
function Show-NetDhcpScope {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCP-Scopes'
    $liste = @(Get-NetDhcpScopeList)
    if ($liste.Count -eq 0) { Write-Log -Level Warn -Message 'Keine Scopes vorhanden.'; return }
    $server = Get-NetDhcpScopeOption
    foreach ($s in $liste) {
        $id = $s.ScopeId
        $stat = Get-NetSafe -Beschreibung "Statistik $id" -Abfrage { Get-DhcpServerv4ScopeStatistics -ScopeId $id }
        $belegt = ''
        if ($stat) { $belegt = ('belegt {0:N0}% ({1} frei)' -f [double]$stat.PercentageInUse, $stat.Free) }
        $farbe = 'Gray'
        if ($s.Status -ne 'Active') { $farbe = 'DarkGray' }
        Write-Host ('  {0,-15} {1,-18} {2} - {3} /{4}  {5}  Lease {6} Tage  {7}' -f $id, $s.Name, $s.Start, $s.Ende, $s.Prefix, $s.Status, $s.LeaseTage, $belegt) -ForegroundColor $farbe
        $opt = Get-NetDhcpScopeOption -ScopeId $id
        foreach ($nr in @(3, 6, 15)) {
            $quelle = 'Scope'
            $wert = $opt[$nr]
            if (-not $wert -and $server[$nr]) { $wert = $server[$nr]; $quelle = 'Server' }
            $text = '(fehlt)'
            if ($wert) { $text = ($wert -join ', ') + ' [' + $quelle + ']' }
            Write-Host ('      Option {0,3}: {1}' -f $nr, $text)
        }
        $aus = @(Get-NetSafe -Beschreibung "Ausschluesse $id" -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id })
        foreach ($a in $aus) { if ($a) { Write-Host ('      Ausschluss: {0} - {1}' -f (ConvertTo-NetString $a.StartRange), (ConvertTo-NetString $a.EndRange)) } }
        if ($s.Superscope) { Write-Host ('      Superscope: {0}' -f $s.Superscope) }
    }
}
#
function Get-NetDhcpRangeSuggestion {
    <#
    .SYNOPSIS
        Schlaegt einen Adressbereich vor: bei /24 .100 bis .199, sonst etwa 40 % bis 80 % des Netzes.
    #>
    param([Parameter(Mandatory = $true)][string]$Netz, [Parameter(Mandatory = $true)][int]$Prefix)
    $basis = [int64](ConvertTo-NetIPv4UInt32 -IPAddress $Netz)
    $groesse = [int64][Math]::Pow(2, 32 - $Prefix)
    if ($Prefix -eq 24) { return @((ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($basis + 100))), (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($basis + 199)))) }
    $start = $basis + [int64][Math]::Max(1, [Math]::Floor($groesse * 0.4))
    $ende = $basis + [int64][Math]::Min($groesse - 2, [Math]::Floor($groesse * 0.8))
    return @((ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$start)), (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$ende)))
}
#
function Get-NetDcAddress {
    <#
    .SYNOPSIS
        Liefert IPv4-Adressen der DCs (Vorschlag fuer Option 006). Ohne AD: eigene IP, falls DNS laeuft.
    #>
    param([hashtable]$Zustand = $script:NS.Zustand)
    $liste = @()
    if ($Zustand -and ($Zustand.System.IstDC -or $Zustand.System.IstMitglied) -and (Test-NetCommand -Name 'Get-ADDomainController')) {
        $liste = @(Get-NetSafe -Beschreibung 'DCs' -Standard @() -Abfrage { Get-ADDomainController -Filter * } | Where-Object { $_ -and $_.IPv4Address } | ForEach-Object { [string]$_.IPv4Address })
    }
    if ($liste.Count -eq 0 -and $Zustand -and $Zustand.Dns.Laeuft) { $liste = @($Zustand.Netzwerk.EigeneIPs | Select-Object -First 1) }
    $eigene = @()
    if ($Zustand) { $eigene = @($Zustand.Netzwerk.EigeneIPs) }
    return @(@($liste | Where-Object { $eigene -contains $_ }) + @($liste | Where-Object { $eigene -notcontains $_ }) | Select-Object -Unique)
}
#
function Read-NetExclusionList {
    <#
    .SYNOPSIS
        Fragt Ausschluesse ab ("Start-Ende" oder einzelne Adressen, mit Komma getrennt).
    #>
    param([string]$Netz, [int]$Prefix, [string]$Vorschlag = '')
    $pruefNetz = $Netz
    $pruefPrefix = $Prefix
    $text = Read-NetText -Frage 'Ausschluesse (z. B. 192.168.1.100-192.168.1.109, mehrere mit Komma; leer = keine)' -Vorschlag $Vorschlag -LeerErlaubt -Pruefung {
        param($t)
        foreach ($teil in $t.Split(',')) {
            $teil = $teil.Trim()
            if (-not $teil) { continue }
            $ab = $teil.Split('-')
            $a = $ab[0].Trim()
            $b = $a
            if ($ab.Count -gt 1) { $b = $ab[1].Trim() }
            if (-not (Test-NetIPv4Address -Text $a) -or -not (Test-NetIPv4Address -Text $b)) { return "'$teil' ist kein gueltiger Bereich." }
            if (-not (Test-NetIPInSubnet -IPAddress $a -NetworkAddress $pruefNetz -PrefixLength $pruefPrefix) -or -not (Test-NetIPInSubnet -IPAddress $b -NetworkAddress $pruefNetz -PrefixLength $pruefPrefix)) { return "'$teil' liegt nicht im Netz." }
            if ((ConvertTo-NetIPv4UInt32 -IPAddress $a) -gt (ConvertTo-NetIPv4UInt32 -IPAddress $b)) { return "In '$teil' ist der Anfang groesser als das Ende." }
        }
        return $null
    }
    if ($null -eq $text) { return $null }
    $liste = @()
    foreach ($teil in $text.Split(',')) {
        $teil = $teil.Trim()
        if (-not $teil) { continue }
        $ab = $teil.Split('-')
        $a = $ab[0].Trim()
        $b = $a
        if ($ab.Count -gt 1) { $b = $ab[1].Trim() }
        $liste += , @($a, $b)
    }
    return , $liste
}
#
function New-NetDhcpScope {
    <#
    .SYNOPSIS
        Scope-Assistent. Ungueltige Bereiche werden vor dem Anlegen abgelehnt; ein vorhandener Scope
        fuer dasselbe Netz wird erkannt und nicht ueberschrieben.
    #>
    param([hashtable]$Vorgaben = @{})
    if (-not (Test-NetDhcpReady)) { return $false }
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'Neuer DHCP-Scope'
    $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1
    $netzVorschlag = ''
    if ($karte) { $a = $karte.Adressen | Select-Object -First 1; $netzVorschlag = '{0}/{1}' -f (Get-NetNetworkAddress -IPAddress $a.IP -PrefixLength $a.Prefix), $a.Prefix }
    if ($Vorgaben.Netz) { $netzVorschlag = $Vorgaben.Netz }
    $netz = Read-NetSubnet -Frage 'Netz des Scopes (z. B. 192.168.1.0/24)' -Vorschlag $netzVorschlag
    if (-not $netz) { return $false }
    $vorhanden = @(Get-NetDhcpScopeList | Where-Object { $_.ScopeId -eq $netz.Netz })
    if ($vorhanden.Count -gt 0) {
        Write-Log -Level OK -Message ('Fuer {0} gibt es schon den Scope "{1}" ({2} - {3}). Er wird nicht ueberschrieben.' -f $netz.Text, $vorhanden[0].Name, $vorhanden[0].Start, $vorhanden[0].Ende)
        return $true
    }
    $eigenesNetz = $false
    foreach ($k in @($z.Netzwerk.AktiveKarten)) { foreach ($ad in $k.Adressen) { if (Test-NetIPInSubnet -IPAddress $ad.IP -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix) { $eigenesNetz = $true } } }
    if (-not $eigenesNetz) {
        Write-Log -Level Warn -Message ('Der Server hat keine Adresse im Netz {0}.' -f $netz.Text)
        Write-NetText -Text "Fuer ein anderes Netz (VLAN) muss der Router bzw. Layer-3-Switch DHCP-Anfragen an diesen Server weiterleiten`n(DHCP-Relay, oft 'IP Helper' genannt, Ziel = IP dieses Servers). Sonst kommt keine Anfrage an." -Farbe Yellow
        if (-not (Read-NetYesNo -Frage 'Ist das DHCP-Relay eingerichtet bzw. wird es eingerichtet?' -Vorschlag $true)) { return $false }
    }
    $name = Read-NetText -Frage 'Name des Scopes' -Vorschlag $(if ($Vorgaben.Name) { $Vorgaben.Name } elseif ($eigenesNetz) { 'LAN' } else { 'VLAN ' + $netz.Netz })
    if (-not $name) { return $false }
    $bereich = Get-NetDhcpRangeSuggestion -Netz $netz.Netz -Prefix $netz.Prefix
    while ($true) {
        $start = Read-NetIPAddress -Frage 'Erste Adresse des Bereichs' -Vorschlag $bereich[0] -Netz $netz.Netz -Prefix $netz.Prefix
        if (-not $start) { return $false }
        $ende = Read-NetIPAddress -Frage 'Letzte Adresse des Bereichs' -Vorschlag $bereich[1] -Netz $netz.Netz -Prefix $netz.Prefix
        if (-not $ende) { return $false }
        $grund = Test-NetIPRange -Start $start -Ende $ende -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix
        if (-not $grund) { break }
        Write-Log -Level Fehler -Message $grund
    }
    $imBereich = @()
    foreach ($k in @($z.Netzwerk.AktiveKarten)) {
        foreach ($ad in $k.Adressen) { if (Test-NetIPInRange -IPAddress $ad.IP -Start $start -Ende $ende) { $imBereich += $ad.IP } }
        foreach ($g in $k.Gateway) { if (Test-NetIPInRange -IPAddress $g -Start $start -Ende $ende) { $imBereich += $g } }
    }
    $ausVorschlag = ''
    if ($imBereich.Count -gt 0) {
        Write-Log -Level Warn -Message ('Diese festen Adressen liegen im Bereich und sollten ausgeschlossen werden: ' + ($imBereich -join ', '))
        $ausVorschlag = ($imBereich | ForEach-Object { $_ }) -join ','
    }
    $ausschluesse = Read-NetExclusionList -Netz $netz.Netz -Prefix $netz.Prefix -Vorschlag $ausVorschlag
    if ($null -eq $ausschluesse) { return $false }
    $leaseVorschlag = [int](Get-NetConfigValue -Pfad 'Vorschlaege.LeaseTage' -Standard 8)
    $lease = Read-NetNumber -Frage 'Lease-Dauer in Tagen (Buero: 8, Gaeste/WLAN: 1)' -Minimum 1 -Maximum 999 -Vorschlag $leaseVorschlag
    if ($null -eq $lease) { return $false }
    $gwVorschlag = ''
    if ($karte -and $karte.Gateway.Count -gt 0 -and (Test-NetIPInSubnet -IPAddress $karte.Gateway[0] -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix)) { $gwVorschlag = $karte.Gateway[0] }
    else { $gwVorschlag = ConvertFrom-NetIPv4UInt32 -Wert ([uint32]((ConvertTo-NetIPv4UInt32 -IPAddress $netz.Netz) + 1)) }
    $router = Read-NetIPAddress -Frage 'Router / Gateway (Option 003)' -Vorschlag $gwVorschlag -Netz $netz.Netz -Prefix $netz.Prefix
    if (-not $router) { return $false }
    if (Test-NetIPInRange -IPAddress $router -Start $start -Ende $ende) {
        $drin = $false
        foreach ($a in $ausschluesse) { if (Test-NetIPInRange -IPAddress $router -Start $a[0] -Ende $a[1]) { $drin = $true } }
        if (-not $drin) { Write-Log -Level Warn -Message 'Der Router liegt im Bereich und ist nicht ausgeschlossen. Er wird automatisch ausgeschlossen.'; $ausschluesse += , @($router, $router) }
    }
    $dnsVorschlag = (@(Get-NetDcAddress -Zustand $z) -join ',')
    $dnsText = Read-NetText -Frage 'DNS-Server fuer die Clients (Option 006, Vorschlag: die DCs)' -Vorschlag $dnsVorschlag -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $dnsText) { return $false }
    $dnsServer = @($dnsText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($dnsServer | Where-Object { $_ -in @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9') }).Count -gt 0 -and ($z.System.IstDC -or $z.System.IstMitglied)) {
        Write-Log -Level Warn -Message 'Domaenen-Clients sollten nur die DCs als DNS-Server bekommen, sonst finden sie die Domaene nicht.'
    }
    $domVorschlag = Get-NetDomainName
    $domaene = Read-NetText -Frage 'DNS-Domaene der Clients (Option 015)' -Vorschlag $domVorschlag -LeerErlaubt -Pruefung { param($t) if (-not $t) { $null } else { (Test-NetDomainName -Name $t).Fehler } }
    if ($null -eq $domaene) { return $false }
    $aktiv = Read-NetYesNo -Frage 'Scope sofort aktivieren?' -Vorschlag $true
#
    $scopeId = $netz.Netz
    $maske = $netz.Maske
    $leaseDauer = [TimeSpan]::FromDays($lease)
    $zustandText = 'InActive'
    if ($aktiv) { $zustandText = 'Active' }
    $nachher = @{
        Name = $name; Netz = $netz.Text; Bereich = "$start - $ende"; Ausschluesse = (($ausschluesse | ForEach-Object { $_[0] + '-' + $_[1] }) -join ', ')
        'Lease-Dauer' = "$lease Tage"; 'Router (003)' = $router; 'DNS-Server (006)' = ($dnsServer -join ', '); 'Domaene (015)' = $domaene; Status = $zustandText
    }
    $r = Invoke-NetChange -Titel ('DHCP-Scope {0} ({1}) anlegen' -f $name, $netz.Text) -Stufe Bestaetigen -Vorher '(kein Scope fuer dieses Netz)' -Nachher $nachher -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Scope -Name $name -StartRange $start -EndRange $ende -SubnetMask $maske -LeaseDuration $leaseDauer -State InActive
        foreach ($a in $ausschluesse) { Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $a[0] -EndRange $a[1] }
        if ($domaene) { Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dnsServer -DnsDomain $domaene -Force }
        else { Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dnsServer -Force }
        if ($aktiv) { Set-DhcpServerv4Scope -ScopeId $scopeId -State Active }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Scope'; Parameter = @{ ScopeId = $scopeId; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Add-NetDhcpExclusion {
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Ausschluss fuer welchen Scope?'
    if (-not $s) { return }
    $liste = Read-NetExclusionList -Netz $s.ScopeId -Prefix $s.Prefix
    if (-not $liste -or $liste.Count -eq 0) { return }
    $vorhanden = @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $s.ScopeId } | Where-Object { $_ } | ForEach-Object { (ConvertTo-NetString $_.StartRange) + '-' + (ConvertTo-NetString $_.EndRange) })
    foreach ($a in $liste) {
        $text = $a[0] + '-' + $a[1]
        if ($vorhanden -contains $text) { Write-Log -Level OK -Message "Ausschluss $text existiert bereits."; continue }
        $id = $s.ScopeId
        $von = $a[0]
        $bis = $a[1]
        Invoke-NetChange -Titel "Ausschluss $text zum Scope $id hinzufuegen" -Stufe Bestaetigen -Vorher ($vorhanden -join ', ') -Nachher (@($vorhanden) + $text -join ', ') -BackupBereich @('Dhcp') -Aktion {
            Add-DhcpServerv4ExclusionRange -ScopeId $id -StartRange $von -EndRange $bis
        } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4ExclusionRange'; Parameter = @{ ScopeId = $id; StartRange = $von; EndRange = $bis } } | Out-Null
    }
}
#
function Switch-NetDhcpScopeState {
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Welchen Scope aktivieren/deaktivieren?'
    if (-not $s) { return }
    $id = $s.ScopeId
    $alt = $s.Status
    $neu = 'Active'
    if ($alt -eq 'Active') { $neu = 'InActive' }
    $hinweis = ''
    if ($neu -eq 'InActive') { $hinweis = 'Ein deaktivierter Scope vergibt keine Adressen mehr. Bestehende Leases laufen weiter, werden aber nicht erneuert.' }
    Invoke-NetChange -Titel ("Scope {0} {1}" -f $id, $(if ($neu -eq 'Active') { 'aktivieren' } else { 'deaktivieren' })) -Stufe Bestaetigen -Vorher $alt -Nachher $neu -Hinweis $hinweis -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4Scope -ScopeId $id -State $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4Scope'; Parameter = @{ ScopeId = $id; State = $alt } } | Out-Null
}
#
function Remove-NetDhcpScope {
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Welchen Scope loeschen?'
    if (-not $s) { return }
    $id = $s.ScopeId
    $leases = @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id }).Count
    Invoke-NetChange -Titel "DHCP-Scope $id ($($s.Name)) loeschen" -Stufe Gefaehrlich -Vorher @{ Scope = $id; Name = $s.Name; Bereich = $s.Start + ' - ' + $s.Ende; Leases = $leases } -Nachher '(geloescht)' -BackupBereich @('Dhcp') `
        -Hinweis 'Alle Leases, Reservierungen und Optionen des Scopes gehen verloren. Wiederherstellung nur aus dem Backup.' -Aktion {
        Remove-DhcpServerv4Scope -ScopeId $id -Force
    } | Out-Null
}
#
function New-NetDhcpSuperscope {
    <#
    .SYNOPSIS
        Fasst Scopes, die im selben physischen Netz liegen, zu einem Superscope zusammen.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetText -Text 'Ein Superscope ist nur noetig, wenn mehrere logische Netze auf demselben Kabel/VLAN liegen (z. B. weil das erste Netz voll ist). Fuer getrennte VLANs mit DHCP-Relay braucht man keinen Superscope.'
    $wahl = @(Select-NetItem -Elemente @(Get-NetDhcpScopeList) -Titel 'Welche Scopes zusammenfassen?' -Eigenschaften @('ScopeId', 'Name', 'Superscope') -Mehrfach)
    if ($wahl.Count -lt 2) { Write-Log -Level Warn -Message 'Fuer einen Superscope braucht es mindestens zwei Scopes.'; return }
    $name = Read-NetText -Frage 'Name des Superscopes' -Vorschlag 'Superscope'
    if (-not $name) { return }
    $ids = @($wahl | ForEach-Object { $_.ScopeId })
    Invoke-NetChange -Titel "Superscope $name anlegen" -Stufe Bestaetigen -Vorher (($wahl | ForEach-Object { $_.ScopeId + ' (' + $(if ($_.Superscope) { $_.Superscope } else { 'kein Superscope' }) + ')' }) -join ', ') -Nachher ("$name : " + ($ids -join ', ')) -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Superscope -SuperscopeName $name -ScopeId $ids
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Superscope'; Parameter = @{ SuperscopeName = $name; Force = $true } } | Out-Null
}
#
function Set-NetDhcpStandardOption {
    <#
    .SYNOPSIS
        Aendert Router (003), DNS-Server (006) und Domaene (015) eines Scopes.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Optionen welches Scopes aendern?'
    if (-not $s) { return }
    $id = $s.ScopeId
    $alt = Get-NetDhcpScopeOption -ScopeId $id
    $router = Read-NetIPAddress -Frage 'Router (003)' -Vorschlag (@($alt[3]) -join '') -Netz $s.ScopeId -Prefix $s.Prefix
    if (-not $router) { return }
    $dnsText = Read-NetText -Frage 'DNS-Server (006, mit Komma getrennt)' -Vorschlag $(if ($alt[6]) { $alt[6] -join ',' } else { (@(Get-NetDcAddress -Zustand (Get-NetSetupState)) -join ',') }) -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $dnsText) { return }
    $dnsServer = @($dnsText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $domaene = Read-NetText -Frage 'Domaene (015)' -Vorschlag $(if ($alt[15]) { $alt[15][0] } else { Get-NetDomainName }) -LeerErlaubt
    if ($null -eq $domaene) { return }
    $vorher = @{ '003' = (@($alt[3]) -join ', '); '006' = (@($alt[6]) -join ', '); '015' = (@($alt[15]) -join ', ') }
    $nachher = @{ '003' = $router; '006' = ($dnsServer -join ', '); '015' = $domaene }
    if (($vorher['003'] -eq $nachher['003']) -and ($vorher['006'] -eq $nachher['006']) -and ($vorher['015'] -eq $nachher['015'])) { Write-Log -Level OK -Message 'Keine Aenderung.'; return }
    $rueck = @()
    foreach ($nr in @(3, 6, 15)) {
        if ($alt[$nr]) { $rueck += @{ Befehl = 'Set-DhcpServerv4OptionValue'; Parameter = @{ ScopeId = $id; OptionId = $nr; Value = $alt[$nr]; Force = $true } } }
        else { $rueck += @{ Befehl = 'Remove-DhcpServerv4OptionValue'; Parameter = @{ ScopeId = $id; OptionId = $nr } } }
    }
    Invoke-NetChange -Titel "Optionen 003/006/015 des Scopes $id aendern" -Stufe Bestaetigen -Vorher $vorher -Nachher $nachher -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4OptionValue -ScopeId $id -Router $router -DnsServer $dnsServer -Force
        if ($domaene) { Set-DhcpServerv4OptionValue -ScopeId $id -DnsDomain $domaene -Force }
    } -Rueckgaengig $rueck | Out-Null
}
# ----------------------------------------------------------------------
# src/dhcp/DhcpOptionen.ps1
# ----------------------------------------------------------------------
# Zusatzoptionen (standardmaessig aus): NTP (042), PXE (066/067) und DNS-Suchliste (119).
# Option 119 ist in Windows nicht vordefiniert: sie wird mit Add-DhcpServerv4OptionDefinition
# angelegt und der Wert nach RFC 3397 kodiert.
#
$script:NetZusatzOptionen = @{
    42  = 'NTP-Server (042): Zeitserver fuer die Clients. Domaenen-Clients holen die Zeit ohnehin vom DC; sinnvoll fuer Geraete ohne Domaene (Drucker, Telefone).'
    66  = 'PXE-Bootserver (066): Name oder IP des TFTP-Servers fuer Netzwerkboot (z. B. WDS/MDT). Nur noetig, wenn Clients per Netzwerk booten und kein IP-Helper/WDS-Proxy genutzt wird.'
    67  = 'PXE-Bootdatei (067): Pfad der Bootdatei, z. B. boot\x64\wdsmgfw.efi (UEFI) oder boot\x64\wdsnbp.com (BIOS).'
    119 = 'DNS-Suchliste (119): weitere Domaenen, die Clients beim Aufloesen kurzer Namen anhaengen. Windows-Clients werten 119 erst ab Windows 10 1803 aus; Linux und macOS nutzen sie.'
}
#
function ConvertTo-NetDhcpSearchList {
    <#
    .SYNOPSIS
        Kodiert eine Liste von Domaenen nach RFC 3397 (DNS-Namen im Wire-Format, ohne Kompression).
    .OUTPUTS
        Byte-Array.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Domaenen)
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($d in $Domaenen) {
        $name = $d.Trim().TrimEnd('.')
        if (-not $name) { continue }
        foreach ($label in $name.Split('.')) {
            $ascii = [System.Text.Encoding]::ASCII.GetBytes($label.ToLower())
            if ($ascii.Length -lt 1 -or $ascii.Length -gt 63) { throw "Ungueltiger Teil '$label' in $d." }
            $bytes.Add([byte]$ascii.Length)
            foreach ($b in $ascii) { $bytes.Add($b) }
        }
        $bytes.Add([byte]0)
    }
    if ($bytes.Count -gt 255) { throw 'Die Suchliste ist zu lang (hoechstens 255 Bytes in einer Option).' }
    return [byte[]]$bytes.ToArray()
}
#
function ConvertFrom-NetDhcpSearchList {
    <#
    .SYNOPSIS
        Dekodiert eine RFC-3397-Suchliste (ohne Kompression) in Domaenennamen.
    #>
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $liste = @()
    $labels = @()
    $i = 0
    while ($i -lt $Bytes.Length) {
        $laenge = [int]$Bytes[$i]
        $i++
        if ($laenge -eq 0) { if ($labels.Count) { $liste += ($labels -join '.') }; $labels = @(); continue }
        if ($laenge -ge 192) { throw 'Komprimierte Suchlisten werden nicht unterstuetzt.' }
        $labels += [System.Text.Encoding]::ASCII.GetString($Bytes, $i, $laenge)
        $i += $laenge
    }
    return $liste
}
#
function Install-NetDhcpOption119 {
    <#
    .SYNOPSIS
        Legt die Optionsdefinition 119 an, falls sie fehlt.
    #>
    $def = Get-NetSafe -Beschreibung 'Option 119' -Abfrage { Get-DhcpServerv4OptionDefinition -OptionId 119 }
    if ($def) { return $true }
    $r = Invoke-NetChange -Titel 'DHCP-Optionsdefinition 119 (DNS-Suchliste) anlegen' -Stufe Bestaetigen -Vorher '(nicht definiert)' -Nachher 'Option 119 "Domain Search List", Typ BinaryData (RFC 3397)' -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4OptionDefinition -OptionId 119 -Name 'Domain Search List' -Type BinaryData -Description 'DNS-Suchliste nach RFC 3397 (angelegt von NetSetup)'
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Set-NetDhcpExtraOption {
    <#
    .SYNOPSIS
        Setzt eine Zusatzoption auf Server- oder Scope-Ebene (042, 066, 067, 119).
    #>
    param([ValidateSet(0, 42, 66, 67, 119)][int]$OptionId = 0)
    if (-not (Test-NetDhcpReady)) { return $false }
    if ($OptionId -eq 0) {
        $ids = @(42, 66, 67, 119)
        $i = Read-NetChoice -Frage 'Welche Zusatzoption?' -Optionen @($ids | ForEach-Object { $script:NetZusatzOptionen[$_] }) -Vorschlag 1
        if ($i -lt 0) { return $false }
        $OptionId = $ids[$i]
    }
    Write-NetText -Text $script:NetZusatzOptionen[$OptionId]
    $ebene = Read-NetChoice -Frage 'Fuer wen?' -Optionen @('Alle Scopes (Server-Ebene)', 'Nur einen Scope') -Vorschlag 2
    if ($ebene -lt 0) { return $false }
    $scopeId = ''
    if ($ebene -eq 1) {
        $s = Select-NetDhcpScope -Titel 'Fuer welchen Scope?'
        if (-not $s) { return $false }
        $scopeId = $s.ScopeId
    }
    $werte = @()
    $anzeige = ''
    switch ($OptionId) {
        42 {
            $t = Read-NetText -Frage 'NTP-Server (IPv4, mit Komma getrennt)' -Vorschlag ((@(Get-NetDcAddress -Zustand (Get-NetSetupState))) -join ',') -Pruefung {
                param($x)
                foreach ($y in $x.Split(',')) { if (-not (Test-NetIPv4Address -Text $y.Trim())) { return "'$y' ist keine gueltige IPv4-Adresse." } }
                return $null
            }
            if (-not $t) { return $false }
            $werte = @($t.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $anzeige = $werte -join ', '
        }
        66 {
            $t = Read-NetText -Frage 'Name oder IP des Bootservers' -Pruefung { param($x) if ($x -match '^[A-Za-z0-9.-]+$') { $null } else { 'Nur Name oder IP-Adresse.' } }
            if (-not $t) { return $false }
            $werte = @($t); $anzeige = $t
        }
        67 {
            $t = Read-NetText -Frage 'Bootdatei' -Vorschlag 'boot\x64\wdsmgfw.efi' -Pruefung { param($x) if ($x -match '^[A-Za-z0-9._\\/-]+$') { $null } else { 'Ungueltige Zeichen im Pfad.' } }
            if (-not $t) { return $false }
            $werte = @($t); $anzeige = $t
        }
        119 {
            $t = Read-NetText -Frage 'Domaenen der Suchliste (mit Komma getrennt)' -Vorschlag (Get-NetDomainName) -Pruefung {
                param($x)
                foreach ($y in $x.Split(',')) { $e = (Test-NetDomainName -Name $y.Trim()).Fehler; if ($e) { return $e } }
                return $null
            }
            if (-not $t) { return $false }
            $domaenen = @($t.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if (-not (Install-NetDhcpOption119)) { return $false }
            $werte = @(ConvertTo-NetDhcpSearchList -Domaenen $domaenen | ForEach-Object { [string][int]$_ })
            $anzeige = ($domaenen -join ', ') + (' ({0} Bytes nach RFC 3397)' -f $werte.Count)
        }
    }
    $alt = Get-NetDhcpScopeOption -ScopeId $scopeId
    $altWert = $alt[$OptionId]
    $p = @{ OptionId = $OptionId; Value = $werte; Force = $true }
    $rp = @{ OptionId = $OptionId }
    if ($scopeId) { $p.ScopeId = $scopeId; $rp.ScopeId = $scopeId }
    $rueck = @{ Befehl = 'Remove-DhcpServerv4OptionValue'; Parameter = $rp }
    if ($altWert) { $rueck = @{ Befehl = 'Set-DhcpServerv4OptionValue'; Parameter = ($rp + @{ Value = $altWert; Force = $true }) } }
    $r = Invoke-NetChange -Titel ('DHCP-Option {0:000} setzen ({1})' -f $OptionId, $(if ($scopeId) { 'Scope ' + $scopeId } else { 'Server' })) -Stufe Bestaetigen -Vorher $(if ($altWert) { $altWert -join ', ' } else { '(nicht gesetzt)' }) -Nachher $anzeige -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4OptionValue @p
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Remove-NetDhcpExtraOption {
    if (-not (Test-NetDhcpReady)) { return }
    $eintraege = @()
    foreach ($nr in @(42, 66, 67, 119)) {
        $server = Get-NetDhcpScopeOption
        if ($server[$nr]) { $eintraege += [pscustomobject]@{ Ebene = 'Server'; ScopeId = ''; Option = $nr; Wert = ($server[$nr] -join ', ') } }
    }
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $o = Get-NetDhcpScopeOption -ScopeId $s.ScopeId
        foreach ($nr in @(42, 66, 67, 119)) { if ($o[$nr]) { $eintraege += [pscustomobject]@{ Ebene = 'Scope'; ScopeId = $s.ScopeId; Option = $nr; Wert = ($o[$nr] -join ', ') } } }
    }
    $wahl = Select-NetItem -Elemente $eintraege -Titel 'Welche Zusatzoption entfernen?' -Eigenschaften @('Ebene', 'ScopeId', 'Option', 'Wert')
    if (-not $wahl) { return }
    $p = @{ OptionId = [int]$wahl.Option }
    if ($wahl.ScopeId) { $p.ScopeId = $wahl.ScopeId }
    $altWert = @($wahl.Wert.Split(',') | ForEach-Object { $_.Trim() })
    Invoke-NetChange -Titel ('DHCP-Option {0:000} entfernen' -f [int]$wahl.Option) -Stufe Bestaetigen -Vorher $wahl.Wert -Nachher '(nicht gesetzt)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4OptionValue @p
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4OptionValue'; Parameter = ($p + @{ Value = $altWert; Force = $true }) } | Out-Null
}
#
function Show-NetDhcpExtraOptionMenu {
    $eintraege = @(
        @{ Text = 'Zusatzoption setzen (042, 066, 067, 119)'; Aktion = { Set-NetDhcpExtraOption | Out-Null }; Hilfe = "Alle Zusatzoptionen sind standardmaessig aus und nur bei Bedarf noetig.`n042 NTP-Server, 066/067 PXE-Netzwerkboot, 119 DNS-Suchliste (wird bei Bedarf definiert und nach RFC 3397 kodiert)." },
        @{ Text = 'Zusatzoption entfernen'; Aktion = 'Remove-NetDhcpExtraOption'; Hilfe = 'Entfernt eine gesetzte Zusatzoption auf Server- oder Scope-Ebene (rueckgaengig moeglich).' }
    )
    Show-NetMenu -Titel 'DHCP - Zusatzoptionen' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/dhcp/DhcpReservierung.ps1
# ----------------------------------------------------------------------
# Reservierungen (auch aus einem bestehenden Lease in einem Schritt) und Leases.
#
function ConvertTo-NetMacAddress {
    <#
    .SYNOPSIS
        Normalisiert eine MAC-Adresse auf aa-bb-cc-dd-ee-ff. Liefert $null bei ungueltiger Eingabe.
    #>
    param([AllowEmptyString()][string]$Text)
    $roh = ($Text -replace '[\s:.-]', '').ToLower()
    if ($roh -notmatch '^[0-9a-f]{12}$') { return $null }
    return (($roh -split '(..)' | Where-Object { $_ }) -join '-')
}
#
function Get-NetDhcpLeaseList {
    param([string]$ScopeId)
    $scopes = @()
    if ($ScopeId) { $scopes = @($ScopeId) } else { $scopes = @(Get-NetDhcpScopeList | ForEach-Object { $_.ScopeId }) }
    $liste = @()
    foreach ($id in $scopes) {
        foreach ($l in @(Get-NetSafe -Beschreibung "Leases $id" -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id })) {
            if ($null -eq $l) { continue }
            $liste += [pscustomobject]@{
                ScopeId  = $id
                IP       = ConvertTo-NetString -Wert $l.IPAddress
                Mac      = [string]$l.ClientId
                Name     = [string]$l.HostName
                Status   = [string]$l.AddressState
                Ablauf   = $l.LeaseExpiryTime
            }
        }
    }
    return $liste
}
#
function Test-NetDhcpReservation {
    <#
    .SYNOPSIS
        Prueft eine geplante Reservierung: im Scope-Bereich, nicht im Ausschluss, nicht belegt.
        Liefert eine Liste von Problemen (leer = in Ordnung).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][string]$Mac,
        [object[]]$Ausschluesse = $null,
        [object[]]$Reservierungen = $null,
        [object[]]$Leases = $null
    )
    $probleme = @()
    $id = $Scope.ScopeId
    if (-not (Test-NetIPInRange -IPAddress $IPAddress -Start $Scope.Start -Ende $Scope.Ende)) {
        $probleme += ('{0} liegt nicht im Bereich des Scopes ({1} - {2}).' -f $IPAddress, $Scope.Start, $Scope.Ende)
    }
    if ($null -eq $Ausschluesse) { $Ausschluesse = @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id }) }
    foreach ($a in @($Ausschluesse | Where-Object { $_ })) {
        if (Test-NetIPInRange -IPAddress $IPAddress -Start (ConvertTo-NetString $a.StartRange) -Ende (ConvertTo-NetString $a.EndRange)) {
            $probleme += ('{0} liegt in einem Ausschluss ({1} - {2}).' -f $IPAddress, (ConvertTo-NetString $a.StartRange), (ConvertTo-NetString $a.EndRange))
        }
    }
    if ($null -eq $Reservierungen) { $Reservierungen = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id }) }
    foreach ($r in @($Reservierungen | Where-Object { $_ })) {
        $rIp = ConvertTo-NetString $r.IPAddress
        $rMac = ConvertTo-NetMacAddress -Text ([string]$r.ClientId)
        if ($rIp -eq $IPAddress -and $rMac -ne $Mac) { $probleme += ('{0} ist schon fuer {1} ({2}) reserviert.' -f $IPAddress, $rMac, $r.Name) }
        if ($rMac -eq $Mac -and $rIp -ne $IPAddress) { $probleme += ('Dieses Geraet ({0}) hat schon die Reservierung {1}.' -f $Mac, $rIp) }
    }
    if ($null -eq $Leases) { $Leases = @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id }) }
    foreach ($l in @($Leases | Where-Object { $_ })) {
        $lIp = ConvertTo-NetString $l.IPAddress
        $lMac = ConvertTo-NetMacAddress -Text ([string]$l.ClientId)
        if ($lIp -eq $IPAddress -and $lMac -and $lMac -ne $Mac) { $probleme += ('{0} ist zurzeit an ein anderes Geraet vergeben ({1}, {2}).' -f $IPAddress, $lMac, $l.HostName) }
    }
    return $probleme
}
#
function Add-NetDhcpReservation {
    <#
    .SYNOPSIS
        Reservierung anlegen (mit Pruefung), optional mit DNS-Eintrag.
    #>
    param([object]$Scope, [string]$IPAddress, [string]$Mac, [string]$Name, [string]$Beschreibung = '', [switch]$OhneDnsFrage)
    if (-not (Test-NetDhcpReady)) { return $false }
    if (-not $Scope) { $Scope = Select-NetDhcpScope -Titel 'Reservierung in welchem Scope?' }
    if (-not $Scope) { return $false }
    if (-not $Mac) {
        $Mac = Read-NetText -Frage 'MAC-Adresse des Geraets (z. B. 00-15-5D-01-02-03)' -Pruefung { param($t) if (ConvertTo-NetMacAddress -Text $t) { $null } else { 'Bitte 12 Hex-Zeichen eingeben, z. B. 00-15-5D-01-02-03.' } }
        if (-not $Mac) { return $false }
    }
    $Mac = ConvertTo-NetMacAddress -Text $Mac
    if (-not $Mac) { Write-Log -Level Fehler -Message 'Ungueltige MAC-Adresse.'; return $false }
    if (-not $IPAddress) {
        $IPAddress = Read-NetIPAddress -Frage 'Reservierte IP-Adresse' -Netz $Scope.ScopeId -Prefix $Scope.Prefix
        if (-not $IPAddress) { return $false }
    }
    if (-not $Name) {
        $Name = Read-NetText -Frage 'Name des Geraets (z. B. drucker-buero)' -Pruefung { param($t) Test-NetDnsRecordName -Name $t }
        if (-not $Name) { return $false }
    }
    $id = $Scope.ScopeId
    $vorhanden = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })
    $gleich = @($vorhanden | Where-Object { $_ -and (ConvertTo-NetString $_.IPAddress) -eq $IPAddress -and (ConvertTo-NetMacAddress -Text ([string]$_.ClientId)) -eq $Mac })
    if ($gleich.Count -gt 0) { Write-Log -Level OK -Message "Die Reservierung $IPAddress fuer $Mac existiert bereits. Nichts zu tun."; return $true }
    $probleme = @(Test-NetDhcpReservation -Scope $Scope -IPAddress $IPAddress -Mac $Mac -Reservierungen $vorhanden)
    if ($probleme.Count -gt 0) {
        foreach ($p in $probleme) { Write-Log -Level Fehler -Message $p }
        Write-Log -Message 'Naechster Schritt: eine andere Adresse waehlen bzw. den Konflikt beheben. Die Reservierung wird nicht angelegt.'
        return $false
    }
    $ip = $IPAddress
    $mac = $Mac
    $geraet = $Name
    $text = $Beschreibung
    $r = Invoke-NetChange -Titel "Reservierung $ip fuer $geraet anlegen" -Stufe Bestaetigen -Vorher '(keine Reservierung)' -Nachher @{ Scope = $id; IP = $ip; MAC = $mac; Name = $geraet } -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Reservation -ScopeId $id -IPAddress $ip -ClientId $mac -Name $geraet -Description $text
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Reservation'; Parameter = @{ IPAddress = $ip } }
    $ok = [bool]($r.Erfolg -and -not $r.Probelauf)
    if ($ok -and -not $OhneDnsFrage -and (Test-NetCommand -Name 'Add-NetDnsRecord') -and (Test-NetDnsReady -Still)) {
        $zone = Get-NetDomainName
        if ($zone -and (Read-NetYesNo -Frage ("Passenden DNS-Eintrag {0}.{1} -> {2} (mit PTR) anlegen?" -f $geraet, $zone, $ip) -Vorschlag $true)) {
            Add-NetDnsRecord -Zone $zone -Name $geraet -Typ A -Daten @{ IPv4Address = $ip } -MitPtr $true | Out-Null
        }
    }
    return $ok
}
#
function Add-NetDhcpReservationFromLease {
    <#
    .SYNOPSIS
        Macht aus einem bestehenden Lease in einem Schritt eine Reservierung.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    $leases = @(Get-NetDhcpLeaseList | Where-Object { $_.Status -like 'Active*' -and $_.Status -notlike '*Reservation*' })
    if ($leases.Count -eq 0) { Write-Log -Level Warn -Message 'Es gibt keine aktiven Leases ohne Reservierung.'; return $false }
    $l = Select-NetItem -Elemente $leases -Titel 'Welches Geraet soll seine Adresse behalten?' -Eigenschaften @('IP', 'Mac', 'Name', 'ScopeId')
    if (-not $l) { return $false }
    $scope = @(Get-NetDhcpScopeList | Where-Object { $_.ScopeId -eq $l.ScopeId }) | Select-Object -First 1
    $name = ([string]$l.Name).Split('.')[0]
    if (-not $name) { $name = 'geraet-' + ($l.IP -replace '\.', '-') }
    return (Add-NetDhcpReservation -Scope $scope -IPAddress $l.IP -Mac $l.Mac -Name $name -Beschreibung 'aus Lease uebernommen (NetSetup)' -OhneDnsFrage)
}
#
function Show-NetDhcpReservation {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'Reservierungen'
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $id = $s.ScopeId
        $liste = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })
        Write-Host ('  Scope {0} ({1}): {2} Reservierung(en)' -f $id, $s.Name, @($liste | Where-Object { $_ }).Count) -ForegroundColor White
        foreach ($r in @($liste | Where-Object { $_ })) {
            $ip = ConvertTo-NetString $r.IPAddress
            $warn = ''
            if (-not (Test-NetIPInRange -IPAddress $ip -Start $s.Start -Ende $s.Ende)) { $warn = '  [WARN] ausserhalb des Bereichs' }
            Write-Host ('    {0,-15} {1,-18} {2}{3}' -f $ip, $r.ClientId, $r.Name, $warn)
        }
    }
}
#
function Remove-NetDhcpReservation {
    if (-not (Test-NetDhcpReady)) { return }
    $alle = @()
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $id = $s.ScopeId
        foreach ($r in @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })) {
            if ($r) { $alle += [pscustomobject]@{ ScopeId = $id; IP = (ConvertTo-NetString $r.IPAddress); Mac = [string]$r.ClientId; Name = [string]$r.Name; Beschreibung = [string]$r.Description } }
        }
    }
    $w = Select-NetItem -Elemente $alle -Titel 'Welche Reservierung loeschen?' -Eigenschaften @('ScopeId', 'IP', 'Mac', 'Name')
    if (-not $w) { return }
    $ip = $w.IP
    Invoke-NetChange -Titel "Reservierung $ip ($($w.Name)) loeschen" -Stufe Bestaetigen -Vorher ('{0} {1} {2}' -f $w.IP, $w.Mac, $w.Name) -Nachher '(geloescht)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4Reservation -IPAddress $ip
    } -Rueckgaengig @{ Befehl = 'Add-DhcpServerv4Reservation'; Parameter = @{ ScopeId = $w.ScopeId; IPAddress = $w.IP; ClientId = $w.Mac; Name = $w.Name; Description = $w.Beschreibung } } | Out-Null
}
#
function Show-NetDhcpLease {
    param([string]$Suche)
    if (-not (Test-NetDhcpReady)) { return }
    $liste = @(Get-NetDhcpLeaseList)
    if ($Suche) { $liste = @($liste | Where-Object { $_.IP -like "*$Suche*" -or $_.Mac -like "*$Suche*" -or $_.Name -like "*$Suche*" }) }
    Write-NetTitle -Titel ('Leases ({0})' -f $liste.Count)
    foreach ($l in ($liste | Sort-Object -Property { ConvertTo-NetIPv4UInt32 -IPAddress $_.IP })) {
        Write-Host ('  {0,-15} {1,-18} {2,-30} {3,-18} bis {4}' -f $l.IP, $l.Mac, $l.Name, $l.Status, $l.Ablauf)
    }
}
#
function Find-NetDhcpLease {
    $s = Read-NetText -Frage 'Suchbegriff (Teil von IP, MAC oder Name)'
    if ($s) { Show-NetDhcpLease -Suche $s }
}
#
function Remove-NetDhcpLease {
    if (-not (Test-NetDhcpReady)) { return }
    $l = Select-NetItem -Elemente @(Get-NetDhcpLeaseList) -Titel 'Welches Lease loeschen?' -Eigenschaften @('IP', 'Mac', 'Name', 'Status')
    if (-not $l) { return }
    $ip = $l.IP
    Invoke-NetChange -Titel "Lease $ip ($($l.Name)) loeschen" -Stufe Bestaetigen -Vorher ('{0} {1} {2}' -f $l.IP, $l.Mac, $l.Name) -Nachher '(geloescht - das Geraet bekommt beim naechsten Erneuern eine neue Adresse)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4Lease -IPAddress $ip
    } | Out-Null
}
#
function Show-NetDhcpReservationMenu {
    $eintraege = @(
        @{ Text = 'Reservierungen anzeigen'; Aktion = 'Show-NetDhcpReservation'; Hilfe = 'Alle Reservierungen pro Scope; Reservierungen ausserhalb des Bereichs werden markiert.' },
        @{ Text = 'Reservierung anlegen'; Aktion = { Add-NetDhcpReservation | Out-Null }; Hilfe = "Feste Adresse fuer ein Geraet (MAC). Vorher wird geprueft: im Bereich, nicht im Ausschluss, nicht an ein anderes Geraet vergeben.`nAuf Wunsch wird gleich der DNS-Eintrag (A + PTR) angelegt." },
        @{ Text = 'Reservierung aus bestehendem Lease'; Aktion = { Add-NetDhcpReservationFromLease | Out-Null }; Hilfe = 'Ein Geraet behaelt seine aktuelle Adresse dauerhaft - in einem Schritt.' },
        @{ Text = 'Reservierung loeschen'; Aktion = 'Remove-NetDhcpReservation'; Hilfe = 'Loescht eine Reservierung (rueckgaengig moeglich).' },
        @{ Text = 'Leases anzeigen'; Aktion = { Show-NetDhcpLease }; Hilfe = 'Alle vergebenen Adressen mit MAC, Name, Status und Ablauf.' },
        @{ Text = 'Lease suchen'; Aktion = 'Find-NetDhcpLease'; Hilfe = 'Sucht nach Teil von IP, MAC oder Name.' },
        @{ Text = 'Lease loeschen'; Aktion = 'Remove-NetDhcpLease'; Hilfe = 'Gibt eine Adresse frei. Das Geraet holt sich beim naechsten Erneuern eine neue Adresse.' },
        @{ Text = 'Konflikterkennung einstellen'; Aktion = { Set-NetDhcpConflictDetection | Out-Null }; Hilfe = 'Der Server pingt eine Adresse vor der Vergabe (Vorschlag: 1 Versuch), um Doppelvergaben zu vermeiden.' }
    )
    Show-NetMenu -Titel 'DHCP - Reservierungen und Leases' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/dhcp/DhcpFailover.ps1
# ----------------------------------------------------------------------
# DHCP-Failover: Partner pruefen (Rolle, autorisiert, erreichbar), Lastverteilung oder Reserve,
# gemeinsames Geheimnis verdeckt, Status anzeigen, Replikation ausloesen.
#
function Test-NetTcpPort {
    <#
    .SYNOPSIS
        Prueft, ob ein TCP-Port erreichbar ist (nur .NET-Bordmittel, mit Zeitlimit).
    #>
    param([Parameter(Mandatory = $true)][string]$Ziel, [Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Ziel, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($ar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}
#
function Test-NetDhcpFailoverPartner {
    <#
    .SYNOPSIS
        Prueft den Failover-Partner. Liefert eine Liste von Problemen (leer = bereit).
    #>
    param([Parameter(Mandatory = $true)][string]$Partner)
    $probleme = @()
    $aufgeloest = Get-NetSafe -Beschreibung "Aufloesung $Partner" -Abfrage { Resolve-DnsName -Name $Partner -Type A -DnsOnly -QuickTimeout }
    if (-not $aufgeloest) { $probleme += "Der Name $Partner laesst sich im DNS nicht aufloesen." }
    if (-not (Test-NetTcpPort -Ziel $Partner -Port 647)) { $probleme += "$Partner ist auf TCP-Port 647 (DHCP-Failover) nicht erreichbar: DHCP-Dienst aus, Firewall oder falscher Name." }
    $einst = Get-NetSafe -Beschreibung "DHCP auf $Partner" -Abfrage { Get-DhcpServerSetting -ComputerName $Partner }
    if (-not $einst) { $probleme += "Auf $Partner ist kein DHCP-Server erreichbar (Rolle fehlt oder keine Rechte)." }
    elseif ($einst.IsDomainJoined -and -not $einst.IsAuthorized) { $probleme += "$Partner ist nicht im AD autorisiert." }
    return $probleme
}
#
function Show-NetDhcpFailover {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCP-Failover'
    $liste = @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover })
    if (@($liste | Where-Object { $_ }).Count -eq 0) { Write-Log -Message 'Kein Failover eingerichtet.'; return }
    foreach ($f in @($liste | Where-Object { $_ })) {
        $status = 'OK'
        if ([string]$f.State -ne 'Normal') { $status = 'WARN' }
        Write-NetStatus -Status $status -Bereich ([string]$f.Name) -Text ('Partner {0}, Modus {1}, Zustand {2}, Scopes {3}' -f $f.PartnerServer, $f.Mode, $f.State, ((@($f.ScopeId) | ForEach-Object { ConvertTo-NetString $_ }) -join ', '))
    }
}
#
function New-NetDhcpFailover {
    <#
    .SYNOPSIS
        Failover-Assistent. Bricht sauber ab, wenn der Partner nicht bereit ist.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    Write-NetTitle -Titel 'DHCP-Failover einrichten'
    Write-NetText -Text "Zwei DHCP-Server teilen sich Scopes. Lastverteilung: beide vergeben je die Haelfte. Reserve (Hot-Standby): einer arbeitet,`nder andere haelt einige Prozent zurueck und uebernimmt bei Ausfall. Der Partner braucht die DHCP-Rolle, muss autorisiert und ueber TCP 647 erreichbar sein."
    $partner = Read-NetText -Frage 'Name des Partner-DHCP-Servers (z. B. dc02.ad.firma.ch)' -Pruefung { param($t) if ($t -match '^[A-Za-z0-9.-]+$') { $null } else { 'Ungueltiger Name.' } }
    if (-not $partner) { return $false }
    Write-Log -Message "Pruefe den Partner $partner ..."
    $probleme = @(Test-NetDhcpFailoverPartner -Partner $partner)
    if ($probleme.Count -gt 0) {
        foreach ($p in $probleme) { Write-Log -Level Fehler -Message $p }
        Write-Log -Message 'Der Partner ist nicht bereit. Es wurde nichts geaendert. Naechster Schritt: auf dem Partner NetSetup ausfuehren (DHCP-Rolle installieren, autorisieren) und Firewall pruefen.'
        return $false
    }
    Write-Log -Level OK -Message "Der Partner $partner ist bereit."
    $vorhanden = @(Get-NetSafe -Beschreibung 'Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover } | Where-Object { $_ } | ForEach-Object { @($_.ScopeId | ForEach-Object { ConvertTo-NetString $_ }) })
    $frei = @(Get-NetDhcpScopeList | Where-Object { $vorhanden -notcontains $_.ScopeId })
    if ($frei.Count -eq 0) { Write-Log -Level Warn -Message 'Alle Scopes sind bereits in einer Failover-Beziehung (oder es gibt keine).'; return $false }
    $wahl = @(Select-NetItem -Elemente $frei -Titel 'Welche Scopes sollen ausfallsicher werden?' -Eigenschaften @('ScopeId', 'Name', 'Start', 'Ende') -Mehrfach)
    if ($wahl.Count -eq 0) { return $false }
    $modus = Read-NetChoice -Frage 'Modus' -Optionen @('Lastverteilung 50/50 (empfohlen)', 'Reserve / Hot-Standby (dieser Server aktiv, Partner haelt 5 % zurueck)') -Vorschlag 1
    if ($modus -lt 0) { return $false }
    Write-NetText -Text 'Das gemeinsame Geheimnis sichert die Verbindung der beiden Server. Es wird nicht gespeichert.'
    $geheim = Read-NetSecret -Frage 'Gemeinsames Geheimnis' -Bestaetigen -MinLaenge 8
    if (-not $geheim) { return $false }
    $name = Read-NetText -Frage 'Name der Failover-Beziehung' -Vorschlag (('{0}-{1}' -f [Environment]::MachineName, $partner.Split('.')[0]).ToUpper())
    if (-not $name) { return $false }
    $ids = @($wahl | ForEach-Object { $_.ScopeId })
    $art = 'Lastverteilung 50 %'
    if ($modus -eq 1) { $art = 'Reserve (Hot-Standby), 5 % Reserve' }
    $r = Invoke-NetChange -Titel "DHCP-Failover $name mit $partner einrichten" -Stufe Bestaetigen -Vorher '(kein Failover)' -Nachher @{ Name = $name; Partner = $partner; Modus = $art; Scopes = ($ids -join ', '); Geheimnis = '(verdeckt)' } -BackupBereich @('Dhcp') -Aktion {
        $klar = ConvertFrom-NetSecureString -Geheim $geheim
        try {
            if ($modus -eq 0) { Add-DhcpServerv4Failover -Name $name -PartnerServer $partner -ScopeId $ids -LoadBalancePercent 50 -SharedSecret $klar -Force }
            else { Add-DhcpServerv4Failover -Name $name -PartnerServer $partner -ScopeId $ids -ServerRole Active -ReservePercent 5 -SharedSecret $klar -Force }
        }
        finally { $klar = $null }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Failover'; Parameter = @{ Name = $name; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Sync-NetDhcpFailover {
    <#
    .SYNOPSIS
        Repliziert die Scope-Einstellungen zum Partner (Optionen, Reservierungen, Ausschluesse).
    #>
    if (-not (Test-NetDhcpReady)) { return }
    $liste = @(Get-NetSafe -Beschreibung 'Failover' -Standard @() -Abfrage { Get-DhcpServerv4Failover } | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Partner = [string]$_.PartnerServer; Zustand = [string]$_.State } })
    $f = Select-NetItem -Elemente $liste -Titel 'Welche Failover-Beziehung replizieren?' -Eigenschaften @('Name', 'Partner', 'Zustand')
    if (-not $f) { return }
    $name = $f.Name
    Invoke-NetChange -Titel "Einstellungen von $name zum Partner replizieren" -Stufe Bestaetigen -Vorher 'Partner hat evtl. veraltete Einstellungen' -Nachher 'Partner hat die Einstellungen dieses Servers' -Hinweis 'Die Einstellungen dieses Servers ueberschreiben die des Partners fuer die betroffenen Scopes.' -BackupBereich @('Dhcp') -Aktion {
        Invoke-DhcpServerv4FailoverReplication -Name $name -Force | Out-Null
    } | Out-Null
}
#
function Show-NetDhcpFailoverMenu {
    $eintraege = @(
        @{ Text = 'Status anzeigen'; Aktion = 'Show-NetDhcpFailover'; Hilfe = 'Zeigt alle Failover-Beziehungen mit Partner, Modus, Zustand (Normal = in Ordnung) und Scopes.' },
        @{ Text = 'Failover einrichten (Assistent)'; Aktion = { New-NetDhcpFailover | Out-Null }; Hilfe = "Prueft zuerst den Partner (Name, TCP 647, DHCP-Rolle, Autorisierung) und bricht sauber ab, wenn er nicht bereit ist.`nDann Lastverteilung oder Reserve waehlen und ein gemeinsames Geheimnis verdeckt eingeben." },
        @{ Text = 'Replikation ausloesen'; Aktion = 'Sync-NetDhcpFailover'; Hilfe = 'Nach Aenderungen an Optionen, Reservierungen oder Ausschluessen: Einstellungen zum Partner uebertragen.' }
    )
    Show-NetMenu -Titel 'DHCP - Failover' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/dhcp/DhcpMenue.ps1
# ----------------------------------------------------------------------
# DHCP: Uebersicht, Einrichtungs-Assistent und Menue.
#
function Show-NetDhcpOverview {
    if (-not (Test-NetDhcpReady)) { return }
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'DHCP-Uebersicht'
    $auth = Test-NetDhcpAuthorized
    if ($null -eq $auth) { Write-NetStatus -Status NA -Bereich 'Autorisierung' -Text 'keine Domaene - nicht noetig' }
    elseif ($auth) { Write-NetStatus -Status OK -Bereich 'Autorisierung' -Text 'im AD autorisiert' }
    else { Write-NetStatus -Status FEHLER -Bereich 'Autorisierung' -Text 'NICHT autorisiert - der Server vergibt keine Adressen' }
    if ($z.Dhcp.Nachkonfiguriert) { Write-NetStatus -Status OK -Bereich 'Nachkonfiguration' -Text 'erledigt' }
    else { Write-NetStatus -Status WARN -Bereich 'Nachkonfiguration' -Text 'fehlt (Server-Manager meldet "Konfiguration erforderlich")' }
    Write-NetStatus -Status INFO -Bereich 'Konflikterkennung' -Text ('{0} Versuch(e)' -f $z.Dhcp.KonfliktErkennung)
    Show-NetDhcpScope
    if (@($z.Dhcp.Failover).Count -gt 0) { Show-NetDhcpFailover }
}
#
function Start-NetDhcpSetup {
    <#
    .SYNOPSIS
        Assistent: Rolle, Nachkonfiguration, Autorisierung, Bindungen, erster Scope, Optionen.
        Ueberspringt alles, was schon passt.
    #>
    Write-NetTitle -Titel 'DHCP einrichten'
    $z = Get-NetSetupState
    $andererServer = @($z.Netzwerk.AktiveKarten | Where-Object { $_.Dhcp })
    if ($andererServer.Count -gt 0) {
        Write-Log -Level Warn -Message 'Dieser Server bezieht seine eigene Adresse per DHCP. Ein DHCP-Server braucht eine feste IP (sonst bindet er nicht).'
        if (Read-NetYesNo -Frage 'Jetzt eine feste IP setzen?' -Vorschlag $true) { Set-NetStaticAddress -Karte $andererServer[0] | Out-Null }
    }
    if (-not ($z.Dhcp.Installiert -and $z.Dhcp.Tools)) {
        if (-not (Install-NetDhcpRole)) { return }
    }
    elseif (-not $z.Dhcp.Nachkonfiguriert) { Complete-NetDhcpPostInstall | Out-Null }
    else { Write-Log -Level OK -Message 'DHCP-Rolle installiert und nachkonfiguriert.' }
    if (-not (Test-NetDhcpReady)) { return }
    $auth = Test-NetDhcpAuthorized
    if ($auth -eq $false) { Add-NetDhcpAuthorization | Out-Null }
    elseif ($null -eq $auth) { Write-Log -Message 'Keine Domaene: Autorisierung nicht noetig.' }
    else { Write-Log -Level OK -Message 'Im AD autorisiert.' }
    $z = Get-NetSetupState
    if (@($z.Dhcp.Bindungen | Where-Object { $_.Aktiv }).Count -eq 0 -and @($z.Dhcp.Bindungen).Count -gt 0) {
        Write-Log -Level Warn -Message 'Der DHCP-Server ist an keine Netzwerkkarte gebunden.'
        Set-NetDhcpBinding
    }
    if (@($z.Dhcp.Scopes).Count -eq 0) {
        Write-Log -Message 'Es gibt noch keinen Scope. Der Scope-Assistent startet.'
        New-NetDhcpScope | Out-Null
    }
    else {
        Write-Log -Level OK -Message (('{0} Scope(s) vorhanden: ' -f @($z.Dhcp.Scopes).Count) + (($z.Dhcp.Scopes | ForEach-Object { $_.ScopeId }) -join ', '))
        foreach ($s in @($z.Dhcp.Scopes)) {
            $fehlt = @(@('3', '6', '15') | Where-Object { -not $s.Optionen.ContainsKey($_) -and -not $z.Dhcp.ServerOptionen.ContainsKey($_) })
            if ($fehlt.Count -gt 0) { Write-Log -Level Warn -Message ('Im Scope {0} fehlen die Optionen {1}. Im Menue Scopes -> Optionen 003/006/015 ergaenzen.' -f $s.ScopeId, ($fehlt -join ', ')) }
            if (-not $s.Aktiv) { Write-Log -Level Warn -Message ('Der Scope {0} ist nicht aktiv.' -f $s.ScopeId) }
        }
        if (Read-NetYesNo -Frage 'Einen weiteren Scope (z. B. fuer ein anderes VLAN) anlegen?' -Vorschlag $false) { New-NetDhcpScope | Out-Null }
    }
    if ($z.Dhcp.KonfliktErkennung -eq 0 -and (Read-NetYesNo -Frage 'Konflikterkennung einschalten (1 Ping vor jeder Vergabe)?' -Vorschlag $true)) {
        Set-NetDhcpConflictDetection -Versuche 1 | Out-Null
    }
    Write-Log -Level OK -Message 'DHCP-Einrichtung abgeschlossen.'
}
#
function Show-NetDhcpScopeMenu {
    $eintraege = @(
        @{ Text = 'Scopes anzeigen'; Aktion = 'Show-NetDhcpScope'; Hilfe = 'Alle Scopes mit Bereich, Status, Lease-Dauer, Auslastung, Optionen 003/006/015 und Ausschluessen.' },
        @{ Text = 'Neuer Scope (Assistent)'; Aktion = { New-NetDhcpScope | Out-Null }; Hilfe = "Name, Netz, Bereich, Ausschluesse, Lease-Dauer (Vorschlag 8 Tage), Router (003), DNS-Server (006, Vorschlag: die DCs), Domaene (015).`nUngueltige Bereiche werden abgelehnt; fuer andere Netze (VLANs) Hinweis auf DHCP-Relay am Router." },
        @{ Text = 'Ausschluss hinzufuegen'; Aktion = 'Add-NetDhcpExclusion'; Hilfe = 'Adressen im Bereich, die nie vergeben werden (Drucker, Server, Router mit fester IP).' },
        @{ Text = 'Optionen 003/006/015 aendern'; Aktion = 'Set-NetDhcpStandardOption'; Hilfe = 'Router, DNS-Server und Domaene eines Scopes aendern.' },
        @{ Text = 'Scope aktivieren/deaktivieren'; Aktion = 'Switch-NetDhcpScopeState'; Hilfe = 'Ein deaktivierter Scope vergibt keine Adressen mehr.' },
        @{ Text = 'Superscope anlegen'; Aktion = 'New-NetDhcpSuperscope'; Hilfe = 'Mehrere Scopes im selben physischen Netz zusammenfassen. Fuer getrennte VLANs nicht noetig.' },
        @{ Text = 'Scope loeschen (gefaehrlich)'; Aktion = 'Remove-NetDhcpScope'; Hilfe = 'Loescht einen Scope mit allen Leases und Reservierungen. Vorher automatisches Backup, Servername eintippen.' }
    )
    Show-NetMenu -Titel 'DHCP - Scopes' -Eintraege $eintraege
}
#
function Show-NetDhcpMenu {
    $eintraege = @(
        @{ Text = 'Uebersicht'; Aktion = 'Show-NetDhcpOverview'; Hilfe = 'Autorisierung, Nachkonfiguration, Konflikterkennung, alle Scopes und Failover auf einen Blick.' },
        @{ Text = 'DHCP einrichten (Assistent)'; Aktion = 'Start-NetDhcpSetup'; Hilfe = 'Rolle, Nachkonfiguration, Autorisierung, Bindungen, erster Scope und Optionen - Erledigtes wird uebersprungen.' },
        @{ Text = 'Rolle installieren und nachkonfigurieren'; Aktion = { Install-NetDhcpRole | Out-Null }; Hilfe = 'Installiert die DHCP-Rolle aus dem lokalen Windows und fuehrt die Nachkonfiguration aus (Sicherheitsgruppen, ConfigurationState = 2, Dienstneustart).' },
        @{ Text = 'Im AD autorisieren'; Aktion = { Add-NetDhcpAuthorization | Out-Null }; Hilfe = 'In einer Domaene vergibt ein DHCP-Server erst nach der Autorisierung Adressen. Dafuer braucht es Organisations-Admins (Enterprise Admins). Ohne Domaene wird uebersprungen.' },
        @{ Text = 'Bindungen anzeigen'; Aktion = 'Show-NetDhcpBinding'; Hilfe = 'Auf welchen Netzwerkkarten der DHCP-Server antwortet.' },
        @{ Text = 'Bindungen einstellen'; Aktion = 'Set-NetDhcpBinding'; Hilfe = 'Nur Karten im Netz der Clients binden.' },
        @{ Text = 'Scopes'; Aktion = 'Show-NetDhcpScopeMenu'; OhnePause = $true; Hilfe = 'Scopes anzeigen, anlegen, Ausschluesse, Optionen, aktivieren/deaktivieren, Superscope, loeschen.' },
        @{ Text = 'Zusatzoptionen (NTP, PXE, Suchliste)'; Aktion = 'Show-NetDhcpExtraOptionMenu'; OhnePause = $true; Hilfe = 'Optionen 042, 066/067 und 119 - standardmaessig aus, auf Server- oder Scope-Ebene.' },
        @{ Text = 'Reservierungen und Leases'; Aktion = 'Show-NetDhcpReservationMenu'; OhnePause = $true; Hilfe = 'Reservierungen anlegen (auch aus einem Lease), pruefen, loeschen; Leases anzeigen, suchen, loeschen; Konflikterkennung.' },
        @{ Text = 'Failover'; Aktion = 'Show-NetDhcpFailoverMenu'; OhnePause = $true; Hilfe = 'Zweiter DHCP-Server fuer Ausfallsicherheit: Lastverteilung oder Reserve, Status, Replikation.' }
    )
    Show-NetMenu -Titel 'DHCP' -Eintraege $eintraege
}
# ----------------------------------------------------------------------
# src/ui/Ersteinrichtung.ps1
# ----------------------------------------------------------------------
# Ersteinrichtungs-Assistent: entscheidet anhand der Bestandsaufnahme die noetigen Schritte
# (AD -> DNS -> DHCP -> Verbindung -> Test), ueberspringt Erledigtes und ruft die Funktionen
# der einzelnen Bereiche auf. Fehlende Bereiche erscheinen als "kommt noch".
#
function Get-NetFirstSetupStep {
    <#
    .SYNOPSIS
        Liefert die Schritte der Ersteinrichtung mit Status (erledigt oder offen).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Zustand)
    $s = $Zustand.System
    $modus = [string](Get-NetConfigValue -Pfad 'AD.Modus' -Standard '')
    $forward = @($Zustand.Dns.Zonen | Where-Object { -not $_.Reverse -and $_.Typ -eq 'Primary' })
    $reverse = @($Zustand.Dns.Zonen | Where-Object { $_.Reverse })
    $aktiveScopes = @($Zustand.Dhcp.Scopes | Where-Object { $_.Aktiv })
    $e = $Zustand.Dhcp.DnsEinstellung
#
    $adText = 'Domaenencontroller einrichten oder Domaene beitreten'
    if ($s.IstDC) { $adText = 'Domaenencontroller fuer ' + $Zustand.AD.Domaene }
    elseif ($modus -eq 'OhneAD') { $adText = 'bewusst ohne AD' }
    elseif ($modus -eq 'Mitglied') { $adText = 'Mitgliedsserver, nur DNS/DHCP' }
#
    $dnsErledigt = $Zustand.Dns.Verfuegbar -and $Zustand.Dns.Laeuft -and ($forward.Count -gt 0) -and ($reverse.Count -gt 0)
    $dhcpErledigt = $Zustand.Dhcp.Verfuegbar -and $Zustand.Dhcp.Laeuft -and $Zustand.Dhcp.Nachkonfiguriert -and
        ((-not $Zustand.Dhcp.InDomaene) -or $Zustand.Dhcp.Autorisiert) -and ($aktiveScopes.Count -gt 0)
    $verbindungErledigt = $Zustand.Dhcp.Verfuegbar -and $e -and ($e.DynamicUpdates -eq 'Always') -and $e.DeleteDnsRROnLeaseExpiry -and
        ((-not $s.IstDC) -or $Zustand.Dhcp.DnsZugangsdaten.Gesetzt)
#
    return @(
        [pscustomobject]@{ Nr = 1; Name = 'Active Directory'; Funktion = 'Start-NetAdSetup'; Erledigt = [bool]($s.IstDC -or $modus -eq 'OhneAD' -or $modus -eq 'Mitglied'); Text = $adText },
        [pscustomobject]@{ Nr = 2; Name = 'DNS'; Funktion = 'Start-NetDnsSetup'; Erledigt = [bool]$dnsErledigt; Text = ('{0} Zone(n), {1} Reverse-Zone(n)' -f $forward.Count, $reverse.Count) },
        [pscustomobject]@{ Nr = 3; Name = 'DHCP'; Funktion = 'Start-NetDhcpSetup'; Erledigt = [bool]$dhcpErledigt; Text = ('{0} aktive(r) Scope(s)' -f $aktiveScopes.Count) },
        [pscustomobject]@{ Nr = 4; Name = 'DHCP + DNS verbinden'; Funktion = 'Start-NetIntegrationSetup'; Erledigt = [bool]$verbindungErledigt; Text = 'Clients automatisch mit A- und PTR-Eintrag' },
        [pscustomobject]@{ Nr = 5; Name = 'Test (Doktor)'; Funktion = 'Invoke-NetDoctor'; Erledigt = $false; Text = 'alles pruefen und Fehler beheben' }
    )
}
#
function Show-NetFirstSetupPlan {
    param([Parameter(Mandatory = $true)][object[]]$Schritte)
    foreach ($s in $Schritte) {
        if ($s.Erledigt) { Write-NetStatus -Status OK -Bereich ('{0}. {1}' -f $s.Nr, $s.Name) -Text ('erledigt - ' + $s.Text) }
        elseif (-not (Test-NetCommand -Name $s.Funktion)) { Write-NetStatus -Status NA -Bereich ('{0}. {1}' -f $s.Nr, $s.Name) -Text 'offen - kommt in einer spaeteren Version' }
        else { Write-NetStatus -Status WARN -Bereich ('{0}. {1}' -f $s.Nr, $s.Name) -Text ('offen - ' + $s.Text) }
    }
}
#
function Start-NetFirstSetup {
    <#
    .SYNOPSIS
        Fuehrt durch die komplette Einrichtung und ueberspringt bereits Erledigtes.
    #>
    Write-NetTitle -Titel 'Ersteinrichtung'
    Write-NetText -Text "Der Assistent prueft den Server und fuehrt nur die noch offenen Schritte aus:`n  1. Active Directory  2. DNS  3. DHCP  4. DHCP + DNS verbinden  5. Test`nJeder Schritt zeigt vorher, was er aendert, und fragt nach." -Farbe White
    $uebersprungen = @()
    $versuche = @{}
    while ($true) {
        $zustand = Get-NetSetupState
        $schritte = @(Get-NetFirstSetupStep -Zustand $zustand)
        Write-Host ''
        Show-NetFirstSetupPlan -Schritte $schritte
        $naechster = $schritte | Where-Object { -not $_.Erledigt -and ($uebersprungen -notcontains $_.Nr) } | Select-Object -First 1
        if (-not $naechster) {
            Write-Log -Level OK -Message 'Die Ersteinrichtung ist abgeschlossen (bzw. alle offenen Schritte wurden uebersprungen).'
            return
        }
        if (-not (Test-NetCommand -Name $naechster.Funktion)) {
            Write-Log -Level Warn -Message ('Schritt {0} ({1}) kommt in einer spaeteren Version und wird uebersprungen.' -f $naechster.Nr, $naechster.Name)
            $uebersprungen += $naechster.Nr
            continue
        }
        $versuche[$naechster.Nr] = 1 + [int]$versuche[$naechster.Nr]
        if ($versuche[$naechster.Nr] -gt 1) {
            Write-Log -Level Warn -Message ('Schritt {0} ({1}) ist noch nicht abgeschlossen.' -f $naechster.Nr, $naechster.Name)
            $wahl = Read-NetChoice -Frage 'Wie weiter?' -Optionen @('Schritt erneut ausfuehren', 'Schritt ueberspringen', 'Assistent beenden') -Vorschlag 1
            if ($wahl -eq 1) { $uebersprungen += $naechster.Nr; continue }
            if ($wahl -ne 0) { return }
        }
        elseif (-not (Read-NetYesNo -Frage ('Naechster Schritt: {0}. {1}. Jetzt ausfuehren?' -f $naechster.Nr, $naechster.Name) -Vorschlag $true)) {
            Write-Log -Message 'Assistent beendet. Er kann jederzeit erneut gestartet werden und macht dort weiter.'
            return
        }
        $script:NS.AssistentAktiv = $true
        try { & $naechster.Funktion }
        catch { Write-NetError -Fehler $_ -Titel $naechster.Name | Out-Null }
        finally { $script:NS.AssistentAktiv = $false }
        if ($naechster.Nr -eq 5) { $uebersprungen += 5 }
        if ($script:NS.NeustartGeplant) {
            Write-Log -Message 'Nach dem Neustart setzt NetSetup den Assistenten automatisch fort.'
            return
        }
    }
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
            Text   = 'Bestandsaufnahme (Zustand des Servers)'
            Aktion = 'Show-NetInventoryMenu'
            Hilfe  = "Zeigt, was auf dem Server schon eingerichtet ist: Rolle, Funktionen, Dienste, Netzwerk, DNS, DHCP, Zeit.`nNur lesend. Kann gefundene DNS-/DHCP-Einstellungen in die NetSetup-Konfiguration uebernehmen."
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
