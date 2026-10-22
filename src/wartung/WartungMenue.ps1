# Geplante Aufgabe (taeglich -Task Health) und Menue "Backup, Wiederherstellen, Rueckgaengig".

$script:NetAufgabeName = 'NetSetup Gesundheitspruefung'

function Get-NetHealthTask {
    return (Get-NetSafe -Beschreibung 'Geplante Aufgabe' -Abfrage { Get-ScheduledTask -TaskName $script:NetAufgabeName })
}

function Register-NetHealthTask {
    <#
    .SYNOPSIS
        Legt die taegliche Gesundheitspruefung als geplante Aufgabe an (laeuft als SYSTEM, aendert nichts).
    #>
    $vorhanden = Get-NetHealthTask
    if ($vorhanden) { Write-Log -Level OK -Message ('Die geplante Aufgabe "{0}" gibt es bereits.' -f $script:NetAufgabeName); return $true }
    $uhrzeit = Read-NetText -Frage 'Uhrzeit (HH:MM)' -Vorschlag '06:30' -Pruefung { param($t) if ($t -match '^([01]\d|2[0-3]):[0-5]\d$') { $null } else { 'Bitte im Format HH:MM eingeben, z. B. 06:30.' } }
    if (-not $uhrzeit) { return $false }
    $scriptDatei = Save-NetSelf
    if (-not $scriptDatei) { $scriptDatei = Get-NetPath -Name Script }
    $argumente = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Task Health' -f $scriptDatei
    $exe = Get-NetPowerShellExe
    $name = $script:NetAufgabeName
    $r = Invoke-NetChange -Titel "Geplante Aufgabe '$name' anlegen" -Stufe Bestaetigen -Vorher '(keine)' -Nachher @{ Aufgabe = $name; Zeit = "taeglich $uhrzeit"; Konto = 'SYSTEM'; Befehl = "$exe $argumente"; Ergebnis = (Get-NetPath -Name Berichte) } `
        -Hinweis 'Die Aufgabe prueft nur und schreibt einen Bericht. Sie aendert nichts am Server.' -Aktion {
        $aktion = New-ScheduledTaskAction -Execute $exe -Argument $argumente -WorkingDirectory (Get-NetPath -Name Root)
        $ausloeser = New-ScheduledTaskTrigger -Daily -At $uhrzeit
        $konto = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $einst = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(1))
        Register-ScheduledTask -TaskName $name -Action $aktion -Trigger $ausloeser -Principal $konto -Settings $einst -Description 'Taegliche Pruefung von AD, DNS und DHCP durch NetSetup (aendert nichts).' | Out-Null
    } -Rueckgaengig @{ Befehl = 'Unregister-ScheduledTask'; Parameter = @{ TaskName = $name; Confirm = $false } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Unregister-NetHealthTask {
    if (-not (Get-NetHealthTask)) { Write-Log -Message 'Es gibt keine geplante Aufgabe von NetSetup.'; return }
    $name = $script:NetAufgabeName
    Invoke-NetChange -Titel "Geplante Aufgabe '$name' entfernen" -Stufe Bestaetigen -Vorher 'vorhanden' -Nachher '(entfernt)' -Aktion {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    } | Out-Null
}

function Show-NetHealthTask {
    $t = Get-NetHealthTask
    if (-not $t) { Write-NetStatus -Status NA -Bereich 'Geplante Aufgabe' -Text 'nicht eingerichtet (optional)'; return }
    Write-NetStatus -Status OK -Bereich 'Geplante Aufgabe' -Text ('{0}, Zustand {1}' -f $t.TaskName, $t.State)
}

function Show-NetUndoMenu {
    $eintraege = @(
        @{ Text = 'Letzte Aenderung rueckgaengig machen'; Aktion = 'Undo-NetLastChange'; Hilfe = 'Fuehrt die gemerkte Gegenaktion der letzten Aenderung aus (mit Vorher/Nachher und Bestaetigung).' },
        @{ Text = 'Aenderung aus dem Verlauf waehlen'; Aktion = 'Undo-NetSelectedChange'; Hilfe = 'Waehlt eine bestimmte Aenderung aus dem Verlauf und nimmt sie zurueck.' },
        @{ Text = 'Verlauf anzeigen'; Aktion = 'Show-NetChangeHistory'; Hilfe = 'Alle Aenderungen mit Zeit und Status.' }
    )
    Show-NetMenu -Titel 'Rueckgaengig' -Eintraege $eintraege
}

function Show-NetMaintenanceMenu {
    $eintraege = @(
        @{ Text = 'Backup jetzt erstellen'; Aktion = 'Invoke-NetBackupNow'; Hilfe = "Sichert DHCP (Datenbank + Export mit Leases), DNS (jede Zone + alle Eintraege als CSV), Konfiguration und Netzwerk.`nVor jeder Aenderung sichert NetSetup automatisch; die letzten 20 Backups werden aufbewahrt (Einstellungen)." },
        @{ Text = 'Backups anzeigen'; Aktion = 'Show-NetBackupList'; Hilfe = 'Liste aller Backups mit Zeit, Anlass und Inhalt.' },
        @{ Text = 'DHCP wiederherstellen (gefaehrlich)'; Aktion = { Restore-NetDhcpBackup | Out-Null }; Hilfe = 'Datenbank zuruecksetzen (Restore-DhcpServer) oder Konfiguration importieren (Import-DhcpServer). Vorher wird der aktuelle Stand gesichert, Servername eintippen.' },
        @{ Text = 'DNS-Eintraege wiederherstellen (gefaehrlich)'; Aktion = { Restore-NetDnsBackup | Out-Null }; Hilfe = 'Legt fehlende Eintraege (und Zonen) aus der CSV eines Backups neu an. Vorhandene Eintraege bleiben unveraendert.' },
        @{ Text = 'Rueckgaengig'; Aktion = 'Show-NetUndoMenu'; OhnePause = $true; Hilfe = 'Letzte Aenderung oder eine Aenderung aus dem Verlauf zuruecknehmen.' },
        @{ Text = 'Serverumzug: Paket exportieren'; Aktion = { Export-NetMigrationPackage | Out-Null }; Hilfe = 'Packt DHCP (mit Leases), DNS-Zonen und -Eintraege und die Konfiguration in einen Ordner (optional ZIP) fuer den neuen Server.' },
        @{ Text = 'Serverumzug: Paket importieren'; Aktion = { Import-NetMigrationPackage | Out-Null }; Hilfe = 'Importiert ein Paket auf diesem Server: Bestandsaufnahme, Vorher/Nachher, vorhandene Scopes und Zonen werden nicht ueberschrieben.' },
        @{ Text = 'CSV-Import (DNS-Eintraege oder Reservierungen)'; Aktion = { Import-NetCsv | Out-Null }; Hilfe = "Prueft jede Zeile vorher und zeigt das Ergebnis. Bei einem Fehler wird nichts importiert (alles oder nichts).`nVorlagen: Menuepunkt 'Vorlagen anlegen'." },
        @{ Text = 'Vorlagen anlegen'; Aktion = 'New-NetImportTemplate'; Hilfe = 'Legt Beispiel-CSVs fuer DNS-Eintraege und Reservierungen im Ordner Vorlagen an.' },
        @{ Text = 'Geplante Aufgabe: taegliche Pruefung einrichten'; Aktion = { Register-NetHealthTask | Out-Null }; Hilfe = 'Optional: taeglich NetSetup -Task Health als SYSTEM. Prueft nur und schreibt einen Bericht nach Berichte.' },
        @{ Text = 'Geplante Aufgabe entfernen'; Aktion = 'Unregister-NetHealthTask'; Hilfe = 'Entfernt die geplante Gesundheitspruefung wieder.' }
    )
    Show-NetMenu -Titel 'Backup, Wiederherstellen, Rueckgaengig' -Eintraege $eintraege -Kopf { Show-NetHealthTask; Write-Host ('  Backups: {0}' -f @(Get-NetBackupList).Count) }
}
