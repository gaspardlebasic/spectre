import Foundation
import SpectreCore

// Compare deux images PPM — en pratique, le rendu GPU et le rendu processeur.
//
//     ImageCheck gpu.ppm cpu.ppm
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE PROGRAMME EXISTE
//
// Le nuanceur GLSL a été traduit du MSL sans qu'aucune machine ne puisse
// l'afficher pendant l'écriture : la machine virtuelle qui compile n'a pas de
// bureau, et le seul œil disponible est celui de l'utilisateur. Or « ça a l'air
// bien » ne distingue pas une image juste d'une image retournée, décalée d'un
// pixel, ou dont le contraste a glissé — toutes plausibles.
//
// D'où la marche à suivre :
//
//   SpectreWindows.exe morceau.wav --rendu gpu.ppm   (relit la carte graphique)
//   SpectreCLI morceau.wav cpu.ppm --taille 1200x700 (la même formule, sur CPU)
//   ImageCheck gpu.ppm cpu.ppm
//
// Les deux images ne peuvent pas être identiques : le GPU interpole entre
// colonnes et entre lignes, le processeur prend le plus proche voisin. Ce qui
// doit tenir, c'est l'orientation et le cadrage — et ceux-là se mesurent.
// ─────────────────────────────────────────────────────────────────────────────

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage : ImageCheck <a.ppm> <b.ppm>\n".utf8))
    exit(2)
}

let a: (width: Int, height: Int, pixels: [UInt8])
let b: (width: Int, height: Int, pixels: [UInt8])
do {
    a = try PPM.read(at: URL(fileURLWithPath: arguments[1]))
    b = try PPM.read(at: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

guard let r = ImageComparison.compare(a, b) else {
    FileHandle.standardError.write(Data(
        "Dimensions différentes : \(a.width)×\(a.height) contre \(b.width)×\(b.height).\n".utf8))
    exit(1)
}

var échecs: [String] = []
func exige(_ condition: Bool, _ quoi: String) {
    print("  \(condition ? "ok  " : "ÉCHEC") \(quoi)")
    if !condition { échecs.append(quoi) }
}

print("ImageCheck — \(a.width)×\(a.height)")
print(String(format: "  profils de lignes    : %+.4f  (retourné : %+.4f)",
             r.rowProfile, r.rowProfileFlipped))
print(String(format: "  profils de colonnes  : %+.4f  (retourné : %+.4f)",
             r.columnProfile, r.columnProfileFlipped))
print(String(format: "  pixel à pixel        : %+.4f", r.pixelCorrelation))
print(String(format: "  écart : moyen %.2f/255, médian %.2f/255, %.1f %% sous 8/255",
             r.meanDifference, r.medianDifference, 100 * r.withinEight))
print("")

// L'image est-elle à l'endroit ? Le critère n'est pas « la corrélation est
// haute » mais « elle est franchement meilleure à l'endroit qu'à l'envers » :
// un spectrogramme a des bandes horizontales, donc même retourné il corrèle un
// peu, et un seuil absolu se ferait avoir.
exige(r.rowProfile > 0.9, "l'image est à l'endroit (verticalement)")
exige(r.rowProfile > r.rowProfileFlipped + 0.2, "franchement mieux à l'endroit qu'à l'envers")
exige(r.columnProfile > 0.9, "le temps coule dans le bon sens")
exige(r.pixelCorrelation > 0.9, "les deux dessinent la même chose")
exige(r.medianDifference < 4, "le pixel médian est au même niveau")
exige(r.withinEight > 0.8, "au moins 4 pixels sur 5 se superposent")

print("")
if échecs.isEmpty {
    print("Les deux rendus s'accordent.")
} else {
    print("\(échecs.count) désaccord(s).")
    exit(1)
}
