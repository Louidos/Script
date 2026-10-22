BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')
    $script:dsrm = ConvertTo-SecureString -String 'Sicher!2026x' -AsPlainText -Force
}

Describe 'Entscheidungsbaum' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:optionen = $null
        Mock Read-NetChoice { $script:optionen = $Optionen; return ($Optionen.Count - 1) }
    }
    It 'DC: zeigt die Domaene und fragt nichts' {
        $script:z = New-TestZustand -Szenario DcDns
        Mock Get-NetSetupState { $script:z }
        Mock Show-NetAdInfo { }
        Start-NetAdSetup
        Should -Invoke Show-NetAdInfo -Times 1
        $script:optionen | Should -BeNullOrEmpty
    }
    It 'Mitgliedsserver: zusaetzlicher DC oder nur DNS/DHCP' {
        $script:z = New-TestZustand -Szenario Mitglied
        Mock Get-NetSetupState { $script:z }
        Start-NetAdSetup
        ($script:optionen -join ' ') | Should -Match 'Zusaetzlicher Domaenencontroller'
        ($script:optionen -join ' ') | Should -Match 'nur DNS'
    }
    It 'Arbeitsgruppe: neue Gesamtstruktur, Beitritt + DC, nur Beitritt, ohne AD' {
        $script:z = New-TestZustand -Szenario Frisch
        Mock Get-NetSetupState { $script:z }
        Start-NetAdSetup
        $text = $script:optionen -join ' | '
        $text | Should -Match 'Neue Gesamtstruktur'
        $text | Should -Match 'beitreten und zusaetzlicher DC'
        $text | Should -Match 'nur beitreten'
        $text | Should -Match 'Ohne AD'
    }
    It 'Arbeitsgruppe: "ohne AD" wird gemerkt' {
        $script:z = New-TestZustand -Szenario Frisch
        Mock Get-NetSetupState { $script:z }
        Mock Read-NetChoice { 3 }
        Start-NetAdSetup
        $script:NS.Config.AD.Modus | Should -Be 'OhneAD'
    }
}

