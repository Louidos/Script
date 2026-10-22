BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
}

Describe 'IP-Hilfsfunktionen' {
    It 'erkennt gueltige und ungueltige IPv4-Adressen' {
        Test-NetIPv4Address -Text '192.168.1.10' | Should -BeTrue
        Test-NetIPv4Address -Text '256.1.1.1' | Should -BeFalse
        Test-NetIPv4Address -Text '192.168.1' | Should -BeFalse
        Test-NetIPv4Address -Text '192.168.01.1' | Should -BeFalse
        Test-NetIPv4Address -Text 'abc' | Should -BeFalse
    }
    It 'rechnet Praefix und Maske um' {
        ConvertTo-NetSubnetMask -PrefixLength 24 | Should -Be '255.255.255.0'
        ConvertTo-NetSubnetMask -PrefixLength 22 | Should -Be '255.255.252.0'
        ConvertTo-NetSubnetMask -PrefixLength 32 | Should -Be '255.255.255.255'
        ConvertTo-NetPrefixLength -SubnetMask '255.255.255.0' | Should -Be 24
        ConvertTo-NetPrefixLength -SubnetMask '255.255.0.255' | Should -Be -1
    }
    It 'berechnet Netz- und Broadcastadresse' {
        Get-NetNetworkAddress -IPAddress '192.168.1.77' -PrefixLength 24 | Should -Be '192.168.1.0'
        Get-NetBroadcastAddress -IPAddress '10.0.5.1' -PrefixLength 22 | Should -Be '10.0.7.255'
    }
    It 'prueft Adressbereiche fuer Scopes' {
        Test-NetIPRange -Start '192.168.1.100' -Ende '192.168.1.200' -NetworkAddress '192.168.1.0' -PrefixLength 24 | Should -BeNullOrEmpty
        Test-NetIPRange -Start '192.168.1.200' -Ende '192.168.1.100' -NetworkAddress '192.168.1.0' -PrefixLength 24 | Should -Match 'kleiner'
        Test-NetIPRange -Start '192.168.2.10' -Ende '192.168.2.20' -NetworkAddress '192.168.1.0' -PrefixLength 24 | Should -Match 'nicht im Netz'
        Test-NetIPRange -Start '192.168.1.0' -Ende '192.168.1.20' -NetworkAddress '192.168.1.0' -PrefixLength 24 | Should -Match 'Netzadresse'
        Test-NetIPRange -Start '192.168.1.10' -Ende '192.168.1.255' -NetworkAddress '192.168.1.0' -PrefixLength 24 | Should -Match 'Broadcast'
    }
    It 'liefert Reverse-Zonen und PTR-Namen' {
        Get-NetReverseZoneName -NetworkAddress '192.168.1.0' -PrefixLength 24 | Should -Be '1.168.192.in-addr.arpa'
        Get-NetReverseZoneName -NetworkAddress '10.20.0.0' -PrefixLength 16 | Should -Be '20.10.in-addr.arpa'
        @(Get-NetReverseZoneName -NetworkAddress '10.0.4.0' -PrefixLength 22) | Should -Be @('4.0.10.in-addr.arpa', '5.0.10.in-addr.arpa', '6.0.10.in-addr.arpa', '7.0.10.in-addr.arpa')
        Get-NetPtrName -IPAddress '192.168.1.50' -ZoneName '1.168.192.in-addr.arpa' | Should -Be '50'
        Get-NetPtrName -IPAddress '10.20.3.4' -ZoneName '20.10.in-addr.arpa' | Should -Be '4.3'
        Get-NetPtrName -IPAddress '10.21.3.4' -ZoneName '20.10.in-addr.arpa' | Should -BeNullOrEmpty
        Find-NetReverseZone -IPAddress '10.20.3.4' -ZoneNames @('20.10.in-addr.arpa', '3.20.10.in-addr.arpa', 'ad.firma.ch') | Should -Be '3.20.10.in-addr.arpa'
    }
    It 'prueft Computer- und Domaenennamen' {
        Test-NetHostName -Name 'DC01' | Should -BeNullOrEmpty
        Test-NetHostName -Name 'EIN-VIEL-ZU-LANGER-NAME' | Should -Match '15'
        Test-NetHostName -Name '1234' | Should -Match 'Ziffern'
        (Test-NetDomainName -Name 'ad.firma.ch').Gueltig | Should -BeTrue
        (Test-NetDomainName -Name 'firma').Gueltig | Should -BeFalse
        (Test-NetDomainName -Name 'firma.local').Warnungen -join ' ' | Should -Match 'local'
        Get-NetNetBiosSuggestion -DomainName 'ad.firma.ch' | Should -Be 'FIRMA'
    }
}

