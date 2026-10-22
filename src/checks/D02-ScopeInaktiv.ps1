# Pruefung D02: Alle Scopes sind aktiv.
Register-NetCheck @{
    Id            = 'D02'
    Kategorie     = 'DHCP'
    Titel         = 'Inaktive Scopes'
    Problem       = 'Diese Scopes sind deaktiviert:'
    Erklaerung    = 'Ein deaktivierter Scope vergibt keine Adressen. Gewollt ist das nur waehrend Umbauten. Die Reparatur aktiviert die Scopes.'
    Stufe         = 'Bestaetigen'
    Backup        = @('Dhcp')
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes).Count -gt 0 }
    Test          = {
        param($Z)
        $inaktiv = @($Z.Dhcp.Scopes | Where-Object { -not $_.Aktiv } | ForEach-Object { $_.ScopeId })
        if ($inaktiv.Count -gt 0) { return (New-NetCheckResult WARN ($inaktiv -join ', ') $inaktiv) }
        New-NetCheckResult OK 'alle aktiv'
    }
    Reparatur     = { param($Z, $E) $null = $Z; foreach ($id in @($E.Daten)) { Set-DhcpServerv4Scope -ScopeId $id -State Active } }
}
