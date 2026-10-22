# Testdaten: Zustaende (wie Get-NetSetupState sie liefert) und Mocks fuer typische Ausgangslagen.
#   Frisch  = frischer Server in einer Arbeitsgruppe, IP per DHCP, keine Rollen
#   DcDns   = Domaenencontroller nur mit DNS
#   DcDhcp  = Domaenencontroller mit fertig eingerichtetem DHCP

function New-TestZustand {
    param([ValidateSet('Frisch', 'DcDns', 'DcDhcp', 'Mitglied')][string]$Szenario = 'DcDhcp')
    $dc = $Szenario -like 'Dc*'
    $features = @{ 'AD-Domain-Services' = 'Available'; DNS = 'Available'; DHCP = 'Available'; 'RSAT-AD-PowerShell' = 'Available'; 'RSAT-ADDS' = 'Available'; 'RSAT-DNS-Server' = 'Available'; 'RSAT-DHCP' = 'Available' }
    $dienste = @{
        NTDS       = @{ Vorhanden = $false; Status = 'Fehlt'; StartTyp = '' }
        Netlogon   = @{ Vorhanden = $true; Status = 'Stopped'; StartTyp = 'Manual' }
        DNS        = @{ Vorhanden = $false; Status = 'Fehlt'; StartTyp = '' }
        DHCPServer = @{ Vorhanden = $false; Status = 'Fehlt'; StartTyp = '' }
        W32Time    = @{ Vorhanden = $true; Status = 'Running'; StartTyp = 'Automatic' }
    }
    if ($dc) {
        foreach ($f in @('AD-Domain-Services', 'DNS', 'RSAT-AD-PowerShell', 'RSAT-ADDS', 'RSAT-DNS-Server')) { $features[$f] = 'Installed' }
        $dienste.NTDS = @{ Vorhanden = $true; Status = 'Running'; StartTyp = 'Automatic' }
        $dienste.Netlogon = @{ Vorhanden = $true; Status = 'Running'; StartTyp = 'Automatic' }
        $dienste.DNS = @{ Vorhanden = $true; Status = 'Running'; StartTyp = 'Automatic' }
    }
    if ($Szenario -eq 'DcDhcp') {
        $features['DHCP'] = 'Installed'; $features['RSAT-DHCP'] = 'Installed'
        $dienste.DHCPServer = @{ Vorhanden = $true; Status = 'Running'; StartTyp = 'Automatic' }
    }
    $rolle = @{ Frisch = 2; DcDns = 5; DcDhcp = 5; Mitglied = 3 }[$Szenario]
    $ip = '192.168.1.50'
    if ($dc) { $ip = '192.168.1.10' }
    $karte = @{
        Index = 4; Name = 'Ethernet'; Beschreibung = 'Intel'; Mac = '00-15-5D-01-02-03'; Status = 'Up'
        Dhcp = ($Szenario -eq 'Frisch')
        Adressen = @(@{ IP = $ip; Prefix = 24; Herkunft = $(if ($Szenario -eq 'Frisch') { 'Dhcp' } else { 'Manual' }) })
        Gateway = @('192.168.1.1')
        DnsServer = $(if ($dc) { @('127.0.0.1') } elseif ($Szenario -eq 'Mitglied') { @('192.168.1.10') } else { @('192.168.1.1') })
    }
    $zustand = @{
        Zeitpunkt = '2026-01-01 10:00:00'
        System    = @{
            Hostname = $(if ($dc) { 'DC01' } else { 'SRV01' }); OsName = 'Microsoft Windows Server 2022 Standard'; OsVersion = '10.0.20348'; Build = '20348'
            ProductType = $(if ($dc) { 2 } else { 3 }); Edition = 'ServerStandard'; IstCore = $false; Sprache = 'de-CH'; UiSprache = 'de-DE'; OsSprache = 1031
            DomainRole = $rolle; RolleText = $script:NetDomainRoleText[$rolle]
            IstDC = $dc; IstPdc = $dc; IstMitglied = ($Szenario -eq 'Mitglied'); IstArbeitsgruppe = ($Szenario -eq 'Frisch')
            Domaene = $(if ($Szenario -ne 'Frisch') { 'ad.firma.ch' } else { '' }); Arbeitsgruppe = $(if ($Szenario -eq 'Frisch') { 'WORKGROUP' } else { '' })
            IstAdmin = $true
        }
        AD        = @{ Verfuegbar = $dc; Domaene = $(if ($Szenario -ne 'Frisch') { 'ad.firma.ch' } else { '' }); NetBios = 'FIRMA'; Gesamtstruktur = 'ad.firma.ch'; DomainMode = 'Windows2016Domain'; ForestMode = 'Windows2016Forest'; Pdc = 'DC01.ad.firma.ch'; ModulFehlt = $false }
        Features  = $features
        Dienste   = $dienste
        Neustart  = @{ Ausstehend = $false; Gruende = @() }
        Netzwerk  = @{ Karten = @($karte); AktiveKarten = @($karte); MehrereKarten = $false; EigeneIPs = @($ip) }
        Dns       = @{ Installiert = $dc; Tools = $dc; Laeuft = $dc; Verfuegbar = $dc; Zonen = @(); Weiterleitungen = @(); Scavenging = $null; AbhoerIPs = @() }
        Dhcp      = @{ Installiert = $false; Tools = $false; Laeuft = $false; Verfuegbar = $false; Nachkonfiguriert = $false; Autorisiert = $null; InDomaene = $false; Bindungen = @(); Scopes = @(); ServerOptionen = @{}; Failover = @(); DnsEinstellung = $null; DnsZugangsdaten = @{ Gesetzt = $false; Benutzer = ''; Domaene = '' }; KonfliktErkennung = 0 }
        Zeit      = @{ Typ = $(if ($dc -or $Szenario -eq 'Mitglied') { 'NT5DS' } else { 'NTP' }); NtpServer = 'time.windows.com,0x9' }
    }
    if ($dc) {
        $zustand.Zeit = @{ Typ = 'NTP'; NtpServer = 'ch.pool.ntp.org,0x8' }
        $zustand.Dns.Zonen = @(
            @{ Name = 'ad.firma.ch'; Typ = 'Primary'; AdIntegriert = $true; Reverse = $false; DynUpdate = 'Secure'; Replikation = 'Domain'; Signiert = $false; Aging = @{ Aktiv = $true; NoRefresh = '7.00:00:00'; Refresh = '7.00:00:00' } },
            @{ Name = '_msdcs.ad.firma.ch'; Typ = 'Primary'; AdIntegriert = $true; Reverse = $false; DynUpdate = 'Secure'; Replikation = 'Forest'; Signiert = $false; Aging = $null },
            @{ Name = '1.168.192.in-addr.arpa'; Typ = 'Primary'; AdIntegriert = $true; Reverse = $true; DynUpdate = 'Secure'; Replikation = 'Domain'; Signiert = $false; Aging = @{ Aktiv = $true; NoRefresh = '7.00:00:00'; Refresh = '7.00:00:00' } }
        )
        $zustand.Dns.Weiterleitungen = @('9.9.9.9', '1.1.1.1')
        $zustand.Dns.Scavenging = @{ Aktiv = $true; Intervall = '7.00:00:00'; NoRefresh = '7.00:00:00'; Refresh = '7.00:00:00' }
        $zustand.Dns.AbhoerIPs = @()
    }
    if ($Szenario -eq 'DcDhcp') {
        $zustand.Dhcp = @{
            Installiert = $true; Tools = $true; Laeuft = $true; Verfuegbar = $true; Nachkonfiguriert = $true; Autorisiert = $true; InDomaene = $true
            Bindungen = @(@{ Karte = 'Ethernet'; IP = '192.168.1.10'; Aktiv = $true })
            Scopes = @(@{
                    ScopeId = '192.168.1.0'; Name = 'LAN'; Start = '192.168.1.100'; Ende = '192.168.1.199'; Maske = '255.255.255.0'; Prefix = 24
                    Status = 'Active'; Aktiv = $true; LeaseDauer = '8.00:00:00'; LeaseTage = 8; Superscope = ''
                    Optionen = @{ '3' = @('192.168.1.1'); '6' = @('192.168.1.10'); '15' = @('ad.firma.ch') }
                    Ausschluesse = @(@{ Start = '192.168.1.100'; Ende = '192.168.1.109' })
                    Reservierungen = @(@{ IP = '192.168.1.150'; ClientId = 'aa-bb-cc-dd-ee-ff'; Name = 'drucker'; Beschreibung = '' })
                    Auslastung = 35; Frei = 58; Belegt = 32
                    DnsEinstellung = @{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = $false; DisableDnsPtrRRUpdate = $false }
                })
            ServerOptionen = @{}
            Failover = @()
            DnsEinstellung = @{ DynamicUpdates = 'Always'; DeleteDnsRROnLeaseExpiry = $true; UpdateDnsRRForOlderClients = $true; NameProtection = $false; DisableDnsPtrRRUpdate = $false }
            DnsZugangsdaten = @{ Gesetzt = $true; Benutzer = 'svc-dhcpdns'; Domaene = 'FIRMA' }
            KonfliktErkennung = 1
        }
    }
    return $zustand
}

function New-TestCimObjekt {
    param([hashtable]$Werte)
    return [pscustomobject]$Werte
}
