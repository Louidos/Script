BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
}

Describe 'Eingaben' {
    It 'Read-NetYesNo versteht j, n und Enter' {
        Mock Read-NetInput { 'j' }
        Read-NetYesNo -Frage 'x' -Vorschlag $false | Should -BeTrue
        Mock Read-NetInput { 'nein' }
        Read-NetYesNo -Frage 'x' | Should -BeFalse
        Mock Read-NetInput { '' }
        Read-NetYesNo -Frage 'x' -Vorschlag $true | Should -BeTrue
    }
    It 'Read-NetIPAddress lehnt ungueltige Werte ab und fragt erneut' {
        $script:antworten = [System.Collections.Queue]::new(@('300.1.1.1', '10.0.0.5'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        Read-NetIPAddress -Frage 'IP' | Should -Be '10.0.0.5'
        Should -Invoke Read-NetInput -Times 2 -Exactly
    }
    It 'Read-NetIPAddress prueft das Subnetz' {
        $script:antworten = [System.Collections.Queue]::new(@('10.0.1.5', '10.0.0.5'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        Read-NetIPAddress -Frage 'IP' -Netz '10.0.0.0' -Prefix 24 | Should -Be '10.0.0.5'
    }
    It 'Enter uebernimmt den Vorschlag, ! bricht ab' {
        Mock Read-NetInput { '' }
        Read-NetText -Frage 'Name' -Vorschlag 'DC01' | Should -Be 'DC01'
        Mock Read-NetInput { '!' }
        Read-NetText -Frage 'Name' -Vorschlag 'DC01' | Should -BeNullOrEmpty
    }
    It 'Read-NetNumber prueft Grenzen' {
        $script:antworten = [System.Collections.Queue]::new(@('abc', '0', '5'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        Read-NetNumber -Frage 'Tage' -Minimum 1 -Maximum 10 | Should -Be 5
    }
    It 'ConvertTo-NetSubnet versteht Praefix und Maske' {
        (ConvertTo-NetSubnet -Text '192.168.1.0/24').Maske | Should -Be '255.255.255.0'
        (ConvertTo-NetSubnet -Text '10.0.0.0 255.255.0.0').Prefix | Should -Be 16
        (ConvertTo-NetSubnet -Text '192.168.1.77/24').Netz | Should -Be '192.168.1.0'
        ConvertTo-NetSubnet -Text '192.168.1.0 255.0.255.0' | Should -BeNullOrEmpty
    }
    It 'Read-NetChoice liefert den Index' {
        Mock Read-NetInput { '2' }
        Read-NetChoice -Frage 'Was?' -Optionen @('a', 'b', 'c') | Should -Be 1
    }
    It 'ConvertTo-NetNumberList versteht Bereiche' {
        ConvertTo-NetNumberList -Text '1,3-5' -Maximum 6 -Mehrfach | Should -Be @(1, 3, 4, 5)
        ConvertTo-NetNumberList -Text '*' -Maximum 3 -Mehrfach | Should -Be @(1, 2, 3)
        ConvertTo-NetNumberList -Text '7' -Maximum 6 | Should -BeNullOrEmpty
        ConvertTo-NetNumberList -Text '1,2' -Maximum 6 | Should -BeNullOrEmpty
    }
    It 'Read-NetSecret verlangt Komplexitaet und gleiche Wiederholung' {
        $schwach = ConvertTo-SecureString -String 'abc' -AsPlainText -Force
        $stark = ConvertTo-SecureString -String 'Sicher!2026' -AsPlainText -Force
        $script:antworten = [System.Collections.Queue]::new(@($schwach, $stark, $stark))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        $r = Read-NetSecret -Frage 'Kennwort' -Komplex -Bestaetigen
        $r | Should -BeOfType [System.Security.SecureString]
        Should -Invoke Read-NetInput -Times 3 -Exactly
    }
}

Describe 'Bestaetigungen' {
    It 'Confirm-NetDangerous verlangt den Servernamen' {
        Mock Read-NetInput { [Environment]::MachineName.ToLower() }
        Confirm-NetDangerous -Titel 'x' | Should -BeTrue
        Mock Read-NetInput { 'anderer' }
        Confirm-NetDangerous -Titel 'x' | Should -BeFalse
    }
    It 'Confirm-NetChange schlaegt Nein vor' {
        Mock Read-NetInput { '' }
        Confirm-NetChange -Titel 'x' -Vorher 'a' -Nachher 'b' | Should -BeFalse
    }
}

Describe 'Auswahl' {
    It 'Select-NetItem waehlt per Nummer, wenn kein Auswahlfenster da ist' {
        Mock Read-NetInput { '2' }
        $e = Select-NetItem -Elemente @(@{ Name = 'a' }, @{ Name = 'b' }) -Eigenschaften 'Name'
        $e.Name | Should -Be 'b'
    }
    It 'Select-NetItem liefert $null bei Abbruch und leerer Liste' {
        Mock Read-NetInput { '0' }
        Select-NetItem -Elemente @('x', 'y') | Should -BeNullOrEmpty
        Select-NetItem -Elemente @() | Should -BeNullOrEmpty
    }
}

Describe 'Menue' {
    It 'fuehrt einen Punkt aus und beendet mit 0' {
        $script:aufgerufen = 0
        $script:antworten = [System.Collections.Queue]::new(@('1', '', '0'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        Show-NetMenu -Titel 'Test' -Eintraege @(@{ Text = 'Eins'; Aktion = { $script:aufgerufen++ }; Hilfe = 'h' })
        $script:aufgerufen | Should -Be 1
    }
    It 'zeigt fuer fehlende Funktionen "kommt noch" statt eines Fehlers' {
        $script:antworten = [System.Collections.Queue]::new(@('1', '', '?1', '', 'G', '', 'x', '0'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        { Show-NetMenu -Titel 'Test' -Eintraege @(@{ Text = 'Spaeter'; Aktion = 'Show-NetGibtEsNicht'; Hilfe = 'h' }) } | Should -Not -Throw
    }
    It 'Fehler in einem Punkt beenden das Menue nicht' {
        $script:antworten = [System.Collections.Queue]::new(@('1', '', '0'))
        Mock Read-NetInput { $script:antworten.Dequeue() }
        { Show-NetMenu -Titel 'Test' -Eintraege @(@{ Text = 'Kaputt'; Aktion = { throw 'boom' }; Hilfe = 'h' }) } | Should -Not -Throw
    }
}

Describe 'Hauptmenue, Hilfe und Glossar' {
    It 'enthaelt alle geplanten Punkte mit Hilfe' {
        $e = Get-NetMainMenuEntry
        $texte = $e | ForEach-Object { $_.Text }
        foreach ($erwartet in @('Ersteinrichtung', 'Active Directory', 'DNS', 'DHCP', 'DHCP \+ DNS', 'Doktor', 'Berichte', 'Backup', 'Erweitert', 'Hilfe', 'Einstellungen')) {
            ($texte -match $erwartet).Count | Should -BeGreaterThan 0 -Because "Punkt $erwartet fehlt"
        }
        foreach ($eintrag in $e) { $eintrag.Hilfe | Should -Not -BeNullOrEmpty }
    }
    It 'Glossar enthaelt alle Pflichtbegriffe' {
        foreach ($b in @('Lease', 'Scope', 'Ausschluss', 'Reservierung', 'Option', 'Autorisierung', 'Failover', 'Zone', 'Reverse-Zone', 'PTR', 'Weiterleitung', 'Stammhinweise', 'Aging/Scavenging', 'Dynamisches Update', 'DSRM', 'Gesamtstruktur')) {
            $script:NetGlossar.Contains($b) | Should -BeTrue -Because "Begriff $b fehlt"
        }
    }
    It 'Glossar und Hilfe sind reines ASCII' {
        foreach ($t in $script:NetGlossar.Values) { $t | Should -Not -Match '[^\x20-\x7E]' }
    }
}
