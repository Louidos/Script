# Aging und Scavenging: alte, dynamisch eingetragene DNS-Eintraege automatisch entfernen.
# Assistent mit Vorschlag "an, 7 + 7 Tage" und Modus "nur melden" (veraltete Eintraege auflisten).

$script:NetAgingHilfe = @'
Aging/Scavenging raeumt alte, automatisch eingetragene DNS-Eintraege auf (z. B. von Laptops,
die laengst weg sind). Statische Eintraege werden nie geloescht.
  - No-Refresh-Intervall: so lange wird ein frischer Eintrag nicht erneut gestempelt.
  - Refresh-Intervall: danach darf der Client ihn erneuern. Wer in No-Refresh + Refresh nicht
    erneuert, gilt als veraltet und wird beim naechsten Aufraeumen geloescht.
  - Vorschlag: an, 7 + 7 Tage, Aufraeumen alle 7 Tage.
  - Wichtig: No-Refresh + Refresh muss mindestens so lang sein wie die DHCP-Lease-Dauer,
    sonst werden Eintraege aktiver Clients geloescht. Bei 8 Tagen Lease passen 7 + 7 Tage.
  - "Nur melden" zeigt, was geloescht wuerde, ohne etwas zu loeschen.
'@

function ConvertTo-NetTimeSpan {
    param([AllowNull()][object]$Wert)
    if ($null -eq $Wert) { return [TimeSpan]::Zero }
    if ($Wert -is [TimeSpan]) { return $Wert }
    $ts = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse([string]$Wert, [ref]$ts)) { return $ts }
    return [TimeSpan]::Zero
}

function Get-NetMaxLeaseDuration {
    param([hashtable]$Zustand = $script:NS.Zustand)
    $max = 0
    if ($Zustand -and $Zustand.Dhcp) {
        foreach ($s in @($Zustand.Dhcp.Scopes)) { if ($s.LeaseTage -gt $max) { $max = [double]$s.LeaseTage } }
    }
    return $max
}

function Show-NetDnsAging {
    if (-not (Test-NetDnsReady)) { return }
    Write-NetTitle -Titel 'Aging und Scavenging'
    $sc = Get-NetSafe -Beschreibung 'Get-DnsServerScavenging' -Abfrage { Get-DnsServerScavenging }
    if ($sc) {
        Write-Host ('  Server: Aufraeumen {0}, alle {1} Tage, No-Refresh {2} Tage, Refresh {3} Tage' -f $(if ($sc.ScavengingState) { 'AN' } else { 'aus' }), (ConvertTo-NetTimeSpan $sc.ScavengingInterval).TotalDays, (ConvertTo-NetTimeSpan $sc.NoRefreshInterval).TotalDays, (ConvertTo-NetTimeSpan $sc.RefreshInterval).TotalDays)
        if ($sc.LastScavengeTime) { Write-Host ('  Zuletzt aufgeraeumt: {0}' -f $sc.LastScavengeTime) }
    }
    foreach ($z in @(Get-NetDnsZoneInfo -Art Primaer)) {
        $name = $z.Name
        $a = Get-NetSafe -Beschreibung "Aging $name" -Abfrage { Get-DnsServerZoneAging -Name $name }
        if ($a) { Write-Host ('  Zone {0,-35} Aging {1,-4} No-Refresh {2,4} Tage, Refresh {3,4} Tage' -f $name, $(if ($a.AgingEnabled) { 'an' } else { 'aus' }), (ConvertTo-NetTimeSpan $a.NoRefreshInterval).TotalDays, (ConvertTo-NetTimeSpan $a.RefreshInterval).TotalDays) }
    }
    $lease = Get-NetMaxLeaseDuration -Zustand (Get-NetSetupState)
    if ($lease -gt 0 -and $sc -and ((ConvertTo-NetTimeSpan $sc.NoRefreshInterval).TotalDays + (ConvertTo-NetTimeSpan $sc.RefreshInterval).TotalDays) -lt $lease) {
        Write-Log -Level Warn -Message ('No-Refresh + Refresh ist kuerzer als die laengste Lease-Dauer ({0} Tage).' -f $lease)
    }
}

function Get-NetStaleDnsRecord {
    <#
    .SYNOPSIS
        Listet veraltete dynamische Eintraege (aelter als No-Refresh + Refresh), ohne etwas zu loeschen.
    #>
    param([int]$NoRefreshTage = 7, [int]$RefreshTage = 7)
    $grenze = (Get-Date).AddDays( - ($NoRefreshTage + $RefreshTage))
    $liste = @()
    foreach ($z in @(Get-NetDnsZoneInfo -Art Primaer)) {
        $liste += @(Get-NetDnsRecord -Zone $z.Name | Where-Object { -not $_.Statisch -and $_.Zeitstempel -lt $grenze -and @('A', 'AAAA', 'PTR', 'CNAME') -contains $_.Typ })
    }
    return $liste
}

