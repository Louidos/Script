BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')

    function New-TestDnsZone {
        param([string]$Name, [bool]$Ds = $true, [bool]$Reverse = $false, [string]$Update = 'Secure', [string]$Typ = 'Primary')
        [pscustomobject]@{ ZoneName = $Name; ZoneType = $Typ; IsDsIntegrated = $Ds; IsReverseLookupZone = $Reverse; DynamicUpdate = $Update; ReplicationScope = 'Domain'; IsAutoCreated = $false }
    }
    function New-TestDnsRecordObjekt {
        param([string]$Name, [string]$Typ, [hashtable]$Daten, [object]$Zeit = $null)
        $rd = [pscustomobject]$Daten
        if ($Typ -eq 'A') { $rd = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse($Daten.IPv4Address) } }
        [pscustomobject]@{ HostName = $Name; RecordType = $Typ; RecordData = $rd; Timestamp = $Zeit; TimeToLive = '01:00:00' }
    }
}

Describe 'DNS-Zonen' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        Mock Invoke-NetBackupHook { $true }
        Mock Add-DnsServerPrimaryZone { }
    }
    It 'legt eine vorhandene Zone nicht nochmal an' {
        Mock Get-DnsServerZone { New-TestDnsZone -Name 'ad.firma.ch' }
        New-NetDnsZone -Name 'ad.firma.ch' | Should -BeTrue
        Should -Invoke Add-DnsServerPrimaryZone -Times 0 -Exactly
    }
    It 'legt auf einem DC eine AD-integrierte Zone mit sicheren Updates an' {
        $script:NS.Zustand = New-TestZustand -Szenario DcDns
        Mock Get-DnsServerZone { throw 'nicht vorhanden' }
        Mock Read-NetInput { if ($Prompt -match 'Ausfuehren') { 'j' } else { '' } }
        New-NetDnsZone -Name 'intern.firma.ch' | Should -BeTrue
        Should -Invoke Add-DnsServerPrimaryZone -Times 1 -Exactly -ParameterFilter { $ReplicationScope -eq 'Domain' -and $DynamicUpdate -eq 'Secure' -and -not $ZoneFile }
    }
    It 'legt ohne DC eine dateibasierte Zone an' {
        $script:NS.Zustand = New-TestZustand -Szenario Frisch
        Mock Get-DnsServerZone { throw 'nicht vorhanden' }
        Mock Read-NetInput { if ($Prompt -match 'Ausfuehren') { 'j' } else { '' } }
        New-NetDnsZone -Name 'firma.lan' | Should -BeTrue
        Should -Invoke Add-DnsServerPrimaryZone -Times 1 -Exactly -ParameterFilter { $ZoneFile -eq 'firma.lan.dns' -and -not $ReplicationScope -and $DynamicUpdate -eq 'NonsecureAndSecure' }
    }
    It 'aendert nichts ohne Bestaetigung' {
        $script:NS.Zustand = New-TestZustand -Szenario DcDns
        Mock Get-DnsServerZone { throw 'nicht vorhanden' }
        Mock Read-NetInput { if ($Prompt -match 'Ausfuehren') { 'n' } else { '' } }
        New-NetDnsZone -Name 'intern.firma.ch' | Should -BeFalse
        Should -Invoke Add-DnsServerPrimaryZone -Times 0 -Exactly
    }
    It 'schlaegt fehlende Reverse-Zonen fuer Server-Netz und Scopes vor' {
        $z = New-TestZustand -Szenario DcDhcp
        $z.Dhcp.Scopes += @{ ScopeId = '10.20.0.0'; Name = 'WLAN'; Prefix = 16 }
        $fehlend = @(Get-NetMissingReverseZone -Zustand $z)
        $fehlend.Count | Should -Be 1
        $fehlend[0].Zone | Should -Be '20.10.in-addr.arpa'
    }
    It 'eine groessere Reverse-Zone deckt kleinere Netze ab' {
        $z = New-TestZustand -Szenario DcDhcp
        $z.Dns.Zonen = @(@{ Name = '168.192.in-addr.arpa'; Reverse = $true; Typ = 'Primary' })
        @(Get-NetMissingReverseZone -Zustand $z).Count | Should -Be 0
    }
    It 'sichere Updates nur fuer AD-integrierte Zonen' {
        Mock Get-DnsServerZone { New-TestDnsZone -Name 'firma.lan' -Ds $false -Update 'None' }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Set-DnsServerPrimaryZone { }
        Set-NetDnsZoneUpdate -Zone 'firma.lan' -Wert 'Secure' | Should -BeFalse
        Should -Invoke Set-DnsServerPrimaryZone -Times 0 -Exactly
    }
}

