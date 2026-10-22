# Active Directory einrichten: Entscheidungsbaum, Vorpruefungen, Heraufstufung, Beitritt,
# Neustart mit Fortsetzung. Zugangsdaten nur per Get-Credential, DSRM-Kennwort nur als SecureString.

# Reihenfolge der Funktionsebenen, hoechste zuerst (Namen der ADDSDeployment-Enums).
$script:NetFunktionsebenen = @('Win2025', 'WinThreshold', 'Win2012R2', 'Win2012', 'Win2008R2', 'Win2008')
$script:NetFunktionsebeneText = @{
    Win2025      = 'Windows Server 2025'
    WinThreshold = 'Windows Server 2016 (gilt auch fuer 2019 und 2022)'
    Win2012R2    = 'Windows Server 2012 R2'
    Win2012      = 'Windows Server 2012'
    Win2008R2    = 'Windows Server 2008 R2'
    Win2008      = 'Windows Server 2008'
}

function Get-NetAvailableFunctionLevel {
    <#
    .SYNOPSIS
        Liefert die Funktionsebenen, die dieses Betriebssystem kann (hoechste zuerst).
        Ermittelt ueber den Parametertyp von Install-ADDSForest, nicht ueber Versionsnummern.
    #>
    $namen = @()
    $cmd = Get-Command -Name Install-ADDSForest -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Parameters.ContainsKey('ForestMode')) {
        $typ = $cmd.Parameters['ForestMode'].ParameterType
        if ($typ.IsEnum) { $namen = [Enum]::GetNames($typ) }
    }
    $ergebnis = @($script:NetFunktionsebenen | Where-Object { $namen -contains $_ })
    if ($ergebnis.Count -eq 0) { $ergebnis = @('WinThreshold') }
    return $ergebnis
}

function Show-NetAdInfo {
    <#
    .SYNOPSIS
        Zeigt Domaene, Gesamtstruktur, Funktionsebenen, FSMO-Rollen und Domaenencontroller.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'Active Directory'
    Write-Host ('  Dieser Server : {0} ({1})' -f $z.System.Hostname, $z.System.RolleText)
    if (-not ($z.System.IstDC -or $z.System.IstMitglied)) {
        Write-Log -Message 'Der Server ist in keiner Domaene (Arbeitsgruppe). Im AD-Menue "AD einrichten" waehlen.'
        return
    }
    if ($z.AD.ModulFehlt) {
        Write-Log -Level Warn -Message ('Domaene {0}, aber das AD-PowerShell-Modul fehlt (RSAT-AD-PowerShell).' -f $z.System.Domaene)
        return
    }
    $d = Get-NetSafe -Beschreibung 'Get-ADDomain' -Abfrage { Get-ADDomain }
    $f = Get-NetSafe -Beschreibung 'Get-ADForest' -Abfrage { Get-ADForest }
    if (-not $d) { Write-Log -Level Warn -Message 'Die Domaene ist nicht erreichbar. Details im Log; Doktor ausfuehren.'; return }
    Write-Host ('  Domaene       : {0} (NetBIOS {1})' -f $d.DNSRoot, $d.NetBIOSName)
    Write-Host ('  Ebene Domaene : {0}' -f $d.DomainMode)
    if ($f) {
        Write-Host ('  Gesamtstruktur: {0}, Ebene {1}' -f $f.Name, $f.ForestMode)
        Write-Host ('  Schema-Master : {0}   Namensmaster: {1}' -f $f.SchemaMaster, $f.DomainNamingMaster)
    }
    Write-Host ('  PDC-Emulator  : {0}   RID-Master: {1}   Infrastruktur: {2}' -f $d.PDCEmulator, $d.RIDMaster, $d.InfrastructureMaster)
    $dcs = @(Get-NetSafe -Beschreibung 'Get-ADDomainController' -Standard @() -Abfrage { Get-ADDomainController -Filter * })
    Write-Host ('  Domaenencontroller ({0}):' -f $dcs.Count)
    foreach ($dc in $dcs) { Write-Host ('    {0,-30} {1,-15} Standort {2}' -f $dc.HostName, $dc.IPv4Address, $dc.Site) }
    if ($dcs.Count -eq 1) { Write-Log -Level Warn -Message 'Nur ein Domaenencontroller. Empfohlen sind mindestens zwei, damit die Anmeldung auch bei einem Ausfall funktioniert.' }
}

