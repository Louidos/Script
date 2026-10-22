BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')
    function New-TestScope {
        param([string]$Id = '192.168.1.0', [string]$Start = '192.168.1.100', [string]$Ende = '192.168.1.199')
        [pscustomobject]@{ ScopeId = [System.Net.IPAddress]::Parse($Id); Name = 'LAN'; StartRange = [System.Net.IPAddress]::Parse($Start); EndRange = [System.Net.IPAddress]::Parse($Ende); SubnetMask = [System.Net.IPAddress]::Parse('255.255.255.0'); State = 'Active'; LeaseDuration = [timespan]::FromDays(8); SuperscopeName = '' }
    }
}

Describe 'Rolle, Nachkonfiguration und Autorisierung' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Add-DhcpServerSecurityGroup { }
        Mock Set-ItemProperty -ParameterFilter { $Path -like '*Roles\12' } { }
        Mock Test-Path -ParameterFilter { $Path -like '*Roles\12' } { $true }
        Mock Restart-Service { }
        Mock Add-DhcpServerInDC { }
        Mock Read-NetInput { 'j' }
    }
    It 'fuehrt die Nachkonfiguration aus, wenn ConfigurationState nicht 2 ist' {
        Mock Get-ItemProperty -ParameterFilter { $Path -like '*Roles\12' } { [pscustomobject]@{ ConfigurationState = 1 } }
        Complete-NetDhcpPostInstall | Should -BeTrue
        Should -Invoke Add-DhcpServerSecurityGroup -Times 1 -Exactly
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'ConfigurationState' -and $Value -eq 2 }
        Should -Invoke Restart-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'DHCPServer' }
    }
    It 'macht nichts, wenn die Nachkonfiguration schon erledigt ist' {
        Mock Get-ItemProperty -ParameterFilter { $Path -like '*Roles\12' } { [pscustomobject]@{ ConfigurationState = 2 } }
        Complete-NetDhcpPostInstall | Should -BeTrue
        Should -Invoke Add-DhcpServerSecurityGroup -Times 0 -Exactly
    }
    It 'ueberspringt die Autorisierung ohne Domaene' {
        Mock Get-DhcpServerSetting { [pscustomobject]@{ IsDomainJoined = $false; IsAuthorized = $false } }
        Add-NetDhcpAuthorization | Should -BeTrue
        Should -Invoke Add-DhcpServerInDC -Times 0 -Exactly
    }
    It 'erklaert fehlende Rechte und bricht auf Wunsch ab' {
        Mock Get-DhcpServerSetting { [pscustomobject]@{ IsDomainJoined = $true; IsAuthorized = $false } }
        Mock Test-NetEnterpriseAdmin { $false }
        Mock Read-NetInput { 'n' }
        Add-NetDhcpAuthorization | Should -BeFalse
        Should -Invoke Add-DhcpServerInDC -Times 0 -Exactly
    }
    It 'autorisiert mit Organisations-Admin-Rechten' {
        $script:z = New-TestZustand -Szenario DcDns
        $script:NS.Zustand = $script:z
        Mock Get-NetSetupState { $script:z }
        Mock Get-DhcpServerSetting { [pscustomobject]@{ IsDomainJoined = $true; IsAuthorized = $false } }
        Mock Test-NetEnterpriseAdmin { $true }
        Add-NetDhcpAuthorization | Should -BeTrue
        Should -Invoke Add-DhcpServerInDC -Times 1 -Exactly -ParameterFilter { $DnsName -like '*.ad.firma.ch' -and $IPAddress -eq '192.168.1.10' }
    }
}

