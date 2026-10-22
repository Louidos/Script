BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')
    function Initialize-TestErweitert {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:NS.ErweitertFrei = $false
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
    }
}

Describe 'Erweitert ist ohne Freischalten wirkungslos' {
    BeforeEach { Initialize-TestErweitert }
    It '<Funktion> aendert nichts, wenn nicht freigeschaltet wird' -ForEach @(
        @{ Funktion = 'Invoke-NetDnssecSign'; Cmdlet = 'Invoke-DnsServerZoneSign' }
        @{ Funktion = 'New-NetSplitBrain'; Cmdlet = 'Add-DnsServerQueryResolutionPolicy' }
        @{ Funktion = 'New-NetDhcpPolicy'; Cmdlet = 'Add-DhcpServerv4Policy' }
        @{ Funktion = 'Add-NetDnsBlock'; Cmdlet = 'Add-DnsServerQueryResolutionPolicy' }
        @{ Funktion = 'New-NetDhcpv6Scope'; Cmdlet = 'Add-DhcpServerv6Scope' }
    ) {
        Mock $Cmdlet { }
        Mock Read-NetInput { 'n' }
        & $Funktion | Out-Null
        Should -Invoke $Cmdlet -Times 0 -Exactly
        $script:NS.ErweitertFrei | Should -BeFalse
    }
    It 'jede Funktion hat Hilfe und das Menue eine Warnung' {
        foreach ($t in @($script:NetHilfeDnssec, $script:NetHilfeSplitBrain, $script:NetHilfeDhcpRichtlinie, $script:NetHilfeSperrliste, $script:NetHilfeDhcpv6, $script:NetErweitertWarnung)) {
            $t | Should -Not -BeNullOrEmpty
        }
        $script:NetErweitertWarnung | Should -Match 'ACHTUNG'
    }
    It 'die Einstellungen sind standardmaessig aus' {
        $e = (Get-NetDefaultConfig).Erweitert
        foreach ($k in $e.Keys) { $e[$k] | Should -BeFalse }
    }
}

