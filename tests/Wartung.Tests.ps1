BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestZustand.ps1')
    $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
    function Initialize-TestDaten {
        $script:NS.Datenpfad = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Initialize-NetFolder | Out-Null
        $script:NS.Config = Get-NetDefaultConfig
        $script:NS.Probelauf = $false
        $script:NS.LogDatei = $null
    }
}

Describe 'Backup' {
    BeforeEach { Initialize-TestDaten }
    It 'sichert die Konfiguration mit info.json' {
        Save-NetConfig
        $ordner = Backup-NetSetupData -Bereich @('Config') -Anlass 'Test'
        Test-Path -Path (Join-Path -Path $ordner -ChildPath 'netsetup.json') | Should -BeTrue
        $info = Get-Content -Path (Join-Path -Path $ordner -ChildPath 'info.json') -Raw | ConvertFrom-Json
        $info.Bereiche | Should -Contain 'Config'
        @(Get-NetBackupList).Count | Should -Be 1
    }
    It 'behaelt nur die eingestellte Anzahl Backups' {
        $script:NS.Config.Allgemein.BackupAufbewahrung = 3
        1..5 | ForEach-Object { Backup-NetSetupData -Bereich @('Config') -Anlass "Nr$_" | Out-Null }
        @(Get-NetBackupList).Count | Should -Be 3
        (@(Get-NetBackupList)[0]).Anlass | Should -Be 'Nr5'
    }
    It 'sichert DHCP (Datenbank und Export mit Leases) und DNS (Zonen und CSV)' {
        Mock Test-NetDhcpReady { $true }
        Mock Test-NetDnsReady { $true }
        Mock Export-DhcpServer { Set-Content -Path $File -Value '<DHCPServer/>' }
        Mock Backup-DhcpServer { New-Item -Path $Path -ItemType Directory -Force | Out-Null; Set-Content -Path (Join-Path -Path $Path -ChildPath 'dhcp.mdb') -Value 'x' }
        Mock Get-NetWindowsPath { Join-Path -Path $TestDrive -ChildPath ($Unterpfad -replace '\\', '_') }
        Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = 'ad.firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false } }
        Mock Export-DnsServerZone { }
        Mock Get-DnsServerResourceRecord { [pscustomobject]@{ HostName = 'srv01'; RecordType = 'A'; RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('192.168.1.20') }; Timestamp = $null; TimeToLive = '01:00:00' } }
        Mock Get-DnsServerForwarder { }
        $ordner = Backup-NetSetupData -Bereich @('Dhcp', 'Dns') -Anlass 'Test'
        Should -Invoke Export-DhcpServer -Times 1 -Exactly -ParameterFilter { $Leases }
        Should -Invoke Backup-DhcpServer -Times 1 -Exactly
        Should -Invoke Export-DnsServerZone -Times 1 -Exactly -ParameterFilter { $Name -eq 'ad.firma.ch' }
        $csv = @(Import-Csv -Path (Join-Path -Path $ordner -ChildPath 'Dns/eintraege.csv') -Delimiter ';')
        $csv[0].Wert | Should -Be '192.168.1.20'
        Test-Path -Path (Join-Path -Path $ordner -ChildPath 'Dhcp/Datenbank/dhcp.mdb') | Should -BeTrue
    }
    It 'vor einer gefaehrlichen Aenderung liegt ein Backup vor' {
        Save-NetConfig
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } else { 'j' } }
        $script:backupsWaehrendAktion = -1
        Invoke-NetChange -Titel 'Test' -Stufe Gefaehrlich -BackupBereich @('Config') -Aktion { $script:backupsWaehrendAktion = @(Get-NetBackupList).Count } | Out-Null
        $script:backupsWaehrendAktion | Should -Be 1
    }
}

