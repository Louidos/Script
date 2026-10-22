BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')

    # Mocks fuer alle lesenden Abfragen; das Szenario steht in $script:Szenario.
    function Add-TestServerMock {
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } {
            switch ($script:Szenario) {
                'Frisch' { [pscustomobject]@{ Name = 'SRV01'; DomainRole = 2; PartOfDomain = $false; Domain = 'WORKGROUP' } }
                default { [pscustomobject]@{ Name = 'DC01'; DomainRole = 5; PartOfDomain = $true; Domain = 'ad.firma.ch' } }
            }
        }
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } {
            [pscustomobject]@{ Caption = 'Microsoft Windows Server 2022 Standard'; Version = '10.0.20348'; BuildNumber = '20348'; ProductType = 3; OSLanguage = 1031 }
        }
        Mock Get-ItemProperty {
            if ($Path -like '*Roles\12') { if ($script:Szenario -eq 'DcDhcp') { return [pscustomobject]@{ ConfigurationState = 2 } } else { throw 'fehlt' } }
            if ($Path -like '*W32Time\Parameters') { return [pscustomobject]@{ Type = 'NTP'; NtpServer = 'ch.pool.ntp.org,0x8' } }
            if ($Path -like '*CurrentVersion') { return [pscustomobject]@{ InstallationType = 'Server'; EditionID = 'ServerStandard' } }
            if ($Path -like '*ComputerName*') { return [pscustomobject]@{ ComputerName = 'DC01' } }
            throw 'nicht vorhanden'
        }
        Mock Test-Path -ParameterFilter { $Path -like 'HKLM:*' } { $false }
        Mock Get-WindowsFeature {
            foreach ($n in $Name) {
                $st = 'Available'
                if ($script:Szenario -ne 'Frisch' -and $n -ne 'DHCP' -and $n -ne 'RSAT-DHCP') { $st = 'Installed' }
                if ($script:Szenario -eq 'DcDhcp') { $st = 'Installed' }
                [pscustomobject]@{ Name = $n; InstallState = $st }
            }
        }
        Mock Get-Service {
            $vorhanden = @('W32Time', 'Netlogon')
            if ($script:Szenario -ne 'Frisch') { $vorhanden += @('NTDS', 'DNS') }
            if ($script:Szenario -eq 'DcDhcp') { $vorhanden += 'DHCPServer' }
            if ($vorhanden -notcontains $Name) { throw 'Dienst fehlt' }
            [pscustomobject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Get-NetAdapter { [pscustomobject]@{ ifIndex = 4; Name = 'Ethernet'; InterfaceDescription = 'Intel'; MacAddress = '00-15-5D-01-02-03'; Status = 'Up' } }
        Mock Get-NetIPInterface { [pscustomobject]@{ Dhcp = $(if ($script:Szenario -eq 'Frisch') { 'Enabled' } else { 'Disabled' }) } }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.168.1.10'; PrefixLength = 24; PrefixOrigin = 'Manual' } }
        Mock Get-NetRoute { [pscustomobject]@{ NextHop = '192.168.1.1' } }
        Mock Get-DnsClientServerAddress { [pscustomobject]@{ ServerAddresses = @('127.0.0.1') } }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'ad.firma.ch'; NetBIOSName = 'FIRMA'; DomainMode = 'Windows2016Domain'; PDCEmulator = 'DC01.ad.firma.ch' } }
        Mock Get-ADForest { [pscustomobject]@{ Name = 'ad.firma.ch'; ForestMode = 'Windows2016Forest' } }
        Mock Get-DnsServerZone {
            [pscustomobject]@{ ZoneName = 'ad.firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false }
            [pscustomobject]@{ ZoneName = '1.168.192.in-addr.arpa'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $true; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false }
            [pscustomobject]@{ ZoneName = '0.in-addr.arpa'; ZoneType = 'Primary'; IsDsIntegrated = $false; IsReverseLookupZone = $true; DynamicUpdate = 'None'; ReplicationScope = 'None'; IsAutoCreated = $true }
            [pscustomobject]@{ ZoneName = 'TrustAnchors'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'None'; ReplicationScope = 'Forest'; IsAutoCreated = $false }
        }
        Mock Get-DnsServerZoneAging { [pscustomobject]@{ AgingEnabled = $true; NoRefreshInterval = [timespan]::FromDays(7); RefreshInterval = [timespan]::FromDays(7) } }
        Mock Get-DnsServerForwarder { [pscustomobject]@{ IPAddress = @([System.Net.IPAddress]::Parse('9.9.9.9')) } }
        Mock Get-DnsServerScavenging { [pscustomobject]@{ ScavengingState = $true; ScavengingInterval = [timespan]::FromDays(7); NoRefreshInterval = [timespan]::FromDays(7); RefreshInterval = [timespan]::FromDays(7) } }
        Mock Get-DnsServerSetting { [pscustomobject]@{ ListeningIPAddress = @() } }
        Mock Get-DhcpServerSetting { [pscustomobject]@{ IsAuthorized = $true; IsDomainJoined = $true; ConflictDetectionAttempts = 1 } }
        Mock Get-DhcpServerv4Binding { [pscustomobject]@{ InterfaceAlias = 'Ethernet'; IPAddress = [System.Net.IPAddress]::Parse('192.168.1.10'); BindingState = $true } }
        Mock Get-DhcpServerv4Scope {
            [pscustomobject]@{ ScopeId = [System.Net.IPAddress]::Parse('192.168.1.0'); Name = 'LAN'; StartRange = [System.Net.IPAddress]::Parse('192.168.1.100'); EndRange = [System.Net.IPAddress]::Parse('192.168.1.199'); SubnetMask = [System.Net.IPAddress]::Parse('255.255.255.0'); State = 'Active'; LeaseDuration = [timespan]::FromDays(8); SuperscopeName = '' }
        }
        Mock Get-DhcpServerv4OptionValue {
            if ($ScopeId) {
                [pscustomobject]@{ OptionId = 3; Value = @('192.168.1.1') }
                [pscustomobject]@{ OptionId = 6; Value = @('192.168.1.10') }
                [pscustomobject]@{ OptionId = 15; Value = @('ad.firma.ch') }
            }
        }
        Mock Get-DhcpServerv4ExclusionRange { }
        Mock Get-DhcpServerv4Reservation { [pscustomobject]@{ IPAddress = [System.Net.IPAddress]::Parse('192.168.1.150'); ClientId = 'aa-bb-cc-dd-ee-ff'; Name = 'drucker'; Description = '' } }
        Mock Get-DhcpServerv4ScopeStatistics { [pscustomobject]@{ PercentageInUse = 35; Free = 58; InUse = 32 } }
        Mock Get-DhcpServerv4DnsSetting { [pscustomobject]@{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = $false; DisableDnsPtrRRUpdate = $false } }
        Mock Get-DhcpServerv4Failover { }
        Mock Get-DhcpServerDnsCredential { [pscustomobject]@{ UserName = 'svc-dhcpdns'; DomainName = 'FIRMA' } }
    }
}

