# Pruefung O01: Ein Domaenencontroller ohne DNS-Rolle.
Register-NetCheck @{
    Id            = 'O01'
    Kategorie     = 'Rollen'
    Titel         = 'DNS-Rolle auf dem DC'
    Problem       = 'Dieser Domaenencontroller hat keine DNS-Server-Rolle.'
    Erklaerung    = 'Das AD braucht DNS. Ueblich ist DNS auf jedem DC (AD-integrierte Zonen). Die Reparatur installiert die Rolle aus dem lokalen Windows.'
    Stufe         = 'Bestaetigen'
    Interaktiv    = $true
    Voraussetzung = { param($Z) $Z.System.IstDC }
    Test          = {
        param($Z)
        if ($Z.Features['DNS'] -eq 'Installed') { New-NetCheckResult OK 'DNS installiert' }
        else { New-NetCheckResult FEHLER ('(Status: ' + (ConvertTo-NetFeatureText -Status $Z.Features['DNS']) + ')') }
    }
    Reparatur     = { Install-NetDnsRole }
}
