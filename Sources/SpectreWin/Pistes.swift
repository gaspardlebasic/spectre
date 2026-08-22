import Foundation
import SpectreCore
import SpectreModele

// Le rangement des pistes séparées, sous Windows — le jumeau de
// `SpectreMac/Stems.swift`.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CELUI-CI EST ÉCRIT DEUX FOIS, ALORS QUE LE MOTEUR NE L'EST PLUS
//
// Le calcul de Demucs est descendu dans le noyau : une convention à côté et les
// deux plateformes sépareraient la même musique différemment, sans que personne ne
// s'en aperçoive. Le rangement, lui, n'a rien d'un algorithme — c'est de la
// plomberie de fichiers, et elle diffère franchement d'un système à l'autre :
// AVFoundation écrit du FLAC en trois lignes, Windows n'a pas d'écrivain sans perte
// qu'on puisse supposer présent.
//
// C'est exactement le partage que le décodeur, le lecteur et le rendu suivent déjà :
// ce qui se calcule est commun, ce qui touche au système est jumeau. Un `Player` et
// un `Lecteur` de trois cents lignes chacun ne sont pas un échec de conception.
//
// Ce qui est commun quand même : la **réserve de niveau** et le format d'écriture,
// qui vivent dans `SpectreCore/EcritureWAV.swift`. Écrire avec une réserve que la
// relecture ne rattrape pas rend un signal six décibels trop bas en silence, et
// c'est une faute qui a déjà été commise une fois sur le Mac.
// ─────────────────────────────────────────────────────────────────────────────

public enum RangementDesPistes {
    private static var racine: URL? { Storage.root }

    /// Fréquence à laquelle les pistes rangées doivent être : celle du réseau, la
    /// seule à laquelle il travaille.
    public static let frequenceDesPistes = 44_100.0