Describe 'DNS-Eintraege' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:eintraege = New-Object System.Collections.ArrayList
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-DnsServerZone { New-TestDnsZone -Name 'ad.firma.ch'; New-TestDnsZone -Name '1.168.192.in-addr.arpa' -Reverse $true }
        Mock Get-DnsServerResourceRecord { @($script:eintraege | Where-Object { (-not $Name -or $_.HostName -eq $Name) -and (-not $RRType -or $_.RecordType -eq $RRType) }) }
        Mock Add-DnsServerResourceRecordA { [void]$script:eintraege.Add((New-TestDnsRecordObjekt -Name $Name -Typ 'A' -Daten @{ IPv4Address = $IPv4Address })) }
        Mock Add-DnsServerResourceRecordCName { [void]$script:eintraege.Add((New-TestDnsRecordObjekt -Name $Name -Typ 'CNAME' -Daten @{ HostNameAlias = $HostNameAlias })) }
        Mock Remove-DnsServerResourceRecord { $script:eintraege.Remove($InputObject) }
        Mock Read-NetInput { if ($Prompt -match 'Ausfuehren') { 'j' } elseif ($Prompt -match 'PTR') { 'j' } else { '' } }
    }
    It 'zweimal anlegen erzeugt kein Duplikat' {
        Add-NetDnsRecord -Zone 'ad.firma.ch' -Name 'srv01' -Typ A -Daten @{ IPv4Address = '192.168.1.20' } | Should -BeTrue
        Add-NetDnsRecord -Zone 'ad.firma.ch' -Name 'srv01' -Typ A -Daten @{ IPv4Address = '192.168.1.20' } | Should -BeTrue
        Should -Invoke Add-DnsServerResourceRecordA -Times 1 -Exactly
        $script:eintraege.Count | Should -Be 1
    }
    It 'legt den PTR mit an, wenn es die Reverse-Zone gibt' {
        Add-NetDnsRecord -Zone 'ad.firma.ch' -Name 'pc01' -Typ A -Daten @{ IPv4Address = '192.168.1.50' } | Should -BeTrue
        Should -Invoke Add-DnsServerResourceRecordA -Times 1 -Exactly -ParameterFilter { $CreatePtr }
    }
    It 'warnt bei Konflikt mit einem CNAME und legt ohne Ja nichts an' {
        [void]$script:eintraege.Add((New-TestDnsRecordObjekt -Name 'intranet' -Typ 'CNAME' -Daten @{ HostNameAlias = 'srv01.ad.firma.ch.' }))
        Mock Read-NetInput { if ($Prompt -match 'Trotzdem') { 'n' } else { 'j' } }
        Add-NetDnsRecord -Zone 'ad.firma.ch' -Name 'intranet' -Typ A -Daten @{ IPv4Address = '192.168.1.30' } -MitPtr $false | Should -BeFalse
        Should -Invoke Add-DnsServerResourceRecordA -Times 0 -Exactly
    }
    It 'Gegenaktion loescht genau den angelegten Eintrag' {
        [void]$script:eintraege.Add((New-TestDnsRecordObjekt -Name 'srv01' -Typ 'A' -Daten @{ IPv4Address = '192.168.1.21' }))
        Mock Read-NetInput { 'j' }
        Add-NetDnsRecord -Zone 'ad.firma.ch' -Name 'srv01' -Typ A -Daten @{ IPv4Address = '192.168.1.20' } -MitPtr $false | Should -BeTrue
        $script:eintraege.Count | Should -Be 2
        Mock Read-NetInput { 'j' }
        Undo-NetChange -Id (@(Get-NetUndoEntry)[0].Id) | Should -BeTrue
        $script:eintraege.Count | Should -Be 1
        $script:eintraege[0].RecordData.IPv4Address.IPAddressToString | Should -Be '192.168.1.21'
    }
    It 'CNAME-Ziel wird mit und ohne Punkt am Ende als gleich erkannt' {
        [void]$script:eintraege.Add((New-TestDnsRecordObjekt -Name 'www' -Typ 'CNAME' -Daten @{ HostNameAlias = 'srv01.ad.firma.ch.' }))
        Add-NetDnsRecord -Zone 'ad.firma.ch' -Name 'www' -Typ CNAME -Daten @{ HostNameAlias = 'srv01.ad.firma.ch' } | Should -BeTrue
        Should -Invoke Add-DnsServerResourceRecordCName -Times 0 -Exactly
    }
    It 'sucht in allen Zonen' {
        [void]$script:eintraege.Add((New-TestDnsRecordObjekt -Name 'drucker' -Typ 'A' -Daten @{ IPv4Address = '192.168.1.99' }))
        @(Find-NetDnsRecord -Suche 'druck').Count | Should -BeGreaterThan 0
    }
    It 'prueft Namen von Eintraegen' {
        Test-NetDnsRecordName -Name '@' | Should -BeNullOrEmpty
        Test-NetDnsRecordName -Name 'pc 01' | Should -Not -BeNullOrEmpty
        Test-NetDnsRecordName -Name '_sip._tcp' -Srv | Should -BeNullOrEmpty
    }
}

