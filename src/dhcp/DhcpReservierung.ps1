# Reservierungen (auch aus einem bestehenden Lease in einem Schritt) und Leases.

function ConvertTo-NetMacAddress {
    <#
    .SYNOPSIS
        Normalisiert eine MAC-Adresse auf aa-bb-cc-dd-ee-ff. Liefert $null bei ungueltiger Eingabe.
    #>
    param([AllowEmptyString()][string]$Text)
    $roh = ($Text -replace '[\s:.-]', '').ToLower()
    if ($roh -notmatch '^[0-9a-f]{12}$') { return $null }
    return (($roh -split '(..)' | Where-Object { $_ }) -join '-')
}

function Get-NetDhcpLeaseList {
    param([string]$ScopeId)
    $scopes = @()
    if ($ScopeId) { $scopes = @($ScopeId) } else { $scopes = @(Get-NetDhcpScopeList | ForEach-Object { $_.ScopeId }) }
    $liste = @()
    foreach ($id in $scopes) {
        foreach ($l in @(Get-NetSafe -Beschreibung "Leases $id" -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id })) {
            if ($null -eq $l) { continue }
            $liste += [pscustomobject]@{
                ScopeId  = $id
                IP       = ConvertTo-NetString -Wert $l.IPAddress
                Mac      = [string]$l.ClientId
                Name     = [string]$l.HostName
                Status   = [string]$l.AddressState
                Ablauf   = $l.LeaseExpiryTime
            }
        }
    }
    return $liste
}

function Test-NetDhcpReservation {
    <#
    .SYNOPSIS
        Prueft eine geplante Reservierung: im Scope-Bereich, nicht im Ausschluss, nicht belegt.
        Liefert eine Liste von Problemen (leer = in Ordnung).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Scope,
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][string]$Mac,
        [object[]]$Ausschluesse = $null,
        [object[]]$Reservierungen = $null,
        [object[]]$Leases = $null
    )
    $probleme = @()
    $id = $Scope.ScopeId
    if (-not (Test-NetIPInRange -IPAddress $IPAddress -Start $Scope.Start -Ende $Scope.Ende)) {
        $probleme += ('{0} liegt nicht im Bereich des Scopes ({1} - {2}).' -f $IPAddress, $Scope.Start, $Scope.Ende)
    }
    if ($null -eq $Ausschluesse) { $Ausschluesse = @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id }) }
    foreach ($a in @($Ausschluesse | Where-Object { $_ })) {
        if (Test-NetIPInRange -IPAddress $IPAddress -Start (ConvertTo-NetString $a.StartRange) -Ende (ConvertTo-NetString $a.EndRange)) {
            $probleme += ('{0} liegt in einem Ausschluss ({1} - {2}).' -f $IPAddress, (ConvertTo-NetString $a.StartRange), (ConvertTo-NetString $a.EndRange))
        }
    }
    if ($null -eq $Reservierungen) { $Reservierungen = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id }) }
    foreach ($r in @($Reservierungen | Where-Object { $_ })) {
        $rIp = ConvertTo-NetString $r.IPAddress
        $rMac = ConvertTo-NetMacAddress -Text ([string]$r.ClientId)
        if ($rIp -eq $IPAddress -and $rMac -ne $Mac) { $probleme += ('{0} ist schon fuer {1} ({2}) reserviert.' -f $IPAddress, $rMac, $r.Name) }
        if ($rMac -eq $Mac -and $rIp -ne $IPAddress) { $probleme += ('Dieses Geraet ({0}) hat schon die Reservierung {1}.' -f $Mac, $rIp) }
    }
    if ($null -eq $Leases) { $Leases = @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id }) }
    foreach ($l in @($Leases | Where-Object { $_ })) {
        $lIp = ConvertTo-NetString $l.IPAddress
        $lMac = ConvertTo-NetMacAddress -Text ([string]$l.ClientId)
        if ($lIp -eq $IPAddress -and $lMac -and $lMac -ne $Mac) { $probleme += ('{0} ist zurzeit an ein anderes Geraet vergeben ({1}, {2}).' -f $IPAddress, $lMac, $l.HostName) }
    }
    return $probleme
}

