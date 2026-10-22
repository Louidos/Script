# DHCP-Grundlagen: Rolle installieren und nachkonfigurieren, Autorisierung im AD, Bindungen.

function Test-NetEnterpriseAdmin {
    <#
    .SYNOPSIS
        Prueft ueber die SID (endet auf -519), ob das Konto Mitglied der Organisations-Admins ist.
    #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        foreach ($g in $id.Groups) { if ($g.Value -match '^S-1-5-21-\d+-\d+-\d+-519$') { return $true } }
    }
    catch { Write-Log -Level Debug -Message 'Gruppenmitgliedschaften nicht lesbar.' }
    return $false
}

function Get-NetServerFqdn {
    $domaene = Get-NetDomainName
    if ($domaene) { return ('{0}.{1}' -f [Environment]::MachineName, $domaene).ToLower() }
    return [Environment]::MachineName.ToLower()
}

function Complete-NetDhcpPostInstall {
    <#
    .SYNOPSIS
        Nachkonfiguration nach der Rolleninstallation: Sicherheitsgruppen, ConfigurationState = 2,
        Dienst neu starten (ersetzt den Assistenten im Server-Manager).
    #>
    $status = Get-NetSafe -Beschreibung 'ConfigurationState' -Abfrage { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState).ConfigurationState }
    if ([int]$status -eq 2) {
        Write-Log -Level OK -Message 'Die DHCP-Nachkonfiguration ist bereits erledigt.'
        return $true
    }
    $r = Invoke-NetChange -Titel 'DHCP-Nachkonfiguration abschliessen' -Stufe Bestaetigen -Vorher ('ConfigurationState = {0} (Server-Manager zeigt "Konfiguration erforderlich")' -f $(if ($null -ne $status) { $status } else { 'fehlt' })) `
        -Nachher 'Sicherheitsgruppen DHCP-Administratoren/DHCP-Benutzer angelegt, ConfigurationState = 2, Dienst neu gestartet' -Aktion {
        Add-DhcpServerSecurityGroup
        if (-not (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12')) { New-Item -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Force | Out-Null }
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2
        Restart-Service -Name DHCPServer -Force
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Install-NetDhcpRole {
    <#
    .SYNOPSIS
        Installiert die DHCP-Rolle mit Tools (falls noetig) und fuehrt die Nachkonfiguration aus.
    #>
    $f = Get-NetFeatureState
    if (-not ($f['DHCP'] -eq 'Installed' -and $f['RSAT-DHCP'] -eq 'Installed' -and (Test-NetCommand -Name 'Get-DhcpServerv4Scope'))) {
        $namen = @()
        if ($f['DHCP'] -ne 'Installed') { $namen += 'DHCP' }
        if ($f['RSAT-DHCP'] -ne 'Installed') { $namen += 'RSAT-DHCP' }
        if ($namen.Count -eq 0) { $namen = @('RSAT-DHCP') }
        $r = Invoke-NetChange -Titel ('Windows-Funktion(en) installieren: ' + ($namen -join ', ')) -Stufe Bestaetigen `
            -Vorher @{ DHCP = (ConvertTo-NetFeatureText -Status $f['DHCP']); 'RSAT-DHCP' = (ConvertTo-NetFeatureText -Status $f['RSAT-DHCP']) } -Nachher @{ DHCP = 'installiert'; 'RSAT-DHCP' = 'installiert' } -Aktion {
            $erg = Install-WindowsFeature -Name $namen -IncludeManagementTools
            if ($erg -and $erg.PSObject.Properties['Success'] -and -not $erg.Success) { throw 'Die Installation ist fehlgeschlagen.' }
            Import-Module DhcpServer -ErrorAction SilentlyContinue
        } -Rueckgaengig @{ Befehl = 'Uninstall-WindowsFeature'; Parameter = @{ Name = $namen } }
        if (-not $r.Erfolg -or $r.Probelauf) { return $false }
    }
    else { Write-Log -Level OK -Message 'DHCP-Rolle und Verwaltungstools sind installiert.' }
    return (Complete-NetDhcpPostInstall)
}