Describe 'Heraufstufung zur neuen Gesamtstruktur' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:z = New-TestZustand -Szenario Frisch
        $script:z.Netzwerk.AktiveKarten[0].Dhcp = $false
        Mock Get-NetSetupState { $script:z }
        Mock Test-NetAdNameReady { 'OK' }
        Mock Read-NetSecret { $script:dsrm }
        Mock Install-NetAdRole { $true }
        Mock Install-ADDSForest { }
        Mock Save-NetResumeState { }
        Mock Request-NetRestart { }
        Mock Invoke-NetBackupHook { $true }
    }
    It 'startet nicht, wenn Test-ADDSForestInstallation einen Fehler meldet' {
        Mock Test-ADDSForestInstallation { [pscustomobject]@{ Status = 'Error'; Message = 'Fehler beim Test' } }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } elseif ($Prompt -match 'Domaenenname') { 'ad.firma.ch' } elseif ($Prompt -match 'NetBIOS') { '' } else { 'j' } }
        New-NetForest
        Should -Invoke Install-ADDSForest -Times 0 -Exactly
    }
    It 'startet nicht ohne eingetippten Servernamen' {
        Mock Test-ADDSForestInstallation { [pscustomobject]@{ Status = 'Success'; Message = 'ok' } }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { 'falsch' } elseif ($Prompt -match 'Domaenenname') { 'ad.firma.ch' } elseif ($Prompt -match 'NetBIOS') { '' } else { 'j' } }
        New-NetForest
        Should -Invoke Install-ADDSForest -Times 0 -Exactly
    }
    It 'stuft nach erfolgreichem Test und Servername herauf und plant die Fortsetzung' {
        Mock Test-ADDSForestInstallation { [pscustomobject]@{ Status = 'Success'; Message = 'ok' } }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } elseif ($Prompt -match 'Domaenenname') { 'ad.firma.ch' } elseif ($Prompt -match 'NetBIOS') { '' } elseif ($Prompt -match 'niedrigere') { 'n' } else { 'j' } }
        New-NetForest
        Should -Invoke Install-ADDSForest -Times 1 -Exactly -ParameterFilter { $DomainName -eq 'ad.firma.ch' -and $DomainNetbiosName -eq 'FIRMA' -and $InstallDns -and $SafeModeAdministratorPassword -is [System.Security.SecureString] }
        Should -Invoke Save-NetResumeState -Times 1 -ParameterFilter { $Schritt -eq 'AdNachHeraufstufung' }
        Should -Invoke Request-NetRestart -Times 1
    }
    It 'lehnt einteilige Domaenennamen ab' {
        $script:antworten = [System.Collections.Queue]::new(@('firma', '!'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        Mock Test-ADDSForestInstallation { }
        New-NetForest
        Should -Invoke Test-ADDSForestInstallation -Times 0 -Exactly
    }
}

Describe 'Zusaetzlicher DC' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:z = New-TestZustand -Szenario Mitglied
        Mock Test-NetAdNameReady { 'OK' }
        Mock Read-NetSecret { $script:dsrm }
        Mock Install-NetAdRole { $true }
        Mock Get-Credential { New-Object System.Management.Automation.PSCredential('FIRMA\admin', $script:dsrm) }
        Mock Install-ADDSDomainController { }
        Mock Save-NetResumeState { }
        Mock Request-NetRestart { }
        Mock Invoke-NetBackupHook { $true }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } else { 'j' } }
    }
    It 'stuft erst nach erfolgreichem Test-ADDSDomainControllerInstallation herauf' {
        Mock Test-ADDSDomainControllerInstallation { [pscustomobject]@{ Status = 'Error'; Message = 'kein DC erreichbar' } }
        Add-NetDomainController -Zustand $script:z
        Should -Invoke Install-ADDSDomainController -Times 0 -Exactly
        Mock Test-ADDSDomainControllerInstallation { [pscustomobject]@{ Status = 'Success'; Message = 'ok' } }
        Add-NetDomainController -Zustand $script:z
        Should -Invoke Install-ADDSDomainController -Times 1 -Exactly -ParameterFilter { $DomainName -eq 'ad.firma.ch' -and $Credential }
    }
    It 'verlangt die Mitgliedschaft in der Domaene' {
        Add-NetDomainController -Zustand (New-TestZustand -Szenario Frisch)
        Should -Invoke Install-ADDSDomainController -Times 0 -Exactly
    }
}

Describe 'Neustart und Fortsetzung' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:runOnce = $null
        Mock Set-ItemProperty -ParameterFilter { $Path -like '*RunOnce' } { $script:runOnce = $Value }
        Mock Test-Path -ParameterFilter { $Path -like '*RunOnce' } { $true }
        Mock Remove-ItemProperty -ParameterFilter { $Path -like '*RunOnce' } { $script:runOnce = $null }
        Mock Save-NetSelf { 'C:\NetSetup\NetSetup.ps1' }
    }
    It 'speichert den Stand ohne Kennwoerter und traegt RunOnce mit -Task Resume ein' {
        Save-NetResumeState -Schritt 'AdNachHeraufstufung' -Daten @{ Art = 'Forest'; Domaene = 'ad.firma.ch' } -Beschreibung 'Test'
        $script:runOnce | Should -Match '-Task Resume'
        $script:runOnce | Should -Match 'NetSetup.ps1'
        $stand = Get-NetResumeState
        $stand.Schritt | Should -Be 'AdNachHeraufstufung'
        $stand.Daten.Domaene | Should -Be 'ad.firma.ch'
        (Get-Content -Path (Get-NetPath -Name Fortsetzung) -Raw) | Should -Not -Match 'Password|Kennwort|SecureString'
    }
    It 'setzt nach dem Neustart an der richtigen Stelle fort und raeumt auf' {
        Save-NetResumeState -Schritt 'AdNachHeraufstufung' -Daten @{ Art = 'Forest'; Domaene = 'ad.firma.ch' } -Beschreibung 'Test'
        Mock Complete-NetAdNachHeraufstufung { $script:fortgesetzt = $Daten.Domaene }
        Mock Show-NetStartOverview { }
        Mock Show-NetMainMenu { }
        $script:fortgesetzt = $null
        Resume-NetSetup
        $script:fortgesetzt | Should -Be 'ad.firma.ch'
        Get-NetResumeState | Should -BeNullOrEmpty
        $script:runOnce | Should -BeNullOrEmpty
    }
    It 'nach dem Beitritt geht es mit der DC-Heraufstufung weiter' {
        $script:z = New-TestZustand -Szenario Mitglied
        Mock Get-NetSetupState { $script:z }
        Mock Add-NetDomainController { }
        Complete-NetAdNachBeitritt -Daten @{ Ziel = 'Dc'; Domaene = 'ad.firma.ch' }
        Should -Invoke Add-NetDomainController -Times 1
    }
    It 'nach der Heraufstufung wird der DNS-Client auf den DC selbst gestellt' {
        $script:z = New-TestZustand -Szenario DcDns
        $script:z.Netzwerk.AktiveKarten[0].DnsServer = @('192.168.1.1')
        Mock Get-NetSetupState { $script:z }
        Mock Set-NetDnsClient { $script:dnsSoll = $Server; $true }
        Complete-NetAdNachHeraufstufung -Daten @{ Art = 'Forest'; KarteIndex = 4 }
        $script:dnsSoll | Should -Be @('192.168.1.10', '127.0.0.1')
    }
}