Describe 'Weiterleitungen' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Set-DnsServerForwarder { }
        Mock Read-NetInput { 'j' }
    }
    It 'funktioniert ohne Internet: Test schlaegt fehl, Einstellung wird trotzdem gesetzt' {
        Mock Get-DnsServerForwarder { [pscustomobject]@{ IPAddress = @() } }
        Mock Resolve-DnsName { throw 'Zeitueberschreitung' }
        Set-NetDnsForwarder -Adressen @('9.9.9.9', '1.1.1.1') | Should -BeTrue
        Should -Invoke Set-DnsServerForwarder -Times 1 -Exactly -ParameterFilter { ($IPAddress -join ',') -eq '9.9.9.9,1.1.1.1' }
    }
    It 'aendert gleiche Weiterleitungen nicht nochmal' {
        Mock Get-DnsServerForwarder { [pscustomobject]@{ IPAddress = @([System.Net.IPAddress]::Parse('9.9.9.9'), [System.Net.IPAddress]::Parse('1.1.1.1')) } }
        Mock Resolve-DnsName { 'ok' }
        Set-NetDnsForwarder -Adressen @('9.9.9.9', '1.1.1.1') | Should -BeTrue
        Should -Invoke Set-DnsServerForwarder -Times 0 -Exactly
    }
    It 'nur nach Bestaetigung' {
        Mock Get-DnsServerForwarder { [pscustomobject]@{ IPAddress = @([System.Net.IPAddress]::Parse('8.8.8.8')) } }
        Mock Resolve-DnsName { 'ok' }
        Mock Read-NetInput { 'n' }
        Set-NetDnsForwarder -Adressen @('9.9.9.9') | Should -BeFalse
        Should -Invoke Set-DnsServerForwarder -Times 0 -Exactly
    }
}

Describe 'Aging und Scavenging' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:testZ = New-TestZustand -Szenario DcDhcp
        Mock Get-NetSetupState { $script:testZ }
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-DnsServerZone { New-TestDnsZone -Name 'ad.firma.ch'; New-TestDnsZone -Name '1.168.192.in-addr.arpa' -Reverse $true }
        Mock Set-DnsServerScavenging { }
        Mock Set-DnsServerZoneAging { }
        Mock Read-NetInput { 'j' }
    }
    It 'schaltet mit Vorschlag 7 + 7 Tage ein (Server und Zonen)' {
        Mock Get-DnsServerScavenging { [pscustomobject]@{ ScavengingState = $false; ScavengingInterval = [timespan]::Zero; NoRefreshInterval = [timespan]::FromDays(7); RefreshInterval = [timespan]::FromDays(7) } }
        Set-NetDnsScavenging -Aktiv $true -NoRefreshTage 7 -RefreshTage 7 | Should -BeTrue
        Should -Invoke Set-DnsServerScavenging -Times 1 -Exactly -ParameterFilter { $ScavengingState -eq $true -and $NoRefreshInterval -eq [timespan]::FromDays(7) -and $RefreshInterval -eq [timespan]::FromDays(7) }
        Should -Invoke Set-DnsServerZoneAging -Times 2 -Exactly
    }
    It 'aendert nichts, wenn es schon so eingestellt ist' {
        Mock Get-DnsServerScavenging { [pscustomobject]@{ ScavengingState = $true; ScavengingInterval = [timespan]::FromDays(7); NoRefreshInterval = [timespan]::FromDays(7); RefreshInterval = [timespan]::FromDays(7) } }
        Set-NetDnsScavenging -Aktiv $true -NoRefreshTage 7 -RefreshTage 7 | Should -BeTrue
        Should -Invoke Set-DnsServerScavenging -Times 0 -Exactly
    }
    It 'warnt, wenn No-Refresh + Refresh kuerzer als die Lease-Dauer ist' {
        Mock Get-DnsServerScavenging { [pscustomobject]@{ ScavengingState = $false } }
        Mock Read-NetInput { if ($Prompt -match 'Trotzdem') { 'n' } else { 'j' } }
        Set-NetDnsScavenging -Aktiv $true -NoRefreshTage 2 -RefreshTage 2 | Should -BeFalse
        Should -Invoke Set-DnsServerScavenging -Times 0 -Exactly
    }
    It 'nur melden loescht nichts' {
        $alt = (Get-Date).AddDays(-30)
        Mock Get-DnsServerResourceRecord { New-TestDnsRecordObjekt -Name 'altpc' -Typ 'A' -Daten @{ IPv4Address = '192.168.1.77' } -Zeit $alt }
        Mock Remove-DnsServerResourceRecord { }
        Mock Export-Csv { }
        @(Get-NetStaleDnsRecord -NoRefreshTage 7 -RefreshTage 7).Count | Should -BeGreaterThan 0
        Show-NetStaleDnsRecord
        Should -Invoke Remove-DnsServerResourceRecord -Times 0 -Exactly
    }
}
