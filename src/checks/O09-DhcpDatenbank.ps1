# Pruefung O09: DHCP-Datenbank fehlt oder der Dienst kann sie nicht lesen.
Register-NetCheck @{
    Id            = 'O09'
    Kategorie     = 'Rollen'
    Titel         = 'DHCP-Datenbank'
    Problem       = 'Die DHCP-Datenbank fehlt oder ist beschaedigt.'
    Erklaerung    = 'Ohne lesbare Datenbank startet der DHCP-Dienst nicht. Die Reparatur stellt die Datenbank aus einem Backup wieder her (gefaehrlich: aktuelle Leases werden ersetzt).'
    Stufe         = 'Gefaehrlich'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.Features['DHCP'] -eq 'Installed' -and $Z.Dienste['DHCPServer'] -and $Z.Dienste['DHCPServer'].Vorhanden }
    Test          = {
        param($Z)
        $windows = $env:SystemRoot
        if (-not $windows) { $windows = 'C:\Windows' }
        $datei = $windows.TrimEnd('\') + '\System32\dhcp\dhcp.mdb'
        if (-not (Test-Path -Path $datei)) { return (New-NetCheckResult FEHLER ('(' + $datei + ' fehlt)')) }
        if ($Z.Dienste['DHCPServer'].Status -ne 'Running' -and -not $Z.Dhcp.Verfuegbar) { return (New-NetCheckResult WARN '(Dienst laeuft nicht - Datenbank evtl. beschaedigt, zuerst O06 pruefen)') }
        New-NetCheckResult OK 'vorhanden'
    }
    Reparatur     = {
        if (Test-NetCommand -Name 'Restore-NetDhcpBackup') { Restore-NetDhcpBackup }
        else { Write-Log -Level Warn -Message 'Wiederherstellen ist im Menue Backup verfuegbar.' }
    }
}
