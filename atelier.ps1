# L'environnement de construction, posé une fois pour tous les scripts.
#
#     . .\atelier.ps1
#
# Dot-sourcé — le point suivi d'un espace — sans quoi il poserait ses variables dans
# une portée qui disparaît en rendant la main.
#
# ─────────────────────────────────────────────────────────────────────────────
# TROIS CHOSES À POSER, ET PAS DEUX
#
# 1. **L'environnement de MSVC.** Swift n'a pas d'éditeur de liens à lui et emprunte
#    celui de Visual Studio, avec les bibliothèques du SDK Windows.
# 2. **`SDKROOT`**, qui désigne la bibliothèque standard de Swift.
# 3. **Le chemin des bibliothèques d'exécution.** Sans lui, `swift.exe` s'arrête sur
#    `0xC0000135` — DLL introuvable — **sans écrire un mot**. C'est le premier piège
#    de l'étape 0 du portage, et il revient à chaque fois qu'on ouvre un terminal
#    neuf.
#
# `VsDevCmd.bat` est un fichier de commandes : il ne peut pas modifier notre
# environnement. On le fait donc s'imprimer, et on relit ce qu'il a dit.
# ─────────────────────────────────────────────────────────────────────────────

# ── 1 et 2. Swift, là où l'installeur le pose ────────────────────────────────
#
# Sur une machine de développement, c'est ce chemin-là et pas un autre. Sur un
# coureur d'intégration continue, la chaîne est posée par une action qui a déjà
# rempli le `PATH` et `SDKROOT` : on ne touche alors à rien, et le repli plus bas
# retrouvera les bibliothèques d'exécution en les cherchant.
$swift = "$env:LOCALAPPDATA\Programs\Swift"
$devant = ""
if (Test-Path "$swift\Toolchains") {
    $versionDeSwift = (Get-ChildItem "$swift\Toolchains" -Directory | Sort-Object Name |
                       Select-Object -Last 1).Name
    # Le dossier des exécutions porte la version sans son suffixe : « 6.3.3 » là où
    # la chaîne s'appelle « 6.3.3+Asserts ».
    $versionCourte = $versionDeSwift -replace '\+.*$', ''
    $executions = "$swift\Runtimes\$versionCourte\usr\bin"
    $devant = "$executions;$swift\Toolchains\$versionDeSwift\usr\bin"

    $env:SDKROOT = "$swift\Platforms\$versionCourte\Windows.platform\Developer\SDKs\Windows.sdk"
    $env:PATH = "$devant;$env:PATH"
}

# ── L'environnement de MSVC ──────────────────────────────────────────────────
#
# `vswhere` plutôt que deux chemins écrits à la main : il est livré avec le
# programme d'installation de Visual Studio, il est toujours au même endroit, et il
# connaît les éditions qu'on n'a pas ici — Enterprise, notamment, qui est celle des
# coureurs de GitHub. Deux chemins codés en dur faisaient échouer l'intégration
# continue sur « VsDevCmd.bat introuvable », ce qui désigne l'atelier plutôt que la
# cause.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsdev = $null
if (Test-Path $vswhere) {
    $ou = & $vswhere -latest -products * `
                     -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                     -property installationPath 2>$null | Select-Object -First 1
    if ($ou) { $vsdev = Join-Path $ou "Common7\Tools\VsDevCmd.bat" }
}
if (-not $vsdev -or -not (Test-Path $vsdev)) {
    foreach ($essai in @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat")) {
        if (Test-Path $essai) { $vsdev = $essai; break }
    }
}
if (-not $vsdev -or -not (Test-Path $vsdev)) {
    throw "VsDevCmd.bat introuvable — Visual Studio Build Tools 2022 est nécessaire."
}

$architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
cmd /c "call `"$vsdev`" -arch=$architecture -host_arch=$architecture >nul 2>nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        # `SDKROOT` est à nous et ne doit pas être écrasé : Visual Studio en pose un
        # qui désigne autre chose.
        if ($matches[1] -notin @('SDKROOT')) {
            Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue
        }
    }
}
# `set` ci-dessus a écrasé le PATH avec celui de MSVC : on remet Swift devant.
if ($devant) { $env:PATH = "$devant;$env:PATH" }

# ── 3. Le chemin des bibliothèques d'exécution ───────────────────────────────
#
# `build.ps1` en a besoin : c'est là qu'il prend les seize DLL qui voyagent avec
# l'application. Il se déduit de la disposition de l'installeur quand c'est elle
# qu'on a ; sinon on le **cherche**, en demandant au `PATH` qui porte `swiftCore.dll`.
#
# Cette recherche n'est pas un raffinement : une chaîne posée autrement — par une
# action d'intégration continue, par exemple — range ses exécutions ailleurs, et une
# liste de DLL bâtie sur un dossier vide ne se voit pas. Elle produit un paquet qui
# s'assemble, qui s'archive, et qui refuse de s'ouvrir sur `0xC0000135` chez le
# premier qui le télécharge.
if (-not $executions -or -not (Test-Path (Join-Path $executions "swiftCore.dll"))) {
    $executions = ($env:PATH -split ';' | Where-Object {
        $_ -and (Test-Path (Join-Path $_ "swiftCore.dll"))
    } | Select-Object -First 1)
}
if (-not $executions) {
    throw "Les bibliothèques d'exécution de Swift sont introuvables — swiftCore.dll n'est nulle part sur le PATH."
}

# ── Lancer l'application, et attendre qu'elle ait fini ────────────────────────
#
# `Spectre.exe` est lié en sous-système « fenêtre » — c'est ce qui empêche Windows
# d'ouvrir une console noire à côté d'elle. **Un shell n'attend pas un programme de
# ce sous-système** : `& Spectre.exe … --photo image.ppm` rend la main en dix
# millisecondes, `$LASTEXITCODE` ne dit rien de l'application, et la photographie
# qu'on allait relire n'existe pas encore. Le contrôle passe alors au vert sur un
# fichier qui sera écrit quinze secondes plus tard — ou jamais, le processus
# orphelin mourant avec le shell qui l'a lancé.
#
# La redirection du shell ne traverse pas davantage : rien n'est capturé. Il faut
# donc dire l'attente et la sortie explicitement, ce que fait `Lancer`.
function Lancer {
    param([string]$Exe, [string[]]$Arguments)

    # Les arguments passent en une seule chaîne : `Start-Process` ne cite pas les
    # éléments d'un tableau, et un chemin à espaces s'y couperait en deux.
    $ligne = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '

    $marque = [guid]::NewGuid().ToString('N')
    $fluxSortie = Join-Path $env:TEMP "spectre-sortie-$marque.txt"
    $fluxErreur = Join-Path $env:TEMP "spectre-erreur-$marque.txt"
    $processus = Start-Process -FilePath $Exe -ArgumentList $ligne -Wait -PassThru `
                               -NoNewWindow -RedirectStandardOutput $fluxSortie `
                               -RedirectStandardError $fluxErreur

    # `-Encoding UTF8` : l'application écrit de l'UTF-8, et `Get-Content` lit dans
    # la page de codes du système. Sans quoi « 1200×700 » se lit « 1200Ã—700 », et
    # une expression régulière qui cherche une flèche ne la trouve plus.
    $lignes = @()
    foreach ($flux in @($fluxSortie, $fluxErreur)) {
        if (Test-Path $flux) { $lignes += @(Get-Content $flux -Encoding UTF8) }
        Remove-Item $flux -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ Code = $processus.ExitCode; Sortie = $lignes }
}
