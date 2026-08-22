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

$swift = "$env:LOCALAPPDATA\Programs\Swift"
$versionDeSwift = (Get-ChildItem "$swift\Toolchains" -Directory | Sort-Object Name |
                   Select-Object -Last 1).Name
# Le dossier des exécutions porte la version sans son suffixe : « 6.3.3 » là où la
# chaîne s'appelle « 6.3.3+Asserts ».
$versionCourte = $versionDeSwift -replace '\+.*$', ''
$executions = "$swift\Runtimes\$versionCourte\usr\bin"

$env:SDKROOT = "$swift\Platforms\$versionCourte\Windows.platform\Developer\SDKs\Windows.sdk"
$env:PATH = "$executions;$swift\Toolchains\$versionDeSwift\usr\bin;$env:PATH"

$vsdev = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path $vsdev)) {
    $vsdev = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
}
if (-not (Test-Path $vsdev)) { throw "VsDevCmd.bat introuvable — Visual Studio Build Tools 2022 est nécessaire." }

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
$env:PATH = "$executions;$swift\Toolchains\$versionDeSwift\usr\bin;$env:PATH"
