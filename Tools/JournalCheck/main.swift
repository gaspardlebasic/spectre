import Foundation
import SpectreCore
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

// MARK: - Le rôle du muet : parler sans avoir où parler

// C'est la panne de la v0.4, réduite à six lignes.
//
// L'application est en sous-système « fenêtre ». Lancée par l'Explorateur, elle
// n'hérite d'aucune console : `GetStdHandle` rend zéro, et **les poignées du
// processus sont nulles**. `FileHandle.standardError.write` lève alors — et
// Foundation appelle cela derrière un `try!`, si bien que la première note de
// l'application la tuait. Voir `Foundation/FileHandle.swift:709`.
//
// La note en question était le nom de la carte graphique, écrit juste après la
// création du périphérique Direct3D : d'où une panne « après la fenêtre », que ni
// l'épreuve du dossier propre ni le coureur ne pouvaient voir — l'une et l'autre
// redirigent la sortie, donc la rendent valide.
//
// **Et les deux systèmes ne se privent pas de sortie de la même façon.** Ce n'est pas
// un détail de mise en œuvre : c'est la différence entre une épreuve fidèle et une
// épreuve qui a l'air de passer.
//
// Sous Linux et sur le Mac, fermer les descripteurs 1 et 2 **est** la situation :
// `FileHandle.standardError` écrit sur le descripteur 2, qui rend `EBADF`, et
// Foundation lève. C'est reproduit ici, et c'est ce que le fils fait de lui-même.
//
// Sous Windows, non : ce que l'Explorateur donne n'est pas un descripteur fermé mais
// des **poignées nulles**, et cela se décide au lancement, pas depuis l'intérieur.
// `SetStdHandle(…, nil)` a été essayé et n'a rien reproduit — le fils continuait
// d'écrire dans le tube dont il avait hérité, et le harnais restait vert **avec le
// défaut en place**. C'est le père qui doit s'en charger : voir
// `lancerSansAucunePoignee` plus bas.
//
// **Rien n'est ouvert ensuite** : le premier fichier ouvert reprendrait le
// descripteur 1 ou 2 qu'on vient de libérer, ce qui est le piège classique du genre.
if ProcessInfo.processInfo.environment["SPECTRE_SANS_SORTIE"] != nil {
    #if !os(Windows)
    _ = close(1); _ = close(2)
    #endif
    Journal.note("une note sans personne pour la lire")
    Journal.erreur("et une erreur, pareil")
    exit(0)
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

// MARK: - Parler sans avoir où parler

// Le harnais de la panne de la v0.4. Il ne regarde qu'une chose : que le fils soit
// encore en vie après avoir parlé dans le vide.
//
// ─────────────────────────────────────────────────────────────────────────────
// ET SOUS WINDOWS, IL NE REGARDE RIEN — CE QUI EST DIT PLUTÔT QUE CACHÉ
//
// La panne était windowsienne, et c'est précisément là que ce harnais ne sait pas la
// rejouer. Trois montages ont été essayés sur la machine d'essai, et **aucun n'a
// viré au rouge avec le défaut remis en place** :
//
//   * fermer les descripteurs 1 et 2 — le runtime C abat alors le processus de
//     lui-même, quoi que Spectre écrive : on éprouve ucrt, pas nous ;
//   * `SetStdHandle(…, nil)` dans le fils — il continue d'écrire dans le tube dont
//     il a hérité ;
//   * `CreateProcessW` détaché, sans fenêtre, les trois poignées à zéro — le plus
//     proche de l'Explorateur qu'on puisse faire depuis un programme, et Foundation
//     n'y lève toujours pas.
//
// Un contrôle qui ne peut pas devenir rouge ne prouve rien, et en laisser un passer
// pour vert serait refaire l'erreur que tout ce chantier corrige. On le saute donc,
// **en le disant**, et la couverture de ce cas-là est ailleurs : `recette.sh` pose
// l'installeur sur le bureau de la machine d'essai, et quelqu'un double-clique. Le
// vrai lancement par l'Explorateur reste hors de portée d'un programme.
// ─────────────────────────────────────────────────────────────────────────────
#if os(Windows)
print("  · sans sortie ouverte : non éprouvé ici — voir recette.sh et docs/PAQUETS.md")
#else
let muet = Process()
muet.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
var sansSortie = ProcessInfo.processInfo.environment
sansSortie["SPECTRE_SANS_SORTIE"] = "1"
sansSortie["SPECTRE_RANGEMENT"] = rangement.path
muet.environment = sansSortie
try? muet.run()
muet.waitUntilExit()
verifie(muet.terminationStatus == 0,
        "écrire sans aucune sortie ouverte ne tue pas l'application",
        "code \(muet.terminationStatus)")
#endif

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
