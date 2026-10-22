# DNS-Grundlagen: Rolle pruefen/installieren, Zonen auswaehlen, Eintraege lesen und vergleichen.

function Install-NetDnsRole {
    <#
    .SYNOPSIS
        Installiert die DNS-Server-Rolle und/oder die Verwaltungstools, falls sie fehlen.
    #>
    $f = Get-NetFeatureState
    if ($f['DNS'] -eq 'Installed' -and $f['RSAT-DNS-Server'] -eq 'Installed' -and (Test-NetCommand -Name 'Get-DnsServerZone')) {
        Write-Log -Level OK -Message 'DNS-Server-Rolle und Verwaltungstools sind installiert.'
        return $true
    }
    $namen = @()
    if ($f['DNS'] -ne 'Installed') { $namen += 'DNS' }
    if ($f['RSAT-DNS-Server'] -ne 'Installed') { $namen += 'RSAT-DNS-Server' }
    if ($namen.Count -eq 0) { $namen = @('RSAT-DNS-Server') }
    $r = Invoke-NetChange -Titel ('Windows-Funktion(en) installieren: ' + ($namen -join ', ')) -Stufe Bestaetigen `
        -Vorher @{ DNS = (ConvertTo-NetFeatureText -Status $f['DNS']); 'RSAT-DNS-Server' = (ConvertTo-NetFeatureText -Status $f['RSAT-DNS-Server']) } `
        -Nachher @{ DNS = 'installiert'; 'RSAT-DNS-Server' = 'installiert' } -Aktion {
        $erg = Install-WindowsFeature -Name $namen -IncludeManagementTools
        if ($erg -and $erg.PSObject.Properties['Success'] -and -not $erg.Success) { throw 'Die Installation ist fehlgeschlagen.' }
        Import-Module DnsServer -ErrorAction SilentlyContinue
    } -Rueckgaengig @{ Befehl = 'Uninstall-WindowsFeature'; Parameter = @{ Name = $namen } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Test-NetDnsReady {
    <#
    .SYNOPSIS
        Prueft, ob DNS verwaltet werden kann. Bietet sonst die Installation an.
    #>
    param([switch]$Still)
    $dienst = Get-NetSafe -Beschreibung 'Dienst DNS' -Abfrage { Get-Service -Name DNS }
    if ((Test-NetCommand -Name 'Get-DnsServerZone') -and $dienst) {
        if ([string]$dienst.Status -ne 'Running') {
            Write-Log -Level Warn -Message 'Der DNS-Dienst laeuft nicht.'
            if (-not $Still -and (Read-NetYesNo -Frage 'DNS-Dienst jetzt starten?' -Vorschlag $true)) {
                $r = Invoke-NetChange -Titel 'DNS-Dienst starten' -Stufe Automatisch -Aktion { Start-Service -Name DNS }
                return [bool]$r.Erfolg
            }
            return $false
        }
        return $true
    }
    if ($Still) { return $false }
    Write-Log -Level Warn -Message 'Der DNS-Server ist auf diesem Server nicht (vollstaendig) installiert.'
    if (Read-NetYesNo -Frage 'DNS-Server-Rolle jetzt installieren?' -Vorschlag $true) { return (Install-NetDnsRole) }
    return $false
}

function Get-NetDnsZoneInfo {
    <#
    .SYNOPSIS
        Liefert die Zonen (ohne automatisch erzeugte und TrustAnchors) als einfache Objekte.
    #>
    param([ValidateSet('Alle', 'Forward', 'Reverse', 'Primaer')][string]$Art = 'Alle')
    $liste = @()
    foreach ($z in @(Get-NetSafe -Beschreibung 'Get-DnsServerZone' -Standard @() -Abfrage { Get-DnsServerZone })) {
        if ($null -eq $z -or $z.IsAutoCreated -or [string]$z.ZoneName -eq 'TrustAnchors') { continue }
        $o = [pscustomobject]@{
            Name         = [string]$z.ZoneName
            Typ          = [string]$z.ZoneType
            AdIntegriert = [bool]$z.IsDsIntegrated
            Reverse      = [bool]$z.IsReverseLookupZone
            Updates      = [string]$z.DynamicUpdate
            Replikation  = [string]$z.ReplicationScope
        }
        switch ($Art) {
            'Forward' { if (-not $o.Reverse -and $o.Typ -ne 'Forwarder') { $liste += $o } }
            'Reverse' { if ($o.Reverse) { $liste += $o } }
            'Primaer' { if ($o.Typ -eq 'Primary') { $liste += $o } }
            default { $liste += $o }
        }
    }
    return $liste
}

function Select-NetDnsZone {
    param([ValidateSet('Alle', 'Forward', 'Reverse', 'Primaer')][string]$Art = 'Alle', [string]$Titel = 'Zone waehlen')
    $zonen = @(Get-NetDnsZoneInfo -Art $Art | Where-Object { $_.Typ -eq 'Primary' -or $Art -eq 'Alle' })
    if ($zonen.Count -eq 0) {
        Write-Log -Level Warn -Message 'Es gibt keine passende Zone. Zuerst eine Zone anlegen.'
        return $null
    }
    if ($zonen.Count -eq 1) { return $zonen[0] }
    return (Select-NetItem -Elemente $zonen -Titel $Titel -Eigenschaften @('Name', 'Typ', 'Updates', 'Replikation'))
}

function Show-NetDnsZone {
    Write-NetTitle -Titel 'DNS-Zonen'
    $zonen = @(Get-NetDnsZoneInfo)
    if ($zonen.Count -eq 0) { Write-Log -Level Warn -Message 'Keine Zonen vorhanden.'; return }
    Write-Host ('  {0,-38} {1,-10} {2,-16} {3}' -f 'Zone', 'Typ', 'Speicherung', 'Dynamische Updates')
    foreach ($z in $zonen) {
        $art = 'Datei'
        if ($z.AdIntegriert) { $art = 'AD (' + $z.Replikation + ')' }
        $farbe = 'Gray'
        if ($z.Typ -eq 'Primary' -and $z.Updates -eq 'None' -and -not $z.Reverse) { $farbe = 'Yellow' }
        Write-Host ('  {0,-38} {1,-10} {2,-16} {3}' -f $z.Name, $z.Typ, $art, (ConvertTo-NetDnsUpdateText -Wert $z.Updates)) -ForegroundColor $farbe
    }
}

function ConvertTo-NetDnsUpdateText {
    param([string]$Wert)
    switch ($Wert) {
        'Secure' { return 'nur sicher (empfohlen)' }
        'NonsecureAndSecure' { return 'sicher und unsicher' }
        'None' { return 'aus' }
        default { return $Wert }
    }
}

function ConvertTo-NetDnsRecord {
    <#
    .SYNOPSIS
        Wandelt einen DNS-Eintrag in ein einfaches Objekt mit Typ, Daten (Hashtable) und Anzeigetext.
    #>
    param([Parameter(Mandatory = $true)][object]$Eintrag, [string]$Zone = '')
    $typ = [string]$Eintrag.RecordType
    $rd = $Eintrag.RecordData
    $daten = @{}
    $text = ''
    switch ($typ) {
        'A' { $daten.IPv4Address = ConvertTo-NetString -Wert $rd.IPv4Address; $text = $daten.IPv4Address }
        'AAAA' { $daten.IPv6Address = ConvertTo-NetString -Wert $rd.IPv6Address; $text = $daten.IPv6Address }
        'CNAME' { $daten.HostNameAlias = [string]$rd.HostNameAlias; $text = $daten.HostNameAlias }
        'MX' { $daten.MailExchange = [string]$rd.MailExchange; $daten.Preference = [int]$rd.Preference; $text = '{0} {1}' -f $daten.Preference, $daten.MailExchange }
        'SRV' { $daten.DomainName = [string]$rd.DomainName; $daten.Priority = [int]$rd.Priority; $daten.Weight = [int]$rd.Weight; $daten.Port = [int]$rd.Port; $text = '{0} {1} {2} {3}' -f $daten.Priority, $daten.Weight, $daten.Port, $daten.DomainName }
        'TXT' { $daten.DescriptiveText = [string]$rd.DescriptiveText; $text = $daten.DescriptiveText }
        'PTR' { $daten.PtrDomainName = [string]$rd.PtrDomainName; $text = $daten.PtrDomainName }
        'NS' { $text = [string]$rd.NameServer }
        'SOA' { $text = [string]$rd.PrimaryServer }
        default { $text = '(' + $typ + ')' }
    }
    $zeit = $null
    if ($Eintrag.Timestamp) { $zeit = [datetime]$Eintrag.Timestamp }
    return [pscustomobject]@{
        Zone       = $Zone
        Name       = [string]$Eintrag.HostName
        Typ        = $typ
        Wert       = $text
        Daten      = $daten
        Zeitstempel = $zeit
        Statisch   = ($null -eq $zeit)
        Ttl        = [string]$Eintrag.TimeToLive
    }
}

function Get-NetDnsRecord {
    <#
    .SYNOPSIS
        Liest Eintraege einer Zone (optional nach Name und Typ gefiltert).
    #>
    param([Parameter(Mandatory = $true)][string]$Zone, [string]$Name, [string]$Typ)
    $p = @{ ZoneName = $Zone }
    if ($Name) { $p.Name = $Name }
    if ($Typ) { $p.RRType = $Typ }
    $liste = @()
    foreach ($e in @(Get-NetSafe -Beschreibung "Eintraege $Zone" -Standard @() -Abfrage { Get-DnsServerResourceRecord @p })) {
        if ($e) { $liste += (ConvertTo-NetDnsRecord -Eintrag $e -Zone $Zone) }
    }
    return $liste
}

function Test-NetDnsRecordEqual {
    param([hashtable]$A, [hashtable]$B)
    foreach ($k in $A.Keys) {
        if ([string]$A[$k] -ne [string]$B[$k]) {
            $x = ([string]$A[$k]).TrimEnd('.')
            $y = ([string]$B[$k]).TrimEnd('.')
            if ($x -ne $y) { return $false }
        }
    }
    return $true
}

function Add-NetDnsRecordExact {
    <#
    .SYNOPSIS
        Legt genau einen Eintrag an. Wird auch als Gegenaktion in der Rueckgaengig-Liste verwendet.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('A', 'AAAA', 'CNAME', 'MX', 'SRV', 'TXT', 'PTR')][string]$Typ,
        [Parameter(Mandatory = $true)][hashtable]$Daten,
        [switch]$CreatePtr
    )
    switch ($Typ) {
        'A' {
            if ($CreatePtr) { Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $Name -IPv4Address $Daten.IPv4Address -CreatePtr }
            else { Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $Name -IPv4Address $Daten.IPv4Address }
        }
        'AAAA' { Add-DnsServerResourceRecordAAAA -ZoneName $ZoneName -Name $Name -IPv6Address $Daten.IPv6Address }
        'CNAME' { Add-DnsServerResourceRecordCName -ZoneName $ZoneName -Name $Name -HostNameAlias $Daten.HostNameAlias }
        'MX' { Add-DnsServerResourceRecordMX -ZoneName $ZoneName -Name $Name -MailExchange $Daten.MailExchange -Preference ([uint16]$Daten.Preference) }
        'SRV' { Add-DnsServerResourceRecord -Srv -ZoneName $ZoneName -Name $Name -DomainName $Daten.DomainName -Priority ([uint16]$Daten.Priority) -Weight ([uint16]$Daten.Weight) -Port ([uint16]$Daten.Port) }
        'TXT' { Add-DnsServerResourceRecord -Txt -ZoneName $ZoneName -Name $Name -DescriptiveText $Daten.DescriptiveText }
        'PTR' { Add-DnsServerResourceRecordPtr -ZoneName $ZoneName -Name $Name -PtrDomainName $Daten.PtrDomainName }
    }
}

function Remove-NetDnsRecordExact {
    <#
    .SYNOPSIS
        Loescht genau den Eintrag mit diesen Daten (andere Eintraege gleichen Namens bleiben).
        Wird auch als Gegenaktion in der Rueckgaengig-Liste verwendet.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Typ,
        [Parameter(Mandatory = $true)][hashtable]$Daten
    )
    $treffer = 0
    foreach ($e in @(Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $Name -RRType $Typ -ErrorAction SilentlyContinue)) {
        if ($null -eq $e) { continue }
        $o = ConvertTo-NetDnsRecord -Eintrag $e -Zone $ZoneName
        if (Test-NetDnsRecordEqual -A $Daten -B $o.Daten) {
            $e | Remove-DnsServerResourceRecord -ZoneName $ZoneName -Force
            $treffer++
        }
    }
    if ($treffer -eq 0) { Write-Log -Level Warn -Message ('Eintrag {0} ({1}) in {2} war nicht (mehr) vorhanden.' -f $Name, $Typ, $ZoneName) }
}
