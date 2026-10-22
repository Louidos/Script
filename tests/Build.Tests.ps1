BeforeAll {
    $script:root = Split-Path -Path $PSScriptRoot -Parent
    $script:dist = Join-Path -Path $script:root -ChildPath 'dist/NetSetup.ps1'
}

Describe 'Build und Einzeldatei' {
    It 'dist/NetSetup.ps1 ist aktuell' {
        & (Join-Path -Path $script:root -ChildPath 'scripts/Build-NetSetup.ps1') -Check | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'besteht die Qualitaetspruefung (ASCII, Tabs, Parser, Verbotsliste)' {
        & (Join-Path -Path $script:root -ChildPath 'scripts/Test-NetSetupQualitaet.ps1') | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'enthaelt jede Datei aus build.psd1' {
        $text = Get-Content -Path $script:dist -Raw
        $projekt = Import-PowerShellDataFile -Path (Join-Path -Path $script:root -ChildPath 'build.psd1')
        foreach ($d in $projekt.Dateien) {
            if ($d -ne '@checks') { $text | Should -Match ([regex]::Escape('# ' + $d)) }
        }
        $text | Should -Match ([regex]::Escape("NetSetupVersion = '" + $projekt.Version + "'"))
    }
    It 'kann sich selbst speichern und die gespeicherte Datei ist gueltig' {
        $tokens = $null; $fehler = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:dist, [ref]$tokens, [ref]$fehler)
        $block = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        $inner = $block.Extent.Text
        $NetSetupCode = [scriptblock]::Create($inner.Substring(1, $inner.Length - 2))
        . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
        $ziel = Join-Path -Path $TestDrive -ChildPath 'NetSetup.ps1'
        $script:NS.LogDatei = $null
        Save-NetSelf -Ziel $ziel | Should -Be $ziel
        $f2 = $null
        $ast2 = [System.Management.Automation.Language.Parser]::ParseFile($ziel, [ref]$null, [ref]$f2)
        @($f2).Count | Should -Be 0
        @($ast2.EndBlock.Statements).Count | Should -Be 2
        [System.IO.File]::ReadAllBytes($ziel) | Where-Object { $_ -gt 127 } | Should -BeNullOrEmpty
    }
    It 'startet als Datei ohne Menue und stuerzt nicht ab (-Task Health)' {
        $exe = 'pwsh'
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $exe = 'powershell.exe' }
        $ausgabe = & $exe -NoProfile -ExecutionPolicy Bypass -File $script:dist -Task Health 2>&1 | Out-String
        $ausgabe | Should -Match 'NetSetup'
        $ausgabe | Should -Not -Match 'Exception|ParserError|CommandNotFound'
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $ausgabe | Should -Not -Match '\[FEHLER\]'
        }
    }
    It 'laeuft auch als eingefuegter Text (Scriptblock ohne Datei)' {
        $text = Get-Content -Path $script:dist -Raw
        $exe = 'pwsh'
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $exe = 'powershell.exe' }
        $befehl = '$text = [System.IO.File]::ReadAllText(''' + $script:dist + '''); $text = $text -replace ''& \$NetSetupCode @args'', ''& $NetSetupCode -Task Health''; Invoke-Expression $text'
        $ausgabe = & $exe -NoProfile -ExecutionPolicy Bypass -Command $befehl 2>&1 | Out-String
        $text | Should -Not -BeNullOrEmpty
        $ausgabe | Should -Match 'NetSetup'
        $ausgabe | Should -Not -Match 'ParserError|CommandNotFound'
    }
}
