# DHCP-Scopes: Assistent (Name, Bereich, Maske, Ausschluesse, Lease, 003/006/015),
# mehrere Netze mit Hinweis auf DHCP-Relay, Superscopes, aktivieren/deaktivieren, loeschen.

function Get-NetDhcpScopeList {
    $liste = @()
    foreach ($s in @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Scope' -Standard @() -Abfrage { Get-DhcpServerv4Scope })) {
        if ($null -eq $s) { continue }
        $maske = ConvertTo-NetString -Wert $s.SubnetMask
        $liste += [pscustomobject]@{
            ScopeId    = ConvertTo-NetString -Wert $s.ScopeId
            Name       = [string]$s.Name
            Start      = ConvertTo-NetString -Wert $s.StartRange
            Ende       = ConvertTo-NetString -Wert $s.EndRange
            Maske      = $maske
            Prefix     = ConvertTo-NetPrefixLength -SubnetMask $maske
            Status     = [string]$s.State
            LeaseTage  = $(if ($s.LeaseDuration -is [TimeSpan]) { [Math]::Round($s.LeaseDuration.TotalDays, 2) } else { 0 })
            Superscope = [string]$s.SuperscopeName
        }
    }
    return $liste
}

function Select-NetDhcpScope {
    param([string]$Titel = 'Scope waehlen')
    $liste = @(Get-NetDhcpScopeList)
    if ($liste.Count -eq 0) { Write-Log -Level Warn -Message 'Es gibt noch keinen Scope. Zuerst einen Scope anlegen.'; return $null }
    if ($liste.Count -eq 1) { return $liste[0] }
    return (Select-NetItem -Elemente $liste -Titel $Titel -Eigenschaften @('ScopeId', 'Name', 'Start', 'Ende', 'Status'))
}

function Get-NetDhcpScopeOption {
    <#
    .SYNOPSIS
        Liefert die Optionen eines Scopes (oder des Servers ohne ScopeId) als Hashtable OptionId -> Werte.
    #>
    param([string]$ScopeId)
    $ergebnis = @{}
    $werte = @()
    if ($ScopeId) { $werte = @(Get-NetSafe -Beschreibung "Optionen $ScopeId" -Standard @() -Abfrage { Get-DhcpServerv4OptionValue -ScopeId $ScopeId }) }
    else { $werte = @(Get-NetSafe -Beschreibung 'Serveroptionen' -Standard @() -Abfrage { Get-DhcpServerv4OptionValue }) }
    foreach ($o in $werte) { if ($o) { $ergebnis[[int]$o.OptionId] = @($o.Value | ForEach-Object { [string]$_ }) } }
    return $ergebnis
}

function Show-NetDhcpScope {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCP-Scopes'
    $liste = @(Get-NetDhcpScopeList)
    if ($liste.Count -eq 0) { Write-Log -Level Warn -Message 'Keine Scopes vorhanden.'; return }
    $server = Get-NetDhcpScopeOption
    foreach ($s in $liste) {
        $id = $s.ScopeId
        $stat = Get-NetSafe -Beschreibung "Statistik $id" -Abfrage { Get-DhcpServerv4ScopeStatistics -ScopeId $id }
        $belegt = ''
        if ($stat) { $belegt = ('belegt {0:N0}% ({1} frei)' -f [double]$stat.PercentageInUse, $stat.Free) }
        $farbe = 'Gray'
        if ($s.Status -ne 'Active') { $farbe = 'DarkGray' }
        Write-Host ('  {0,-15} {1,-18} {2} - {3} /{4}  {5}  Lease {6} Tage  {7}' -f $id, $s.Name, $s.Start, $s.Ende, $s.Prefix, $s.Status, $s.LeaseTage, $belegt) -ForegroundColor $farbe
        $opt = Get-NetDhcpScopeOption -ScopeId $id
        foreach ($nr in @(3, 6, 15)) {
            $quelle = 'Scope'
            $wert = $opt[$nr]
            if (-not $wert -and $server[$nr]) { $wert = $server[$nr]; $quelle = 'Server' }
            $text = '(fehlt)'
            if ($wert) { $text = ($wert -join ', ') + ' [' + $quelle + ']' }
            Write-Host ('      Option {0,3}: {1}' -f $nr, $text)
        }
        $aus = @(Get-NetSafe -Beschreibung "Ausschluesse $id" -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $id })
        foreach ($a in $aus) { if ($a) { Write-Host ('      Ausschluss: {0} - {1}' -f (ConvertTo-NetString $a.StartRange), (ConvertTo-NetString $a.EndRange)) } }
        if ($s.Superscope) { Write-Host ('      Superscope: {0}' -f $s.Superscope) }
    }
}