Describe 'Scope-Assistent' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:z = New-TestZustand -Szenario DcDns
        $script:NS.Zustand = $script:z
        Mock Get-NetSetupState { $script:z }
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-ADDomainController { [pscustomobject]@{ IPv4Address = '192.168.1.10' } }
        Mock Add-DhcpServerv4Scope { }
        Mock Add-DhcpServerv4ExclusionRange { }
        Mock Set-DhcpServerv4OptionValue { }
        Mock Set-DhcpServerv4Scope { }
        $script:start = [System.Collections.Queue]::new(@('192.168.1.200', '192.168.1.100'))
        $script:ende = [System.Collections.Queue]::new(@('192.168.1.100', '192.168.1.199'))
        Mock Read-NetInput {
            switch -Regex ($Prompt) {
                'Netz des Scopes' { return '192.168.1.0/24' }
                'Name des Scopes' { return 'LAN' }
                'Erste Adresse' { return $script:start.Dequeue() }
                'Letzte Adresse' { return $script:ende.Dequeue() }
                'Ausschluesse' { return '192.168.1.100-192.168.1.109' }
                'Lease' { return '' }
                'Router' { return '192.168.1.1' }
                'DNS-Server' { return '' }
                'Domaene' { return '' }
                default { return 'j' }
            }
        }
    }
    It 'lehnt einen ungueltigen Bereich ab und legt danach den gueltigen Scope an' {
        Mock Get-DhcpServerv4Scope { }
        New-NetDhcpScope | Should -BeTrue
        Should -Invoke Add-DhcpServerv4Scope -Times 1 -Exactly -ParameterFilter { $StartRange -eq '192.168.1.100' -and $EndRange -eq '192.168.1.199' -and $SubnetMask -eq '255.255.255.0' -and $LeaseDuration -eq [timespan]::FromDays(8) }
        Should -Invoke Add-DhcpServerv4ExclusionRange -Times 1 -Exactly -ParameterFilter { $StartRange -eq '192.168.1.100' -and $EndRange -eq '192.168.1.109' }
        Should -Invoke Set-DhcpServerv4OptionValue -Times 1 -Exactly -ParameterFilter { $Router -eq '192.168.1.1' -and ($DnsServer -join ',') -eq '192.168.1.10' -and $DnsDomain -eq 'ad.firma.ch' -and $Force }
        Should -Invoke Set-DhcpServerv4Scope -Times 1 -Exactly -ParameterFilter { $State -eq 'Active' }
    }
    It 'ueberschreibt einen vorhandenen Scope nicht' {
        Mock Get-DhcpServerv4Scope { New-TestScope }
        New-NetDhcpScope | Should -BeTrue
        Should -Invoke Add-DhcpServerv4Scope -Times 0 -Exactly
    }
    It 'nichts ohne Bestaetigung' {
        Mock Get-DhcpServerv4Scope { }
        Mock Read-NetInput {
            switch -Regex ($Prompt) {
                'Netz des Scopes' { return '192.168.1.0/24' }
                'Erste Adresse' { return '192.168.1.100' }
                'Letzte Adresse' { return '192.168.1.199' }
                'Ausfuehren' { return 'n' }
                default { return '' }
            }
        }
        New-NetDhcpScope | Should -BeFalse
        Should -Invoke Add-DhcpServerv4Scope -Times 0 -Exactly
    }
    It 'schlaegt sinnvolle Bereiche vor' {
        Get-NetDhcpRangeSuggestion -Netz '192.168.1.0' -Prefix 24 | Should -Be @('192.168.1.100', '192.168.1.199')
        $b = Get-NetDhcpRangeSuggestion -Netz '10.0.0.0' -Prefix 22
        Test-NetIPRange -Start $b[0] -Ende $b[1] -NetworkAddress '10.0.0.0' -PrefixLength 22 | Should -BeNullOrEmpty
    }
}

