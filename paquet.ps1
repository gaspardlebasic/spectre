# Fabrique l'installeur Windows de Spectre.
#
#     .\paquet.ps1                    l'installeur de cette machine
#     .\paquet.ps1 -Version 0.3       le numéro que porte la livraison
#     .\paquet.ps1 -Force             en réinstallant le compilateur
#
# Produit deux fichiers, sous le même numéro : l'installeur, et l'archive du dossier
# pour qui préfère ne rien inscrire dans la base de registres. Le script refait
# l'icône et l'assemblage à chaque fois — c'est l'ordre qui compte, la ressource
# posant le numéro de version dans l'exécutable avant qu'il ne soit construit.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE CE SCRIPT AJOUTE À `build.ps1`
#
# `build.ps1` produit un dossier qui se suffit à lui-même, et son épreuve du dossier
# propre dit qu'il tourne sur une machine qui n'a jamais vu Swift. C'est une
# distribution valable, et c'est celle qu'on donne à qui veut essayer sans rien
# inscrire nulle part.
#
# Ce qu'un dossier ne peut pas faire, c'est **se faire connaître de Windows** : un
# raccourci au menu Démarrer, une entrée dans « Applications installées », une icône
# sur les fichiers audio, un double-clic qui ouvre le morceau. Rien de cela n'est un
# fichier — ce sont des inscriptions dans la base de registres, qu'il faut poser et
# surtout savoir retirer. D'où un installeur, et d'où `Spectre.iss` qui le décrit.
#
# ─────────────────────────────────────────────────────────────────────────────
# POURQUOI INNO SETUP, ET POURQUOI IL N'EST PAS DANS LE DÉPÔT
#
# Windows ne fournit rien pour fabriquer un installeur. Le SDK a de quoi *lire* un
# MSI, pas de quoi en écrire un ; WiX est un paquet .NET de plusieurs centaines de
# mégaoctets ; et écrire soi-même un programme qui décompresse et inscrit des clés
# serait réécrire, moins bien, ce que trente ans de logiciel libre ont déjà fait.
#
# Inno Setup s'installe **en mode portable dans `build\`**, ne touche à rien
# ailleurs, et s'en va avec le dossier. C'est exactement le régime d'ONNX Runtime :
# hors dépôt, récupéré par un script, absent sans que rien d'autre ne casse — voir
# `onnx.ps1`. Le dépôt ne porte donc que `Spectre.iss`, qui est du texte et qui se
# lit.
#
# ─────────────────────────────────────────────────────────────────────────────
# LA LISTE DES EXTENSIONS N'EST PAS ÉCRITE DEUX FOIS
#
# Les formats que l'installeur associe sont ceux que `DecodeurWindows.formats`
# déclare, et ce script va les y chercher pour en engendrer `build\formats.iss`.
# C'est le même principe que l'icône Windows tirée du `.icns` : **les deux ne
# peuvent pas diverger**, l'une étant faite de l'autre. Une liste recopiée à la main
# aurait fini par proposer d'ouvrir un format que le décodeur refuse — ce qui, du
# point de vue de l'utilisateur, est une application qui ne marche pas.
# ─────────────────────────────────────────────────────────────────────────────