function Show-NetStaleDnsRecord {
    <#
    .SYNOPSIS
        Modus "nur melden": zeigt veraltete Eintraege und speichert sie als CSV im Ordner Berichte.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $nr = [int](Get-NetConfigValue -Pfad 'Vorschlaege.NoRefreshTage' -Standard 7)
    $rf = [int](Get-NetConfigValue -Pfad 'Vorschlaege.RefreshTage' -Standard 7)
    $liste = @(Get-NetStaleDnsRecord -NoRefreshTage $nr -RefreshTage $rf)
    Write-NetTitle -Titel ('Veraltete Eintraege (aelter als {0} Tage) - es wird nichts geloescht' -f ($nr + $rf))
    if ($liste.Count -eq 0) { Write-Log -Level OK -Message 'Keine veralteten dynamischen Eintraege gefunden.'; return }
    foreach ($e in $liste) { Write-Host ('  {0,-28} {1,-25} {2,-6} {3,-18} zuletzt {4}' -f $e.Zone, $e.Name, $e.Typ, $e.Wert, $e.Zeitstempel.ToString('yyyy-MM-dd')) }
    $datei = Join-Path -Path (Get-NetPath -Name Berichte) -ChildPath ('DNS_veraltet_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $liste | Select-Object -Property Zone, Name, Typ, Wert, Zeitstempel | Export-Csv -Path $datei -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Log -Level OK -Message ('{0} veraltete Eintraege, Liste gespeichert: {1}' -f $liste.Count, $datei)
    }
    catch { Write-NetError -Fehler $_ -Titel 'Liste speichern' | Out-Null }
}

