# Hilfsfunktionen fuer IPv4-Adressen, Subnetze, Reverse-Zonen und Namen.
# Reine Rechenfunktionen ohne Zugriff auf den Server.

function Test-NetIPv4Address {
    <#
    .SYNOPSIS
        Prueft, ob ein Text eine gueltige IPv4-Adresse in Punktschreibweise ist.
    #>
    param([AllowEmptyString()][string]$Text)
    if ($Text -notmatch '^\s*(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\s*$') { return $false }
    foreach ($i in 1..4) {
        if ([int]$Matches[$i] -gt 255) { return $false }
        if (($Matches[$i].Length -gt 1) -and $Matches[$i].StartsWith('0')) { return $false }
    }
    return $true
}

function ConvertTo-NetIPv4UInt32 {
    param([Parameter(Mandatory = $true)][string]$IPAddress)
    $bytes = ([System.Net.IPAddress]::Parse($IPAddress.Trim())).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-NetIPv4UInt32 {
    param([Parameter(Mandatory = $true)][uint32]$Wert)
    $bytes = [BitConverter]::GetBytes($Wert)
    [Array]::Reverse($bytes)
    return ($bytes -join '.')
}

function ConvertTo-NetSubnetMask {
    <#
    .SYNOPSIS
        Praefixlaenge (z. B. 24) in Subnetzmaske (255.255.255.0) umrechnen.
    #>
    param([Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    if ($PrefixLength -eq 0) { return '0.0.0.0' }
    [uint32]$maske = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $PrefixLength))
    return (ConvertFrom-NetIPv4UInt32 -Wert $maske)
}

function ConvertTo-NetPrefixLength {
    <#
    .SYNOPSIS
        Subnetzmaske in Praefixlaenge umrechnen. Liefert -1 bei ungueltiger Maske.
    #>
    param([Parameter(Mandatory = $true)][string]$SubnetMask)
    if (-not (Test-NetIPv4Address -Text $SubnetMask)) { return -1 }
    $wert = ConvertTo-NetIPv4UInt32 -IPAddress $SubnetMask
    $bits = [Convert]::ToString([int64]$wert, 2).PadLeft(32, '0')
    if ($bits -notmatch '^1*0*$') { return -1 }
    return ($bits.TrimEnd('0')).Length
}

function Get-NetNetworkAddress {
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    $ip = ConvertTo-NetIPv4UInt32 -IPAddress $IPAddress
    $maske = ConvertTo-NetIPv4UInt32 -IPAddress (ConvertTo-NetSubnetMask -PrefixLength $PrefixLength)
    return (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($ip -band $maske)))
}

function Get-NetBroadcastAddress {
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    $netz = ConvertTo-NetIPv4UInt32 -IPAddress (Get-NetNetworkAddress -IPAddress $IPAddress -PrefixLength $PrefixLength)
    $host_anzahl = [uint32]([Math]::Pow(2, 32 - $PrefixLength) - 1)
    return (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($netz + $host_anzahl)))
}

function Test-NetIPInSubnet {
    <#
    .SYNOPSIS
        Prueft, ob eine Adresse im angegebenen Netz liegt.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][string]$NetworkAddress,
        [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength
    )
    if (-not (Test-NetIPv4Address -Text $IPAddress) -or -not (Test-NetIPv4Address -Text $NetworkAddress)) { return $false }
    return ((Get-NetNetworkAddress -IPAddress $IPAddress -PrefixLength $PrefixLength) -eq (Get-NetNetworkAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength))
}

function Test-NetIPRange {
    <#
    .SYNOPSIS
        Prueft einen Adressbereich fuer einen Scope. Liefert $null wenn gueltig, sonst den Grund.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Start,
        [Parameter(Mandatory = $true)][string]$Ende,
        [Parameter(Mandatory = $true)][string]$NetworkAddress,
        [Parameter(Mandatory = $true)][ValidateRange(1, 32)][int]$PrefixLength
    )
    if (-not (Test-NetIPv4Address -Text $Start)) { return "Startadresse '$Start' ist keine gueltige IPv4-Adresse." }
    if (-not (Test-NetIPv4Address -Text $Ende)) { return "Endadresse '$Ende' ist keine gueltige IPv4-Adresse." }
    if ($PrefixLength -gt 30) { return 'Das Netz ist zu klein fuer DHCP (mindestens /30).' }
    if (-not (Test-NetIPInSubnet -IPAddress $Start -NetworkAddress $NetworkAddress -PrefixLength $PrefixLength)) { return "Startadresse $Start liegt nicht im Netz $NetworkAddress/$PrefixLength." }
    if (-not (Test-NetIPInSubnet -IPAddress $Ende -NetworkAddress $NetworkAddress -PrefixLength $PrefixLength)) { return "Endadresse $Ende liegt nicht im Netz $NetworkAddress/$PrefixLength." }
    $s = ConvertTo-NetIPv4UInt32 -IPAddress $Start
    $e = ConvertTo-NetIPv4UInt32 -IPAddress $Ende
    if ($s -ge $e) { return 'Die Startadresse muss kleiner als die Endadresse sein.' }
    $netz = ConvertTo-NetIPv4UInt32 -IPAddress (Get-NetNetworkAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength)
    $bc = ConvertTo-NetIPv4UInt32 -IPAddress (Get-NetBroadcastAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength)
    if ($s -eq $netz) { return 'Die Startadresse darf nicht die Netzadresse sein.' }
    if ($e -eq $bc) { return 'Die Endadresse darf nicht die Broadcast-Adresse sein.' }
    return $null
}