Describe 'Rueckgaengig' {
    BeforeEach { Initialize-TestDaten }
    It 'stellt den alten Zustand her (Weiterleitungen)' {
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-DnsServerForwarder { [pscustomobject]@{ IPAddress = @([System.Net.IPAddress]::Parse('8.8.8.8')) } }
        Mock Resolve-DnsName { 'ok' }
        Mock Set-DnsServerForwarder { }
        Mock Read-NetInput { 'j' }
        Set-NetDnsForwarder -Adressen @('9.9.9.9') | Should -BeTrue
        Undo-NetLastChange
        Should -Invoke Set-DnsServerForwarder -Times 1 -Exactly -ParameterFilter { ($IPAddress -join ',') -eq '8.8.8.8' }
        @(Get-NetUndoEntry -NurOffen).Count | Should -Be 0
    }
}

Describe 'CSV-Import' {
    BeforeEach {
        Initialize-TestDaten
        Mock Test-NetDnsReady { $true }
        Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = 'ad.firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false } }
        Mock Get-DnsServerResourceRecord { }
        Mock Add-NetDnsRecordExact { }
        Mock Remove-NetDnsRecordExact { }
        Mock Read-NetInput { 'j' }
        $script:csv = Join-Path -Path $TestDrive -ChildPath 'import.csv'
    }
    It 'meldet fehlerhafte Zeilen vorher und importiert dann nichts' {
        Set-Content -Path $script:csv -Value @('Zone;Name;Typ;Wert;Prioritaet;Gewicht;Port', 'ad.firma.ch;pc01;A;192.168.1.50;;;', 'ad.firma.ch;pc02;A;999.1.1.1;;;', 'gibtsnicht.ch;pc03;A;192.168.1.52;;;')
        Import-NetCsv -Art Dns -Datei $script:csv | Should -BeFalse
        Should -Invoke Add-NetDnsRecordExact -Times 0 -Exactly
        $e = Test-NetDnsImport -Zeilen @(Import-Csv -Path $script:csv -Delimiter ';')
        @($e.Fehler).Count | Should -Be 2
        ($e.Fehler -join ' ') | Should -Match 'Zeile 3'
        ($e.Fehler -join ' ') | Should -Match 'Zeile 4'
    }
    It 'importiert gueltige Zeilen nach Bestaetigung' {
        Copy-Item -Path (Join-Path -Path $script:repoRoot -ChildPath 'config/dns-eintraege.example.csv') -Destination $script:csv
        Import-NetCsv -Art Dns -Datei $script:csv | Should -BeTrue
        Should -Invoke Add-NetDnsRecordExact -Times 5 -Exactly
    }
    It 'erkennt doppelte Zeilen in der Datei' {
        Set-Content -Path $script:csv -Value @('Zone;Name;Typ;Wert;Prioritaet;Gewicht;Port', 'ad.firma.ch;pc01;A;192.168.1.50;;;', 'ad.firma.ch;pc01;A;192.168.1.50;;;')
        Import-NetCsv -Art Dns -Datei $script:csv | Should -BeFalse
        Should -Invoke Add-NetDnsRecordExact -Times 0 -Exactly
    }
    It 'nimmt bei einem Fehler waehrend des Imports alles zurueck (nichts halb importiert)' {
        Set-Content -Path $script:csv -Value @('Zone;Name;Typ;Wert;Prioritaet;Gewicht;Port', 'ad.firma.ch;pc01;A;192.168.1.50;;;', 'ad.firma.ch;pc02;A;192.168.1.51;;;', 'ad.firma.ch;pc03;A;192.168.1.52;;;')
        $script:zaehler = 0
        Mock Add-NetDnsRecordExact { $script:zaehler++; if ($script:zaehler -eq 3) { throw 'Server weg' } }
        Import-NetCsv -Art Dns -Datei $script:csv | Should -BeFalse
        Should -Invoke Remove-NetDnsRecordExact -Times 2 -Exactly
    }
    It 'prueft Reservierungen (Scope, Bereich, MAC, doppelte IP)' {
        Mock Test-NetDhcpReady { $true }
        Mock Get-DhcpServerv4Scope { [pscustomobject]@{ ScopeId = [System.Net.IPAddress]::Parse('192.168.1.0'); Name = 'LAN'; StartRange = '192.168.1.100'; EndRange = '192.168.1.199'; SubnetMask = '255.255.255.0'; State = 'Active'; LeaseDuration = [timespan]::FromDays(8) } }
        Mock Get-DhcpServerv4ExclusionRange { }
        Mock Get-DhcpServerv4Reservation { }
        Mock Get-DhcpServerv4Lease { }
        Mock Add-DhcpServerv4Reservation { }
        Set-Content -Path $script:csv -Value @('ScopeId;IP;MAC;Name;Beschreibung', '192.168.1.0;192.168.1.150;00-15-5D-01-02-03;drucker;', '192.168.1.0;192.168.1.150;00-15-5D-01-02-04;telefon;', '10.0.0.0;10.0.0.5;00-15-5D-01-02-05;x;', '192.168.1.0;192.168.1.20;zz;y;')
        Import-NetCsv -Art Reservierung -Datei $script:csv | Should -BeFalse
        Should -Invoke Add-DhcpServerv4Reservation -Times 0 -Exactly
        Copy-Item -Path (Join-Path -Path $script:repoRoot -ChildPath 'config/reservierungen.example.csv') -Destination $script:csv -Force
        Import-NetCsv -Art Reservierung -Datei $script:csv | Should -BeTrue
        Should -Invoke Add-DhcpServerv4Reservation -Times 2 -Exactly
    }
    It 'legt Vorlagen an und ueberschreibt sie nicht' {
        New-NetImportTemplate
        $datei = Join-Path -Path (Get-NetPath -Name Vorlagen) -ChildPath 'dns-eintraege.csv'
        Test-Path -Path $datei | Should -BeTrue
        Set-Content -Path $datei -Value 'eigene'
        New-NetImportTemplate
        (Get-Content -Path $datei -Raw).Trim() | Should -Be 'eigene'
    }
    It 'die Vorlagen im Script stimmen mit config/*.example.csv ueberein' {
        (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'config/dns-eintraege.example.csv')) | Should -Be $script:NetVorlageDns
        (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'config/reservierungen.example.csv')) | Should -Be $script:NetVorlageReservierung
    }
}

