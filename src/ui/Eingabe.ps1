# Eingaben mit sofortiger Pruefung und Vorschlagswerten.
# Leere Eingabe = Vorschlag uebernehmen, "!" = abbrechen (Rueckgabe $null).

function Read-NetInput {
    <#
    .SYNOPSIS
        Einzige Stelle, die Read-Host aufruft (in Tests leicht zu ersetzen).
    #>
    param([Parameter(Mandatory = $true)][string]$Prompt, [switch]$Geheim)
    if (-not $script:NS.Interaktiv) { return $null }
    if ($Geheim) { return (Read-Host -Prompt $Prompt -AsSecureString) }
    return (Read-Host -Prompt $Prompt)
}

function Wait-NetKey {
    if (-not $script:NS.Interaktiv) { return }
    Read-NetInput -Prompt 'Weiter mit Enter' | Out-Null
}

function Read-NetText {
    <#
    .SYNOPSIS
        Fragt einen Text ab. Die Pruefung liefert $null (gueltig) oder einen Fehlertext.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [string]$Vorschlag = '',
        [scriptblock]$Pruefung,
        [switch]$LeerErlaubt
    )
    while ($true) {
        $prompt = $Frage
        if ($Vorschlag) { $prompt += " [$Vorschlag]" }
        $antwort = Read-NetInput -Prompt $prompt
        if ($null -eq $antwort) { return $null }
        $antwort = ([string]$antwort).Trim()
        if ($antwort -eq '!') { Write-Log -Message 'Eingabe abgebrochen.'; return $null }
        if ($antwort -eq '') {
            if ($Vorschlag) { $antwort = $Vorschlag }
            elseif ($LeerErlaubt) { return '' }
            else { Write-Host '[WARN]   Bitte einen Wert eingeben (oder ! zum Abbrechen).' -ForegroundColor Yellow; continue }
        }
        if ($Pruefung) {
            $fehler = & $Pruefung $antwort
            if ($fehler) { Write-Host ('[WARN]   ' + $fehler) -ForegroundColor Yellow; continue }
        }
        return $antwort
    }
}

function Read-NetYesNo {
    <#
    .SYNOPSIS
        Ja/Nein-Frage. Leere Eingabe = Vorschlag. Ohne Benutzer (Task) gilt der Vorschlag.
    #>
    param([Parameter(Mandatory = $true)][string]$Frage, [bool]$Vorschlag = $true)
    if (-not $script:NS.Interaktiv) { return $Vorschlag }
    $auswahl = '[j/N]'
    if ($Vorschlag) { $auswahl = '[J/n]' }
    while ($true) {
        $antwort = Read-NetInput -Prompt ("$Frage $auswahl")
        if ($null -eq $antwort) { return $Vorschlag }
        $a = ([string]$antwort).Trim().ToLower()
        if ($a -eq '') { return $Vorschlag }
        if (@('j', 'ja', 'y', 'yes') -contains $a) { return $true }
        if (@('n', 'nein', 'no', '!') -contains $a) { return $false }
        Write-Host '[WARN]   Bitte j oder n eingeben.' -ForegroundColor Yellow
    }
}

function Read-NetNumber {
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [int]$Minimum = 0,
        [int]$Maximum = [int]::MaxValue,
        [Nullable[int]]$Vorschlag = $null
    )
    $vor = ''
    if ($null -ne $Vorschlag) { $vor = [string]$Vorschlag }
    $grenzeMin = $Minimum
    $grenzeMax = $Maximum
    $text = Read-NetText -Frage $Frage -Vorschlag $vor -Pruefung {
        param($t)
        $z = 0
        if (-not [int]::TryParse($t, [ref]$z)) { return 'Bitte eine ganze Zahl eingeben.' }
        if ($z -lt $grenzeMin -or $z -gt $grenzeMax) { return "Erlaubt ist $grenzeMin bis $grenzeMax." }
        return $null
    }
    if ($null -eq $text) { return $null }
    return [int]$text
}

function Read-NetIPAddress {
    <#
    .SYNOPSIS
        Fragt eine IPv4-Adresse ab, optional muss sie in einem Netz liegen.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [string]$Vorschlag = '',
        [string]$Netz,
        [int]$Prefix = 0,
        [switch]$LeerErlaubt
    )
    $pruefNetz = $Netz
    $pruefPrefix = $Prefix
    $pruefung = {
        param($t)
        if (-not (Test-NetIPv4Address -Text $t)) { return "'$t' ist keine gueltige IPv4-Adresse (Beispiel: 192.168.1.10)." }
        if ($pruefNetz -and $pruefPrefix -gt 0 -and -not (Test-NetIPInSubnet -IPAddress $t -NetworkAddress $pruefNetz -PrefixLength $pruefPrefix)) {
            return "Die Adresse liegt nicht im Netz $pruefNetz/$pruefPrefix."
        }
        return $null
    }
    return (Read-NetText -Frage $Frage -Vorschlag $Vorschlag -Pruefung $pruefung -LeerErlaubt:$LeerErlaubt)
}