Describe 'Reservierungen' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:scope = [pscustomobject]@{ ScopeId = '192.168.1.0'; Name = 'LAN'; Start = '192.168.1.100'; Ende = '192.168.1.199'; Prefix = 24; Status = 'Active' }
        $script:aus = @([pscustomobject]@{ StartRange = '192.168.1.100'; EndRange = '192.168.1.109' })
        $script:leases = @([pscustomobject]@{ IPAddress = '192.168.1.150'; ClientId = '00-11-22-33-44-55'; HostName = 'pc01.ad.firma.ch'; AddressState = 'Active' })
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Add-DhcpServerv4Reservation { }
    }
    It 'normalisiert MAC-Adressen' {
        ConvertTo-NetMacAddress -Text '00:15:5D:AA:BB:CC' | Should -Be '00-15-5d-aa-bb-cc'
        ConvertTo-NetMacAddress -Text '00155daabbcc' | Should -Be '00-15-5d-aa-bb-cc'
        ConvertTo-NetMacAddress -Text 'xyz' | Should -BeNullOrEmpty
    }
    It 'prueft: im Scope, nicht im Ausschluss, nicht belegt' {
        @(Test-NetDhcpReservation -Scope $script:scope -IPAddress '192.168.1.50' -Mac 'aa-bb-cc-dd-ee-ff' -Ausschluesse $script:aus -Reservierungen @() -Leases @()) | Should -Match 'nicht im Bereich'
        @(Test-NetDhcpReservation -Scope $script:scope -IPAddress '192.168.1.105' -Mac 'aa-bb-cc-dd-ee-ff' -Ausschluesse $script:aus -Reservierungen @() -Leases @()) | Should -Match 'Ausschluss'
        @(Test-NetDhcpReservation -Scope $script:scope -IPAddress '192.168.1.150' -Mac 'aa-bb-cc-dd-ee-ff' -Ausschluesse $script:aus -Reservierungen @() -Leases $script:leases) | Should -Match 'anderes Geraet'
        @(Test-NetDhcpReservation -Scope $script:scope -IPAddress '192.168.1.160' -Mac 'aa-bb-cc-dd-ee-ff' -Ausschluesse $script:aus -Reservierungen @() -Leases $script:leases).Count | Should -Be 0
    }
    It 'legt bei Konflikt keine Reservierung an' {
        Mock Get-DhcpServerv4Reservation { }
        Mock Get-DhcpServerv4ExclusionRange { $script:aus }
        Mock Get-DhcpServerv4Lease { $script:leases }
        Mock Read-NetInput { 'j' }
        Add-NetDhcpReservation -Scope $script:scope -IPAddress '192.168.1.150' -Mac 'aa-bb-cc-dd-ee-ff' -Name 'drucker' -OhneDnsFrage | Should -BeFalse
        Should -Invoke Add-DhcpServerv4Reservation -Times 0 -Exactly
    }
    It 'macht aus einem Lease in einem Schritt eine Reservierung' {
        Mock Get-DhcpServerv4Scope { New-TestScope }
        Mock Get-DhcpServerv4Lease { $script:leases }
        Mock Get-DhcpServerv4Reservation { }
        Mock Get-DhcpServerv4ExclusionRange { $script:aus }
        Mock Read-NetInput { if ($Prompt -match 'Nummer') { '1' } else { 'j' } }
        Add-NetDhcpReservationFromLease | Should -BeTrue
        Should -Invoke Add-DhcpServerv4Reservation -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '192.168.1.150' -and $ClientId -eq '00-11-22-33-44-55' -and $Name -eq 'pc01' }
    }
    It 'zweimal dieselbe Reservierung erzeugt kein Duplikat' {
        Mock Get-DhcpServerv4Reservation { [pscustomobject]@{ IPAddress = '192.168.1.160'; ClientId = 'aa-bb-cc-dd-ee-ff'; Name = 'drucker' } }
        Add-NetDhcpReservation -Scope $script:scope -IPAddress '192.168.1.160' -Mac 'AA:BB:CC:DD:EE:FF' -Name 'drucker' -OhneDnsFrage | Should -BeTrue
        Should -Invoke Add-DhcpServerv4Reservation -Times 0 -Exactly
    }
}

Describe 'Optionen' {
    It 'kodiert die DNS-Suchliste nach RFC 3397' {
        $b = ConvertTo-NetDhcpSearchList -Domaenen @('ad.firma.ch')
        $b | Should -Be @(2, 97, 100, 5, 102, 105, 114, 109, 97, 2, 99, 104, 0)
        ConvertFrom-NetDhcpSearchList -Bytes (ConvertTo-NetDhcpSearchList -Domaenen @('ad.firma.ch', 'firma.ch')) | Should -Be @('ad.firma.ch', 'firma.ch')
    }
    It 'definiert Option 119, wenn sie fehlt' {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Probelauf = $false
        Mock Invoke-NetBackupHook { $true }
        Mock Get-DhcpServerv4OptionDefinition { throw 'nicht definiert' }
        Mock Add-DhcpServerv4OptionDefinition { }
        Mock Read-NetInput { 'j' }
        Install-NetDhcpOption119 | Should -BeTrue
        Should -Invoke Add-DhcpServerv4OptionDefinition -Times 1 -Exactly -ParameterFilter { $OptionId -eq 119 -and $Type -eq 'BinaryData' }
    }
}

Describe 'Failover' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Probelauf = $false
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Add-DhcpServerv4Failover { }
    }
    It 'bricht sauber ab, wenn der Partner nicht bereit ist' {
        Mock Resolve-DnsName { throw 'unbekannt' }
        Mock Test-NetTcpPort { $false }
        Mock Get-DhcpServerSetting -ParameterFilter { $ComputerName } { throw 'nicht erreichbar' }
        Mock Read-NetInput { 'dc02.ad.firma.ch' }
        New-NetDhcpFailover | Should -BeFalse
        Should -Invoke Add-DhcpServerv4Failover -Times 0 -Exactly
    }
    It 'meldet einen nicht autorisierten Partner' {
        Mock Resolve-DnsName { 'ok' }
        Mock Test-NetTcpPort { $true }
        Mock Get-DhcpServerSetting -ParameterFilter { $ComputerName } { [pscustomobject]@{ IsDomainJoined = $true; IsAuthorized = $false } }
        @(Test-NetDhcpFailoverPartner -Partner 'dc02') | Should -Match 'nicht im AD autorisiert'
    }
}
