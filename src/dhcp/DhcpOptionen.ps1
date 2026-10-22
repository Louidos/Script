# Zusatzoptionen (standardmaessig aus): NTP (042), PXE (066/067) und DNS-Suchliste (119).
# Option 119 ist in Windows nicht vordefiniert: sie wird mit Add-DhcpServerv4OptionDefinition
# angelegt und der Wert nach RFC 3397 kodiert.

$script:NetZusatzOptionen = @{
    42  = 'NTP-Server (042): Zeitserver fuer die Clients. Domaenen-Clients holen die Zeit ohnehin vom DC; sinnvoll fuer Geraete ohne Domaene (Drucker, Telefone).'
    66  = 'PXE-Bootserver (066): Name oder IP des TFTP-Servers fuer Netzwerkboot (z. B. WDS/MDT). Nur noetig, wenn Clients per Netzwerk booten und kein IP-Helper/WDS-Proxy genutzt wird.'
    67  = 'PXE-Bootdatei (067): Pfad der Bootdatei, z. B. boot\x64\wdsmgfw.efi (UEFI) oder boot\x64\wdsnbp.com (BIOS).'
    119 = 'DNS-Suchliste (119): weitere Domaenen, die Clients beim Aufloesen kurzer Namen anhaengen. Windows-Clients werten 119 erst ab Windows 10 1803 aus; Linux und macOS nutzen sie.'
}

function ConvertTo-NetDhcpSearchList {
    <#
    .SYNOPSIS
        Kodiert eine Liste von Domaenen nach RFC 3397 (DNS-Namen im Wire-Format, ohne Kompression).
    .OUTPUTS
        Byte-Array.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Domaenen)
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($d in $Domaenen) {
        $name = $d.Trim().TrimEnd('.')
        if (-not $name) { continue }
        foreach ($label in $name.Split('.')) {
            $ascii = [System.Text.Encoding]::ASCII.GetBytes($label.ToLower())
            if ($ascii.Length -lt 1 -or $ascii.Length -gt 63) { throw "Ungueltiger Teil '$label' in $d." }
            $bytes.Add([byte]$ascii.Length)
            foreach ($b in $ascii) { $bytes.Add($b) }
        }
        $bytes.Add([byte]0)
    }
    if ($bytes.Count -gt 255) { throw 'Die Suchliste ist zu lang (hoechstens 255 Bytes in einer Option).' }
    return [byte[]]$bytes.ToArray()
}

function ConvertFrom-NetDhcpSearchList {
    <#
    .SYNOPSIS
        Dekodiert eine RFC-3397-Suchliste (ohne Kompression) in Domaenennamen.
    #>
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $liste = @()
    $labels = @()
    $i = 0
    while ($i -lt $Bytes.Length) {
        $laenge = [int]$Bytes[$i]
        $i++
        if ($laenge -eq 0) { if ($labels.Count) { $liste += ($labels -join '.') }; $labels = @(); continue }
        if ($laenge -ge 192) { throw 'Komprimierte Suchlisten werden nicht unterstuetzt.' }
        $labels += [System.Text.Encoding]::ASCII.GetString($Bytes, $i, $laenge)
        $i += $laenge
    }
    return $liste
}