Describe 'Bestandsaufnahme ist nur lesend' {
    It 'Bestandsaufnahme.ps1 ruft keine aendernden Cmdlets auf (statische Pruefung)' {
        $datei = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/inventar/Bestandsaufnahme.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($datei, [ref]$null, [ref]$null)
        $befehle = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
        $verboten = $befehle | Where-Object { $_ -match '^(Set|Add|Remove|Install|Uninstall|New|Enable|Disable|Restart|Start|Stop|Rename|Register|Unregister|Restore|Import|Clear|Reset|Update|Invoke|Backup|Export|Move|Copy|Grant|Revoke|Suspend|Resume)-' }
        $verboten | Should -BeNullOrEmpty
    }
    It 'ruft zur Laufzeit keine Set-/Add-/Remove-/Install-Cmdlets auf' {
        $script:Szenario = 'DcDhcp'
        Add-TestServerMock
        $aendernd = @($stubDefinitionen.Keys | Where-Object { $_ -match '^(Set|Add|Remove|Install|Uninstall|New|Enable|Disable|Restart|Start|Stop|Rename|Register|Unregister|Restore|Import|Invoke|Backup|Export)-' } | ForEach-Object { Get-Command -Name $_ })
        foreach ($c in $aendernd) { Mock $c.Name { throw 'aendernder Aufruf' } }
        $z = Get-NetSetupState
        $z.System.IstDC | Should -BeTrue
        foreach ($c in $aendernd) { Should -Invoke $c.Name -Times 0 -Exactly }
    }
}