function ConvertTo-NetSubnet {
    <#
    .SYNOPSIS
        Wandelt "192.168.1.0/24" oder "192.168.1.0 255.255.255.0" in ein Subnetz-Objekt.
        Liefert $null bei ungueltiger Eingabe.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $t = $Text.Trim()
    $ip = $null
    $prefix = -1
    if ($t -match '^(\S+)\s*/\s*(\d{1,2})$') { $ip = $Matches[1]; $prefix = [int]$Matches[2] }
    elseif ($t -match '^(\S+)\s+(\S+)$') { $ip = $Matches[1]; $prefix = ConvertTo-NetPrefixLength -SubnetMask $Matches[2] }
    else { return $null }
    if (-not (Test-NetIPv4Address -Text $ip) -or $prefix -lt 1 -or $prefix -gt 32) { return $null }
    $netz = Get-NetNetworkAddress -IPAddress $ip -PrefixLength $prefix
    return [pscustomobject]@{
        Netz        = $netz
        Prefix      = $prefix
        Maske       = (ConvertTo-NetSubnetMask -PrefixLength $prefix)
        Text        = "$netz/$prefix"
        HostBitsGesetzt = ($netz -ne $ip)
    }
}

function Read-NetSubnet {
    <#
    .SYNOPSIS
        Fragt ein Netz ab (192.168.1.0/24 oder 192.168.1.0 255.255.255.0).
    #>
    param([Parameter(Mandatory = $true)][string]$Frage, [string]$Vorschlag = '')
    $text = Read-NetText -Frage $Frage -Vorschlag $Vorschlag -Pruefung {
        param($t)
        $s = ConvertTo-NetSubnet -Text $t
        if ($null -eq $s) { return 'Bitte im Format 192.168.1.0/24 oder 192.168.1.0 255.255.255.0 eingeben (Maske muss gueltig sein).' }
        if ($s.Prefix -gt 30) { return 'Das Netz ist zu klein (hoechstens /30).' }
        return $null
    }
    if ($null -eq $text) { return $null }
    $s = ConvertTo-NetSubnet -Text $text
    if ($s.HostBitsGesetzt) { Write-Log -Message ('Hinweis: Als Netzadresse wird {0} verwendet.' -f $s.Text) }
    return $s
}

function Read-NetChoice {
    <#
    .SYNOPSIS
        Auswahl aus einer Liste per Nummer. Liefert den Index (ab 0) oder -1 bei Abbruch.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [Parameter(Mandatory = $true)][string[]]$Optionen,
        [int]$Vorschlag = 1
    )
    if (-not $script:NS.Interaktiv) { return ($Vorschlag - 1) }
    Write-Host ''
    Write-Host ('  ' + $Frage) -ForegroundColor White
    for ($i = 0; $i -lt $Optionen.Count; $i++) {
        Write-Host ('   [{0}] {1}' -f ($i + 1), $Optionen[$i])
    }
    $anzahl = $Optionen.Count
    $t = Read-NetText -Frage 'Nummer' -Vorschlag ([string]$Vorschlag) -Pruefung {
        param($x)
        $z = 0
        if (-not [int]::TryParse($x, [ref]$z) -or $z -lt 1 -or $z -gt $anzahl) { return "Bitte eine Nummer von 1 bis $anzahl eingeben." }
        return $null
    }
    if ($null -eq $t) { return -1 }
    return ([int]$t - 1)
}

function ConvertFrom-NetSecureString {
    <#
    .SYNOPSIS
        Gibt den Klartext einer SecureString nur kurz im Speicher zurueck (fuer Pruefungen und
        Cmdlets, die Klartext verlangen). Nie speichern, nie loggen.
    #>
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Geheim)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Geheim)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-NetSecretComplexity {
    <#
    .SYNOPSIS
        Prueft ein Kennwort auf Windows-Komplexitaet. Liefert $null wenn ok, sonst den Grund.
    #>
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Geheim, [int]$MinLaenge = 8)
    $klar = ConvertFrom-NetSecureString -Geheim $Geheim
    try {
        if ($klar.Length -lt $MinLaenge) { return "Das Kennwort muss mindestens $MinLaenge Zeichen haben." }
        $klassen = 0
        if ($klar -cmatch '[A-Z]') { $klassen++ }
        if ($klar -cmatch '[a-z]') { $klassen++ }
        if ($klar -match '\d') { $klassen++ }
        if ($klar -match '[^A-Za-z0-9]') { $klassen++ }
        if ($klassen -lt 3) { return 'Das Kennwort braucht mindestens 3 von 4 Arten: Grossbuchstaben, Kleinbuchstaben, Ziffern, Sonderzeichen.' }
        return $null
    }
    finally { $klar = $null }
}

