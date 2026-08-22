import Foundation
import SpectreCore
#if canImport(WinSDK)
import WinSDK
#endif

// Ce qu'on retrouve en rouvrant un morceau, et ce qui vaut pour l'application
// entière — les deux rangements que le noyau tient, éprouvés sans écran.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE HARNAIS EXISTE, ET POURQUOI IL EST PORTABLE
//
// Les sessions sont la promesse la plus discrète de l'application : le travail de
// transcription se fait en plusieurs fois, et rien de ce qu'on a recalé — le
// premier temps, le contraste, la boucle sur le passage difficile — n'a de sens
// s'il est à refaire au lancement suivant. Une promesse discrète est une promesse
// qui casse sans bruit : personne ne remarque une session perdue avant d'avoir
// perdu la sienne.
//
// Le rangement est dans `SpectreCore`, donc portable, donc **exactement le même**
// sur les trois plateformes. Ce harnais l'est aussi : il tourne sur le Mac, sous
// Windows et sur le coureur Linux, et c'est ce qui donne son sens à l'étape 8 du
// portage — les sessions n'ont pas été « portées », elles ont été *mesurées* là où
// elles n'avaient jamais tourné.
//
// Il pose lui-même `SPECTRE_RANGEMENT` sur un dossier neuf. Un harnais des
// sessions qui écrirait dans les vraies serait le pire de tous : il effacerait
// précisément ce qu'il est chargé de protéger.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

let gestionnaire = FileManager.default

/// Pose une variable d'environnement pour ce processus.
///
/// `setenv` est du POSIX, et n'existe pas sous Windows : c'est `SetEnvironmentVariableW`
/// qui écrit dans le bloc d'environnement que `ProcessInfo` relit. Trois lignes,
/// mais c'est exactement le genre de détail qui fait qu'un harnais « portable »
/// s'arrête à la compilation sur la plateforme pour laquelle il a été écrit.
func poserDansLEnvironnement(_ nom: String, _ valeur: String) {
    #if canImport(WinSDK)
    _ = nom.withCString(encodedAs: UTF16.self) { n in
        valeur.withCString(encodedAs: UTF16.self) { v in
            SetEnvironmentVariableW(n, v)
        }
    }
    #else
    setenv(nom, valeur, 1)
    #endif
}

