# Bestandsaufnahme: erfasst den kompletten Zustand des Servers.
# NUR LESEND: hier werden ausschliesslich Get-*-Cmdlets, Test-Path und Get-ItemProperty verwendet.
# Fehlende Module oder Rollen fuehren zu "nicht installiert" bzw. "Unbekannt", nie zum Absturz.

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

function Get-NetTimeState {
    $param = Get-NetSafe -Beschreibung 'W32Time Parameter' -Abfrage { Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' }
    $typ = ''
    $ntp = ''
    if ($param) { $typ = [string]$param.Type; $ntp = [string]$param.NtpServer }
    return @{ Typ = $typ; NtpServer = $ntp }
}

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
