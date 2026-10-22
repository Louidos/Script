BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')
    function New-TestLease {
        param([string]$IP, [string]$Name)
        [pscustomobject]@{ IPAddress = [System.Net.IPAddress]::Parse($IP); HostName = $Name; ClientId = '00-11-22-33-44-55'; AddressState = 'Active' }
    }
}

Describe 'DHCP-DNS-Einstellungen' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:einst = @{ '' = [pscustomobject]@{ DynamicUpdates = 'OnClientRequest'; DeleteDnsRROnLeaseExpiry = $false; UpdateDnsRRForOlderClients = $false; NameProtection = $false; DisableDnsPtrRRUpdate = $false } }
        $script:einst['192.168.1.0'] = $script:einst['']
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-DhcpServerv4Scope { [pscustomobject]@{ ScopeId = [System.Net.IPAddress]::Parse('192.168.1.0'); Name = 'LAN'; StartRange = '192.168.1.100'; EndRange = '192.168.1.199'; SubnetMask = '255.255.255.0'; State = 'Active'; LeaseDuration = [timespan]::FromDays(8) } }
        Mock Get-DhcpServerv4DnsSetting { $script:einst[[string]$ScopeId] }
        Mock Set-DhcpServerv4DnsSetting {
            $script:einst[[string]$ScopeId] = [pscustomobject]@{ DynamicUpdates = $DynamicUpdates; DeleteDnsRROnLeaseExpiry = $DeleteDnsRROnLeaseExpiry; UpdateDnsRRForOlderClients = $UpdateDnsRRForOlderClients; NameProtection = $NameProtection; DisableDnsPtrRRUpdate = $DisableDnsPtrRRUpdate }
        }
        Mock Read-NetInput { 'j' }
    }
    It 'setzt Server und Scope auf Always, Loeschen bei Ablauf und aeltere Clients' {
        Set-NetDhcpDnsSetting -Namensschutz $false | Should -BeTrue
        Should -Invoke Set-DhcpServerv4DnsSetting -Times 2 -Exactly -ParameterFilter { $DynamicUpdates -eq 'Always' -and $DeleteDnsRROnLeaseExpiry -and $UpdateDnsRRForOlderClients }
        Should -Invoke Set-DhcpServerv4DnsSetting -Times 1 -Exactly -ParameterFilter { $ScopeId -eq '192.168.1.0' }
    }
    It 'ist idempotent' {
        Set-NetDhcpDnsSetting -Namensschutz $false | Out-Null
        Set-NetDhcpDnsSetting -Namensschutz $false | Out-Null
        Should -Invoke Set-DhcpServerv4DnsSetting -Times 2 -Exactly
    }
    It 'nach dem Setzen zeigt die Statusuebersicht [OK]' {
        Set-NetDhcpDnsSetting -Namensschutz $false | Out-Null
        $z = New-TestZustand -Szenario DcDhcp
        $z.Dhcp.DnsEinstellung = ConvertTo-NetDhcpDnsSetting -Einstellung $script:einst['']
        ((Get-NetStateSummary -Zustand $z) | Where-Object Bereich -eq 'DHCP + DNS').Status | Should -Be 'OK'
    }
}

Describe 'Warnung DHCP auf DC ohne Zugangsdaten' {
    It 'zeigt einen deutlichen Fehler' {
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dhcp.DnsZugangsdaten = @{ Gesetzt = $false; Benutzer = ''; Domaene = '' }
        Mock Get-NetSetupState { $script:z }
        Mock Test-NetDhcpDnsZoneReady { $true }
        Mock Test-NetAgingVsLease { $true }
        $script:meldungen = @()
        Mock Write-NetStatus { $script:meldungen += ('{0}|{1}|{2}' -f $Status, $Bereich, $Text) }
        Show-NetIntegrationStatus
        ($script:meldungen -join "`n") | Should -Match 'FEHLER\|Zugangsdaten\|DHCP LAEUFT AUF EINEM DC OHNE DNS-ZUGANGSDATEN'
        ((Get-NetStateSummary -Zustand $script:z) | Where-Object Bereich -eq 'DHCP + DNS').Text | Should -Match 'ohne DNS-Zugangsdaten'
    }
}