Describe 'Konfiguration' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.LogDatei = $null
    }
    It 'Standardkonfiguration ist gueltig' {
        @(Test-NetConfig -Config (Get-NetDefaultConfig)).Count | Should -Be 0
    }
    It 'speichert und laedt die Konfiguration (Rundreise)' {
        $c = Get-NetDefaultConfig
        $c.Vorschlaege.LeaseTage = 3
        Save-NetConfig -Config $c
        $neu = Import-NetConfig
        $neu.Vorschlaege.LeaseTage | Should -Be 3
        $neu.Vorschlaege.Weiterleitungen | Should -Contain '9.9.9.9'
    }
    It 'ergaenzt fehlende Werte aus der Vorlage' {
        Set-Content -Path (Get-NetPath -Name ConfigDatei) -Value '{ "SchemaVersion": 1, "Allgemein": { "Probelauf": false } }'
        $c = Import-NetConfig
        $c.Allgemein.BackupAufbewahrung | Should -Be 20
        $c.Vorschlaege.LeaseTage | Should -Be 8
    }
    It 'sichert eine beschaedigte Datei und verwendet Standardwerte' {
        Set-Content -Path (Get-NetPath -Name ConfigDatei) -Value '{ kaputt'
        $c = Import-NetConfig
        $c.SchemaVersion | Should -Be 1
        @(Get-ChildItem -Path (Get-NetPath -Name Config) -Filter '*.defekt_*').Count | Should -Be 1
    }
    It 'meldet ungueltige Werte' {
        $c = Get-NetDefaultConfig
        $c.Vorschlaege.Weiterleitungen = @('999.1.1.1')
        $c.Allgemein.BackupAufbewahrung = 0
        @(Test-NetConfig -Config $c).Count | Should -Be 2
    }
    It 'liest Werte ueber einen Pfad' {
        $script:NS.Config = Get-NetDefaultConfig
        Get-NetConfigValue -Pfad 'Vorschlaege.LeaseTage' | Should -Be 8
        Get-NetConfigValue -Pfad 'Gibt.Es.Nicht' -Standard 'x' | Should -Be 'x'
    }
}

Describe 'Fehlerbehandlung' {
    It 'uebersetzt fehlende Befehle mit der passenden Rolle' {
        $ex = New-Object System.Management.Automation.CommandNotFoundException('fehlt')
        $ex.CommandName = 'Get-DhcpServerv4Scope'
        $info = Get-NetErrorInfo -Fehler $ex
        $info.Code | Should -Be 'BefehlFehlt'
        $info.NaechsterSchritt | Should -Match 'RSAT-DHCP'
    }
    It 'uebersetzt Zugriff verweigert' {
        (Get-NetErrorInfo -Fehler (New-Object System.UnauthorizedAccessException('nein'))).Code | Should -Be 'Zugriff'
    }
    It 'wertet Win32-Fehlernummern statt Texten aus' {
        $record = New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception('egal in welcher Sprache')), 'WIN32 9601,Get-DnsServerZone', 'ObjectNotFound', $null)
        (Get-NetErrorInfo -Fehler $record).Code | Should -Be 'NichtGefunden'
    }
    It 'Invoke-NetStep stuerzt nie ab' {
        $r = Invoke-NetStep -Titel 'Test' -Aktion { throw 'kaputt' } -Still
        $r.Erfolg | Should -BeFalse
        $r.Fehler.Ursache | Should -Not -BeNullOrEmpty
        (Invoke-NetStep -Titel 'Test' -Aktion { 42 } -Still).Ergebnis | Should -Be 42
    }
    It 'Get-NetSafe liefert bei Fehler den Rueckfallwert' {
        Get-NetSafe -Abfrage { Get-DnsServerZone } -Standard 'leer' | Should -Be 'leer'
    }
}