function Test-NetDhcpReady {
    <#
    .SYNOPSIS
        Prueft, ob DHCP verwaltet werden kann; bietet sonst Installation bzw. Dienststart an.
    #>
    param([switch]$Still)
    $dienst = Get-NetSafe -Beschreibung 'Dienst DHCPServer' -Abfrage { Get-Service -Name DHCPServer }
    if ((Test-NetCommand -Name 'Get-DhcpServerv4Scope') -and $dienst) {
        if ([string]$dienst.Status -ne 'Running') {
            Write-Log -Level Warn -Message 'Der DHCP-Dienst laeuft nicht.'
            if (-not $Still -and (Read-NetYesNo -Frage 'DHCP-Dienst jetzt starten?' -Vorschlag $true)) {
                $r = Invoke-NetChange -Titel 'DHCP-Dienst starten' -Stufe Automatisch -Aktion { Start-Service -Name DHCPServer }
                return [bool]$r.Erfolg
            }
            return $false
        }
        return $true
    }
    if ($Still) { return $false }
    Write-Log -Level Warn -Message 'Der DHCP-Server ist auf diesem Server nicht (vollstaendig) installiert.'
    if (Read-NetYesNo -Frage 'DHCP-Rolle jetzt installieren?' -Vorschlag $true) { return (Install-NetDhcpRole) }
    return $false
}

function Test-NetDhcpAuthorized {
    <#
    .SYNOPSIS
        Liefert $true (autorisiert), $false (nicht autorisiert) oder $null (keine Domaene).
    #>
    $einst = Get-NetSafe -Beschreibung 'Get-DhcpServerSetting' -Abfrage { Get-DhcpServerSetting }
    if (-not $einst) { return $null }
    if (-not $einst.IsDomainJoined) { return $null }
    return [bool]$einst.IsAuthorized
}

