# Dépose l'en-tête de miniaudio là où la cible C l'attend.
#
# Il n'est pas versionné : près de quatre mégaoctets pour un fichier qui se
# retélécharge en une seconde, et que personne ne relit.
$ErrorActionPreference = "Stop"
$racine = Split-Path $PSScriptRoot
$cible = Join-Path $racine "Sources\CMiniaudio\include\miniaudio.h"
$version = "0.11.22"
if (Test-Path $cible) { Write-Host "miniaudio déjà présent"; exit 0 }
New-Item -ItemType Directory -Force -Path (Split-Path $cible) | Out-Null
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mackron/miniaudio/$version/miniaudio.h" -OutFile $cible
Write-Host "miniaudio $version → $cible"
