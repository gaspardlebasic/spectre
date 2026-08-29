# L'épreuve complète, sous Windows — le pendant d'`essai.sh`.
#
#     .\essai.ps1                 tout
#     .\essai.ps1 -Rapide         sans les harnais hors écran
#     .\essai.ps1 -Fluidite 20    et un relevé de fluidité plus long
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE CE SCRIPT ÉPROUVE, ET POURQUOI IL EST NÉCESSAIRE
#
# `essai.sh` ouvre l'application par LaunchServices et photographie sa fenêtre à
# l'écran. Rien de tout cela n'existe ici, et il se trouve qu'on peut faire mieux :
# l'image est relue de la **chaîne d'échange elle-même**, donc rien ne peut la
# recouvrir, aucune autorisation n'est à demander, et l'épreuve tourne pendant
# qu'on travaille ailleurs.
#
# Comme sur le Mac, le morceau témoin est de la synthèse dont on connaît d'avance
# le tempo, la grille et la batterie : aucun fichier privé n'est nécessaire.
#
# **`SPECTRE_RANGEMENT` est posé sur un dossier neuf**, et ce n'est pas une
# précaution de style. Sans lui, l'épreuve écrirait dans les sessions de
# l'utilisateur — et, plus vicieux, elle *relirait* la sienne d'une fois sur
# l'autre : le relevé de fluidité fait défiler l'image, la session le retient, et
# la photographie suivante montre alors une vue décalée qu'aucune modification du
# code n'explique. Une demi-heure a été perdue là-dessus, pour une règle qui est
# écrite dans AGENTS.md depuis toujours.
# ─────────────────────────────────────────────────────────────────────────────

param(
    [switch]$Rapide,
    [double]$Fluidite = 10
)

# « Continue » et non « Stop » : PowerShell tient pour une erreur tout ce qu'un
# exécutable écrit sur la sortie d'erreur, et `swift build` s'y plaint à chaque fois
# de ne pas pouvoir poser le lien symbolique `.build\release` — Windows le refuse
# hors du mode développeur. Ce n'est pas un échec, et l'épreuve entière s'arrêterait
# dessus. Les vrais échecs se lisent dans `$LASTEXITCODE`, qu'on regarde.
$ErrorActionPreference = "Continue"
$racine = $PSScriptRoot
$echecs = 0

function Etape($titre) { Write-Host "`n=== $titre ===" }
function Verdict($nom, $ok, $detail) {
    if ($ok) { Write-Host "  ok    $nom — $detail" } else { Write-Host "  ECHEC $nom — $detail"; $script:echecs++ }
}

# ── L'environnement de construction ──────────────────────────────────────────
#
# Les trois choses à poser, et les raisons de chacune, sont dans `atelier.ps1` —
# `build.ps1` en a besoin des mêmes, et deux copies d'un environnement finissent par
# ne plus poser tout à fait la même chose.
. (Join-Path $racine "atelier.ps1")

# ── Un dossier à soi ─────────────────────────────────────────────────────────

$travail = Join-Path $env:TEMP "spectre-essai-$PID"
New-Item -ItemType Directory -Force -Path $travail | Out-Null
$env:SPECTRE_RANGEMENT = Join-Path $travail "rangement"
# Et rien ne part chez Sentry : `non` retire l'adresse. `RapportsCheck`, lui, se
# donne la sienne. Voir `Rapports.ouvrir`.
$env:SPECTRE_RAPPORTS = "non"
# Ni diaporama ni mise à jour, pour la même raison que sous macOS : le premier
# couvre toute la fenêtre qu'on photographie, et l'epreuve tourne dans un rangement
# neuf — donc chaque passage serait un premier lancement.
$env:SPECTRE_BIENVENUE = "non"
$env:SPECTRE_MAJ = "non"
New-Item -ItemType Directory -Force -Path $env:SPECTRE_RANGEMENT | Out-Null

Etape "Construction"
Push-Location $racine
try {
    $journal = swift build -c release 2>&1 | ForEach-Object { "$_" }
    $construit = $LASTEXITCODE -eq 0
    $journal | Where-Object { $_ -match ': error' } | ForEach-Object { Write-Host "  $_" }
    $bin = (swift build -c release --show-bin-path 2>$null | Select-Object -Last 1).Trim()
} finally { Pop-Location }
Verdict "tout compile" ($construit -and (Test-Path "$bin\SpectreWindows.exe")) $bin
if (-not $construit) { Write-Host "`n$echecs vérification(s) en échec."; exit 1 }

