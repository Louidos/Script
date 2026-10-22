# Netzwerk-Grundlagen fuer AD, DNS und DHCP: feste IP, DNS-Client, Servername, Zeit.
# Alle Aenderungen laufen ueber Invoke-NetChange (Vorher/Nachher, Backup, Rueckgaengig).

function Select-NetActiveAdapter {
    <#
    .SYNOPSIS
        Waehlt die Netzwerkkarte, um die es geht (bei mehreren wird gefragt).
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    $karten = @($Zustand.Netzwerk.AktiveKarten)
    if ($karten.Count -eq 0) {
        Write-Log -Level Fehler -Message 'Keine aktive Netzwerkkarte mit IPv4-Adresse gefunden.'
        Write-Log -Message 'Naechster Schritt: Netzwerkkabel bzw. virtuellen Switch pruefen und die Karte aktivieren.'
        return $null
    }
    if ($karten.Count -eq 1) { return $karten[0] }
    Write-Log -Level Warn -Message 'Es sind mehrere Netzwerkkarten aktiv. Bitte die Karte im Netz der Clients waehlen.'
    $anzeige = @($karten | ForEach-Object { [pscustomobject]@{ Index = $_.Index; Name = $_.Name; IP = (($_.Adressen | ForEach-Object { $_.IP + '/' + $_.Prefix }) -join ', '); Art = $(if ($_.Dhcp) { 'DHCP' } else { 'statisch' }) } })
    $wahl = Select-NetItem -Elemente $anzeige -Titel 'Netzwerkkarte waehlen' -Eigenschaften @('Index', 'Name', 'IP', 'Art')
    if (-not $wahl) { return $null }
    return ($karten | Where-Object { $_.Index -eq $wahl.Index } | Select-Object -First 1)
}

