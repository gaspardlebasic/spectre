# Construit Spectre sous Windows et assemble ce qui se distribue.
#
# Pendant de `build.sh`, et volontairement plus court : il n'y a pas de paquet
# `.app` à monter, pas de signature ad-hoc, pas d'enregistrement auprès de
# LaunchServices. Un dossier, un zip.
#
# Ce que ce script produit aujourd'hui n'est pas encore l'application : l'interface
# et le rendu ne sont pas portés. C'est `SpectreCLI` — décoder, analyser, régler le
# contraste, estimer le tempo, dessiner — plus les vérifications, qui permettent à
# qui reçoit le zip de constater que le calcul est juste chez lui.
#
#   .\build.ps1              construit et assemble
#   .\build.ps1 -Verifier    et fait tourner les vérifications avant d'assembler

param(
    [switch]$Verifier,
    [string]$Configuration = "release"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# SwiftPM ne sait pas travailler sur un chemin UNC : si le dépôt est monté depuis
# un partage — le cas quand on construit dans une machine virtuelle — il faut le
# copier sur un disque local d'abord. Mieux vaut le dire que d'échouer sur un
# « invalid absolute path 'UNC\...' » qui n'évoque rien.
if ($PSScriptRoot -like "\\*") {
    throw "SwiftPM ne construit pas depuis un chemin réseau ($PSScriptRoot). " +
          "Copier le dépôt sur un disque local, par exemple : " +
          "robocopy $PSScriptRoot C:\spectre /MIR /XD .build build .git"
}

Write-Host "Compilation ($Configuration)…"
swift build -c $Configuration
if ($LASTEXITCODE -ne 0) { throw "La compilation a échoué." }

$bin = swift build -c $Configuration --show-bin-path

if ($Verifier) {
    foreach ($p in @("DSPCheck", "FilterCheck", "ChainCheck", "WAVCheck", "AnalysisCheck")) {
        Write-Host ""
        Write-Host "=== $p ==="
        & "$bin\$p.exe"
        if ($LASTEXITCODE -ne 0) { throw "$p a échoué." }
    }
    Write-Host ""
}

$sortie = "build\Spectre"
if (Test-Path $sortie) { Remove-Item -Recurse -Force $sortie }
New-Item -ItemType Directory -Force -Path $sortie | Out-Null

Copy-Item "$bin\SpectreCLI.exe" $sortie
if (Test-Path "$bin\SpectreWindows.exe") {
    Copy-Item "$bin\SpectreWindows.exe" $sortie
    # Le nuanceur est lu à côté de l'exécutable : il n'est pas compilé dans le
    # binaire, ce qui permet de le retoucher sans reconstruire.
    Copy-Item "Resources\spectrogramme.glsl" $sortie
    $sdl = Get-ChildItem "build\deps" -Filter "SDL3.dll" -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.DirectoryName -like "*arm64*" -or $_.DirectoryName -like "*x64*" } |
           Select-Object -First 1
    if ($sdl) { Copy-Item $sdl.FullName $sortie } else { Write-Host "Note : SDL3.dll introuvable." }
}

# Les bibliothèques d'exécution de Swift ne sont pas sur la machine de qui reçoit
# le zip. Les emporter évite un « le programme ne peut pas démarrer car
# swiftCore.dll est introuvable », qui est le premier obstacle d'une distribution
# Windows et n'a rien d'évident quand on vient de macOS.
#
# La liste est explicite, et pas un `*.dll` : le dossier du compilateur contient
# aussi tout ce qui sert à *produire* du Swift, ce qui fait passer le zip de
# quelques dizaines de mégaoctets à deux cent cinquante.
# Les bibliothèques d'exécution ne sont **pas** à côté du compilateur : elles
# vivent dans `…\Swift\Runtimes\<version>\usr\bin`, un dossier distinct que
# l'installeur ajoute au PATH. Chercher à côté de `swift.exe` ne trouve presque
# rien, et le zip part sans elles — panne qui n'apparaît que chez l'utilisateur.
# On remonte jusqu'au dossier `Swift` plutôt que de compter les niveaux : la
# profondeur change d'une version à l'autre, et un compte faux ne se voit pas —
# il rend juste un dossier vide.
$toolchain = Split-Path (Get-Command swift.exe).Source
$racine = Get-Item $toolchain
while ($racine -and $racine.Name -ne "Swift") { $racine = $racine.Parent }
$runtime = $null
if ($racine) {
    $runtime = (Get-ChildItem $racine.FullName -Filter "swiftCore.dll" -Recurse `
                              -ErrorAction SilentlyContinue |
                Select-Object -First 1).DirectoryName
}
if (-not $runtime) { $runtime = $toolchain }

$emportees = @(
    "swiftCore.dll", "swiftCRT.dll", "swiftWinSDK.dll",
    "swiftDispatch.dll", "dispatch.dll", "BlocksRuntime.dll",
    "Foundation.dll", "FoundationEssentials.dll",
    "FoundationInternationalization.dll", "FoundationNetworking.dll",
    "_FoundationICU.dll",
    "swift_Concurrency.dll", "swift_StringProcessing.dll",
    "swift_RegexParser.dll", "swiftSynchronization.dll"
)
$manquantes = @()
foreach ($dll in $emportees) {
    $chemin = Join-Path $runtime $dll
    if (Test-Path $chemin) { Copy-Item $chemin $sortie } else { $manquantes += $dll }
}
if ($manquantes) {
    # Pas une erreur : la composition du runtime bouge d'une version à l'autre, et
    # une DLL absente ici est souvent une DLL qui n'existe plus. On le dit, parce
    # que le contraire — une DLL nécessaire oubliée — ne se voit que sur la
    # machine de l'utilisateur, au lancement.
    Write-Host "Note : absentes du runtime, non emportées — $($manquantes -join ', ')"
}

Copy-Item "README.md", "WINDOWS.md" $sortie -ErrorAction SilentlyContinue

$zip = "build\Spectre-windows.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path "$sortie\*" -DestinationPath $zip

$taille = "{0:N1}" -f ((Get-Item $zip).Length / 1MB)
Write-Host ""
Write-Host "→ $sortie"
Write-Host "→ $zip ($taille Mo)"
Write-Host ""
Write-Host "Essai :  $sortie\SpectreCLI.exe morceau.wav"
