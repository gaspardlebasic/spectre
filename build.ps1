# Assemble Spectre pour Windows — le pendant de `build.sh`.
#
#     .\build.ps1                 assemble build\Spectre
#     .\build.ps1 -Archive        et en fait un .zip
#     .\build.ps1 -SansEpreuve    sans l'épreuve du dossier propre
#     .\build.ps1 -SansFenetre    l'épreuve, mais par le rendu hors écran
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QU'ASSEMBLER VEUT DIRE ICI
#
# Sur le Mac, `build.sh` fabrique un paquet `.app` : un dossier dont la forme est
# décrite par le système, et que LaunchServices sait enregistrer. Windows n'a rien de
# tel — une application y est un exécutable et les bibliothèques qu'il lui faut, dans
# le même dossier.
#
# Ce qui compte est donc **la liste** : `SpectreWindows.exe` dépend de la
# bibliothèque standard de Swift, de Foundation, de dispatch et du runtime de Visual
# Studio, dont aucun n'est présent sur une machine qui n'a pas la chaîne de
# compilation. L'oublier ne donne pas une erreur lisible : Windows refuse d'ouvrir le
# programme sur `0xC0000135`, sans un mot. C'est le premier piège de l'étape 0 du
# portage, et c'est celui qu'une distribution ratée rejoue chez l'utilisateur.
#
# La liste n'est pas écrite à la main. `dumpbin /dependents` la donne, et l'on suit
# la chaîne de proche en proche jusqu'à ce que plus rien de nouveau n'apparaisse :
# ce qui se trouve dans le dossier des exécutions de Swift est copié, le reste — les
# DLL du système — est laissé où il est. Copier le dossier entier serait plus simple
# et ferait soixante mégaoctets au lieu de vingt-quatre, dont trente-six pour un ICU
# dont on ne se sert pas.
#
# **L'épreuve du dossier propre est le seul contrôle qui compte.** Le programme est
# lancé depuis un dossier temporaire, avec un `PATH` d'où toute trace de Swift a été
# retirée : c'est la machine de quelqu'un d'autre, autant qu'on puisse la simuler
# sans en avoir une. Sans elle, on ne découvre l'oubli qu'au moment où quelqu'un
# essaie.
# ─────────────────────────────────────────────────────────────────────────────

param(
    [switch]$Archive,
    [switch]$SansEpreuve,
    [switch]$SansFenetre
)

$ErrorActionPreference = "Continue"
$racine = $PSScriptRoot
. (Join-Path $racine "atelier.ps1")

$cible = Join-Path $racine "build\Spectre"
$architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

function Etape($titre) { Write-Host "`n=== $titre ===" }

# ── L'icône, si elle a été fabriquée ─────────────────────────────────────────
#
# `logo.ps1` produit `build\spectre.res`, que `Package.swift` lie à l'exécutable
# quand il le trouve. On l'appelle ici plutôt que d'exiger qu'on y ait pensé : sans
# icône, l'application porte celle que Windows donne à ce qui n'en a pas, et cela se
# voit dans la barre des tâches avant tout le reste.

Etape "L'icône"
if (-not (Test-Path (Join-Path $racine "build\spectre.res"))) {
    & (Join-Path $racine "logo.ps1") | Out-Null
}
if (Test-Path (Join-Path $racine "build\spectre.res")) {
    Write-Host "  build\spectre.res"
} else {
    Write-Host "  (pas d'icône — l'exécutable portera celle de Windows)"
}

# ── La construction ──────────────────────────────────────────────────────────