function Add-NetDhcpAuthorization {
    <#
    .SYNOPSIS
        Autorisiert den DHCP-Server im AD (Add-DhcpServerInDC). Ohne Domaene wird uebersprungen.
    #>
    if (-not (Test-NetDhcpReady)) { return $false }
    $status = Test-NetDhcpAuthorized
    if ($null -eq $status) {
        Write-Log -Message 'Der Server ist in keiner Domaene: eine Autorisierung ist nicht noetig und wird uebersprungen.'
        return $true
    }
    if ($status) { Write-Log -Level OK -Message 'Der DHCP-Server ist im AD autorisiert.'; return $true }
    if (-not (Test-NetEnterpriseAdmin)) {
        Write-Log -Level Warn -Message 'Das angemeldete Konto ist nicht in der Gruppe Organisations-Admins (Enterprise Admins).'
        Write-NetText -Text "Die Autorisierung schreibt in den Konfigurationsbereich der Gesamtstruktur. Das duerfen nur Organisations-Admins`n(oder Konten, denen das Recht delegiert wurde). Moeglichkeiten:`n  - mit einem Konto aus Organisations-Admins anmelden und NetSetup erneut starten, oder`n  - einen Organisations-Admin bitten, auf einem DC auszufuehren:`n      Add-DhcpServerInDC -DnsName $(Get-NetServerFqdn) -IPAddress <IP dieses Servers>" -Farbe Yellow
        if (-not (Read-NetYesNo -Frage 'Trotzdem versuchen (falls das Recht delegiert ist)?' -Vorschlag $false)) { return $false }
    }
    $fqdn = Get-NetServerFqdn
    $karte = @((Get-NetSetupState).Netzwerk.AktiveKarten) | Select-Object -First 1
    $ip = ''
    if ($karte) { $ip = ($karte.Adressen | Select-Object -First 1).IP }
    $r = Invoke-NetChange -Titel "DHCP-Server $fqdn im AD autorisieren" -Stufe Bestaetigen -Vorher 'nicht autorisiert (vergibt keine Adressen)' -Nachher ('autorisiert: {0} ({1})' -f $fqdn, $ip) -Aktion {
        if ($ip) { Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ip } else { Add-DhcpServerInDC -DnsName $fqdn }
    } -Rueckgaengig @{ Befehl = 'Remove-DhcpServerInDC'; Parameter = @{ DnsName = $fqdn; IPAddress = $ip } }
    if ($r.Erfolg -and -not $r.Probelauf) { Write-Log -Message 'Hinweis: Es kann einige Minuten dauern, bis der Dienst die Autorisierung bemerkt.' }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Show-NetDhcpBinding {
    if (-not (Test-NetDhcpReady)) { return }
    Write-NetTitle -Titel 'DHCP-Bindungen (auf welchen Netzwerkkarten DHCP antwortet)'
    $z = Get-NetSetupState
    foreach ($b in @($z.Dhcp.Bindungen)) {
        $karte = @($z.Netzwerk.Karten | Where-Object { $_.Name -eq $b.Karte }) | Select-Object -First 1
        $hinweis = ''
        if ($karte -and $karte.Dhcp) { $hinweis = ' - Karte hat eine DHCP-Adresse, darauf bindet der DHCP-Server nicht!' }
        if ($b.Aktiv) { Write-NetStatus -Status OK -Bereich $b.Karte -Text ('gebunden ({0}){1}' -f $b.IP, $hinweis) }
        else { Write-NetStatus -Status NA -Bereich $b.Karte -Text ('nicht gebunden ({0}){1}' -f $b.IP, $hinweis) }
    }
}

function Set-NetDhcpBinding {
    <#
    .SYNOPSIS
        Legt fest, auf welchen Netzwerkkarten der DHCP-Server antwortet.
    #>
    if (-not (Test-NetDhcpReady)) { return }
    $bindungen = @(Get-NetSafe -Beschreibung 'Get-DhcpServerv4Binding' -Standard @() -Abfrage { Get-DhcpServerv4Binding } | ForEach-Object {
            [pscustomobject]@{ Karte = [string]$_.InterfaceAlias; IP = (ConvertTo-NetString -Wert $_.IPAddress); Aktiv = [bool]$_.BindingState }
        })
    if ($bindungen.Count -eq 0) { Write-Log -Level Warn -Message 'Keine Netzwerkkarte mit fester IPv4-Adresse fuer DHCP gefunden.'; return }
    Write-NetText -Text 'Nur Karten im Netz der Clients (bzw. mit DHCP-Relay) sollten gebunden sein. Karten fuer Speicher-, Backup- oder Internetnetze nicht binden.'
    $wahl = @(Select-NetItem -Elemente $bindungen -Titel 'Welche Karten sollen gebunden sein?' -Eigenschaften @('Karte', 'IP', 'Aktiv') -Mehrfach)
    if ($wahl.Count -eq 0) { return }
    $soll = @($wahl | ForEach-Object { $_.Karte })
    foreach ($b in $bindungen) {
        $neu = $soll -contains $b.Karte
        if ($neu -eq $b.Aktiv) { continue }
        $karte = $b.Karte
        $alt = $b.Aktiv
        Invoke-NetChange -Titel ("DHCP-Bindung fuer {0} {1}" -f $karte, $(if ($neu) { 'einschalten' } else { 'ausschalten' })) -Stufe Bestaetigen -Vorher $(if ($alt) { 'gebunden' } else { 'nicht gebunden' }) -Nachher $(if ($neu) { 'gebunden' } else { 'nicht gebunden' }) -BackupBereich @('Dhcp') -Aktion {
            Set-DhcpServerv4Binding -InterfaceAlias $karte -BindingState $neu
        } -Rueckgaengig @{ Befehl = 'Set-DhcpServerv4Binding'; Parameter = @{ InterfaceAlias = $karte; BindingState = $alt } } | Out-Null
    }
}

function Set-NetDhcpConflictDetection {
    <#
    .SYNOPSIS
        Konflikterkennung: der Server pingt eine Adresse vor der Vergabe (0 = aus, Vorschlag 1).
    #>
    param([Nullable[int]]$Versuche = $null)
    if (-not (Test-NetDhcpReady)) { return $false }
    $einst = Get-NetSafe -Beschreibung 'Get-DhcpServerSetting' -Abfrage { Get-DhcpServerSetting }
    $alt = 0
    if ($einst) { $alt = [int]$einst.ConflictDetectionAttempts }
    if ($null -eq $Versuche) {
        Write-NetText -Text 'Bei eingeschalteter Konflikterkennung pingt der DHCP-Server eine Adresse, bevor er sie vergibt. So werden Doppelvergaben (z. B. Geraete mit fest eingetragener IP) vermieden. Jeder Versuch verzoegert die Vergabe um etwa eine Sekunde. Vorschlag: 1.'
        $Versuche = Read-NetNumber -Frage ('Anzahl Pingversuche (0-5, aktuell {0})' -f $alt) -Minimum 0 -Maximum 5 -Vorschlag 1
        if ($null -eq $Versuche) { return $false }
    }
    if ($Versuche -eq $alt) { Write-Log -Level OK -Message 'Die Konflikterkennung ist bereits so eingestellt.'; return $true }
    $neu = [int]$Versuche
    $r = Invoke-NetChange -Titel 'DHCP-Konflikterkennung einstellen' -Stufe Bestaetigen -Vorher ('{0} Versuch(e)' -f $alt) -Nachher ('{0} Versuch(e)' -f $neu) -BackupBereich @('Dhcp') -Aktion {
        Set-DhcpServerSetting -ConflictDetectionAttempts $neu
    } -Rueckgaengig @{ Befehl = 'Set-DhcpServerSetting'; Parameter = @{ ConflictDetectionAttempts = $alt } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