    /// Les pistes sont rangées sous le nom du modèle qui les a produites. Changer de
    /// modèle un jour ne doit pas faire resservir en silence des pistes calculées par
    /// l'ancien.
    public static func dossier(pour empreinte: String) -> URL? {
        guard let racine else { return nil }
        let dossier = racine.appendingPathComponent("pistes/\(empreinte)/\(Reseau.nom)",
                                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        return dossier
    }

    public static func url(_ piste: Stem, pour empreinte: String) -> URL? {
        guard piste != .mix, let dossier = dossier(pour: empreinte) else { return nil }
        return existant(nomme: piste.rawValue, dans: dossier)
    }

    /// Le fichier d'un nom donné, quel que soit son format.
    ///
    /// Le vingt-quatre bits d'abord, le flottant ensuite — celui qu'on écrit quand
    /// une piste dépasse la réserve. Quand ni l'un ni l'autre n'existe, c'est le
    /// chemin d'écriture qui est rendu, donc l'entier.
    static func existant(nomme nom: String, dans dossier: URL) -> URL {
        let entier = dossier.appendingPathComponent("\(nom).wav")
        if FileManager.default.fileExists(atPath: entier.path) { return entier }
        let flottant = dossier.appendingPathComponent("\(nom).wavf")
        if FileManager.default.fileExists(atPath: flottant.path) { return flottant }
        return entier
    }

    /// Un jeu de pistes utilisable existe-t-il pour ce morceau ?
    ///
    /// Les quatre fichiers, **et à la bonne fréquence**. Ce second point répare après
    /// coup un jeu de pistes écrit de travers : rien dans le contenu d'un fichier ne
    /// dit qu'il a été étiqueté avec la fréquence du morceau d'origine au lieu de
    /// celle du réseau. Les ignorer les fait recalculer, ce qui est la seule issue.
    public static func estSepare(_ empreinte: String) -> Bool {
        Stem.separated.allSatisfy { piste in
            guard let url = url(piste, pour: empreinte),
                  FileManager.default.fileExists(atPath: url.path),
                  let forme = WAVFile.forme(at: url) else { return false }
            return abs(forme.sampleRate - frequenceDesPistes) < 1
        }
    }

    /// Efface les pistes d'un morceau, **et le dossier qui les portait**.
    public static func oublier(_ empreinte: String) {
        guard let racine else { return }
        try? FileManager.default.removeItem(
            at: racine.appendingPathComponent("pistes/\(empreinte)", isDirectory: true))
    }

    // MARK: Combinaisons

    /// Le fichier correspondant à un ensemble de pistes — la piste elle-même quand
    /// il n'y en a qu'une, leur somme sinon.
    ///
    /// Les sommes sont gardées à côté des pistes, sous un nom formé des leurs :
    /// réécouter « basse + batterie » ne doit pas coûter une nouvelle addition sur dix
    /// millions d'échantillons. Le nom est trié, de sorte que l'ordre dans lequel on a
    /// cliqué ne fabrique pas deux fichiers pour la même combinaison.
    public static func combinee(_ pistes: Set<Stem>, pour empreinte: String) throws -> URL? {
        let voulues = pistes.subtracting([.mix]).sorted { $0.rawValue < $1.rawValue }
        guard !voulues.isEmpty else { return nil }
        if voulues.count == 1 { return url(voulues[0], pour: empreinte) }

        guard let dossier = dossier(pour: empreinte) else { return nil }
        let nom = voulues.map(\.rawValue).joined(separator: "+")
        let cible = existant(nomme: nom, dans: dossier)
        if FileManager.default.fileExists(atPath: cible.path) { return cible }

        var somme: [[Float]] = []
        var frequence = frequenceDesPistes
        for piste in voulues {
            guard let fichier = url(piste, pour: empreinte) else { continue }
            let (canaux, echantillonnage) = try lire(fichier)
            frequence = echantillonnage
            if somme.isEmpty { somme = canaux; continue }
            // Les pistes viennent du même morceau : mêmes longueurs, même cadence.
            // On se garde tout de même d'un dépassement, plutôt que d'y compter.
            for c in 0..<min(somme.count, canaux.count) {
                let n = min(somme[c].count, canaux[c].count)
                for i in 0..<n { somme[c][i] += canaux[c][i] }
            }
        }
        guard !somme.isEmpty else { return nil }
        // La somme peut, elle aussi, ne pas tenir dans la réserve : c'est le chemin
        // réellement écrit qui fait foi.
        return try ecrire(somme, echantillonnage: frequence, vers: cible)
    }

    // MARK: Lire et écrire

    /// Lit une piste canal par canal, réserve de niveau rattrapée.
    ///
    /// **La réserve n'est rattrapée que sur nos propres fichiers** : l'extension seule
    /// ne suffit pas à décider, un WAV de la discothèque n'ayant pas été écrit par
    /// nous. D'où la double condition, l'extension *et* l'emplacement. Le pendant
    /// macOS s'est fait prendre exactement là.
    public static func lire(_ url: URL) throws -> (canaux: [[Float]], echantillonnage: Double) {
        var (canaux, echantillonnage) = try WAVFile.readChannels(at: url)
        let gain = gain(pour: url)
        if gain != 1 {
            for c in canaux.indices {
                for i in canaux[c].indices { canaux[c][i] *= gain }
            }
        }
        return (canaux, echantillonnage)
    }

    public static func gain(pour url: URL) -> Float {
        guard let racine,
              url.path.hasPrefix(racine.appendingPathComponent("pistes").path)
        else { return 1 }
        return WAVFile.gain(pour: url)
    }

    /// Écrit une piste, et rend le chemin réellement écrit.
    ///
    /// La stéréo est conservée alors que l'analyse, elle, resomme les canaux : elle ne
    /// coûte que de la place, et il serait dommage d'écouter en mono une basse qu'on
    /// vient d'isoler.
    @discardableResult
    public static func ecrire(_ canaux: [[Float]], echantillonnage: Double,
                              vers url: URL) throws -> URL {
        let ecrit = try WAVFile.ecrire(canaux, echantillonnage: echantillonnage, vers: url)
        // Écrire en flottant laisse derrière lui l'entier d'une fois précédente, que
        // `existant` retrouverait en premier : c'est la piste d'avant qu'on relirait.
        if ecrit != url { try? FileManager.default.removeItem(at: url) }
        return ecrit
    }

    // MARK: Le plafond du cache

    /// Au-delà, les morceaux les moins récemment ouverts s'en vont.
    ///
    /// Un morceau de sept minutes coûte environ 300 Mo de pistes en vingt-quatre
    /// bits : le plafond en garde donc trois, ce qui couvre une séance de travail. Ce
    /// qui est jeté se recalcule — c'est quelques minutes de calcul, pas une perte.
    public static var plafond = 1_000_000_000

    public static func taille() -> Int {
        guard let racine else { return 0 }
        return poids(de: racine.appendingPathComponent("pistes", isDirectory: true))
    }

    public static func vider() {
        guard let racine else { return }
        try? FileManager.default.removeItem(
            at: racine.appendingPathComponent("pistes", isDirectory: true))
    }

    /// Ramène le dossier des pistes sous le plafond.
    ///
    /// Un morceau s'en va **entier** : il ne servirait à rien de garder trois pistes
    /// sur quatre, `estSepare` demandant les quatre. Le plus anciennement ouvert part
    /// le premier, et celui qu'on écoute ne part jamais — sans cette règle on jetterait
    /// ce qu'on vient de calculer.
    @discardableResult
    public static func ranger(enGardant empreinte: String?,
                              plafond limite: Int = plafond) -> Int {
        guard let racine else { return 0 }
        let gestionnaire = FileManager.default
        let pistes = racine.appendingPathComponent("pistes", isDirectory: true)
        guard let entrees = try? gestionnaire.contentsOfDirectory(
            at: pistes, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }

        var morceaux = [(url: URL, taille: Int, servi: Date)]()
        var total = 0
        for entree in entrees {
            let taille = poids(de: entree)
            let servi = (try? entree.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            morceaux.append((entree, taille, servi))
            total += taille
        }

        var libere = 0
        for morceau in morceaux.sorted(by: { $0.servi < $1.servi }) where total > limite {
            guard morceau.url.lastPathComponent != empreinte else { continue }
            try? gestionnaire.removeItem(at: morceau.url)
            total -= morceau.taille
            libere += morceau.taille
        }
        return libere
    }

    /// Marque un morceau comme servi, pour qu'il ne parte pas le premier.
    ///
    /// Relire un fichier ne change pas sa date : sans ce coup de pouce, l'ordre du
    /// ménage serait celui des calculs et non celui des écoutes, et le morceau sur
    /// lequel on travaille depuis une heure passerait pour le plus vieux.
    public static func marquerServi(_ empreinte: String) {
        guard let dossier = racine?.appendingPathComponent("pistes/\(empreinte)",
                                                           isDirectory: true),
              FileManager.default.fileExists(atPath: dossier.path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: dossier.path)
    }

    private static func poids(de dossier: URL) -> Int {
        guard let parcours = FileManager.default.enumerator(
            at: dossier, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for cas in parcours {
            guard let fichier = cas as? URL else { continue }
            total += (try? fichier.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }
}

// MARK: - Ce que le modèle voit

/// Le rangement des pistes et leur fabrication, réunis comme le modèle les voit.
///
/// Il ne distingue jamais les deux : il demande si un morceau est séparé, la somme de
/// telles pistes, ou le lancement d'un calcul. Que les pistes soient rangées dans
/// `%APPDATA%` et écrites en WAV vingt-quatre bits ne le regarde pas.
public final class RangementWindows: ServiceDeSeparation {
    public init() {}

    public var modeleDisponible: Bool { Reseau.disponible }

    public func estSepare(_ empreinte: String) -> Bool {
        RangementDesPistes.estSepare(empreinte)
    }

    public func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? {
        RangementDesPistes.url(piste, pour: empreinte)
    }

    public func urlCombinee(_ pistes: Set<Stem>, empreinte: String) throws -> URL? {
        try RangementDesPistes.combinee(pistes, pour: empreinte)
    }

    public func oublierLesPistes(empreinte: String) {
        RangementDesPistes.oublier(empreinte)
    }

    public func marquerUtilise(_ empreinte: String) {
        RangementDesPistes.marquerServi(empreinte)
    }

    public func separer(fichier: URL, empreinte: String,
                        avancement: @escaping (SeparationProgress) -> Void,
                        fin: @escaping (Result<Void, Error>) -> Void) -> TravailAnnulable {
        let travail = TravailDeSeparation()
        travail.lancer(fichier: fichier, empreinte: empreinte,
                       moteur: SeparateurWindows(), avancement: avancement, fin: fin)
        return travail
    }
}

/// Sépare un morceau sans bloquer l'interface.
///
/// Le calcul dure des minutes ; il se fait donc sur une file de fond, et tout ce qui
/// touche au modèle d'application est renvoyé sur le fil principal. L'annulation est
/// consultée par le moteur entre deux tranches, de sorte que fermer un morceau
/// n'attende pas la fin d'un calcul devenu inutile.
public final class TravailDeSeparation: TravailAnnulable {
    private var annule = false
    private let verrou = NSLock()

    public init() {}

    public var isCancelled: Bool {
        verrou.lock(); defer { verrou.unlock() }
        return annule
    }

    public func cancel() {
        verrou.lock(); annule = true; verrou.unlock()
    }

    public func lancer(fichier: URL, empreinte: String, moteur: StemSeparator,
                       avancement: @escaping (SeparationProgress) -> Void,
                       fin: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let issue: Result<Void, Error>
            do {
                let pistes = try moteur.separate(
                    fileAt: fichier,
                    progress: { p in DispatchQueue.main.async { avancement(p) } },
                    isCancelled: { self.isCancelled })
                guard !isCancelled else { throw SeparationFailure.cancelled }

                // La fréquence vient du moteur, jamais du fichier d'entrée : c'est
                // exactement la confusion qui faisait jouer les pistes trop vite.
                for (piste, canaux) in pistes.channels {
                    guard let cible = RangementDesPistes.url(piste, pour: empreinte)
                    else { continue }
                    try RangementDesPistes.ecrire(canaux,
                                                  echantillonnage: pistes.sampleRate,
                                                  vers: cible)
                }
                // C'est ici que le dossier grossit, donc ici qu'on fait le ménage — et
                // en épargnant le morceau qu'on vient de calculer, qui serait sinon le
                // premier candidat sur une machine dont le cache est déjà plein.
                RangementDesPistes.marquerServi(empreinte)
                RangementDesPistes.ranger(enGardant: empreinte)
                issue = .success(())
            } catch {
                // Un échec en cours d'écriture laisserait un jeu de pistes incomplet,
                // que l'application prendrait ensuite pour un travail fait. On préfère
                // ne rien garder.
                if !(error is SeparationFailure) || isCancelled {
                    RangementDesPistes.oublier(empreinte)
                }
                issue = .failure(error)
            }
            DispatchQueue.main.async { fin(issue) }
        }
    }
}
