BeforeDiscovery {
    $checkOrdner = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/checks'
    $script:checkDateien = @(Get-ChildItem -Path $checkOrdner -Filter '*.ps1' | ForEach-Object { @{ Datei = $_.Name; Id = $_.Name.Split('-')[0] } })

    # Pro Pruefung: Ausgangslage (Szenario) und wie der Fehlerfall hergestellt wird.
    # Der OK-Fall ist das Szenario ohne Aenderung (optional angepasst mit Ok).
    $script:faelle = @(
        @{ Id = 'R01'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.System.IstAdmin = $false } }
        @{ Id = 'R02'; Szenario = 'Mitglied'; Fehler = { param($z) Mock Get-NetCurrentAccount { [pscustomobject]@{ Name = 'SRV01\Administrator'; IstLokal = $true } } } }
        @{ Id = 'R03'; Szenario = 'DcDhcp'; Ok = { param($z) $z.Dhcp.Autorisiert = $false }; Fehler = { param($z) $z.Dhcp.Autorisiert = $false; Mock Test-NetEnterpriseAdmin { $false } } }
        @{ Id = 'R04'; Szenario = 'Mitglied'; Fehler = { param($z) Mock Get-NetTimeOffset { 400 } } }
        @{ Id = 'O01'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Features['DNS'] = 'Available' } }
        @{ Id = 'O02'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Features['RSAT-DNS-Server'] = 'Available' } }
        @{ Id = 'O03'; Szenario = 'Mitglied'; Fehler = { param($z) $z.Features['AD-Domain-Services'] = 'Installed' } }
        @{ Id = 'O04'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Scopes = @() } }
        @{ Id = 'O05'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Neustart = @{ Ausstehend = $true; Gruende = @('Windows Update') } } }
        @{ Id = 'O06'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dienste['DNS'].Status = 'Stopped' } }
        @{ Id = 'O07'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dienste['DHCPServer'].StartTyp = 'Disabled' } }
        @{ Id = 'O08'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Nachkonfiguriert = $false } }
        @{ Id = 'O09'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Test-Path -ParameterFilter { $Path -like '*dhcp.mdb' } { $false } } }
        @{ Id = 'A01'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dienste['NTDS'].Status = 'Stopped' } }
        @{ Id = 'A02'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Get-SmbShare { throw 'fehlt' } } }
        @{ Id = 'A03'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Resolve-NetDcSrvRecord { $null } } }
        @{ Id = 'A04'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Zeit = @{ Typ = 'NT5DS'; NtpServer = '' } } }
        @{ Id = 'N01'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Netzwerk.AktiveKarten[0].Dhcp = $true } }
        @{ Id = 'N02'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Netzwerk.AktiveKarten[0].DnsServer = @('8.8.8.8') } }
        @{ Id = 'N03'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Bindungen[0].Aktiv = $false } }
        @{ Id = 'N04'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Test-NetFirewallPortOpen { $false } } }
        @{ Id = 'N05'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Test-NetFirewallPortOpen { $false } } }
        @{ Id = 'N06'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Test-NetDnsForwarder { $false } } }
        @{ Id = 'D01'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Autorisiert = $false } }
        @{ Id = 'D02'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Scopes[0].Aktiv = $false } }
        @{ Id = 'D03'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Scopes[0].Auslastung = 95 } }
        @{ Id = 'D04'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Scopes[0].Optionen.Remove('6') } }
        @{ Id = 'D05'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Scopes[0].Reservierungen = @(@{ IP = '192.168.1.105'; ClientId = 'aa'; Name = 'drucker' }) } }
        @{ Id = 'D06'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Netzwerk.EigeneIPs = @('192.168.1.120') } }
        @{ Id = 'D07'; Szenario = 'DcDhcp'; Ok = { param($z) $z.Dhcp.Failover = @(@{ Name = 'F1'; Partner = 'dc02'; Modus = 'LoadBalance'; Status = 'Normal'; Scopes = @('192.168.1.0') }) }; Fehler = { param($z) $z.Dhcp.Failover = @(@{ Name = 'F1'; Partner = 'dc02'; Modus = 'LoadBalance'; Status = 'CommunicationInterrupted'; Scopes = @('192.168.1.0') }) } }
        @{ Id = 'D08'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Find-NetForeignDhcpServer { @('192.168.1.10', '192.168.1.1') } } }
        @{ Id = 'V01'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.Scopes[0].Optionen['15'] = @('andere.ch') } }
        @{ Id = 'V02'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dns.Zonen = @($z.Dns.Zonen | Where-Object { -not $_.Reverse }) } }
        @{ Id = 'V03'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dns.Zonen[0].DynUpdate = 'None' } }
        @{ Id = 'V04'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.DnsZugangsdaten = @{ Gesetzt = $false; Benutzer = ''; Domaene = '' } } }
        @{ Id = 'V05'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Get-NetLeaseDnsCheck { [pscustomobject]@{ IP = '192.168.1.121'; Name = 'pc02'; A = $false; PTR = $false } } } }
        @{ Id = 'V06'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dns.Scavenging.Aktiv = $false } }
        @{ Id = 'V07'; Szenario = 'DcDhcp'; Fehler = { param($z) Mock Get-NetDuplicateDnsRecord { [pscustomobject]@{ Zone = 'ad.firma.ch'; Art = 'x'; Wert = 'pc01'; Liste = '1.1.1.1, 1.1.1.2' } } } }
        @{ Id = 'V08'; Szenario = 'DcDhcp'; Fehler = { param($z) $z.Dhcp.DnsEinstellung.DynamicUpdates = 'OnClientRequest' } }
    )
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')

    function Set-TestDoktorMock {
        Mock Get-NetCurrentAccount { [pscustomobject]@{ Name = 'FIRMA\admin'; IstLokal = $false } }
        Mock Test-NetEnterpriseAdmin { $true }
        Mock Get-NetTimeOffset { 0.5 }
        Mock Get-SmbShare { [pscustomobject]@{ Name = $Name } }
        Mock Resolve-NetDcSrvRecord { 'ok' }
        Mock Get-ADDomainController { [pscustomobject]@{ IPv4Address = '192.168.1.10' } }
        Mock Test-NetFirewallPortOpen { $true }
        Mock Test-NetDnsForwarder { $true }
        Mock Get-DhcpServerv4Lease { }
        Mock Get-DhcpServerInDC { }
        Mock Find-NetForeignDhcpServer { @('192.168.1.10') }
        Mock Get-NetDnsCredentialAccountState { [pscustomobject]@{ Vorhanden = $true; Problem = '' } }
        Mock Get-NetLeaseDnsCheck { }
        Mock Get-NetStaleDnsRecord { }
        Mock Get-NetDuplicateDnsRecord { }
        Mock Test-Path -ParameterFilter { $Path -like '*dhcp.mdb' } { $true }
    }
    function New-TestDoktorZustand {
        param([string]$Szenario)
        $z = New-TestZustand -Szenario $Szenario
        if ($Szenario -eq 'Mitglied') { $z.AD.Pdc = 'dc01.ad.firma.ch'; $z.AD.Verfuegbar = $true }
        return $z
    }
}