Describe 'Bestandsaufnahme erkennt die Ausgangslage' {
    BeforeEach { $script:NS.Config = Get-NetDefaultConfig }
    It 'frischer Server in der Arbeitsgruppe' {
        $script:Szenario = 'Frisch'
        Add-TestServerMock
        $z = Get-NetSetupState
        $z.System.IstArbeitsgruppe | Should -BeTrue
        $z.Features['DNS'] | Should -Be 'Available'
        $z.Dns.Verfuegbar | Should -BeFalse
        $z.Dhcp.Verfuegbar | Should -BeFalse
        $z.Netzwerk.Karten[0].Dhcp | Should -BeTrue
        $s = Get-NetStateSummary -Zustand $z
        ($s | Where-Object Bereich -eq 'DNS').Status | Should -Be 'NA'
        ($s | Where-Object Bereich -eq 'DHCP').Status | Should -Be 'NA'
        ($s | Where-Object Bereich -eq 'Active Directory').Status | Should -Be 'NA'
        ($s | Where-Object Bereich -eq 'Netzwerk').Status | Should -Be 'WARN'
    }
    It 'DC nur mit DNS' {
        $script:Szenario = 'DcDns'
        Add-TestServerMock
        $z = Get-NetSetupState
        $z.System.IstDC | Should -BeTrue
        $z.AD.Domaene | Should -Be 'ad.firma.ch'
        @($z.Dns.Zonen).Count | Should -Be 2
        $z.Dns.Weiterleitungen | Should -Be '9.9.9.9'
        $s = Get-NetStateSummary -Zustand $z
        ($s | Where-Object Bereich -eq 'Active Directory').Status | Should -Be 'OK'
        ($s | Where-Object Bereich -eq 'DNS').Status | Should -Be 'OK'
        ($s | Where-Object Bereich -eq 'DHCP').Status | Should -Be 'NA'
    }
    It 'DC mit fertigem DHCP' {
        $script:Szenario = 'DcDhcp'
        Add-TestServerMock
        $z = Get-NetSetupState
        $z.Dhcp.Verfuegbar | Should -BeTrue
        $z.Dhcp.Nachkonfiguriert | Should -BeTrue
        $z.Dhcp.Scopes[0].ScopeId | Should -Be '192.168.1.0'
        $z.Dhcp.Scopes[0].Prefix | Should -Be 24
        $z.Dhcp.Scopes[0].Optionen['6'] | Should -Be '192.168.1.10'
        $z.Dhcp.Scopes[0].LeaseTage | Should -Be 8
        $s = Get-NetStateSummary -Zustand $z
        ($s | Where-Object Bereich -eq 'DHCP').Status | Should -Be 'OK'
        ($s | Where-Object Bereich -eq 'DHCP + DNS').Status | Should -Be 'OK'
    }
    It 'fehlende Rollen und Module fuehren zu "nicht installiert" statt Absturz' {
        $script:Szenario = 'Frisch'
        Add-TestServerMock
        Mock Test-NetCommand { $false }
        Mock Get-CimInstance -ParameterFilter { $true } { throw 'WMI kaputt' }
        { Get-NetSetupState } | Should -Not -Throw
        $z = Get-NetSetupState
        $z.Features['DHCP'] | Should -Be 'Unbekannt'
        $z.System.RolleText | Should -Be 'Unbekannt'
        { Get-NetStateSummary -Zustand $z } | Should -Not -Throw
    }
}