function Get-NetDhcpRangeSuggestion {
    <#
    .SYNOPSIS
        Schlaegt einen Adressbereich vor: bei /24 .100 bis .199, sonst etwa 40 % bis 80 % des Netzes.
    #>
    param([Parameter(Mandatory = $true)][string]$Netz, [Parameter(Mandatory = $true)][int]$Prefix)
    $basis = [int64](ConvertTo-NetIPv4UInt32 -IPAddress $Netz)
    $groesse = [int64][Math]::Pow(2, 32 - $Prefix)
    if ($Prefix -eq 24) { return @((ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($basis + 100))), (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]($basis + 199)))) }
    $start = $basis + [int64][Math]::Max(1, [Math]::Floor($groesse * 0.4))
    $ende = $basis + [int64][Math]::Min($groesse - 2, [Math]::Floor($groesse * 0.8))
    return @((ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$start)), (ConvertFrom-NetIPv4UInt32 -Wert ([uint32]$ende)))
}

function Get-NetDcAddress {
    <#
    .SYNOPSIS
        Liefert IPv4-Adressen der DCs (Vorschlag fuer Option 006). Ohne AD: eigene IP, falls DNS laeuft.
    #>
    param([hashtable]$Zustand = $script:NS.Zustand)
    $liste = @()
    if ($Zustand -and ($Zustand.System.IstDC -or $Zustand.System.IstMitglied) -and (Test-NetCommand -Name 'Get-ADDomainController')) {
        $liste = @(Get-NetSafe -Beschreibung 'DCs' -Standard @() -Abfrage { Get-ADDomainController -Filter * } | Where-Object { $_ -and $_.IPv4Address } | ForEach-Object { [string]$_.IPv4Address })
    }
    if ($liste.Count -eq 0 -and $Zustand -and $Zustand.Dns.Laeuft) { $liste = @($Zustand.Netzwerk.EigeneIPs | Select-Object -First 1) }
    $eigene = @()
    if ($Zustand) { $eigene = @($Zustand.Netzwerk.EigeneIPs) }
    return @(@($liste | Where-Object { $eigene -contains $_ }) + @($liste | Where-Object { $eigene -notcontains $_ }) | Select-Object -Unique)
}

function Read-NetExclusionList {
    <#
    .SYNOPSIS
        Fragt Ausschluesse ab ("Start-Ende" oder einzelne Adressen, mit Komma getrennt).
    #>
    param([string]$Netz, [int]$Prefix, [string]$Vorschlag = '')
    $pruefNetz = $Netz
    $pruefPrefix = $Prefix
    $text = Read-NetText -Frage 'Ausschluesse (z. B. 192.168.1.100-192.168.1.109, mehrere mit Komma; leer = keine)' -Vorschlag $Vorschlag -LeerErlaubt -Pruefung {
        param($t)
        foreach ($teil in $t.Split(',')) {
            $teil = $teil.Trim()
            if (-not $teil) { continue }
            $ab = $teil.Split('-')
            $a = $ab[0].Trim()
            $b = $a
            if ($ab.Count -gt 1) { $b = $ab[1].Trim() }
            if (-not (Test-NetIPv4Address -Text $a) -or -not (Test-NetIPv4Address -Text $b)) { return "'$teil' ist kein gueltiger Bereich." }
            if (-not (Test-NetIPInSubnet -IPAddress $a -NetworkAddress $pruefNetz -PrefixLength $pruefPrefix) -or -not (Test-NetIPInSubnet -IPAddress $b -NetworkAddress $pruefNetz -PrefixLength $pruefPrefix)) { return "'$teil' liegt nicht im Netz." }
            if ((ConvertTo-NetIPv4UInt32 -IPAddress $a) -gt (ConvertTo-NetIPv4UInt32 -IPAddress $b)) { return "In '$teil' ist der Anfang groesser als das Ende." }
        }
        return $null
    }
    if ($null -eq $text) { return $null }
    $liste = @()
    foreach ($teil in $text.Split(',')) {
        $teil = $teil.Trim()
        if (-not $teil) { continue }
        $ab = $teil.Split('-')
        $a = $ab[0].Trim()
        $b = $a
        if ($ab.Count -gt 1) { $b = $ab[1].Trim() }
        $liste += , @($a, $b)
    }
    return , $liste
}