param(
    [string]$Version = "1.0.0",
    [string]$InnoSetup = "6.7.3",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$racine = $PSScriptRoot
# L'atelier, parce que `logo.ps1` est appelé d'ici et qu'il lui faut `rc.exe`.
# `build.ps1` le pose aussi, mais il passe **après** : sans cette ligne, la
# ressource de version échoue sur « rc.exe n'est pas reconnu », et le message
# désigne l'icône alors que la cause est l'ordre des appels.
. (Join-Path $racine "atelier.ps1")
$build = Join-Path $racine "build"
$assemble = Join-Path $build "Spectre"
$outils = Join-Path $build "innosetup"
$architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

function Etape($titre) { Write-Host "`n=== $titre ===" }

# ── Ce qu'on empaquette ──────────────────────────────────────────────────────
#
# On appelle `build.ps1` plutôt que d'exiger qu'on y ait pensé — c'est ce que fait
# déjà `build.ps1` avec `logo.ps1`. L'épreuve du dossier propre est sautée ici :
# elle vient d'avoir lieu si le dossier a été refait, et l'installeur n'ajoute
# aucune bibliothèque.

Etape "Le dossier à empaqueter"
# La ressource d'abord, avec **ce** numéro de version : c'est elle qui le pose dans
# l'exécutable. Puis l'assemblage, sans condition — l'ordre est le point, et sauter
# la construction parce qu'un dossier existe déjà livrerait un exécutable qui
# annonce dans ses propriétés une version que l'installeur dément.
& (Join-Path $racine "logo.ps1") -Version $Version | Out-Null
& (Join-Path $racine "build.ps1")
if ($LASTEXITCODE -ne 0) { throw "L'assemblage a échoué." }
$poids = (Get-ChildItem $assemble -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("  {0} ({1:N1} Mo)" -f $assemble, ($poids / 1MB))

# ── Le compilateur d'installeurs ─────────────────────────────────────────────

Etape "Inno Setup"
$marque = Join-Path $outils "version.txt"
$aJour = (Test-Path (Join-Path $outils "ISCC.exe")) -and (Test-Path $marque) -and
         ((Get-Content $marque -Raw).Trim() -eq $InnoSetup)
if ($aJour -and -not $Force) {
    Write-Host "  $InnoSetup est déjà là ($outils)"
} else {
    $archive = Join-Path $env:TEMP "innosetup-$InnoSetup.exe"
    $adresse = "https://github.com/jrsoftware/issrc/releases/download/" +
               ("is-{0}/innosetup-{1}.exe" -f ($InnoSetup -replace '\.', '_'), $InnoSetup)
    if (-not (Test-Path $archive)) {
        Write-Host "  téléchargement d'Inno Setup $InnoSetup…"
        # Même raison que dans `onnx.ps1` : la barre de progression d'
        # `Invoke-WebRequest` divise son débit par dix, ce qui est documenté et
        # surprend chaque fois.
        $avant = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        try { Invoke-WebRequest $adresse -OutFile $archive -TimeoutSec 900 }
        finally { $ProgressPreference = $avant }
    }
    # `/PORTABLE=1` : rien dans la base de registres, rien au menu Démarrer, rien
    # dans « Applications installées ». Le compilateur vit dans `build\` et s'en va
    # avec lui — c'est ce qui permet de fabriquer un installeur sans en subir un.
    Remove-Item -Recurse -Force $outils -ErrorAction SilentlyContinue
    $pose = Start-Process -FilePath $archive -Wait -PassThru -ArgumentList `
        "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /PORTABLE=1 /CURRENTUSER /DIR=`"$outils`""
    if ($pose.ExitCode -ne 0 -or -not (Test-Path (Join-Path $outils "ISCC.exe"))) {
        throw "Inno Setup ne s'est pas posé dans $outils (code $($pose.ExitCode))."
    }
    Set-Content -Path $marque -Value $InnoSetup -Encoding utf8 -NoNewline
    Remove-Item $archive -ErrorAction SilentlyContinue
    Write-Host "  $InnoSetup → $outils"
}

# ── Les extensions, prises là où le décodeur les déclare ─────────────────────

Etape "Les formats"
$plateforme = Join-Path $racine "Sources\SpectreWin\Plateforme.swift"
$texte = Get-Content $plateforme -Raw -Encoding UTF8
if ($texte -notmatch 'static var formats:\s*\[String\]\s*\{\s*\r?\n\s*\[([^\]]*)\]') {
    throw "La liste des formats est introuvable dans $plateforme — a-t-elle changé de forme ?"
}
$formats = [regex]::Matches($matches[1], '"([a-z0-9]+)"') |
           ForEach-Object { $_.Groups[1].Value }
if ($formats.Count -lt 2) { throw "La liste des formats paraît vide." }

# `mp4` est dans « Ouvrir avec » et hors de la case à cocher : Media Foundation sait
# en tirer le son et Spectre l'ouvre volontiers, mais c'est d'abord un conteneur
# vidéo. Une case qui dit « fichiers audio » n'a pas à emporter la vidéothèque de
# qui la coche.
$pasAudio = @("mp4")
$audio = $formats | Where-Object { $_ -notin $pasAudio }
Write-Host ("  « ouvrir avec » : {0}" -f ($formats -join ", "))
Write-Host ("  la case à cocher : {0}" -f ($audio -join ", "))

$lignes = @(
    "; Engendré par paquet.ps1 — ne pas modifier à la main.",
    "; La liste vient de DecodeurWindows.formats, dans Sources/SpectreWin/Plateforme.swift.",
    ""
)
foreach ($ext in $formats) {
    $lignes += "; ── .$ext"
    # Ce que le système lit pour savoir quoi proposer dans « Ouvrir avec ».
    $lignes += "Root: HKA; Subkey: ""Software\Classes\Applications\{#Executable}\SupportedTypes""; " +
               "ValueType: string; ValueName: "".$ext""; ValueData: """""
    $lignes += "Root: HKA; Subkey: ""Software\Classes\.$ext\OpenWithProgids""; " +
               "ValueType: string; ValueName: ""{#ProgId}""; ValueData: """"; Flags: uninsdeletevalue"
    if ($ext -in $audio) {
        # Ce que Paramètres → Applications par défaut affiche comme proposition.
        $lignes += "Root: HKA; Subkey: ""Software\{#Application}\Capabilities\FileAssociations""; " +
                   "ValueType: string; ValueName: "".$ext""; ValueData: ""{#ProgId}"""
        # L'association classique, et **seulement** sous HKEY_CURRENT_USER : voir la
        # note en tête de Spectre.iss. Écrire un défaut dans HKEY_LOCAL_MACHINE
        # écraserait celui du système sans que la désinstallation le rende.
        $lignes += "Root: HKCU; Subkey: ""Software\Classes\.$ext""; ValueType: string; " +
                   "ValueName: """"; ValueData: ""{#ProgId}""; Tasks: associer; Flags: uninsdeletevalue"
    }
    $lignes += ""
}
$engendre = Join-Path $build "formats.iss"
# La marque d'ordre est écrite à la main, et ce n'est pas de la coquetterie : Inno
# Setup ne tient un fichier pour de l'UTF-8 que s'il la porte, et sans elle les
# accents des commentaires ci-dessus le font échouer. `Set-Content -Encoding utf8`
# la pose sous Windows PowerShell et **ne la pose pas** sous PowerShell 7 : un
# coureur d'intégration continue qui appelle `pwsh` casserait donc la compilation,
# pour une différence qu'aucun message n'annonce.
[IO.File]::WriteAllText($engendre, ($lignes -join "`r`n") + "`r`n",
                        (New-Object Text.UTF8Encoding($true)))
Write-Host "  → $engendre"

# ── La compilation ───────────────────────────────────────────────────────────

Etape "Compilation"
$iss = Join-Path $racine "Spectre.iss"
$journal = & (Join-Path $outils "ISCC.exe") `
    "/DVersion=$Version" "/DArch=$architecture" `
    "/DSource=build\Spectre" "/DSortie=build" $iss 2>&1 | ForEach-Object { "$_" }
$compile = $LASTEXITCODE -eq 0
if (-not $compile) {
    $journal | ForEach-Object { Write-Host "  $_" }
    throw "ISCC a échoué."
}

$installeur = Join-Path $build "Spectre-$Version-$architecture-installeur.exe"
if (-not (Test-Path $installeur)) { throw "$installeur n'a pas été produit." }
Write-Host ("  → {0} ({1:N1} Mo)" -f $installeur, ((Get-Item $installeur).Length / 1MB))

# ── Et l'archive, pour qui ne veut rien inscrire ─────────────────────────────
#
# Le même dossier, sans installeur : il se suffit à lui-même, et c'est ce qu'on
# donne à qui veut essayer sans que rien ne s'inscrive dans la base de registres.
# Livrée à côté de l'installeur, sous le même numéro de version, pour qu'on ne
# puisse pas se tromper sur ce qu'on télécharge.

Etape "L'archive"
$archiveZip = Join-Path $build "Spectre-$Version-$architecture.zip"
Remove-Item $archiveZip -ErrorAction SilentlyContinue
Compress-Archive -Path $assemble -DestinationPath $archiveZip
Write-Host ("  → {0} ({1:N1} Mo)" -f $archiveZip, ((Get-Item $archiveZip).Length / 1MB))

Write-Host ""
Write-Host "L'installeur et l'archive sont dans build\."
Write-Host "Il n'est signé par personne : Windows SmartScreen le dira au premier"
Write-Host "lancement, et il faut passer par « Informations complémentaires »."