Describe 'Statusuebersicht aus Testzustaenden' {
    BeforeEach { $script:NS.Config = Get-NetDefaultConfig }
    It 'meldet DHCP auf DC ohne DNS-Zugangsdaten' {
        $z = New-TestZustand -Szenario DcDhcp
        $z.Dhcp.DnsZugangsdaten.Gesetzt = $false
        $s = Get-NetStateSummary -Zustand $z
        ($s | Where-Object Bereich -eq 'DHCP + DNS').Text | Should -Match 'ohne DNS-Zugangsdaten'
    }
    It 'meldet nicht autorisierten DHCP als Fehler' {
        $z = New-TestZustand -Szenario DcDhcp
        $z.Dhcp.Autorisiert = $false
        ((Get-NetStateSummary -Zustand $z) | Where-Object Bereich -eq 'DHCP').Status | Should -Be 'FEHLER'
    }
    It 'meldet gestoppten DNS-Dienst als Fehler' {
        $z = New-TestZustand -Szenario DcDns
        $z.Dns.Laeuft = $false
        ((Get-NetStateSummary -Zustand $z) | Where-Object Bereich -eq 'DNS').Status | Should -Be 'FEHLER'
    }
    It 'meldet einen DC, der nicht sich selbst als DNS fragt' {
        $z = New-TestZustand -Szenario DcDns
        $z.Netzwerk.AktiveKarten[0].DnsServer = @('8.8.8.8')
        ((Get-NetStateSummary -Zustand $z) | Where-Object Bereich -eq 'Netzwerk').Text | Should -Match 'nicht sich selbst'
    }
}

Describe 'Vorhandene Konfiguration uebernehmen' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
    }
    It 'schreibt DNS und DHCP in die Config, ohne den Server zu aendern' {
        $script:testZustand = New-TestZustand -Szenario DcDhcp
        Mock Get-NetSetupState { $script:testZustand }
        Mock Read-NetInput { 'j' }
        Mock Add-DhcpServerv4Scope { throw 'darf nicht' }
        Import-NetExistingConfig
        $c = Import-NetConfig
        @($c.Dhcp.Scopes).Count | Should -Be 1
        $c.Dhcp.Scopes[0].ScopeId | Should -Be '192.168.1.0'
        $c.Dns.Weiterleitungen | Should -Contain '9.9.9.9'
        $c.AD.Domaene | Should -Be 'ad.firma.ch'
        Should -Invoke Add-DhcpServerv4Scope -Times 0 -Exactly
    }
}

Describe 'Ersteinrichtungs-Assistent' {
    BeforeEach { $script:NS.Config = Get-NetDefaultConfig }
    It 'frischer Server: alle Schritte offen' {
        $schritte = Get-NetFirstSetupStep -Zustand (New-TestZustand -Szenario Frisch)
        @($schritte | Where-Object Erledigt).Count | Should -Be 0
    }
    It 'DC nur mit DNS: AD und DNS erledigt, DHCP offen' {
        $schritte = Get-NetFirstSetupStep -Zustand (New-TestZustand -Szenario DcDns)
        ($schritte | Where-Object Nr -eq 1).Erledigt | Should -BeTrue
        ($schritte | Where-Object Nr -eq 2).Erledigt | Should -BeTrue
        ($schritte | Where-Object Nr -eq 3).Erledigt | Should -BeFalse
    }
    It 'DC mit fertigem DHCP: nur noch der Test offen' {
        $schritte = Get-NetFirstSetupStep -Zustand (New-TestZustand -Szenario DcDhcp)
        @($schritte | Where-Object { -not $_.Erledigt } | ForEach-Object Nr) | Should -Be @(5)
    }
    It 'bewusst ohne AD gilt der AD-Schritt als erledigt' {
        $script:NS.Config.AD.Modus = 'OhneAD'
        (Get-NetFirstSetupStep -Zustand (New-TestZustand -Szenario Frisch) | Where-Object Nr -eq 1).Erledigt | Should -BeTrue
    }
    It 'ueberspringt fehlende Bereiche ohne Absturz und ruft vorhandene auf' {
        $script:testZustand = New-TestZustand -Szenario Frisch
        Mock Get-NetSetupState { $script:testZustand }
        Mock Test-NetCommand { $Name -eq 'Start-NetDnsSetup' }
        function Start-NetDnsSetup { $script:dnsAufgerufen = $true; $script:testZustand = New-TestZustand -Szenario DcDns }
        Mock Read-NetInput { 'j' }
        $script:dnsAufgerufen = $false
        { Start-NetFirstSetup } | Should -Not -Throw
        $script:dnsAufgerufen | Should -BeTrue
    }
}
