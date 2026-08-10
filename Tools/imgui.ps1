# Dépose les sources de Dear ImGui là où la cible C++ les attend.
#
# Elles ne sont pas versionnées : c'est une bibliothèque tierce, figée sur une
# version, qui se retélécharge en deux secondes. Seuls les fichiers utilisés sont
# gardés — le dépôt d'ImGui contient une vingtaine de greffons dont un seul nous
# sert, et autant d'exemples.
$ErrorActionPreference = "Stop"
$racine = Split-Path $PSScriptRoot
$cible = Join-Path $racine "Sources\CImGui\imgui"
$version = "v1.92.9b"
if (Test-Path (Join-Path $cible "imgui.cpp")) {
    Write-Host "Dear ImGui déjà présent"
    exit 0
}
New-Item -ItemType Directory -Force -Path $cible | Out-Null
$ProgressPreference = "SilentlyContinue"
$temp = Join-Path $env:TEMP "imgui-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $zip = Join-Path $temp "imgui.zip"
    Invoke-WebRequest -Uri "https://github.com/ocornut/imgui/archive/refs/tags/$version.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $temp -Force
    $src = Join-Path $temp "imgui-$($version.TrimStart('v'))"
    foreach ($f in @("imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp",
                     "imgui.h", "imgui_internal.h", "imconfig.h", "imstb_textedit.h",
                     "imstb_rectpack.h", "imstb_truetype.h")) {
        Copy-Item (Join-Path $src $f) $cible
    }
    foreach ($f in @("imgui_impl_sdl3.cpp", "imgui_impl_sdl3.h", "imgui_impl_opengl3.cpp",
                     "imgui_impl_opengl3.h", "imgui_impl_opengl3_loader.h")) {
        Copy-Item (Join-Path $src "backends\$f") $cible
    }
} finally {
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
Write-Host "Dear ImGui $version → $cible"