Describe 'Pruefkatalog' {
    It 'jede Datei in src/checks meldet genau eine Pruefung mit passender Id an (<Datei>)' -ForEach $checkDateien {
        $vorher = $script:NS.Checks.Count
        $script:NS.Checks.Clear()
        . (Join-Path -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/checks') -ChildPath $Datei)
        $script:NS.Checks.Count | Should -Be 1
        $script:NS.Checks[0].Id | Should -Be $Id
        foreach ($c in (Get-ChildItem -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/checks') -Filter '*.ps1')) { . $c.FullName }
        $script:NS.Checks.Count | Should -BeGreaterOrEqual $vorher
    }
    It 'jede Pruefung hat Testfaelle fuer OK und Fehler' {
        $ids = @($faelle | ForEach-Object { $_.Id })
        foreach ($c in (Get-NetCheck)) { $ids | Should -Contain $c.Id -Because "Pruefung $($c.Id) braucht Testfaelle in Doktor.Tests.ps1" }
    }
    It 'der Build bindet jede Datei aus src/checks automatisch ein' {
        $dist = Get-Content -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'dist/NetSetup.ps1') -Raw
        foreach ($d in $checkDateien) { $dist | Should -Match ([regex]::Escape('# src/checks/' + $d.Datei)) }
    }
    It 'deckt alle Kategorien ab' {
        foreach ($k in $script:NetCheckKategorien) { @(Get-NetCheck -Kategorie $k).Count | Should -BeGreaterThan 0 -Because "Kategorie $k" }
    }
}

Describe 'Pruefung <Id>' -ForEach $faelle {
    BeforeEach {
        $script:NS.Config = Get-NetDefaultConfig
        Set-TestDoktorMock
    }
    It 'OK-Fall' {
        $z = New-TestDoktorZustand -Szenario $Szenario
        if ($Ok) { & $Ok $z }
        $p = @(Get-NetCheck -Id $Id)[0]
        $e = Invoke-NetCheck -Pruefung $p -Zustand $z
        $e.Status | Should -Be 'OK' -Because $e.Detail
    }
    It 'Fehlerfall' {
        $z = New-TestDoktorZustand -Szenario $Szenario
        & $Fehler $z
        $p = @(Get-NetCheck -Id $Id)[0]
        $e = Invoke-NetCheck -Pruefung $p -Zustand $z
        @('WARN', 'FEHLER') | Should -Contain $e.Status -Because $e.Detail
        $e.Problem | Should -Not -BeNullOrEmpty
    }
}

Describe 'Engine' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        Set-TestDoktorMock
        Mock Invoke-NetBackupHook { $true }
    }
    AfterEach {
        foreach ($t in @($script:NS.Checks | Where-Object { $_.Id -like 'T*' })) { [void]$script:NS.Checks.Remove($t) }
    }
    It 'eine Pruefung, die selbst abstuerzt, wird zu [WARN]' {
        Register-NetCheck @{ Id = 'T01'; Kategorie = 'Rechte'; Titel = 't'; Problem = 'p'; Erklaerung = 'e'; Test = { throw 'kaputt' } }
        (Invoke-NetCheck -Pruefung (@(Get-NetCheck -Id 'T01')[0]) -Zustand (New-TestZustand)).Status | Should -Be 'WARN'
    }
    It 'ohne erfuellte Voraussetzung: [--]' {
        Register-NetCheck @{ Id = 'T02'; Kategorie = 'Rechte'; Titel = 't'; Problem = 'p'; Erklaerung = 'e'; Voraussetzung = { $false }; Test = { New-NetCheckResult FEHLER 'x' } }
        (Invoke-NetCheck -Pruefung (@(Get-NetCheck -Id 'T02')[0]) -Zustand (New-TestZustand)).Status | Should -Be 'NA'
    }
    It 'lehnt Pruefungen ohne Pflichtfelder oder mit falscher Stufe ab' {
        { Register-NetCheck @{ Id = 'T03'; Kategorie = 'Rechte'; Titel = 't'; Test = { $true } } } | Should -Throw
        { Register-NetCheck @{ Id = 'T04'; Kategorie = 'Rechte'; Titel = 't'; Problem = 'p'; Erklaerung = 'e'; Test = { $true }; Stufe = 'Egal' } } | Should -Throw
    }
    It 'repariert Stufe Automatisch ohne Rueckfrage' {
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dienste['DNS'].Status = 'Stopped'
        Mock Get-NetSetupState { $script:z }
        Mock Start-Service { $script:z.Dienste['DNS'].Status = 'Running' }
        Mock Read-NetInput { if ($Prompt -match 'Reparatur|Ausfuehren') { 'n' } else { '' } }
        Invoke-NetDoctor -Kategorie 'Rollen' | Out-Null
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'DNS' }
    }
    It 'Probelauf gilt auch fuer Reparaturen' {
        $script:NS.Probelauf = $true
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dienste['DNS'].Status = 'Stopped'
        Mock Get-NetSetupState { $script:z }
        Mock Start-Service { }
        Mock Read-NetInput { 'j' }
        Invoke-NetDoctor -Kategorie 'Rollen' | Out-Null
        Should -Invoke Start-Service -Times 0 -Exactly
    }
    It 'automatische Reparatur ist abschaltbar' {
        $script:NS.Config.Allgemein.AutoReparatur = $false
        $script:z = New-TestZustand -Szenario DcDhcp
        $script:z.Dienste['DNS'].Status = 'Stopped'
        Mock Get-NetSetupState { $script:z }
        Mock Start-Service { }
        Mock Read-NetInput { 'n' }
        Invoke-NetDoctor -Kategorie 'Rollen' | Out-Null
        Should -Invoke Start-Service -Times 0 -Exactly
    }
    It 'Stufe Gefaehrlich verlangt den Servernamen' {
        $script:repariert = 0
        Register-NetCheck @{ Id = 'T05'; Kategorie = 'Rechte'; Titel = 't'; Problem = 'p'; Erklaerung = 'e'; Stufe = 'Gefaehrlich'; Test = { New-NetCheckResult FEHLER 'x' }; Reparatur = { $script:repariert++ } }
        $e = Invoke-NetCheck -Pruefung (@(Get-NetCheck -Id 'T05')[0]) -Zustand (New-TestZustand)
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { 'falsch' } else { 'j' } }
        Invoke-NetCheckRepair -Ergebnis $e -Zustand (New-TestZustand) | Should -BeFalse
        $script:repariert | Should -Be 0
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } else { 'j' } }
        Invoke-NetCheckRepair -Ergebnis $e -Zustand (New-TestZustand) | Should -BeTrue
        $script:repariert | Should -Be 1
        Should -Invoke Invoke-NetBackupHook -Times 1
    }
    It 'Gefaehrliche oder bestaetigungspflichtige Reparaturen laufen nie automatisch' {
        $script:repariert = 0
        Register-NetCheck @{ Id = 'T06'; Kategorie = 'Rechte'; Titel = 't'; Problem = 'p'; Erklaerung = 'e'; Stufe = 'Bestaetigen'; Test = { New-NetCheckResult FEHLER 'x' }; Reparatur = { $script:repariert++ } }
        $e = Invoke-NetCheck -Pruefung (@(Get-NetCheck -Id 'T06')[0]) -Zustand (New-TestZustand)
        Invoke-NetCheckRepair -Ergebnis $e -Zustand (New-TestZustand) -Automatisch | Should -BeFalse
        $script:repariert | Should -Be 0
    }
    It 'Health-Aufgabe prueft nur und legt ein Ergebnis ab' {
        $script:z = New-TestZustand -Szenario DcDhcp
        Mock Get-NetSetupState { $script:z }
        Mock Start-Service { }
        Invoke-NetHealthTask
        Should -Invoke Start-Service -Times 0 -Exactly
        @(Get-ChildItem -Path (Get-NetPath -Name Berichte)).Count | Should -BeGreaterThan 0
    }
}

Describe 'DHCPDISCOVER' {
    It 'baut ein gueltiges Paket' {
        $p = New-NetDhcpDiscoverPacket -Xid ([byte[]](1, 2, 3, 4)) -Mac ([byte[]](2, 0, 0, 0, 0, 1))
        $p[0] | Should -Be 1
        $p[10] | Should -Be 0x80
        $p[236..239] | Should -Be @(99, 130, 83, 99)
        $p[240..242] | Should -Be @(53, 1, 1)
        $p.Length | Should -BeGreaterOrEqual 300
    }
}
