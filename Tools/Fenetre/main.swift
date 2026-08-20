import CoreGraphics
import Foundation

// Le numéro de la fenêtre d'une application, pour qui veut la photographier.
//
//     Fenetre Spectre
//     14237 1512x949 temoin
//
// `screencapture -R x,y,l,h` photographie une *région de l'écran* : tout ce qui
// recouvre la fenêtre au moment du déclenchement se retrouve sur l'image, et il
// suffit qu'une autre application prenne le premier plan entre la mise au premier
// plan et la capture pour photographier autre chose. `screencapture -l numéro`
// vise la fenêtre elle-même, recouverte ou non — encore faut-il connaître son
// numéro, et c'est tout ce que fait ce programme.
//
// Le nom de la fenêtre n'est lisible qu'avec l'autorisation « Enregistrement de
// l'écran » ; le numéro et le propriétaire, eux, le sont toujours. L'un manquant,
// l'autre suffit à capturer.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage : Fenetre <nom de l'application>\n".utf8))
    exit(2)
}
let cherché = arguments[1]

guard let fenêtres = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                                 .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("liste des fenêtres illisible\n".utf8))
    exit(1)
}

for fenêtre in fenêtres {
    guard fenêtre[kCGWindowOwnerName as String] as? String == cherché,
          let numéro = fenêtre[kCGWindowNumber as String] as? Int,
          let cadre = fenêtre[kCGWindowBounds as String] as? [String: Any],
          let largeur = cadre["Width"] as? Double, let hauteur = cadre["Height"] as? Double
    else { continue }
    // Les fenêtres minuscules sont les ombres, les infobulles et les panneaux
    // flottants : ce qu'on cherche est la fenêtre du document.
    guard largeur > 200, hauteur > 200 else { continue }
    let nom = fenêtre[kCGWindowName as String] as? String ?? ""
    print("\(numéro) \(Int(largeur))x\(Int(hauteur)) \(nom)")
    exit(0)
}

FileHandle.standardError.write(Data("aucune fenêtre pour « \(cherché) »\n".utf8))
exit(1)
