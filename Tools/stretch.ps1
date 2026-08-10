# Dépose signalsmith-stretch là où la cible C++ l'attend.
#
# C'est le vocodeur de phase qui remplace `AVAudioUnitTimePitch` : ralentir sans
# transposer, transposer sans ralentir. MIT, et l'archive de la version publiée
# porte déjà son dossier `dsp` — le seul sous-module du dépôt ne sert qu'à son
# programme d'exemple.
$ErrorActionPreference = "Stop"
$racine = Split-Path $PSScriptRoot
$cible = Join-Path $racine "Sources\CStretch\signalsmith"
$version = "1.1.0"
if (Test-Path (Join-Path $cible "signalsmith-stretch.h")) {
    Write-Host "signalsmith-stretch déjà présent"
    exit 0
}
New-Item -ItemType Directory -Force -Path $cible | Out-Null
$ProgressPreference = "SilentlyContinue"
$temp = Join-Path $env:TEMP "stretch-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $zip = Join-Path $temp "stretch.zip"
    Invoke-WebRequest -Uri "https://github.com/Signalsmith-Audio/signalsmith-stretch/archive/refs/tags/$version.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $temp -Force
    $src = Join-Path $temp "signalsmith-stretch-$version"
    Copy-Item (Join-Path $src "signalsmith-stretch.h") $cible
    Copy-Item (Join-Path $src "LICENSE.txt") $cible
    Copy-Item (Join-Path $src "dsp") $cible -Recurse -Force
} finally {
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
Write-Host "signalsmith-stretch $version → $cible"
