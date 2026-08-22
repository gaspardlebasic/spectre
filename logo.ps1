# Fabrique l'icône Windows — le pendant de `logo.sh`.
#
#     .\logo.ps1
#
# Produit `Resources\Spectre.ico`, versionné comme l'est `Resources\Spectre.icns`,
# puis `build\spectre.res` que `Package.swift` lie à l'exécutable quand il le trouve.
#
# ─────────────────────────────────────────────────────────────────────────────
# L'ICÔNE VIENT DU .ICNS, ET NON DU SVG
#
# `logo.sh` part de `Resources/icone.svg` et le fait rastériser par le système : sur
# le Mac, `NSImage` charge un SVG en vectoriel, si bien que chaque taille est dessinée
# à sa résolution propre. Rien sous Windows ne sait faire cela — ni WIC, ni Direct2D,
# ni GDI+ — et embarquer un moteur SVG pour une icône serait payer très cher un
# fichier de cent kilo-octets.
#
# On repart donc du `.icns`, qui est versionné et qui **porte déjà** un carré de
# 1024 points dessiné à cette résolution. Les tailles de l'icône Windows en sont
# réduites. C'est un tirage de plus, mais il part d'une image quatre fois plus grande
# que la plus grande dont Windows se sert : ce qu'on y perd ne se voit pas.
#
# L'effet de bord est une propriété qu'on veut : **les deux icônes ne peuvent pas
# diverger**, l'une étant faite de l'autre. Y compris la plaque arrondie de macOS,
# qui vient avec — une icône Windows serait normalement à fond perdu, mais avoir deux
# dessins pour la même application serait pire que d'avoir une marge.
# ─────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"
$racine = $PSScriptRoot
Add-Type -AssemblyName System.Drawing

$icns = Join-Path $racine "Resources\Spectre.icns"
if (-not (Test-Path $icns)) { throw "Resources\Spectre.icns est introuvable — voir logo.sh." }

# ── Extraire la plus grande image du .icns ───────────────────────────────────
#
# Le format est une suite de morceaux : quatre octets de type, quatre octets de
# taille en gros-boutien — **la taille comprend ces huit octets** — puis les données.
# Depuis Mac OS X 10.7, les grandes tailles y sont rangées en PNG tel quel.

$octets = [System.IO.File]::ReadAllBytes($icns)
function GrosBoutien($tableau, $i) {
    [int]$tableau[$i] * 16777216 + [int]$tableau[$i+1] * 65536 +
    [int]$tableau[$i+2] * 256 + [int]$tableau[$i+3]
}

$plusGrande = $null
$i = 8
while ($i + 8 -le $octets.Length) {
    $taille = GrosBoutien $octets ($i + 4)
    if ($taille -le 8) { break }
    # La signature PNG : les morceaux plus anciens sont des bitmaps compressés d'une
    # façon qui n'a plus cours, et qu'on n'a aucune raison de savoir lire.
    if ($octets[$i+8] -eq 0x89 -and $octets[$i+9] -eq 0x50) {
        $corps = New-Object byte[] ($taille - 8)
        [Array]::Copy($octets, $i + 8, $corps, 0, $taille - 8)
        $flux = New-Object System.IO.MemoryStream(, $corps)
        $image = [System.Drawing.Image]::FromStream($flux)
        if ($null -eq $plusGrande -or $image.Width -gt $plusGrande.Width) {
            if ($plusGrande) { $plusGrande.Dispose() }
            $plusGrande = $image
        } else { $image.Dispose() }
    }
    $i += $taille
}
if ($null -eq $plusGrande) { throw "aucune image PNG dans le .icns." }
Write-Host "source : $($plusGrande.Width)×$($plusGrande.Height)"

# ── Réduire, et assembler l'ICO ──────────────────────────────────────────────
#
# Les six tailles que Windows demande : 16 dans les listes, 32 dans la barre des
# tâches, 48 dans l'explorateur, et les grandes pour les affichages denses et la
# vignette de fichier.
#
# Chaque image est rangée **en PNG**, ce que le format ICO accepte depuis Vista.
# L'ancien chemin — un bitmap et son masque en un bit — pèserait quatre fois plus et
# n'apporterait rien : Windows 10 est le plus ancien que ce portage vise.

