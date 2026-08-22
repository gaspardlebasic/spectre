import Foundation
import SpectreCore
import SpectreModele
import SpectreWin
#if canImport(WinSDK)
import WinSDK
#endif

// Le rangement des pistes séparées sous Windows — le pendant de `SeparationCheck`,
// qui fait le même travail sur le Mac.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUI SE VÉRIFIE SANS LES POIDS, ET CE QUI NE S'Y VÉRIFIE PAS
//
// Les poids de Demucs pèsent 166 Mo et ne sont pas dans le dépôt — ni ici ni sur le
// Mac. Ce harnais éprouve donc **l'ossature** : où les pistes sont rangées, comment
// elles s'écrivent et se relisent, ce qu'une somme de deux pistes vaut, ce que le
// plafond du cache jette, et le fait qu'un échec ne laisse pas derrière lui un jeu
// de pistes incomplet — que l'application prendrait ensuite pour un travail fait.
//
// Ce qu'il ne peut pas dire : si les pistes sortent justes. Cela demande le réseau,
// et se juge en écoutant. Le dire ici plutôt que de laisser croire qu'un harnais
// vert vaut une séparation vérifiée.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

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

// Un dossier à soi, et posé avant le premier appel au rangement. Sans cela le
// harnais écrirait dans le cache de l'utilisateur — et, plus vicieux, en
// déclencherait le plafond, qui effacerait les pistes de vrais morceaux.
let gestionnaire = FileManager.default
let atelier = gestionnaire.temporaryDirectory
    .appendingPathComponent("spectre-pistes-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? gestionnaire.createDirectory(at: atelier, withIntermediateDirectories: true)
poserDansLEnvironnement("SPECTRE_RANGEMENT", atelier.path)
defer { try? gestionnaire.removeItem(at: atelier) }

/// Un signal stéréo dont les deux canaux diffèrent : un aller-retour qui les
/// intervertirait ne se verrait pas sur de la stéréo identique.
let frequence = RangementDesPistes.frequenceDesPistes
let images = Int(frequence / 2)
let gauche = (0..<images).map { Float(0.4 * sin(2 * .pi * 220 * Double($0) / frequence)) }
let droite = (0..<images).map { Float(0.25 * sin(2 * .pi * 660 * Double($0) / frequence)) }

let empreinte = "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888"

titre("Où les pistes sont rangées")

verifie(RangementDesPistes.dossier(pour: empreinte)?.lastPathComponent == Reseau.nom,
        "sous le nom du modèle qui les a produites",
        RangementDesPistes.dossier(pour: empreinte)?.lastPathComponent ?? "—")
verifie(RangementDesPistes.url(.mix, pour: empreinte) == nil,
        "le mixage n'est pas une piste rangée")
verifie(RangementDesPistes.url(.bass, pour: empreinte)?.lastPathComponent == "bass.wav",
        "chaque piste a son fichier",
        RangementDesPistes.url(.bass, pour: empreinte)?.lastPathComponent ?? "—")

titre("Écrire et relire une piste")

do {
    guard let cible = RangementDesPistes.url(.bass, pour: empreinte) else {
        throw SeparationFailure.noSourceFile
    }
    let ecrit = try RangementDesPistes.ecrire([gauche, droite],
                                              echantillonnage: frequence, vers: cible)
    verifie(ecrit == cible, "elle tient dans la réserve et reste en entier",
            ecrit.lastPathComponent)

    let (canaux, lue) = try RangementDesPistes.lire(ecrit)
    verifie(lue == frequence, "la fréquence est celle du réseau", "\(lue) Hz")
    var ecart: Float = 0
    for i in 0..<images {
        ecart = max(ecart, abs(canaux[0][i] - gauche[i]))
        ecart = max(ecart, abs(canaux[1][i] - droite[i]))
    }
    // La réserve est rattrapée par le rangement, et par lui seul : c'est là que la
    // double condition — l'extension *et* l'emplacement — se vérifie.
    verifie(Double(ecart) < 1e-6, "le signal revient, réserve rattrapée",
            String(format: "écart %.1e", ecart))

    // Un WAV qui n'est pas à nous ne doit pas être remonté de six décibels.
    let ailleurs = atelier.appendingPathComponent("emprunte.wav")
    _ = try WAVFile.ecrire([gauche], echantillonnage: frequence, vers: ailleurs)
    verifie(RangementDesPistes.gain(pour: ailleurs) == 1,
            "un WAV venu d'ailleurs n'est pas remonté")
} catch {
    verifie(false, "écriture d'une piste", "\(error)")
}

titre("Un jeu de pistes complet")

func poser(_ empreinte: String, frequence: Double = RangementDesPistes.frequenceDesPistes) {
    for piste in Stem.separated {
        guard let url = RangementDesPistes.url(piste, pour: empreinte) else { continue }
        // Une piste par voie, d'amplitude différente : la somme de deux d'entre elles
        // se vérifie alors sur autre chose qu'un facteur deux.
        let facteur = Float(Stem.separated.firstIndex(of: piste)! + 1) / 4
        _ = try? RangementDesPistes.ecrire([gauche.map { $0 * facteur },
                                            droite.map { $0 * facteur }],
                                           echantillonnage: frequence, vers: url)
    }
}

poser(empreinte)
verifie(RangementDesPistes.estSepare(empreinte), "les quatre pistes sont sur le disque")

titre("Les sommes de pistes")

do {
    guard let melange = try RangementDesPistes.combinee([.bass, .drums], pour: empreinte),
          let basse = RangementDesPistes.url(.bass, pour: empreinte),
          let batterie = RangementDesPistes.url(.drums, pour: empreinte) else {
        throw SeparationFailure.noSourceFile
    }
    let (somme, _) = try RangementDesPistes.lire(melange)
    let (a, _) = try RangementDesPistes.lire(basse)
    let (b, _) = try RangementDesPistes.lire(batterie)
    var ecart: Float = 0
    for i in 0..<images { ecart = max(ecart, abs(somme[0][i] - (a[0][i] + b[0][i]))) }
    verifie(Double(ecart) < 2e-6, "la somme de deux pistes est bien leur somme",
            String(format: "écart %.1e", ecart))

    // Le nom est trié : l'ordre dans lequel on a cliqué ne doit pas fabriquer deux
    // fichiers pour la même combinaison.
    let encore = try RangementDesPistes.combinee([.drums, .bass], pour: empreinte)
    verifie(encore == melange, "l'ordre des clics ne change pas le fichier",
            encore?.lastPathComponent ?? "—")

    let seule = try RangementDesPistes.combinee([.vocals], pour: empreinte)
    verifie(seule == RangementDesPistes.url(.vocals, pour: empreinte),
            "une piste seule est elle-même, sans recopie")
    verifie((try RangementDesPistes.combinee([], pour: empreinte)) == nil,
            "aucune piste ne donne aucun fichier")
} catch {
    verifie(false, "sommes de pistes", "\(error)")
}

titre("Une piste écrite à la mauvaise fréquence")

// Le défaut réparé après coup : les pistes ont longtemps été étiquetées avec la
// fréquence du fichier d'origine au lieu de celle du réseau, si bien qu'un morceau à
// 48 kHz produisait des pistes à 44,1 kHz annoncées 48 kHz — jouées 8,8 % trop vite.
// Rien dans le contenu ne le dit ; les ignorer les fait recalculer, ce qui est la
// seule issue.
let empreinteFausse = "1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff"
poser(empreinteFausse, frequence: 48000)
verifie(!RangementDesPistes.estSepare(empreinteFausse),
        "elle ne compte pas comme un jeu de pistes valable")
RangementDesPistes.oublier(empreinteFausse)

titre("Effacer")

RangementDesPistes.oublier(empreinte)
// Dans cet ordre, et pas l'autre : `dossier(pour:)` crée à la demande — c'est ce qui
// permet d'écrire une piste sans avoir à préparer son dossier — si bien que demander
// `estSepare` d'abord recréerait la coquille qu'on vient d'effacer, et le contrôle
// suivant passerait toujours en disant le contraire de ce qu'il vérifie.
verifie(!gestionnaire.fileExists(
    atPath: atelier.appendingPathComponent("pistes/\(empreinte)").path),
        "le dossier du morceau s'en va entier, coquille comprise")
verifie(!RangementDesPistes.estSepare(empreinte), "il ne reste plus rien")

titre("Le plafond du cache")

let cobayes = ["c0baye000000000000000000000000000000000000000000000000000000001",
               "c0baye000000000000000000000000000000000000000000000000000000002",
               "c0baye000000000000000000000000000000000000000000000000000000003"]
for (rang, nom) in cobayes.enumerated() {
    poser(nom)
    // Les dates d'accès décident de l'ordre du ménage : on les écarte franchement
    // plutôt que de compter sur la résolution de l'horloge du système de fichiers.
    if let dossier = RangementDesPistes.dossier(pour: nom)?.deletingLastPathComponent() {
        try? gestionnaire.setAttributes(
            [.modificationDate: Date().addingTimeInterval(Double(rang) * 60 - 3600)],
            ofItemAtPath: dossier.path)
    }
}
verifie(cobayes.allSatisfy(RangementDesPistes.estSepare), "les trois jeux sont en place")

let libere = RangementDesPistes.ranger(enGardant: cobayes.last, plafond: 0)
verifie(libere > 0, "le ménage a libéré de la place",
        String(format: "%.1f Mo", Double(libere) / 1_000_000))
verifie(RangementDesPistes.estSepare(cobayes[2]),
        "celui qu'on écoute n'est jamais jeté")
verifie(!RangementDesPistes.estSepare(cobayes[0]) && !RangementDesPistes.estSepare(cobayes[1]),
        "les plus anciens s'en vont entiers")
RangementDesPistes.vider()
verifie(RangementDesPistes.taille() == 0, "et l'on peut tout vider")

titre("Le pont vers ONNX Runtime")

// Ce qui se vérifie sans les poids : que la DLL se charge, que l'API se retrouve, et
// qu'un fichier qui n'est pas un réseau **échoue en le disant** plutôt qu'en
// emportant le processus. C'est tout le pont C sauf l'inférence elle-même, et c'est
// la moitié qui casse quand elle casse.
if let dll = Reseau.bibliotheque {
    let faux = atelier.appendingPathComponent("pas-un-reseau.onnx")
    try? Data("ceci n'est pas un graphe".utf8).write(to: faux)
    do {
        _ = try MoteurONNX(modele: faux, bibliotheque: dll)
        verifie(false, "un fichier qui n'est pas un réseau est refusé",
                "aucune erreur levée")
    } catch let erreur as SeparationFailure {
        // Le message vient d'ONNX Runtime lui-même : le recevoir prouve que la
        // bibliothèque a été chargée et que son `OrtApi` a répondu.
        let dit = erreur.errorDescription ?? ""
        verifie(dit.count > 30, "un fichier qui n'est pas un réseau est refusé, et dit pourquoi",
                String(dit.prefix(80)))
    } catch {
        verifie(false, "un fichier qui n'est pas un réseau est refusé", "\(error)")
    }
} else {
    print("  (ONNX Runtime n'est pas installé — lancer .\\onnx.ps1)")
}

titre("Le moteur, quand le réseau n'est pas là")

// Sans les poids, la séparation doit être annoncée **absente** plutôt que proposée
// puis échouée. C'est le même chemin que sur un Mac dont le modèle n'est pas
// installé, et c'est ce que le modèle d'application consulte pour décider s'il
// propose les pistes.
let service = RangementWindows()
if Reseau.fichier == nil {
    verifie(!service.modeleDisponible, "elle s'annonce absente")
    do {
        _ = try SeparateurWindows().separate(fileAt: atelier, progress: { _ in },
                                             isCancelled: { false })
        verifie(false, "et refuse de séparer", "aucune erreur levée")
    } catch let erreur as SeparationFailure {
        verifie(true, "et refuse de séparer", erreur.errorDescription ?? "")
    } catch {
        verifie(false, "et refuse de séparer", "\(error)")
    }
} else {
    // Le réseau est là. Le moteur peut manquer indépendamment — il se télécharge, là
    // où les poids se fabriquent — et le dire séparément évite de chercher du côté
    // du modèle quand c'est la DLL qui n'est pas installée.
    verifie(Reseau.bibliotheque != nil, "ONNX Runtime est installé",
            Reseau.bibliotheque?.path ?? "lancer .\\onnx.ps1")
    verifie(service.modeleDisponible == (Reseau.bibliotheque != nil),
            "la séparation est proposée si et seulement si les deux sont là")
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