Describe 'Vorpruefungen' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
    }
    It 'bietet bei DHCP-Adresse eine feste IP an' {
        $script:z = New-TestZustand -Szenario Frisch
        Mock Read-NetInput { 'n' }
        Test-NetAdNetworkReady -Zustand $script:z | Should -BeNullOrEmpty
    }
    It 'setzt die feste IP nur nach Servername (Stufe Gefaehrlich)' {
        $karte = (New-TestZustand -Szenario Frisch).Netzwerk.AktiveKarten[0]
        Mock Invoke-NetBackupHook { $true }
        Mock Set-NetIPInterface { }
        Mock Get-NetIPAddress { }
        Mock Remove-NetIPAddress { }
        Mock Get-NetRoute { }
        Mock Remove-NetRoute { }
        Mock New-NetIPAddress { }
        Mock Set-DnsClientServerAddress { }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { 'falsch' } elseif ($Prompt -match 'Ausfuehren') { 'j' } else { '' } }
        Set-NetStaticAddress -Karte $karte | Should -BeFalse
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } elseif ($Prompt -match 'Ausfuehren') { 'j' } else { '' } }
        Set-NetStaticAddress -Karte $karte | Should -BeTrue
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '192.168.1.50' -and $PrefixLength -eq 24 -and $DefaultGateway -eq '192.168.1.1' }
    }
    It 'schlaegt bei automatisch vergebenem Namen die Umbenennung vor' {
        $script:z = New-TestZustand -Szenario Frisch
        $script:z.System.Hostname = 'WIN-ABCDEF12345'
        Mock Rename-NetServer { $true }
        Mock Read-NetInput { 'j' }
        Test-NetAdNameReady -Zustand $script:z -WeiterMit 'Forest' | Should -Be 'Neustart'
        Should -Invoke Rename-NetServer -Times 1 -ParameterFilter { $WeiterMit -eq 'Forest' }
    }
    It 'waehlt die hoechste Funktionsebene ueber den Parametertyp' {
        if (-not ('NetSetupTest.ForestModeTest' -as [type])) {
            Add-Type -TypeDefinition 'namespace NetSetupTest { public enum ForestModeTest { Win2008, Win2012R2, WinThreshold, Win2025, Default } }'
        }
        function Install-ADDSForest { param([NetSetupTest.ForestModeTest]$ForestMode) }
        @(Get-NetAvailableFunctionLevel)[0] | Should -Be 'Win2025'
    }
    It 'Zeitabweichung: keine Antwort liefert $null statt Fehler' {
        Get-NetTimeOffset -Server '192.0.2.1' -TimeoutMs 200 | Should -BeNullOrEmpty
    }
}
