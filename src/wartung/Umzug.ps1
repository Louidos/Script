# Serverumzug: Paket exportieren (DHCP mit Leases, DNS-Zonen und -Eintraege, Konfiguration)
# und auf dem Zielserver mit Bestandsaufnahme und Vorher/Nachher importieren.

function Export-NetMigrationPackage {
    <#
    .SYNOPSIS
        Erstellt ein Umzugspaket im Ordner Backups (Umzug_<Server>_<Zeit>), optional als ZIP.
    #>
    $z = Get-NetSetupState
    $ziel = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('Umzug_{0}_{1}' -f [Environment]::MachineName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $bereiche = @('Config')
    if ($z.Dhcp.Verfuegbar) { $bereiche += 'Dhcp' }
    if ($z.Dns.Verfuegbar) { $bereiche += 'Dns' }
    $r = Invoke-NetStep -Titel 'Umzugspaket erstellen' -Aktion { Backup-NetSetupData -Bereich $bereiche -Anlass 'Umzug' -Ziel $ziel }
    if (-not $r.Erfolg) { return $null }
    Write-NetText -Text ("Paket: {0}`nDiesen Ordner (z. B. per Freigabe oder USB-Stick) auf den Zielserver kopieren und dort NetSetup -> Backup -> Umzug importieren." -f $ziel) -Farbe White
    if ((Test-NetCommand -Name 'Compress-Archive') -and (Read-NetYesNo -Frage 'Zusaetzlich als ZIP-Datei verpacken?' -Vorschlag $true)) {
        $zip = $ziel + '.zip'
        Compress-Archive -Path (Join-Path -Path $ziel -ChildPath '*') -DestinationPath $zip -Force
        Write-Log -Level OK -Message ('ZIP: ' + $zip)
    }
    return $ziel
}

function Read-NetMigrationPackage {
    <#
    .SYNOPSIS
        Liest ein Umzugspaket (Ordner oder ZIP) und liefert seinen Inhalt.
    #>
    param([Parameter(Mandatory = $true)][string]$Pfad)
    if ($Pfad -like '*.zip') {
        $entpackt = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('Import_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Expand-Archive -Path $Pfad -DestinationPath $entpackt -Force
        $Pfad = $entpackt
    }
    $info = Join-Path -Path $Pfad -ChildPath 'info.json'
    if (-not (Test-Path -Path $info)) { throw 'Kein gueltiges NetSetup-Paket (info.json fehlt).' }
    $meta = Get-Content -Path $info -Raw | ConvertFrom-Json
    $export = Join-Path -Path (Join-Path -Path $Pfad -ChildPath 'Dhcp') -ChildPath 'dhcp-export.xml'
    $scopes = @()
    if (Test-Path -Path $export) {
        [xml]$xml = Get-Content -Path $export -Raw
        foreach ($s in @($xml.SelectNodes('//IPv4/Scopes/Scope'))) {
            $scopes += [pscustomobject]@{ ScopeId = [string]$s.ScopeId; Name = [string]$s.Name; Start = [string]$s.StartRange; Ende = [string]$s.EndRange }
        }
    }
    $zonenDatei = Join-Path -Path (Join-Path -Path $Pfad -ChildPath 'Dns') -ChildPath 'zonen.json'
    $zonen = @()
    if (Test-Path -Path $zonenDatei) { $zonen = @(Get-Content -Path $zonenDatei -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{
        Pfad      = $Pfad
        Server    = [string]$meta.Server
        Zeit      = [string]$meta.Zeit
        Export    = $export
        Scopes    = $scopes
        Zonen     = $zonen
        Eintraege = @(Get-NetDnsBackupRecord -Pfad $Pfad | Where-Object { $script:NetDnsTypen -contains $_.Typ })
    }
}

function Import-NetMigrationPackage {
    <#
    .SYNOPSIS
        Importiert ein Umzugspaket auf diesem Server: Bestandsaufnahme, Vorher/Nachher, Gefaehrlich.
        Vorhandene Scopes und Zonen werden nicht ueberschrieben.
    #>
    $pfad = Read-NetText -Frage 'Pfad zum Umzugspaket (Ordner oder ZIP)' -Pruefung { param($t) if (Test-Path -Path $t) { $null } else { 'Der Pfad existiert nicht.' } }
    if (-not $pfad) { return $false }
    $paket = $null
    try { $paket = Read-NetMigrationPackage -Pfad $pfad }
    catch { Write-NetError -Fehler $_ -Titel 'Umzugspaket lesen' | Out-Null; return $false }
    Write-Log -Message ('Paket von {0} vom {1}.' -f $paket.Server, $paket.Zeit)
    $z = Get-NetSetupState
    $vorhandeneScopes = @($z.Dhcp.Scopes | ForEach-Object { $_.ScopeId })
    $neueScopes = @($paket.Scopes | Where-Object { $vorhandeneScopes -notcontains $_.ScopeId })
    $vorhandeneZonen = @($z.Dns.Zonen | ForEach-Object { $_.Name })
    $neueZonen = @($paket.Zonen | Where-Object { $vorhandeneZonen -notcontains $_.Name -and -not $_.Name.StartsWith('_msdcs') })
    foreach ($s in @($paket.Scopes | Where-Object { $vorhandeneScopes -contains $_.ScopeId })) { Write-Log -Level Warn -Message ('Scope {0} gibt es hier schon - wird nicht ueberschrieben.' -f $s.ScopeId) }
    if ($neueScopes.Count -gt 0 -and -not (Test-NetDhcpReady)) { Write-Log -Level Warn -Message 'DHCP ist hier nicht bereit, die Scopes werden uebersprungen.'; $neueScopes = @() }
    if ($neueZonen.Count -gt 0 -and -not (Test-NetDnsReady)) { Write-Log -Level Warn -Message 'DNS ist hier nicht bereit, die Zonen werden uebersprungen.'; $neueZonen = @() }
    if ($neueScopes.Count -eq 0 -and $neueZonen.Count -eq 0) { Write-Log -Level OK -Message 'Alles aus dem Paket ist hier schon vorhanden. Nichts zu tun.'; return $true }
    $speicherung = $null
    if ($neueZonen.Count -gt 0) { $speicherung = Read-NetDnsZoneStorage; if (-not $speicherung) { return $false } }
    $zonenNamen = @($neueZonen | ForEach-Object { $_.Name })
    $eintraege = @($paket.Eintraege | Where-Object { $zonenNamen -contains $_.Zone -and $_.Daten.Count -gt 0 })
    $scopeIds = @($neueScopes | ForEach-Object { $_.ScopeId })
    $export = $paket.Export
    $vorher = @{ Scopes = ($vorhandeneScopes -join ', '); Zonen = ($vorhandeneZonen -join ', ') }
    $nachher = @{ 'Neue Scopes' = (($neueScopes | ForEach-Object { '{0} ({1})' -f $_.ScopeId, $_.Name }) -join ', '); 'Neue Zonen' = ($zonenNamen -join ', '); 'DNS-Eintraege' = $eintraege.Count }
    $r = Invoke-NetChange -Titel ('Umzugspaket von {0} importieren' -f $paket.Server) -Stufe Gefaehrlich -Vorher $vorher -Nachher $nachher -BackupBereich @('Dhcp', 'Dns', 'Config') `
        -Hinweis 'Nach dem Import den alten DHCP-Server deaktivieren, damit nicht zwei Server dieselben Adressen vergeben. Danach den Doktor ausfuehren (Autorisierung, Optionen 006).' -Aktion {
        if ($scopeIds.Count -gt 0) {
            $arbeit = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupImport'
            Import-DhcpServer -File $export -BackupPath $arbeit -ScopeId $scopeIds -Leases -Force
        }
        foreach ($zone in $zonenNamen) {
            $p = @{ Name = $zone; DynamicUpdate = $speicherung.Updates }
            if ($speicherung.AdIntegriert) { $p.ReplicationScope = $speicherung.Replikation } else { $p.ZoneFile = $zone + '.dns' }
            Add-DnsServerPrimaryZone @p
        }
        foreach ($e in $eintraege) {
            try { Add-NetDnsRecordExact -ZoneName $e.Zone -Name $e.Name -Typ $e.Typ -Daten $e.Daten }
            catch { Write-Log -Level Debug -Message ('Eintrag {0} {1} in {2} uebersprungen: {3}' -f $e.Name, $e.Typ, $e.Zone, $_.Exception.Message) }
        }
    }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}
