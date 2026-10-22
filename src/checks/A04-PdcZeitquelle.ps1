# Pruefung A04: PDC-Emulator holt die Zeit von einer externen Quelle.
Register-NetCheck @{
    Id            = 'A04'
    Kategorie     = 'AD'
    Titel         = 'Zeitquelle des PDC'
    Problem       = 'Der PDC-Emulator hat keine externe Zeitquelle.'
    Erklaerung    = 'Alle Rechner der Domaene folgen der Uhr des PDC. Er sollte die Zeit per NTP von aussen holen (z. B. ch.pool.ntp.org oder vom Router).'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.System.IstPdc }
    Test          = {
        param($Z)
        if ($Z.Zeit.Typ -eq 'NTP' -and $Z.Zeit.NtpServer) { New-NetCheckResult OK $Z.Zeit.NtpServer }
        else { New-NetCheckResult WARN ('(Typ ' + $Z.Zeit.Typ + ')') }
    }
    Reparatur     = { Set-NetPdcTimeSource }
}