function Install-NetDhcpOption119 {
    <#
    .SYNOPSIS
        Legt die Optionsdefinition 119 an, falls sie fehlt.
    #>
    $def = Get-NetSafe -Beschreibung 'Option 119' -Abfrage { Get-DhcpServerv4OptionDefinition -OptionId 119 }
    if ($def) { return $true }
    $r = Invoke-NetChange -Titel 'DHCP-Optionsdefinition 119 (DNS-Suchliste) anlegen' -Stufe Bestaetigen -Vorher '(nicht definiert)' -Nachher 'Option 119 "Domain Search List", Typ BinaryData (RFC 3397)' -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4OptionDefinition -OptionId 119 -Name 'Domain Search List' -Type BinaryData -Description 'DNS-Suchliste nach RFC 3397 (angelegt von NetSetup)'
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Set-NetDhcpExtraOption {
    <#
    .SYNOPSIS
        Setzt eine Zusatzoption auf Server- oder Scope-Ebene (042, 066, 067, 119).
    #>
    param([ValidateSet(0, 42, 66, 67, 119)][int]$OptionId = 0)
    if (-not (Test-NetDhcpReady)) { return $false }
    if ($OptionId -eq 0) {
        $ids = @(42, 66, 67, 119)
        $i = Read-NetChoice -Frage 'Welche Zusatzoption?' -Optionen @($ids | ForEach-Object { $script:NetZusatzOptionen[$_] }) -Vorschlag 1
        if ($i -lt 0) { return $false }
        $OptionId = $ids[$i]
    }
    Write-NetText -Text $script:NetZusatzOptionen[$OptionId]
    $ebene = Read-NetChoice -Frage 'Fuer wen?' -Optionen @('Alle Scopes (Server-Ebene)', 'Nur einen Scope') -Vorschlag 2
    if ($ebene -lt 0) { return $false }
    $scopeId = ''
    if ($ebene -eq 1) {
        $s = Select-NetDhcpScope -Titel 'Fuer welchen Scope?'
        if (-not $s) { return $false }
        $scopeId = $s.ScopeId
    }
    $werte = @()
    $anzeige = ''
    switch ($OptionId) {
        42 {
            $t = Read-NetText -Frage 'NTP-Server (IPv4, mit Komma getrennt)' -Vorschlag ((@(Get-NetDcAddress -Zustand (Get-NetSetupState))) -join ',') -Pruefung {
                param($x)
                foreach ($y in $x.Split(',')) { if (-not (Test-NetIPv4Address -Text $y.Trim())) { return "'$y' ist keine gueltige IPv4-Adresse." } }
                return $null
            }
            if (-not $t) { return $false }
            $werte = @($t.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $anzeige = $werte -join ', '
        }
        66 {
            $t = Read-NetText -Frage 'Name oder IP des Bootservers' -Pruefung { param($x) if ($x -match '^[A-Za-z0-9.-]+$') { $null } else { 'Nur Name oder IP-Adresse.' } }
            if (-not $t) { return $false }
            $werte = @($t); $anzeige = $t
        }
        67 {
            $t = Read-NetText -Frage 'Bootdatei' -Vorschlag 'boot\x64\wdsmgfw.efi' -Pruefung { param($x) if ($x -match '^[A-Za-z0-9._\\/-]+$') { $null } else { 'Ungueltige Zeichen im Pfad.' } }
            if (-not $t) { return $false }
            $werte = @($t); $anzeige = $t
        }
        119 {
            $t = Read-NetText -Frage 'Domaenen der Suchliste (mit Komma getrennt)' -Vorschlag (Get-NetDomainName) -Pruefung {
                param($x)
                foreach ($y in $x.Split(',')) { $e = (Test-NetDomainName -Name $y.Trim()).Fehler; if ($e) { return $e } }
                return $null
            }
            if (-not $t) { return $false }
            $domaenen = @($t.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if (-not (Install-NetDhcpOption119)) { return $false }
            $werte = @(ConvertTo-NetDhcpSearchList -Domaenen $domaenen | ForEach-Object { [string][int]$_ })
            $anzeige = ($domaenen -join ', ') + (' ({0} Bytes nach RFC 3397)' -f $werte.Count)
        }
    }
    $alt = Get-NetDhcpScopeOption -ScopeId $scopeId
    $altWert = $alt[$OptionId]
    $p = @{ OptionId = $OptionId; Value = $werte; Force = $true }
    $rp = @{ OptionId = $OptionId }
    if ($scopeId) { $p.ScopeId = $scopeId; $rp.ScopeId = $scopeId }
    $rueck = @{ Befehl = 'Remove-DhcpServerv4OptionValue'; Parameter = $rp }
    if ($altWert) { $rueck = @{ Befehl = 'Set-DhcpServerv4OptionValue'; Parameter = ($rp + @{ Value = $altWert; Force = $true }) } }
    $r = Invoke-NetChange -Titel ('DHCP-Option {0:000} setzen ({1})' -f $OptionId, $(if ($scopeId) { 'Scope ' + $scopeId } else { 'Server' })) -Stufe Bestaetigen -Vorher $(if ($altWert) { $altWert -join ', ' } else { '(nicht gesetzt)' }) -Nachher $anzeige -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4OptionValue @p
    } -Rueckgaengig $rueck
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Remove-NetDhcpExtraOption {
    if (-not (Test-NetDhcpReady)) { return }
    $eintraege = @()
    foreach ($nr in @(42, 66, 67, 119)) {
        $server = Get-NetDhcpScopeOption
        if ($server[$nr]) { $eintraege += [pscustomobject]@{ Ebene = 'Server'; ScopeId = ''; Option = $nr; Wert = ($server[$nr] -join ', ') } }
    }
    foreach ($s in @(Get-NetDhcpScopeList)) {
        $o = Get-NetDhcpScopeOption -ScopeId $s.ScopeId
        foreach ($nr in @(42, 66, 67, 119)) { if ($o[$nr]) { $eintraege += [pscustomobject]@{ Ebene = 'Scope'; ScopeId = $s.ScopeId; Option = $nr; Wert = ($o[$nr] -join ', ') } } }
    }
    $wahl = Select-NetItem -Elemente $eintraege -Titel 'Welche Zusatzoption entfernen?' -Eigenschaften @('Ebene', 'ScopeId', 'Option', 'Wert')
    if (-not $wahl) { return }
    $p = @{ OptionId = [int]$wahl.Option }
    if ($wahl.ScopeId) { $p.ScopeId = $wahl.ScopeId }
    $altWert = @($wahl.Wert.Split(',') | ForEach-Object { $_.Trim() })
    Invoke-NetChange -Titel ('DHCP-Option {0:000} entfernen' -f [int]$wahl.Option) -Stufe Bestaetigen -Vorher $wahl.Wert -Nachher '(nicht gesetzt)' -BackupBereich @('Dhcp') -Aktion {
        Remove-DhcpServerv4OptionValue @p
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4OptionValue'; Parameter = ($p + @{ Value = $altWert; Force = $true }) } | Out-Null
}

function Show-NetDhcpExtraOptionMenu {
    $eintraege = @(
        @{ Text = 'Zusatzoption setzen (042, 066, 067, 119)'; Aktion = { Set-NetDhcpExtraOption | Out-Null }; Hilfe = "Alle Zusatzoptionen sind standardmaessig aus und nur bei Bedarf noetig.`n042 NTP-Server, 066/067 PXE-Netzwerkboot, 119 DNS-Suchliste (wird bei Bedarf definiert und nach RFC 3397 kodiert)." },
        @{ Text = 'Zusatzoption entfernen'; Aktion = 'Remove-NetDhcpExtraOption'; Hilfe = 'Entfernt eine gesetzte Zusatzoption auf Server- oder Scope-Ebene (rueckgaengig moeglich).' }
    )
    Show-NetMenu -Titel 'DHCP - Zusatzoptionen' -Eintraege $eintraege
}