$tailles = @(16, 32, 48, 64, 128, 256)
$images = @()
foreach ($t in $tailles) {
    $reduite = New-Object System.Drawing.Bitmap($t, $t,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $dessin = [System.Drawing.Graphics]::FromImage($reduite)
    $dessin.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $dessin.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $dessin.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $dessin.DrawImage($plusGrande, (New-Object System.Drawing.Rectangle(0, 0, $t, $t)))
    $dessin.Dispose()
    $flux = New-Object System.IO.MemoryStream
    $reduite.Save($flux, [System.Drawing.Imaging.ImageFormat]::Png)
    $reduite.Dispose()
    $images += ,@($t, $flux.ToArray())
}
$plusGrande.Dispose()

$ico = New-Object System.IO.MemoryStream
$plume = New-Object System.IO.BinaryWriter($ico)
$plume.Write([UInt16]0)          # réservé
$plume.Write([UInt16]1)          # 1 = icône, 2 = curseur
$plume.Write([UInt16]$images.Count)

# Les données suivent le répertoire, dont chaque entrée fait seize octets.
$decalage = 6 + 16 * $images.Count
foreach ($entree in $images) {
    $t = $entree[0]; $donnees = $entree[1]
    # 256 s'écrit zéro : le champ ne fait qu'un octet, et c'est la convention.
    $plume.Write([byte]$(if ($t -ge 256) { 0 } else { $t }))
    $plume.Write([byte]$(if ($t -ge 256) { 0 } else { $t }))
    $plume.Write([byte]0)        # couleurs de la palette : aucune
    $plume.Write([byte]0)        # réservé
    $plume.Write([UInt16]1)      # plans
    $plume.Write([UInt16]32)     # bits par pixel
    $plume.Write([UInt32]$donnees.Length)
    $plume.Write([UInt32]$decalage)
    $decalage += $donnees.Length
}
foreach ($entree in $images) { $plume.Write($entree[1]) }
$plume.Flush()

$sortie = Join-Path $racine "Resources\Spectre.ico"
[System.IO.File]::WriteAllBytes($sortie, $ico.ToArray())
$plume.Dispose()
Write-Host ("→ {0} ({1} tailles, {2:N0} octets)" -f $sortie, $images.Count,
            (Get-Item $sortie).Length)

# Relue tout de suite, et à la plus petite taille : une entrée que Windows ne sait
# pas décoder ne se voit pas dans le fichier, elle se voit dans une barre des tâches
# vide. Autant l'apprendre ici.
$verif = New-Object System.Drawing.Icon($sortie, (New-Object System.Drawing.Size(16, 16)))
$petite = $verif.ToBitmap()
if ($petite.Width -ne 16) { throw "l'icône de 16 points ne se relit pas." }
$petite.Dispose(); $verif.Dispose()
Write-Host "  relue par Windows en 16×16"

# ── La ressource, pour que l'exécutable la porte ─────────────────────────────
#
# Un exécutable Windows porte son icône et son numéro de version dans ses ressources.
# `rc.exe` compile le script ci-dessous, et `Package.swift` donne le `.res` à
# l'éditeur de liens quand il le trouve — la même règle que pour ONNX Runtime :
# absent, il ne manque rien d'autre que l'icône.

$build = Join-Path $racine "build"
New-Item -ItemType Directory -Force -Path $build | Out-Null
$rc = Join-Path $build "spectre.rc"
$script = @"
#include <windows.h>

1 ICON "$($sortie -replace '\\', '\\')"

VS_VERSION_INFO VERSIONINFO
 FILEVERSION 1,0,0,0
 PRODUCTVERSION 1,0,0,0
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_APP
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040C04B0"
        BEGIN
            VALUE "FileDescription", "Spectre — transcrire de la musique a l'oreille"
            VALUE "FileVersion", "1.0.0.0"
            VALUE "InternalName", "Spectre"
            VALUE "OriginalFilename", "Spectre.exe"
            VALUE "ProductName", "Spectre"
            VALUE "ProductVersion", "1.0.0.0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x040C, 1200
    END
END
"@
Set-Content -Path $rc -Value $script -Encoding ascii

$res = Join-Path $build "spectre.res"
& rc.exe /nologo /fo $res $rc
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $res)) {
    throw "rc.exe a échoué — l'environnement de Visual Studio est-il posé ? (. .\atelier.ps1)"
}
Write-Host "→ $res (l'exécutable la portera à la prochaine construction)"
