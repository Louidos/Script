## Was ändert sich?

<!-- Kurz beschreiben, was der Nutzer merkt. -->

Closes #

## Checkliste

- [ ] Branch vom aktuellen `main`, ein Thema pro PR
- [ ] Conventional Commit (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`)
- [ ] CHANGELOG unter `## Unveröffentlicht` ergänzt (mit Issue-Nummer)
- [ ] `./scripts/Build-NetSetup.ps1` ausgeführt, `dist/NetSetup.ps1` aktuell
- [ ] Tests ergänzt, `Invoke-Pester -Path tests -CI` grün
- [ ] `Invoke-ScriptAnalyzer` ohne Befunde
- [ ] README/docs angepasst, falls sich Bedienung oder Verhalten ändert

## Getestet

<!-- Wo und wie getestet? Falls nicht lokal möglich: "lokal nicht getestet, CI entscheidet". -->
