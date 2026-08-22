# Installe ONNX Runtime pour Windows — le moteur qui exécute Demucs.
#
#     .\onnx.ps1                    l'architecture de cette machine
#     .\onnx.ps1 -Arch x64          l'autre
#     .\onnx.ps1 -Version 1.29.0    une version précise
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI UN SCRIPT, ET PAS UNE DÉPENDANCE
#
# Sur le Mac, ONNX Runtime arrive par SwiftPM : Microsoft publie
# `onnxruntime-swift-package-manager`, qui porte la tranche macOS précompilée.
# **Ce paquet ne connaît qu'Apple.** Ailleurs, le moteur se distribue en NuGet et
# en archives GitHub, que SwiftPM ne sait pas aller chercher.
#
# On ne le commet pas non plus : seize mégaoctets par architecture, une version
# nouvelle toutes les six semaines, et un binaire versionné que personne ne relit.
# C'est exactement le régime des poids de Demucs — hors dépôt, fabriqués par un
# script, absents sans que rien ne casse.
#
# **Son absence n'empêche pas de construire.** `Package.swift` regarde si la
# bibliothèque est là : si elle n'y est pas, la séparation est compilée absente, et
# l'application le dit au lieu d'échouer. C'est ce qui permet à l'intégration
# continue de compiler tout le reste sans télécharger cent cinquante mégaoctets à
# chaque exécution.
# ─────────────────────────────────────────────────────────────────────────────

param(
    [string]$Version = "1.29.0",
    [ValidateSet("arm64", "x64", "les-deux")]
    [string]$Arch = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$racine = $PSScriptRoot
$cible = Join-Path $racine "build\onnxruntime"

if (-not $Arch) {
    # `PROCESSOR_ARCHITECTURE` dit ARM64 sur une machine ARM, AMD64 sinon. Le nom
    # que NuGet emploie n'est ni l'un ni l'autre, d'où la traduction.
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
}
$architectures = if ($Arch -eq "les-deux") { @("arm64", "x64") } else { @($Arch) }

$marque = Join-Path $cible "version.txt"
if ((Test-Path $marque) -and ((Get-Content $marque -Raw).Trim() -eq $Version) -and -not $Force) {
    $manque = $architectures | Where-Object {
        -not (Test-Path (Join-Path $cible "$_\onnxruntime.lib"))
    }
    if (-not $manque) {
        Write-Host "ONNX Runtime $Version est déjà là ($cible)."
        exit 0
    }
}

# Le paquet complet pèse cent cinquante mégaoctets — toutes les plateformes à la
# fois. On n'en garde que les quelques fichiers qui servent, et l'archive s'en va.
$archive = Join-Path $env:TEMP "onnxruntime-$Version.nupkg"
$adresse = "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/" +
           "$Version/microsoft.ml.onnxruntime.$Version.nupkg"

if (-not (Test-Path $archive)) {
    Write-Host "Téléchargement d'ONNX Runtime $Version…"
    # `ProgressPreference` à « SilentlyContinue » : la barre de progression de
    # `Invoke-WebRequest` divise son débit par dix sur un gros fichier, ce qui est
    # documenté et surprend chaque fois.
    $avant = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try { Invoke-WebRequest $adresse -OutFile $archive -TimeoutSec 900 }
    finally { $ProgressPreference = $avant }
}
Write-Host ("archive : {0:N1} Mo" -f ((Get-Item $archive).Length / 1MB))

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try {
    function extraire($dans, $depuis) {
        $entree = $zip.Entries | Where-Object { $_.FullName -eq $depuis }
        if (-not $entree) { throw "« $depuis » n'est pas dans le paquet." }
        New-Item -ItemType Directory -Force -Path (Split-Path $dans) | Out-Null
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entree, $dans, $true)
    }

    # Les en-têtes sont les mêmes pour toutes les architectures : un seul dossier.
    foreach ($entree in $zip.Entries) {
        if ($entree.FullName -like "build/native/include/*" -and $entree.Name) {
            extraire (Join-Path $cible "include\$($entree.Name)") $entree.FullName
        }
    }

    foreach ($a in $architectures) {
        foreach ($fichier in @("onnxruntime.lib", "onnxruntime.dll",
                               "onnxruntime_providers_shared.dll")) {
            extraire (Join-Path $cible "$a\$fichier") "runtimes/win-$a/native/$fichier"
        }
        Write-Host "  $a — $(Join-Path $cible $a)"
    }
} finally { $zip.Dispose() }

Set-Content -Path $marque -Value $Version -Encoding utf8 -NoNewline
Remove-Item $archive -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "ONNX Runtime $Version installé dans build\onnxruntime."
Write-Host "Reconstruire pour que la séparation entre dans la compilation :"
Write-Host "    swift build -c release"
