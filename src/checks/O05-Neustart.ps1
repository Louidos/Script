# Pruefung O05: Ein Neustart steht aus.
Register-NetCheck @{
    Id         = 'O05'
    Kategorie  = 'Rollen'
    Titel      = 'Ausstehender Neustart'
    Problem    = 'Ein Neustart steht aus:'
    Erklaerung = 'Installationen oder Umbenennungen werden erst nach dem Neustart wirksam. Vor AD-Aenderungen unbedingt neu starten.'
    Stufe      = 'Bestaetigen'
    Interaktiv = $true
    Test       = {
        param($Z)
        if ($Z.Neustart.Ausstehend) { New-NetCheckResult WARN ($Z.Neustart.Gruende -join ', ') }
        else { New-NetCheckResult OK 'kein Neustart ausstehend' }
    }
    Reparatur  = { param($Z, $E) $null = $Z; Request-NetRestart -Grund ('ausstehender Neustart: ' + $E.Detail) }
}
