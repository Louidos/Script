# Konfiguration als JSON mit Schema-Version unter <Datenordner>\Config\netsetup.json.
# Passwoerter stehen nie in der Konfiguration.

$script:NetConfigSchemaVersion = 1

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