Etape "Construction"
Push-Location $racine
try {
    # ── La ressource ne fait pas relier ────────────────────────────────────────
    #
    # SwiftPM ne connaît le `.res` que comme un drapeau passé à l'éditeur de liens :
    # il ne le compte pas parmi les entrées de la cible, et ne voit donc pas qu'il a
    # changé. Une icône refaite, ou un numéro de version neuf, restent alors sans
    # effet sur un exécutable que rien n'oblige à être relié — et l'on livre un
    # fichier dont les propriétés annoncent la version précédente.
    #
    # Effacer l'exécutable est ce qui force la seule étape qui manque. Cela coûte une
    # édition de liens, quelques secondes, et seulement quand la ressource est la
    # plus fraîche des deux.
    $res = Join-Path $racine "build\spectre.res"
    $binAvant = (swift build -c release --show-bin-path 2>$null | Select-Object -Last 1)
    if ($binAvant) {
        $exe = Join-Path $binAvant.Trim() "SpectreWindows.exe"
        if ((Test-Path $res) -and (Test-Path $exe) -and
            ((Get-Item $res).LastWriteTime -gt (Get-Item $exe).LastWriteTime)) {
            Remove-Item $exe -Force
            Write-Host "  (la ressource a changé — on relie)"
        }
    }

    $journal = swift build -c release 2>&1 | ForEach-Object { "$_" }
    $construit = $LASTEXITCODE -eq 0
    $journal | Where-Object { $_ -match ': error' } | ForEach-Object { Write-Host "  $_" }
    $bin = (swift build -c release --show-bin-path 2>$null | Select-Object -Last 1).Trim()
} finally { Pop-Location }
if (-not $construit) { Write-Host "`nLa construction a échoué."; exit 1 }
Write-Host "  $bin"

# ── L'assemblage ─────────────────────────────────────────────────────────────

Etape "Assemblage"
Remove-Item -Recurse -Force $cible -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $cible | Out-Null

Copy-Item (Join-Path $bin "SpectreWindows.exe") (Join-Path $cible "Spectre.exe")

# La fermeture des dépendances, de proche en proche. Ce que `dumpbin` nomme et que le
# dossier des exécutions de Swift porte est à nous ; le reste appartient à Windows.
$aVoir = New-Object System.Collections.Queue
$aVoir.Enqueue((Join-Path $cible "Spectre.exe"))
$vues = New-Object System.Collections.Generic.HashSet[string]
$copiees = 0
while ($aVoir.Count -gt 0) {
    $fichier = $aVoir.Dequeue()
    $dependances = (dumpbin /dependents $fichier 2>$null) |
        Where-Object { $_ -match '^\s+\S+\.dll$' } | ForEach-Object { $_.Trim() }
    foreach ($nom in $dependances) {
        if (-not $vues.Add($nom.ToLower())) { continue }
        $source = Join-Path $executions $nom
        if (-not (Test-Path $source)) { continue }        # une DLL de Windows
        $pose = Join-Path $cible $nom
        Copy-Item $source $pose -Force
        $copiees++
        $aVoir.Enqueue($pose)
    }
}
Write-Host ("  {0} bibliothèques d'exécution, {1:N1} Mo" -f $copiees,
            ((Get-ChildItem $cible -File | Measure-Object Length -Sum).Sum / 1MB))

# ONNX Runtime, s'il est installé. Il n'est pas dans la fermeture ci-dessus : il est
# chargé à l'exécution par `LoadLibraryW`, précisément pour que l'application
# s'ouvre quand il n'est pas là.
$onnx = Join-Path $racine "build\onnxruntime\$architecture"
if (Test-Path (Join-Path $onnx "onnxruntime.dll")) {
    foreach ($dll in @("onnxruntime.dll", "onnxruntime_providers_shared.dll")) {
        if (Test-Path (Join-Path $onnx $dll)) { Copy-Item (Join-Path $onnx $dll) $cible -Force }
    }
    Write-Host "  ONNX Runtime"
} else {
    Write-Host "  (sans ONNX Runtime — lancer .\onnx.ps1 pour la séparation des pistes)"
}

# Les poids de Demucs, s'ils ont été fabriqués. Ils ne sont pas dans le dépôt : leur
# licence ne permet pas de les rediffuser, et cette copie-ci reste locale.
$poids = Join-Path $racine "Resources\htdemucs.onnx"
if (Test-Path $poids) {
    Copy-Item $poids $cible -Force
    Write-Host ("  htdemucs.onnx ({0:N0} Mo)" -f ((Get-Item $poids).Length / 1MB))
} else {
    Write-Host "  (sans les poids de Demucs — voir modele.sh)"
}

