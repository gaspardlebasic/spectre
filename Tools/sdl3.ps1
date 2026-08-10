# Va chercher SDL3 et rend les drapeaux à passer au compilateur.
#
#   .\Tools\sdl3.ps1              installe dans build\deps si nécessaire
#   swift build -c release @(& .\Tools\sdl3.ps1 -Drapeaux)
#
# SDL3 est distribué compilé pour Windows : on prend l'archive MSVC, qui est
# l'ABI de Swift ici, plutôt que de la reconstruire. L'archive n'est pas
# versionnée — elle vit dans `build\`, que le dépôt ignore.

param([switch]$Drapeaux)

$ErrorActionPreference = "Stop"
$racine = Split-Path $PSScriptRoot
$version = "3.4.14"
$dossier = Join-Path $racine "build\deps\SDL3-$version"

if (-not (Test-Path $dossier)) {
    $deps = Join-Path $racine "build\deps"
    New-Item -ItemType Directory -Force -Path $deps | Out-Null
    $zip = Join-Path $deps "SDL3.zip"
    $url = "https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-devel-$version-VC.zip"
    if (-not $Drapeaux) { Write-Host "Téléchargement de SDL3 $version…" }
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $url -OutFile $zip
    Expand-Archive $zip -DestinationPath $deps -Force
    Remove-Item $zip
}

# L'architecture de la machine, pas celle qu'on suppose : un Windows sur puce
# Apple est en ARM64, et pointer les bibliothèques x64 échoue à l'édition de
# liens sur un message qui parle de symboles, pas d'architecture.
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { "arm64" }
    "AMD64" { "x64" }
    default { "x86" }
}
$include = Join-Path $dossier "include"
$lib = Join-Path $dossier "lib\$arch"

if ($Drapeaux) {
    # Sortis un par ligne, à passer tels quels à `swift build`. `-Xcxx` en plus
    # de `-Xcc` : la passerelle vers Dear ImGui est du C++, et SwiftPM ne verse
    # pas les drapeaux C dans la compilation C++.
    "-Xcc"; "-I$include"
    "-Xcxx"; "-I$include"
    "-Xlinker"; "-L$lib"
} else {
    Write-Host "SDL3 $version ($arch)"
    Write-Host "  en-têtes     $include"
    Write-Host "  bibliothèque $lib"
    Write-Host ""
    Write-Host "  swift build -c release @(& .\Tools\sdl3.ps1 -Drapeaux)"
}