function Set-NetStaticAddress {
    <#
    .SYNOPSIS
        Setzt eine feste IPv4-Adresse (Stufe Gefaehrlich: Remotedesktop kann getrennt werden).
    #>
    param([hashtable]$Karte)
    if (-not $Karte) { $Karte = Select-NetActiveAdapter }
    if (-not $Karte) { return $false }
    $aktuell = $Karte.Adressen | Select-Object -First 1
    $vorschlagGw = ''
    if ($Karte.Gateway.Count -gt 0) { $vorschlagGw = $Karte.Gateway[0] }
    Write-NetText -Text ('Netzwerkkarte {0}: zurzeit {1}/{2} ({3}).' -f $Karte.Name, $aktuell.IP, $aktuell.Prefix, $(if ($Karte.Dhcp) { 'per DHCP' } else { 'statisch' })) -Farbe White
    Write-NetText -Text 'Ein Server braucht eine feste IP. Ueblich ist eine Adresse ausserhalb des DHCP-Bereichs, z. B. .10 bis .20.'
    $ip = Read-NetIPAddress -Frage 'Feste IP-Adresse' -Vorschlag $aktuell.IP
    if (-not $ip) { return $false }
    $netz = Read-NetSubnet -Frage 'Netz (Praefix oder Maske)' -Vorschlag ('{0}/{1}' -f (Get-NetNetworkAddress -IPAddress $ip -PrefixLength $aktuell.Prefix), $aktuell.Prefix)
    if (-not $netz) { return $false }
    if (-not (Test-NetIPInSubnet -IPAddress $ip -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix)) {
        Write-Log -Level Fehler -Message "Die Adresse $ip liegt nicht im Netz $($netz.Text)."
        return $false
    }
    $gw = Read-NetIPAddress -Frage 'Gateway (Router)' -Vorschlag $vorschlagGw -Netz $netz.Netz -Prefix $netz.Prefix -LeerErlaubt
    if ($null -eq $gw) { return $false }
    $dnsVorschlag = ($Karte.DnsServer -join ',')
    $dnsText = Read-NetText -Frage 'DNS-Server (mit Komma getrennt)' -Vorschlag $dnsVorschlag -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $dnsText) { return $false }
    $dnsListe = @($dnsText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $index = [int]$Karte.Index
    $prefix = [int]$netz.Prefix
    $vorher = @{ Karte = $Karte.Name; IP = ('{0}/{1}' -f $aktuell.IP, $aktuell.Prefix); Art = $(if ($Karte.Dhcp) { 'DHCP' } else { 'statisch' }); Gateway = ($Karte.Gateway -join ', '); DNS = ($Karte.DnsServer -join ', ') }
    $nachher = @{ Karte = $Karte.Name; IP = ('{0}/{1}' -f $ip, $prefix); Art = 'statisch'; Gateway = $gw; DNS = ($dnsListe -join ', ') }
    $rueck = @(
        @{ Befehl = 'Remove-NetIPAddress'; Parameter = @{ InterfaceIndex = $index; IPAddress = $ip; Confirm = $false } },
        @{ Befehl = 'Set-NetIPInterface'; Parameter = @{ InterfaceIndex = $index; Dhcp = 'Enabled' } },
        @{ Befehl = 'Set-DnsClientServerAddress'; Parameter = @{ InterfaceIndex = $index; ResetServerAddresses = $true } }
    )
    if (-not $Karte.Dhcp) {
        $rueck = @(
            @{ Befehl = 'Remove-NetIPAddress'; Parameter = @{ InterfaceIndex = $index; IPAddress = $ip; Confirm = $false } },
            @{ Befehl = 'New-NetIPAddress'; Parameter = @{ InterfaceIndex = $index; IPAddress = $aktuell.IP; PrefixLength = [int]$aktuell.Prefix } }
        )
    }
    $r = Invoke-NetChange -Titel ('Feste IP-Adresse {0}/{1} auf {2} setzen' -f $ip, $prefix, $Karte.Name) -Stufe Gefaehrlich -Vorher $vorher -Nachher $nachher -BackupBereich @('Netzwerk') `
        -Hinweis 'ACHTUNG: Waehrend der Umstellung wird die Verbindung kurz unterbrochen. Eine Remotedesktop-Sitzung wird getrennt, wenn sich die Adresse aendert - danach mit der neuen Adresse neu verbinden.' -Aktion {
        Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:$false
        Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
        if ($gw) { New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw | Out-Null }
        else { New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $ip -PrefixLength $prefix | Out-Null }
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dnsListe
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Set-NetDnsClient {
    <#
    .SYNOPSIS
        Stellt die DNS-Server ein, die dieser Server selbst fragt (DNS-Client).
    #>
    param([hashtable]$Karte, [string[]]$Server, [string]$Grund = '')
    if (-not $Karte) { $Karte = Select-NetActiveAdapter }
    if (-not $Karte) { return $false }
    if (-not $Server) {
        Write-NetText -Text 'Ein Domaenencontroller fragt sich selbst (eigene IP, dann 127.0.0.1). Mitgliedsserver fragen die DCs, nie direkt einen Internet-DNS wie 8.8.8.8.'
        $text = Read-NetText -Frage 'DNS-Server (mit Komma getrennt)' -Vorschlag ($Karte.DnsServer -join ',') -Pruefung {
            param($t)
            foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
            return $null
        }
        if (-not $text) { return $false }
        $Server = @($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $alt = @($Karte.DnsServer)
    if (($alt -join ',') -eq ($Server -join ',')) {
        Write-Log -Level OK -Message ('DNS-Client ist bereits richtig eingestellt: ' + ($Server -join ', '))
        return $true
    }
    $index = [int]$Karte.Index
    $neu = @($Server)
    $rueck = @{ Befehl = 'Set-DnsClientServerAddress'; Parameter = @{ InterfaceIndex = $index; ServerAddresses = $alt } }
    if ($alt.Count -eq 0) { $rueck = @{ Befehl = 'Set-DnsClientServerAddress'; Parameter = @{ InterfaceIndex = $index; ResetServerAddresses = $true } } }
    $r = Invoke-NetChange -Titel ('DNS-Client von {0} einstellen' -f $Karte.Name) -Stufe Bestaetigen -Vorher ($alt -join ', ') -Nachher ($neu -join ', ') -Hinweis $Grund -BackupBereich @('Netzwerk') -Aktion {
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $neu
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Rename-NetServer {
    <#
    .SYNOPSIS
        Benennt den Server um (vor der Heraufstufung zum DC). Danach ist ein Neustart noetig.
    #>
    param([string]$NeuerName, [string]$WeiterMit = '', [hashtable]$WeiterDaten = @{})
    $alt = [Environment]::MachineName
    if (-not $NeuerName) {
        Write-NetText -Text 'Der Name muss vor der Heraufstufung zum DC feststehen; danach ist eine Umbenennung aufwendig. Beispiele: DC01, SRV-DC01.'
        $NeuerName = Read-NetText -Frage 'Neuer Servername' -Vorschlag 'DC01' -Pruefung { param($t) Test-NetHostName -Name $t }
        if (-not $NeuerName) { return $false }
    }
    if ($NeuerName -ieq $alt) { Write-Log -Level OK -Message 'Der Server heisst bereits so.'; return $true }
    $neu = $NeuerName.ToUpper()
    $r = Invoke-NetChange -Titel "Server umbenennen in $neu" -Stufe Bestaetigen -Vorher $alt -Nachher $neu -Hinweis 'Die Umbenennung wird erst nach einem Neustart wirksam.' -Aktion {
        Rename-Computer -NewName $neu -Force
    } -Rueckgaengig @{ Befehl = 'Rename-Computer'; Parameter = @{ NewName = $alt; Force = $true } }
    if ($r.Erfolg -and -not $r.Probelauf) {
        Save-NetResumeState -Schritt 'AdNachUmbenennung' -Daten @{ WeiterMit = $WeiterMit; WeiterDaten = $WeiterDaten } -Beschreibung "Umbenennung in $neu"
        Request-NetRestart -Grund "Umbenennung in $neu"
        return $true
    }
    return $false
}

function Get-NetTimeOffset {
    <#
    .SYNOPSIS
        Misst die Zeitabweichung zu einem NTP-Server (SNTP ueber UDP 123, nur .NET-Bordmittel).
    .OUTPUTS
        Abweichung in Sekunden (positiv = Server geht vor) oder $null, wenn keine Antwort kam.
    #>
    param([Parameter(Mandatory = $true)][string]$Server, [int]$TimeoutMs = 3000)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $anfrage = New-Object byte[] 48
        $anfrage[0] = 0x1B
        $udp.Connect($Server, 123)
        $t1 = [DateTime]::UtcNow
        [void]$udp.Send($anfrage, $anfrage.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $antwort = $udp.Receive([ref]$ep)
        $t4 = [DateTime]::UtcNow
        if ($antwort.Length -lt 48) { return $null }
        $sek = [uint64](([uint32]$antwort[40] -shl 24) -bor ([uint32]$antwort[41] -shl 16) -bor ([uint32]$antwort[42] -shl 8) -bor [uint32]$antwort[43])
        $bruch = [uint64](([uint32]$antwort[44] -shl 24) -bor ([uint32]$antwort[45] -shl 16) -bor ([uint32]$antwort[46] -shl 8) -bor [uint32]$antwort[47])
        $basis = New-Object DateTime(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $serverZeit = $basis.AddSeconds([double]$sek + ([double]$bruch / 4294967296.0))
        $mitte = $t1.AddTicks([long](($t4 - $t1).Ticks / 2))
        return [Math]::Round(($serverZeit - $mitte).TotalSeconds, 2)
    }
    catch {
        Write-Log -Level Debug -Message ('Zeitabfrage bei {0} fehlgeschlagen: {1}' -f $Server, $_.Exception.Message)
        return $null
    }
    finally {
        if ($udp) { $udp.Close() }
    }
}

function Invoke-NetW32tm {
    <#
    .SYNOPSIS
        Ruft w32tm.exe auf. Ausgewertet wird nur der Exitcode, nie der (uebersetzte) Text.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Argumente)
    $ausgabe = & w32tm.exe @Argumente 2>&1
    Write-Log -Level Debug -Message ('w32tm ' + ($Argumente -join ' ') + ' -> ' + $LASTEXITCODE + ': ' + (($ausgabe | Out-String).Trim()))
    if ($LASTEXITCODE -ne 0) { throw ('w32tm meldet Fehlercode {0}.' -f $LASTEXITCODE) }
}

function Set-NetPdcTimeSource {
    <#
    .SYNOPSIS
        Stellt die externe Zeitquelle fuer den PDC-Emulator (bzw. einen Server ohne Domaene) ein.
    #>
    param([string]$NtpServer)
    if (-not $NtpServer) {
        Write-NetText -Text "Der PDC-Emulator ist die Zeitquelle der ganzen Domaene. Er sollte die Zeit von einer externen Quelle holen,`nz. B. ch.pool.ntp.org, de.pool.ntp.org, time.windows.com oder der Router. Ohne Internet: den Router oder eine interne Zeitquelle angeben."
        $NtpServer = Read-NetText -Frage 'NTP-Server (mehrere mit Leerzeichen)' -Vorschlag 'ch.pool.ntp.org' -Pruefung {
            param($t)
            foreach ($x in $t.Split(' ')) { if ($x -and $x -notmatch '^[A-Za-z0-9.-]+$') { return "'$x' ist kein gueltiger Name bzw. keine IP." } }
            return $null
        }
        if (-not $NtpServer) { return $false }
    }
    $zeit = Get-NetTimeState
    $liste = ($NtpServer.Split(' ') | Where-Object { $_ } | ForEach-Object { $_ + ',0x8' }) -join ' '
    $r = Invoke-NetChange -Titel 'Externe Zeitquelle einstellen' -Stufe Bestaetigen -Vorher @{ Typ = $zeit.Typ; Server = $zeit.NtpServer } -Nachher @{ Typ = 'NTP'; Server = $liste } -Aktion {
        Invoke-NetW32tm -Argumente @('/config', ('/manualpeerlist:' + $liste), '/syncfromflags:manual', '/reliable:yes', '/update')
        Restart-Service -Name W32Time -Force
        try { Invoke-NetW32tm -Argumente @('/resync', '/force') } catch { Write-Log -Level Warn -Message 'Die erste Synchronisierung ist fehlgeschlagen (Quelle nicht erreichbar?). Windows versucht es automatisch erneut.' }
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Sync-NetTimeWithDc {
    <#
    .SYNOPSIS
        Synchronisiert die Uhr mit einem Domaenencontroller (vor Beitritt oder Heraufstufung).
    #>
    param([Parameter(Mandatory = $true)][string]$Dc)
    $r = Invoke-NetChange -Titel "Uhrzeit mit $Dc abgleichen" -Stufe Bestaetigen -Hinweis 'Mehr als 5 Minuten Abweichung verhindern die Anmeldung an der Domaene (Kerberos).' -Aktion {
        Invoke-NetW32tm -Argumente @('/config', ('/manualpeerlist:' + $Dc), '/syncfromflags:manual', '/update')
        Restart-Service -Name W32Time -Force
        Invoke-NetW32tm -Argumente @('/resync', '/force')
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