// `SPECTRE_RANGEMENT` est posé **avant** le premier appel au rangement : `Storage`
// le relit à chaque fois, mais un harnais qui l'oublierait écrirait sa première
// session chez l'utilisateur, et c'est la première qui compte.
let atelier = gestionnaire.temporaryDirectory
    .appendingPathComponent("spectre-sessions-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? gestionnaire.createDirectory(at: atelier, withIntermediateDirectories: true)
poserDansLEnvironnement("SPECTRE_RANGEMENT", atelier.path)
defer { try? gestionnaire.removeItem(at: atelier) }

titre("Le dossier de rangement")

verifie(Storage.root?.standardizedFileURL == atelier.standardizedFileURL,
        "SPECTRE_RANGEMENT détourne tout le rangement",
        Storage.root?.path ?? "aucun")

// MARK: - L'empreinte

titre("L'empreinte d'un fichier")

/// Un fichier d'octets connus, assez gros pour que l'empreinte lise une tête et
/// une queue distinctes — c'est le cas qui distingue deux morceaux de même taille.
func fabrique(_ nom: String, octets: Int, graine: UInt8) throws -> URL {
    var contenu = [UInt8](repeating: 0, count: octets)
    for i in 0..<octets { contenu[i] = graine &+ UInt8(truncatingIfNeeded: i &* 7) }
    let url = atelier.appendingPathComponent(nom)
    try Data(contenu).write(to: url)
    return url
}

do {
    let taille = 400 * 1024
    let morceau = try fabrique("morceau.wav", octets: taille, graine: 3)
    let copie = try fabrique("copie-ailleurs.wav", octets: taille, graine: 3)
    let autre = try fabrique("autre.wav", octets: taille, graine: 200)
    let plusCourt = try fabrique("court.wav", octets: taille - 1, graine: 3)

    let empreinte = SessionStore.fingerprint(of: morceau)
    verifie(empreinte != nil, "un fichier a une empreinte", empreinte?.prefix(16).description ?? "aucune")
    verifie(empreinte == SessionStore.fingerprint(of: morceau),
            "la même deux fois de suite")
    // C'est la promesse qui compte à l'usage : un morceau rangé ailleurs ou renommé
    // retrouve ses réglages, parce que ni le chemin ni le nom n'entrent dans le
    // calcul.
    verifie(empreinte == SessionStore.fingerprint(of: copie),
            "un fichier renommé garde la sienne")
    verifie(empreinte != SessionStore.fingerprint(of: autre),
            "un autre contenu en donne une autre")
    verifie(empreinte != SessionStore.fingerprint(of: plusCourt),
            "un octet de moins en donne une autre")
    verifie(SessionStore.fingerprint(of: atelier.appendingPathComponent("absent.wav")) == nil,
            "un fichier absent n'en a pas")
} catch {
    verifie(false, "fabrication des fichiers d'essai", "\(error)")
}

// MARK: - La session

titre("Ce qu'on retrouve en rouvrant")

var session = FileSession()
session.display.floorDb = -73.5
session.display.colorMap = .viridis
session.display.useFlats = false
session.display.referenceA = 432
session.tempo = TempoGrid(bpm: 128.5, origin: 0.375, beatsPerBar: 3, confidence: 4)
session.loop = 12.25...30.75
session.playhead = 18.5
session.speed = 0.65
session.transpose = -3
session.viewport.startColumn = 1234.5
session.viewport.columnsPerPoint = 2.75
session.viewport.bottomBin = 96.5
session.viewport.binsPerPoint = 1.25

let empreinteDEssai = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SessionStore.save(session, for: empreinteDEssai)
let relue = SessionStore.load(empreinteDEssai)

verifie(relue == session, "une session écrite se relit à l'identique")
verifie(relue?.display.floorDb == -73.5 && relue?.display.colorMap == .viridis,
        "le contraste et la palette reviennent",
        relue.map { "\($0.display.floorDb) dB, \($0.display.colorMap.label)" } ?? "rien")
verifie(relue?.tempo?.bpm == 128.5 && relue?.tempo?.beatsPerBar == 3,
        "la grille métrique revient, temps par mesure compris")
verifie(relue?.loop == 12.25...30.75, "la boucle revient")
verifie(relue?.speed == 0.65 && relue?.transpose == -3,
        "le ralenti et la transposition reviennent")
verifie(relue?.viewport.startColumn == 1234.5 && relue?.viewport.columnsPerPoint == 2.75,
        "le cadrage revient — c'est lui qu'on remarque en premier")

verifie(SessionStore.load("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") == nil,
        "un morceau jamais ouvert n'a pas de session")

// La tête de lecture est exclue de la comparaison qui décide d'écrire, parce
// qu'elle bouge à chaque image pendant la lecture. Elle n'est pas exclue de ce
// qu'on enregistre — c'est la nuance, et elle est vérifiable.
var avance = session
avance.playhead = 99
verifie(avance.withoutPlayhead == session.withoutPlayhead,
        "deux sessions qui ne diffèrent que par la tête de lecture se valent")
verifie(avance != session, "…mais ne sont pas la même session")

// MARK: - Un réglage ajouté n'efface pas ceux qui sont déjà écrits

titre("Une session écrite par une version antérieure")

// Le cas qui a dicté le décodage tolérant de `DisplaySettings` : `SessionStore.load`
// avale l'échec par un `try?`, si bien qu'un champ ajouté ferait rendre `nil` à
// **toutes** les sessions déjà enregistrées. L'utilisatrice retrouverait contraste,
// palette et diapason remis à zéro, sans un mot, pour tous ses morceaux.
let ancienne = """
    {"display":{"floorDb":-88,"colorMap":3},"playhead":42.5,"speed":0.8}
    """
let empreinteAncienne = "1111111111111111111111111111111111111111111111111111111111111111"
do {
    let dossier = atelier.appendingPathComponent("sessions", isDirectory: true)
    try gestionnaire.createDirectory(at: dossier, withIntermediateDirectories: true)
    try Data(ancienne.utf8).write(to: dossier.appendingPathComponent("\(empreinteAncienne).json"))
    let vieille = SessionStore.load(empreinteAncienne)
    verifie(vieille != nil, "elle se relit encore")
    verifie(vieille?.display.floorDb == -88 && vieille?.display.colorMap == .viridis,
            "ce qu'elle portait est retrouvé")
    verifie(vieille?.display.useFlats == DisplaySettings().useFlats
            && vieille?.display.referenceA == DisplaySettings().referenceA,
            "ce qu'elle ne portait pas reprend sa valeur d'origine")
    verifie(vieille?.playhead == 42.5 && vieille?.speed == 0.8,
            "la tête de lecture et le ralenti sont là")
    verifie(vieille?.transpose == 0 && vieille?.loop == nil,
            "et ce qui manque ne fait pas échouer la relecture")
} catch {
    verifie(false, "écriture d'une session ancienne", "\(error)")
}

titre("Une session abîmée")

let empreinteAbimee = "2222222222222222222222222222222222222222222222222222222222222222"
do {
    let dossier = atelier.appendingPathComponent("sessions", isDirectory: true)
    try Data("{ ceci n'est pas du JSON".utf8)
        .write(to: dossier.appendingPathComponent("\(empreinteAbimee).json"))
    // Elle ne doit jamais empêcher d'ouvrir le morceau : on repart des réglages
    // courants, exactement comme pour un fichier neuf.
    verifie(SessionStore.load(empreinteAbimee) == nil,
            "elle est ignorée plutôt que fatale")
} catch {
    verifie(false, "écriture d'une session abîmée", "\(error)")
}

// MARK: - Les morceaux récents

titre("Les morceaux récents")

RecentFiles.clear()
verifie(RecentFiles.all().isEmpty, "la liste part vide")

do {
    var fichiers: [URL] = []
    for i in 0..<(RecentFiles.limit + 4) {
        fichiers.append(try fabrique("recent-\(i).wav", octets: 64, graine: UInt8(i)))
    }
    for url in fichiers { RecentFiles.note(url) }

    let liste = RecentFiles.all()
    verifie(liste.count == RecentFiles.limit, "elle est plafonnée",
            "\(liste.count) sur \(fichiers.count) notés")
    verifie(liste.first?.lastPathComponent == fichiers.last?.lastPathComponent,
            "le dernier ouvert est en tête")

    // Rouvrir un morceau déjà présent le remonte sans le compter deux fois : sans
    // cela, revenir trois fois au même morceau remplirait la liste avec lui seul.
    let ancien = liste[3]
    RecentFiles.note(ancien)
    let apres = RecentFiles.all()
    verifie(apres.first?.standardizedFileURL == ancien.standardizedFileURL,
            "un morceau rouvert remonte en tête")
    verifie(apres.count == liste.count, "et n'y figure toujours qu'une fois",
            "\(apres.count) entrées")

    // Un morceau déplacé ne doit pas être proposé : « Ouvrir récemment » qui ouvre
    // sur une erreur est pire que de ne rien proposer.
    try gestionnaire.removeItem(at: ancien)
    verifie(!RecentFiles.all().contains { $0.standardizedFileURL == ancien.standardizedFileURL },
            "un morceau disparu sort de la liste")

    RecentFiles.clear()
    verifie(RecentFiles.all().isEmpty, "et l'on peut tout effacer")
} catch {
    verifie(false, "fabrication des morceaux récents", "\(error)")
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
