# Pruefung O02: Rolle installiert, aber Verwaltungstools fehlen.
Register-NetCheck @{
    Id         = 'O02'
    Kategorie  = 'Rollen'
    Titel      = 'Verwaltungstools'
    Problem    = 'Eine Rolle ist ohne Verwaltungstools installiert:'
    Erklaerung = 'Ohne Verwaltungstools fehlen die PowerShell-Befehle (z. B. Get-DhcpServerv4Scope), NetSetup kann die Rolle dann nicht verwalten. Die Reparatur installiert die Tools aus dem lokalen Windows.'
    Stufe      = 'Bestaetigen'
    Test       = {
        param($Z)
        $fehlend = @()
        if ($Z.Features['DNS'] -eq 'Installed' -and $Z.Features['RSAT-DNS-Server'] -ne 'Installed') { $fehlend += 'RSAT-DNS-Server' }
        if ($Z.Features['DHCP'] -eq 'Installed' -and $Z.Features['RSAT-DHCP'] -ne 'Installed') { $fehlend += 'RSAT-DHCP' }
        if ($Z.Features['AD-Domain-Services'] -eq 'Installed' -and $Z.Features['RSAT-AD-PowerShell'] -ne 'Installed') { $fehlend += 'RSAT-AD-PowerShell' }
        if ($fehlend.Count -gt 0) { return (New-NetCheckResult WARN ($fehlend -join ', ') $fehlend) }
        New-NetCheckResult OK 'vollstaendig'
    }
    Reparatur  = {
        param($Z, $E)
        $null = $Z
        $erg = Install-WindowsFeature -Name $E.Daten
        if ($erg -and $erg.PSObject.Properties['Success'] -and -not $erg.Success) { throw 'Die Installation der Tools ist fehlgeschlagen.' }
    }
}
