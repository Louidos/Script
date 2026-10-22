# Hilfsfunktionen fuer die Pruefungen des Doktors (alle nur mit Bordmitteln).

function Get-NetCurrentAccount {
    <#
    .SYNOPSIS
        Liefert das angemeldete Konto und ob es ein lokales Konto ist.
    #>
    $name = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $teile = $name.Split('\')
    $lokal = ($teile.Count -eq 2 -and $teile[0] -ieq [Environment]::MachineName)
    return [pscustomobject]@{ Name = $name; IstLokal = $lokal }
}

function Test-NetFirewallPortOpen {
    <#
    .SYNOPSIS
        Prueft ueber Port und Protokoll (nicht ueber Regelnamen), ob eingehend erlaubt ist.
        Ist die Firewall in keinem Profil aktiv, gilt der Port als offen.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('TCP', 'UDP')][string]$Protokoll, [Parameter(Mandatory = $true)][int]$Port)
    $aktiveProfile = @(Get-NetFirewallProfile | Where-Object { [string]$_.Enabled -eq 'True' })
    if ($aktiveProfile.Count -eq 0) { return $true }
    foreach ($filter in @(Get-NetFirewallPortFilter -Protocol $Protokoll)) {
        if ($null -eq $filter) { continue }
        $ports = @($filter.LocalPort | ForEach-Object { [string]$_ })
        $passt = ($ports -contains [string]$Port)
        foreach ($p in $ports) {
            if ($p -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { $passt = $true }
        }
        if (-not $passt) { continue }
        foreach ($regel in @($filter | Get-NetFirewallRule)) {
            if ($regel -and [string]$regel.Enabled -eq 'True' -and [string]$regel.Direction -eq 'Inbound' -and [string]$regel.Action -eq 'Allow') { return $true }
        }
    }
    return $false
}

function New-NetFirewallPortRule {
    <#
    .SYNOPSIS
        Legt eine eingehende Firewall-Regel fuer einen Port an (Gruppe NetSetup).
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('TCP', 'UDP')][string]$Protokoll, [Parameter(Mandatory = $true)][int]$Port, [Parameter(Mandatory = $true)][string]$Zweck)
    $name = 'NetSetup-{0}-{1}' -f $Protokoll, $Port
    New-NetFirewallRule -Name $name -DisplayName ('NetSetup {0} ({1} {2})' -f $Zweck, $Protokoll, $Port) -Direction Inbound -Protocol $Protokoll -LocalPort $Port -Action Allow -Group 'NetSetup' -Profile 'Domain,Private' -Description 'Angelegt vom NetSetup-Doktor' | Out-Null
}

function Resolve-NetDcSrvRecord {
    param([Parameter(Mandatory = $true)][string]$Domaene)
    $name = '_ldap._tcp.dc._msdcs.' + $Domaene
    return (Get-NetSafe -Beschreibung "SRV $name" -Abfrage { Resolve-DnsName -Name $name -Type SRV -DnsOnly -QuickTimeout })
}

function New-NetDhcpDiscoverPacket {
    <#
    .SYNOPSIS
        Baut ein DHCPDISCOVER-Paket (RFC 2131) mit Broadcast-Flag und einer zufaelligen,
        lokal verwalteten MAC-Adresse.
    #>
    param([byte[]]$Xid, [byte[]]$Mac)
    $p = New-Object byte[] 300
    $p[0] = 1; $p[1] = 1; $p[2] = 6; $p[3] = 0
    [Array]::Copy($Xid, 0, $p, 4, 4)
    $p[10] = 0x80
    [Array]::Copy($Mac, 0, $p, 28, 6)
    $p[236] = 99; $p[237] = 130; $p[238] = 83; $p[239] = 99
    $p[240] = 53; $p[241] = 1; $p[242] = 1; $p[243] = 255
    return $p
}

function Find-NetForeignDhcpServer {
    <#
    .SYNOPSIS
        Sendet ein DHCPDISCOVER (UDP 67) und sammelt alle DHCP-Server, die antworten.
        Nur .NET-Bordmittel (UdpClient). Liefert die Adressen der antwortenden Server
        oder $null, wenn die Pruefung nicht moeglich war (z. B. Port 68 belegt).
    #>
    param([int]$WarteSekunden = 4)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 68)))
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 1000
        $zufall = New-Object System.Random
        $xid = New-Object byte[] 4
        $zufall.NextBytes($xid)
        $mac = New-Object byte[] 6
        $zufall.NextBytes($mac)
        $mac[0] = ($mac[0] -band 0xFC) -bor 0x02
        $paket = New-NetDhcpDiscoverPacket -Xid $xid -Mac $mac
        $ziel = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 67)
        [void]$udp.Send($paket, $paket.Length, $ziel)
        $server = @()
        $ende = (Get-Date).AddSeconds($WarteSekunden)
        while ((Get-Date) -lt $ende) {
            try {
                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $antwort = $udp.Receive([ref]$ep)
            }
            catch { continue }
            if ($antwort.Length -lt 240 -or $antwort[0] -ne 2) { continue }
            if ($antwort[4] -ne $xid[0] -or $antwort[5] -ne $xid[1] -or $antwort[6] -ne $xid[2] -or $antwort[7] -ne $xid[3]) { continue }
            $kennung = $ep.Address.ToString()
            $i = 240
            while ($i -lt $antwort.Length - 1) {
                $code = $antwort[$i]
                if ($code -eq 255) { break }
                if ($code -eq 0) { $i++; continue }
                $laenge = $antwort[$i + 1]
                if ($code -eq 54 -and $laenge -eq 4) { $kennung = '{0}.{1}.{2}.{3}' -f $antwort[$i + 2], $antwort[$i + 3], $antwort[$i + 4], $antwort[$i + 5] }
                $i += 2 + $laenge
            }
            if ($server -notcontains $kennung) { $server += $kennung }
        }
        return $server
    }
    catch {
        Write-Log -Level Debug -Message ('DHCP-Suche nicht moeglich: ' + $_.Exception.Message)
        return $null
    }
    finally {
        if ($udp) { $udp.Close() }
    }
}