function Add-NetDhcpReservation {
    <#
    .SYNOPSIS
        Reservierung anlegen (mit Pruefung), optional mit DNS-Eintrag.
    #>
    param([object]$Scope, [string]$IPAddress, [string]$Mac, [string]$Name, [string]$Beschreibung = '', [switch]$OhneDnsFrage)
    if (-not (Test-NetDhcpReady)) { return $false }
    if (-not $Scope) { $Scope = Select-NetDhcpScope -Titel 'Reservierung in welchem Scope?' }
    if (-not $Scope) { return $false }
    if (-not $Mac) {
        $Mac = Read-NetText -Frage 'MAC-Adresse des Geraets (z. B. 00-15-5D-01-02-03)' -Pruefung { param($t) if (ConvertTo-NetMacAddress -Text $t) { $null } else { 'Bitte 12 Hex-Zeichen eingeben, z. B. 00-15-5D-01-02-03.' } }
        if (-not $Mac) { return $false }
    }
    $Mac = ConvertTo-NetMacAddress -Text $Mac
    if (-not $Mac) { Write-Log -Level Fehler -Message 'Ungueltige MAC-Adresse.'; return $false }
    if (-not $IPAddress) {
        $IPAddress = Read-NetIPAddress -Frage 'Reservierte IP-Adresse' -Netz $Scope.ScopeId -Prefix $Scope.Prefix
        if (-not $IPAddress) { return $false }
    }
    if (-not $Name) {
        $Name = Read-NetText -Frage 'Name des Geraets (z. B. drucker-buero)' -Pruefung { param($t) Test-NetDnsRecordName -Name $t }
        if (-not $Name) { return $false }
    }
    $id = $Scope.ScopeId
    $vorhanden = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })
    $gleich = @($vorhanden | Where-Object { $_ -and (ConvertTo-NetString $_.IPAddress) -eq $IPAddress -and (ConvertTo-NetMacAddress -Text ([string]$_.ClientId)) -eq $Mac })
    if ($gleich.Count -gt 0) { Write-Log -Level OK -Message "Die Reservierung $IPAddress fuer $Mac existiert bereits. Nichts zu tun."; return $true }
    $probleme = @(Test-NetDhcpReservation -Scope $Scope -IPAddress $IPAddress -Mac $Mac -Reservierungen $vorhanden)
    if ($probleme.Count -gt 0) {
        foreach ($p in $probleme) { Write-Log -Level Fehler -Message $p }
        Write-Log -Message 'Naechster Schritt: eine andere Adresse waehlen bzw. den Konflikt beheben. Die Reservierung wird nicht angelegt.'
        return $false
    }
    $ip = $IPAddress
    $mac = $Mac
    $geraet = $Name
    $text = $Beschreibung
    $r = Invoke-NetChange -Titel "Reservierung $ip fuer $geraet anlegen" -Stufe Bestaetigen -Vorher '(keine Reservierung)' -Nachher @{ Scope = $id; IP = $ip; MAC = $mac; Name = $geraet } -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Reservation -ScopeId $id -IPAddress $ip -ClientId $mac -Name $geraet -Description $text
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Reservation'; Parameter = @{ IPAddress = $ip } }
    $ok = [bool]($r.Erfolg -and -not $r.Probelauf)
    if ($ok -and -not $OhneDnsFrage -and (Test-NetCommand -Name 'Add-NetDnsRecord') -and (Test-NetDnsReady -Still)) {
        $zone = Get-NetDomainName
        if ($zone -and (Read-NetYesNo -Frage ("Passenden DNS-Eintrag {0}.{1} -> {2} (mit PTR) anlegen?" -f $geraet, $zone, $ip) -Vorschlag $true)) {
            Add-NetDnsRecord -Zone $zone -Name $geraet -Typ A -Daten @{ IPv4Address = $ip } -MitPtr $true | Out-Null
        }
    }
    return $ok
}

function Add-NetDhcpReservationFromLease {
    <#
    .SYNOPSIS
        Macht aus einem bestehenden Lease in einem Schritt eine Reservierung.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    $leases = @(Get-NetDhcpLeaseList | Where-Object { $_.Status -like 'Active*' -and $_.Status -notlike '*Reservation*' })
    if ($leases.Count -eq 0) { Write-Log -Level Warn -Message 'Es gibt keine aktiven Leases ohne Reservierung.'; return $false }
    $l = Select-NetItem -Elemente $leases -Titel 'Welches Geraet soll seine Adresse behalten?' -Eigenschaften @('IP', 'Mac', 'Name', 'ScopeId')
    if (-not $l) { return $false }
    $scope = @(Get-NetDhcpScopeList | Where-Object { $_.ScopeId -eq $l.ScopeId }) | Select-Object -First 1
    $name = ([string]$l.Name).Split('.')[0]
    if (-not $name) { $name = 'geraet-' + ($l.IP -replace '\.', '-') }
    return (Add-NetDhcpReservation -Scope $scope -IPAddress $l.IP -Mac $l.Mac -Name $name -Beschreibung 'aus Lease uebernommen (NetSetup)' -OhneDnsFrage)
}

function Show-NetDhcpReservation {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'Reservierungen'
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $id = $s.ScopeId
        $liste = @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })
        Write-Host ('  Scope {0} ({1}): {2} Reservierung(en)' -f $id, $s.Name, @($liste | Where-Object { $_ }).Count) -ForegroundColor White
        foreach ($r in @($liste | Where-Object { $_ })) {
            $ip = ConvertTo-NetString $r.IPAddress
            $warn = ''
            if (-not (Test-NetIPInRange -IPAddress $ip -Start $s.Start -Ende $s.Ende)) { $warn = '  [WARN] ausserhalb des Bereichs' }
            Write-Host ('    {0,-15} {1,-18} {2}{3}' -f $ip, $r.ClientId, $r.Name, $warn)
        }
    }
}