Describe 'Invoke-NetChange' {
    BeforeEach {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Probelauf = $false
        $script:zaehler = 0
    }
    It 'fuehrt im Probelauf nichts aus' {
        $script:NS.Probelauf = $true
        Mock Read-NetInput { 'j' }
        $r = Invoke-NetChange -Titel 'Test' -Aktion { $script:zaehler++ }
        $r.Probelauf | Should -BeTrue
        $script:zaehler | Should -Be 0
    }
    It 'fuehrt bei Nein nichts aus' {
        Mock Read-NetInput { 'n' }
        $r = Invoke-NetChange -Titel 'Test' -Vorher 'a' -Nachher 'b' -Aktion { $script:zaehler++ }
        $r.Abgebrochen | Should -BeTrue
        $script:zaehler | Should -Be 0
    }
    It 'fuehrt bei Ja aus und merkt die Gegenaktion' {
        Mock Read-NetInput { 'j' }
        $r = Invoke-NetChange -Titel 'Zone anlegen' -Aktion { $script:zaehler++ } -Rueckgaengig @{ Befehl = 'Remove-DnsServerZone'; Parameter = @{ Name = 'x'; Force = $true } }
        $r.Erfolg | Should -BeTrue
        $script:zaehler | Should -Be 1
        $liste = @(Get-NetUndoEntry)
        $liste.Count | Should -Be 1
        $liste[0].Schritte[0].Befehl | Should -Be 'Remove-DnsServerZone'
    }
    It 'verlangt bei Gefaehrlich den Servernamen' {
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { 'falsch' } else { 'j' } }
        $r = Invoke-NetChange -Titel 'Zone loeschen' -Stufe Gefaehrlich -Aktion { $script:zaehler++ }
        $r.Abgebrochen | Should -BeTrue
        $script:zaehler | Should -Be 0
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } else { 'j' } }
        $r = Invoke-NetChange -Titel 'Zone loeschen' -Stufe Gefaehrlich -Aktion { $script:zaehler++ }
        $r.Erfolg | Should -BeTrue
        $script:zaehler | Should -Be 1
    }
    It 'Automatisch fragt nicht nach' {
        Mock Read-NetInput { throw 'darf nicht fragen' }
        (Invoke-NetChange -Titel 'Dienst starten' -Stufe Automatisch -Aktion { $script:zaehler++ }).Erfolg | Should -BeTrue
        $script:zaehler | Should -Be 1
    }
    It 'beachtet -WhatIf' {
        Mock Read-NetInput { 'j' }
        $r = Invoke-NetChange -Titel 'Test' -Aktion { $script:zaehler++ } -WhatIf
        $r.Probelauf | Should -BeTrue
        $script:zaehler | Should -Be 0
    }
    It 'nimmt eine Aenderung zurueck' {
        function Remove-NetTestObjekt { param($Name) $script:entfernt = $Name }
        Mock Read-NetInput { 'j' }
        Invoke-NetChange -Titel 'Objekt anlegen' -Aktion { 1 } -Rueckgaengig @{ Befehl = 'Remove-NetTestObjekt'; Parameter = @{ Name = 'abc' } } | Out-Null
        $id = @(Get-NetUndoEntry)[0].Id
        Undo-NetChange -Id $id | Should -BeTrue
        $script:entfernt | Should -Be 'abc'
        @(Get-NetUndoEntry)[0].Status | Should -Be 'Rueckgaengig'
    }
    It 'erlaubt keine fremden Befehle als Gegenaktion' {
        Test-NetUndoCommand -Befehl 'Invoke-Expression' | Should -BeFalse
    }
}

Describe 'Argumente (-Task)' {
    It 'liest -Task mit Leerzeichen und Doppelpunkt' {
        (ConvertFrom-NetArgument -Argumente @('-Task', 'health')).Task | Should -Be 'Health'
        (ConvertFrom-NetArgument -Argumente @('-Task:Report')).Task | Should -Be 'Report'
    }
    It 'meldet unbekannte Aufgaben' {
        (ConvertFrom-NetArgument -Argumente @('-Task', 'Kaffee')).Fehler | Should -Match 'Health'
    }
    It 'erkennt -WhatIf als Probelauf' {
        (ConvertFrom-NetArgument -Argumente @('-WhatIf')).Probelauf | Should -BeTrue
    }
    It 'ruft fuer fehlende Aufgaben "kommt noch" statt eines Fehlers' {
        Mock Test-NetCommand { $false }
        { Invoke-NetTask -Name 'Report' } | Should -Not -Throw
    }
}

Describe 'Voraussetzungen' {
    It 'bricht auf Windows 10/11 verstaendlich ab' {
        $u = [pscustomobject]@{ IstWindows = $true; PsVersion = [version]'5.1'; PsEdition = 'Desktop'; ProductType = 1; OsName = 'Windows 11 Pro'; IstAdmin = $true }
        Test-NetPrerequisite -Umgebung $u | Should -Be 'Abbruch'
    }
    It 'bietet ohne Adminrechte den Neustart an' {
        $u = [pscustomobject]@{ IstWindows = $true; PsVersion = [version]'5.1'; PsEdition = 'Desktop'; ProductType = 3; OsName = 'Windows Server 2022'; IstAdmin = $false }
        Mock Read-NetInput { 'n' }
        Test-NetPrerequisite -Umgebung $u | Should -Be 'Abbruch'
        Mock Read-NetInput { 'j' }
        Mock Request-NetElevation { $true }
        Test-NetPrerequisite -Umgebung $u | Should -Be 'NeuGestartet'
    }
    It 'akzeptiert Windows Server mit Adminrechten' {
        $u = [pscustomobject]@{ IstWindows = $true; PsVersion = [version]'5.1'; PsEdition = 'Desktop'; ProductType = 2; OsName = 'Windows Server 2019'; IstAdmin = $true }
        Test-NetPrerequisite -Umgebung $u | Should -Be 'OK'
    }
}

Describe 'Format-NetValue' {
    It 'formatiert Hashtables sortiert' {
        Format-NetValue -Wert @{ b = 2; a = 1 } | Should -Be @('a = 1', 'b = 2')
        Format-NetValue -Wert $null | Should -Be '(nichts)'
    }
}