Describe 'Berichte' {
    BeforeEach {
        Initialize-TestDaten
        $script:z = New-TestZustand -Szenario DcDhcp
        Mock Get-NetSetupState { $script:z }
        Mock Get-NetLeaseDnsCheck { [pscustomobject]@{ IP = '192.168.1.121'; Name = 'pc02<script>'; A = $false; PTR = $true; Ursache = 'Test' } }
        Mock Get-DhcpServerv4ExclusionRange { [pscustomobject]@{ StartRange = '192.168.1.100'; EndRange = '192.168.1.109' } }
        Mock Get-DhcpServerv4Reservation { [pscustomobject]@{ IPAddress = '192.168.1.150' } }
        Mock Get-DhcpServerv4Lease { [pscustomobject]@{ IPAddress = '192.168.1.110' } }
        $script:doktor = @([pscustomobject]@{ Id = 'R01'; Kategorie = 'Rechte'; Titel = 'Admin'; Status = 'OK'; Detail = 'ok'; Problem = 'p' })
    }
    It 'HTML ohne externe Links, Schriften oder Scripts' {
        $datei = New-NetReport -DoktorErgebnis $script:doktor
        $html = Get-Content -Path $datei -Raw
        $html | Should -Not -Match '(?i)https?://|<link|<script|src=|@import|url\('
        $html | Should -Match 'Scope-Auslastung'
        $html | Should -Match 'Leases ohne DNS-Eintrag'
        $html | Should -Match 'pc02&lt;script&gt;'
        @(Get-ChildItem -Path (Get-NetPath -Name Berichte) -Filter '*.csv').Count | Should -Be 5
    }
    It 'berechnet freie Adressbereiche' {
        $f = Get-NetFreeAddressRange -ScopeId '192.168.1.0' -Start '192.168.1.100' -Ende '192.168.1.199'
        $f.Frei | Should -Be 88
        $f.Bereiche | Should -Be @('192.168.1.111 - 192.168.1.149', '192.168.1.151 - 192.168.1.199')
    }
}