Describe 'Erweitert nach Freischalten' {
    BeforeEach {
        Initialize-TestErweitert
        $script:NS.ErweitertFrei = $true
    }
    It 'DNSSEC: signiert erst nach Servername und merkt die Ruecknahme' {
        Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = 'ad.firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false; IsSigned = $false } }
        Mock Invoke-DnsServerZoneSign { }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { 'falsch' } else { 'j' } }
        Invoke-NetDnssecSign | Should -BeFalse
        Should -Invoke Invoke-DnsServerZoneSign -Times 0 -Exactly
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } else { 'j' } }
        Invoke-NetDnssecSign | Should -BeTrue
        Should -Invoke Invoke-DnsServerZoneSign -Times 1 -Exactly
        @(Get-NetUndoEntry)[0].Schritte[0].Befehl | Should -Be 'Invoke-DnsServerZoneUnsign'
    }
    It 'Split-Brain: lehnt AD-integrierte Zonen ab' {
        Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = 'ad.firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false } }
        Mock Add-DnsServerQueryResolutionPolicy { }
        Mock Read-NetInput { 'j' }
        New-NetSplitBrain | Should -BeFalse
        Should -Invoke Add-DnsServerQueryResolutionPolicy -Times 0 -Exactly
    }
    It 'Split-Brain: legt die Richtlinie standardmaessig ausgeschaltet an' {
        Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = 'firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $false; IsReverseLookupZone = $false; DynamicUpdate = 'None'; ReplicationScope = 'None'; IsAutoCreated = $false } }
        Mock Get-DnsServerClientSubnet { }
        Mock Add-DnsServerClientSubnet { }
        Mock Get-DnsServerZoneScope { }
        Mock Add-DnsServerZoneScope { }
        Mock Add-DnsServerResourceRecordA { }
        Mock Add-DnsServerQueryResolutionPolicy { }
        Mock Read-NetInput {
            switch -Regex ($Prompt) {
                'Internes Netz' { '192.168.0.0/16' }
                'Name des Eintrags' { 'mail' }
                'Interne IP' { '192.168.1.20' }
                'sofort aktivieren' { '' }
                default { 'j' }
            }
        }
        New-NetSplitBrain | Should -BeTrue
        Should -Invoke Add-DnsServerQueryResolutionPolicy -Times 1 -Exactly -ParameterFilter { $Disable -and $ZoneName -eq 'firma.ch' -and $ClientSubnet -eq 'eq,NetSetup-Intern' }
        Should -Invoke Add-DnsServerResourceRecordA -Times 1 -Exactly -ParameterFilter { $ZoneScope -eq 'intern' -and $IPv4Address -eq '192.168.1.20' }
        @(Get-NetUndoEntry)[0].Schritte.Count | Should -Be 2
    }
    It 'DHCP-Richtlinie: wird ausgeschaltet angelegt (MAC-Praefix)' {
        Mock Get-DhcpServerv4Scope { [pscustomobject]@{ ScopeId = [System.Net.IPAddress]::Parse('192.168.1.0'); Name = 'LAN'; StartRange = '192.168.1.100'; EndRange = '192.168.1.199'; SubnetMask = '255.255.255.0'; State = 'Active'; LeaseDuration = [timespan]::FromDays(8) } }
        Mock Add-DhcpServerv4Policy { }
        Mock Set-DhcpServerv4OptionValue { }
        Mock Set-DhcpServerv4Policy { }
        Mock Read-NetInput {
            switch -Regex ($Prompt) {
                'MAC-Praefix' { '00-15-5D' }
                'Wert' { '192.168.1.11' }
                'Nummer' { '1' }
                'sofort aktivieren' { 'n' }
                default { '' }
            }
        }
        Mock Read-NetChoice { if ($Frage -match 'Option') { 1 } else { 0 } }
        Mock Read-NetYesNo { if ($Frage -match 'sofort') { $false } else { $true } }
        New-NetDhcpPolicy | Should -BeTrue
        Should -Invoke Add-DhcpServerv4Policy -Times 1 -Exactly -ParameterFilter { $Enabled -eq $false -and ($MacAddress -join ',') -eq 'EQ,00155D*' }
        Should -Invoke Set-DhcpServerv4Policy -Times 0 -Exactly
        Should -Invoke Set-DhcpServerv4OptionValue -Times 1 -Exactly -ParameterFilter { $OptionId -eq 6 -and $PolicyName }
    }
    It 'Sperrliste: legt Sperren ausgeschaltet an und ist idempotent' {
        Mock Get-DnsServerQueryResolutionPolicy { [pscustomobject]@{ Name = 'NetSetup-Sperre-alt.example'; IsEnabled = 'True' } }
        Mock Add-DnsServerQueryResolutionPolicy { }
        Mock Read-NetInput { if ($Prompt -match 'Domaenen sperren') { 'alt.example, neu.example' } elseif ($Prompt -match 'sofort') { '' } else { 'j' } }
        Add-NetDnsBlock | Should -BeTrue
        Should -Invoke Add-DnsServerQueryResolutionPolicy -Times 1 -Exactly -ParameterFilter { $Name -eq 'NetSetup-Sperre-neu.example' -and $Action -eq 'IGNORE' -and $Disable -and $Fqdn -eq 'EQ,*.neu.example,neu.example' }
    }
    It 'DHCPv6: Scope wird inaktiv angelegt, Ruecknahme moeglich' {
        Mock Get-DhcpServerv6Scope { }
        Mock Add-DhcpServerv6Scope { }
        Mock Read-NetInput { if ($Prompt -match 'Praefix') { 'fd00:1234:5678:1::' } elseif ($Prompt -match 'Name') { '' } else { 'j' } }
        New-NetDhcpv6Scope | Should -BeTrue
        Should -Invoke Add-DhcpServerv6Scope -Times 1 -Exactly -ParameterFilter { $State -eq 'InActive' -and $Prefix -eq 'fd00:1234:5678:1::' }
        @(Get-NetUndoEntry)[0].Schritte[0].Befehl | Should -Be 'Remove-DhcpServerv6Scope'
    }
}
