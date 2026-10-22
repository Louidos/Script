# Pruefung D05: Reservierungen liegen im Scope-Bereich und nicht in einem Ausschluss.
Register-NetCheck @{
    Id            = 'D05'
    Kategorie     = 'DHCP'
    Titel         = 'Reservierungen'
    Problem       = 'Reservierungen liegen ausserhalb des Bereichs oder in einem Ausschluss:'
    Erklaerung    = 'Solche Reservierungen funktionieren nicht wie erwartet. Die Reservierung loeschen und mit einer Adresse im Bereich neu anlegen (Menue DHCP -> Reservierungen).'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes | ForEach-Object { $_.Reservierungen }).Count -gt 0 }
    Test          = {
        param($Z)
        $probleme = @()
        foreach ($s in $Z.Dhcp.Scopes) {
            foreach ($r in @($s.Reservierungen)) {
                if (-not (Test-NetIPInRange -IPAddress $r.IP -Start $s.Start -Ende $s.Ende)) { $probleme += ('{0} ({1}) ausserhalb' -f $r.IP, $r.Name); continue }
                foreach ($a in @($s.Ausschluesse)) { if (Test-NetIPInRange -IPAddress $r.IP -Start $a.Start -Ende $a.Ende) { $probleme += ('{0} ({1}) im Ausschluss' -f $r.IP, $r.Name) } }
            }
        }
        if ($probleme.Count -gt 0) { return (New-NetCheckResult WARN ($probleme -join ', ')) }
        New-NetCheckResult OK 'alle im Bereich'
    }
}
