# Gemeinsamer Zustand der laufenden Sitzung.
# Alle Funktionen lesen und schreiben ueber $script:NS, damit beim Einfuegen
# in die Konsole ausser dieser einen Variable nichts liegen bleibt.

if (-not $script:NetSetupVersion) { $script:NetSetupVersion = '0.0.0-dev' }
if (-not $script:NetSetupBuildDatum) { $script:NetSetupBuildDatum = '' }

$script:NS = @{
    Version         = $script:NetSetupVersion
    BuildDatum      = $script:NetSetupBuildDatum
    StandardPfad    = 'C:\NetSetup'
    Datenpfad       = 'C:\NetSetup'
    RegistryPfad    = 'HKLM:\SOFTWARE\NetSetup'
    Unterordner     = @('Config', 'Logs', 'Backups', 'Berichte', 'Rueckgaengig', 'Vorlagen')
    Probelauf       = $false
    Interaktiv      = $true
    Config          = $null
    LogDatei        = $null
    TranscriptAktiv = $false
    Umgebung        = $null
    Zustand         = $null
    Checks          = New-Object System.Collections.ArrayList
    ErsterStart     = $false
    Zusammenfassung = $null
    AssistentAktiv  = $false
    NeustartGeplant = $false
    LetzterDoktor   = $null
    ErweitertFrei   = $false
}
