# Pruefung R04: Zeitabweichung zum PDC bzw. zur Domaene.
Register-NetCheck @{
    Id            = 'R04'
    Kategorie     = 'Rechte'
    Titel         = 'Zeitabweichung zur Domaene'
    Problem       = 'Die Uhr weicht vom PDC-Emulator ab.'
    Erklaerung    = 'Ab 5 Minuten Abweichung schlaegt die Anmeldung (Kerberos) fehl. Die Reparatur synchronisiert die Uhr mit der Domaenenhierarchie (w32tm /resync).'
    Stufe         = 'Automatisch'
    Voraussetzung = { param($Z) ($Z.System.IstMitglied -or ($Z.System.IstDC -and -not $Z.System.IstPdc)) -and $Z.AD.Pdc }
    Test          = {
        param($Z)
        $abw = Get-NetTimeOffset -Server $Z.AD.Pdc
        if ($null -eq $abw) { return (New-NetCheckResult WARN ('PDC {0} antwortet nicht auf UDP 123.' -f $Z.AD.Pdc)) }
        $betrag = [Math]::Abs([double]$abw)
        if ($betrag -gt 300) { return (New-NetCheckResult FEHLER ('{0:N0} Sekunden.' -f $abw) $abw) }
        if ($betrag -gt 60) { return (New-NetCheckResult WARN ('{0:N0} Sekunden.' -f $abw) $abw) }
        New-NetCheckResult OK ('{0} Sekunden' -f $abw) $abw
    }
    Reparatur     = {
        Invoke-NetW32tm -Argumente @('/config', '/syncfromflags:domhier', '/update')
        Invoke-NetW32tm -Argumente @('/resync', '/force')
    }
}