function Install-NetAdRole {
    <#
    .SYNOPSIS
        Installiert die Rolle AD-Domain-Services mit Verwaltungstools (falls noetig).
    #>
    $f = Get-NetFeatureState
    if ($f['AD-Domain-Services'] -eq 'Installed' -and $f['RSAT-AD-PowerShell'] -eq 'Installed') {
        Write-Log -Level OK -Message 'Die Rolle AD-Domain-Services ist installiert.'
        return $true
    }
    if ($f['AD-Domain-Services'] -eq 'Removed') {
        Write-Log -Level Fehler -Message 'Die Installationsdateien der Rolle wurden vom Server entfernt (Removed).'
        Write-Log -Message 'Naechster Schritt: Windows-Installationsmedium einlegen und Install-WindowsFeature AD-Domain-Services -Source <Laufwerk>:\sources\sxs ausfuehren.'
        return $false
    }
    $r = Invoke-NetChange -Titel 'Rolle AD-Domain-Services mit Verwaltungstools installieren' -Stufe Bestaetigen `
        -Vorher ('AD-Domain-Services: ' + (ConvertTo-NetFeatureText -Status $f['AD-Domain-Services'])) -Nachher 'AD-Domain-Services: installiert (noch kein DC)' -Aktion {
        $erg = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        if ($erg -and ($erg.PSObject.Properties['Success']) -and -not $erg.Success) { throw 'Die Installation der Rolle ist fehlgeschlagen.' }
    } -Rueckgaengig @{ Befehl = 'Uninstall-WindowsFeature'; Parameter = @{ Name = 'AD-Domain-Services' } }
    return [bool]($r.Erfolg -and -not $r.Probelauf)
}

function Show-NetAddsTestResult {
    <#
    .SYNOPSIS
        Zeigt das Ergebnis von Test-ADDS*Installation verstaendlich an. Liefert $true, wenn kein Fehler dabei ist.
    #>
    param([object[]]$Ergebnis)
    $ok = $true
    $liste = @($Ergebnis | Where-Object { $null -ne $_ })
    if ($liste.Count -eq 0) {
        Write-Log -Level Fehler -Message 'Die Vorpruefung von Windows hat kein Ergebnis geliefert.'
        return $false
    }
    foreach ($e in $liste) {
        $status = [string]$e.Status
        $text = ([string]$e.Message).Trim()
        if (-not $text) { continue }
        if ($status -eq 'Error') { $ok = $false; Write-Log -Level Fehler -Message $text }
        elseif ($status -eq 'Warning') { Write-Log -Level Warn -Message $text }
        else { Write-Log -Message $text }
    }
    if ($ok) { Write-Log -Level OK -Message 'Die Vorpruefung von Windows (Test-ADDS) war erfolgreich.' }
    else { Write-Log -Message 'Naechster Schritt: die markierten Fehler beheben (Doktor hilft) und erneut starten.' }
    return $ok
}

function Test-NetAdNetworkReady {
    <#
    .SYNOPSIS
        Vorpruefung: feste IP. Bietet die Reparatur an. Liefert die Netzwerkkarte oder $null.
    #>
    param([hashtable]$Zustand)
    $karte = Select-NetActiveAdapter -Zustand $Zustand
    if (-not $karte) { return $null }
    if ($karte.Dhcp) {
        Write-Log -Level Warn -Message ('Die Netzwerkkarte {0} bezieht ihre IP per DHCP. Ein Domaenencontroller braucht eine feste IP.' -f $karte.Name)
        if (-not (Read-NetYesNo -Frage 'Jetzt eine feste IP setzen?' -Vorschlag $true)) { return $null }
        if (-not (Set-NetStaticAddress -Karte $karte)) { return $null }
        $karte = Select-NetActiveAdapter -Zustand (Get-NetSetupState)
    }
    else { Write-Log -Level OK -Message ('Feste IP: {0}' -f (($karte.Adressen | ForEach-Object { $_.IP + '/' + $_.Prefix }) -join ', ')) }
    return $karte
}

function Test-NetAdNameReady {
    <#
    .SYNOPSIS
        Vorpruefung: Servername. Ein automatisch vergebener Name (WIN-...) sollte vorher geaendert werden.
        Liefert 'OK', 'Neustart' (Umbenennung laeuft) oder 'Abbruch'.
    #>
    param([hashtable]$Zustand, [string]$WeiterMit, [hashtable]$WeiterDaten = @{})
    if ($Zustand.Neustart.Ausstehend) {
        Write-Log -Level Warn -Message ('Ein Neustart steht aus: ' + ($Zustand.Neustart.Gruende -join ', '))
        Write-Log -Message 'Vor der Einrichtung von AD muss der Server neu gestartet werden.'
        if (Read-NetYesNo -Frage 'Jetzt neu starten und danach automatisch weitermachen?' -Vorschlag $true) {
            Save-NetResumeState -Schritt 'AdNachUmbenennung' -Daten @{ WeiterMit = $WeiterMit; WeiterDaten = $WeiterDaten } -Beschreibung 'Neustart vor der AD-Einrichtung'
            Request-NetRestart -Grund 'ausstehender Neustart vor der AD-Einrichtung'
            return 'Neustart'
        }
        return 'Abbruch'
    }
    $name = $Zustand.System.Hostname
    $grund = Test-NetHostName -Name $name
    if ($name -match '^WIN-[A-Z0-9]{8,}$' -or $grund) {
        if ($grund) { Write-Log -Level Warn -Message ("Der Servername '{0}' ist ungeeignet: {1}" -f $name, $grund) }
        else { Write-Log -Level Warn -Message ("Der Servername '{0}' wurde automatisch vergeben." -f $name) }
        if (Read-NetYesNo -Frage 'Den Server jetzt umbenennen (mit Neustart, danach geht es automatisch weiter)?' -Vorschlag $true) {
            if (Rename-NetServer -WeiterMit $WeiterMit -WeiterDaten $WeiterDaten) { return 'Neustart' }
            return 'Abbruch'
        }
        if (-not (Read-NetYesNo -Frage "Mit dem Namen '$name' weitermachen?" -Vorschlag $false)) { return 'Abbruch' }
    }
    else { Write-Log -Level OK -Message ('Servername: ' + $name) }
    return 'OK'
}

function Read-NetDsrmPassword {
    Write-NetText -Text "Das DSRM-Kennwort (Verzeichnisdienst-Wiederherstellungsmodus) braucht man im Notfall, wenn das AD nicht startet.`nEs wird nicht gespeichert. Bitte sicher aufbewahren (z. B. im Passwort-Safe)."
    return (Read-NetSecret -Frage 'DSRM-Kennwort' -Bestaetigen -Komplex)
}