function Set-NetDnsScavenging {
    <#
    .SYNOPSIS
        Assistent: Aging/Scavenging auf Server- und Zonenebene einstellen.
    #>
    param([Nullable[bool]]$Aktiv = $null, [int]$NoRefreshTage = 0, [int]$RefreshTage = 0)
    if (-not (Test-NetDnsReady)) { return $false }
    if ($null -eq $Aktiv) {
        Write-NetText -Text $script:NetAgingHilfe
        $i = Read-NetChoice -Frage 'Was soll passieren?' -Optionen @(
            'Aufraeumen einschalten (Server und alle Zonen) - Vorschlag',
            'Nur melden: veraltete Eintraege auflisten, nichts loeschen',
            'Aufraeumen ausschalten') -Vorschlag 1
        if ($i -lt 0) { return $false }
        if ($i -eq 1) { Show-NetStaleDnsRecord; return $true }
        $Aktiv = ($i -eq 0)
    }
    $vorNr = [int](Get-NetConfigValue -Pfad 'Vorschlaege.NoRefreshTage' -Standard 7)
    $vorRf = [int](Get-NetConfigValue -Pfad 'Vorschlaege.RefreshTage' -Standard 7)
    if ($Aktiv -and $NoRefreshTage -le 0) {
        $NoRefreshTage = Read-NetNumber -Frage 'No-Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag $vorNr
        if ($null -eq $NoRefreshTage) { return $false }
        $RefreshTage = Read-NetNumber -Frage 'Refresh-Intervall in Tagen' -Minimum 1 -Maximum 365 -Vorschlag $vorRf
        if ($null -eq $RefreshTage) { return $false }
    }
    if ($NoRefreshTage -le 0) { $NoRefreshTage = $vorNr }
    if ($RefreshTage -le 0) { $RefreshTage = $vorRf }
    $lease = Get-NetMaxLeaseDuration -Zustand (Get-NetSetupState)
    if ($Aktiv -and $lease -gt 0 -and ($NoRefreshTage + $RefreshTage) -lt $lease) {
        Write-Log -Level Warn -Message ('No-Refresh + Refresh ({0} Tage) ist kuerzer als die Lease-Dauer ({1} Tage). Dann wuerden Eintraege aktiver Clients geloescht.' -f ($NoRefreshTage + $RefreshTage), $lease)
        if (-not (Read-NetYesNo -Frage 'Trotzdem so einstellen?' -Vorschlag $false)) { return $false }
    }
    $alt = Get-NetSafe -Beschreibung 'Get-DnsServerScavenging' -Abfrage { Get-DnsServerScavenging }
    $altZustand = @{ Aktiv = $false; Intervall = '7.00:00:00'; NoRefresh = '7.00:00:00'; Refresh = '7.00:00:00' }
    if ($alt) {
        $altZustand = @{ Aktiv = [bool]$alt.ScavengingState; Intervall = (ConvertTo-NetTimeSpan $alt.ScavengingInterval).ToString(); NoRefresh = (ConvertTo-NetTimeSpan $alt.NoRefreshInterval).ToString(); Refresh = (ConvertTo-NetTimeSpan $alt.RefreshInterval).ToString() }
    }
    $nr = [TimeSpan]::FromDays($NoRefreshTage)
    $rf = [TimeSpan]::FromDays($RefreshTage)
    $intervall = [TimeSpan]::FromDays(7)
    $neuAktiv = [bool]$Aktiv
    if ($altZustand.Aktiv -eq $neuAktiv -and $altZustand.NoRefresh -eq $nr.ToString() -and $altZustand.Refresh -eq $rf.ToString() -and (-not $neuAktiv -or $altZustand.Intervall -eq $intervall.ToString())) {
        Write-Log -Level OK -Message 'Aging/Scavenging ist bereits so eingestellt.'
        return $true
    }
    $zonen = @(Get-NetDnsZoneInfo -Art Primaer | Where-Object { $_.Updates -ne 'None' } | ForEach-Object { $_.Name })
    $r = Invoke-NetChange -Titel ('Aging/Scavenging {0}' -f $(if ($neuAktiv) { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen `
        -Vorher @{ Aufraeumen = $(if ($altZustand.Aktiv) { 'an' } else { 'aus' }); 'No-Refresh' = $altZustand.NoRefresh; Refresh = $altZustand.Refresh } `
        -Nachher @{ Aufraeumen = $(if ($neuAktiv) { 'an, alle 7 Tage' } else { 'aus' }); 'No-Refresh' = $nr.ToString(); Refresh = $rf.ToString(); Zonen = ($zonen -join ', ') } -BackupBereich @('Dns') -Aktion {
        if ($neuAktiv) {
            Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval $intervall -NoRefreshInterval $nr -RefreshInterval $rf -ApplyOnAllZones
            foreach ($zone in $zonen) { Set-DnsServerZoneAging -Name $zone -Aging $true -NoRefreshInterval $nr -RefreshInterval $rf }
        }
        else {
            Set-DnsServerScavenging -ScavengingState $false
        }
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerScavenging'; Parameter = @{ ScavengingState = $altZustand.Aktiv; ScavengingInterval = $altZustand.Intervall; NoRefreshInterval = $altZustand.NoRefresh; RefreshInterval = $altZustand.Refresh } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Set-NetDnsZoneAgingOne {
    <#
    .SYNOPSIS
        Aging fuer eine einzelne Zone ein- oder ausschalten.
    #>
    if (-not (Test-NetDnsReady)) { return }
    $z = Select-NetDnsZone -Art Primaer -Titel 'Aging fuer welche Zone?'
    if (-not $z) { return }
    $name = $z.Name
    $alt = Get-NetSafe -Beschreibung "Aging $name" -Abfrage { Get-DnsServerZoneAging -Name $name }
    $altAn = $false
    if ($alt) { $altAn = [bool]$alt.AgingEnabled }
    $an = Read-NetYesNo -Frage ("Aging fuer {0} einschalten? (aktuell {1})" -f $name, $(if ($altAn) { 'an' } else { 'aus' })) -Vorschlag $true
    if ($an -eq $altAn) { Write-Log -Level OK -Message 'Keine Aenderung noetig.'; return }
    $nr = [TimeSpan]::FromDays([int](Get-NetConfigValue -Pfad 'Vorschlaege.NoRefreshTage' -Standard 7))
    $rf = [TimeSpan]::FromDays([int](Get-NetConfigValue -Pfad 'Vorschlaege.RefreshTage' -Standard 7))
    Invoke-NetChange -Titel "Aging der Zone $name $(if ($an) { 'einschalten' } else { 'ausschalten' })" -Stufe Bestaetigen -Vorher $(if ($altAn) { 'an' } else { 'aus' }) -Nachher $(if ($an) { 'an' } else { 'aus' }) -BackupBereich @('Dns') -Aktion {
        if ($an) { Set-DnsServerZoneAging -Name $name -Aging $true -NoRefreshInterval $nr -RefreshInterval $rf }
        else { Set-DnsServerZoneAging -Name $name -Aging $false }
    } -Rueckgaengig @{ Befehl = 'Set-DnsServerZoneAging'; Parameter = @{ Name = $name; Aging = $altAn } } | Out-Null
}

function Show-NetDnsAgingMenu {
    $eintraege = @(
        @{ Text = 'Einstellungen anzeigen'; Aktion = 'Show-NetDnsAging'; Hilfe = 'Zeigt Aging/Scavenging auf Server- und Zonenebene und vergleicht mit der DHCP-Lease-Dauer.' },
        @{ Text = 'Assistent (Vorschlag: an, 7 + 7 Tage)'; Aktion = { Set-NetDnsScavenging | Out-Null }; Hilfe = $script:NetAgingHilfe },
        @{ Text = 'Nur melden: veraltete Eintraege auflisten'; Aktion = 'Show-NetStaleDnsRecord'; Hilfe = 'Zeigt, welche dynamischen Eintraege beim Aufraeumen geloescht wuerden, und speichert die Liste als CSV. Es wird nichts geloescht.' },
        @{ Text = 'Aging einer einzelnen Zone'; Aktion = 'Set-NetDnsZoneAgingOne'; Hilfe = 'Schaltet Aging nur fuer eine Zone ein oder aus.' }
    )
    Show-NetMenu -Titel 'DNS - Aufraeumen alter Eintraege' -Eintraege $eintraege -Einleitung $script:NetAgingHilfe
}
