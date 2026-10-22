# Backup: DHCP (Backup-DhcpServer und Export-DhcpServer mit Leases), DNS (Export-DnsServerZone pro Zone
# und alle Eintraege als CSV), Konfiguration und Netzwerk. Automatisch vor jeder Aenderung,
# Aufbewahrung der letzten N Backups (Einstellung, Vorschlag 20).

$script:NetBackupBereiche = @('Dhcp', 'Dns', 'Config', 'Netzwerk')

function Get-NetWindowsPath {
    param([string]$Unterpfad)
    $windows = $env:SystemRoot
    if (-not $windows) { $windows = 'C:\Windows' }
    return ($windows.TrimEnd('\') + '\' + $Unterpfad.TrimStart('\'))
}

function Get-NetBackupList {
    <#
    .SYNOPSIS
        Liefert alle Backups (neueste zuerst) mit Zeit, Anlass und enthaltenen Bereichen.
    #>
    $ordner = Get-NetPath -Name Backups
    if (-not (Test-Path -Path $ordner)) { return @() }
    $liste = @()
    foreach ($d in @(Get-ChildItem -Path $ordner -Directory | Sort-Object -Property Name -Descending)) {
        $info = Join-Path -Path $d.FullName -ChildPath 'info.json'
        if (-not (Test-Path -Path $info)) { continue }
        try { $i = Get-Content -Path $info -Raw | ConvertFrom-Json } catch { continue }
        $liste += [pscustomobject]@{
            Name      = $d.Name
            Pfad      = $d.FullName
            Zeit      = [string]$i.Zeit
            Anlass    = [string]$i.Anlass
            Bereiche  = @($i.Bereiche)
            Server    = [string]$i.Server
            Automatisch = [bool]$i.Automatisch
        }
    }
    return $liste
}

function Remove-NetOldBackup {
    <#
    .SYNOPSIS
        Loescht die aeltesten Backups, wenn mehr als die eingestellte Anzahl vorhanden sind.
    #>
    $behalten = [int](Get-NetConfigValue -Pfad 'Allgemein.BackupAufbewahrung' -Standard 20)
    $liste = @(Get-NetBackupList | Where-Object { $_.Name -notlike 'Umzug_*' })
    if ($liste.Count -le $behalten) { return }
    foreach ($alt in ($liste | Select-Object -Skip $behalten)) {
        Remove-Item -Path $alt.Pfad -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log -Level Debug -Message ('Altes Backup geloescht: ' + $alt.Name)
    }
}

function Export-NetDnsRecordCsv {
    <#
    .SYNOPSIS
        Schreibt alle Eintraege der Zonen als CSV (mit Daten als JSON, fuer die Wiederherstellung).
    #>
    param([Parameter(Mandatory = $true)][string]$Datei, [string[]]$Zonen)
    if (-not $Zonen) { $Zonen = @(Get-NetDnsZoneInfo -Art Primaer | ForEach-Object { $_.Name }) }
    $zeilen = @()
    foreach ($zone in $Zonen) {
        foreach ($e in @(Get-NetDnsRecord -Zone $zone)) {
            $zeilen += [pscustomobject]@{
                Zone     = $e.Zone
                Name     = $e.Name
                Typ      = $e.Typ
                Wert     = $e.Wert
                Statisch = $e.Statisch
                Ttl      = $e.Ttl
                Daten    = ($e.Daten | ConvertTo-Json -Compress -Depth 3)
            }
        }
    }
    $zeilen | Export-Csv -Path $Datei -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    return $zeilen.Count
}

function Backup-NetSetupData {
    <#
    .SYNOPSIS
        Erstellt ein Backup der gewaehlten Bereiche. Liefert den Ordner (oder $null bei Fehler).
    .PARAMETER Bereich
        Dhcp, Dns, Config, Netzwerk (AD wird mit der Windows-Serversicherung gesichert).
    #>
    param(
        [string[]]$Bereich = $script:NetBackupBereiche,
        [string]$Anlass = 'manuell',
        [switch]$Automatisch,
        [string]$Ziel
    )
    $zeit = Get-Date
    $kurz = ($Anlass -replace '[^A-Za-z0-9]+', '-').Trim('-')
    if ($kurz.Length -gt 40) { $kurz = $kurz.Substring(0, 40) }
    if (-not $Ziel) { $Ziel = Join-Path -Path (Get-NetPath -Name Backups) -ChildPath ('{0}_{1}' -f $zeit.ToString('yyyyMMdd_HHmmss_fff'), $kurz) }
    New-Item -Path $Ziel -ItemType Directory -Force | Out-Null
    $erledigt = @()
    $hinweise = @()
    foreach ($b in @($Bereich | Select-Object -Unique)) {
        switch ($b) {
            'Config' {
                $datei = Get-NetPath -Name ConfigDatei
                if (Test-Path -Path $datei) { Copy-Item -Path $datei -Destination (Join-Path -Path $Ziel -ChildPath 'netsetup.json') -Force }
                $verlauf = Get-NetPath -Name Verlauf
                if (Test-Path -Path $verlauf) { Copy-Item -Path $verlauf -Destination (Join-Path -Path $Ziel -ChildPath 'verlauf.json') -Force }
                $erledigt += 'Config'
            }
            'Netzwerk' {
                $netz = Get-NetNetworkState
                Set-Content -Path (Join-Path -Path $Ziel -ChildPath 'netzwerk.json') -Value ($netz | ConvertTo-Json -Depth 8) -Encoding UTF8
                $erledigt += 'Netzwerk'
            }
            'Dhcp' {
                if (-not (Test-NetDhcpReady -Still)) { $hinweise += 'DHCP: nicht vorhanden oder Dienst gestoppt - uebersprungen'; continue }
                $dhcpZiel = Join-Path -Path $Ziel -ChildPath 'Dhcp'
                New-Item -Path $dhcpZiel -ItemType Directory -Force | Out-Null
                Export-DhcpServer -File (Join-Path -Path $dhcpZiel -ChildPath 'dhcp-export.xml') -Leases -Force
                # Backup-DhcpServer schreibt der DHCP-Dienst selbst (NetworkService): erst in seinen Ordner, dann kopieren.
                $dienstOrdner = Get-NetWindowsPath -Unterpfad 'System32\dhcp\NetSetupBackup'
                if (Test-Path -Path $dienstOrdner) { Remove-Item -Path $dienstOrdner -Recurse -Force -ErrorAction SilentlyContinue }
                Backup-DhcpServer -Path $dienstOrdner
                Copy-Item -Path $dienstOrdner -Destination (Join-Path -Path $dhcpZiel -ChildPath 'Datenbank') -Recurse -Force
                $erledigt += 'Dhcp'
            }
            'Dns' {
                if (-not (Test-NetDnsReady -Still)) { $hinweise += 'DNS: nicht vorhanden oder Dienst gestoppt - uebersprungen'; continue }
                $dnsZiel = Join-Path -Path $Ziel -ChildPath 'Dns'
                New-Item -Path $dnsZiel -ItemType Directory -Force | Out-Null
                $zonen = @(Get-NetDnsZoneInfo -Art Primaer)
                $stempel = $zeit.ToString('yyyyMMddHHmmss')
                foreach ($z in $zonen) {
                    $dateiName = 'NetSetup_{0}_{1}.dns' -f ($z.Name -replace '[^A-Za-z0-9.-]', '_'), $stempel
                    try {
                        Export-DnsServerZone -Name $z.Name -FileName $dateiName
                        $quelle = Get-NetWindowsPath -Unterpfad ('System32\dns\' + $dateiName)
                        if (Test-Path -Path $quelle) { Move-Item -Path $quelle -Destination (Join-Path -Path $dnsZiel -ChildPath $dateiName) -Force }
                    }
                    catch { $hinweise += ('DNS: Zone {0} konnte nicht exportiert werden ({1})' -f $z.Name, $_.Exception.Message) }
                }
                Set-Content -Path (Join-Path -Path $dnsZiel -ChildPath 'zonen.json') -Value (ConvertTo-Json -InputObject @($zonen) -Depth 4) -Encoding UTF8
                $anzahl = Export-NetDnsRecordCsv -Datei (Join-Path -Path $dnsZiel -ChildPath 'eintraege.csv') -Zonen @($zonen | ForEach-Object { $_.Name })
                $einst = @{ Weiterleitungen = @(Get-NetDnsForwarderList) }
                Set-Content -Path (Join-Path -Path $dnsZiel -ChildPath 'einstellungen.json') -Value ($einst | ConvertTo-Json -Depth 4) -Encoding UTF8
                Write-Log -Level Debug -Message "DNS-Backup: $($zonen.Count) Zonen, $anzahl Eintraege"
                $erledigt += 'Dns'
            }
            default { $hinweise += "Bereich $b wird nicht gesichert (AD: Windows-Serversicherung verwenden)." }
        }
    }
    $info = @{ Zeit = $zeit.ToString('yyyy-MM-dd HH:mm:ss'); Anlass = $Anlass; Bereiche = $erledigt; Hinweise = $hinweise; Server = [Environment]::MachineName; Version = $script:NS.Version; Automatisch = [bool]$Automatisch }
    Set-Content -Path (Join-Path -Path $Ziel -ChildPath 'info.json') -Value ($info | ConvertTo-Json -Depth 4) -Encoding UTF8
    foreach ($h in $hinweise) { Write-Log -Level Debug -Message ('Backup: ' + $h) }
    if ($Automatisch) { Write-Log -Message ('Backup erstellt ({0}): {1}' -f ($erledigt -join ', '), (Split-Path -Path $Ziel -Leaf)) }
    else { Write-Log -Level OK -Message ('Backup erstellt ({0}): {1}' -f ($erledigt -join ', '), $Ziel) }
    Remove-NetOldBackup
    return $Ziel
}

function Invoke-NetBackupNow {
    $i = Read-NetChoice -Frage 'Was sichern?' -Optionen @('Alles (DHCP, DNS, Konfiguration, Netzwerk)', 'Nur DHCP', 'Nur DNS', 'Nur Konfiguration') -Vorschlag 1
    if ($i -lt 0) { return }
    $bereiche = switch ($i) { 0 { $script:NetBackupBereiche } 1 { @('Dhcp') } 2 { @('Dns') } default { @('Config') } }
    $r = Invoke-NetStep -Titel 'Backup' -Aktion { Backup-NetSetupData -Bereich $bereiche -Anlass 'manuell' }
    if ($r.Erfolg) { Write-NetText -Text ('Ordner: ' + $r.Ergebnis) }
}

function Invoke-NetBackupTask {
    <#
    .SYNOPSIS
        Aufgabe ohne Menue (-Task Backup).
    #>
    Backup-NetSetupData -Bereich $script:NetBackupBereiche -Anlass 'Aufgabe' | Out-Null
}

function Show-NetBackupList {
    Write-NetTitle -Titel 'Backups'
    $liste = @(Get-NetBackupList)
    if ($liste.Count -eq 0) { Write-Log -Message 'Noch keine Backups vorhanden.'; return }
    foreach ($b in $liste) { Write-Host ('  {0,-19} {1,-28} {2,-30} {3}' -f $b.Zeit, ($b.Bereiche -join ','), $b.Anlass, $(if ($b.Automatisch) { 'automatisch' } else { '' })) }
    Write-Host ('  Ordner: ' + (Get-NetPath -Name Backups)) -ForegroundColor DarkGray
}