function New-NetForest {
    <#
    .SYNOPSIS
        Neue Gesamtstruktur erstellen: Vorpruefungen, Test-ADDSForestInstallation, Install-ADDSForest.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    Write-NetTitle -Titel 'Neue Gesamtstruktur erstellen (erster Domaenencontroller)'
    $karte = Test-NetAdNetworkReady -Zustand $Zustand
    if (-not $karte) { return }
    $name = Test-NetAdNameReady -Zustand $Zustand -WeiterMit 'Forest'
    if ($name -ne 'OK') { return }

    Write-NetText -Text "Der Domaenenname ist der DNS-Name des AD. Empfohlen: eine Subdomain der eigenen Internet-Domain,`nz. B. ad.firma.ch (nicht .local und kein einteiliger Name)."
    $vorschlag = [string](Get-NetConfigValue -Pfad 'AD.Domaene' -Standard '')
    while ($true) {
        $domaene = Read-NetText -Frage 'Domaenenname (z. B. ad.firma.ch)' -Vorschlag $vorschlag -Pruefung { param($t) (Test-NetDomainName -Name $t).Fehler }
        if (-not $domaene) { return }
        $pruef = Test-NetDomainName -Name $domaene
        $domaene = $pruef.Name
        foreach ($w in $pruef.Warnungen) { Write-Log -Level Warn -Message $w }
        if ($pruef.Warnungen.Count -eq 0 -or (Read-NetYesNo -Frage "Trotzdem '$domaene' verwenden?" -Vorschlag $false)) { break }
        $vorschlag = ''
    }
    $netbios = Read-NetText -Frage 'NetBIOS-Name der Domaene' -Vorschlag (Get-NetNetBiosSuggestion -DomainName $domaene) -Pruefung {
        param($t)
        if ($t.Length -gt 15) { return 'Hoechstens 15 Zeichen.' }
        if ($t -notmatch '^[A-Za-z0-9-]+$') { return 'Nur Buchstaben, Ziffern und Bindestrich.' }
        if ($t -match '^\d+$') { return 'Nicht nur Ziffern.' }
        return $null
    }
    if (-not $netbios) { return }
    $netbios = $netbios.ToUpper()

    $ebenen = @(Get-NetAvailableFunctionLevel)
    $ebene = $ebenen[0]
    Write-Log -Message ('Funktionsebene: {0} - die hoechste, die dieses Windows kann.' -f $script:NetFunktionsebeneText[$ebene])
    if ($ebenen.Count -gt 1 -and (Read-NetYesNo -Frage 'Eine niedrigere Funktionsebene waehlen (nur noetig fuer aeltere DCs)?' -Vorschlag $false)) {
        $i = Read-NetChoice -Frage 'Funktionsebene' -Optionen @($ebenen | ForEach-Object { $script:NetFunktionsebeneText[$_] }) -Vorschlag 1
        if ($i -lt 0) { return }
        $ebene = $ebenen[$i]
    }

    $dsrm = Read-NetDsrmPassword
    if (-not $dsrm) { return }
    if (-not (Install-NetAdRole)) { return }

    $parameter = @{
        DomainName                    = $domaene
        DomainNetbiosName             = $netbios
        ForestMode                    = $ebene
        DomainMode                    = $ebene
        InstallDns                    = $true
        SafeModeAdministratorPassword = $dsrm
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Write-Log -Message 'Windows prueft die Heraufstufung (Test-ADDSForestInstallation) ...'
    $test = Invoke-NetStep -Titel 'Vorpruefung Test-ADDSForestInstallation' -Aktion { Test-ADDSForestInstallation @parameter -WarningAction SilentlyContinue }
    if (-not $test.Erfolg -or -not (Show-NetAddsTestResult -Ergebnis $test.Ergebnis)) {
        Write-Log -Level Fehler -Message 'Die Heraufstufung wird nicht gestartet, weil die Vorpruefung nicht erfolgreich war.'
        return
    }
    $script:NS.Config.AD.Domaene = $domaene
    $script:NS.Config.AD.NetBios = $netbios
    Save-NetConfig
    $r = Invoke-NetChange -Titel "Server zum ersten Domaenencontroller der neuen Gesamtstruktur $domaene heraufstufen" -Stufe Gefaehrlich -BackupBereich @('Config', 'Netzwerk') `
        -Vorher @{ Rolle = $Zustand.System.RolleText; Domaene = '(keine)' } `
        -Nachher @{ Rolle = 'Domaenencontroller mit DNS'; Domaene = $domaene; NetBIOS = $netbios; Funktionsebene = $script:NetFunktionsebeneText[$ebene] } `
        -Hinweis 'Danach ist ein Neustart noetig. NetSetup setzt nach der Anmeldung automatisch fort (DNS-Client, Pruefung).' -Aktion {
        Install-ADDSForest @parameter -WarningAction SilentlyContinue | Out-Null
    }
    if ($r.Erfolg -and -not $r.Probelauf) {
        Save-NetResumeState -Schritt 'AdNachHeraufstufung' -Daten @{ Art = 'Forest'; Domaene = $domaene; KarteIndex = [int]$karte.Index } -Beschreibung "Heraufstufung zum DC von $domaene"
        Request-NetRestart -Grund 'Abschluss der Heraufstufung zum Domaenencontroller'
    }
}

function Read-NetExistingDc {
    <#
    .SYNOPSIS
        Fragt Domaene und die IP eines bestehenden DCs ab und prueft die Erreichbarkeit (DNS-SRV).
    #>
    param([hashtable]$Zustand)
    $domaene = Read-NetText -Frage 'Name der bestehenden Domaene (z. B. ad.firma.ch)' -Vorschlag ([string]$Zustand.System.Domaene) -Pruefung { param($t) (Test-NetDomainName -Name $t).Fehler }
    if (-not $domaene) { return $null }
    $domaene = $domaene.ToLower()
    $dcVorschlag = ''
    $karte = @($Zustand.Netzwerk.AktiveKarten) | Select-Object -First 1
    if ($karte -and $karte.DnsServer.Count -gt 0) { $dcVorschlag = $karte.DnsServer[0] }
    $dcIp = Read-NetIPAddress -Frage 'IP-Adresse eines bestehenden Domaenencontrollers' -Vorschlag $dcVorschlag
    if (-not $dcIp) { return $null }
    $srv = '_ldap._tcp.dc._msdcs.' + $domaene
    $antwort = Get-NetSafe -Beschreibung "SRV $srv" -Abfrage { Resolve-DnsName -Name $srv -Type SRV -Server $dcIp -DnsOnly -QuickTimeout }
    if (-not $antwort) {
        Write-Log -Level Fehler -Message ("Der DC {0} kennt die Domaene {1} nicht (kein Eintrag {2})." -f $dcIp, $domaene, $srv)
        Write-Log -Message 'Naechster Schritt: Domaenenname und DC-Adresse pruefen; Firewall (Port 53) und Netzwerkverbindung pruefen.'
        return $null
    }
    Write-Log -Level OK -Message ("Der DC {0} ist erreichbar und kennt die Domaene {1}." -f $dcIp, $domaene)
    $abw = Get-NetTimeOffset -Server $dcIp
    if ($null -eq $abw) { Write-Log -Level Warn -Message 'Die Uhrzeit des DCs konnte nicht abgefragt werden (UDP 123).' }
    elseif ([Math]::Abs($abw) -gt 120) {
        Write-Log -Level Warn -Message ('Die Uhr weicht {0:N0} Sekunden vom DC ab. Ab 5 Minuten schlaegt die Anmeldung fehl.' -f $abw)
        if (Read-NetYesNo -Frage 'Uhrzeit jetzt mit dem DC abgleichen?' -Vorschlag $true) { Sync-NetTimeWithDc -Dc $dcIp | Out-Null }
    }
    else { Write-Log -Level OK -Message ('Zeitabweichung zum DC: {0} Sekunden.' -f $abw) }
    if ($karte -and (@($karte.DnsServer) -notcontains $dcIp)) {
        Write-Log -Level Warn -Message 'Dieser Server fragt nicht den DC als DNS-Server. Ohne das findet er die Domaene nicht.'
        Set-NetDnsClient -Karte $karte -Server @($dcIp) -Grund 'Fuer den Beitritt muss der Server den DC als DNS-Server verwenden.' | Out-Null
    }
    return @{ Domaene = $domaene; DcIp = $dcIp }
}

function Join-NetDomain {
    <#
    .SYNOPSIS
        Tritt einer bestehenden Domaene bei. Danach ist ein Neustart noetig.
    .PARAMETER DanachDc
        Nach dem Neustart direkt mit "zusaetzlicher DC werden" weitermachen.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState), [switch]$DanachDc)
    Write-NetTitle -Titel 'Domaene beitreten'
    $karte = Test-NetAdNetworkReady -Zustand $Zustand
    if (-not $karte) { return }
    $weiter = 'Join'
    if ($DanachDc) { $weiter = 'JoinDc' }
    if ((Test-NetAdNameReady -Zustand $Zustand -WeiterMit $weiter) -ne 'OK') { return }
    $ziel = Read-NetExistingDc -Zustand $Zustand
    if (-not $ziel) { return }
    Write-NetText -Text 'Jetzt die Zugangsdaten eines Kontos eingeben, das Computer in die Domaene aufnehmen darf (z. B. FIRMA\Administrator). Sie werden nicht gespeichert.'
    $cred = Get-Credential -Message ('Konto fuer den Beitritt zu {0}' -f $ziel.Domaene)
    if (-not $cred) { Write-Log -Level Warn -Message 'Keine Zugangsdaten eingegeben. Abbruch.'; return }
    $domaene = $ziel.Domaene
    $r = Invoke-NetChange -Titel "Domaene $domaene beitreten" -Stufe Bestaetigen -Vorher ('Arbeitsgruppe ' + $Zustand.System.Arbeitsgruppe) -Nachher ('Mitglied der Domaene ' + $domaene) -BackupBereich @('Config') -Hinweis 'Danach ist ein Neustart noetig.' -Aktion {
        Add-Computer -DomainName $domaene -Credential $cred -Force
    }
    if ($r.Erfolg -and -not $r.Probelauf) {
        $schritt = 'Mitglied'
        if ($DanachDc) { $schritt = 'Dc' }
        Save-NetResumeState -Schritt 'AdNachBeitritt' -Daten @{ Ziel = $schritt; Domaene = $domaene } -Beschreibung "Beitritt zu $domaene"
        Request-NetRestart -Grund "Beitritt zur Domaene $domaene"
    }
}

function Add-NetDomainController {
    <#
    .SYNOPSIS
        Diesen Mitgliedsserver zu einem zusaetzlichen DC der bestehenden Domaene machen.
    #>
    param([hashtable]$Zustand = (Get-NetSetupState))
    Write-NetTitle -Titel 'Zusaetzlicher Domaenencontroller'
    if (-not $Zustand.System.IstMitglied) {
        Write-Log -Level Fehler -Message 'Der Server muss zuerst Mitglied der Domaene sein.'
        return
    }
    $karte = Test-NetAdNetworkReady -Zustand $Zustand
    if (-not $karte) { return }
    if ((Test-NetAdNameReady -Zustand $Zustand -WeiterMit 'Dc') -ne 'OK') { return }
    $domaene = $Zustand.System.Domaene
    Write-NetText -Text ('Zugangsdaten eines Domaenen-Admins von {0} eingeben (z. B. {1}\Administrator). Sie werden nicht gespeichert.' -f $domaene, ($domaene.Split('.')[0].ToUpper()))
    $cred = Get-Credential -Message ('Domaenen-Admin fuer {0}' -f $domaene)
    if (-not $cred) { Write-Log -Level Warn -Message 'Keine Zugangsdaten eingegeben. Abbruch.'; return }
    $dsrm = Read-NetDsrmPassword
    if (-not $dsrm) { return }
    if (-not (Install-NetAdRole)) { return }
    $parameter = @{
        DomainName                    = $domaene
        Credential                    = $cred
        InstallDns                    = $true
        SafeModeAdministratorPassword = $dsrm
        NoRebootOnCompletion          = $true
        Force                         = $true
    }
    Write-Log -Message 'Windows prueft die Heraufstufung (Test-ADDSDomainControllerInstallation) ...'
    $test = Invoke-NetStep -Titel 'Vorpruefung Test-ADDSDomainControllerInstallation' -Aktion { Test-ADDSDomainControllerInstallation @parameter -WarningAction SilentlyContinue }
    if (-not $test.Erfolg -or -not (Show-NetAddsTestResult -Ergebnis $test.Ergebnis)) {
        Write-Log -Level Fehler -Message 'Die Heraufstufung wird nicht gestartet, weil die Vorpruefung nicht erfolgreich war.'
        return
    }
    $r = Invoke-NetChange -Titel "Server zum zusaetzlichen Domaenencontroller von $domaene heraufstufen" -Stufe Gefaehrlich -BackupBereich @('Config', 'Netzwerk') `
        -Vorher @{ Rolle = $Zustand.System.RolleText } -Nachher @{ Rolle = 'Domaenencontroller mit DNS'; Domaene = $domaene } `
        -Hinweis 'Die AD-Daten werden vom bestehenden DC kopiert (Replikation). Danach ist ein Neustart noetig.' -Aktion {
        Install-ADDSDomainController @parameter -WarningAction SilentlyContinue | Out-Null
    }
    if ($r.Erfolg -and -not $r.Probelauf) {
        Save-NetResumeState -Schritt 'AdNachHeraufstufung' -Daten @{ Art = 'Dc'; Domaene = $domaene; KarteIndex = [int]$karte.Index } -Beschreibung "Heraufstufung zum zusaetzlichen DC von $domaene"
        Request-NetRestart -Grund 'Abschluss der Heraufstufung zum Domaenencontroller'
    }
}

function Complete-NetAdNachHeraufstufung {
    <#
    .SYNOPSIS
        Fortsetzung nach der Heraufstufung: Dienste pruefen, DNS-Client auf sich selbst stellen.
    #>
    param([hashtable]$Daten = @{})
    $z = Get-NetSetupState
    if (-not $z.System.IstDC) {
        Write-Log -Level Fehler -Message 'Der Server ist nach dem Neustart kein Domaenencontroller. Die Heraufstufung ist vermutlich fehlgeschlagen.'
        Write-Log -Message 'Naechster Schritt: Ereignisanzeige (Directory Service, DNS Server) und C:\Windows\debug\dcpromo.log pruefen, dann erneut versuchen.'
        return
    }
    Write-Log -Level OK -Message ('Der Server ist jetzt Domaenencontroller von {0}.' -f $z.AD.Domaene)
    foreach ($d in @('NTDS', 'Netlogon', 'DNS')) {
        $x = $z.Dienste[$d]
        if ($x -and $x.Status -eq 'Running') { Write-Log -Level OK -Message "Dienst $d laeuft." }
        else { Write-Log -Level Warn -Message "Dienst $d laeuft nicht. Der Doktor kann ihn starten." }
    }
    $karte = @($z.Netzwerk.AktiveKarten | Where-Object { $_.Index -eq [int]$Daten.KarteIndex }) | Select-Object -First 1
    if (-not $karte) { $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1 }
    if ($karte) {
        $eigene = ($karte.Adressen | Select-Object -First 1).IP
        $soll = @($eigene, '127.0.0.1')
        if ($Daten.Art -eq 'Dc') {
            $andere = @($karte.DnsServer | Where-Object { $_ -ne $eigene -and $_ -ne '127.0.0.1' }) | Select-Object -First 1
            if ($andere) { $soll = @($andere, $eigene, '127.0.0.1') }
        }
        Set-NetDnsClient -Karte $karte -Server $soll -Grund 'Ein DC fragt sich selbst (und ggf. einen weiteren DC). So findet er die Domaene immer.' | Out-Null
    }
    if ($z.System.IstPdc -and $z.Zeit.Typ -ne 'NTP') {
        Write-Log -Level Warn -Message 'Dieser DC ist PDC-Emulator und hat noch keine externe Zeitquelle.'
        if (Read-NetYesNo -Frage 'Jetzt eine externe Zeitquelle einstellen?' -Vorschlag $true) { Set-NetPdcTimeSource | Out-Null }
    }
    $script:NS.Config.AD.Modus = ''
    Save-NetConfig
}

function Complete-NetAdNachBeitritt {
    param([hashtable]$Daten = @{})
    $z = Get-NetSetupState
    if (-not $z.System.IstMitglied -and -not $z.System.IstDC) {
        Write-Log -Level Fehler -Message 'Der Server ist nach dem Neustart nicht in der Domaene.'
        Write-Log -Message 'Naechster Schritt: DNS-Client (muss auf den DC zeigen), Zeit und Zugangsdaten pruefen, dann erneut beitreten.'
        return
    }
    Write-Log -Level OK -Message ('Der Server ist jetzt Mitglied der Domaene {0}.' -f $z.System.Domaene)
    if ($Daten.Ziel -eq 'Dc') {
        Write-Log -Message 'Weiter mit der Heraufstufung zum zusaetzlichen Domaenencontroller.'
        Add-NetDomainController -Zustand $z
    }
    else {
        $script:NS.Config.AD.Modus = 'Mitglied'
        Save-NetConfig
    }
}

function Complete-NetAdNachUmbenennung {
    param([hashtable]$Daten = @{})
    Write-Log -Level OK -Message ('Der Server heisst jetzt {0}.' -f [Environment]::MachineName)
    switch ([string]$Daten.WeiterMit) {
        'Forest' { New-NetForest }
        'Join' { Join-NetDomain }
        'JoinDc' { Join-NetDomain -DanachDc }
        'Dc' { Add-NetDomainController }
        default { Write-Log -Message 'Weiter im Menue.' }
    }
}

function Set-NetAdMode {
    param([ValidateSet('OhneAD', 'Mitglied', '')][string]$Modus)
    $script:NS.Config.AD.Modus = $Modus
    Save-NetConfig
}

function Start-NetAdSetup {
    <#
    .SYNOPSIS
        Entscheidungsbaum: bietet je nach Ausgangslage den passenden Weg an.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'Active Directory einrichten'
    Write-Log -Message ('Ausgangslage: {0} ({1})' -f $z.System.RolleText, $z.System.Hostname)
    if ($z.System.IstDC) {
        Write-Log -Level OK -Message ('Dieser Server ist bereits Domaenencontroller von {0}. Nichts zu tun.' -f $z.AD.Domaene)
        Show-NetAdInfo
        return
    }
    if ($z.Features['AD-Domain-Services'] -eq 'Installed') {
        Write-Log -Level Warn -Message 'Die Rolle AD-Domain-Services ist installiert, der Server ist aber noch kein DC (Heraufstufung fehlt oder ist fehlgeschlagen).'
    }
    if ($z.System.IstMitglied) {
        $wahl = Read-NetChoice -Frage ('Der Server ist Mitglied der Domaene {0}. Was soll er werden?' -f $z.System.Domaene) -Optionen @(
            'Zusaetzlicher Domaenencontroller (empfohlen fuer Ausfallsicherheit)',
            'Kein DC - nur DNS und/oder DHCP auf diesem Server',
            'Abbrechen') -Vorschlag 2
        switch ($wahl) {
            0 { Add-NetDomainController -Zustand $z }
            1 { Set-NetAdMode -Modus 'Mitglied'; Write-Log -Level OK -Message 'Gemerkt: Mitgliedsserver ohne DC-Rolle. Weiter mit DNS bzw. DHCP.' }
            default { return }
        }
        return
    }
    $wahl = Read-NetChoice -Frage 'Der Server ist in einer Arbeitsgruppe (kein AD). Was soll passieren?' -Optionen @(
        'Neue Gesamtstruktur erstellen (dieser Server wird der erste DC)',
        'Bestehender Domaene beitreten und zusaetzlicher DC werden',
        'Bestehender Domaene nur beitreten (Mitgliedsserver)',
        'Ohne AD weiter (DHCP ohne Autorisierung, DNS dateibasiert)',
        'Abbrechen') -Vorschlag 1
    switch ($wahl) {
        0 { New-NetForest -Zustand $z }
        1 { Join-NetDomain -Zustand $z -DanachDc }
        2 { Join-NetDomain -Zustand $z }
        3 {
            Write-NetText -Text "Ohne AD: DHCP braucht keine Autorisierung, DNS-Zonen werden als Datei gespeichert`n(nur dieser Server, keine sicheren dynamischen Updates). Das kann spaeter jederzeit geaendert werden." -Farbe Yellow
            Set-NetAdMode -Modus 'OhneAD'
            Write-Log -Level OK -Message 'Gemerkt: ohne AD. Weiter mit DNS bzw. DHCP.'
        }
        default { return }
    }
}

