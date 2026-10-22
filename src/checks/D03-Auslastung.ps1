# Pruefung D03: Auslastung der Scopes (Warnung ab 80 %, Fehler ab 90 %).
Register-NetCheck @{
    Id            = 'D03'
    Kategorie     = 'DHCP'
    Titel         = 'Auslastung der Scopes'
    Problem       = 'Scopes sind fast voll:'
    Erklaerung    = 'Ist ein Scope voll, bekommen neue Geraete keine Adresse. Abhilfe: Bereich vergroessern, Ausschluesse verkleinern, Lease-Dauer verkuerzen (z. B. Gaeste-WLAN 1 Tag) oder ein groesseres Netz planen.'
    Stufe         = 'Bestaetigen'
    Voraussetzung = { param($Z) $Z.Dhcp.Verfuegbar -and @($Z.Dhcp.Scopes | Where-Object { $_.Aktiv }).Count -gt 0 }
    Test          = {
        param($Z)
        $warnung = [int](Get-NetConfigValue -Pfad 'Vorschlaege.AuslastungWarnung' -Standard 80)
        $fehler = [int](Get-NetConfigValue -Pfad 'Vorschlaege.AuslastungFehler' -Standard 90)
        $voll = @($Z.Dhcp.Scopes | Where-Object { $_.Aktiv -and $_.Auslastung -ge $fehler })
        $knapp = @($Z.Dhcp.Scopes | Where-Object { $_.Aktiv -and $_.Auslastung -ge $warnung -and $_.Auslastung -lt $fehler })
        $text = ((@($voll) + @($knapp)) | ForEach-Object { '{0} {1:N0}%' -f $_.ScopeId, $_.Auslastung }) -join ', '
        if ($voll.Count -gt 0) { return (New-NetCheckResult FEHLER $text) }
        if ($knapp.Count -gt 0) { return (New-NetCheckResult WARN $text) }
        New-NetCheckResult OK ((@($Z.Dhcp.Scopes | Where-Object { $_.Aktiv }) | ForEach-Object { '{0} {1:N0}%' -f $_.ScopeId, $_.Auslastung }) -join ', ')
    }
}
