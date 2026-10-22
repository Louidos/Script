BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelper.ps1')
    $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:handbuch = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'docs/handbuch.md') -Raw -Encoding UTF8
    $script:testplan = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'docs/testplan.md') -Raw -Encoding UTF8
    $script:readme = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'README.md') -Raw -Encoding UTF8
}

Describe 'Handbuch' {
    It 'Menuepunkte und Glossar im Handbuch sind aktuell (Update-Handbuch -Check)' {
        & (Join-Path -Path $script:repoRoot -ChildPath 'scripts/Update-Handbuch.ps1') -Check | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'das Glossar im Handbuch stimmt mit dem Glossar im Script ueberein' {
        foreach ($begriff in $script:NetGlossar.Keys) {
            $script:handbuch | Should -Match ([regex]::Escape('**' + $begriff + '**')) -Because "Begriff $begriff"
            $script:handbuch | Should -Match ([regex]::Escape(': ' + $script:NetGlossar[$begriff])) -Because "Text zu $begriff"
        }
    }
    It 'beschreibt jeden Hauptmenuepunkt' {
        foreach ($e in (Get-NetMainMenuEntry)) { $script:handbuch | Should -Match ([regex]::Escape('**' + $e.Text + '**')) }
    }
}

Describe 'Testplan' {
    It 'deckt alle Ausgangslagen ab' {
        foreach ($stichwort in @('Arbeitsgruppe', 'DC nur mit DNS', 'fertigem DHCP', 'Falsch installierte Rollen', 'Server Core', 'Deutsch', 'Englisch', '2016', '2019', '2022', '2025', 'ohne Internet', 'ISE', 'Windows 11')) {
            $script:testplan | Should -Match ([regex]::Escape($stichwort)) -Because "Ausgangslage $stichwort"
        }
    }
}

Describe 'README' {
    It 'erklaert das Einfuegen fuer ISE, Konsole und Datei' {
        foreach ($stichwort in @('Als Administrator ausf', 'F5', 'Strg+V', '-ExecutionPolicy Bypass -File', 'dist/NetSetup.ps1')) {
            $script:readme | Should -Match ([regex]::Escape($stichwort))
        }
    }
}