function Get-NetKnownDhcpServer {
    <#
    .SYNOPSIS
        Eigene Adressen und im AD autorisierte DHCP-Server (diese gelten nicht als fremd).
    #>
    param([hashtable]$Zustand)
    $bekannt = @($Zustand.Netzwerk.EigeneIPs)
    foreach ($s in @(Get-NetSafe -Beschreibung 'Get-DhcpServerInDC' -Standard @() -Abfrage { Get-DhcpServerInDC })) {
        if ($s -and $s.IPAddress) { $bekannt += (ConvertTo-NetString $s.IPAddress) }
    }
    foreach ($f in @($Zustand.Dhcp.Failover)) {
        $ip = Get-NetSafe -Beschreibung 'Partner' -Abfrage { (Resolve-DnsName -Name $f.Partner -Type A -DnsOnly -QuickTimeout | Select-Object -First 1).IPAddress }
        if ($ip) { $bekannt += [string]$ip }
    }
    return @($bekannt | Select-Object -Unique)
}

function Show-NetForeignDhcpServer {
    Write-Log -Message 'Sende DHCPDISCOVER und warte 4 Sekunden auf Antworten ...'
    Write-NetText -Text 'Hinweis: Ein DHCP-Server, der antwortet, reserviert die angebotene Adresse kurz fuer die Test-MAC. Das ist harmlos und laeuft von selbst ab.'
    $z = Get-NetSetupState
    $server = Find-NetForeignDhcpServer
    if ($null -eq $server) { Write-Log -Level Warn -Message 'Die Suche war nicht moeglich (UDP-Port 68 belegt oder gesperrt).'; return }
    $bekannt = Get-NetKnownDhcpServer -Zustand $z
    if (@($server).Count -eq 0) { Write-Log -Level Warn -Message 'Kein DHCP-Server hat geantwortet (auch dieser nicht - Bindung, Scope oder Firewall pruefen).'; return }
    foreach ($s in $server) {
        if ($bekannt -contains $s) { Write-NetStatus -Status OK -Bereich $s -Text 'bekannter DHCP-Server' }
        else { Write-NetStatus -Status FEHLER -Bereich $s -Text 'FREMDER DHCP-Server - verteilt evtl. falsche Adressen (Router/WLAN-Box?)' }
    }
}

function Get-NetDuplicateDnsRecord {
    <#
    .SYNOPSIS
        Findet doppelte A-Eintraege: gleicher Name mit mehreren IPs bzw. gleiche IP unter mehreren Namen
        (nur dynamische Eintraege; statische Round-Robin-Eintraege sind gewollt).
    #>
    param([string[]]$Zonen)
    $doppelt = @()
    foreach ($zone in $Zonen) {
        $a = @(Get-NetDnsRecord -Zone $zone -Typ 'A' | Where-Object { -not $_.Statisch -and $_.Name -ne '@' -and $_.Name -notlike 'DomainDnsZones*' -and $_.Name -notlike 'ForestDnsZones*' })
        foreach ($g in @($a | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })) {
            $doppelt += [pscustomobject]@{ Zone = $zone; Art = 'Name mit mehreren IPs'; Wert = $g.Name; Liste = (($g.Group | ForEach-Object { $_.Wert }) -join ', ') }
        }
        foreach ($g in @($a | Group-Object -Property Wert | Where-Object { $_.Count -gt 1 })) {
            $doppelt += [pscustomobject]@{ Zone = $zone; Art = 'IP unter mehreren Namen'; Wert = $g.Name; Liste = (($g.Group | ForEach-Object { $_.Name }) -join ', ') }
        }
    }
    return $doppelt
}

function Get-NetDnsCredentialAccountState {
    <#
    .SYNOPSIS
        Prueft das Konto der DHCP-DNS-Zugangsdaten im AD (aktiv, Kennwort nicht abgelaufen).
        Liefert $null, wenn das nicht pruefbar ist.
    #>
    param([Parameter(Mandatory = $true)][string]$Benutzer)
    if (-not (Test-NetCommand -Name 'Get-ADUser')) { return $null }
    $u = Get-NetSafe -Beschreibung "Konto $Benutzer" -Abfrage { Get-ADUser -Identity $Benutzer -Properties Enabled, PasswordExpired, AccountExpirationDate, LockedOut }
    if (-not $u) { return [pscustomobject]@{ Vorhanden = $false; Problem = "Das Konto $Benutzer gibt es im AD nicht (mehr)." } }
    $problem = ''
    if (-not $u.Enabled) { $problem = "Das Konto $Benutzer ist deaktiviert." }
    elseif ($u.PasswordExpired) { $problem = "Das Kennwort von $Benutzer ist abgelaufen." }
    elseif ($u.LockedOut) { $problem = "Das Konto $Benutzer ist gesperrt." }
    elseif ($u.AccountExpirationDate -and ([datetime]$u.AccountExpirationDate) -lt (Get-Date)) { $problem = "Das Konto $Benutzer ist abgelaufen." }
    return [pscustomobject]@{ Vorhanden = $true; Problem = $problem }
}
