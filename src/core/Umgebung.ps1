# Umgebung erkennen (Administrator, Windows Server, PowerShell-Version, Server Core, Sprache),
# Script selbst speichern, Desktop-Verknuepfung und Neustart mit Adminrechten.

function Test-NetIsAdmin {
    if (-not (Test-NetIsWindows)) { return $false }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-NetEnvironment {
    <#
    .SYNOPSIS
        Erkennt die Umgebung, in der NetSetup laeuft (nur lesend).
    #>
    $os = Get-NetSafe -Beschreibung 'Win32_OperatingSystem' -Abfrage { Get-CimInstance -ClassName Win32_OperatingSystem }
    $installationsTyp = Get-NetSafe -Beschreibung 'InstallationType' -Abfrage {
        (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType).InstallationType
    }
    $edition = Get-NetSafe -Beschreibung 'EditionID' -Abfrage {
        (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID).EditionID
    }
    $istIse = ($null -ne (Get-Variable -Name psISE -Scope Global -ErrorAction SilentlyContinue)) -or ($Host.Name -eq 'Windows PowerShell ISE Host')
    $istCore = ([string]$installationsTyp -eq 'Server Core')
    $productType = 0
    if ($os) { $productType = [int]$os.ProductType }
    $umgebung = [pscustomobject]@{
        IstWindows   = (Test-NetIsWindows)
        IstAdmin     = (Test-NetIsAdmin)
        ProductType  = $productType
        IstServer    = ($productType -eq 2 -or $productType -eq 3)
        OsName       = $(if ($os) { [string]$os.Caption } else { 'unbekannt' })
        OsVersion    = $(if ($os) { [string]$os.Version } else { '' })
        Build        = $(if ($os) { [string]$os.BuildNumber } else { '' })
        OsSprache    = $(if ($os) { [int]$os.OSLanguage } else { 0 })
        Edition      = [string]$edition
        IstCore      = $istCore
        PsVersion    = $PSVersionTable.PSVersion
        PsEdition    = $(if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' })
        Sprache      = (Get-Culture).Name
        UiSprache    = (Get-UICulture).Name
        IstIse       = $istIse
        HatGridView  = ((-not $istCore) -and [bool](Get-Command -Name Out-GridView -ErrorAction SilentlyContinue))
        Computername = [Environment]::MachineName
    }
    $script:NS.Umgebung = $umgebung
    return $umgebung
}

function Test-NetPrerequisite {
    <#
    .SYNOPSIS
        Prueft die Voraussetzungen. Liefert 'OK', 'Abbruch' oder 'NeuGestartet'.
    #>
    param([Parameter(Mandatory = $true)][object]$Umgebung)

    if (-not $Umgebung.IstWindows) {
        Write-Log -Level Fehler -Message 'NetSetup laeuft nur auf Windows Server.'
        return 'Abbruch'
    }
    if ($Umgebung.PsVersion.Major -lt 5 -or ($Umgebung.PsVersion.Major -eq 5 -and $Umgebung.PsVersion.Minor -lt 1)) {
        Write-Log -Level Fehler -Message ('NetSetup braucht Windows PowerShell 5.1, gefunden: {0}.' -f $Umgebung.PsVersion)
        Write-Log -Message 'Naechster Schritt: Windows Management Framework 5.1 installieren (bei Server 2016 und neuer schon enthalten).'
        return 'Abbruch'
    }
    if ($Umgebung.PsEdition -eq 'Core') {
        Write-Log -Level Warn -Message ('Gestartet in PowerShell {0}. NetSetup ist fuer Windows PowerShell 5.1 gebaut (powershell.exe), manche Server-Module laufen nur dort.' -f $Umgebung.PsVersion)
        if ($script:NS.Interaktiv -and -not (Read-NetYesNo -Frage 'Trotzdem fortfahren?' -Vorschlag $false)) { return 'Abbruch' }
    }
    if ($Umgebung.ProductType -eq 1) {
        Write-Log -Level Fehler -Message ('Dies ist kein Windows Server, sondern {0}.' -f $Umgebung.OsName)
        Write-Log -Message 'AD, DNS-Server und DHCP-Server gibt es nur auf Windows Server. Bitte NetSetup auf dem Server ausfuehren, der diese Rollen bekommen soll.'
        return 'Abbruch'
    }
    if ($Umgebung.ProductType -eq 0) {
        Write-Log -Level Warn -Message 'Die Windows-Version konnte nicht erkannt werden. NetSetup versucht es trotzdem.'
    }
    if (-not $Umgebung.IstAdmin) {
        Write-Log -Level Warn -Message 'NetSetup laeuft ohne Administratorrechte. Fast alle Aufgaben brauchen diese Rechte.'
        if (-not $script:NS.Interaktiv) { return 'Abbruch' }
        if (Read-NetYesNo -Frage 'Jetzt mit Administratorrechten neu starten (Windows fragt nach)?' -Vorschlag $true) {
            if (Request-NetElevation) { return 'NeuGestartet' }
        }
        Write-Log -Message 'So geht es von Hand: Startmenue -> "Windows PowerShell ISE" oder "Windows PowerShell" mit rechter Maustaste -> "Als Administrator ausfuehren", dann das Script erneut einfuegen.'
        return 'Abbruch'
    }
    return 'OK'
}

function Get-NetSelfContent {
    <#
    .SYNOPSIS
        Liefert den vollstaendigen Script-Text zum Speichern (aus dem laufenden Scriptblock).
    #>
    $block = Get-Variable -Name NetSetupCode -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $block) { return $null }
    $kopf = @(
        '<#',
        ('    NetSetup {0} (Build {1})' -f $script:NS.Version, $script:NS.BuildDatum),
        '    AD, DNS und DHCP auf Windows Server einrichten, verwalten und reparieren.',
        '    Gespeichert von NetSetup. Start: powershell.exe -ExecutionPolicy Bypass -File NetSetup.ps1',
        '    Ohne Menue: -Task Health | Report | Backup | Resume',
        '#>'
    ) -join "`r`n"
    return ($kopf + "`r`n`$NetSetupCode = {" + $block.ToString() + "}`r`n& `$NetSetupCode @args`r`n")
}

function Save-NetSelf {
    <#
    .SYNOPSIS
        Speichert das laufende Script als Datei (Standard: <Datenordner>\NetSetup.ps1).
    #>
    param([string]$Ziel = (Get-NetPath -Name Script))
    $inhalt = Get-NetSelfContent
    if (-not $inhalt) {
        Write-Log -Level Debug -Message 'Script-Text nicht verfuegbar (Scriptblock fehlt), Speichern uebersprungen.'
        return $null
    }
    try {
        $ordner = Split-Path -Path $Ziel -Parent
        if (-not (Test-Path -Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
        $alt = $null
        if (Test-Path -Path $Ziel) { $alt = Get-Content -Path $Ziel -Raw -ErrorAction SilentlyContinue }
        if ($alt -ne $inhalt) {
            [System.IO.File]::WriteAllText($Ziel, $inhalt, (New-Object System.Text.ASCIIEncoding))
            Write-Log -Level OK -Message ('Script gespeichert: ' + $Ziel)
        }
        return $Ziel
    }
    catch {
        Write-NetError -Fehler $_ -Titel 'Script speichern' | Out-Null
        return $null
    }
}

function Get-NetPowerShellExe {
    return (Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Request-NetElevation {
    <#
    .SYNOPSIS
        Speichert eine Kopie nach %TEMP% und startet sie per UAC mit Administratorrechten.
    #>
    $ziel = Join-Path -Path $env:TEMP -ChildPath 'NetSetup.ps1'
    $gespeichert = Save-NetSelf -Ziel $ziel
    if (-not $gespeichert) {
        Write-Log -Level Warn -Message 'Die Kopie fuer den Neustart konnte nicht gespeichert werden.'
        return $false
    }
    try {
        $argumente = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $ziel))
        Start-Process -FilePath (Get-NetPowerShellExe) -ArgumentList $argumente -Verb RunAs -ErrorAction Stop | Out-Null
        Write-Log -Level OK -Message 'NetSetup wurde in einem neuen Fenster mit Administratorrechten gestartet. Dieses Fenster kann geschlossen werden.'
        return $true
    }
    catch {
        Write-Log -Level Warn -Message 'Der Start mit Administratorrechten wurde abgelehnt oder ist fehlgeschlagen.'
        Write-Log -Level Debug -Message $_.Exception.ToString()
        return $false
    }
}

function New-NetDesktopShortcut {
    <#
    .SYNOPSIS
        Legt eine Desktop-Verknuepfung "NetSetup" an, die als Administrator startet.
    #>
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -Path $desktop)) {
        Write-Log -Level Warn -Message 'Kein Desktop gefunden (z. B. Server Core). Verknuepfung wird nicht angelegt.'
        return $false
    }
    $lnk = Join-Path -Path $desktop -ChildPath 'NetSetup.lnk'
    $script_pfad = Get-NetPath -Name Script
    $r = Invoke-NetChange -Titel 'Desktop-Verknuepfung NetSetup anlegen' -Stufe Automatisch -Aktion {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($lnk)
        $link.TargetPath = (Get-NetPowerShellExe)
        $link.Arguments = ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $script_pfad)
        $link.WorkingDirectory = (Get-NetPath -Name Root)
        $link.Description = 'NetSetup: AD, DNS und DHCP einrichten und pruefen'
        $link.Save()
        # Flag "Als Administrator ausfuehren" (Bit 0x20 in Byte 0x15 der .lnk-Datei)
        $bytes = [System.IO.File]::ReadAllBytes($lnk)
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [System.IO.File]::WriteAllBytes($lnk, $bytes)
    } -Rueckgaengig @{ Befehl = 'Remove-Item'; Parameter = @{ Path = $lnk; Force = $true } }
    return $r.Erfolg
}