# Les deux captures du diaporama du premier lancement, a cote de l'executable, ou
# `Ressources.fichier` les cherche. Ce sont les memes fichiers que ceux du README ;
# renommes en passant, parce que le nom traverse un installeur et deux systemes de
# fichiers et que ce n'est pas la qu'on veut decouvrir une difference de
# normalisation Unicode.
$captures = @{
    "faire boucler une section au ralenti.png" = "diapo-boucle.png"
    "s" + [char]0xE9 + "paration des pistes.png" = "diapo-pistes.png"
}
foreach ($nom in $captures.Keys) {
    $source = Join-Path $racine (Join-Path "Resources\Captures" $nom)
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source (Join-Path $cible $captures[$nom]) -Force
    }
}

Copy-Item (Join-Path $racine "LICENSE") (Join-Path $cible "LICENSE.txt") -Force
Copy-Item (Join-Path $racine "NOTICE.md") $cible -Force

$total = (Get-ChildItem $cible -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("  → {0} ({1:N1} Mo)" -f $cible, ($total / 1MB))

# ── L'épreuve du dossier propre ──────────────────────────────────────────────

if (-not $SansEpreuve) {
    Etape "L'épreuve du dossier propre"
    $travail = Join-Path $env:TEMP "spectre-distribution-$PID"
    Remove-Item -Recurse -Force $travail -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $travail | Out-Null
    Copy-Item $cible (Join-Path $travail "Spectre") -Recurse -Force

    & "$bin\Temoin.exe" (Join-Path $travail "temoin.wav") | Out-Null

    # Un `PATH` d'où Swift et Visual Studio ont disparu, et un rangement neuf : ce
    # que l'application trouve, elle l'a apporté avec elle.
    $propre = ($env:PATH -split ';' | Where-Object {
        $_ -and $_ -notmatch 'Programs\\Swift' -and $_ -notmatch 'Microsoft Visual Studio' `
             -and $_ -notmatch 'Windows Kits'
    }) -join ';'

    # `Start-Process -Wait` et non `&` : l'application est du sous-système
    # « fenêtre » — c'est ce qui lui évite une console noire au double-clic — et un
    # shell ne l'attend pas. `&` rendrait la main en dix millisecondes, et
    # l'épreuve conclurait à l'échec sur une image pas encore écrite. `atelier.ps1`
    # a la fonction qui fait cela, mais elle n'est pas ici : ce processus est neuf
    # et ne doit rien connaître de l'atelier.
    # La sortie de l'application passe par des fichiers, et pas par le tube du
    # shell : un programme du sous-système « fenêtre » lancé par `Start-Process`
    # n'écrit dans aucun des deux à moins qu'on ne le lui dise. Sans ces deux
    # redirections, l'épreuve rate en silence et l'on ne voit pas pourquoi — ce qui
    # est exactement le contraire de ce qu'elle est là pour faire.
    #
    # ── `--photo`, ou `--rendu` là où il n'y a pas de bureau ───────────────────
    #
    # `--photo` ouvre une vraie fenêtre et relit l'image de sa chaîne d'échange :
    # c'est le chemin complet, et c'est celui qu'on veut. Il demande une session
    # graphique, que **n'a pas un coureur d'intégration continue** — son travail
    # tourne en session 0, sans bureau, et DXGI meurt d'une violation d'accès en
    # tentant d'attacher une chaîne d'échange à une fenêtre qui n'est sur aucun
    # écran. Ce n'est pas une panne de Spectre : sur la même machine, `RenduCheck`
    # fait passer toute la chaîne Direct3D hors écran sans broncher.
    #
    # `-SansFenetre` prend alors `--rendu`, qui dessine sans fenêtre. Ce que
    # l'épreuve est là pour dire — **l'application trouve-t-elle ses bibliothèques
    # hors de l'atelier ?** — se lit tout aussi bien : c'est le même exécutable et
    # les mêmes DLL. Ce qu'on y perd est la fenêtre, que la machine de
    # développement éprouve de toute façon à chaque `.\essai.ps1`. C'est la même
    # concession que `./essai.sh --sans-fenetre` sur le Mac, et pour la même raison.
    $sortie = Join-Path $travail "image.ppm"
    $commande = if ($SansFenetre) { "--rendu" } else { "--photo" }
    $script = @"
`$env:PATH = '$propre'
`$env:SPECTRE_RANGEMENT = '$travail\rangement'
`$p = Start-Process -FilePath '$travail\Spectre\Spectre.exe' ``
                   -ArgumentList '"$travail\temoin.wav" $commande "$sortie"' ``
                   -Wait -PassThru -NoNewWindow ``
                   -RedirectStandardOutput '$travail\dit.txt' ``
                   -RedirectStandardError '$travail\erreur.txt'
exit `$p.ExitCode
"@
    $fichierScript = Join-Path $travail "essai.ps1"
    Set-Content -Path $fichierScript -Value $script -Encoding utf8
    # Un processus **neuf** : notre propre environnement porte déjà tout ce qu'il
    # faut, et le retirer d'une variable ne le retire pas des DLL déjà chargées.
    $rapport = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fichierScript 2>&1)
    $code = $LASTEXITCODE
    foreach ($flux in @("$travail\dit.txt", "$travail\erreur.txt")) {
        if (Test-Path $flux) { $rapport += @(Get-Content $flux -Encoding UTF8) }
    }
    # L'image est relevée **avant** de faire le ménage : le dossier de travail la
    # porte, et l'effacer d'abord fait échouer l'épreuve sur son propre nettoyage.
    $imageFaite = Test-Path $sortie
    Remove-Item -Recurse -Force $travail -ErrorAction SilentlyContinue

    # ── Ce que l'épreuve distingue, et pourquoi ────────────────────────────────
    #
    # Elle est là pour une seule question : **l'application trouve-t-elle ses
    # bibliothèques hors de l'atelier ?** Quand la réponse est non, Windows arrête
    # le programme sur `0xC0000135` — DLL introuvable — ou sur `0xC0000139` — un
    # point d'entrée manquant — avant qu'une ligne de Swift ne s'exécute. C'est le
    # premier piège du portage, et c'est celui qu'une distribution ratée rejoue chez
    # l'utilisateur.
    #
    # Elle reste **stricte** : une image, ou un échec. Ce qui varie selon la
    # machine, c'est par quel chemin on la demande — voir `-SansFenetre` plus haut —
    # et non l'exigence.
    #
    # Le code de sortie est rapporté parce qu'il désigne le coupable sans qu'on ait
    # à chercher : `0xC0000135` est une DLL introuvable, `0xC0000139` un point
    # d'entrée manquant, `0xC0000005` un plantage. Sans lui, l'échec se lisait
    # « l'application ne tourne pas », suivi de rien, et l'on cherchait pendant une
    # heure du côté de la liste des bibliothèques.
    if ($imageFaite) {
        Write-Host "  ok    l'application tourne sans la chaîne de compilation"
        if ($SansFenetre) { Write-Host "        (par le rendu hors écran — pas de bureau ici)" }
    } else {
        Write-Host ("  ECHEC l'application ne tourne pas hors de l'atelier (code 0x{0:X8})" -f $code)
        $rapport | Where-Object { $_ } | ForEach-Object { Write-Host "        $_" }
        exit 1
    }
}

# ── L'archive ────────────────────────────────────────────────────────────────

if ($Archive) {
    Etape "Archive"
    $zip = Join-Path $racine "build\Spectre-$architecture.zip"
    Remove-Item $zip -ErrorAction SilentlyContinue
    Compress-Archive -Path $cible -DestinationPath $zip
    Write-Host ("  → {0} ({1:N1} Mo)" -f $zip, ((Get-Item $zip).Length / 1MB))
}

Write-Host ""
Write-Host "Spectre est assemblé dans build\Spectre."
