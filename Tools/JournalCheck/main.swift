import Foundation
import SpectreCore

// Le journal, éprouvé sur ce que personne ne peut écrire à la main : sa propre mort.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE HARNAIS EXISTE
//
// La v0.4 est partie avec un installeur Windows qui ne s'ouvrait pas. L'application
// disait pourquoi — une erreur fatale du runtime de Swift écrit toujours son
// message — et ce message n'arrivait nulle part : pas de console pour une
// application en sous-système « fenêtre », pas de fichier, rien. Il a fallu une
// machine virtuelle, un accès distant et une demi-journée pour apprendre ce qu'une
// ligne de texte disait déjà. Voir `docs/PAQUETS.md`.
//
// `Journal.ouvrir()` répond à cela. Mais un journal qui n'attrape pas la dernière
// phrase est un journal qui rassure sans servir, et **cela ne se voit pas** : il
// s'ouvre, il porte son en-tête, il a l'air de marcher. On ne s'aperçoit du contraire
// qu'au moment où l'on en a besoin, c'est-à-dire trop tard, chez quelqu'un d'autre.
//
// D'où ce harnais, qui va jusqu'au bout : il **se relance lui-même** dans un
// processus fils, sans terminal, lui fait commettre une erreur fatale, puis rouvre
// le journal et regarde si le message y est. C'est la seule façon de l'éprouver —
// un programme ne peut pas survivre à sa propre erreur fatale pour vérifier ce
// qu'elle a écrit.
//
// La variable `SPECTRE_CHUTE` est ce qui distingue les deux rôles. Elle n'existe
// que pour ce harnais, et l'application ne la connaît pas.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Le rôle du fils : ouvrir le journal, et tomber

if ProcessInfo.processInfo.environment["SPECTRE_CHUTE"] != nil {
    Journal.ouvrir(version: "essai")
    Journal.erreur("le fils va tomber")
    // L'erreur fatale du runtime de Swift, celle-là même qui a emporté la v0.4 sous
    // Windows. Son message part sur la sortie d'erreur avant que le processus ne
    // meure — c'est ce qu'on veut retrouver dans le fichier.
    fatalError("chute volontaire du harnais")
}

// MARK: - Le rôle du père

var echecs = 0

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

print("\n=== La chute, et ce qu'il en reste ===")

// Un rangement à soi, et c'est la règle de tous les harnais du dépôt : celui qui
// n'écrit pas chez lui abîme ce qu'il est censé protéger.
let rangement = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("spectre-journal-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? FileManager.default.createDirectory(at: rangement, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: rangement) }

let fils = Process()
fils.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
var environnement = ProcessInfo.processInfo.environment
environnement["SPECTRE_CHUTE"] = "1"
environnement["SPECTRE_RANGEMENT"] = rangement.path
fils.environment = environnement
// **Sans terminal, et c'est le point de l'épreuve.** Le journal ne prend la place de
// la sortie d'erreur que lorsqu'il n'y a personne au bout — ce qui est le cas d'une
// application double-cliquée, et le cas d'un coureur d'intégration continue. Un tube
// suffit à le faire croire, et il rend en prime ce que le père aurait vu : c'est ce
// qui permet de vérifier que la sortie d'origine n'a pas été perdue en chemin.
let tube = Pipe()
fils.standardError = tube
fils.standardOutput = tube

do {
    try fils.run()
} catch {
    print("  ✗ le fils n'a pas pu être lancé — \(error)")
    exit(1)
}
let capture = String(decoding: tube.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
fils.waitUntilExit()

verifie(fils.terminationStatus != 0, "le fils est bien mort",
        "code \(fils.terminationStatus)")

let fichier = rangement.appendingPathComponent("journal.txt")
let journal = (try? String(contentsOf: fichier, encoding: .utf8)) ?? ""

verifie(!journal.isEmpty, "le journal a été écrit", fichier.lastPathComponent)
verifie(journal.contains("Spectre essai"), "l'en-tête porte la version")
verifie(journal.contains("le fils va tomber"), "ce que l'application disait y est")

// Les deux lignes qui n'existent que grâce au détournement de la sortie d'erreur :
// personne ne les écrit par `Journal`, elles viennent du runtime de Swift lui-même.
verifie(journal.contains("chute volontaire du harnais"),
        "le message de l'erreur fatale y est")
verifie(journal.contains("Fatal error"), "et il est nommé comme tel")

// Et la sortie d'origine n'a pas été mangée : c'est ce qui garde le diagnostic de
// `build.ps1` lisible quand l'épreuve du dossier propre échoue chez un coureur.
verifie(capture.contains("le fils va tomber"),
        "ce que l'application dit part aussi là où ça serait allé")

print("")
if echecs == 0 {
    print("Le journal attrape ce que l'application ne peut plus dire.")
} else {
    print("\(echecs) échec(s).")
    print("── le journal ──")
    print(journal)
    print("── la sortie du fils ──")
    print(capture)
}
exit(echecs == 0 ? 0 : 1)