function Remove-NetDhcpReservation {
    if (-not (Test-NetDhcpReady)) { return }
    $alle = @()
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $id = $s.ScopeId
        foreach ($r in @(Get-NetSafe -Beschreibung 'Reservierungen' -Standard @() -Abfrage { Get-DhcpServerv4Reservation -ScopeId $id })) {
            if ($r) { $alle += [pscustomobject]@{ ScopeId = $id; IP = (ConvertTo-NetString $r.IPAddress); Mac = [string]$r.ClientId; Name = [string]$r.Name; Beschreibung = [string]$r.Description } }
        }
    }
    $w = Select-NetItem -Elemente $alle -Titel 'Welche Reservierung loeschen?' -Eigenschaften @('ScopeId', 'IP', 'Mac', 'Name')
    if (-not $w) { return }
    $ip = $w.IP
    Invoke-NetChange -Titel "Reservierung $ip ($($w.Name)) loeschen" -Stufe Bestaetigen -Vorher ('{0} {1} {2}' -f $w.IP, $w.Mac, $w.Name) -Nachher '(geloescht)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4Reservation -IPAddress $ip
    } -Rueckgaengig @{ Befehl = 'Add-DhcpServerv4Reservation'; Parameter = @{ ScopeId = $w.ScopeId; IPAddress = $w.IP; ClientId = $w.Mac; Name = $w.Name; Description = $w.Beschreibung } } | Out-Null
}

function Show-NetDhcpLease {
    param([string]$Suche)
    if (-not (Test-NetDhcpReady)) { return }
    $liste = @(Get-NetDhcpLeaseList)
    if ($Suche) { $liste = @($liste | Where-Object { $_.IP -like "*$Suche*" -or $_.Mac -like "*$Suche*" -or $_.Name -like "*$Suche*" }) }
    Write-NetTitle -Titel ('Leases ({0})' -f $liste.Count)
    foreach ($l in ($liste | Sort-Object -Property { ConvertTo-NetIPv4UInt32 -IPAddress $_.IP })) {
        Write-Host ('  {0,-15} {1,-18} {2,-30} {3,-18} bis {4}' -f $l.IP, $l.Mac, $l.Name, $l.Status, $l.Ablauf)
    }
}

function Find-NetDhcpLease {
    $s = Read-NetText -Frage 'Suchbegriff (Teil von IP, MAC oder Name)'
    if ($s) { Show-NetDhcpLease -Suche $s }
}

function Remove-NetDhcpLease {
    if (-not (Test-NetDhcpReady)) { return }
    $l = Select-NetItem -Elemente @(Get-NetDhcpLeaseList) -Titel 'Welches Lease loeschen?' -Eigenschaften @('IP', 'Mac', 'Name', 'Status')
    if (-not $l) { return }
    $ip = $l.IP
    Invoke-NetChange -Titel "Lease $ip ($($l.Name)) loeschen" -Stufe Bestaetigen -Vorher ('{0} {1} {2}' -f $l.IP, $l.Mac, $l.Name) -Nachher '(geloescht - das Geraet bekommt beim naechsten Erneuern eine neue Adresse)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4Lease -IPAddress $ip
    } | Out-Null
}

function Show-NetDhcpReservationMenu {
    $eintraege = @(
        @{ Text = 'Reservierungen anzeigen'; Aktion = 'Show-NetDhcpReservation'; Hilfe = 'Alle Reservierungen pro Scope; Reservierungen ausserhalb des Bereichs werden markiert.' },
        @{ Text = 'Reservierung anlegen'; Aktion = { Add-NetDhcpReservation | Out-Null }; Hilfe = "Feste Adresse fuer ein Geraet (MAC). Vorher wird geprueft: im Bereich, nicht im Ausschluss, nicht an ein anderes Geraet vergeben.`nAuf Wunsch wird gleich der DNS-Eintrag (A + PTR) angelegt." },
        @{ Text = 'Reservierung aus bestehendem Lease'; Aktion = { Add-NetDhcpReservationFromLease | Out-Null }; Hilfe = 'Ein Geraet behaelt seine aktuelle Adresse dauerhaft - in einem Schritt.' },
        @{ Text = 'Reservierung loeschen'; Aktion = 'Remove-NetDhcpReservation'; Hilfe = 'Loescht eine Reservierung (rueckgaengig moeglich).' },
        @{ Text = 'Leases anzeigen'; Aktion = { Show-NetDhcpLease }; Hilfe = 'Alle vergebenen Adressen mit MAC, Name, Status und Ablauf.' },
        @{ Text = 'Lease suchen'; Aktion = 'Find-NetDhcpLease'; Hilfe = 'Sucht nach Teil von IP, MAC oder Name.' },
        @{ Text = 'Lease loeschen'; Aktion = 'Remove-NetDhcpLease'; Hilfe = 'Gibt eine Adresse frei. Das Geraet holt sich beim naechsten Erneuern eine neue Adresse.' },
        @{ Text = 'Konflikterkennung einstellen'; Aktion = { Set-NetDhcpConflictDetection | Out-Null }; Hilfe = 'Der Server pingt eine Adresse vor der Vergabe (Vorschlag: 1 Versuch), um Doppelvergaben zu vermeiden.' }
    )
    Show-NetMenu -Titel 'DHCP - Reservierungen und Leases' -Eintraege $eintraege
}
