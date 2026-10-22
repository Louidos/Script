# Pruefung A03: _ldap._tcp.dc._msdcs.<domaene> ist aufloesbar.
Register-NetCheck @{
    Id            = 'A03'
    Kategorie     = 'AD'
    Titel         = 'DC-Eintrag im DNS (SRV)'
    Problem       = 'Der Eintrag _ldap._tcp.dc._msdcs.<Domaene> laesst sich nicht aufloesen.'
    Erklaerung    = 'Clients finden Domaenencontroller ueber diesen SRV-Eintrag. Fehlt er, scheitern Beitritt und Anmeldung. Ursachen: DNS-Client zeigt nicht auf einen DC, Zone _msdcs fehlt, Netlogon hat sich nicht registriert. Die Reparatur startet Netlogon neu (registriert die Eintraege erneut).'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) ($Z.System.IstDC -or $Z.System.IstMitglied) -and (Get-NetDomainName -Zustand $Z) }
    Test          = {
        param($Z)
        $d = Get-NetDomainName -Zustand $Z
        if (Resolve-NetDcSrvRecord -Domaene $d) { New-NetCheckResult OK ('_ldap._tcp.dc._msdcs.' + $d) }
        else { New-NetCheckResult FEHLER ('(' + $d + ')') }
    }
    Reparatur     = {
        param($Z)
        if (-not $Z.System.IstDC) { throw 'Auf einem Mitgliedsserver kann der Eintrag nicht repariert werden: DNS-Client pruefen (N02) oder auf dem DC reparieren.' }
        Restart-Service -Name Netlogon -Force
    }
}
