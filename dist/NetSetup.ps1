<#
    NetSetup 0.0.0 (Build 2026-10-22 22:20)
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
$script:NetSetupBuildDatum = '2026-10-22 22:20'
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
    LetzterDoktor   = $null
    ErweitertFrei   = $false
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
    $PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }
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
    if ($script:NetUndoModule -contains [string]$cmd.ModuleName) { return $true }
    # Befehle der Server-Module auch am Namen erkennen (z. B. wenn das Modul anders geladen wurde).
    return ($Befehl -match '^[A-Za-z]+-(DnsServer|DhcpServer|NetIPAddress|NetIPInterface|NetRoute|DnsClient|NetFirewall|AD[A-Z]|WindowsFeature|ScheduledTask|Item$|ItemProperty$|Computer$)')
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
    $versuche = 0
    while ($true) {
        $versuche++
        if ($versuche -gt 25) {
            Write-Log -Level Warn -Message 'Zu viele ungueltige Eingaben, Abbruch.'
            return $null
        }
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
# src/integration/Verbindung.ps1
# ----------------------------------------------------------------------
# DHCP traegt automatisch in DNS ein: jeder Client bekommt A- und PTR-Eintrag,
# abgelaufene Leases entfernen ihre Eintraege wieder. Mit Pruefung aller aktiven Leases.
#
$script:NetIntegrationHilfe = @'
Damit jeder DHCP-Client automatisch im DNS steht:
  - DHCP-Server: "immer aktualisieren" (Always), auch fuer aeltere Clients, und Eintraege beim
    Ablauf der Lease loeschen. Das gilt fuer den Server und jeden Scope.
  - DNS-Zonen: dynamische Updates an (auf DCs: nur sicher), Reverse-Zone fuer jeden Scope.
  - Zugangsdaten: der DHCP-Server traegt mit einem eigenen Dienstkonto ein (Vorschlag svc-dhcpdns).
    Laeuft DHCP auf einem DC ohne Dienstkonto, gehoeren die Eintraege dem DC-Computerkonto - das
    ist ein Sicherheitsrisiko und macht Probleme, wenn Eintraege spaeter aktualisiert werden.
  - Aufraeumen: No-Refresh + Refresh mindestens so lang wie die Lease-Dauer.
'@
#
function Get-NetDhcpDnsSettingInfo {
    param([string]$ScopeId)
    $e = $null
    if ($ScopeId) { $e = Get-NetSafe -Beschreibung "DNS-Einstellung $ScopeId" -Abfrage { Get-DhcpServerv4DnsSetting -ScopeId $ScopeId } }
    else { $e = Get-NetSafe -Beschreibung 'DNS-Einstellung Server' -Abfrage { Get-DhcpServerv4DnsSetting } }
    return (ConvertTo-NetDhcpDnsSetting -Einstellung $e)
}
#
function Test-NetDhcpDnsSettingOk {
    param([hashtable]$Einstellung)
    if (-not $Einstellung) { return $false }
    return (($Einstellung.DynamicUpdates -eq 'Always') -and $Einstellung.DeleteDnsRROnLeaseExpiry -and $Einstellung.UpdateDnsRRForOlderClients -and -not $Einstellung.DisableDnsPtrRRUpdate)
}
#
function Set-NetDhcpDnsSetting {
    <#
    .SYNOPSIS
        Setzt die DNS-Einstellungen des DHCP-Servers server- und scopeweit.
    #>
    param([Nullable[bool]]$Namensschutz = $null)
    if (-not (Test-NetDhcpReady)) { return $false }
    if ($null -eq $Namensschutz) {
        Write-NetText -Text 'Namensschutz verhindert, dass ein Geraet den DNS-Namen eines anderen uebernimmt. Nachteil: Geraete, die vorher selbst eingetragen waren, muessen ihre alten Eintraege erst verlieren. Fuer neue Netze empfohlen.'
        $Namensschutz = Read-NetYesNo -Frage 'Namensschutz einschalten?' -Vorschlag $false
    }
    $ziele = @(@{ ScopeId = ''; Name = 'Server' })
    foreach ($s in @(Get-NetDhcpScopeList)) { $ziele += @{ ScopeId = $s.ScopeId; Name = ('Scope ' + $s.ScopeId) } }
    $alleOk = $true
    foreach ($ziel in $ziele) {
        $alt = Get-NetDhcpDnsSettingInfo -ScopeId $ziel.ScopeId
        $soll = @{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = [bool]$Namensschutz; DisableDnsPtrRRUpdate = $false }
        if ($alt -and (Test-NetDhcpDnsSettingOk -Einstellung $alt) -and ([bool]$alt.NameProtection -eq [bool]$Namensschutz)) {
            Write-Log -Level OK -Message ('{0}: DNS-Einstellungen passen bereits.' -f $ziel.Name)
            continue
        }
        $p = @{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = [bool]$Namensschutz; DisableDnsPtrRRUpdate = $false }
        $rp = @{}
        if ($alt) { $rp = @{ DynamicUpdates = $alt.DynamicUpdates; DeleteDnsRROnLeaseExpiry = [bool]$alt.DeleteDnsRROnLeaseExpiry; UpdateDnsRRForOlderClients = [bool]$alt.UpdateDnsRRForOlderClients; NameProtection = [bool]$alt.NameProtection; DisableDnsPtrRRUpdate = [bool]$alt.DisableDnsPtrRRUpdate } }
        if ($ziel.ScopeId) { $p.ScopeId = $ziel.ScopeId; $rp.ScopeId = $ziel.ScopeId }
        $rueck = $null
        if ($alt) { $rueck = @{ Befehl = 'Set-DhcpServerv4DnsSetting'; Parameter = $rp } }
        $r = Invoke-NetChange -Titel ('DHCP-DNS-Einstellungen ({0})' -f $ziel.Name) -Stufe Bestaetigen -Vorher $alt -Nachher $soll -BackupBereich @('Dhcp') -Aktion {
            Set-DhcpServerv4DnsSetting @p
        } -Rueckgaengig $rueck
        if (-not $r.Erfolg -or $r.Probelauf) { $alleOk = $false }
    }
    return $alleOk
}
#
function Test-NetDhcpDnsZoneReady {
    <#
    .SYNOPSIS
        Prueft die Zonen fuer die DHCP-Eintraege (dynamische Updates) und bietet die Korrektur an.
    #>
    param([switch]$NurPruefen)
    $z = Get-NetSetupState
    $domaenen = @()
    foreach ($s in @($z.Dhcp.Scopes)) { if ($s.Optionen.ContainsKey('15')) { $domaenen += $s.Optionen['15'] } }
    if ($z.Dhcp.ServerOptionen.ContainsKey('15')) { $domaenen += $z.Dhcp.ServerOptionen['15'] }
    $ad = Get-NetDomainName -Zustand $z
    if ($ad) { $domaenen += $ad }
    $domaenen = @($domaenen | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower().TrimEnd('.') } | Select-Object -Unique)
    $ok = $true
    foreach ($d in $domaenen) {
        $zone = @($z.Dns.Zonen | Where-Object { $_.Name -eq $d }) | Select-Object -First 1
        if (-not $zone) {
            Write-Log -Level Warn -Message "Die Zone $d (Domaene der Clients) gibt es auf diesem DNS-Server nicht."
            $ok = $false
            if (-not $NurPruefen -and (Test-NetCommand -Name 'New-NetDnsZone') -and (Read-NetYesNo -Frage "Zone $d anlegen?" -Vorschlag $true)) { New-NetDnsZone -Name $d | Out-Null }
            continue
        }
        $soll = 'NonsecureAndSecure'
        if ($zone.AdIntegriert) { $soll = 'Secure' }
        if ($zone.DynUpdate -eq $soll -or ($zone.AdIntegriert -and $zone.DynUpdate -eq 'NonsecureAndSecure')) {
            if ($zone.AdIntegriert -and $zone.DynUpdate -ne 'Secure') { Write-Log -Level Warn -Message "Zone ${d}: unsichere Updates erlaubt. Empfohlen: nur sicher." }
            else { Write-Log -Level OK -Message ("Zone {0}: dynamische Updates {1}." -f $d, (ConvertTo-NetDnsUpdateText -Wert $zone.DynUpdate)) }
            continue
        }
        Write-Log -Level Warn -Message ("Zone {0}: dynamische Updates sind aus - DHCP kann keine Clients eintragen." -f $d)
        $ok = $false
        if (-not $NurPruefen) { Set-NetDnsZoneUpdate -Zone $d -Wert $soll | Out-Null }
    }
    $fehlend = @(Get-NetMissingReverseZone -Zustand $z | Where-Object { $_.Quelle -like 'DHCP-Scope*' })
    if ($fehlend.Count -gt 0) {
        $ok = $false
        Write-Log -Level Warn -Message ('Fuer diese Scopes fehlt die Reverse-Zone: ' + (($fehlend | ForEach-Object { $_.Netz }) -join ', '))
        if (-not $NurPruefen) {
            foreach ($f in $fehlend) {
                if (Read-NetYesNo -Frage ('Reverse-Zone {0} anlegen?' -f $f.Zone) -Vorschlag $true) { New-NetDnsZone -Name $f.Zone -Netz $f.Netz | Out-Null }
            }
        }
    }
    return $ok
}
#
function New-NetDhcpDnsCredential {
    <#
    .SYNOPSIS
        Legt (nach Bestaetigung) das Dienstkonto an und setzt es als DNS-Zugangsdaten des DHCP-Servers.
        Das Kennwort wird nur als SecureString verarbeitet und nie gespeichert.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    $z = Get-NetSetupState
    if (-not ($z.System.IstDC -or $z.System.IstMitglied)) {
        Write-Log -Message 'Ohne Domaene gibt es kein Dienstkonto. Bei dateibasierten Zonen traegt DHCP ohne Zugangsdaten ein.'
        return $true
    }
    if (-not (Test-NetCommand -Name 'Get-ADUser')) {
        Write-Log -Level Fehler -Message 'Das AD-PowerShell-Modul fehlt (RSAT-AD-PowerShell). Ohne es kann kein Dienstkonto angelegt werden.'
        return $false
    }
    Write-NetText -Text $script:NetIntegrationHilfe
    $kontoName = Read-NetText -Frage 'Name des Dienstkontos' -Vorschlag ([string](Get-NetConfigValue -Pfad 'Vorschlaege.DnsDienstkonto' -Standard 'svc-dhcpdns')) -Pruefung { param($t) if ($t -match '^[A-Za-z0-9._-]{1,20}$') { $null } else { '1 bis 20 Zeichen: Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.' } }
    if (-not $kontoName) { return $false }
    $vorhanden = Get-NetSafe -Beschreibung "Konto $kontoName" -Abfrage { Get-ADUser -Identity $kontoName -Properties PasswordNeverExpires, Enabled }
    $netbios = [string]$z.AD.NetBios
    if (-not $netbios) { $netbios = ([string](Get-NetDomainName -Zustand $z)).Split('.')[0].ToUpper() }
    if ($vorhanden) {
        Write-Log -Level OK -Message "Das Konto $kontoName gibt es bereits. Bitte sein Kennwort eingeben (es wird nicht gespeichert)."
        $kennwort = Read-NetSecret -Frage "Kennwort von $kontoName"
        if (-not $kennwort) { return $false }
    }
    else {
        Write-NetText -Text "Das Konto wird als normales Benutzerkonto ohne besondere Rechte angelegt. Ein Administrator vergibt das Kennwort.`nLaeuft das Kennwort ab, schlagen die DNS-Eintraege fehl - dann hier ein neues Kennwort setzen." -Farbe Yellow
        $kennwort = Read-NetSecret -Frage "Kennwort fuer das neue Konto $kontoName" -Bestaetigen -Komplex -MinLaenge 14
        if (-not $kennwort) { return $false }
        $nieAblaufen = Read-NetYesNo -Frage 'Kennwort laeuft nie ab? (sonst muss es hier regelmaessig erneuert werden)' -Vorschlag $true
        $r = Invoke-NetChange -Titel "Dienstkonto $kontoName im AD anlegen" -Stufe Bestaetigen -Vorher '(kein Konto)' -Nachher @{ Konto = "$netbios\$kontoName"; Rechte = 'normaler Benutzer'; 'Kennwort laeuft ab' = $(if ($nieAblaufen) { 'nie' } else { 'nach Domaenenrichtlinie' }) } -Aktion {
            New-ADUser -Name $kontoName -SamAccountName $kontoName -AccountPassword $kennwort -Enabled $true -PasswordNeverExpires $nieAblaufen -CannotChangePassword $true -Description 'DNS-Eintraege des DHCP-Servers (angelegt von NetSetup)'
        } -Rueckgaengig @{ Befehl = 'Remove-ADUser'; Parameter = @{ Identity = $kontoName; Confirm = $false } }
        if (-not $r.Erfolg -or $r.Probelauf) { return $false }
    }
    $cred = New-Object System.Management.Automation.PSCredential(("{0}\{1}" -f $netbios, $kontoName), $kennwort)
    $alt = $z.Dhcp.DnsZugangsdaten
    $r2 = Invoke-NetChange -Titel 'DNS-Zugangsdaten des DHCP-Servers setzen' -Stufe Bestaetigen -Vorher $(if ($alt.Gesetzt) { '{0}\{1}' -f $alt.Domaene, $alt.Benutzer } else { '(keine - Computerkonto)' }) -Nachher ("{0}\{1}" -f $netbios, $kontoName) -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerDnsCredential -Credential $cred
    }
    return [bool]($r2.Erfolg -and -not $r2.Probelauf)
}
#
function Test-NetAgingVsLease {
    param([switch]$NurPruefen)
    $z = Get-NetSetupState
    $lease = Get-NetMaxLeaseDuration -Zustand $z
    if ($lease -le 0) { return $true }
    $sc = $z.Dns.Scavenging
    if (-not $sc -or -not $sc.Aktiv) {
        Write-Log -Level Warn -Message 'Das Aufraeumen alter DNS-Eintraege ist aus: Eintraege von Geraeten, die nicht mehr da sind, bleiben liegen.'
        if (-not $NurPruefen -and (Test-NetCommand -Name 'Set-NetDnsScavenging') -and (Read-NetYesNo -Frage 'Aufraeumen mit 7 + 7 Tagen einschalten?' -Vorschlag $true)) { Set-NetDnsScavenging -Aktiv $true | Out-Null }
        return $false
    }
    $summe = (ConvertTo-NetTimeSpan $sc.NoRefresh).TotalDays + (ConvertTo-NetTimeSpan $sc.Refresh).TotalDays
    if ($summe -lt $lease) {
        Write-Log -Level Warn -Message ('No-Refresh + Refresh ({0} Tage) ist kuerzer als die Lease-Dauer ({1} Tage): Eintraege aktiver Clients koennten geloescht werden.' -f $summe, $lease)
        if (-not $NurPruefen -and (Read-NetYesNo -Frage 'Aufraeumen passend einstellen?' -Vorschlag $true)) {
            $tage = [int][Math]::Ceiling($lease / 2)
            Set-NetDnsScavenging -Aktiv $true -NoRefreshTage ([Math]::Max(7, $tage)) -RefreshTage ([Math]::Max(7, $tage)) | Out-Null
        }
        return $false
    }
    Write-Log -Level OK -Message ('Aufraeumen passt zur Lease-Dauer ({0} >= {1} Tage).' -f $summe, $lease)
    return $true
}
#
function Get-NetLeaseDnsCheck {
    <#
    .SYNOPSIS
        Gleicht alle aktiven Leases mit A- und PTR-Eintraegen ab und nennt die wahrscheinliche Ursache.
    .OUTPUTS
        Liste von Objekten: IP, Name, Zone, A, PTR, Ursache.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    $ergebnis = @()
    $zonenNamen = @($Zustand.Dns.Zonen | ForEach-Object { $_.Name })
    $reverseNamen = @($Zustand.Dns.Zonen | Where-Object { $_.Reverse } | ForEach-Object { $_.Name })
    $adDomaene = Get-NetDomainName -Zustand $Zustand
    $ohneZugang = $Zustand.System.IstDC -and -not $Zustand.Dhcp.DnsZugangsdaten.Gesetzt
    foreach ($scope in @($Zustand.Dhcp.Scopes)) {
        $id = $scope.ScopeId
        $leases = @(Get-NetSafe -Beschreibung "Leases $id" -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id })
        $domaene = $adDomaene
        if ($scope.Optionen.ContainsKey('15')) { $domaene = [string]$scope.Optionen['15'][0] }
        elseif ($Zustand.Dhcp.ServerOptionen.ContainsKey('15')) { $domaene = [string]$Zustand.Dhcp.ServerOptionen['15'][0] }
        $einst = $scope.DnsEinstellung
        if (-not $einst) { $einst = $Zustand.Dhcp.DnsEinstellung }
        foreach ($l in $leases) {
            if ($null -eq $l -or ([string]$l.AddressState) -notlike 'Active*') { continue }
            $ip = ConvertTo-NetString $l.IPAddress
            $hostName = ([string]$l.HostName).TrimEnd('.')
            $zone = $domaene
            $label = $hostName
            if ($hostName -match '^([^.]+)\.(.+)$') { $label = $Matches[1]; $zone = $Matches[2].ToLower() }
            $zeile = [pscustomobject]@{ IP = $ip; Name = $hostName; Label = $label; Zone = $zone; ReverseZone = ''; A = $false; PTR = $false; Ursache = '' }
            $ursachen = @()
            if (-not $hostName) {
                $zeile.Ursache = 'Der Client hat keinen Namen gemeldet (z. B. Drucker oder IoT-Geraet).'
                $ergebnis += $zeile
                continue
            }
            if (-not $zone -or $zonenNamen -notcontains $zone) { $ursachen += "Zone '$zone' gibt es auf diesem DNS-Server nicht." }
            else {
                $zi = @($Zustand.Dns.Zonen | Where-Object { $_.Name -eq $zone }) | Select-Object -First 1
                $a = @(Get-NetSafe -Beschreibung "A $hostName" -Standard @() -Abfrage { Get-DnsServerResourceRecord -ZoneName $zone -Name $label -RRType A })
                $ips = @($a | Where-Object { $_ } | ForEach-Object { ConvertTo-NetString $_.RecordData.IPv4Address })
                $zeile.A = ($ips -contains $ip)
                if (-not $zeile.A) {
                    if ($ips.Count -gt 0) { $ursachen += ('Der Name zeigt auf {0} (veralteter Eintrag oder Namensschutz).' -f ($ips -join ', ')) }
                    elseif ($zi -and $zi.DynUpdate -eq 'None') { $ursachen += "Dynamische Updates in Zone $zone sind aus." }
                }
            }
            $rz = Find-NetReverseZone -IPAddress $ip -ZoneNames $reverseNamen
            if (-not $rz) { $ursachen += 'Reverse-Zone fuer dieses Netz fehlt.' }
            else {
                $zeile.ReverseZone = $rz
                $ptrName = Get-NetPtrName -IPAddress $ip -ZoneName $rz
                $ptr = @(Get-NetSafe -Beschreibung "PTR $ip" -Standard @() -Abfrage { Get-DnsServerResourceRecord -ZoneName $rz -Name $ptrName -RRType PTR })
                $zeile.PTR = (@($ptr | Where-Object { $_ }).Count -gt 0)
            }
            if (-not ($zeile.A -and $zeile.PTR)) {
                if ($einst -and $einst.DynamicUpdates -ne 'Always') { $ursachen += ('DHCP traegt nur auf Wunsch des Clients ein ({0}).' -f $einst.DynamicUpdates) }
                if ($einst -and $einst.DisableDnsPtrRRUpdate -and -not $zeile.PTR) { $ursachen += 'PTR-Aktualisierung ist im DHCP abgeschaltet.' }
                if ($ohneZugang) { $ursachen += 'DHCP auf DC ohne DNS-Zugangsdaten.' }
                if ($ursachen.Count -eq 0) { $ursachen += 'Unklar - evtl. wurde die Lease gerade erst vergeben oder die AD-Replikation steht noch aus.' }
                $zeile.Ursache = ($ursachen -join ' ')
            }
            $ergebnis += $zeile
        }
    }
    return $ergebnis
}
#
function Show-NetLeaseDnsCheck {
    <#
    .SYNOPSIS
        Prueft alle aktiven Leases auf A- und PTR-Eintrag, zeigt fehlende mit Ursache und bietet das Nachtragen an.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    if (-not (Test-NetDnsReady -Still)) { Write-Log -Level Warn -Message 'Der DNS-Server laeuft nicht auf diesem Server. Die Pruefung braucht DNS lokal.'; return }
    $liste = @(Get-NetLeaseDnsCheck)
    $fehlend = @($liste | Where-Object { -not ($_.A -and $_.PTR) })
    Write-NetTitle -Titel ('Leases und DNS: {0} aktiv, {1} ohne vollstaendigen Eintrag' -f $liste.Count, $fehlend.Count)
    foreach ($f in $fehlend) {
        Write-Host ('  {0,-15} {1,-30} A:{2,-4} PTR:{3,-4} {4}' -f $f.IP, $f.Name, $(if ($f.A) { 'ok' } else { 'fehlt' }), $(if ($f.PTR) { 'ok' } else { 'fehlt' }), $f.Ursache) -ForegroundColor Yellow
    }
    if ($fehlend.Count -eq 0) { Write-Log -Level OK -Message 'Alle aktiven Leases haben einen A- und einen PTR-Eintrag.'; return $liste }
    $nachtragbar = @($fehlend | Where-Object { $_.Name -and $_.Zone -and ((-not $_.A) -or ((-not $_.PTR) -and $_.ReverseZone)) })
    if ($nachtragbar.Count -eq 0) { return $liste }
    if (-not (Read-NetYesNo -Frage ('{0} fehlende Eintraege jetzt nachtragen?' -f $nachtragbar.Count) -Vorschlag $false)) { return $liste }
    $wahl = @(Select-NetItem -Elemente $nachtragbar -Titel 'Welche nachtragen?' -Eigenschaften @('IP', 'Name', 'A', 'PTR') -Mehrfach)
    if ($wahl.Count -eq 0) { return $liste }
    $schritte = @()
    $rueck = @()
    foreach ($w in $wahl) {
        if (-not $w.A) {
            $schritte += @{ ZoneName = $w.Zone; Name = $w.Label; Typ = 'A'; Daten = @{ IPv4Address = $w.IP } }
            $rueck += @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $w.Zone; Name = $w.Label; Typ = 'A'; Daten = @{ IPv4Address = $w.IP } } }
        }
        if (-not $w.PTR -and $w.ReverseZone) {
            $ptrDaten = @{ PtrDomainName = ('{0}.{1}.' -f $w.Label, $w.Zone) }
            $ptrName = Get-NetPtrName -IPAddress $w.IP -ZoneName $w.ReverseZone
            $schritte += @{ ZoneName = $w.ReverseZone; Name = $ptrName; Typ = 'PTR'; Daten = $ptrDaten }
            $rueck += @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $w.ReverseZone; Name = $ptrName; Typ = 'PTR'; Daten = $ptrDaten } }
        }
    }
    $anzeige = @($schritte | ForEach-Object { '{0} {1} in {2}: {3}' -f $_.Name, $_.Typ, $_.ZoneName, (@($_.Daten.Values) -join '') })
    Invoke-NetChange -Titel ('{0} fehlende DNS-Eintraege nachtragen' -f $schritte.Count) -Stufe Bestaetigen -Vorher '(fehlen)' -Nachher $anzeige -BackupBereich @('Dns') `
        -Hinweis 'Von Hand nachgetragene Eintraege sind statisch und werden nicht automatisch aufgeraeumt. Besser die Ursache beheben (Assistent), dann traegt DHCP beim naechsten Erneuern selbst ein.' -Aktion {
        foreach ($s in $schritte) { Add-NetDnsRecordExact -ZoneName $s.ZoneName -Name $s.Name -Typ $s.Typ -Daten $s.Daten }
    } -Rueckgaengig $rueck | Out-Null
    return $liste
}
#
function Show-NetIntegrationStatus {
    <#
    .SYNOPSIS
        Zeigt den Stand der DHCP-DNS-Verbindung; warnt deutlich bei DHCP auf DC ohne Zugangsdaten.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'DHCP + DNS: Stand'
    if (-not $z.Dhcp.Verfuegbar) { Write-NetStatus -Status NA -Bereich 'DHCP' -Text 'kein DHCP-Server auf diesem Server'; return }
    if (Test-NetDhcpDnsSettingOk -Einstellung $z.Dhcp.DnsEinstellung) { Write-NetStatus -Status OK -Bereich 'Server-Einstellung' -Text 'immer eintragen, alte Eintraege loeschen, auch fuer aeltere Clients' }
    else { Write-NetStatus -Status WARN -Bereich 'Server-Einstellung' -Text 'nicht vollstaendig (Assistent ausfuehren)' }
    foreach ($s in @($z.Dhcp.Scopes)) {
        if (Test-NetDhcpDnsSettingOk -Einstellung $s.DnsEinstellung) { Write-NetStatus -Status OK -Bereich ('Scope ' + $s.ScopeId) -Text 'DNS-Einstellung passt' }
        else { Write-NetStatus -Status WARN -Bereich ('Scope ' + $s.ScopeId) -Text 'DNS-Einstellung unvollstaendig' }
    }
    if ($z.Dhcp.DnsZugangsdaten.Gesetzt) { Write-NetStatus -Status OK -Bereich 'Zugangsdaten' -Text ('{0}\{1}' -f $z.Dhcp.DnsZugangsdaten.Domaene, $z.Dhcp.DnsZugangsdaten.Benutzer) }
    elseif ($z.System.IstDC) {
        Write-NetStatus -Status FEHLER -Bereich 'Zugangsdaten' -Text 'DHCP LAEUFT AUF EINEM DC OHNE DNS-ZUGANGSDATEN!'
        Write-NetText -Text "Ohne eigenes Dienstkonto traegt der DHCP-Server mit dem Computerkonto des DCs ein. Die Eintraege gehoeren dann dem DC,`nund ueber die Gruppe DnsUpdateProxy liesse sich das ausnutzen. Abhilfe: 'Dienstkonto einrichten' im Menue DHCP + DNS." -Farbe Red
    }
    elseif ($z.System.IstMitglied) { Write-NetStatus -Status WARN -Bereich 'Zugangsdaten' -Text 'keine - empfohlen ist ein eigenes Dienstkonto' }
    else { Write-NetStatus -Status NA -Bereich 'Zugangsdaten' -Text 'ohne Domaene nicht noetig' }
    Test-NetDhcpDnsZoneReady -NurPruefen | Out-Null
    Test-NetAgingVsLease -NurPruefen | Out-Null
}
#
function Start-NetIntegrationSetup {
    <#
    .SYNOPSIS
        Assistent: DHCP mit DNS verbinden. Danach erscheint der Bereich beim Start als [OK].
    #>
    Write-NetTitle -Titel 'DHCP + DNS verbinden'
    Write-NetText -Text $script:NetIntegrationHilfe
    if (-not (Test-NetDhcpReady)) { return }
    Set-NetDhcpDnsSetting | Out-Null
    if (Test-NetDnsReady -Still) { Test-NetDhcpDnsZoneReady | Out-Null }
    else { Write-Log -Level Warn -Message 'DNS laeuft nicht auf diesem Server: Zonen bitte auf dem DNS-Server pruefen.' }
    $z = Get-NetSetupState
    if (($z.System.IstDC -or $z.System.IstMitglied) -and -not $z.Dhcp.DnsZugangsdaten.Gesetzt) {
        if ($z.System.IstDC) { Write-Log -Level Warn -Message 'DHCP laeuft auf einem DC ohne DNS-Zugangsdaten. Ein Dienstkonto wird dringend empfohlen.' }
        if (Read-NetYesNo -Frage 'Dienstkonto fuer die DNS-Eintraege einrichten?' -Vorschlag $true) { New-NetDhcpDnsCredential | Out-Null }
    }
    if (Test-NetDnsReady -Still) { Test-NetAgingVsLease | Out-Null }
    $script:NS.Zusammenfassung = Get-NetStateSummary -Zustand (Get-NetSetupState)
    $zeile = @($script:NS.Zusammenfassung | Where-Object { $_.Bereich -eq 'DHCP + DNS' }) | Select-Object -First 1
    if ($zeile) { Write-NetStatus -Status $zeile.Status -Bereich $zeile.Bereich -Text $zeile.Text }
}
#
function Show-NetIntegrationMenu {
    $eintraege = @(
        @{ Text = 'Stand anzeigen'; Aktion = 'Show-NetIntegrationStatus'; Hilfe = 'Zeigt DHCP-DNS-Einstellungen (Server und Scopes), Zugangsdaten, Zonen und Aufraeumen. Warnt deutlich, wenn DHCP auf einem DC ohne Zugangsdaten laeuft.' },
        @{ Text = 'Assistent: DHCP mit DNS verbinden'; Aktion = 'Start-NetIntegrationSetup'; Hilfe = $script:NetIntegrationHilfe },
        @{ Text = 'DHCP-DNS-Einstellungen setzen'; Aktion = { Set-NetDhcpDnsSetting | Out-Null }; Hilfe = 'Immer eintragen (Always), alte Eintraege beim Lease-Ablauf loeschen, auch fuer aeltere Clients; Namensschutz waehlbar. Server und alle Scopes.' },
        @{ Text = 'Dienstkonto einrichten (svc-dhcpdns)'; Aktion = { New-NetDhcpDnsCredential | Out-Null }; Hilfe = 'Legt nach Bestaetigung ein eigenes AD-Konto an (oder nutzt ein vorhandenes) und setzt es als DNS-Zugangsdaten des DHCP-Servers. Das Kennwort wird nicht gespeichert.' },
        @{ Text = 'Pruefen: Leases ohne DNS-Eintrag'; Aktion = { Show-NetLeaseDnsCheck | Out-Null }; Hilfe = 'Gleicht alle aktiven Leases mit A- und PTR-Eintraegen ab, nennt die wahrscheinliche Ursache und bietet das Nachtragen an.' }
    )
    Show-NetMenu -Titel 'DHCP + DNS verbinden' -Eintraege $eintraege -Einleitung $script:NetIntegrationHilfe
}
# ----------------------------------------------------------------------
# src/doktor/Engine.ps1
# ----------------------------------------------------------------------
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
#
$script:NetCheckKategorien = @('Rechte', 'Rollen', 'AD', 'Netzwerk', 'DHCP', 'DNS')
#
function New-NetCheckResult {
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidateSet('OK', 'WARN', 'FEHLER', 'NA')][string]$Status,
        [Parameter(Position = 1)][string]$Detail = '',
        [Parameter(Position = 2)][object]$Daten = $null
    )
    return @{ Status = $Status; Detail = $Detail; Daten = $Daten }
}
#
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
#
function Get-NetCheck {
    param([string[]]$Kategorie, [string[]]$Id)
    $liste = @($script:NS.Checks)
    if ($Kategorie) { $liste = @($liste | Where-Object { $Kategorie -contains $_.Kategorie }) }
    if ($Id) { $liste = @($liste | Where-Object { $Id -contains $_.Id }) }
    return @($liste | Sort-Object -Property @{ Expression = { [array]::IndexOf($script:NetCheckKategorien, $_.Kategorie) } }, @{ Expression = { $_.Id } })
}
#
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
#
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
#
function Get-NetCheckSummary {
    param([object[]]$Ergebnisse)
    $ok = @($Ergebnisse | Where-Object { $_.Status -eq 'OK' }).Count
    $warn = @($Ergebnisse | Where-Object { $_.Status -eq 'WARN' }).Count
    $fehler = @($Ergebnisse | Where-Object { $_.Status -eq 'FEHLER' }).Count
    $na = @($Ergebnisse | Where-Object { $_.Status -eq 'NA' }).Count
    return [pscustomobject]@{ OK = $ok; WARN = $warn; FEHLER = $fehler; NA = $na; Text = ('{0} OK, {1} Warnung(en), {2} Fehler, {3} nicht zutreffend' -f $ok, $warn, $fehler, $na) }
}
#
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
#
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
#
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
#
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
#
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
#
function Invoke-NetDoctorCategory {
    $i = Read-NetChoice -Frage 'Welche Kategorie?' -Optionen $script:NetCheckKategorien -Vorschlag 1
    if ($i -lt 0) { return }
    Invoke-NetDoctor -Kategorie $script:NetCheckKategorien[$i] | Out-Null
}
#
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
#
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
# ----------------------------------------------------------------------
# src/doktor/Hilfen.ps1
# ----------------------------------------------------------------------
# Hilfsfunktionen fuer die Pruefungen des Doktors (alle nur mit Bordmitteln).
#
function Get-NetCurrentAccount {
    <#
    .SYNOPSIS
        Liefert das angemeldete Konto und ob es ein lokales Konto ist.
    #>
    $name = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $teile = $name.Split('\')
    $lokal = ($teile.Count -eq 2 -and $teile[0] -ieq [Environment]::MachineName)
    return [pscustomobject]@{ Name = $name; IstLokal = $lokal }
}
#
function Test-NetFirewallPortOpen {
    <#
    .SYNOPSIS
        Prueft ueber Port und Protokoll (nicht ueber Regelnamen), ob eingehend erlaubt ist.
        Ist die Firewall in keinem Profil aktiv, gilt der Port als offen.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('TCP', 'UDP')][string]$Protokoll, [Parameter(Mandatory = $true)][int]$Port)
    $aktiveProfile = @(Get-NetFirewallProfile | Where-Object { [string]$_.Enabled -eq 'True' })
    if ($aktiveProfile.Count -eq 0) { return $true }
    foreach ($filter in @(Get-NetFirewallPortFilter -Protocol $Protokoll)) {
        if ($null -eq $filter) { continue }
        $ports = @($filter.LocalPort | ForEach-Object { [string]$_ })
        $passt = ($ports -contains [string]$Port)
        foreach ($p in $ports) {
            if ($p -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { $passt = $true }
        }
        if (-not $passt) { continue }
        foreach ($regel in @($filter | Get-NetFirewallRule)) {
            if ($regel -and [string]$regel.Enabled -eq 'True' -and [string]$regel.Direction -eq 'Inbound' -and [string]$regel.Action -eq 'Allow') { return $true }
        }
    }
    return $false
}
#
function New-NetFirewallPortRule {
    <#
    .SYNOPSIS
        Legt eine eingehende Firewall-Regel fuer einen Port an (Gruppe NetSetup).
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('TCP', 'UDP')][string]$Protokoll, [Parameter(Mandatory = $true)][int]$Port, [Parameter(Mandatory = $true)][string]$Zweck)
    $name = 'NetSetup-{0}-{1}' -f $Protokoll, $Port
    New-NetFirewallRule -Name $name -DisplayName ('NetSetup {0} ({1} {2})' -f $Zweck, $Protokoll, $Port) -Direction Inbound -Protocol $Protokoll -LocalPort $Port -Action Allow -Group 'NetSetup' -Profile 'Domain,Private' -Description 'Angelegt vom NetSetup-Doktor' | Out-Null
}
#
function Resolve-NetDcSrvRecord {
    param([Parameter(Mandatory = $true)][string]$Domaene)
    $name = '_ldap._tcp.dc._msdcs.' + $Domaene
    return (Get-NetSafe -Beschreibung "SRV $name" -Abfrage { Resolve-DnsName -Name $name -Type SRV -DnsOnly -QuickTimeout })
}
#
function New-NetDhcpDiscoverPacket {
    <#
    .SYNOPSIS
        Baut ein DHCPDISCOVER-Paket (RFC 2131) mit Broadcast-Flag und einer zufaelligen,
        lokal verwalteten MAC-Adresse.
    #>
    param([byte[]]$Xid, [byte[]]$Mac)
    $p = New-Object byte[] 300
    $p[0] = 1; $p[1] = 1; $p[2] = 6; $p[3] = 0
    [Array]::Copy($Xid, 0, $p, 4, 4)
    $p[10] = 0x80
    [Array]::Copy($Mac, 0, $p, 28, 6)
    $p[236] = 99; $p[237] = 130; $p[238] = 83; $p[239] = 99
    $p[240] = 53; $p[241] = 1; $p[242] = 1; $p[243] = 255
    return $p
}
#
function Find-NetForeignDhcpServer {
    <#
    .SYNOPSIS
        Sendet ein DHCPDISCOVER (UDP 67) und sammelt alle DHCP-Server, die antworten.
        Nur .NET-Bordmittel (UdpClient). Liefert die Adressen der antwortenden Server
        oder $null, wenn die Pruefung nicht moeglich war (z. B. Port 68 belegt).
    #>
    param([int]$WarteSekunden = 4)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 68)))
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 1000
        $zufall = New-Object System.Random
        $xid = New-Object byte[] 4
        $zufall.NextBytes($xid)
        $mac = New-Object byte[] 6
        $zufall.NextBytes($mac)
        $mac[0] = ($mac[0] -band 0xFC) -bor 0x02
        $paket = New-NetDhcpDiscoverPacket -Xid $xid -Mac $mac
        $ziel = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 67)
        [void]$udp.Send($paket, $paket.Length, $ziel)
        $server = @()
        $ende = (Get-Date).AddSeconds($WarteSekunden)
        while ((Get-Date) -lt $ende) {
            try {
                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $antwort = $udp.Receive([ref]$ep)
            }
            catch { continue }
            if ($antwort.Length -lt 240 -or $antwort[0] -ne 2) { continue }
            if ($antwort[4] -ne $xid[0] -or $antwort[5] -ne $xid[1] -or $antwort[6] -ne $xid[2] -or $antwort[7] -ne $xid[3]) { continue }
            $kennung = $ep.Address.ToString()
            $i = 240
            while ($i -lt $antwort.Length - 1) {
                $code = $antwort[$i]
                if ($code -eq 255) { break }
                if ($code -eq 0) { $i++; continue }
                $laenge = $antwort[$i + 1]
                if ($code -eq 54 -and $laenge -eq 4) { $kennung = '{0}.{1}.{2}.{3}' -f $antwort[$i + 2], $antwort[$i + 3], $antwort[$i + 4], $antwort[$i + 5] }
                $i += 2 + $laenge
            }
            if ($server -notcontains $kennung) { $server += $kennung }
        }
        return $server
    }
    catch {
        Write-Log -Level Debug -Message ('DHCP-Suche nicht moeglich: ' + $_.Exception.Message)
        return $null
    }
    finally {
        if ($udp) { $udp.Close() }
    }
}
#
function Get-NetKnownDhcpServer {
    <#
    .SYNOPSIS
        Eigene Adressen und im AD autorisierte DHCP-Server (diese gelten nicht als fremd).
    #>
    param([hashtable]$Zustand)
    $bekannt = @($Zustand.Netzwerk.EigeneIPs)
    foreach ($s in @(Get-NetSafe -Beschreibung 'Get-DhcpServerInDC' -Standard @() -Abfrage { Get-DhcpServerInDC })) {
        if ($s -and $s.IPAddress) { $bekannt += (ConvertTo-NetString $s.IPAddress) }
    }
    foreach ($f in @($Zustand.Dhcp.Failover)) {
        $ip = Get-NetSafe -Beschreibung 'Partner' -Abfrage { (Resolve-DnsName -Name $f.Partner -Type A -DnsOnly -QuickTimeout | Select-Object -First 1).IPAddress }
        if ($ip) { $bekannt += [string]$ip }
    }
    return @($bekannt | Select-Object -Unique)
}
#
function Show-NetForeignDhcpServer {
    Write-Log -Message 'Sende DHCPDISCOVER und warte 4 Sekunden auf Antworten ...'
    Write-NetText -Text 'Hinweis: Ein DHCP-Server, der antwortet, reserviert die angebotene Adresse kurz fuer die Test-MAC. Das ist harmlos und laeuft von selbst ab.'
    $z = Get-NetSetupState
    $server = Find-NetForeignDhcpServer
    if ($null -eq $server) { Write-Log -Level Warn -Message 'Die Suche war nicht moeglich (UDP-Port 68 belegt oder gesperrt).'; return }
    $bekannt = Get-NetKnownDhcpServer -Zustand $z
    if (@($server).Count -eq 0) { Write-Log -Level Warn -Message 'Kein DHCP-Server hat geantwortet (auch dieser nicht - Bindung, Scope oder Firewall pruefen).'; return }
    foreach ($s in $server) {
        if ($bekannt -contains $s) { Write-NetStatus -Status OK -Bereich $s -Text 'bekannter DHCP-Server' }
        else { Write-NetStatus -Status FEHLER -Bereich $s -Text 'FREMDER DHCP-Server - verteilt evtl. falsche Adressen (Router/WLAN-Box?)' }
    }
}
#
function Get-NetDuplicateDnsRecord {
    <#
    .SYNOPSIS
        Findet doppelte A-Eintraege: gleicher Name mit mehreren IPs bzw. gleiche IP unter mehreren Namen
        (nur dynamische Eintraege; statische Round-Robin-Eintraege sind gewollt).
    #>
    param([string[]]$Zonen)
    $doppelt = @()
    foreach ($zone in $Zonen) {
        $a = @(Get-NetDnsRecord -Zone $zone -Typ 'A' | Where-Object { -not $_.Statisch -and $_.Name -ne '@' -and $_.Name -notlike 'DomainDnsZones*' -and $_.Name -notlike 'ForestDnsZones*' })
        foreach ($g in @($a | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })) {
            $doppelt += [pscustomobject]@{ Zone = $zone; Art = 'Name mit mehreren IPs'; Wert = $g.Name; Liste = (($g.Group | ForEach-Object { $_.Wert }) -join ', ') }
        }
        foreach ($g in @($a | Group-Object -Property Wert | Where-Object { $_.Count -gt 1 })) {
            $doppelt += [pscustomobject]@{ Zone = $zone; Art = 'IP unter mehreren Namen'; Wert = $g.Name; Liste = (($g.Group | ForEach-Object { $_.Name }) -join ', ') }
        }
    }
    return $doppelt
}
#
function Get-NetDnsCredentialAccountState {
    <#
    .SYNOPSIS
        Prueft das Konto der DHCP-DNS-Zugangsdaten im AD (aktiv, Kennwort nicht abgelaufen).
        Liefert $null, wenn das nicht pruefbar ist.
    #>
    param([Parameter(Mandatory = $true)][string]$Benutzer)
    if (-not (Test-NetCommand -Name 'Get-ADUser')) { return $null }
    $u = Get-NetSafe -Beschreibung "Konto $Benutzer" -Abfrage { Get-ADUser -Identity $Benutzer -Properties Enabled, PasswordExpired, AccountExpirationDate, LockedOut }
    if (-not $u) { return [pscustomobject]@{ Vorhanden = $false; Problem = "Das Konto $Benutzer gibt es im AD nicht (mehr)." } }
    $problem = ''
    if (-not $u.Enabled) { $problem = "Das Konto $Benutzer ist deaktiviert." }
    elseif ($u.PasswordExpired) { $problem = "Das Kennwort von $Benutzer ist abgelaufen." }
    elseif ($u.LockedOut) { $problem = "Das Konto $Benutzer ist gesperrt." }
    elseif ($u.AccountExpirationDate -and ([datetime]$u.AccountExpirationDate) -lt (Get-Date)) { $problem = "Das Konto $Benutzer ist abgelaufen." }
    return [pscustomobject]@{ Vorhanden = $true; Problem = $problem }
}
# ----------------------------------------------------------------------
# src/checks/A01-AdDienste.ps1
# ----------------------------------------------------------------------
# Pruefung A01: NTDS und Netlogon laufen auf dem DC.
Register-NetCheck @{
    Id            = 'A01'
    Kategorie     = 'AD'
    Titel         = 'AD-Dienste (NTDS, Netlogon)'
    Problem       = 'AD-Dienste laufen nicht:'
    Erklaerung    = 'Ohne NTDS und Netlogon funktioniert die Anmeldung an der Domaene nicht. Die Reparatur startet die Dienste.'
    Stufe         = 'Automatisch'
    Voraussetzung = { param($Z) $Z.System.IstDC }
    Test          = {
        param($Z)
        $aus = @(@('NTDS', 'Netlogon') | Where-Object { -not $Z.Dienste[$_] -or $Z.Dienste[$_].Status -ne 'Running' })
        if ($aus.Count -gt 0) { return (New-NetCheckResult FEHLER ($aus -join ', ') $aus) }
        New-NetCheckResult OK 'NTDS und Netlogon laufen'
    }
    Reparatur     = { param($Z, $E) $null = $Z; foreach ($d in @($E.Daten)) { Start-Service -Name $d } }
}
# ----------------------------------------------------------------------
# src/checks/A02-Freigaben.ps1
# ----------------------------------------------------------------------
# Pruefung A02: Freigaben SYSVOL und NETLOGON auf dem DC.
Register-NetCheck @{
    Id            = 'A02'
    Kategorie     = 'AD'
    Titel         = 'Freigaben SYSVOL und NETLOGON'
    Problem       = 'Freigaben fehlen:'
    Erklaerung    = 'Ohne SYSVOL/NETLOGON gibt es keine Gruppenrichtlinien und Anmeldescripts. Nach einer frischen Heraufstufung dauert es einige Minuten. Die Reparatur startet Netlogon neu; hilft das nicht, die SYSVOL-Replikation (DFSR) in der Ereignisanzeige pruefen.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.System.IstDC }
    Test          = {
        $fehlend = @(@('SYSVOL', 'NETLOGON') | Where-Object { $n = $_; -not (Get-NetSafe -Beschreibung "Freigabe $n" -Abfrage { Get-SmbShare -Name $n }) })
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult FEHLER ($fehlend -join ', ')) }
        New-NetCheckResult OK 'vorhanden'
    }
    Reparatur     = { Restart-Service -Name Netlogon -Force }
}
# ----------------------------------------------------------------------
# src/checks/A03-DcSrvEintrag.ps1
# ----------------------------------------------------------------------
# Pruefung A03: _ldap._tcp.dc._msdcs.<domaene> ist aufloesbar.
Register-NetCheck @{
    Id            = 'A03'
    Kategorie     = 'AD'
    Titel         = 'DC-Eintrag im DNS (SRV)'
    Problem       = 'Der Eintrag _ldap._tcp.dc._msdcs.<Domaene> laesst sich nicht aufloesen.'
    Erklaerung    = 'Clients finden Domaenencontroller ueber diesen SRV-Eintrag. Fehlt er, scheitern Beitritt und Anmeldung. Ursachen: DNS-Client zeigt nicht auf einen DC, Zone _msdcs fehlt, Netlogon hat sich nicht registriert. Die Reparatur startet Netlogon neu (registriert die Eintraege erneut).'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) ($Z.System.IstDC -or $Z.System.IstMitglied) -and (Get-NetDomainName -Zustand $Z) }
    Test          = {
        param($Z)
        $d = Get-NetDomainName -Zustand $Z
        if (Resolve-NetDcSrvRecord -Domaene $d) { New-NetCheckResult OK ('_ldap._tcp.dc._msdcs.' + $d) }
        else { New-NetCheckResult FEHLER ('(' + $d + ')') }
    }
    Reparatur     = {
        param($Z)
        if (-not $Z.System.IstDC) { throw 'Auf einem Mitgliedsserver kann der Eintrag nicht repariert werden: DNS-Client pruefen (N02) oder auf dem DC reparieren.' }
        Restart-Service -Name Netlogon -Force
    }
}
# ----------------------------------------------------------------------
# src/checks/A04-PdcZeitquelle.ps1
# ----------------------------------------------------------------------
# Pruefung A04: PDC-Emulator holt die Zeit von einer externen Quelle.
Register-NetCheck @{
    Id            = 'A04'
    Kategorie     = 'AD'
    Titel         = 'Zeitquelle des PDC'
    Problem       = 'Der PDC-Emulator hat keine externe Zeitquelle.'
    Erklaerung    = 'Alle Rechner der Domaene folgen der Uhr des PDC. Er sollte die Zeit per NTP von aussen holen (z. B. ch.pool.ntp.org oder vom Router).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.System.IstPdc }
    Test          = {
        param($Z)
        if ($Z.Zeit.Typ -eq 'NTP' -and $Z.Zeit.NtpServer) { New-NetCheckResult OK $Z.Zeit.NtpServer }
        else { New-NetCheckResult WARN ('(Typ ' + $Z.Zeit.Typ + ')') }
    }
    Reparatur     = { Set-NetPdcTimeSource }
}
# ----------------------------------------------------------------------
# src/checks/D01-NichtAutorisiert.ps1
# ----------------------------------------------------------------------
# Pruefung D01: DHCP-Server ist im AD autorisiert.
Register-NetCheck @{
    Id            = 'D01'
    Kategorie     = 'DHCP'
    Titel         = 'Autorisierung im AD'
    Problem       = 'Der DHCP-Server ist nicht im AD autorisiert und vergibt deshalb keine Adressen.'
    Erklaerung    = 'In einer Domaene muss jeder Windows-DHCP-Server autorisiert sein (Add-DhcpServerInDC). Dafuer braucht es Organisations-Admins.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and $Z.Dhcp.InDomaene }
    Test          = {
        param($Z)
        if ($Z.Dhcp.Autorisiert) { New-NetCheckResult OK 'autorisiert' }
        else { New-NetCheckResult FEHLER '' }
    }
    Reparatur     = { Add-NetDhcpAuthorization }
}
# ----------------------------------------------------------------------
# src/checks/D02-ScopeInaktiv.ps1
# ----------------------------------------------------------------------
# Pruefung D02: Alle Scopes sind aktiv.
Register-NetCheck @{
    Id            = 'D02'
    Kategorie     = 'DHCP'
    Titel         = 'Inaktive Scopes'
    Problem       = 'Diese Scopes sind deaktiviert:'
    Erklaerung    = 'Ein deaktivierter Scope vergibt keine Adressen. Gewollt ist das nur waehrend Umbauten. Die Reparatur aktiviert die Scopes.'
    Stufe         = 'Bestaetigen'
    Backup        = @('Dhcp')
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $inaktiv = @($Z.Dhcp.Scopes | Where-Object { -not $_.Aktiv } | ForEach-Object { $_.ScopeId })
        if ($inaktiv.Count -gt 0) { return (New-NetCheckResult WARN ($inaktiv -join ', ') $inaktiv) }
        New-NetCheckResult OK 'alle aktiv'
    }
    Reparatur     = { param($Z, $E) $null = $Z; foreach ($id in @($E.Daten)) { Set-DhcpServerv4Scope -ScopeId $id -State Active } }
}
# ----------------------------------------------------------------------
# src/checks/D03-Auslastung.ps1
# ----------------------------------------------------------------------
# Pruefung D03: Auslastung der Scopes (Warnung ab 80 %, Fehler ab 90 %).
Register-NetCheck @{
    Id            = 'D03'
    Kategorie     = 'DHCP'
    Titel         = 'Auslastung der Scopes'
    Problem       = 'Scopes sind fast voll:'
    Erklaerung    = 'Ist ein Scope voll, bekommen neue Geraete keine Adresse. Abhilfe: Bereich vergroessern, Ausschluesse verkleinern, Lease-Dauer verkuerzen (z. B. Gaeste-WLAN 1 Tag) oder ein groesseres Netz planen.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes | Where-Object { $_.Aktiv }).Count -gt 0 }
    Test          = {
        param($Z)
        $warnung = [int](Get-NetConfigValue -Pfad 'Vorschlaege.AuslastungWarnung' -Standard 80)
        $fehler = [int](Get-NetConfigValue -Pfad 'Vorschlaege.AuslastungFehler' -Standard 90)
        $voll = @($Z.Dhcp.Scopes | Where-Object { $_.Aktiv -and $_.Auslastung -ge $fehler })
        $knapp = @($Z.Dhcp.Scopes | Where-Object { $_.Aktiv -and $_.Auslastung -ge $warnung -and $_.Auslastung -lt $fehler })
        $text = ((@($voll) + @($knapp)) | ForEach-Object { '{0} {1:N0}%' -f $_.ScopeId, $_.Auslastung }) -join ', '
        if ($voll.Count -gt 0) { return (New-NetCheckResult FEHLER $text) }
        if ($knapp.Count -gt 0) { return (New-NetCheckResult WARN $text) }
        New-NetCheckResult OK ((@($Z.Dhcp.Scopes | Where-Object { $_.Aktiv }) | ForEach-Object { '{0} {1:N0}%' -f $_.ScopeId, $_.Auslastung }) -join ', ')
    }
}
# ----------------------------------------------------------------------
# src/checks/D04-Optionen.ps1
# ----------------------------------------------------------------------
# Pruefung D04: Optionen 003, 006 und 015 sind gesetzt und zeigen richtig.
Register-NetCheck @{
    Id            = 'D04'
    Kategorie     = 'DHCP'
    Titel         = 'Optionen 003/006/015'
    Problem       = 'Optionen fehlen oder zeigen falsch:'
    Erklaerung    = 'Ohne Router (003) kommen Clients nicht aus dem Netz, ohne DNS-Server (006) loesen sie keine Namen auf, ohne Domaene (015) fehlt der DNS-Suffix. In einer Domaene muss 006 auf die DCs zeigen.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $probleme = @()
        $fehler = $false
        $dcs = @()
        if ($Z.System.IstDC -or $Z.System.IstMitglied) { $dcs = @(Get-NetDcAddress -Zustand $Z) }
        foreach ($s in $Z.Dhcp.Scopes) {
            foreach ($nr in @('3', '6', '15')) {
                if (-not $s.Optionen.ContainsKey($nr) -and -not $Z.Dhcp.ServerOptionen.ContainsKey($nr)) { $probleme += ('{0}: {1} fehlt' -f $s.ScopeId, $nr); if ($nr -ne '15') { $fehler = $true } }
            }
            $router = @($s.Optionen['3'])
            if ($router.Count -gt 0 -and $router[0] -and $s.Prefix -gt 0 -and -not (Test-NetIPInSubnet -IPAddress $router[0] -NetworkAddress $s.ScopeId -PrefixLength $s.Prefix)) { $probleme += ('{0}: Router {1} liegt nicht im Netz' -f $s.ScopeId, $router[0]); $fehler = $true }
            $dns = @($s.Optionen['6'])
            if ($dns.Count -eq 0) { $dns = @($Z.Dhcp.ServerOptionen['6']) }
            if ($dcs.Count -gt 0 -and @($dns | Where-Object { $_ -and $dcs -notcontains $_ }).Count -gt 0) { $probleme += ('{0}: DNS {1} ist kein DC' -f $s.ScopeId, ((@($dns | Where-Object { $dcs -notcontains $_ })) -join ',')); $fehler = $true }
        }
        if ($probleme.Count -eq 0) { return (New-NetCheckResult OK 'vollstaendig') }
        if ($fehler) { return (New-NetCheckResult FEHLER ($probleme -join '; ')) }
        New-NetCheckResult WARN ($probleme -join '; ')
    }
    Reparatur     = { Set-NetDhcpStandardOption }
}
# ----------------------------------------------------------------------
# src/checks/D05-ReservierungAusserhalb.ps1
# ----------------------------------------------------------------------
# Pruefung D05: Reservierungen liegen im Scope-Bereich und nicht in einem Ausschluss.
Register-NetCheck @{
    Id            = 'D05'
    Kategorie     = 'DHCP'
    Titel         = 'Reservierungen'
    Problem       = 'Reservierungen liegen ausserhalb des Bereichs oder in einem Ausschluss:'
    Erklaerung    = 'Solche Reservierungen funktionieren nicht wie erwartet. Die Reservierung loeschen und mit einer Adresse im Bereich neu anlegen (Menue DHCP -> Reservierungen).'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes | ForEach-Object { $_.Reservierungen }).Count -gt 0 }
    Test          = {
        param($Z)
        $probleme = @()
        foreach ($s in $Z.Dhcp.Scopes) {
            foreach ($r in @($s.Reservierungen)) {
                if (-not (Test-NetIPInRange -IPAddress $r.IP -Start $s.Start -Ende $s.Ende)) { $probleme += ('{0} ({1}) ausserhalb' -f $r.IP, $r.Name); continue }
                foreach ($a in @($s.Ausschluesse)) { if (Test-NetIPInRange -IPAddress $r.IP -Start $a.Start -Ende $a.Ende) { $probleme += ('{0} ({1}) im Ausschluss' -f $r.IP, $r.Name) } }
            }
        }
        if ($probleme.Count -gt 0) { return (New-NetCheckResult WARN ($probleme -join ', ')) }
        New-NetCheckResult OK 'alle im Bereich'
    }
}
# ----------------------------------------------------------------------
# src/checks/D06-IpKonflikt.ps1
# ----------------------------------------------------------------------
# Pruefung D06: IP-Konflikte (feste Adressen im Bereich, abgelehnte Adressen).
Register-NetCheck @{
    Id            = 'D06'
    Kategorie     = 'DHCP'
    Titel         = 'IP-Konflikte'
    Problem       = 'Moegliche IP-Konflikte:'
    Erklaerung    = 'Liegt eine feste Adresse (Server, Router) im DHCP-Bereich, kann sie doppelt vergeben werden. Die Reparatur traegt diese Adressen als Ausschluss ein. Abgelehnte Adressen (Declined) deuten auf Geraete mit fest eingetragener IP hin - Konflikterkennung einschalten.'
    Stufe         = 'Bestaetigen'
    Backup        = @('Dhcp')
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $fest = @($Z.Netzwerk.EigeneIPs)
        foreach ($k in @($Z.Netzwerk.AktiveKarten)) { $fest += @($k.Gateway) }
        $treffer = @()
        foreach ($s in $Z.Dhcp.Scopes) {
            foreach ($ip in @($fest | Where-Object { $_ } | Select-Object -Unique)) {
                if (-not (Test-NetIPInRange -IPAddress $ip -Start $s.Start -Ende $s.Ende)) { continue }
                $aus = @($s.Ausschluesse | Where-Object { Test-NetIPInRange -IPAddress $ip -Start $_.Start -Ende $_.Ende })
                $res = @($s.Reservierungen | Where-Object { $_.IP -eq $ip })
                if ($aus.Count -eq 0 -and $res.Count -eq 0) { $treffer += @{ ScopeId = $s.ScopeId; IP = $ip } }
            }
        }
        $abgelehnt = @()
        foreach ($s in $Z.Dhcp.Scopes) {
            $id = $s.ScopeId
            $abgelehnt += @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id } | Where-Object { $_ -and [string]$_.AddressState -like '*Declined*' } | ForEach-Object { ConvertTo-NetString $_.IPAddress })
        }
        if ($treffer.Count -gt 0) { return (New-NetCheckResult FEHLER (('feste Adresse im Bereich: ' + (($treffer | ForEach-Object { $_.IP }) -join ', ')) + $(if ($abgelehnt.Count) { '; abgelehnt: ' + ($abgelehnt -join ', ') } else { '' })) $treffer) }
        if ($abgelehnt.Count -gt 0) { return (New-NetCheckResult WARN ('abgelehnte Adressen: ' + ($abgelehnt -join ', '))) }
        New-NetCheckResult OK 'keine Konflikte gefunden'
    }
    Reparatur     = { param($Z, $E) $null = $Z; foreach ($t in @($E.Daten)) { if ($t.IP) { Add-DhcpServerv4ExclusionRange -ScopeId $t.ScopeId -StartRange $t.IP -EndRange $t.IP } } }
}
# ----------------------------------------------------------------------
# src/checks/D07-FailoverSync.ps1
# ----------------------------------------------------------------------
# Pruefung D07: DHCP-Failover ist im Zustand Normal.
Register-NetCheck @{
    Id            = 'D07'
    Kategorie     = 'DHCP'
    Titel         = 'Failover-Zustand'
    Problem       = 'Failover ist nicht synchron:'
    Erklaerung    = 'Normal ist der Zustand "Normal". CommunicationInterrupted bedeutet, dass der Partner nicht erreichbar ist (Netz, Dienst, Firewall TCP 647). Nach Aenderungen an Optionen oder Reservierungen die Replikation ausloesen.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Failover).Count -gt 0 }
    Test          = {
        param($Z)
        $nicht = @($Z.Dhcp.Failover | Where-Object { $_.Status -ne 'Normal' })
        if ($nicht.Count -gt 0) { return (New-NetCheckResult WARN (($nicht | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Status }) -join ', ')) }
        New-NetCheckResult OK 'Normal'
    }
    Reparatur     = { Sync-NetDhcpFailover }
}
# ----------------------------------------------------------------------
# src/checks/D08-FremderDhcp.ps1
# ----------------------------------------------------------------------
# Pruefung D08: Kein fremder DHCP-Server im Netz (DHCPDISCOVER mit UdpClient).
Register-NetCheck @{
    Id            = 'D08'
    Kategorie     = 'DHCP'
    Titel         = 'Fremde DHCP-Server'
    Problem       = 'Ein fremder DHCP-Server antwortet im Netz:'
    Erklaerung    = 'Ein zweiter, unbekannter DHCP-Server (oft ein Router oder eine WLAN-Box mit eingeschaltetem DHCP) verteilt falsche Adressen, Gateways und DNS-Server. Dort DHCP ausschalten.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -or $Z.System.IstDC }
    Test          = {
        param($Z)
        $server = Find-NetForeignDhcpServer
        if ($null -eq $server) { return (New-NetCheckResult NA 'Suche nicht moeglich (UDP 68 belegt)') }
        $bekannt = Get-NetKnownDhcpServer -Zustand $Z
        $fremd = @($server | Where-Object { $bekannt -notcontains $_ })
        if ($fremd.Count -gt 0) { return (New-NetCheckResult FEHLER ($fremd -join ', ') $fremd) }
        New-NetCheckResult OK ('kein fremder Server ({0} Antwort(en))' -f @($server).Count)
    }
}
# ----------------------------------------------------------------------
# src/checks/N01-FesteIp.ps1
# ----------------------------------------------------------------------
# Pruefung N01: Der Server hat eine feste IP-Adresse.
Register-NetCheck @{
    Id         = 'N01'
    Kategorie  = 'Netzwerk'
    Titel      = 'Feste IP-Adresse'
    Problem    = 'Der Server bezieht seine IP per DHCP:'
    Erklaerung = 'DCs, DNS- und DHCP-Server brauchen eine feste IP, sonst finden Clients sie nach einer Aenderung nicht mehr (und der DHCP-Server bindet nicht). Die Reparatur setzt eine feste IP (gefaehrlich: Remotedesktop kann getrennt werden).'
    Stufe      = 'Gefaehrlich'
    Interaktiv = $true
    Test       = {
        param($Z)
        $karten = @($Z.Netzwerk.AktiveKarten)
        if ($karten.Count -eq 0) { return (New-NetCheckResult FEHLER 'keine aktive Netzwerkkarte') }
        $dhcp = @($karten | Where-Object { $_.Dhcp })
        if ($dhcp.Count -eq 0) { return (New-NetCheckResult OK 'statisch') }
        $status = 'WARN'
        if ($Z.System.IstDC -or $Z.Dns.Installiert -or $Z.Dhcp.Installiert) { $status = 'FEHLER' }
        New-NetCheckResult $status (($dhcp | ForEach-Object { $_.Name }) -join ', ') $dhcp[0]
    }
    Reparatur  = { param($Z, $E) $null = $Z; Set-NetStaticAddress -Karte $E.Daten }
}
# ----------------------------------------------------------------------
# src/checks/N02-FremderDns.ps1
# ----------------------------------------------------------------------
# Pruefung N02: Der Server fragt die richtigen DNS-Server (DC: sich selbst bzw. andere DCs).
Register-NetCheck @{
    Id            = 'N02'
    Kategorie     = 'Netzwerk'
    Titel         = 'DNS-Client des Servers'
    Problem       = 'Der Server fragt fremde DNS-Server:'
    Erklaerung    = 'In einer Domaene muessen alle Rechner (auch Server und DCs) nur die DCs als DNS fragen. Oeffentliche Server wie 8.8.8.8 kennen die Domaene nicht - Anmeldung, Gruppenrichtlinien und Replikation scheitern. Internet-Namen loest der DC ueber Weiterleitungen auf.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) ($Z.System.IstDC -or $Z.System.IstMitglied) -and @($Z.Netzwerk.AktiveKarten).Count -gt 0 }
    Test          = {
        param($Z)
        $karte = @($Z.Netzwerk.AktiveKarten)[0]
        $erlaubt = @(Get-NetDcAddress -Zustand $Z) + @($Z.Netzwerk.EigeneIPs)
        if ($Z.System.IstDC) { $erlaubt += '127.0.0.1' }
        $dns = @($karte.DnsServer)
        if ($dns.Count -eq 0) { return (New-NetCheckResult FEHLER 'kein DNS-Server eingetragen' $karte) }
        $fremd = @($dns | Where-Object { $erlaubt -notcontains $_ })
        if ($fremd.Count -gt 0) { return (New-NetCheckResult FEHLER ($fremd -join ', ') $karte) }
        if ($Z.System.IstDC -and @($dns | Where-Object { $Z.Netzwerk.EigeneIPs -contains $_ -or $_ -eq '127.0.0.1' }).Count -eq 0) {
            return (New-NetCheckResult WARN '(der DC fragt sich selbst nicht)' $karte)
        }
        New-NetCheckResult OK ($dns -join ', ')
    }
    Reparatur     = {
        param($Z, $E)
        $soll = @(Get-NetDcAddress -Zustand $Z)
        if ($Z.System.IstDC) {
            $eigene = @($Z.Netzwerk.EigeneIPs)[0]
            $andere = @($soll | Where-Object { $Z.Netzwerk.EigeneIPs -notcontains $_ })
            $soll = @($andere | Select-Object -First 1) + @($eigene, '127.0.0.1')
        }
        Set-NetDnsClient -Karte $E.Daten -Server @($soll | Where-Object { $_ }) -Grund 'Nur DCs als DNS-Server verwenden.'
    }
}
# ----------------------------------------------------------------------
# src/checks/N03-DhcpBindung.ps1
# ----------------------------------------------------------------------
# Pruefung N03: Der DHCP-Server ist an die richtige Netzwerkkarte gebunden.
Register-NetCheck @{
    Id            = 'N03'
    Kategorie     = 'Netzwerk'
    Titel         = 'DHCP-Bindung'
    Problem       = 'Der DHCP-Server ist an die falsche oder keine Netzwerkkarte gebunden:'
    Erklaerung    = 'Der DHCP-Server antwortet nur auf gebundenen Karten. Gebunden sein sollten die Karten im Netz der Clients (bzw. die Karte, an die das DHCP-Relay weiterleitet).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Bindungen).Count -gt 0 }
    Test          = {
        param($Z)
        $aktiv = @($Z.Dhcp.Bindungen | Where-Object { $_.Aktiv })
        if ($aktiv.Count -eq 0) { return (New-NetCheckResult FEHLER 'keine Karte gebunden') }
        $probleme = @()
        foreach ($b in $Z.Dhcp.Bindungen) {
            $karte = @($Z.Netzwerk.Karten | Where-Object { $_.Name -eq $b.Karte }) | Select-Object -First 1
            if (-not $karte -or -not $b.IP) { continue }
            $adr = @($karte.Adressen | Where-Object { $_.IP -eq $b.IP }) | Select-Object -First 1
            if (-not $adr) { continue }
            $hatScope = @($Z.Dhcp.Scopes | Where-Object { $_.Prefix -gt 0 -and (Test-NetIPInSubnet -IPAddress $b.IP -NetworkAddress $_.ScopeId -PrefixLength $_.Prefix) }).Count -gt 0
            if ($hatScope -and -not $b.Aktiv) { $probleme += ('{0} hat einen Scope, ist aber nicht gebunden' -f $b.Karte) }
        }
        if ($probleme.Count -gt 0) { return (New-NetCheckResult WARN ($probleme -join '; ')) }
        New-NetCheckResult OK (($aktiv | ForEach-Object { $_.Karte }) -join ', ')
    }
    Reparatur     = { Set-NetDhcpBinding }
}
# ----------------------------------------------------------------------
# src/checks/N04-Firewall53.ps1
# ----------------------------------------------------------------------
# Pruefung N04: Firewall erlaubt DNS (Port 53 UDP und TCP) eingehend.
Register-NetCheck @{
    Id            = 'N04'
    Kategorie     = 'Netzwerk'
    Titel         = 'Firewall DNS (Port 53)'
    Problem       = 'Die Firewall blockiert DNS eingehend:'
    Erklaerung    = 'Clients erreichen den DNS-Server nur, wenn UDP und TCP Port 53 eingehend erlaubt sind. Geprueft wird nach Port, nicht nach Regelnamen. Die Reparatur legt eine Regel "NetSetup DNS" an.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Features['DNS'] -eq 'Installed' }
    Test          = {
        $zu = @()
        if (-not (Test-NetFirewallPortOpen -Protokoll UDP -Port 53)) { $zu += 'UDP 53' }
        if (-not (Test-NetFirewallPortOpen -Protokoll TCP -Port 53)) { $zu += 'TCP 53' }
        if ($zu.Count -gt 0) { return (New-NetCheckResult FEHLER ($zu -join ', ') $zu) }
        New-NetCheckResult OK 'UDP und TCP 53 erlaubt'
    }
    Reparatur     = {
        param($Z, $E)
        $null = $Z
        foreach ($p in @($E.Daten)) { New-NetFirewallPortRule -Protokoll ($p.Split(' ')[0]) -Port 53 -Zweck 'DNS' }
    }
}
# ----------------------------------------------------------------------
# src/checks/N05-Firewall67.ps1
# ----------------------------------------------------------------------
# Pruefung N05: Firewall erlaubt DHCP (Port 67 UDP) eingehend.
Register-NetCheck @{
    Id            = 'N05'
    Kategorie     = 'Netzwerk'
    Titel         = 'Firewall DHCP (Port 67)'
    Problem       = 'Die Firewall blockiert DHCP-Anfragen (UDP 67 eingehend).'
    Erklaerung    = 'Ohne offenen UDP-Port 67 erreichen DHCP-Anfragen den Server nicht. Geprueft wird nach Port, nicht nach Regelnamen. Die Reparatur legt eine Regel "NetSetup DHCP" an.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Features['DHCP'] -eq 'Installed' }
    Test          = {
        if (Test-NetFirewallPortOpen -Protokoll UDP -Port 67) { New-NetCheckResult OK 'UDP 67 erlaubt' }
        else { New-NetCheckResult FEHLER '' }
    }
    Reparatur     = { New-NetFirewallPortRule -Protokoll UDP -Port 67 -Zweck 'DHCP' }
}
# ----------------------------------------------------------------------
# src/checks/N06-Weiterleitung.ps1
# ----------------------------------------------------------------------
# Pruefung N06: Die DNS-Weiterleitungen antworten.
Register-NetCheck @{
    Id            = 'N06'
    Kategorie     = 'Netzwerk'
    Titel         = 'DNS-Weiterleitungen'
    Problem       = 'Keine Weiterleitung antwortet:'
    Erklaerung    = 'Ohne erreichbare Weiterleitung koennen Clients keine Internet-Namen aufloesen. Ohne Internetzugang ist das normal. Die Reparatur bietet andere Weiterleitungen an (Quad9, Cloudflare, Router).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar -and @($Z.Dns.Weiterleitungen).Count -gt 0 }
    Test          = {
        param($Z)
        $ok = @($Z.Dns.Weiterleitungen | Where-Object { Test-NetDnsForwarder -Server $_ })
        if ($ok.Count -gt 0) { return (New-NetCheckResult OK (($ok -join ', ') + ' antworten')) }
        New-NetCheckResult WARN ($Z.Dns.Weiterleitungen -join ', ')
    }
    Reparatur     = { Set-NetDnsForwarder }
}
# ----------------------------------------------------------------------
# src/checks/O01-RolleFehlt.ps1
# ----------------------------------------------------------------------
# Pruefung O01: Ein Domaenencontroller ohne DNS-Rolle.
Register-NetCheck @{
    Id            = 'O01'
    Kategorie     = 'Rollen'
    Titel         = 'DNS-Rolle auf dem DC'
    Problem       = 'Dieser Domaenencontroller hat keine DNS-Server-Rolle.'
    Erklaerung    = 'Das AD braucht DNS. Ueblich ist DNS auf jedem DC (AD-integrierte Zonen). Die Reparatur installiert die Rolle aus dem lokalen Windows.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.System.IstDC }
    Test          = {
        param($Z)
        if ($Z.Features['DNS'] -eq 'Installed') { New-NetCheckResult OK 'DNS installiert' }
        else { New-NetCheckResult FEHLER ('(Status: ' + (ConvertTo-NetFeatureText -Status $Z.Features['DNS']) + ')') }
    }
    Reparatur     = { Install-NetDnsRole }
}
# ----------------------------------------------------------------------
# src/checks/O02-RolleOhneTools.ps1
# ----------------------------------------------------------------------
# Pruefung O02: Rolle installiert, aber Verwaltungstools fehlen.
Register-NetCheck @{
    Id         = 'O02'
    Kategorie  = 'Rollen'
    Titel      = 'Verwaltungstools'
    Problem    = 'Eine Rolle ist ohne Verwaltungstools installiert:'
    Erklaerung = 'Ohne Verwaltungstools fehlen die PowerShell-Befehle (z. B. Get-DhcpServerv4Scope), NetSetup kann die Rolle dann nicht verwalten. Die Reparatur installiert die Tools aus dem lokalen Windows.'
    Stufe      = 'Bestaetigen'
    Test       = {
        param($Z)
        $fehlend = @()
        if ($Z.Features['DNS'] -eq 'Installed' -and $Z.Features['RSAT-DNS-Server'] -ne 'Installed') { $fehlend += 'RSAT-DNS-Server' }
        if ($Z.Features['DHCP'] -eq 'Installed' -and $Z.Features['RSAT-DHCP'] -ne 'Installed') { $fehlend += 'RSAT-DHCP' }
        if ($Z.Features['AD-Domain-Services'] -eq 'Installed' -and $Z.Features['RSAT-AD-PowerShell'] -ne 'Installed') { $fehlend += 'RSAT-AD-PowerShell' }
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult WARN ($fehlend -join ', ') $fehlend) }
        New-NetCheckResult OK 'vollstaendig'
    }
    Reparatur  = {
        param($Z, $E)
        $null = $Z
        $erg = Install-WindowsFeature -Name $E.Daten
        if ($erg -and $erg.PSObject.Properties['Success'] -and -not $erg.Success) { throw 'Die Installation der Tools ist fehlgeschlagen.' }
    }
}
# ----------------------------------------------------------------------
# src/checks/O03-AdNichtHeraufgestuft.ps1
# ----------------------------------------------------------------------
# Pruefung O03: Rolle AD-Domain-Services installiert, Server ist aber kein DC.
Register-NetCheck @{
    Id            = 'O03'
    Kategorie     = 'Rollen'
    Titel         = 'AD DS ohne Heraufstufung'
    Problem       = 'Die Rolle AD-Domain-Services ist installiert, der Server ist aber kein Domaenencontroller.'
    Erklaerung    = 'Entweder wurde die Heraufstufung nie gemacht oder ist fehlgeschlagen. Die Reparatur bietet an: jetzt heraufstufen (AD-Assistent) oder die ungewollte Rolle entfernen (gefaehrlich, mit Backup und Neustart).'
    Stufe         = 'Gefaehrlich'
    Interaktiv    = $true
    Voraussetzung = { param($Z) -not $Z.System.IstDC }
    Test          = {
        param($Z)
        if ($Z.Features['AD-Domain-Services'] -eq 'Installed') { New-NetCheckResult WARN '' }
        else { New-NetCheckResult OK 'nicht installiert' }
    }
    Reparatur     = {
        $wahl = Read-NetChoice -Frage 'Was soll passieren?' -Optionen @('Jetzt heraufstufen (AD-Assistent)', 'Rolle entfernen (gefaehrlich)', 'Nichts tun') -Vorschlag 3
        if ($wahl -eq 0) { Start-NetAdSetup }
        elseif ($wahl -eq 1) {
            $r = Invoke-NetChange -Titel 'Rolle AD-Domain-Services entfernen' -Stufe Gefaehrlich -Vorher 'AD-Domain-Services installiert (kein DC)' -Nachher 'Rolle entfernt (Neustart noetig)' -BackupBereich @('Config') -Aktion {
                Uninstall-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
            }
            if ($r.Erfolg -and -not $r.Probelauf) { Request-NetRestart -Grund 'Entfernen der Rolle AD-Domain-Services' }
        }
    }
}
# ----------------------------------------------------------------------
# src/checks/O04-RolleUngenutzt.ps1
# ----------------------------------------------------------------------
# Pruefung O04: DHCP-Rolle installiert, aber ungenutzt (kein Scope) - evtl. auf dem falschen Server.
Register-NetCheck @{
    Id            = 'O04'
    Kategorie     = 'Rollen'
    Titel         = 'Ungenutzte DHCP-Rolle'
    Problem       = 'Die DHCP-Rolle ist installiert, hat aber keinen Scope.'
    Erklaerung    = 'Vielleicht wurde DHCP auf dem falschen Server installiert. Die Reparatur bietet an: Scope anlegen (DHCP-Assistent) oder die Rolle entfernen (gefaehrlich, mit Backup).'
    Stufe         = 'Gefaehrlich'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar }
    Test          = {
        param($Z)
        if (@($Z.Dhcp.Scopes).Count -eq 0) { New-NetCheckResult WARN '' }
        else { New-NetCheckResult OK ('{0} Scope(s)' -f @($Z.Dhcp.Scopes).Count) }
    }
    Reparatur     = {
        $wahl = Read-NetChoice -Frage 'Was soll passieren?' -Optionen @('DHCP hier einrichten (Assistent)', 'DHCP-Rolle entfernen (gefaehrlich)', 'Nichts tun') -Vorschlag 3
        if ($wahl -eq 0) { Start-NetDhcpSetup }
        elseif ($wahl -eq 1) {
            Invoke-NetChange -Titel 'DHCP-Rolle entfernen' -Stufe Gefaehrlich -Vorher 'DHCP installiert (ohne Scope)' -Nachher 'DHCP-Rolle entfernt' -BackupBereich @('Dhcp', 'Config') -Aktion {
                Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
            } | Out-Null
        }
    }
}
# ----------------------------------------------------------------------
# src/checks/O05-Neustart.ps1
# ----------------------------------------------------------------------
# Pruefung O05: Ein Neustart steht aus.
Register-NetCheck @{
    Id         = 'O05'
    Kategorie  = 'Rollen'
    Titel      = 'Ausstehender Neustart'
    Problem    = 'Ein Neustart steht aus:'
    Erklaerung = 'Installationen oder Umbenennungen werden erst nach dem Neustart wirksam. Vor AD-Aenderungen unbedingt neu starten.'
    Stufe      = 'Bestaetigen'
    Interaktiv = $true
    Test       = {
        param($Z)
        if ($Z.Neustart.Ausstehend) { New-NetCheckResult WARN ($Z.Neustart.Gruende -join ', ') }
        else { New-NetCheckResult OK 'kein Neustart ausstehend' }
    }
    Reparatur  = { param($Z, $E) $null = $Z; Request-NetRestart -Grund ('ausstehender Neustart: ' + $E.Detail) }
}
# ----------------------------------------------------------------------
# src/checks/O06-DienstGestoppt.ps1
# ----------------------------------------------------------------------
# Pruefung O06: Dienst einer installierten Rolle ist gestoppt (DNS, DHCP, Zeitdienst).
Register-NetCheck @{
    Id         = 'O06'
    Kategorie  = 'Rollen'
    Titel      = 'Gestoppte Dienste'
    Problem    = 'Diese Dienste laufen nicht:'
    Erklaerung = 'Ein gestoppter Dienst ist harmlos zu starten. Bei Stufe Automatisch startet der Doktor ihn sofort (abschaltbar in den Einstellungen).'
    Stufe      = 'Automatisch'
    Test       = {
        param($Z)
        $namen = @('W32Time')
        if ($Z.Features['DNS'] -eq 'Installed') { $namen += 'DNS' }
        if ($Z.Features['DHCP'] -eq 'Installed') { $namen += 'DHCPServer' }
        $gestoppt = @($namen | Where-Object { $Z.Dienste[$_] -and $Z.Dienste[$_].Vorhanden -and $Z.Dienste[$_].Status -ne 'Running' -and $Z.Dienste[$_].StartTyp -ne 'Disabled' })
        if ($gestoppt.Count -gt 0) { return (New-NetCheckResult FEHLER ($gestoppt -join ', ') $gestoppt) }
        New-NetCheckResult OK (($namen -join ', ') + ' laufen')
    }
    Reparatur  = { param($Z, $E) $null = $Z; foreach ($d in @($E.Daten)) { Start-Service -Name $d } }
}
# ----------------------------------------------------------------------
# src/checks/O07-DienstDeaktiviert.ps1
# ----------------------------------------------------------------------
# Pruefung O07: Dienst einer installierten Rolle ist deaktiviert.
Register-NetCheck @{
    Id         = 'O07'
    Kategorie  = 'Rollen'
    Titel      = 'Deaktivierte Dienste'
    Problem    = 'Diese Dienste sind deaktiviert:'
    Erklaerung = 'Ein deaktivierter Dienst startet nie. Die Reparatur stellt den Starttyp auf Automatisch und startet ihn.'
    Stufe      = 'Bestaetigen'
    Test       = {
        param($Z)
        $namen = @('W32Time')
        if ($Z.Features['DNS'] -eq 'Installed') { $namen += 'DNS' }
        if ($Z.Features['DHCP'] -eq 'Installed') { $namen += 'DHCPServer' }
        if ($Z.System.IstDC) { $namen += @('NTDS', 'Netlogon') }
        $aus = @($namen | Where-Object { $Z.Dienste[$_] -and $Z.Dienste[$_].Vorhanden -and $Z.Dienste[$_].StartTyp -eq 'Disabled' })
        if ($aus.Count -gt 0) { return (New-NetCheckResult FEHLER ($aus -join ', ') $aus) }
        New-NetCheckResult OK 'keiner deaktiviert'
    }
    Reparatur  = { param($Z, $E) $null = $Z; foreach ($d in @($E.Daten)) { Set-Service -Name $d -StartupType Automatic; Start-Service -Name $d } }
}
# ----------------------------------------------------------------------
# src/checks/O08-DhcpNachkonfiguration.ps1
# ----------------------------------------------------------------------
# Pruefung O08: DHCP-Nachkonfiguration fehlt.
Register-NetCheck @{
    Id            = 'O08'
    Kategorie     = 'Rollen'
    Titel         = 'DHCP-Nachkonfiguration'
    Problem       = 'Die DHCP-Nachkonfiguration fehlt (Server-Manager meldet "Konfiguration erforderlich").'
    Erklaerung    = 'Nach der Installation muessen die Sicherheitsgruppen angelegt und der Abschluss im Server-Manager vermerkt werden (ConfigurationState = 2).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Features['DHCP'] -eq 'Installed' }
    Test          = {
        param($Z)
        if ($Z.Dhcp.Nachkonfiguriert) { New-NetCheckResult OK 'erledigt' }
        else { New-NetCheckResult WARN '' }
    }
    Reparatur     = { Complete-NetDhcpPostInstall }
}
# ----------------------------------------------------------------------
# src/checks/O09-DhcpDatenbank.ps1
# ----------------------------------------------------------------------
# Pruefung O09: DHCP-Datenbank fehlt oder der Dienst kann sie nicht lesen.
Register-NetCheck @{
    Id            = 'O09'
    Kategorie     = 'Rollen'
    Titel         = 'DHCP-Datenbank'
    Problem       = 'Die DHCP-Datenbank fehlt oder ist beschaedigt.'
    Erklaerung    = 'Ohne lesbare Datenbank startet der DHCP-Dienst nicht. Die Reparatur stellt die Datenbank aus einem Backup wieder her (gefaehrlich: aktuelle Leases werden ersetzt).'
    Stufe         = 'Gefaehrlich'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Features['DHCP'] -eq 'Installed' -and $Z.Dienste['DHCPServer'] -and $Z.Dienste['DHCPServer'].Vorhanden }
    Test          = {
        param($Z)
        $windows = $env:SystemRoot
        if (-not $windows) { $windows = 'C:\Windows' }
        $datei = $windows.TrimEnd('\') + '\System32\dhcp\dhcp.mdb'
        if (-not (Test-Path -Path $datei)) { return (New-NetCheckResult FEHLER ('(' + $datei + ' fehlt)')) }
        if ($Z.Dienste['DHCPServer'].Status -ne 'Running' -and -not $Z.Dhcp.Verfuegbar) { return (New-NetCheckResult WARN '(Dienst laeuft nicht - Datenbank evtl. beschaedigt, zuerst O06 pruefen)') }
        New-NetCheckResult OK 'vorhanden'
    }
    Reparatur     = {
        if (Test-NetCommand -Name 'Restore-NetDhcpBackup') { Restore-NetDhcpBackup }
        else { Write-Log -Level Warn -Message 'Wiederherstellen ist im Menue Backup verfuegbar.' }
    }
}
# ----------------------------------------------------------------------
# src/checks/R01-Administrator.ps1
# ----------------------------------------------------------------------
# Pruefung R01: NetSetup laeuft mit Administratorrechten.
Register-NetCheck @{
    Id         = 'R01'
    Kategorie  = 'Rechte'
    Titel      = 'Administratorrechte'
    Problem    = 'NetSetup laeuft ohne Administratorrechte.'
    Erklaerung = 'Fast alle Aenderungen brauchen Administratorrechte. PowerShell bzw. ISE mit rechter Maustaste "Als Administrator ausfuehren" starten.'
    Stufe      = 'Bestaetigen'
    Test       = {
        param($Z)
        if ($Z.System.IstAdmin) { New-NetCheckResult OK 'als Administrator gestartet' }
        else { New-NetCheckResult FEHLER '' }
    }
}
# ----------------------------------------------------------------------
# src/checks/R02-Domaenenkonto.ps1
# ----------------------------------------------------------------------
# Pruefung R02: In einer Domaene mit einem Domaenenkonto angemeldet.
Register-NetCheck @{
    Id            = 'R02'
    Kategorie     = 'Rechte'
    Titel         = 'Domaenenkonto'
    Problem       = 'Angemeldet mit einem lokalen Konto.'
    Erklaerung    = 'Fuer AD-, DNS- und DHCP-Aenderungen in der Domaene (z. B. Autorisierung, Dienstkonto) wird ein Domaenenkonto mit passenden Rechten gebraucht. Abmelden und als DOMAENE\Administrator anmelden.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.System.IstMitglied }
    Test          = {
        $konto = Get-NetCurrentAccount
        if ($konto.IstLokal) { New-NetCheckResult WARN ('(' + $konto.Name + ')') }
        else { New-NetCheckResult OK $konto.Name }
    }
}
# ----------------------------------------------------------------------
# src/checks/R03-OrganisationsAdmin.ps1
# ----------------------------------------------------------------------
# Pruefung R03: Rechte fuer die DHCP-Autorisierung (Organisations-Admins).
Register-NetCheck @{
    Id            = 'R03'
    Kategorie     = 'Rechte'
    Titel         = 'Rechte fuer DHCP-Autorisierung'
    Problem       = 'Der DHCP-Server ist nicht autorisiert und das Konto ist nicht in der Gruppe Organisations-Admins.'
    Erklaerung    = 'Die Autorisierung im AD duerfen nur Organisations-Admins (Enterprise Admins) bzw. Konten mit delegiertem Recht. Mit einem solchen Konto anmelden oder einen Organisations-Admin bitten.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and $Z.Dhcp.InDomaene -and -not $Z.Dhcp.Autorisiert }
    Test          = {
        if (Test-NetEnterpriseAdmin) { New-NetCheckResult OK 'Konto ist Organisations-Admin' }
        else { New-NetCheckResult WARN '' }
    }
}
# ----------------------------------------------------------------------
# src/checks/R04-Zeitabweichung.ps1
# ----------------------------------------------------------------------
# Pruefung R04: Zeitabweichung zum PDC bzw. zur Domaene.
Register-NetCheck @{
    Id            = 'R04'
    Kategorie     = 'Rechte'
    Titel         = 'Zeitabweichung zur Domaene'
    Problem       = 'Die Uhr weicht vom PDC-Emulator ab.'
    Erklaerung    = 'Ab 5 Minuten Abweichung schlaegt die Anmeldung (Kerberos) fehl. Die Reparatur synchronisiert die Uhr mit der Domaenenhierarchie (w32tm /resync).'
    Stufe         = 'Automatisch'
    Voraussetzung = { param($Z) ($Z.System.IstMitglied -or ($Z.System.IstDC -and -not $Z.System.IstPdc)) -and $Z.AD.Pdc }
    Test          = {
        param($Z)
        $abw = Get-NetTimeOffset -Server $Z.AD.Pdc
        if ($null -eq $abw) { return (New-NetCheckResult WARN ('PDC {0} antwortet nicht auf UDP 123.' -f $Z.AD.Pdc)) }
        $betrag = [Math]::Abs([double]$abw)
        if ($betrag -gt 300) { return (New-NetCheckResult FEHLER ('{0:N0} Sekunden.' -f $abw) $abw) }
        if ($betrag -gt 60) { return (New-NetCheckResult WARN ('{0:N0} Sekunden.' -f $abw) $abw) }
        New-NetCheckResult OK ('{0} Sekunden' -f $abw) $abw
    }
    Reparatur     = {
        Invoke-NetW32tm -Argumente @('/config', '/syncfromflags:domhier', '/update')
        Invoke-NetW32tm -Argumente @('/resync', '/force')
    }
}
# ----------------------------------------------------------------------
# src/checks/V01-ZoneFehlt.ps1
# ----------------------------------------------------------------------
# Pruefung V01: Die Zone der Domaene bzw. der Clients existiert.
Register-NetCheck @{
    Id            = 'V01'
    Kategorie     = 'DNS'
    Titel         = 'Forward-Zone'
    Problem       = 'Die Zone fehlt:'
    Erklaerung    = 'Ohne Zone der Domaene (bzw. der Client-Domaene aus Option 015) kann niemand eingetragen und gefunden werden. Die Reparatur legt die Zone an.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $soll = @()
        $d = Get-NetDomainName -Zustand $Z
        if ($d -and $Z.System.IstDC) { $soll += $d }
        foreach ($s in @($Z.Dhcp.Scopes)) { if ($s.Optionen.ContainsKey('15')) { $soll += @($s.Optionen['15']) } }
        $soll = @($soll | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLower() } | Select-Object -Unique)
        $vorhanden = @($Z.Dns.Zonen | ForEach-Object { $_.Name })
        $fehlend = @($soll | Where-Object { $vorhanden -notcontains $_ })
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult FEHLER ($fehlend -join ', ') $fehlend) }
        if (@($Z.Dns.Zonen | Where-Object { -not $_.Reverse }).Count -eq 0) { return (New-NetCheckResult WARN 'keine Forward-Zone vorhanden' @()) }
        New-NetCheckResult OK (($soll + @()) -join ', ')
    }
    Reparatur     = {
        param($Z, $E)
        $null = $Z
        if (@($E.Daten).Count -eq 0) { New-NetDnsForwardZone; return }
        foreach ($zone in @($E.Daten)) { New-NetDnsZone -Name $zone | Out-Null }
    }
}
# ----------------------------------------------------------------------
# src/checks/V02-ReverseZoneFehlt.ps1
# ----------------------------------------------------------------------
# Pruefung V02: Reverse-Zonen fuer das Server-Netz und alle Scopes.
Register-NetCheck @{
    Id            = 'V02'
    Kategorie     = 'DNS'
    Titel         = 'Reverse-Zonen'
    Problem       = 'Reverse-Zonen fehlen:'
    Erklaerung    = 'Ohne Reverse-Zone gibt es keine PTR-Eintraege (Adresse -> Name). Viele Programme (Protokolle, Ueberwachung, Mailserver) brauchen das. Die Reparatur schlaegt die fehlenden Zonen vor.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $fehlend = @(Get-NetMissingReverseZone -Zustand $Z)
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult WARN (($fehlend | ForEach-Object { '{0} ({1})' -f $_.Zone, $_.Netz }) -join ', ')) }
        New-NetCheckResult OK 'fuer alle Netze vorhanden'
    }
    Reparatur     = { Add-NetMissingReverseZone }
}
# ----------------------------------------------------------------------
# src/checks/V03-DynUpdatesAus.ps1
# ----------------------------------------------------------------------
# Pruefung V03: Dynamische Updates in den Zonen sind eingeschaltet.
Register-NetCheck @{
    Id            = 'V03'
    Kategorie     = 'DNS'
    Titel         = 'Dynamische Updates'
    Problem       = 'In diesen Zonen sind dynamische Updates aus:'
    Erklaerung    = 'Dann koennen sich weder Clients noch der DHCP-Server eintragen. Auf DCs ist "nur sicher" richtig, bei dateibasierten Zonen "sicher und unsicher".'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar -and @($Z.Dns.Zonen | Where-Object { $_.Typ -eq 'Primary' }).Count -gt 0 }
    Test          = {
        param($Z)
        $aus = @($Z.Dns.Zonen | Where-Object { $_.Typ -eq 'Primary' -and $_.DynUpdate -eq 'None' -and $_.Name -notlike '*.ip6.arpa' } | ForEach-Object { $_.Name })
        $unsicher = @($Z.Dns.Zonen | Where-Object { $_.AdIntegriert -and $_.DynUpdate -eq 'NonsecureAndSecure' } | ForEach-Object { $_.Name })
        if ($aus.Count -gt 0) { return (New-NetCheckResult WARN ($aus -join ', ') $aus) }
        if ($unsicher.Count -gt 0) { return (New-NetCheckResult WARN ('unsichere Updates erlaubt in: ' + ($unsicher -join ', ')) $unsicher) }
        New-NetCheckResult OK 'eingeschaltet'
    }
    Reparatur     = {
        param($Z, $E)
        foreach ($zone in @($E.Daten)) {
            $info = @($Z.Dns.Zonen | Where-Object { $_.Name -eq $zone }) | Select-Object -First 1
            $wert = 'NonsecureAndSecure'
            if ($info -and $info.AdIntegriert) { $wert = 'Secure' }
            Set-NetDnsZoneUpdate -Zone $zone -Wert $wert | Out-Null
        }
    }
}
# ----------------------------------------------------------------------
# src/checks/V04-DnsZugangsdaten.ps1
# ----------------------------------------------------------------------
# Pruefung V04: DNS-Zugangsdaten des DHCP-Servers gesetzt und gueltig.
Register-NetCheck @{
    Id            = 'V04'
    Kategorie     = 'DNS'
    Titel         = 'DNS-Zugangsdaten des DHCP-Servers'
    Problem       = 'Die DNS-Zugangsdaten fehlen oder sind ungueltig:'
    Erklaerung    = 'Laeuft DHCP auf einem DC ohne eigenes Dienstkonto, gehoeren alle Client-Eintraege dem DC (Sicherheitsrisiko, Aktualisierungsprobleme). Ein abgelaufenes Kennwort laesst alle Eintraege scheitern. Die Reparatur richtet das Dienstkonto ein bzw. setzt ein neues Kennwort.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and ($Z.System.IstDC -or $Z.System.IstMitglied) }
    Test          = {
        param($Z)
        $zd = $Z.Dhcp.DnsZugangsdaten
        if (-not $zd.Gesetzt) {
            if ($Z.System.IstDC) { return (New-NetCheckResult FEHLER 'DHCP laeuft auf einem DC ohne Zugangsdaten') }
            return (New-NetCheckResult WARN 'keine Zugangsdaten gesetzt')
        }
        $konto = Get-NetDnsCredentialAccountState -Benutzer $zd.Benutzer
        if ($konto -and $konto.Problem) { return (New-NetCheckResult FEHLER $konto.Problem) }
        New-NetCheckResult OK ('{0}\{1}' -f $zd.Domaene, $zd.Benutzer)
    }
    Reparatur     = { New-NetDhcpDnsCredential }
}
# ----------------------------------------------------------------------
# src/checks/V05-LeasesOhneDns.ps1
# ----------------------------------------------------------------------
# Pruefung V05: Alle aktiven Leases haben A- und PTR-Eintrag.
Register-NetCheck @{
    Id            = 'V05'
    Kategorie     = 'DNS'
    Titel         = 'Leases ohne DNS-Eintrag'
    Problem       = 'Aktive Leases ohne vollstaendigen DNS-Eintrag:'
    Erklaerung    = 'Clients ohne A- oder PTR-Eintrag sind per Name nicht erreichbar. Die Reparatur zeigt jede Lease mit Ursache und bietet das Nachtragen an; dauerhaft hilft der Assistent "DHCP + DNS verbinden".'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and $Z.Dns.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $liste = @(Get-NetLeaseDnsCheck -Zustand $Z)
        $fehlend = @($liste | Where-Object { $_.Name -and -not ($_.A -and $_.PTR) })
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult WARN ('{0} von {1}' -f $fehlend.Count, $liste.Count)) }
        New-NetCheckResult OK ('{0} aktive Lease(s) vollstaendig' -f $liste.Count)
    }
    Reparatur     = { Show-NetLeaseDnsCheck | Out-Null }
}
# ----------------------------------------------------------------------
# src/checks/V06-VeralteteEintraege.ps1
# ----------------------------------------------------------------------
# Pruefung V06: Veraltete dynamische Eintraege bei ausgeschaltetem Aufraeumen.
Register-NetCheck @{
    Id            = 'V06'
    Kategorie     = 'DNS'
    Titel         = 'Veraltete Eintraege'
    Problem       = 'Veraltete dynamische Eintraege, Aufraeumen ist aus:'
    Erklaerung    = 'Alte Eintraege zeigen auf Adressen, die laengst anderen Geraeten gehoeren. Das Aufraeumen (Aging/Scavenging, Vorschlag 7 + 7 Tage) entfernt sie automatisch.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $an = $Z.Dns.Scavenging -and $Z.Dns.Scavenging.Aktiv
        $alt = @(Get-NetStaleDnsRecord -NoRefreshTage 7 -RefreshTage 7)
        if ($alt.Count -gt 0 -and -not $an) { return (New-NetCheckResult WARN ('{0} Eintraege aelter als 14 Tage' -f $alt.Count)) }
        if (-not $an) { return (New-NetCheckResult WARN 'Aufraeumen ist aus (noch keine veralteten Eintraege)') }
        New-NetCheckResult OK ('Aufraeumen an, {0} Eintraege stehen zur Loeschung an' -f $alt.Count)
    }
    Reparatur     = { Set-NetDnsScavenging | Out-Null }
}
# ----------------------------------------------------------------------
# src/checks/V07-DoppelteEintraege.ps1
# ----------------------------------------------------------------------
# Pruefung V07: Doppelte DNS-Eintraege (Name mit mehreren IPs, IP unter mehreren Namen).
Register-NetCheck @{
    Id            = 'V07'
    Kategorie     = 'DNS'
    Titel         = 'Doppelte Eintraege'
    Problem       = 'Doppelte dynamische Eintraege:'
    Erklaerung    = 'Doppelte Eintraege fuehren dazu, dass ein Name mal hier, mal dort landet. Ursache sind meist fehlendes Aufraeumen oder Geraete, die Namen bzw. Adressen wechseln. Abhilfe: Aufraeumen einschalten, Namensschutz im DHCP, falsche Eintraege im Menue DNS -> Eintraege loeschen.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dns.Verfuegbar }
    Test          = {
        param($Z)
        $zonen = @($Z.Dns.Zonen | Where-Object { -not $_.Reverse -and $_.Typ -eq 'Primary' -and $_.Name -notlike '_msdcs.*' } | ForEach-Object { $_.Name })
        $doppelt = @(Get-NetDuplicateDnsRecord -Zonen $zonen)
        if ($doppelt.Count -gt 0) { return (New-NetCheckResult WARN (($doppelt | Select-Object -First 5 | ForEach-Object { '{0}: {1}' -f $_.Wert, $_.Liste }) -join '; ')) }
        New-NetCheckResult OK 'keine'
    }
}
# ----------------------------------------------------------------------
# src/checks/V08-DhcpDnsEinstellung.ps1
# ----------------------------------------------------------------------
# Pruefung V08: Der DHCP-Server traegt alle Clients ein und raeumt beim Lease-Ablauf auf.
Register-NetCheck @{
    Id            = 'V08'
    Kategorie     = 'DNS'
    Titel         = 'DHCP traegt in DNS ein'
    Problem       = 'Die DHCP-DNS-Einstellung ist unvollstaendig:'
    Erklaerung    = 'Damit jeder Client automatisch A- und PTR-Eintrag bekommt, muss DHCP "immer" eintragen, auch fuer aeltere Clients, und bei Lease-Ablauf loeschen - fuer den Server und jeden Scope.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar }
    Test          = {
        param($Z)
        $falsch = @()
        if (-not (Test-NetDhcpDnsSettingOk -Einstellung $Z.Dhcp.DnsEinstellung)) { $falsch += 'Server' }
        foreach ($s in @($Z.Dhcp.Scopes)) { if ($s.DnsEinstellung -and -not (Test-NetDhcpDnsSettingOk -Einstellung $s.DnsEinstellung)) { $falsch += ('Scope ' + $s.ScopeId) } }
        if ($falsch.Count -gt 0) { return (New-NetCheckResult WARN ($falsch -join ', ')) }
        New-NetCheckResult OK 'Always, Loeschen bei Ablauf, aeltere Clients'
    }
    Reparatur     = { Set-NetDhcpDnsSetting | Out-Null }
}
# ----------------------------------------------------------------------
# src/wartung/Backup.ps1
# ----------------------------------------------------------------------
# Backup: DHCP (Backup-DhcpServer und Export-DhcpServer mit Leases), DNS (Export-DnsServerZone pro Zone
# und alle Eintraege als CSV), Konfiguration und Netzwerk. Automatisch vor jeder Aenderung,
# Aufbewahrung der letzten N Backups (Einstellung, Vorschlag 20).
#
$script:NetBackupBereiche = @('Dhcp', 'Dns', 'Config', 'Netzwerk')
#
function Get-NetWindowsPath {
    param([string]$Unterpfad)
    $windows = $env:SystemRoot
    if (-not $windows) { $windows = 'C:\Windows' }
    return ($windows.TrimEnd('\') + '\' + $Unterpfad.TrimStart('\'))
}
#
function Get-NetBackupList {
    <#
    .SYNOPSIS
        Liefert alle Backups (neueste zuerst) mit Zeit, Anlass und enthaltenen Bereichen.
    #>
    $ordner = Get-NetPath -Name Backups
    if (-not (Test-Path -Path $ordner)) { return @() }
    $liste = @()
    foreach ($d in @(Get-ChildItem -Path $ordner -Directory | Sort-Object -Property Name -Descending)) {
        $info = Join-Path -Path $d.FullName -ChildPath 'info.json'
        if (-not (Test-Path -Path $info)) { continue }
        try { $i = Get-Content -Path $info -Raw | ConvertFrom-Json } catch { continue }
        $liste += [pscustomobject]@{
            Name      = $d.Name
            Pfad      = $d.FullName
            Zeit      = [string]$i.Zeit
            Anlass    = [string]$i.Anlass
            Bereiche  = @($i.Bereiche)
            Server    = [string]$i.Server
            Automatisch = [bool]$i.Automatisch
        }
    }
    return $liste
}
#
function Remove-NetOldBackup {
    <#
    .SYNOPSIS
        Loescht die aeltesten Backups, wenn mehr als die eingestellte Anzahl vorhanden sind.
    #>
    $behalten = [int](Get-NetConfigValue -Pfad 'Allgemein.BackupAufbewahrung' -Standard 20)
    $liste = @(Get-NetBackupList | Where-Object { $_.Name -notlike 'Umzug_*' })
    if ($liste.Count -le $behalten) { return }
    foreach ($alt in ($liste | Select-Object -Skip $behalten)) {
        Remove-Item -Path $alt.Pfad -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log -Level Debug -Message ('Altes Backup geloescht: ' + $alt.Name)
    }
}
#
function Export-NetDnsRecordCsv {
    <#
    .SYNOPSIS
        Schreibt alle Eintraege der Zonen als CSV (mit Daten als JSON, fuer die Wiederherstellung).
    #>
    param([Parameter(Mandatory = $true)][string]$Datei, [string[]]$Zonen)
    if (-not $Zonen) { $Zonen = @(Get-NetDnsZoneInfo -Art Primaer | ForEach-Object { $_.Name }) }
    $zeilen = @()
    foreach ($zone in $Zonen) {
        foreach ($e in @(Get-NetDnsRecord -Zone $zone)) {
            $zeilen += [pscustomobject]@{
                Zone     = $e.Zone
                Name     = $e.Name
                Typ      = $e.Typ
                Wert     = $e.Wert
                Statisch = $e.Statisch
                Ttl      = $e.Ttl
                Daten    = ($e.Daten | ConvertTo-Json -Compress -Depth 3)
            }
        }
    }
    $zeilen | Export-Csv -Path $Datei -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    return $zeilen.Count
}
#
function Backup-NetSetupData {
    <#
    .SYNOPSIS
        Erstellt ein Backup der gewaehlten Bereiche. Liefert den Ordner (oder $null bei Fehler).
    .PARAMETER Bereich
        Dhcp, Dns, Config, Netzwerk (AD wird mit der Windows-Serversicherung gesichert).
    #>
    param(
        [string[]]$Bereich = $script:NetBackupBereiche,
        [string]$Anlass = 'manuell',
        [switch]$Automatisch,
        [string]$Ziel
    )
    $zeit = Get-Date
    $kurz = ($Anlass -replace '[^A-Za-z0-9]+', '-').Trim('-')
    if ($kurz.Length -gt 40) { $kurz = $kurz.Substring(0, 40) }
    if (-not $Ziel) { $Ziel = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('{0}_{1}' -f $zeit.ToString('yyyyMMdd_HHmmss_fff'), $kurz) }
    New-Item -Path $Ziel -ItemType Directory -Force | Out-Null
    $erledigt = @()
    $hinweise = @()
    foreach ($b in @($Bereich | Select-Object -Unique)) {
        switch ($b) {
            'Config' {
                $datei = Get-NetPath -Name ConfigDatei
                if (Test-Path -Path $datei) { Copy-Item -Path $datei -Destination (Join-Path -Path $Ziel -ChildPath 'netsetup.json') -Force }
                $verlauf = Get-NetPath -Name Verlauf
                if (Test-Path -Path $verlauf) { Copy-Item -Path $verlauf -Destination (Join-Path -Path $Ziel -ChildPath 'verlauf.json') -Force }
                $erledigt += 'Config'
            }
            'Netzwerk' {
                $netz = Get-NetNetworkState
                Set-Content -Path (Join-Path -Path $Ziel -ChildPath 'netzwerk.json') -Value ($netz | ConvertTo-Json -Depth 8) -Encoding UTF8
                $erledigt += 'Netzwerk'
            }
            'Dhcp' {
                if (-not (Test-NetDhcpReady -Still)) { $hinweise += 'DHCP: nicht vorhanden oder Dienst gestoppt - uebersprungen'; continue }
                $dhcpZiel = Join-Path -Path $Ziel -ChildPath 'Dhcp'
                New-Item -Path $dhcpZiel -ItemType Directory -Force | Out-Null
                Export-DhcpServer -File (Join-Path -Path $dhcpZiel -ChildPath 'dhcp-export.xml') -Leases -Force
                # Backup-DhcpServer schreibt der DHCP-Dienst selbst (NetworkService): erst in seinen Ordner, dann kopieren.
                $dienstOrdner = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupBackup'
                if (Test-Path -Path $dienstOrdner) { Remove-Item -Path $dienstOrdner -Recurse -Force -ErrorAction SilentlyContinue }
                Backup-DhcpServer -Path $dienstOrdner
                Copy-Item -Path $dienstOrdner -Destination (Join-Path -Path $dhcpZiel -ChildPath 'Datenbank') -Recurse -Force
                $erledigt += 'Dhcp'
            }
            'Dns' {
                if (-not (Test-NetDnsReady -Still)) { $hinweise += 'DNS: nicht vorhanden oder Dienst gestoppt - uebersprungen'; continue }
                $dnsZiel = Join-Path -Path $Ziel -ChildPath 'Dns'
                New-Item -Path $dnsZiel -ItemType Directory -Force | Out-Null
                $zonen = @(Get-NetDnsZoneInfo -Art Primaer)
                $stempel = $zeit.ToString('yyyyMMddHHmmss')
                foreach ($z in $zonen) {
                    $dateiName = 'NetSetup_{0}_{1}.dns' -f ($z.Name -replace '[^A-Za-z0-9.-]', '_'), $stempel
                    try {
                        Export-DnsServerZone -Name $z.Name -FileName $dateiName
                        $quelle = Get-NetWindowsPath -Unterpfad ('System32\dns\' + $dateiName)
                        if (Test-Path -Path $quelle) { Move-Item -Path $quelle -Destination (Join-Path -Path $dnsZiel -ChildPath $dateiName) -Force }
                    }
                    catch { $hinweise += ('DNS: Zone {0} konnte nicht exportiert werden ({1})' -f $z.Name, $_.Exception.Message) }
                }
                Set-Content -Path (Join-Path -Path $dnsZiel -ChildPath 'zonen.json') -Value (ConvertTo-Json -InputObject @($zonen) -Depth 4) -Encoding UTF8
                $anzahl = Export-NetDnsRecordCsv -Datei (Join-Path -Path $dnsZiel -ChildPath 'eintraege.csv') -Zonen @($zonen | ForEach-Object { $_.Name })
                $einst = @{ Weiterleitungen = @(Get-NetDnsForwarderList) }
                Set-Content -Path (Join-Path -Path $dnsZiel -ChildPath 'einstellungen.json') -Value ($einst | ConvertTo-Json -Depth 4) -Encoding UTF8
                Write-Log -Level Debug -Message "DNS-Backup: $($zonen.Count) Zonen, $anzahl Eintraege"
                $erledigt += 'Dns'
            }
            default { $hinweise += "Bereich $b wird nicht gesichert (AD: Windows-Serversicherung verwenden)." }
        }
    }
    $info = @{ Zeit = $zeit.ToString('yyyy-MM-dd HH:mm:ss'); Anlass = $Anlass; Bereiche = $erledigt; Hinweise = $hinweise; Server = [Environment]::MachineName; Version = $script:NS.Version; Automatisch = [bool]$Automatisch }
    Set-Content -Path (Join-Path -Path $Ziel -ChildPath 'info.json') -Value ($info | ConvertTo-Json -Depth 4) -Encoding UTF8
    foreach ($h in $hinweise) { Write-Log -Level Debug -Message ('Backup: ' + $h) }
    if ($Automatisch) { Write-Log -Message ('Backup erstellt ({0}): {1}' -f ($erledigt -join ', '), (Split-Path -Path $Ziel -Leaf)) }
    else { Write-Log -Level OK -Message ('Backup erstellt ({0}): {1}' -f ($erledigt -join ', '), $Ziel) }
    Remove-NetOldBackup
    return $Ziel
}
#
function Invoke-NetBackupNow {
    $i = Read-NetChoice -Frage 'Was sichern?' -Optionen @('Alles (DHCP, DNS, Konfiguration, Netzwerk)', 'Nur DHCP', 'Nur DNS', 'Nur Konfiguration') -Vorschlag 1
    if ($i -lt 0) { return }
    $bereiche = switch ($i) { 0 { $script:NetBackupBereiche } 1 { @('Dhcp') } 2 { @('Dns') } default { @('Config') } }
    $r = Invoke-NetStep -Titel 'Backup' -Aktion { Backup-NetSetupData -Bereich $bereiche -Anlass 'manuell' }
    if ($r.Erfolg) { Write-NetText -Text ('Ordner: ' + $r.Ergebnis) }
}
#
function Invoke-NetBackupTask {
    <#
    .SYNOPSIS
        Aufgabe ohne Menue (-Task Backup).
    #>
    Backup-NetSetupData -Bereich $script:NetBackupBereiche -Anlass 'Aufgabe' | Out-Null
}
#
function Show-NetBackupList {
    Write-NetTitle -Titel 'Backups'
    $liste = @(Get-NetBackupList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Noch keine Backups vorhanden.'; return }
    foreach ($b in $liste) { Write-Host ('  {0,-19} {1,-28} {2,-30} {3}' -f $b.Zeit, ($b.Bereiche -join ','), $b.Anlass, $(if ($b.Automatisch) { 'automatisch' } else { '' })) }
    Write-Host ('  Ordner: ' + (Get-NetPath -Name Backups)) -ForegroundColor DarkGray
}
# ----------------------------------------------------------------------
# src/wartung/Wiederherstellen.ps1
# ----------------------------------------------------------------------
# Wiederherstellen (Stufe Gefaehrlich) und Rueckgaengig.
# DHCP: Restore-DhcpServer (Datenbank) oder Import-DhcpServer (Export-Datei).
# DNS: Eintraege aus der CSV neu anlegen (vorhandene bleiben, nichts wird doppelt angelegt).
#
function Select-NetBackup {
    param([Parameter(Mandatory = $true)][string]$Bereich, [string]$Titel = 'Backup waehlen')
    $liste = @(Get-NetBackupList | Where-Object { $_.Bereiche -contains $Bereich })
    if ($liste.Count -eq 0) { Write-Log -Level Warn -Message "Es gibt kein Backup mit dem Bereich $Bereich."; return $null }
    return (Select-NetItem -Elemente $liste -Titel $Titel -Eigenschaften @('Zeit', 'Anlass', 'Bereiche', 'Server'))
}
#
function Restore-NetDhcpBackup {
    <#
    .SYNOPSIS
        Stellt DHCP aus einem Backup wieder her (Gefaehrlich: vorher wird der aktuelle Stand gesichert).
    #>
    if (-not (Test-NetCommand -Name 'Restore-DhcpServer')) { Write-Log -Level Fehler -Message 'Die DHCP-Verwaltungstools fehlen (RSAT-DHCP).'; return $false }
    $b = Select-NetBackup -Bereich 'Dhcp' -Titel 'Aus welchem Backup wiederherstellen?'
    if (-not $b) { return $false }
    $art = Read-NetChoice -Frage 'Wie wiederherstellen?' -Optionen @(
        'Datenbank zuruecksetzen (Restore-DhcpServer) - alles wie zum Zeitpunkt des Backups, Dienst wird neu gestartet',
        'Konfiguration importieren (Import-DhcpServer) - Scopes, Optionen, Reservierungen und Leases werden ueberschrieben') -Vorschlag 1
    if ($art -lt 0) { return $false }
    $quelle = Join-Path -Path $b.Pfad -ChildPath 'Dhcp'
    $datenbank = Join-Path -Path $quelle -ChildPath 'Datenbank'
    $export = Join-Path -Path $quelle -ChildPath 'dhcp-export.xml'
    $r = Invoke-NetChange -Titel ('DHCP aus dem Backup vom {0} wiederherstellen' -f $b.Zeit) -Stufe Gefaehrlich -Vorher 'aktueller DHCP-Stand (wird vorher gesichert)' -Nachher ('Stand vom {0} ({1})' -f $b.Zeit, $b.Anlass) -BackupBereich @('Dhcp') `
        -Hinweis 'Alle Aenderungen seit dem Backup gehen verloren. Clients behalten ihre Adressen bis zur naechsten Erneuerung.' -Aktion {
        if ($art -eq 0) {
            $dienstOrdner = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupRestore'
            if (Test-Path -Path $dienstOrdner) { Remove-Item -Path $dienstOrdner -Recurse -Force }
            Copy-Item -Path $datenbank -Destination $dienstOrdner -Recurse -Force
            Restore-DhcpServer -Path $dienstOrdner -Force
            Restart-Service -Name DHCPServer -Force
        }
        else {
            $arbeit = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupImport'
            Import-DhcpServer -File $export -BackupPath $arbeit -Leases -ScopeOverwrite -Force
        }
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Get-NetDnsBackupRecord {
    param([Parameter(Mandatory = $true)][string]$Pfad)
    $datei = Join-Path -Path (Join-Path -Path $Pfad -ChildPath 'Dns') -ChildPath 'eintraege.csv'
    if (-not (Test-Path -Path $datei)) { return @() }
    $liste = @()
    foreach ($z in @(Import-Csv -Path $datei -Delimiter ';')) {
        $daten = @{}
        if ($z.Daten) { try { $daten = ConvertTo-NetHashtable -Objekt ($z.Daten | ConvertFrom-Json) } catch { $daten = @{} } }
        $liste += [pscustomobject]@{ Zone = $z.Zone; Name = $z.Name; Typ = $z.Typ; Wert = $z.Wert; Daten = $daten; Statisch = ($z.Statisch -eq 'True') }
    }
    return $liste
}
#
function Restore-NetDnsBackup {
    <#
    .SYNOPSIS
        Legt DNS-Eintraege aus der CSV eines Backups neu an (nur fehlende; fehlende Zonen auf Wunsch).
    #>
    if (-not (Test-NetDnsReady)) { return $false }
    $b = Select-NetBackup -Bereich 'Dns' -Titel 'Aus welchem Backup wiederherstellen?'
    if (-not $b) { return $false }
    $alle = @(Get-NetDnsBackupRecord -Pfad $b.Pfad | Where-Object { $script:NetDnsTypen -contains $_.Typ })
    $zonen = @($alle | ForEach-Object { $_.Zone } | Select-Object -Unique)
    $wahl = @(Select-NetItem -Elemente $zonen -Titel 'Welche Zonen wiederherstellen?' -Mehrfach)
    if ($wahl.Count -eq 0) { return $false }
    $vorhandeneZonen = @(Get-NetDnsZoneInfo | ForEach-Object { $_.Name })
    $plan = @()
    $neueZonen = @()
    foreach ($zone in $wahl) {
        if ($vorhandeneZonen -notcontains $zone) { $neueZonen += $zone }
        $jetzt = @()
        if ($vorhandeneZonen -contains $zone) { $jetzt = @(Get-NetDnsRecord -Zone $zone) }
        foreach ($e in @($alle | Where-Object { $_.Zone -eq $zone })) {
            $gleich = @($jetzt | Where-Object { $_.Name -eq $e.Name -and $_.Typ -eq $e.Typ -and (Test-NetDnsRecordEqual -A $e.Daten -B $_.Daten) })
            if ($gleich.Count -eq 0 -and $e.Daten.Count -gt 0) { $plan += $e }
        }
    }
    if ($plan.Count -eq 0 -and $neueZonen.Count -eq 0) { Write-Log -Level OK -Message 'Alle Eintraege aus dem Backup sind vorhanden. Nichts zu tun.'; return $true }
    $speicherung = $null
    if ($neueZonen.Count -gt 0) {
        Write-Log -Message ('Diese Zonen fehlen und werden angelegt: ' + ($neueZonen -join ', '))
        $speicherung = Read-NetDnsZoneStorage
        if (-not $speicherung) { return $false }
    }
    $rueck = @($plan | ForEach-Object { @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $_.Zone; Name = $_.Name; Typ = $_.Typ; Daten = $_.Daten } } })
    $r = Invoke-NetChange -Titel ('DNS aus dem Backup vom {0} wiederherstellen' -f $b.Zeit) -Stufe Gefaehrlich -Vorher ('{0} Eintraege fehlen' -f $plan.Count) -Nachher (@($neueZonen | ForEach-Object { 'Zone ' + $_ }) + @($plan | Select-Object -First 30 | ForEach-Object { '{0} {1} {2} in {3}' -f $_.Name, $_.Typ, $_.Wert, $_.Zone })) -BackupBereich @('Dns') -Aktion {
        foreach ($zone in $neueZonen) {
            $p = @{ Name = $zone; DynamicUpdate = $speicherung.Updates }
            if ($speicherung.AdIntegriert) { $p.ReplicationScope = $speicherung.Replikation } else { $p.ZoneFile = $zone + '.dns' }
            Add-DnsServerPrimaryZone @p
        }
        foreach ($e in $plan) { Add-NetDnsRecordExact -ZoneName $e.Zone -Name $e.Name -Typ $e.Typ -Daten $e.Daten }
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Undo-NetLastChange {
    $offen = @(Get-NetUndoEntry -NurOffen)
    if ($offen.Count -eq 0) { Write-Log -Message 'Es gibt keine Aenderung, die rueckgaengig gemacht werden kann.'; return }
    Write-Log -Message ('Letzte Aenderung: {0} ({1})' -f $offen[0].Titel, $offen[0].Zeit)
    Undo-NetChange -Id $offen[0].Id | Out-Null
}
#
function Undo-NetSelectedChange {
    $offen = @(Get-NetUndoEntry -NurOffen | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Zeit = $_.Zeit; Titel = $_.Titel; Benutzer = $_.Benutzer } })
    $w = Select-NetItem -Elemente $offen -Titel 'Welche Aenderung rueckgaengig machen?' -Eigenschaften @('Zeit', 'Titel', 'Benutzer')
    if ($w) {
        $spaeter = @($offen | Where-Object { $_.Zeit -gt $w.Zeit })
        if ($spaeter.Count -gt 0) { Write-Log -Level Warn -Message ('Danach gab es {0} weitere Aenderung(en). Diese bleiben bestehen und koennten von der alten Einstellung abhaengen.' -f $spaeter.Count) }
        Undo-NetChange -Id $w.Id | Out-Null
    }
}
#
function Show-NetChangeHistory {
    Write-NetTitle -Titel 'Aenderungsverlauf'
    $liste = @(Get-NetUndoEntry)
    if ($liste.Count -eq 0) { Write-Log -Message 'Noch keine Aenderungen.'; return }
    foreach ($e in $liste) {
        $farbe = 'Gray'
        if ($e.Status -ne 'Offen') { $farbe = 'DarkGray' }
        Write-Host ('  {0}  {1,-12} {2}' -f $e.Zeit, $e.Status, $e.Titel) -ForegroundColor $farbe
    }
}
# ----------------------------------------------------------------------
# src/wartung/Umzug.ps1
# ----------------------------------------------------------------------
# Serverumzug: Paket exportieren (DHCP mit Leases, DNS-Zonen und -Eintraege, Konfiguration)
# und auf dem Zielserver mit Bestandsaufnahme und Vorher/Nachher importieren.
#
function Export-NetMigrationPackage {
    <#
    .SYNOPSIS
        Erstellt ein Umzugspaket im Ordner Backups (Umzug_<Server>_<Zeit>), optional als ZIP.
    #>
    $z = Get-NetSetupState
    $ziel = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('Umzug_{0}_{1}' -f [Environment]::MachineName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $bereiche = @('Config')
    if ($z.Dhcp.Verfuegbar) { $bereiche += 'Dhcp' }
    if ($z.Dns.Verfuegbar) { $bereiche += 'Dns' }
    $r = Invoke-NetStep -Titel 'Umzugspaket erstellen' -Aktion { Backup-NetSetupData -Bereich $bereiche -Anlass 'Umzug' -Ziel $ziel }
    if (-not $r.Erfolg) { return $null }
    Write-NetText -Text ("Paket: {0}`nDiesen Ordner (z. B. per Freigabe oder USB-Stick) auf den Zielserver kopieren und dort NetSetup -> Backup -> Umzug importieren." -f $ziel) -Farbe White
    if ((Test-NetCommand -Name 'Compress-Archive') -and (Read-NetYesNo -Frage 'Zusaetzlich als ZIP-Datei verpacken?' -Vorschlag $true)) {
        $zip = $ziel + '.zip'
        Compress-Archive -Path (Join-Path -Path $ziel -ChildPath '*') -DestinationPath $zip -Force
        Write-Log -Level OK -Message ('ZIP: ' + $zip)
    }
    return $ziel
}
#
function Read-NetMigrationPackage {
    <#
    .SYNOPSIS
        Liest ein Umzugspaket (Ordner oder ZIP) und liefert seinen Inhalt.
    #>
    param([Parameter(Mandatory = $true)][string]$Pfad)
    if ($Pfad -like '*.zip') {
        $entpackt = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('Import_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Expand-Archive -Path $Pfad -DestinationPath $entpackt -Force
        $Pfad = $entpackt
    }
    $info = Join-Path -Path $Pfad -ChildPath 'info.json'
    if (-not (Test-Path -Path $info)) { throw 'Kein gueltiges NetSetup-Paket (info.json fehlt).' }
    $meta = Get-Content -Path $info -Raw | ConvertFrom-Json
    $export = Join-Path -Path (Join-Path -Path $Pfad -ChildPath 'Dhcp') -ChildPath 'dhcp-export.xml'
    $scopes = @()
    if (Test-Path -Path $export) {
        [xml]$xml = Get-Content -Path $export -Raw
        foreach ($s in @($xml.SelectNodes('//IPv4/Scopes/Scope'))) {
            $scopes += [pscustomobject]@{ ScopeId = [string]$s.ScopeId; Name = [string]$s.Name; Start = [string]$s.StartRange; Ende = [string]$s.EndRange }
        }
    }
    $zonenDatei = Join-Path -Path (Join-Path -Path $Pfad -ChildPath 'Dns') -ChildPath 'zonen.json'
    $zonen = @()
    if (Test-Path -Path $zonenDatei) { $zonen = @(Get-Content -Path $zonenDatei -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{
        Pfad      = $Pfad
        Server    = [string]$meta.Server
        Zeit      = [string]$meta.Zeit
        Export    = $export
        Scopes    = $scopes
        Zonen     = $zonen
        Eintraege = @(Get-NetDnsBackupRecord -Pfad $Pfad | Where-Object { $script:NetDnsTypen -contains $_.Typ })
    }
}
#
function Import-NetMigrationPackage {
    <#
    .SYNOPSIS
        Importiert ein Umzugspaket auf diesem Server: Bestandsaufnahme, Vorher/Nachher, Gefaehrlich.
        Vorhandene Scopes und Zonen werden nicht ueberschrieben.
    #>
    $pfad = Read-NetText -Frage 'Pfad zum Umzugspaket (Ordner oder ZIP)' -Pruefung { param($t) if (Test-Path -Path $t) { $null } else { 'Der Pfad existiert nicht.' } }
    if (-not $pfad) { return $false }
    $paket = $null
    try { $paket = Read-NetMigrationPackage -Pfad $pfad }
    catch { Write-NetError -Fehler $_ -Titel 'Umzugspaket lesen' | Out-Null; return $false }
    Write-Log -Message ('Paket von {0} vom {1}.' -f $paket.Server, $paket.Zeit)
    $z = Get-NetSetupState
    $vorhandeneScopes = @($z.Dhcp.Scopes | ForEach-Object { $_.ScopeId })
    $neueScopes = @($paket.Scopes | Where-Object { $vorhandeneScopes -notcontains $_.ScopeId })
    $vorhandeneZonen = @($z.Dns.Zonen | ForEach-Object { $_.Name })
    $neueZonen = @($paket.Zonen | Where-Object { $vorhandeneZonen -notcontains $_.Name -and -not $_.Name.StartsWith('_msdcs') })
    foreach ($s in @($paket.Scopes | Where-Object { $vorhandeneScopes -contains $_.ScopeId })) { Write-Log -Level Warn -Message ('Scope {0} gibt es hier schon - wird nicht ueberschrieben.' -f $s.ScopeId) }
    if ($neueScopes.Count -gt 0 -and -not (Test-NetDhcpReady)) { Write-Log -Level Warn -Message 'DHCP ist hier nicht bereit, die Scopes werden uebersprungen.'; $neueScopes = @() }
    if ($neueZonen.Count -gt 0 -and -not (Test-NetDnsReady)) { Write-Log -Level Warn -Message 'DNS ist hier nicht bereit, die Zonen werden uebersprungen.'; $neueZonen = @() }
    if ($neueScopes.Count -eq 0 -and $neueZonen.Count -eq 0) { Write-Log -Level OK -Message 'Alles aus dem Paket ist hier schon vorhanden. Nichts zu tun.'; return $true }
    $speicherung = $null
    if ($neueZonen.Count -gt 0) { $speicherung = Read-NetDnsZoneStorage; if (-not $speicherung) { return $false } }
    $zonenNamen = @($neueZonen | ForEach-Object { $_.Name })
    $eintraege = @($paket.Eintraege | Where-Object { $zonenNamen -contains $_.Zone -and $_.Daten.Count -gt 0 })
    $scopeIds = @($neueScopes | ForEach-Object { $_.ScopeId })
    $export = $paket.Export
    $vorher = @{ Scopes = ($vorhandeneScopes -join ', '); Zonen = ($vorhandeneZonen -join ', ') }
    $nachher = @{ 'Neue Scopes' = (($neueScopes | ForEach-Object { '{0} ({1})' -f $_.ScopeId, $_.Name }) -join ', '); 'Neue Zonen' = ($zonenNamen -join ', '); 'DNS-Eintraege' = $eintraege.Count }
    $r = Invoke-NetChange -Titel ('Umzugspaket von {0} importieren' -f $paket.Server) -Stufe Gefaehrlich -Vorher $vorher -Nachher $nachher -BackupBereich @('Dhcp', 'Dns', 'Config') `
        -Hinweis 'Nach dem Import den alten DHCP-Server deaktivieren, damit nicht zwei Server dieselben Adressen vergeben. Danach den Doktor ausfuehren (Autorisierung, Optionen 006).' -Aktion {
        if ($scopeIds.Count -gt 0) {
            $arbeit = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupImport'
            Import-DhcpServer -File $export -BackupPath $arbeit -ScopeId $scopeIds -Leases -Force
        }
        foreach ($zone in $zonenNamen) {
            $p = @{ Name = $zone; DynamicUpdate = $speicherung.Updates }
            if ($speicherung.AdIntegriert) { $p.ReplicationScope = $speicherung.Replikation } else { $p.ZoneFile = $zone + '.dns' }
            Add-DnsServerPrimaryZone @p
        }
        foreach ($e in $eintraege) {
            try { Add-NetDnsRecordExact -ZoneName $e.Zone -Name $e.Name -Typ $e.Typ -Daten $e.Daten }
            catch { Write-Log -Level Debug -Message ('Eintrag {0} {1} in {2} uebersprungen: {3}' -f $e.Name, $e.Typ, $e.Zone, $_.Exception.Message) }
        }
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
# ----------------------------------------------------------------------
# src/wartung/CsvImport.ps1
# ----------------------------------------------------------------------
# Massenimport aus CSV fuer DNS-Eintraege und DHCP-Reservierungen.
# Jede Zeile wird vorher geprueft; bei einem Fehler wird nichts importiert (alles oder nichts).
# Vorlagen liegen im Ordner Vorlagen (Trennzeichen Semikolon).
#
$script:NetVorlageDns = @(
    'Zone;Name;Typ;Wert;Prioritaet;Gewicht;Port',
    'ad.firma.ch;drucker-buero;A;192.168.1.30;;;',
    'ad.firma.ch;intranet;CNAME;srv01.ad.firma.ch;;;',
    'ad.firma.ch;@;MX;mail.firma.ch;10;;',
    'ad.firma.ch;@;TXT;v=spf1 mx -all;;;',
    'ad.firma.ch;_sip._tcp;SRV;sip.ad.firma.ch;0;100;5060'
)
$script:NetVorlageReservierung = @(
    'ScopeId;IP;MAC;Name;Beschreibung',
    '192.168.1.0;192.168.1.150;00-15-5D-01-02-03;drucker-buero;Drucker im Buero',
    '192.168.1.0;192.168.1.151;00-15-5D-01-02-04;telefon-empfang;IP-Telefon'
)
#
function New-NetImportTemplate {
    <#
    .SYNOPSIS
        Legt die Beispiel-CSVs im Ordner Vorlagen an (vorhandene werden nicht ueberschrieben).
    #>
    $ordner = Get-NetPath -Name Vorlagen
    if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
    foreach ($v in @(@{ Datei = 'dns-eintraege.csv'; Inhalt = $script:NetVorlageDns }, @{ Datei = 'reservierungen.csv'; Inhalt = $script:NetVorlageReservierung })) {
        $pfad = Join-Path -Path $ordner -ChildPath $v.Datei
        if (Test-Path -Path $pfad) { Write-Log -Message ('Vorlage existiert bereits: ' + $pfad); continue }
        Set-Content -Path $pfad -Value $v.Inhalt -Encoding UTF8
        Write-Log -Level OK -Message ('Vorlage angelegt: ' + $pfad)
    }
}
#
function ConvertTo-NetDnsImportRow {
    <#
    .SYNOPSIS
        Prueft eine CSV-Zeile fuer DNS und liefert @{ Fehler; Eintrag } (Eintrag fuer Add-NetDnsRecordExact).
    #>
    param([Parameter(Mandatory = $true)][object]$Zeile, [string[]]$Zonen)
    $typ = ([string]$Zeile.Typ).Trim().ToUpper()
    $zone = ([string]$Zeile.Zone).Trim().ToLower().TrimEnd('.')
    $name = ([string]$Zeile.Name).Trim()
    $wert = ([string]$Zeile.Wert).Trim()
    if ($script:NetDnsTypen -notcontains $typ) { return @{ Fehler = "Typ '$typ' ist unbekannt (erlaubt: $($script:NetDnsTypen -join ', '))." } }
    if ($Zonen -notcontains $zone) { return @{ Fehler = "Zone '$zone' gibt es auf diesem DNS-Server nicht." } }
    $grund = Test-NetDnsRecordName -Name $name -Srv:($typ -eq 'SRV')
    if ($grund) { return @{ Fehler = $grund } }
    if (-not $wert) { return @{ Fehler = 'Wert fehlt.' } }
    $daten = @{}
    $fqdnOk = ((Test-NetDomainName -Name $wert).Gueltig -or $wert -match '^[A-Za-z0-9-]+$')
    switch ($typ) {
        'A' { if (-not (Test-NetIPv4Address -Text $wert)) { return @{ Fehler = "'$wert' ist keine gueltige IPv4-Adresse." } }; $daten.IPv4Address = $wert }
        'AAAA' { if (-not (Test-NetIPv6Address -Text $wert)) { return @{ Fehler = "'$wert' ist keine gueltige IPv6-Adresse." } }; $daten.IPv6Address = $wert }
        'CNAME' { if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }; $daten.HostNameAlias = $wert }
        'PTR' { if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }; $daten.PtrDomainName = $wert }
        'TXT' { if ($wert.Length -gt 255) { return @{ Fehler = 'Text ist laenger als 255 Zeichen.' } }; $daten.DescriptiveText = $wert }
        'MX' {
            if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }
            $prio = 0
            if (-not [int]::TryParse([string]$Zeile.Prioritaet, [ref]$prio) -or $prio -lt 0 -or $prio -gt 65535) { return @{ Fehler = 'Prioritaet muss eine Zahl von 0 bis 65535 sein.' } }
            $daten.MailExchange = $wert; $daten.Preference = $prio
        }
        'SRV' {
            if (-not $fqdnOk) { return @{ Fehler = "'$wert' ist kein gueltiger Name." } }
            $prio = 0; $gew = 0; $port = 0
            if (-not [int]::TryParse([string]$Zeile.Prioritaet, [ref]$prio) -or -not [int]::TryParse([string]$Zeile.Gewicht, [ref]$gew) -or -not [int]::TryParse([string]$Zeile.Port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                return @{ Fehler = 'SRV braucht Prioritaet, Gewicht und Port (1-65535) als Zahlen.' }
            }
            $daten.DomainName = $wert; $daten.Priority = $prio; $daten.Weight = $gew; $daten.Port = $port
        }
    }
    return @{ Fehler = $null; Eintrag = @{ ZoneName = $zone; Name = $name; Typ = $typ; Daten = $daten } }
}
#
function Test-NetDnsImport {
    <#
    .SYNOPSIS
        Prueft alle Zeilen einer DNS-CSV. Liefert Fehler (pro Zeile), Neu und Vorhanden.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Zeilen)
    $zonen = @(Get-NetDnsZoneInfo | Where-Object { $_.Typ -eq 'Primary' } | ForEach-Object { $_.Name })
    $fehler = @()
    $neu = @()
    $vorhanden = @()
    $gesehen = @{}
    $nr = 1
    foreach ($z in $Zeilen) {
        $nr++
        $r = ConvertTo-NetDnsImportRow -Zeile $z -Zonen $zonen
        if ($r.Fehler) { $fehler += ('Zeile {0}: {1}' -f $nr, $r.Fehler); continue }
        $e = $r.Eintrag
        $schluessel = ('{0}|{1}|{2}|{3}' -f $e.ZoneName, $e.Name, $e.Typ, (($e.Daten.Keys | Sort-Object | ForEach-Object { $e.Daten[$_] }) -join ',')).ToLower()
        if ($gesehen.ContainsKey($schluessel)) { $fehler += ('Zeile {0}: doppelt in der Datei (wie Zeile {1}).' -f $nr, $gesehen[$schluessel]); continue }
        $gesehen[$schluessel] = $nr
        $pruef = Test-NetDnsRecordConflict -Zone $e.ZoneName -Name $e.Name -Typ $e.Typ -Daten $e.Daten
        if ($pruef.Duplikat) { $vorhanden += $e; continue }
        if ($pruef.Konflikte.Count -gt 0) { $fehler += ('Zeile {0}: Konflikt - {1}' -f $nr, ($pruef.Konflikte -join ' ')); continue }
        $neu += $e
    }
    return [pscustomobject]@{ Fehler = $fehler; Neu = $neu; Vorhanden = $vorhanden }
}
#
function Test-NetReservationImport {
    <#
    .SYNOPSIS
        Prueft alle Zeilen einer Reservierungs-CSV (Scope, Bereich, Ausschluss, belegt, MAC, Name).
    #>
    param([Parameter(Mandatory = $true)][object[]]$Zeilen)
    $scopes = @(Get-NetDhcpScopeList)
    $fehler = @()
    $neu = @()
    $vorhanden = @()
    $ipGesehen = @{}
    $macGesehen = @{}
    $cache = @{}
    $nr = 1
    foreach ($z in $Zeilen) {
        $nr++
        $id = ([string]$z.ScopeId).Trim()
        $ip = ([string]$z.IP).Trim()
        $mac = ConvertTo-NetMacAddress -Text ([string]$z.MAC)
        $name = ([string]$z.Name).Trim()
        $scope = @($scopes | Where-Object { $_.ScopeId -eq $id }) | Select-Object -First 1
        if (-not $scope) { $fehler += ("Zeile {0}: Scope '{1}' gibt es nicht." -f $nr, $id); continue }
        if (-not (Test-NetIPv4Address -Text $ip)) { $fehler += ("Zeile {0}: '{1}' ist keine gueltige IPv4-Adresse." -f $nr, $ip); continue }
        if (-not $mac) { $fehler += ("Zeile {0}: '{1}' ist keine gueltige MAC-Adresse." -f $nr, $z.MAC); continue }
        $grund = Test-NetDnsRecordName -Name $name
        if (-not $name -or $grund) { $fehler += ('Zeile {0}: Name ungueltig ({1}).' -f $nr, $grund); continue }
        if ($ipGesehen.ContainsKey($ip)) { $fehler += ('Zeile {0}: IP {1} kommt schon in Zeile {2} vor.' -f $nr, $ip, $ipGesehen[$ip]); continue }
        if ($macGesehen.ContainsKey($mac)) { $fehler += ('Zeile {0}: MAC {1} kommt schon in Zeile {2} vor.' -f $nr, $mac, $macGesehen[$mac]); continue }
        $ipGesehen[$ip] = $nr
        $macGesehen[$mac] = $nr
        if (-not $cache.ContainsKey($id)) {
            $cache[$id] = @{
                Aus  = @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id })
                Res  = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })
                Leas = @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id })
            }
        }
        $c = $cache[$id]
        $gleich = @($c.Res | Where-Object { $_ -and (ConvertTo-NetString $_.IPAddress) -eq $ip -and (ConvertTo-NetMacAddress -Text ([string]$_.ClientId)) -eq $mac })
        if ($gleich.Count -gt 0) { $vorhanden += @{ ScopeId = $id; IP = $ip }; continue }
        $probleme = @(Test-NetDhcpReservation -Scope $scope -IPAddress $ip -Mac $mac -Ausschluesse $c.Aus -Reservierungen $c.Res -Leases $c.Leas)
        if ($probleme.Count -gt 0) { $fehler += ('Zeile {0}: {1}' -f $nr, ($probleme -join ' ')); continue }
        $neu += @{ ScopeId = $id; IPAddress = $ip; ClientId = $mac; Name = $name; Description = ([string]$z.Beschreibung) }
    }
    return [pscustomobject]@{ Fehler = $fehler; Neu = $neu; Vorhanden = $vorhanden }
}
#
function Import-NetCsv {
    <#
    .SYNOPSIS
        Massenimport (DNS oder Reservierungen): pruefen, Ergebnis zeigen (wie im Probelauf),
        nach Bestaetigung alles importieren. Bei einem Fehler waehrend des Imports wird das
        bereits Angelegte wieder entfernt - nichts wird halb importiert.
    #>
    param([ValidateSet('Dns', 'Reservierung')][string]$Art, [string]$Datei)
    if (-not $Art) {
        $i = Read-NetChoice -Frage 'Was importieren?' -Optionen @('DNS-Eintraege', 'DHCP-Reservierungen') -Vorschlag 1
        if ($i -lt 0) { return $false }
        $Art = @('Dns', 'Reservierung')[$i]
    }
    if ($Art -eq 'Dns' -and -not (Test-NetDnsReady)) { return $false }
    if ($Art -eq 'Reservierung' -and -not (Test-NetDhcpReady)) { return $false }
    if (-not $Datei) {
        $vorlage = Join-Path -Path (Get-NetPath -Name Vorlagen) -ChildPath $(if ($Art -eq 'Dns') { 'dns-eintraege.csv' } else { 'reservierungen.csv' })
        Write-NetText -Text ('Format siehe Vorlage: ' + $vorlage + ' (Trennzeichen Semikolon, erste Zeile = Spaltennamen).')
        $Datei = Read-NetText -Frage 'Pfad zur CSV-Datei' -Vorschlag $vorlage -Pruefung { param($t) if (Test-Path -Path $t -PathType Leaf) { $null } else { 'Die Datei existiert nicht.' } }
        if (-not $Datei) { return $false }
    }
    $zeilen = @(Import-Csv -Path $Datei -Delimiter ';' -Encoding UTF8)
    if ($zeilen.Count -eq 0) { Write-Log -Level Warn -Message 'Die Datei enthaelt keine Zeilen.'; return $false }
    $pflicht = @('Zone', 'Name', 'Typ', 'Wert')
    if ($Art -eq 'Reservierung') { $pflicht = @('ScopeId', 'IP', 'MAC', 'Name') }
    $spalten = @($zeilen[0].PSObject.Properties | ForEach-Object { $_.Name })
    $fehlt = @($pflicht | Where-Object { $spalten -notcontains $_ })
    if ($fehlt.Count -gt 0) { Write-Log -Level Fehler -Message ('Spalten fehlen: ' + ($fehlt -join ', ') + '. Trennzeichen muss ein Semikolon sein.'); return $false }
#
    $ergebnis = $null
    if ($Art -eq 'Dns') { $ergebnis = Test-NetDnsImport -Zeilen $zeilen } else { $ergebnis = Test-NetReservationImport -Zeilen $zeilen }
    Write-NetTitle -Titel ('Pruefung der Datei: {0} Zeilen' -f $zeilen.Count)
    Write-NetStatus -Status OK -Bereich 'neu anzulegen' -Text ([string]@($ergebnis.Neu).Count)
    Write-NetStatus -Status NA -Bereich 'schon vorhanden' -Text ([string]@($ergebnis.Vorhanden).Count)
    if (@($ergebnis.Fehler).Count -gt 0) {
        Write-NetStatus -Status FEHLER -Bereich 'fehlerhafte Zeilen' -Text ([string]@($ergebnis.Fehler).Count)
        foreach ($f in $ergebnis.Fehler) { Write-Host ('    ' + $f) -ForegroundColor Red }
        Write-Log -Level Fehler -Message 'Es wird nichts importiert. Bitte die Zeilen korrigieren und erneut starten.'
        return $false
    }
    $neu = @($ergebnis.Neu)
    if ($neu.Count -eq 0) { Write-Log -Level OK -Message 'Alles aus der Datei ist schon vorhanden. Nichts zu tun.'; return $true }
    $anzeige = @()
    $rueck = @()
    if ($Art -eq 'Dns') {
        $anzeige = @($neu | ForEach-Object { '{0} {1} {2} in {3}' -f $_.Name, $_.Typ, (($_.Daten.Values | ForEach-Object { [string]$_ }) -join ' '), $_.ZoneName })
        $rueck = @($neu | ForEach-Object { @{ Befehl = 'Remove-NetDnsRecordExact'; Parameter = @{ ZoneName = $_.ZoneName; Name = $_.Name; Typ = $_.Typ; Daten = $_.Daten } } })
    }
    else {
        $anzeige = @($neu | ForEach-Object { '{0} {1} {2} (Scope {3})' -f $_.IPAddress, $_.ClientId, $_.Name, $_.ScopeId })
        $rueck = @($neu | ForEach-Object { @{ Befehl = 'Remove-DhcpServerv4Reservation'; Parameter = @{ IPAddress = $_.IPAddress } } })
    }
    $importArt = $Art
    $r = Invoke-NetChange -Titel ('{0} {1} aus CSV importieren' -f $neu.Count, $(if ($Art -eq 'Dns') { 'DNS-Eintraege' } else { 'Reservierungen' })) -Stufe Bestaetigen -Vorher ('{0} vorhanden' -f @($ergebnis.Vorhanden).Count) -Nachher $anzeige -BackupBereich @($(if ($Art -eq 'Dns') { 'Dns' } else { 'Dhcp' })) -Aktion {
        $angelegt = New-Object System.Collections.ArrayList
        try {
            foreach ($e in $neu) {
                if ($importArt -eq 'Dns') { Add-NetDnsRecordExact -ZoneName $e.ZoneName -Name $e.Name -Typ $e.Typ -Daten $e.Daten }
                else { Add-DhcpServerv4Reservation -ScopeId $e.ScopeId -IPAddress $e.IPAddress -ClientId $e.ClientId -Name $e.Name -Description $e.Description }
                [void]$angelegt.Add($e)
            }
        }
        catch {
            $fehlerText = $_.Exception.Message
            Write-Log -Level Warn -Message ('Fehler beim Import ({0}). {1} bereits angelegte Eintraege werden wieder entfernt.' -f $fehlerText, $angelegt.Count)
            for ($i = $angelegt.Count - 1; $i -ge 0; $i--) {
                $x = $angelegt[$i]
                try {
                    if ($importArt -eq 'Dns') { Remove-NetDnsRecordExact -ZoneName $x.ZoneName -Name $x.Name -Typ $x.Typ -Daten $x.Daten }
                    else { Remove-DhcpServerv4Reservation -IPAddress $x.IPAddress }
                }
                catch { Write-Log -Level Fehler -Message ('Konnte {0} nicht zuruecknehmen: {1}' -f $x.Name, $_.Exception.Message) }
            }
            throw
        }
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
# ----------------------------------------------------------------------
# src/wartung/Berichte.ps1
# ----------------------------------------------------------------------
# Berichte als HTML (alles inline: keine externen Links, Schriften oder Scripts) und CSV:
# Scope-Auslastung, freie IPs, Leases ohne DNS, Doktor-Ergebnis, Aenderungsverlauf.
#
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
#
function ConvertTo-NetHtmlText {
    param([AllowNull()][object]$Wert)
    if ($null -eq $Wert) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Wert)
}
#
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
#
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
#
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
#
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
#
function New-NetHealthReport {
    <#
    .SYNOPSIS
        Bericht fuer die geplante Gesundheitspruefung (-Task Health).
    #>
    param([object[]]$Ergebnisse)
    return (New-NetReport -DoktorErgebnis $Ergebnisse -Name 'Gesundheit')
}
#
function Invoke-NetReportTask {
    New-NetReport | Out-Null
}
#
function Show-NetReport {
    $datei = New-NetReport
    if ($datei -and $script:NS.Umgebung -and -not $script:NS.Umgebung.IstCore -and (Read-NetYesNo -Frage 'Bericht jetzt im Browser oeffnen?' -Vorschlag $true)) {
        Invoke-Item -Path $datei
    }
}
#
function Show-NetFreeAddress {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'Freie IP-Adressen'
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $f = Get-NetFreeAddressRange -ScopeId $s.ScopeId -Start $s.Start -Ende $s.Ende
        Write-Host ('  {0} ({1}): {2} frei' -f $s.ScopeId, $s.Name, $f.Frei) -ForegroundColor White
        foreach ($b in ($f.Bereiche | Select-Object -First 20)) { Write-Host ('    ' + $b) }
    }
}
#
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
# ----------------------------------------------------------------------
# src/wartung/WartungMenue.ps1
# ----------------------------------------------------------------------
# Geplante Aufgabe (taeglich -Task Health) und Menue "Backup, Wiederherstellen, Rueckgaengig".
#
$script:NetAufgabeName = 'NetSetup Gesundheitspruefung'
#
function Get-NetHealthTask {
    return (Get-NetSafe -Beschreibung 'Geplante Aufgabe' -Abfrage { Get-ScheduledTask -TaskName $script:NetAufgabeName })
}
#
function Register-NetHealthTask {
    <#
    .SYNOPSIS
        Legt die taegliche Gesundheitspruefung als geplante Aufgabe an (laeuft als SYSTEM, aendert nichts).
    #>
    $vorhanden = Get-NetHealthTask
    if ($vorhanden) { Write-Log -Level OK -Message ('Die geplante Aufgabe "{0}" gibt es bereits.' -f $script:NetAufgabeName); return $true }
    $uhrzeit = Read-NetText -Frage 'Uhrzeit (HH:MM)' -Vorschlag '06:30' -Pruefung { param($t) if ($t -match '^([01]\d|2[0-3]):[0-5]\d$') { $null } else { 'Bitte im Format HH:MM eingeben, z. B. 06:30.' } }
    if (-not $uhrzeit) { return $false }
    $scriptDatei = Save-NetSelf
    if (-not $scriptDatei) { $scriptDatei = Get-NetPath -Name Script }
    $argumente = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Task Health' -f $scriptDatei
    $exe = Get-NetPowerShellExe
    $name = $script:NetAufgabeName
    $r = Invoke-NetChange -Titel "Geplante Aufgabe '$name' anlegen" -Stufe Bestaetigen -Vorher '(keine)' -Nachher @{ Aufgabe = $name; Zeit = "taeglich $uhrzeit"; Konto = 'SYSTEM'; Befehl = "$exe $argumente"; Ergebnis = (Get-NetPath -Name Berichte) } `
        -Hinweis 'Die Aufgabe prueft nur und schreibt einen Bericht. Sie aendert nichts am Server.' -Aktion {
        $aktion = New-ScheduledTaskAction -Execute $exe -Argument $argumente -WorkingDirectory (Get-NetPath -Name Root)
        $ausloeser = New-ScheduledTaskTrigger -Daily -At $uhrzeit
        $konto = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $einst = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(1))
        Register-ScheduledTask -TaskName $name -Action $aktion -Trigger $ausloeser -Principal $konto -Settings $einst -Description 'Taegliche Pruefung von AD, DNS und DHCP durch NetSetup (aendert nichts).' | Out-Null
    } -Rueckgaengig @{ Befehl = 'Unregister-ScheduledTask'; Parameter = @{ TaskName = $name; Confirm = $false } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Unregister-NetHealthTask {
    if (-not (Get-NetHealthTask)) { Write-Log -Message 'Es gibt keine geplante Aufgabe von NetSetup.'; return }
    $name = $script:NetAufgabeName
    Invoke-NetChange -Titel "Geplante Aufgabe '$name' entfernen" -Stufe Bestaetigen -Vorher 'vorhanden' -Nachher '(entfernt)' -Aktion {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    } | Out-Null
}
#
function Show-NetHealthTask {
    $t = Get-NetHealthTask
    if (-not $t) { Write-NetStatus -Status NA -Bereich 'Geplante Aufgabe' -Text 'nicht eingerichtet (optional)'; return }
    Write-NetStatus -Status OK -Bereich 'Geplante Aufgabe' -Text ('{0}, Zustand {1}' -f $t.TaskName, $t.State)
}
#
function Show-NetUndoMenu {
    $eintraege = @(
        @{ Text = 'Letzte Aenderung rueckgaengig machen'; Aktion = 'Undo-NetLastChange'; Hilfe = 'Fuehrt die gemerkte Gegenaktion der letzten Aenderung aus (mit Vorher/Nachher und Bestaetigung).' },
        @{ Text = 'Aenderung aus dem Verlauf waehlen'; Aktion = 'Undo-NetSelectedChange'; Hilfe = 'Waehlt eine bestimmte Aenderung aus dem Verlauf und nimmt sie zurueck.' },
        @{ Text = 'Verlauf anzeigen'; Aktion = 'Show-NetChangeHistory'; Hilfe = 'Alle Aenderungen mit Zeit und Status.' }
    )
    Show-NetMenu -Titel 'Rueckgaengig' -Eintraege $eintraege
}
#
function Show-NetMaintenanceMenu {
    $eintraege = @(
        @{ Text = 'Backup jetzt erstellen'; Aktion = 'Invoke-NetBackupNow'; Hilfe = "Sichert DHCP (Datenbank + Export mit Leases), DNS (jede Zone + alle Eintraege als CSV), Konfiguration und Netzwerk.`nVor jeder Aenderung sichert NetSetup automatisch; die letzten 20 Backups werden aufbewahrt (Einstellungen)." },
        @{ Text = 'Backups anzeigen'; Aktion = 'Show-NetBackupList'; Hilfe = 'Liste aller Backups mit Zeit, Anlass und Inhalt.' },
        @{ Text = 'DHCP wiederherstellen (gefaehrlich)'; Aktion = { Restore-NetDhcpBackup | Out-Null }; Hilfe = 'Datenbank zuruecksetzen (Restore-DhcpServer) oder Konfiguration importieren (Import-DhcpServer). Vorher wird der aktuelle Stand gesichert, Servername eintippen.' },
        @{ Text = 'DNS-Eintraege wiederherstellen (gefaehrlich)'; Aktion = { Restore-NetDnsBackup | Out-Null }; Hilfe = 'Legt fehlende Eintraege (und Zonen) aus der CSV eines Backups neu an. Vorhandene Eintraege bleiben unveraendert.' },
        @{ Text = 'Rueckgaengig'; Aktion = 'Show-NetUndoMenu'; OhnePause = $true; Hilfe = 'Letzte Aenderung oder eine Aenderung aus dem Verlauf zuruecknehmen.' },
        @{ Text = 'Serverumzug: Paket exportieren'; Aktion = { Export-NetMigrationPackage | Out-Null }; Hilfe = 'Packt DHCP (mit Leases), DNS-Zonen und -Eintraege und die Konfiguration in einen Ordner (optional ZIP) fuer den neuen Server.' },
        @{ Text = 'Serverumzug: Paket importieren'; Aktion = { Import-NetMigrationPackage | Out-Null }; Hilfe = 'Importiert ein Paket auf diesem Server: Bestandsaufnahme, Vorher/Nachher, vorhandene Scopes und Zonen werden nicht ueberschrieben.' },
        @{ Text = 'CSV-Import (DNS-Eintraege oder Reservierungen)'; Aktion = { Import-NetCsv | Out-Null }; Hilfe = "Prueft jede Zeile vorher und zeigt das Ergebnis. Bei einem Fehler wird nichts importiert (alles oder nichts).`nVorlagen: Menuepunkt 'Vorlagen anlegen'." },
        @{ Text = 'Vorlagen anlegen'; Aktion = 'New-NetImportTemplate'; Hilfe = 'Legt Beispiel-CSVs fuer DNS-Eintraege und Reservierungen im Ordner Vorlagen an.' },
        @{ Text = 'Geplante Aufgabe: taegliche Pruefung einrichten'; Aktion = { Register-NetHealthTask | Out-Null }; Hilfe = 'Optional: taeglich NetSetup -Task Health als SYSTEM. Prueft nur und schreibt einen Bericht nach Berichte.' },
        @{ Text = 'Geplante Aufgabe entfernen'; Aktion = 'Unregister-NetHealthTask'; Hilfe = 'Entfernt die geplante Gesundheitspruefung wieder.' }
    )
    Show-NetMenu -Titel 'Backup, Wiederherstellen, Rueckgaengig' -Eintraege $eintraege -Kopf { Show-NetHealthTask; Write-Host ('  Backups: {0}' -f @(Get-NetBackupList).Count) }
}
# ----------------------------------------------------------------------
# src/erweitert/Erweitert.ps1
# ----------------------------------------------------------------------
# Erweiterte Funktionen: DNSSEC, Split-Brain-DNS, DHCP-Richtlinien, DNS-Sperrliste, DHCPv6.
# Alles ist standardmaessig aus: erst nach dem Freischalten (pro Sitzung) nutzbar, jede Aenderung
# braucht eine Bestaetigung, Richtlinien und DHCPv6-Scopes werden ausgeschaltet angelegt und
# muessen aktiv eingeschaltet werden. Fuer jede Funktion gibt es eine Ruecknahme.
#
$script:NetErweitertWarnung = @'
ACHTUNG: Die Funktionen unter "Erweitert" sind fuer Fachleute gedacht.
  - Sie werden selten gebraucht und koennen bei falscher Anwendung die Namensaufloesung oder die
    Adressvergabe im ganzen Netz stoeren.
  - Nichts davon ist eingeschaltet, solange es hier nicht ausdruecklich angelegt UND aktiviert wird.
  - Jede Aenderung zeigt Vorher/Nachher, wird gesichert und laesst sich zuruecknehmen.
'@
#
$script:NetHilfeDnssec = @'
DNSSEC signiert eine Zone digital. DNS-Server, die DNSSEC pruefen, erkennen gefaelschte Antworten.
Folgen:
  - Die Zone wird deutlich groesser (Signaturen), Schluessel muessen gepflegt werden.
  - Clients pruefen nur, wenn per Gruppenrichtlinie (NRPT) eingestellt - sonst bringt es intern wenig.
  - Fehler bei Schluesseln oder Uhrzeit machen die Zone fuer pruefende Resolver unaufloesbar.
  - Die Signatur laesst sich wieder entfernen (Unsign).
'@
#
$script:NetHilfeSplitBrain = @'
Split-Brain: Ein Name liefert intern eine andere Adresse als extern (z. B. mail.firma.ch intern
192.168.1.20, extern die oeffentliche Adresse). Umsetzung mit einem Client-Subnetz, einem
Zonen-Scope mit den internen Eintraegen und einer Abfrage-Richtlinie.
Wichtig: Zonen-Scopes funktionieren nur bei dateibasierten Zonen, nicht bei AD-integrierten.
'@
#
$script:NetHilfeDhcpRichtlinie = @'
DHCP-Richtlinien geben bestimmten Geraeten andere Optionen (oder Bereiche), z. B. alle Geraete mit
MAC-Praefix 00-15-5D (Hyper-V) oder einer bestimmten Herstellerklasse (VoIP-Telefone) bekommen
einen anderen DNS-Server oder Router. Die Richtlinie wird ausgeschaltet angelegt und erst nach
Bestaetigung aktiviert.
'@
#
$script:NetHilfeSperrliste = @'
DNS-Sperrliste: Anfragen fuer bestimmte Domaenen (z. B. bekannte Werbe- oder Schadseiten) werden
vom DNS-Server ignoriert. Umgesetzt mit Abfrage-Richtlinien (Aktion IGNORE) auf Serverebene.
Die globale Sperrliste von Windows (Standard: wpad, isatap) gilt nur fuer Namen in eigenen Zonen.
'@
#
$script:NetHilfeDhcpv6 = @'
DHCPv6 vergibt IPv6-Adressen. In den meisten Netzen nicht noetig: IPv6 konfiguriert sich ueber
Router-Ankuendigungen (SLAAC). DHCPv6 braucht man, wenn der Router "Managed" (M-Flag) ankuendigt
oder Adressen zentral vergeben werden sollen. Der Scope wird inaktiv angelegt.
'@
#
function Assert-NetAdvancedMode {
    <#
    .SYNOPSIS
        Erweiterte Funktionen erst nach ausdruecklichem Freischalten (pro Sitzung) nutzen.
    #>
    if ($script:NS.ErweitertFrei) { return $true }
    Write-NetText -Text $script:NetErweitertWarnung -Farbe Yellow
    if (Read-NetYesNo -Frage 'Erweiterte Funktionen fuer diese Sitzung freischalten?' -Vorschlag $false) {
        $script:NS.ErweitertFrei = $true
        Write-Log -Message 'Erweiterte Funktionen fuer diese Sitzung freigeschaltet.'
        return $true
    }
    return $false
}
#
function Set-NetAdvancedFlag {
    param([Parameter(Mandatory = $true)][string]$Name, [bool]$Wert)
    if ($script:NS.Config -and $script:NS.Config.Erweitert) {
        $script:NS.Config.Erweitert[$Name] = $Wert
        Save-NetConfig
    }
}
#
# ---------------------------------------------------------------- DNSSEC
#
function Invoke-NetDnssecSign {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text $script:NetHilfeDnssec
    $z = Select-NetDnsZone -Art Forward -Titel 'Welche Zone signieren?'
    if (-not $z) { return $false }
    $name = $z.Name
    $info = Get-NetSafe -Beschreibung "Zone $name" -Abfrage { Get-DnsServerZone -Name $name }
    if ($info -and $info.IsSigned) { Write-Log -Level OK -Message "Die Zone $name ist bereits signiert."; return $true }
    $r = Invoke-NetChange -Titel "Zone $name mit DNSSEC signieren" -Stufe Gefaehrlich -Vorher 'unsigniert' -Nachher 'signiert (Standardschluessel, automatische Schluesselpflege)' -BackupBereich @('Dns') `
        -Hinweis 'Pruefende Resolver lehnen die Zone ab, wenn Schluessel oder Uhrzeit nicht stimmen.' -Aktion {
        Invoke-DnsServerZoneSign -ZoneName $name -SignWithDefault -Force
    } -Rueckgaengig @{ Befehl = 'Invoke-DnsServerZoneUnsign'; Parameter = @{ ZoneName = $name; Force = $true } }
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Dnssec' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Invoke-NetDnssecUnsign {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    $signiert = @(Get-NetSafe -Beschreibung 'Zonen' -Standard @() -Abfrage { Get-DnsServerZone } | Where-Object { $_ -and $_.IsSigned } | ForEach-Object { [string]$_.ZoneName })
    if ($signiert.Count -eq 0) { Write-Log -Message 'Keine Zone ist signiert.'; return $true }
    $name = Select-NetItem -Elemente $signiert -Titel 'Signatur welcher Zone entfernen?'
    if (-not $name) { return $false }
    $r = Invoke-NetChange -Titel "DNSSEC-Signatur der Zone $name entfernen" -Stufe Gefaehrlich -Vorher 'signiert' -Nachher 'unsigniert' -BackupBereich @('Dns') -Aktion {
        Invoke-DnsServerZoneUnsign -ZoneName $name -Force
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
# ---------------------------------------------------------------- Split-Brain
#
function New-NetSplitBrain {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text $script:NetHilfeSplitBrain
    $z = Select-NetDnsZone -Art Forward -Titel 'Fuer welche Zone?'
    if (-not $z) { return $false }
    if ($z.AdIntegriert) {
        Write-Log -Level Fehler -Message ('Die Zone {0} ist AD-integriert. Zonen-Scopes gehen nur bei dateibasierten Zonen.' -f $z.Name)
        Write-Log -Message 'Naechster Schritt: fuer die externe Domaene eine eigene dateibasierte Zone verwenden.'
        return $false
    }
    $netz = Read-NetSubnet -Frage 'Internes Netz, das die internen Antworten bekommt (z. B. 192.168.0.0/16)'
    if (-not $netz) { return $false }
    $eintrag = Read-NetText -Frage 'Name des Eintrags (z. B. mail)' -Pruefung { param($t) Test-NetDnsRecordName -Name $t }
    if (-not $eintrag) { return $false }
    $ip = Read-NetIPAddress -Frage 'Interne IP-Adresse fuer diesen Namen'
    if (-not $ip) { return $false }
    $aktiv = Read-NetYesNo -Frage 'Richtlinie sofort aktivieren? (Nein = ausgeschaltet anlegen)' -Vorschlag $false
    $zone = $z.Name
    $subnetz = 'NetSetup-Intern'
    $scope = 'intern'
    $richtlinie = 'NetSetup-SplitBrain-' + ($zone -replace '[^A-Za-z0-9]', '-')
    $netzText = $netz.Text
    $r = Invoke-NetChange -Titel "Split-Brain fuer $eintrag.$zone einrichten" -Stufe Bestaetigen -Vorher ("{0}.{1}: eine Antwort fuer alle" -f $eintrag, $zone) `
        -Nachher @{ 'Client-Subnetz' = "$subnetz = $netzText"; 'Zonen-Scope' = $scope; 'Interner Eintrag' = "$eintrag -> $ip"; Richtlinie = $richtlinie; Aktiv = $(if ($aktiv) { 'ja' } else { 'nein (ausgeschaltet)' }) } -BackupBereich @('Dns') -Aktion {
        if (-not (Get-DnsServerClientSubnet -Name $subnetz -ErrorAction SilentlyContinue)) { Add-DnsServerClientSubnet -Name $subnetz -IPv4Subnet $netzText }
        if (-not (@(Get-DnsServerZoneScope -ZoneName $zone -ErrorAction SilentlyContinue) | Where-Object { $_.ZoneScope -eq $scope })) { Add-DnsServerZoneScope -ZoneName $zone -Name $scope }
        Add-DnsServerResourceRecordA -ZoneName $zone -ZoneScope $scope -Name $eintrag -IPv4Address $ip
        if ($aktiv) { Add-DnsServerQueryResolutionPolicy -Name $richtlinie -Action ALLOW -ClientSubnet ('eq,' + $subnetz) -ZoneScope ($scope + ',1') -ZoneName $zone }
        else { Add-DnsServerQueryResolutionPolicy -Name $richtlinie -Action ALLOW -ClientSubnet ('eq,' + $subnetz) -ZoneScope ($scope + ',1') -ZoneName $zone -Disable }
    } -Rueckgaengig @(
        @{ Befehl = 'Remove-DnsServerQueryResolutionPolicy'; Parameter = @{ Name = $richtlinie; ZoneName = $zone; Force = $true } },
        @{ Befehl = 'Remove-DnsServerZoneScope'; Parameter = @{ ZoneName = $zone; Name = $scope; Force = $true } }
    )
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'SplitBrain' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Remove-NetSplitBrain {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return }
    $liste = @()
    foreach ($z in @(Get-NetDnsZoneInfo -Art Forward)) {
        $zn = $z.Name
        foreach ($p in @(Get-NetSafe -Beschreibung 'Richtlinien' -Standard @() -Abfrage { Get-DnsServerQueryResolutionPolicy -ZoneName $zn })) {
            if ($p -and [string]$p.Name -like 'NetSetup-SplitBrain-*') { $liste += [pscustomobject]@{ Name = [string]$p.Name; Zone = $zn } }
        }
    }
    $w = Select-NetItem -Elemente $liste -Titel 'Welche Split-Brain-Richtlinie entfernen?' -Eigenschaften @('Name', 'Zone')
    if (-not $w) { return }
    $zone = $w.Zone
    $name = $w.Name
    Invoke-NetChange -Titel "Split-Brain $name entfernen" -Stufe Bestaetigen -Vorher 'aktiv bzw. angelegt' -Nachher 'Richtlinie und Zonen-Scope intern entfernt' -BackupBereich @('Dns') -Aktion {
        Remove-DnsServerQueryResolutionPolicy -Name $name -ZoneName $zone -Force
        Remove-DnsServerZoneScope -ZoneName $zone -Name 'intern' -Force
    } | Out-Null
}
#
# ---------------------------------------------------------------- DHCP-Richtlinien
#
function New-NetDhcpPolicy {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return $false }
    Write-NetText -Text $script:NetHilfeDhcpRichtlinie
    $s = Select-NetDhcpScope -Titel 'Fuer welchen Scope?'
    if (-not $s) { return $false }
    $art = Read-NetChoice -Frage 'Bedingung' -Optionen @('MAC-Praefix (z. B. 00-15-5D fuer Hyper-V)', 'Herstellerklasse (Vendor Class)', 'Benutzerklasse (User Class)') -Vorschlag 1
    if ($art -lt 0) { return $false }
    $bedingung = @{}
    $text = ''
    if ($art -eq 0) {
        $praefix = Read-NetText -Frage 'MAC-Praefix (6 Hex-Zeichen, z. B. 00-15-5D)' -Pruefung { param($t) if (($t -replace '[\s:.-]', '') -match '^[0-9A-Fa-f]{6}$') { $null } else { 'Bitte 6 Hex-Zeichen eingeben.' } }
        if (-not $praefix) { return $false }
        $roh = ($praefix -replace '[\s:.-]', '').ToUpper()
        $bedingung.MacAddress = @('EQ', ($roh + '*'))
        $text = 'MAC beginnt mit ' + $roh
    }
    else {
        $typ = 'Vendor'
        if ($art -eq 2) { $typ = 'User' }
        $klassen = @(Get-NetSafe -Beschreibung 'Klassen' -Standard @() -Abfrage { Get-DhcpServerv4Class -Type $typ } | Where-Object { $_ } | ForEach-Object { [string]$_.Name })
        $k = Select-NetItem -Elemente $klassen -Titel 'Welche Klasse?'
        if (-not $k) { return $false }
        if ($art -eq 1) { $bedingung.VendorClass = @('EQ', ($k + '*')) } else { $bedingung.UserClass = @('EQ', $k) }
        $text = "$typ-Klasse $k"
    }
    $optionNr = Read-NetChoice -Frage 'Welche Option soll fuer diese Geraete anders sein?' -Optionen @('003 Router', '006 DNS-Server', '015 DNS-Domaene', '042 NTP-Server') -Vorschlag 2
    if ($optionNr -lt 0) { return $false }
    $optionId = @(3, 6, 15, 42)[$optionNr]
    $wertText = Read-NetText -Frage ('Wert(e) fuer Option {0:000} (mehrere mit Komma)' -f $optionId)
    if (-not $wertText) { return $false }
    $werte = @($wertText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $name = Read-NetText -Frage 'Name der Richtlinie' -Vorschlag ('NetSetup-' + ($text -replace '[^A-Za-z0-9]', ''))
    if (-not $name) { return $false }
    $id = $s.ScopeId
    $aktiv = Read-NetYesNo -Frage 'Richtlinie sofort aktivieren? (Nein = ausgeschaltet anlegen)' -Vorschlag $false
    $p = @{ Name = $name; ScopeId = $id; Condition = 'OR'; Enabled = $false; Description = 'Angelegt von NetSetup' }
    foreach ($k in $bedingung.Keys) { $p[$k] = $bedingung[$k] }
    $r = Invoke-NetChange -Titel "DHCP-Richtlinie $name anlegen" -Stufe Bestaetigen -Vorher '(keine Richtlinie)' -Nachher @{ Scope = $id; Bedingung = $text; Option = ('{0:000} = {1}' -f $optionId, ($werte -join ', ')); Aktiv = $(if ($aktiv) { 'ja' } else { 'nein (ausgeschaltet)' }) } -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Policy @p
        Set-DhcpServerv4OptionValue -ScopeId $id -PolicyName $name -OptionId $optionId -Value $werte -Force
        if ($aktiv) { Set-DhcpServerv4Policy -Name $name -ScopeId $id -Enabled $true }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Policy'; Parameter = @{ Name = $name; ScopeId = $id } }
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Richtlinien' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Get-NetDhcpPolicyList {
    $liste = @()
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $id = $s.ScopeId
        foreach ($p in @(Get-NetSafe -Beschreibung 'Richtlinien' -Standard @() -Abfrage { Get-DhcpServerv4Policy -ScopeId $id })) {
            if ($p) { $liste += [pscustomobject]@{ Name = [string]$p.Name; ScopeId = $id; Aktiv = [bool]$p.Enabled } }
        }
    }
    return $liste
}
#
function Switch-NetDhcpPolicy {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpPolicyList) -Titel 'Welche Richtlinie ein-/ausschalten?' -Eigenschaften @('Name', 'ScopeId', 'Aktiv')
    if (-not $w) { return }
    $name = $w.Name
    $id = $w.ScopeId
    $neu = -not $w.Aktiv
    Invoke-NetChange -Titel ("DHCP-Richtlinie {0} {1}" -f $name, $(if ($neu) { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen -Vorher $(if ($w.Aktiv) { 'aktiv' } else { 'aus' }) -Nachher $(if ($neu) { 'aktiv' } else { 'aus' }) -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4Policy -Name $name -ScopeId $id -Enabled $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4Policy'; Parameter = @{ Name = $name; ScopeId = $id; Enabled = $w.Aktiv } } | Out-Null
}
#
function Remove-NetDhcpPolicy {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpPolicyList) -Titel 'Welche Richtlinie entfernen?' -Eigenschaften @('Name', 'ScopeId', 'Aktiv')
    if (-not $w) { return }
    $name = $w.Name
    $id = $w.ScopeId
    Invoke-NetChange -Titel "DHCP-Richtlinie $name entfernen" -Stufe Bestaetigen -Vorher $name -Nachher '(entfernt)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4Policy -Name $name -ScopeId $id
    } | Out-Null
}
#
# ---------------------------------------------------------------- DNS-Sperrliste
#
function Get-NetDnsBlockList {
    return @(Get-NetSafe -Beschreibung 'Sperrliste' -Standard @() -Abfrage { Get-DnsServerQueryResolutionPolicy } | Where-Object { $_ -and [string]$_.Name -like 'NetSetup-Sperre-*' } | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Domaene = ([string]$_.Name).Substring(16); Aktiv = ([string]$_.IsEnabled -ne 'False') }
        })
}
#
function Add-NetDnsBlock {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return $false }
    Write-NetText -Text $script:NetHilfeSperrliste
    $text = Read-NetText -Frage 'Domaenen sperren (mit Komma, z. B. werbung.example)' -Pruefung {
        param($t)
        foreach ($d in $t.Split(',')) { $f = (Test-NetDomainName -Name $d.Trim()).Fehler; if ($f) { return $f } }
        return $null
    }
    if (-not $text) { return $false }
    $vorhanden = @(Get-NetDnsBlockList | ForEach-Object { $_.Domaene })
    $neu = @($text.Split(',') | ForEach-Object { $_.Trim().ToLower().TrimEnd('.') } | Where-Object { $_ -and $vorhanden -notcontains $_ } | Select-Object -Unique)
    if ($neu.Count -eq 0) { Write-Log -Level OK -Message 'Alle Domaenen sind bereits gesperrt.'; return $true }
    $aktiv = Read-NetYesNo -Frage 'Sperre sofort aktivieren? (Nein = ausgeschaltet anlegen)' -Vorschlag $false
    $rueck = @($neu | ForEach-Object { @{ Befehl = 'Remove-DnsServerQueryResolutionPolicy'; Parameter = @{ Name = ('NetSetup-Sperre-' + $_); Force = $true } } })
    $r = Invoke-NetChange -Titel ('{0} Domaene(n) im DNS sperren' -f $neu.Count) -Stufe Bestaetigen -Vorher ($(if ($vorhanden.Count) { $vorhanden -join ', ' } else { '(keine Sperren)' })) -Nachher (@($neu | ForEach-Object { $_ + $(if ($aktiv) { ' (aktiv)' } else { ' (aus)' }) })) -BackupBereich @('Dns') -Aktion {
        foreach ($d in $neu) {
            $fqdn = 'EQ,*.' + $d + ',' + $d
            if ($aktiv) { Add-DnsServerQueryResolutionPolicy -Name ('NetSetup-Sperre-' + $d) -Action IGNORE -Fqdn $fqdn }
            else { Add-DnsServerQueryResolutionPolicy -Name ('NetSetup-Sperre-' + $d) -Action IGNORE -Fqdn $fqdn -Disable }
        }
    } -Rueckgaengig $rueck
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Sperrliste' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Switch-NetDnsBlock {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDnsBlockList) -Titel 'Welche Sperre ein-/ausschalten?' -Eigenschaften @('Domaene', 'Aktiv')
    if (-not $w) { return }
    $name = $w.Name
    $neu = 'Enable'
    $alt = 'Disable'
    if ($w.Aktiv) { $neu = 'Disable'; $alt = 'Enable' }
    Invoke-NetChange -Titel ("Sperre {0} {1}" -f $w.Domaene, $(if ($neu -eq 'Enable') { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen -Vorher $alt -Nachher $neu -BackupBereich @('Dns') -Aktion {
        Set-DnsServerQueryResolutionPolicy -Name $name -State $neu
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerQueryResolutionPolicy'; Parameter = @{ Name = $name; State = $alt } } | Out-Null
}
#
function Remove-NetDnsBlock {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDnsReady)) { return }
    $wahl = @(Select-NetItem -Elemente @(Get-NetDnsBlockList) -Titel 'Welche Sperren aufheben?' -Eigenschaften @('Domaene', 'Aktiv') -Mehrfach)
    if ($wahl.Count -eq 0) { return }
    $namen = @($wahl | ForEach-Object { $_.Name })
    Invoke-NetChange -Titel ('{0} Sperre(n) aufheben' -f $namen.Count) -Stufe Bestaetigen -Vorher ($namen -join ', ') -Nachher '(aufgehoben)' -BackupBereich @('Dns') -Aktion {
        foreach ($n in $namen) { Remove-DnsServerQueryResolutionPolicy -Name $n -Force }
    } | Out-Null
}
#
function Show-NetDnsBlock {
    if (-not (Test-NetDnsReady)) { return }
    Write-NetTitle -Titel 'DNS-Sperrliste'
    $liste = @(Get-NetDnsBlockList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Keine Sperren von NetSetup.' }
    foreach ($b in $liste) { Write-NetStatus -Status $(if ($b.Aktiv) { 'OK' } else { 'NA' }) -Bereich $b.Domaene -Text $(if ($b.Aktiv) { 'gesperrt' } else { 'angelegt, ausgeschaltet' }) }
    $global = Get-NetSafe -Beschreibung 'Globale Sperrliste' -Abfrage { Get-DnsServerGlobalQueryBlockList }
    if ($global) { Write-Host ('  Globale Sperrliste von Windows ({0}): {1}' -f $(if ($global.Enable) { 'an' } else { 'aus' }), (@($global.List) -join ', ')) -ForegroundColor DarkGray }
}
#
# ---------------------------------------------------------------- DHCPv6
#
function New-NetDhcpv6Scope {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return $false }
    Write-NetText -Text $script:NetHilfeDhcpv6
    $praefix = Read-NetText -Frage 'IPv6-Praefix (/64), z. B. fd00:1234:5678:1::' -Pruefung {
        param($t)
        $x = $t -replace '/64$', ''
        if (-not (Test-NetIPv6Address -Text $x)) { return 'Bitte ein IPv6-Praefix wie fd00:1234:5678:1:: eingeben.' }
        return $null
    }
    if (-not $praefix) { return $false }
    $praefix = $praefix -replace '/64$', ''
    $vorhanden = @(Get-NetSafe -Beschreibung 'DHCPv6' -Standard @() -Abfrage { Get-DhcpServerv6Scope } | Where-Object { $_ -and (ConvertTo-NetString $_.Prefix) -eq $praefix })
    if ($vorhanden.Count -gt 0) { Write-Log -Level OK -Message "Den DHCPv6-Scope $praefix gibt es bereits."; return $true }
    $name = Read-NetText -Frage 'Name' -Vorschlag 'IPv6 LAN'
    if (-not $name) { return $false }
    $r = Invoke-NetChange -Titel "DHCPv6-Scope $praefix anlegen (inaktiv)" -Stufe Bestaetigen -Vorher '(kein DHCPv6-Scope)' -Nachher @{ Praefix = "$praefix/64"; Name = $name; Status = 'inaktiv - muss aktiv eingeschaltet werden' } -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv6Scope -Prefix $praefix -Name $name -State InActive
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv6Scope'; Parameter = @{ Prefix = $praefix; Force = $true } }
    if ($r.Erfolg -and -not $r.Probelauf) { Set-NetAdvancedFlag -Name 'Dhcpv6' -Wert $true }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
#
function Get-NetDhcpv6ScopeList {
    return @(Get-NetSafe -Beschreibung 'DHCPv6' -Standard @() -Abfrage { Get-DhcpServerv6Scope } | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Praefix = (ConvertTo-NetString $_.Prefix); Name = [string]$_.Name; Status = [string]$_.State }
        })
}
#
function Switch-NetDhcpv6Scope {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpv6ScopeList) -Titel 'Welchen DHCPv6-Scope ein-/ausschalten?' -Eigenschaften @('Praefix', 'Name', 'Status')
    if (-not $w) { return }
    $praefix = $w.Praefix
    $alt = $w.Status
    $neu = 'Active'
    if ($alt -eq 'Active') { $neu = 'InActive' }
    Invoke-NetChange -Titel "DHCPv6-Scope $praefix $(if ($neu -eq 'Active') { 'aktivieren' } else { 'deaktivieren' })" -Stufe Bestaetigen -Vorher $alt -Nachher $neu -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv6Scope -Prefix $praefix -State $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv6Scope'; Parameter = @{ Prefix = $praefix; State = $alt } } | Out-Null
}
#
function Remove-NetDhcpv6Scope {
    if (-not (Assert-NetAdvancedMode) -or -not (Test-NetDhcpReady)) { return }
    $w = Select-NetItem -Elemente @(Get-NetDhcpv6ScopeList) -Titel 'Welchen DHCPv6-Scope loeschen?' -Eigenschaften @('Praefix', 'Name', 'Status')
    if (-not $w) { return }
    $praefix = $w.Praefix
    Invoke-NetChange -Titel "DHCPv6-Scope $praefix loeschen" -Stufe Gefaehrlich -Vorher ('{0} ({1})' -f $praefix, $w.Status) -Nachher '(geloescht)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv6Scope -Prefix $praefix -Force
    } | Out-Null
}
#
function Show-NetDhcpv6Scope {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCPv6-Scopes'
    $liste = @(Get-NetDhcpv6ScopeList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Keine DHCPv6-Scopes (Standard).' }
    foreach ($s in $liste) { Write-Host ('  {0,-28} {1,-20} {2}' -f ($s.Praefix + '/64'), $s.Name, $s.Status) }
}
#
# ---------------------------------------------------------------- Menue
#
function Show-NetAdvancedMenu {
    $eintraege = @(
        @{ Text = 'DNSSEC: Zone signieren'; Aktion = { Invoke-NetDnssecSign | Out-Null }; Hilfe = $script:NetHilfeDnssec },
        @{ Text = 'DNSSEC: Signatur entfernen'; Aktion = { Invoke-NetDnssecUnsign | Out-Null }; Hilfe = 'Entfernt die DNSSEC-Signatur einer Zone wieder (gefaehrlich, mit Backup).' },
        @{ Text = 'Split-Brain einrichten'; Aktion = { New-NetSplitBrain | Out-Null }; Hilfe = $script:NetHilfeSplitBrain },
        @{ Text = 'Split-Brain entfernen'; Aktion = 'Remove-NetSplitBrain'; Hilfe = 'Entfernt Richtlinie und Zonen-Scope "intern" wieder.' },
        @{ Text = 'DHCP-Richtlinie anlegen'; Aktion = { New-NetDhcpPolicy | Out-Null }; Hilfe = $script:NetHilfeDhcpRichtlinie },
        @{ Text = 'DHCP-Richtlinie ein-/ausschalten'; Aktion = 'Switch-NetDhcpPolicy'; Hilfe = 'Schaltet eine Richtlinie ein oder aus (rueckgaengig moeglich).' },
        @{ Text = 'DHCP-Richtlinie entfernen'; Aktion = 'Remove-NetDhcpPolicy'; Hilfe = 'Entfernt eine DHCP-Richtlinie.' },
        @{ Text = 'DNS-Sperrliste anzeigen'; Aktion = 'Show-NetDnsBlock'; Hilfe = 'Zeigt die von NetSetup angelegten Sperren und die globale Sperrliste von Windows.' },
        @{ Text = 'Domaenen sperren'; Aktion = { Add-NetDnsBlock | Out-Null }; Hilfe = $script:NetHilfeSperrliste },
        @{ Text = 'Sperre ein-/ausschalten'; Aktion = 'Switch-NetDnsBlock'; Hilfe = 'Schaltet eine Sperre ein oder aus.' },
        @{ Text = 'Sperren aufheben'; Aktion = 'Remove-NetDnsBlock'; Hilfe = 'Entfernt Sperren wieder.' },
        @{ Text = 'DHCPv6-Scopes anzeigen'; Aktion = 'Show-NetDhcpv6Scope'; Hilfe = 'Listet die DHCPv6-Scopes.' },
        @{ Text = 'DHCPv6-Scope anlegen (inaktiv)'; Aktion = { New-NetDhcpv6Scope | Out-Null }; Hilfe = $script:NetHilfeDhcpv6 },
        @{ Text = 'DHCPv6-Scope aktivieren/deaktivieren'; Aktion = 'Switch-NetDhcpv6Scope'; Hilfe = 'Erst hier wird ein DHCPv6-Scope wirksam.' },
        @{ Text = 'DHCPv6-Scope loeschen'; Aktion = 'Remove-NetDhcpv6Scope'; Hilfe = 'Loescht einen DHCPv6-Scope (gefaehrlich, mit Backup).' }
    )
    Show-NetMenu -Titel 'Erweitert (Fachleute)' -Eintraege $eintraege -Einleitung $script:NetErweitertWarnung -Kopf {
        Write-Host ('  Freigeschaltet: {0}' -f $(if ($script:NS.ErweitertFrei) { 'ja (diese Sitzung)' } else { 'nein - beim ersten Punkt wird gefragt' })) -ForegroundColor Yellow
    }
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