function Test-NetSecretEqual {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Erstes, [Parameter(Mandatory = $true)][System.Security.SecureString]$Zweites)
    $a = ConvertFrom-NetSecureString -Geheim $Erstes
    $b = ConvertFrom-NetSecureString -Geheim $Zweites
    try { return ($a -ceq $b) }
    finally { $a = $null; $b = $null }
}

function Read-NetSecret {
    <#
    .SYNOPSIS
        Fragt ein Kennwort verdeckt als SecureString ab, optional zweimal und mit Komplexitaetspruefung.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Frage,
        [switch]$Bestaetigen,
        [switch]$Komplex,
        [int]$MinLaenge = 8
    )
    for ($versuch = 1; $versuch -le 5; $versuch++) {
        $erstes = Read-NetInput -Prompt $Frage -Geheim
        if ($null -eq $erstes) { return $null }
        if ($erstes.Length -eq 0) { Write-Host '[WARN]   Leere Eingabe. Abbruch.' -ForegroundColor Yellow; return $null }
        if ($Komplex) {
            $grund = Test-NetSecretComplexity -Geheim $erstes -MinLaenge $MinLaenge
            if ($grund) { Write-Host ('[WARN]   ' + $grund) -ForegroundColor Yellow; continue }
        }
        if ($Bestaetigen) {
            $zweites = Read-NetInput -Prompt 'Zur Kontrolle wiederholen' -Geheim
            if (($null -eq $zweites) -or -not (Test-NetSecretEqual -Erstes $erstes -Zweites $zweites)) {
                Write-Host '[WARN]   Die Eingaben stimmen nicht ueberein.' -ForegroundColor Yellow
                continue
            }
        }
        return $erstes
    }
    Write-Log -Level Warn -Message 'Zu viele Fehlversuche, Eingabe abgebrochen.'
    return $null
}

function Confirm-NetChange {
    <#
    .SYNOPSIS
        Zeigt Vorher/Nachher einer geplanten Aenderung und fragt J/N (Vorschlag: Nein).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Titel,
        [AllowNull()][object]$Vorher,
        [AllowNull()][object]$Nachher,
        [string]$Hinweis,
        [string]$Stufe = 'Bestaetigen'
    )
    Write-Host ''
    Write-Host ('--- Geplante Aenderung: ' + $Titel + ' ---') -ForegroundColor Yellow
    if ($PSBoundParameters.ContainsKey('Vorher')) {
        Write-Host '  Vorher:' -ForegroundColor DarkYellow
        foreach ($z in (Format-NetValue -Wert $Vorher)) { Write-Host ('    ' + $z) }
    }
    if ($PSBoundParameters.ContainsKey('Nachher')) {
        Write-Host '  Nachher:' -ForegroundColor Green
        foreach ($z in (Format-NetValue -Wert $Nachher)) { Write-Host ('    ' + $z) }
    }
    if ($Hinweis) { Write-NetText -Text $Hinweis -Farbe Yellow }
    if ($Stufe -eq 'Gefaehrlich') { Write-Host '  Stufe: GEFAEHRLICH (vorher wird automatisch ein Backup erstellt)' -ForegroundColor Red }
    if (Test-NetDryRun) { Write-Host '  Probelauf ist aktiv: es wird nichts geaendert.' -ForegroundColor Magenta }
    if (-not $script:NS.Interaktiv) { return $false }
    return (Read-NetYesNo -Frage 'Ausfuehren?' -Vorschlag $false)
}

function Confirm-NetDangerous {
    <#
    .SYNOPSIS
        Zweite Sicherheitsstufe: der Servername muss eingetippt werden.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Dangerous ist ein Adjektiv, kein Plural; der Name ist vorgegeben.')]
    param([Parameter(Mandatory = $true)][string]$Titel, [string]$Hinweis)
    if (-not $script:NS.Interaktiv) { return $false }
    $name = [Environment]::MachineName
    Write-Host ''
    Write-Host '!!! ACHTUNG: Diese Aenderung ist gefaehrlich und kann den Betrieb stoeren !!!' -ForegroundColor Red
    Write-Host ('    ' + $Titel) -ForegroundColor Red
    if ($Hinweis) { Write-NetText -Text $Hinweis -Farbe Red }
    $eingabe = Read-NetInput -Prompt ("Zum Bestaetigen den Servernamen eintippen ($name)")
    if (($null -ne $eingabe) -and (([string]$eingabe).Trim() -ieq $name)) { return $true }
    Write-Log -Level Warn -Message 'Der Servername stimmt nicht. Es wird nichts geaendert.'
    return $false
}