function Test-NetIPInRange {
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][string]$Start, [Parameter(Mandatory = $true)][string]$Ende)
    if (-not ((Test-NetIPv4Address -Text $IPAddress) -and (Test-NetIPv4Address -Text $Start) -and (Test-NetIPv4Address -Text $Ende))) { return $false }
    $ip = ConvertTo-NetIPv4UInt32 -IPAddress $IPAddress
    return (($ip -ge (ConvertTo-NetIPv4UInt32 -IPAddress $Start)) -and ($ip -le (ConvertTo-NetIPv4UInt32 -IPAddress $Ende)))
}

function Get-NetRangeSize {
    param([Parameter(Mandatory = $true)][string]$Start, [Parameter(Mandatory = $true)][string]$Ende)
    return [int64](ConvertTo-NetIPv4UInt32 -IPAddress $Ende) - [int64](ConvertTo-NetIPv4UInt32 -IPAddress $Start) + 1
}

function Get-NetReverseZoneName {
    <#
    .SYNOPSIS
        Liefert die Namen der Reverse-Zonen (in-addr.arpa) fuer ein Netz.
    .DESCRIPTION
        /24 und kleiner: eine Zone mit drei Oktetten. /17 bis /23: je eine /24-Zone.
        /16 und /9 bis /15 entsprechend mit zwei bzw. einem Oktett.
    #>
    param([Parameter(Mandatory = $true)][string]$NetworkAddress, [Parameter(Mandatory = $true)][ValidateRange(8, 32)][int]$PrefixLength)
    $netz = Get-NetNetworkAddress -IPAddress $NetworkAddress -PrefixLength $PrefixLength
    $o = $netz.Split('.')
    if ($PrefixLength -ge 24) { return @("$($o[2]).$($o[1]).$($o[0]).in-addr.arpa") }
    if ($PrefixLength -eq 16) { return @("$($o[1]).$($o[0]).in-addr.arpa") }
    if ($PrefixLength -eq 8) { return @("$($o[0]).in-addr.arpa") }
    if ($PrefixLength -gt 16) {
        $anzahl = [int][Math]::Pow(2, 24 - $PrefixLength)
        $liste = @()
        for ($i = 0; $i -lt $anzahl; $i++) { $liste += "$([int]$o[2] + $i).$($o[1]).$($o[0]).in-addr.arpa" }
        return $liste
    }
    $anzahl = [int][Math]::Pow(2, 16 - $PrefixLength)
    $liste = @()
    for ($i = 0; $i -lt $anzahl; $i++) { $liste += "$([int]$o[1] + $i).$($o[0]).in-addr.arpa" }
    return $liste
}

function Get-NetPtrName {
    <#
    .SYNOPSIS
        Liefert den relativen PTR-Namen einer Adresse innerhalb einer Reverse-Zone.
        Liegt die Adresse nicht in der Zone, wird $null geliefert.
    #>
    param([Parameter(Mandatory = $true)][string]$IPAddress, [Parameter(Mandatory = $true)][string]$ZoneName)
    $o = $IPAddress.Split('.')
    $umgekehrt = @($o[3], $o[2], $o[1], $o[0])
    $zone = $ZoneName.ToLower() -replace '\.in-addr\.arpa\.?$', ''
    $zonenTeile = @($zone.Split('.'))
    $anzahl = $zonenTeile.Count
    if (($anzahl -lt 1) -or ($anzahl -gt 3)) { return $null }
    $erwartet = ($umgekehrt[(4 - $anzahl)..3]) -join '.'
    if ($erwartet -ne $zone) { return $null }
    return (($umgekehrt[0..(3 - $anzahl)]) -join '.')
}