Describe 'Dienstkonto' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.LogDatei = Join-Path -Path $script:NS.Datenpfad -ChildPath 'Logs/test.log'
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dhcp.DnsZugangsdaten = @{ Gesetzt = $false; Benutzer = ''; Domaene = '' }
        Mock Get-NetSetupState { $script:z }
        Mock Invoke-NetBackupHook { $true }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-ADUser { throw 'nicht gefunden' }
        Mock New-ADUser { }
        Mock Set-DhcpServerDnsCredential { }
        $script:geheim = ConvertTo-SecureString -String 'GanzGeheim!12345' -AsPlainText -Force
        Mock Read-NetInput { if ($Geheim) { $script:geheim } elseif ($Prompt -match 'Name des Dienstkontos') { '' } else { 'j' } }
    }
    It 'legt das Konto an, setzt die Zugangsdaten und speichert das Kennwort nirgends' {
        New-NetDhcpDnsCredential | Should -BeTrue
        Should -Invoke New-ADUser -Times 1 -Exactly -ParameterFilter { $SamAccountName -eq 'svc-dhcpdns' -and $AccountPassword -is [System.Security.SecureString] }
        Should -Invoke Set-DhcpServerDnsCredential -Times 1 -Exactly -ParameterFilter { $Credential.UserName -eq 'FIRMA\svc-dhcpdns' }
        foreach ($d in (Get-ChildItem -Path $script:NS.Datenpfad -Recurse -File)) {
            (Get-Content -Path $d.FullName -Raw) | Should -Not -Match 'GanzGeheim'
        }
    }
    It 'legt ohne Bestaetigung kein Konto an' {
        Mock Read-NetInput { if ($Geheim) { $script:geheim } elseif ($Prompt -match 'Ausfuehren') { 'n' } else { '' } }
        New-NetDhcpDnsCredential | Should -BeFalse
        Should -Invoke New-ADUser -Times 0 -Exactly
        Should -Invoke Set-DhcpServerDnsCredential -Times 0 -Exactly
    }
}

Describe 'Pruefung Leases gegen DNS' {
    BeforeEach {
        $script:NS.Config = Get-NetDefaultConfig
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dhcp.Scopes[0].DnsEinstellung = @{ DynamicUpdates = 'OnClientRequest'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $false; NameProtection = $false; DisableDnsPtrRRUpdate = $false }
        $script:z.Dhcp.Scopes += @{ ScopeId = '10.9.0.0'; Name = 'Gaeste'; Prefix = 24; Optionen = @{}; DnsEinstellung = $null }
        Mock Get-DhcpServerv4Lease {
            if ($ScopeId -eq '192.168.1.0') {
                New-TestLease -IP '192.168.1.120' -Name 'pc01.ad.firma.ch'
                New-TestLease -IP '192.168.1.121' -Name 'pc02.ad.firma.ch'
                New-TestLease -IP '192.168.1.122' -Name ''
            }
            else { New-TestLease -IP '10.9.0.50' -Name 'gast1' }
        }
        Mock Get-DnsServerResourceRecord {
            if ($RRType -eq 'A' -and $Name -eq 'pc01') { [pscustomobject]@{ RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('192.168.1.120') } } }
            if ($RRType -eq 'A' -and $Name -eq 'gast1') { [pscustomobject]@{ RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('10.9.0.50') } } }
            if ($RRType -eq 'PTR' -and $Name -eq '120') { [pscustomobject]@{ RecordData = [pscustomobject]@{ PtrDomainName = 'pc01.ad.firma.ch.' } } }
        }
    }
    It 'listet Leases ohne DNS-Eintrag mit Ursache' {
        $liste = @(Get-NetLeaseDnsCheck -Zustand $script:z)
        $liste.Count | Should -Be 4
        $pc01 = $liste | Where-Object IP -eq '192.168.1.120'
        ($pc01.A -and $pc01.PTR) | Should -BeTrue
        ($liste | Where-Object IP -eq '192.168.1.121').Ursache | Should -Match 'nur auf Wunsch des Clients'
        ($liste | Where-Object IP -eq '192.168.1.122').Ursache | Should -Match 'keinen Namen'
        ($liste | Where-Object IP -eq '10.9.0.50').Ursache | Should -Match 'Reverse-Zone'
    }
    It 'traegt fehlende Eintraege nach Bestaetigung nach' {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Probelauf = $false
        Mock Get-NetSetupState { $script:z }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Invoke-NetBackupHook { $true }
        Mock Add-NetDnsRecordExact { }
        Mock Read-NetInput { if ($Prompt -match 'Nummern') { '*' } else { 'j' } }
        Show-NetLeaseDnsCheck | Out-Null
        Should -Invoke Add-NetDnsRecordExact -Times 1 -Exactly -ParameterFilter { $Typ -eq 'A' -and $Name -eq 'pc02' -and $Daten.IPv4Address -eq '192.168.1.121' }
        Should -Invoke Add-NetDnsRecordExact -Times 1 -Exactly -ParameterFilter { $Typ -eq 'PTR' -and $Name -eq '121' -and $ZoneName -eq '1.168.192.in-addr.arpa' }
    }
}

Describe 'Aging gegen Lease-Dauer' {
    It 'warnt, wenn No-Refresh + Refresh kuerzer als die Lease ist' {
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dhcp.Scopes[0].LeaseTage = 30
        Mock Get-NetSetupState { $script:z }
        Test-NetAgingVsLease -NurPruefen | Should -BeFalse
        $script:z.Dhcp.Scopes[0].LeaseTage = 8
        Test-NetAgingVsLease -NurPruefen | Should -BeTrue
    }
}
