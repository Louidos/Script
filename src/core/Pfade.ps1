# Pfade unter dem Datenordner (Standard C:\NetSetup) und Anlegen der Ordner.

function Get-NetPath {
    <#
    .SYNOPSIS
        Liefert einen Pfad unterhalb des Datenordners.
    #>
    param(
        [ValidateSet('Root', 'Config', 'Logs', 'Backups', 'Berichte', 'Rueckgaengig', 'Vorlagen',
            'ConfigDatei', 'Script', 'Fortsetzung', 'Verlauf')]
        [string]$Name = 'Root'
    )
    $root = $script:NS.Datenpfad
    switch ($Name) {
        'Root' { return $root }
        'ConfigDatei' { return (Join-Path -Path (Join-Path -Path $root -ChildPath 'Config') -ChildPath 'netsetup.json') }
        'Fortsetzung' { return (Join-Path -Path (Join-Path -Path $root -ChildPath 'Config') -ChildPath 'fortsetzung.json') }
        'Verlauf' { return (Join-Path -Path (Join-Path -Path $root -ChildPath 'Rueckgaengig') -ChildPath 'verlauf.json') }
        'Script' { return (Join-Path -Path $root -ChildPath 'NetSetup.ps1') }
        default { return (Join-Path -Path $root -ChildPath $Name) }
    }
}

function Test-NetIsWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-NetDataRootPointer {
    <#
    .SYNOPSIS
        Liest den gespeicherten Datenordner aus der Registry (falls beim ersten Start geaendert).
    #>
    try {
        $wert = Get-ItemProperty -Path $script:NS.RegistryPfad -Name 'Datenpfad' -ErrorAction Stop
        if ($wert.Datenpfad) { return [string]$wert.Datenpfad }
    }
    catch {
        Write-Verbose 'Kein gespeicherter Datenordner, Standard wird verwendet.'
    }
    return $null
}

function Set-NetDataRootPointer {
    param([Parameter(Mandatory = $true)][string]$Pfad)
    try {
        if (-not (Test-Path -Path $script:NS.RegistryPfad)) {
            New-Item -Path $script:NS.RegistryPfad -Force | Out-Null
        }
        Set-ItemProperty -Path $script:NS.RegistryPfad -Name 'Datenpfad' -Value $Pfad -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log -Level Warn -Message "Datenordner konnte nicht in der Registry gemerkt werden: $($_.Exception.Message)"
        return $false
    }
}

function Protect-NetFolder {
    <#
    .SYNOPSIS
        Erlaubt den Datenordner nur Administratoren und SYSTEM.
    .DESCRIPTION
        Im Datenordner liegen das Script (RunOnce, geplante Aufgabe), Backups und die
        Rueckgaengig-Liste. Normale Benutzer duerfen dort nichts aendern koennen.
        Gruppen werden ueber SIDs angesprochen, damit es auf jedem Sprachpaket klappt.
    #>
    param([Parameter(Mandatory = $true)][string]$Pfad)
    if (-not (Test-NetIsWindows)) { return }
    try {
        $acl = Get-Acl -Path $Pfad -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($regel in @($acl.Access)) { [void]$acl.RemoveAccessRule($regel) }
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $regel = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl',
                'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($regel)
        }
        Set-Acl -Path $Pfad -AclObject $acl -ErrorAction Stop
    }
    catch {
        Write-Log -Level Warn -Message "Rechte auf $Pfad konnten nicht eingeschraenkt werden. Bitte pruefen, dass nur Administratoren Zugriff haben."
        Write-Log -Level Debug -Message $_.Exception.ToString()
    }
}

function Initialize-NetFolder {
    <#
    .SYNOPSIS
        Legt den Datenordner und alle Unterordner an (idempotent).
    #>
    $root = Get-NetPath -Name Root
    $neu = -not (Test-Path -Path $root)
    if ($neu) { New-Item -Path $root -ItemType Directory -Force | Out-Null }
    foreach ($ordner in $script:NS.Unterordner) {
        $pfad = Join-Path -Path $root -ChildPath $ordner
        if (-not (Test-Path -Path $pfad)) { New-Item -Path $pfad -ItemType Directory -Force | Out-Null }
    }
    if ($neu) { Protect-NetFolder -Pfad $root }
    return $neu
}
