@{
    # Einstellungen fuer PSScriptAnalyzer (Repo und CI, nie im Script selbst).
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # NetSetup ist ein Konsolenprogramm mit farbiger Ausgabe: Write-Host ist gewollt.
        'PSAvoidUsingWriteHost',
        # Alle Aenderungen laufen zentral ueber Invoke-NetChange, das ShouldProcess
        # (Probelauf / -WhatIf) beachtet. Die einzelnen Set-/New-/Remove-Funktionen
        # rufen nur Invoke-NetChange auf und brauchen deshalb kein eigenes ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