Describe 'Wiederherstellen DNS' {
    BeforeEach { Initialize-TestDaten }
    It 'legt nur fehlende Eintraege aus der CSV an' {
        $backup = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath '20260101_100000_000_test'
        New-Item -Path (Join-Path -Path $backup -ChildPath 'Dns') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path -Path $backup -ChildPath 'info.json') -Value '{ "Zeit": "2026-01-01 10:00:00", "Anlass": "test", "Bereiche": ["Dns"], "Server": "DC01" }'
        @(
            [pscustomobject]@{ Zone = 'ad.firma.ch'; Name = 'srv01'; Typ = 'A'; Wert = '192.168.1.20'; Statisch = 'True'; Ttl = ''; Daten = '{"IPv4Address":"192.168.1.20"}' },
            [pscustomobject]@{ Zone = 'ad.firma.ch'; Name = 'srv02'; Typ = 'A'; Wert = '192.168.1.21'; Statisch = 'True'; Ttl = ''; Daten = '{"IPv4Address":"192.168.1.21"}' }
        ) | Export-Csv -Path (Join-Path -Path $backup -ChildPath 'Dns/eintraege.csv') -NoTypeInformation -Delimiter ';'
        Mock Test-NetDnsReady { $true }
        Mock Get-DnsServerZone { [pscustomobject]@{ ZoneName = 'ad.firma.ch'; ZoneType = 'Primary'; IsDsIntegrated = $true; IsReverseLookupZone = $false; DynamicUpdate = 'Secure'; ReplicationScope = 'Domain'; IsAutoCreated = $false } }
        Mock Get-DnsServerResourceRecord { [pscustomobject]@{ HostName = 'srv01'; RecordType = 'A'; RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('192.168.1.20') }; Timestamp = $null } }
        Mock Add-NetDnsRecordExact { }
        Mock Invoke-NetBackupHook { $true }
        Mock Read-NetInput { if ($Prompt -match 'Servernamen') { [Environment]::MachineName } elseif ($Prompt -match 'Nummern') { '*' } elseif ($Prompt -match 'Nummer') { '1' } else { 'j' } }
        Restore-NetDnsBackup | Should -BeTrue
        Should -Invoke Add-NetDnsRecordExact -Times 1 -Exactly -ParameterFilter { $Name -eq 'srv02' }
    }
}

Describe 'Geplante Aufgabe' {
    BeforeEach { Initialize-TestDaten }
    It 'legt die taegliche Pruefung mit -Task Health als SYSTEM an' {
        Mock Get-ScheduledTask { throw 'nicht vorhanden' }
        Mock Save-NetSelf { 'C:\NetSetup\NetSetup.ps1' }
        Mock New-ScheduledTaskAction { [pscustomobject]@{ Argument = $Argument } }
        Mock New-ScheduledTaskTrigger { 'trigger' }
        Mock New-ScheduledTaskPrincipal { 'principal' }
        Mock New-ScheduledTaskSettingsSet { 'settings' }
        Mock Register-ScheduledTask { }
        Mock Read-NetInput { if ($Prompt -match 'Uhrzeit') { '' } else { 'j' } }
        Register-NetHealthTask | Should -BeTrue
        Should -Invoke New-ScheduledTaskAction -Times 1 -Exactly -ParameterFilter { $Argument -match '-Task Health' -and $Argument -match 'NetSetup.ps1' }
        Should -Invoke New-ScheduledTaskPrincipal -Times 1 -Exactly -ParameterFilter { $UserId -eq 'SYSTEM' }
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    }
}