function Invoke-NetAdPrecheck {
    <#
    .SYNOPSIS
        Zeigt alle AD-Vorpruefungen an, ohne etwas zu aendern.
    #>
    $z = Get-NetSetupState
    Write-NetTitle -Titel 'AD-Vorpruefungen (nur anzeigen)'
    $karte = @($z.Netzwerk.AktiveKarten) | Select-Object -First 1
    if (-not $karte) { Write-NetStatus -Status FEHLER -Bereich 'Netzwerk' -Text 'keine aktive Netzwerkkarte' }
    elseif ($karte.Dhcp) { Write-NetStatus -Status WARN -Bereich 'Feste IP' -Text ('{0} bezieht die IP per DHCP' -f $karte.Name) }
    else { Write-NetStatus -Status OK -Bereich 'Feste IP' -Text (($karte.Adressen | ForEach-Object { $_.IP + '/' + $_.Prefix }) -join ', ') }
    if ($z.Netzwerk.MehrereKarten) { Write-NetStatus -Status WARN -Bereich 'Netzwerkkarten' -Text 'mehrere aktive Karten - DCs sollten nur in einem Netz registriert sein' }
    $grund = Test-NetHostName -Name $z.System.Hostname
    if ($grund) { Write-NetStatus -Status FEHLER -Bereich 'Servername' -Text $grund }
    elseif ($z.System.Hostname -match '^WIN-[A-Z0-9]{8,}$') { Write-NetStatus -Status WARN -Bereich 'Servername' -Text ('{0} ist automatisch vergeben, besser umbenennen' -f $z.System.Hostname) }
    else { Write-NetStatus -Status OK -Bereich 'Servername' -Text $z.System.Hostname }
    if ($z.Neustart.Ausstehend) { Write-NetStatus -Status WARN -Bereich 'Neustart' -Text ($z.Neustart.Gruende -join ', ') }
    else { Write-NetStatus -Status OK -Bereich 'Neustart' -Text 'kein Neustart ausstehend' }
    if ($karte -and $karte.DnsServer.Count -gt 0) { Write-NetStatus -Status INFO -Bereich 'DNS-Client' -Text ($karte.DnsServer -join ', ') }
    Write-NetStatus -Status INFO -Bereich 'Rolle AD DS' -Text (ConvertTo-NetFeatureText -Status $z.Features['AD-Domain-Services'])
    Write-NetStatus -Status INFO -Bereich 'Funktionsebene' -Text ('hoechste moegliche: ' + $script:NetFunktionsebeneText[(@(Get-NetAvailableFunctionLevel))[0]])
    Write-NetStatus -Status INFO -Bereich 'Zeit' -Text ('{0} {1}' -f $z.Zeit.Typ, $z.Zeit.NtpServer)
}