function New-NetDhcpScope {
    <#
    .SYNOPSIS
        Scope-Assistent. Ungueltige Bereiche werden vor dem Anlegen abgelehnt; ein vorhandener Scope
        fuer dasselbe Netz wird erkannt und nicht ueberschrieben.
    #>
    param([hashtable]$Vorgaben = @{})
    if (-not (Test-NetDhcpReady)) { return $false }
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'Neuer DHCP-Scope'
    $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1
    $netzVorschlag = ''
    if ($karte) { $a = $karte.Adressen | Select-Object -First 1; $netzVorschlag = '{0}/{1}' -f (Get-NetNetworkAddress -IPAddress $a.IP -PrefixLength $a.Prefix), $a.Prefix }
    if ($Vorgaben.Netz) { $netzVorschlag = $Vorgaben.Netz }
    $netz = Read-NetSubnet -Frage 'Netz des Scopes (z. B. 192.168.1.0/24)' -Vorschlag $netzVorschlag
    if (-not $netz) { return $false }
    $vorhanden = @(Get-NetDhcpScopeList | Where-Object { $_.ScopeId -eq $netz.Netz })
    if ($vorhanden.Count -gt 0) {
        Write-Log -Level OK -Message ('Fuer {0} gibt es schon den Scope "{1}" ({2} - {3}). Er wird nicht ueberschrieben.' -f $netz.Text, $vorhanden[0].Name, $vorhanden[0].Start, $vorhanden[0].Ende)
        return $true
    }
    $eigenesNetz = $false
    foreach ($k in @($z.Netzwerk.AktiveKarten)) { foreach ($ad in $k.Adressen) { if (Test-NetIPInSubnet -IPAddress $ad.IP -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix) { $eigenesNetz = $true } } }
    if (-not $eigenesNetz) {
        Write-Log -Level Warn -Message ('Der Server hat keine Adresse im Netz {0}.' -f $netz.Text)
        Write-NetText -Text "Fuer ein anderes Netz (VLAN) muss der Router bzw. Layer-3-Switch DHCP-Anfragen an diesen Server weiterleiten`n(DHCP-Relay, oft 'IP Helper' genannt, Ziel = IP dieses Servers). Sonst kommt keine Anfrage an." -Farbe Yellow
        if (-not (Read-NetYesNo -Frage 'Ist das DHCP-Relay eingerichtet bzw. wird es eingerichtet?' -Vorschlag $true)) { return $false }
    }
    $name = Read-NetText -Frage 'Name des Scopes' -Vorschlag $(if ($Vorgaben.Name) { $Vorgaben.Name } elseif ($eigenesNetz) { 'LAN' } else { 'VLAN ' + $netz.Netz })
    if (-not $name) { return $false }
    $bereich = Get-NetDhcpRangeSuggestion -Netz $netz.Netz -Prefix $netz.Prefix
    while ($true) {
        $start = Read-NetIPAddress -Frage 'Erste Adresse des Bereichs' -Vorschlag $bereich[0] -Netz $netz.Netz -Prefix $netz.Prefix
        if (-not $start) { return $false }
        $ende = Read-NetIPAddress -Frage 'Letzte Adresse des Bereichs' -Vorschlag $bereich[1] -Netz $netz.Netz -Prefix $netz.Prefix
        if (-not $ende) { return $false }
        $grund = Test-NetIPRange -Start $start -Ende $ende -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix
        if (-not $grund) { break }
        Write-Log -Level Fehler -Message $grund
    }
    $imBereich = @()
    foreach ($k in @($z.Netzwerk.AktiveKarten)) {
        foreach ($ad in $k.Adressen) { if (Test-NetIPInRange -IPAddress $ad.IP -Start $start -Ende $ende) { $imBereich += $ad.IP } }
        foreach ($g in $k.Gateway) { if (Test-NetIPInRange -IPAddress $g -Start $start -Ende $ende) { $imBereich += $g } }
    }
    $ausVorschlag = ''
    if ($imBereich.Count -gt 0) {
        Write-Log -Level Warn -Message ('Diese festen Adressen liegen im Bereich und sollten ausgeschlossen werden: ' + ($imBereich -join ', '))
        $ausVorschlag = ($imBereich | ForEach-Object { $_ }) -join ','
    }
    $ausschluesse = Read-NetExclusionList -Netz $netz.Netz -Prefix $netz.Prefix -Vorschlag $ausVorschlag
    if ($null -eq $ausschluesse) { return $false }
    $leaseVorschlag = [int](Get-NetConfigValue -Pfad 'Vorschlaege.LeaseTage' -Standard 8)
    $lease = Read-NetNumber -Frage 'Lease-Dauer in Tagen (Buero: 8, Gaeste/WLAN: 1)' -Minimum 1 -Maximum 999 -Vorschlag $leaseVorschlag
    if ($null -eq $lease) { return $false }
    $gwVorschlag = ''
    if ($karte -and $karte.Gateway.Count -gt 0 -and (Test-NetIPInSubnet -IPAddress $karte.Gateway[0] -NetworkAddress $netz.Netz -PrefixLength $netz.Prefix)) { $gwVorschlag = $karte.Gateway[0] }
    else { $gwVorschlag = ConvertFrom-NetIPv4UInt32 -Wert ([uint32]((ConvertTo-NetIPv4UInt32 -IPAddress $netz.Netz) + 1)) }
    $router = Read-NetIPAddress -Frage 'Router / Gateway (Option 003)' -Vorschlag $gwVorschlag -Netz $netz.Netz -Prefix $netz.Prefix
    if (-not $router) { return $false }
    if (Test-NetIPInRange -IPAddress $router -Start $start -Ende $ende) {
        $drin = $false
        foreach ($a in $ausschluesse) { if (Test-NetIPInRange -IPAddress $router -Start $a[0] -Ende $a[1]) { $drin = $true } }
        if (-not $drin) { Write-Log -Level Warn -Message 'Der Router liegt im Bereich und ist nicht ausgeschlossen. Er wird automatisch ausgeschlossen.'; $ausschluesse += , @($router, $router) }
    }
    $dnsVorschlag = (@(Get-NetDcAddress -Zustand $z) -join ',')
    $dnsText = Read-NetText -Frage 'DNS-Server fuer die Clients (Option 006, Vorschlag: die DCs)' -Vorschlag $dnsVorschlag -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $dnsText) { return $false }
    $dnsServer = @($dnsText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($dnsServer | Where-Object { $_ -in @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9') }).Count -gt 0 -and ($z.System.IstDC -or $z.System.IstMitglied)) {
        Write-Log -Level Warn -Message 'Domaenen-Clients sollten nur die DCs als DNS-Server bekommen, sonst finden sie die Domaene nicht.'
    }
    $domVorschlag = Get-NetDomainName
    $domaene = Read-NetText -Frage 'DNS-Domaene der Clients (Option 015)' -Vorschlag $domVorschlag -LeerErlaubt -Pruefung { param($t) if (-not $t) { $null } else { (Test-NetDomainName -Name $t).Fehler } }
    if ($null -eq $domaene) { return $false }
    $aktiv = Read-NetYesNo -Frage 'Scope sofort aktivieren?' -Vorschlag $true

    $scopeId = $netz.Netz
    $maske = $netz.Maske
    $leaseDauer = [TimeSpan]::FromDays($lease)
    $zustandText = 'InActive'
    if ($aktiv) { $zustandText = 'Active' }
    $nachher = @{
        Name = $name; Netz = $netz.Text; Bereich = "$start - $ende"; Ausschluesse = (($ausschluesse | ForEach-Object { $_[0] + '-' + $_[1] }) -join ', ')
        'Lease-Dauer' = "$lease Tage"; 'Router (003)' = $router; 'DNS-Server (006)' = ($dnsServer -join ', '); 'Domaene (015)' = $domaene; Status = $zustandText
    }
    $r = Invoke-NetChange -Titel ('DHCP-Scope {0} ({1}) anlegen' -f $name, $netz.Text) -Stufe Bestaetigen -Vorher '(kein Scope fuer dieses Netz)' -Nachher $nachher -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Scope -Name $name -StartRange $start -EndRange $ende -SubnetMask $maske -LeaseDuration $leaseDauer -State InActive
        foreach ($a in $ausschluesse) { Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $a[0] -EndRange $a[1] }
        if ($domaene) { Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dnsServer -DnsDomain $domaene -Force }
        else { Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dnsServer -Force }
        if ($aktiv) { Set-DhcpServerv4Scope -ScopeId $scopeId -State Active }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Scope'; Parameter = @{ ScopeId = $scopeId; Force = $true } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Add-NetDhcpExclusion {
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Ausschluss fuer welchen Scope?'
    if (-not $s) { return }
    $liste = Read-NetExclusionList -Netz $s.ScopeId -Prefix $s.Prefix
    if (-not $liste -or $liste.Count -eq 0) { return }
    $vorhanden = @(Get-NetSafe -Beschreibung 'Ausschluesse' -Standard @() -Abfrage { Get-DhcpServerv4ExclusionRange -ScopeId $s.ScopeId } | Where-Object { $_ } | ForEach-Object { (ConvertTo-NetString $_.StartRange) + '-' + (ConvertTo-NetString $_.EndRange) })
    foreach ($a in $liste) {
        $text = $a[0] + '-' + $a[1]
        if ($vorhanden -contains $text) { Write-Log -Level OK -Message "Ausschluss $text existiert bereits."; continue }
        $id = $s.ScopeId
        $von = $a[0]
        $bis = $a[1]
        Invoke-NetChange -Titel "Ausschluss $text zum Scope $id hinzufuegen" -Stufe Bestaetigen -Vorher ($vorhanden -join ', ') -Nachher (@($vorhanden) + $text -join ', ') -BackupBereich @('Dhcp') -Aktion {
            Add-DhcpServerv4ExclusionRange -ScopeId $id -StartRange $von -EndRange $bis
        } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4ExclusionRange'; Parameter = @{ ScopeId = $id; StartRange = $von; EndRange = $bis } } | Out-Null
    }
}

function Switch-NetDhcpScopeState {
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Welchen Scope aktivieren/deaktivieren?'
    if (-not $s) { return }
    $id = $s.ScopeId
    $alt = $s.Status
    $neu = 'Active'
    if ($alt -eq 'Active') { $neu = 'InActive' }
    $hinweis = ''
    if ($neu -eq 'InActive') { $hinweis = 'Ein deaktivierter Scope vergibt keine Adressen mehr. Bestehende Leases laufen weiter, werden aber nicht erneuert.' }
    Invoke-NetChange -Titel ("Scope {0} {1}" -f $id, $(if ($neu -eq 'Active') { 'aktivieren' } else { 'deaktivieren' })) -Stufe Bestaetigen -Vorher $alt -Nachher $neu -Hinweis $hinweis -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4Scope -ScopeId $id -State $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4Scope'; Parameter = @{ ScopeId = $id; State = $alt } } | Out-Null
}

function Remove-NetDhcpScope {
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Welchen Scope loeschen?'
    if (-not $s) { return }
    $id = $s.ScopeId
    $leases = @(Get-NetSafe -Beschreibung 'Leases' -Standard @() -Abfrage { Get-DhcpServerv4Lease -ScopeId $id }).Count
    Invoke-NetChange -Titel "DHCP-Scope $id ($($s.Name)) loeschen" -Stufe Gefaehrlich -Vorher @{ Scope = $id; Name = $s.Name; Bereich = $s.Start + ' - ' + $s.Ende; Leases = $leases } -Nachher '(geloescht)' -BackupBereich @('Dhcp') `
        -Hinweis 'Alle Leases, Reservierungen und Optionen des Scopes gehen verloren. Wiederherstellung nur aus dem Backup.' -Aktion {
        Remove-DhcpServerv4Scope -ScopeId $id -Force
    } | Out-Null
}

function New-NetDhcpSuperscope {
    <#
    .SYNOPSIS
        Fasst Scopes, die im selben physischen Netz liegen, zu einem Superscope zusammen.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetText -Text 'Ein Superscope ist nur noetig, wenn mehrere logische Netze auf demselben Kabel/VLAN liegen (z. B. weil das erste Netz voll ist). Fuer getrennte VLANs mit DHCP-Relay braucht man keinen Superscope.'
    $wahl = @(Select-NetItem -Elemente @(Get-NetDhcpScopeList) -Titel 'Welche Scopes zusammenfassen?' -Eigenschaften @('ScopeId', 'Name', 'Superscope') -Mehrfach)
    if ($wahl.Count -lt 2) { Write-Log -Level Warn -Message 'Fuer einen Superscope braucht es mindestens zwei Scopes.'; return }
    $name = Read-NetText -Frage 'Name des Superscopes' -Vorschlag 'Superscope'
    if (-not $name) { return }
    $ids = @($wahl | ForEach-Object { $_.ScopeId })
    Invoke-NetChange -Titel "Superscope $name anlegen" -Stufe Bestaetigen -Vorher (($wahl | ForEach-Object { $_.ScopeId + ' (' + $(if ($_.Superscope) { $_.Superscope } else { 'kein Superscope' }) + ')' }) -join ', ') -Nachher ("$name : " + ($ids -join ', ')) -BackupBereich @('Dhcp') -Aktion {
        Add-DhcpServerv4Superscope -SuperscopeName $name -ScopeId $ids
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerv4Superscope'; Parameter = @{ SuperscopeName = $name; Force = $true } } | Out-Null
}

function Set-NetDhcpStandardOption {
    <#
    .SYNOPSIS
        Aendert Router (003), DNS-Server (006) und Domaene (015) eines Scopes.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    $s = Select-NetDhcpScope -Titel 'Optionen welches Scopes aendern?'
    if (-not $s) { return }
    $id = $s.ScopeId
    $alt = Get-NetDhcpScopeOption -ScopeId $id
    $router = Read-NetIPAddress -Frage 'Router (003)' -Vorschlag (@($alt[3]) -join '') -Netz $s.ScopeId -Prefix $s.Prefix
    if (-not $router) { return }
    $dnsText = Read-NetText -Frage 'DNS-Server (006, mit Komma getrennt)' -Vorschlag $(if ($alt[6]) { $alt[6] -join ',' } else { (@(Get-NetDcAddress -Zustand (Get-NetSetupState)) -join ',') }) -Pruefung {
        param($t)
        foreach ($x in $t.Split(',')) { if (-not (Test-NetIPv4Address -Text $x.Trim())) { return "'$x' ist keine gueltige IPv4-Adresse." } }
        return $null
    }
    if (-not $dnsText) { return }
    $dnsServer = @($dnsText.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $domaene = Read-NetText -Frage 'Domaene (015)' -Vorschlag $(if ($alt[15]) { $alt[15][0] } else { Get-NetDomainName }) -LeerErlaubt
    if ($null -eq $domaene) { return }
    $vorher = @{ '003' = (@($alt[3]) -join ', '); '006' = (@($alt[6]) -join ', '); '015' = (@($alt[15]) -join ', ') }
    $nachher = @{ '003' = $router; '006' = ($dnsServer -join ', '); '015' = $domaene }
    if (($vorher['003'] -eq $nachher['003']) -and ($vorher['006'] -eq $nachher['006']) -and ($vorher['015'] -eq $nachher['015'])) { Write-Log -Level OK -Message 'Keine Aenderung.'; return }
    $rueck = @()
    foreach ($nr in @(3, 6, 15)) {
        if ($alt[$nr]) { $rueck += @{ Befehl = 'Set-DhcpServerv4OptionValue'; Parameter = @{ ScopeId = $id; OptionId = $nr; Value = $alt[$nr]; Force = $true } } }
        else { $rueck += @{ Befehl = 'Remove-DhcpServerv4OptionValue'; Parameter = @{ ScopeId = $id; OptionId = $nr } } }
    }
    Invoke-NetChange -Titel "Optionen 003/006/015 des Scopes $id aendern" -Stufe Bestaetigen -Vorher $vorher -Nachher $nachher -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerv4OptionValue -ScopeId $id -Router $router -DnsServer $dnsServer -Force
        if ($domaene) { Set-DhcpServerv4OptionValue -ScopeId $id -DnsDomain $domaene -Force }
    } -Rueckgaengig $rueck | Out-Null
}