# ── Les harnais hors écran ───────────────────────────────────────────────────

if (-not $Rapide) {
    Etape "Les harnais hors écran"
    # Le réseau du dépôt, quand il a été fabriqué : sans lui, `PistesCheck` éprouve
    # l'ossature de la séparation et saute la séparation elle-même. C'est ce que fait
    # déjà `check.sh` avec `SeparationCheck`.
    $modele = Join-Path $racine "Resources\htdemucs.onnx"
    if (Test-Path $modele) { $env:SPECTRE_MODELE = $modele }
    # Les rapports de panne, avec un receveur sur la boucle locale : c'est le seul
    # contrôle qui traverse vraiment `URLSession`, et sous Windows elle vient d'un
    # module à part dont il faut aussi que la DLL soit là. Voir `Tools/Receveur`.
    $recu = Join-Path $travail "receveur"
    Remove-Item -Recurse -Force $recu -ErrorAction SilentlyContinue
    $receveur = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $racine "Tools\Receveur\receveur.ps1"), "-Dossier", $recu)
    foreach ($essai in 1..40) {
        if (Test-Path (Join-Path $recu "port")) { break }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path (Join-Path $recu "port")) {
        $port = Get-Content (Join-Path $recu "port")
        $env:SPECTRE_RECEVEUR = "http://cle-dessai@127.0.0.1:$port/1"
    }

    $harnais = @("RapportsCheck", "DSPCheck", "WAVCheck", "SessionCheck", "AnalysisCheck",
                 "PercussionCheck", "HarmonyCheck", "FilterCheck", "ChainCheck",
                 "GaplessCheck", "EtirementCheck", "RenduCheck", "DecodeCheck",
                 "SortieCheck", "PistesCheck")
    foreach ($h in $harnais) {
        Push-Location $travail
        try { $sortie = & "$bin\$h.exe" 2>&1 } finally { Pop-Location }
        $ok = $LASTEXITCODE -eq 0
        $derniere = ($sortie | Select-Object -Last 1)
        Verdict $h $ok $derniere
        if (-not $ok) { $sortie | ForEach-Object { Write-Host "        $_" } }
    }

    # Et l'on regarde ce qui est arrivé de l'autre côté, plutôt que de croire le
    # harnais sur parole.
    if ($receveur) {
        $arrivee = Join-Path $recu "recu.txt"
        Verdict "le receveur a bien reçu une enveloppe" `
                ((Test-Path $arrivee) -and (Get-Content $arrivee -Raw) -match "spectre@")
        Stop-Process -Id $receveur.Id -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\SPECTRE_RECEVEUR -ErrorAction SilentlyContinue
    }
}

# ── Le morceau témoin ────────────────────────────────────────────────────────

Etape "Le morceau témoin"
$temoin = Join-Path $travail "temoin.wav"
& "$bin\Temoin.exe" $temoin | Out-Null
Verdict "le témoin est fabriqué" (Test-Path $temoin) `
    ("{0:N0} octets" -f (Get-Item $temoin).Length)

# ── La ligne de commande ─────────────────────────────────────────────────────

Etape "La ligne de commande"
$cpu = Join-Path $travail "cpu.ppm"
# `--reattribution` : c'est le réglage de l'application, et sans lui les deux
# rendus ne comparent pas la même matrice.
$sortie = & "$bin\SpectreCLI.exe" $temoin $cpu --taille 1200x700 --reattribution 2>&1
$tempo = ($sortie | Select-String "tempo : (\d+) BPM").Matches.Groups[1].Value
Verdict "le tempo relevé est celui du témoin" ($tempo -eq "120") "$tempo BPM"

# ── La fenêtre, et l'image dedans ────────────────────────────────────────────

Etape "La fenêtre"
# Deux photographies, et il en faut deux.
#
# Celle qu'on regarde porte l'interface entière — réglette, grille, accords,
# batterie, barre. Celle qu'on **mesure** ne la porte pas : la surimpression couvre
# une partie de l'image, et `ImageCheck` trouverait un désaccord partout où passe un
# trait de grille. Les deux passent par le même chemin de fenêtre.
$gpu = Join-Path $travail "fenetre.ppm"
$nu = Join-Path $travail "fenetre-nue.ppm"
$reglages = Join-Path $travail "reglages.ppm"
#
# `Lancer` et non `&` : l'application est du sous-système « fenêtre », qu'un shell
# n'attend pas — la ligne suivante relirait une photographie pas encore écrite.
# Voir `atelier.ps1`.
Lancer "$bin\SpectreWindows.exe" @($temoin, "--photo", $gpu) | Out-Null
Lancer "$bin\SpectreWindows.exe" @($temoin, "--photo", $nu, "--sans-habillage") | Out-Null
# Et une troisième, panneau ouvert. Elle ne se mesure pas — un panneau de réglages
# n'a aucun nombre à rendre — mais c'est le seul moyen d'en juger l'allure sans
# être devant la machine, et c'est sur l'allure qu'il se juge.
Lancer "$bin\SpectreWindows.exe" @($temoin, "--photo", $reglages, "--reglages") | Out-Null
Verdict "la fenêtre s'ouvre et rend une image" (Test-Path $gpu) $gpu
Verdict "le panneau des réglages se dessine" (Test-Path $reglages) $reglages

if (Test-Path $nu) {
    $comparaison = & "$bin\ImageCheck.exe" $nu $cpu 2>&1
    $comparaison | ForEach-Object { Write-Host "    $_" }
    # Le désaccord restant tient à ce que le GPU interpole et que le processeur
    # prend le plus proche voisin : sur une synthèse dont les raies font une ligne
    # de large, c'est le pire cas. Ce qu'on exige, c'est l'orientation et le
    # cadrage — les trois premiers contrôles d'`ImageCheck`.
    $lignes = [double](($comparaison | Select-String "profils de lignes\s+: \+?([\d.]+)").Matches.Groups[1].Value)
    $colonnes = [double](($comparaison | Select-String "profils de colonnes\s+: \+?([\d.]+)").Matches.Groups[1].Value)
    Verdict "l'image est à l'endroit, et le temps va vers la droite" `
        ($lignes -gt 0.9 -and $colonnes -gt 0.9) `
        ("lignes {0:N3}, colonnes {1:N3}" -f $lignes, $colonnes)
}

# ── La fluidité ──────────────────────────────────────────────────────────────

if ($Fluidite -gt 0) {
    Etape "La fluidité"
    $releve = (Lancer "$bin\SpectreWindows.exe" @($temoin, "--fluidite", "$Fluidite")).Sortie
    $releve | Where-Object { $_ -notmatch '^Spectre :' } | ForEach-Object { Write-Host "    $_" }
    # ── Ce qu'on exige ici, et ce qu'on refuse d'exiger ──────────────────────
    #
    # **On ne fait pas échouer l'épreuve sur ces nombres**, et c'est délibéré.
    # Une machine virtuelle sur GPU paravirtualisé ne peut pas dire si le
    # défilement est doux : le même relevé donne 0,4 % d'images manquées sur une
    # machine au repos et 45 % dix secondes après une construction, sans qu'une
    # ligne du code ait changé. Un seuil poserait donc une épreuve qui échoue au
    # hasard, et une épreuve qui échoue au hasard finit par ne plus être lue.
    #
    # Ce qui est exigé, c'est que **l'instrument ait fonctionné** : qu'il y ait eu
    # des images, et qu'elles aient été montrées. Les nombres, eux, servent à
    # comparer — d'une version à l'autre sur la même machine, et de cette machine
    # à du matériel réel.
    $images = ($releve | Select-String "(\d+) images mesurées").Matches.Groups[1].Value
    $cachees = $releve | Select-String "images\(s\)? présentées fenêtre cachée"
    Verdict "le relevé a bien eu lieu" `
        ([int]$images -gt 100 -and -not $cachees) `
        "$images images, fenêtre visible"
}

# ── L'image, pour l'œil ──────────────────────────────────────────────────────

Write-Host "`nÀ regarder : $gpu"
Write-Host "  (le spectrogramme du témoin : huit blocs d'accords, les raies"
Write-Host "   colorées par classe de hauteur, la batterie en traits verticaux)"
Write-Host "Et : $reglages"
Write-Host "  (le panneau des réglages, ouvert sur « Détection du tempo »)"

Write-Host ""
if ($echecs -eq 0) {
    Write-Host "Tout est bon."
    exit 0
} else {
    Write-Host "$echecs vérification(s) en échec."
    exit 1
}