function Find-NetReverseZone {
    <#
    .SYNOPSIS
        Sucht aus einer Liste von Zonennamen die passendste Reverse-Zone fuer eine Adresse.
    #>
    param([Parameter(Mandatory = $true)][string]$IPAddress, [string[]]$ZoneNames = @())
    $best = $null
    $bestLaenge = 0
    foreach ($zone in $ZoneNames) {
        if ($zone -notmatch 'in-addr\.arpa\.?$') { continue }
        $name = Get-NetPtrName -IPAddress $IPAddress -ZoneName $zone
        if ($null -ne $name) {
            $laenge = $zone.Split('.').Count
            if ($laenge -gt $bestLaenge) { $best = $zone; $bestLaenge = $laenge }
        }
    }
    return $best
}

function Test-NetHostName {
    <#
    .SYNOPSIS
        Prueft einen Computernamen (NetBIOS-tauglich). Liefert $null wenn gueltig, sonst den Grund.
    #>
    param([AllowEmptyString()][string]$Name)
    if (-not $Name) { return 'Der Name darf nicht leer sein.' }
    if ($Name.Length -gt 15) { return 'Der Name darf hoechstens 15 Zeichen lang sein (NetBIOS-Grenze).' }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'Erlaubt sind nur Buchstaben A-Z, Ziffern und Bindestrich.' }
    if ($Name -match '^-|-$') { return 'Der Name darf nicht mit einem Bindestrich beginnen oder enden.' }
    if ($Name -match '^\d+$') { return 'Der Name darf nicht nur aus Ziffern bestehen.' }
    return $null
}

function Test-NetDnsLabel {
    param([AllowEmptyString()][string]$Label)
    return ($Label -match '^[A-Za-z0-9_]([A-Za-z0-9-_]{0,61}[A-Za-z0-9])?$')
}

function Test-NetDomainName {
    <#
    .SYNOPSIS
        Prueft einen DNS-Domaenennamen fuer AD. Liefert Gueltig, Fehler und Warnungen.
    #>
    param([AllowEmptyString()][string]$Name)
    $fehler = $null
    $warnungen = @()
    $n = ([string]$Name).Trim().TrimEnd('.').ToLower()
    if (-not $n) { $fehler = 'Der Domaenenname darf nicht leer sein.' }
    elseif ($n.Length -gt 253) { $fehler = 'Der Domaenenname ist zu lang (hoechstens 253 Zeichen).' }
    elseif ($n -notmatch '\.') { $fehler = 'Ein einteiliger Name (Single-Label wie "firma") ist nicht erlaubt. Beispiel: ad.firma.ch' }
    else {
        foreach ($label in $n.Split('.')) {
            if (-not (Test-NetDnsLabel -Label $label) -or $label.Contains('_')) {
                $fehler = "Der Teil '$label' ist ungueltig (nur a-z, 0-9 und Bindestrich, nicht am Anfang oder Ende, hoechstens 63 Zeichen)."
                break
            }
        }
        if ((-not $fehler) -and ($n.Split('.')[-1] -match '^\d+$')) { $fehler = 'Die letzte Stelle darf nicht nur aus Ziffern bestehen.' }
    }
    if (-not $fehler) {
        if ($n -match '\.local$') { $warnungen += '.local ist fuer Multicast-DNS (Bonjour) reserviert und macht Probleme mit Apple-Geraeten und Zertifikaten. Besser eine Subdomain der eigenen Domain verwenden, z. B. ad.firma.ch.' }
        if ($n.Split('.').Count -eq 2) { $warnungen += 'Empfohlen ist eine Subdomain der eigenen Internet-Domain (z. B. ad.firma.ch statt firma.ch), damit interne und externe Namen nicht kollidieren.' }
    }
    return [pscustomobject]@{ Gueltig = (-not $fehler); Fehler = $fehler; Warnungen = $warnungen; Name = $n }
}

function Get-NetNetBiosSuggestion {
    <#
    .SYNOPSIS
        Schlaegt einen NetBIOS-Domaenennamen aus dem DNS-Namen vor (erster Teil, max. 15 Zeichen).
    #>
    param([Parameter(Mandatory = $true)][string]$DomainName)
    $teile = $DomainName.Split('.')
    $basis = $teile[0]
    if ((($basis -eq 'ad') -or ($basis -eq 'corp') -or ($basis -eq 'intern')) -and ($teile.Count -gt 2)) { $basis = $teile[1] }
    $basis = ($basis -replace '[^A-Za-z0-9-]', '').ToUpper()
    if ($basis.Length -gt 15) { $basis = $basis.Substring(0, 15) }
    return $basis
}