function Show-NetAdMenu {
    $eintraege = @(
        @{ Text = 'Domaene anzeigen'; Aktion = 'Show-NetAdInfo'; Hilfe = 'Zeigt Domaene, Gesamtstruktur, Funktionsebenen, FSMO-Rollen und alle Domaenencontroller.' },
        @{ Text = 'AD einrichten (passender Weg)'; Aktion = 'Start-NetAdSetup'; Hilfe = "Erkennt die Ausgangslage und bietet den passenden Weg an:`n- Arbeitsgruppe: neue Gesamtstruktur, Beitritt + DC, nur Beitritt oder ohne AD`n- Mitgliedsserver: zusaetzlicher DC oder nur DNS/DHCP`n- DC: zeigt die Domaene`nMit Vorpruefungen, Test-ADDS vor der Heraufstufung und Fortsetzung nach dem Neustart." },
        @{ Text = 'Vorpruefungen anzeigen (ohne Aenderung)'; Aktion = 'Invoke-NetAdPrecheck'; Hilfe = 'Prueft feste IP, Servername, ausstehenden Neustart, DNS-Client, Rolle, Funktionsebene und Zeitquelle und zeigt das Ergebnis an.' },
        @{ Text = 'Feste IP-Adresse setzen'; Aktion = { Set-NetStaticAddress | Out-Null }; Hilfe = "Server brauchen eine feste IP. Stufe gefaehrlich: Remotedesktop kann getrennt werden.`nUeblich: eine Adresse ausserhalb des DHCP-Bereichs, Gateway = Router, DNS = die DCs." },
        @{ Text = 'Server umbenennen'; Aktion = { Rename-NetServer | Out-Null }; Hilfe = 'Benennt den Server um (z. B. DC01). Vor der Heraufstufung zum DC erledigen. Braucht einen Neustart.' },
        @{ Text = 'DNS-Client einstellen'; Aktion = { Set-NetDnsClient | Out-Null }; Hilfe = 'Welche DNS-Server dieser Server selbst fragt. DC: eigene IP und 127.0.0.1. Mitglied: die DCs. Nie direkt 8.8.8.8 o. ae.' },
        @{ Text = 'Externe Zeitquelle (PDC) einstellen'; Aktion = { Set-NetPdcTimeSource | Out-Null }; Hilfe = 'Der PDC-Emulator gibt die Zeit fuer die ganze Domaene vor und sollte sie von einer externen Quelle (NTP) holen, z. B. ch.pool.ntp.org oder dem Router.' },
        @{ Text = 'Unterbrochene Einrichtung fortsetzen'; Aktion = 'Invoke-NetResumeCheck'; Hilfe = 'Falls eine Einrichtung wegen eines Neustarts unterbrochen wurde und nicht automatisch weiterlief: hier fortsetzen oder verwerfen.' }
    )
    Show-NetMenu -Titel 'Active Directory' -Eintraege $eintraege
}
