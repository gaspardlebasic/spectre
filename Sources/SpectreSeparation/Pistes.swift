import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele

// Le rangement des pistes séparées — le jumeau de `SpectreMac/Stems.swift`.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CELUI-CI EST ÉCRIT DEUX FOIS, ET SEULEMENT DEUX
//
// Le calcul de Demucs est descendu dans le noyau : une convention à côté et les
// plateformes sépareraient la même musique différemment, sans que personne ne s'en
// aperçoive. Le rangement, lui, n'a rien d'un algorithme — c'est de la plomberie de
// fichiers, et elle diffère franchement de macOS : AVFoundation écrit du FLAC en
// trois lignes, ce dont ni Windows ni Linux ne disposent sans y ajouter une
// bibliothèque.
//
// **Mais elle ne diffère pas entre Windows et Linux.** Ce fichier vivait dans
// `SpectreWin` ; il n'importait déjà pas `WinSDK`, et tout ce qu'il fait — écrire du
// WAV vingt-quatre bits sous `Storage.root`, tenir un plafond de cache, relire les
// quatre pistes — se fait avec Foundation seule. Le recopier pour Linux aurait fait
// deux rangements à tenir d'accord, pour rien.
//
// Ce qui est commun aux trois : la **réserve de niveau** et le format d'écriture,
// qui vivent dans `SpectreCore/EcritureWAV.swift`. Écrire avec une réserve que la
// relecture ne rattrape pas rend un signal six décibels trop bas en silence, et
// c'est une faute qui a déjà été commise une fois sur le Mac.
// ─────────────────────────────────────────────────────────────────────────────

public enum RangementDesPistes {
    /// Fréquence à laquelle les pistes rangées doivent être : celle du réseau, la
    /// seule à laquelle il travaille.
    public static let frequenceDesPistes = 44_100.0

    /// Les pistes sont rangées sous le nom du modèle qui les a produites. Changer de
    /// modèle un jour ne doit pas faire resservir en silence des pistes calculées par
    /// l'ancien.
    public static func dossier(pour empreinte: String) -> URL? {
        guard let pistes = Storage.pistes else { return nil }
        let dossier = pistes.appendingPathComponent("\(empreinte)/\(Reseau.nom)",
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
        guard let pistes = Storage.pistes else { return }
        try? FileManager.default.removeItem(
            at: pistes.appendingPathComponent(empreinte, isDirectory: true))
    }

    // MARK: Combinaisons

    /// Relit les quatre pistes et les monte en mémoire, d'un seul bloc.
    ///
    /// Les combinaisons ne sont plus des fichiers. Elles étaient sommées, écrites,
    /// relues et décodées à chaque fois qu'on cochait une piste ; elles se font
    /// maintenant dans la banque, où la somme coûte un demi-quart de ce que coûtait le
    /// seul aller-retour par le disque. Voir `BanqueDePistes`, dans le noyau : les deux
    /// plateformes montent la même.
    ///
    /// Les quatre lectures se font **de front** : elles sont indépendantes, et les
    /// enchaîner ferait attendre quatre fois plus longtemps pour rien.
    ///
    /// Rend `nil` dès qu'une des quatre manque : une banque incomplète ferait jouer un
    /// morceau amputé sans que rien ne le dise.
    public static func banque(pour empreinte: String) throws -> BanqueDePistes? {
        var canaux = [Stem: [[Float]]]()
        var frequence = frequenceDesPistes
        var echec: Error?
        let verrou = NSLock()

        DispatchQueue.concurrentPerform(iterations: Stem.separated.count) { i in
            let piste = Stem.separated[i]
            guard let url = url(piste, pour: empreinte),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let lues = try lire(url)
                verrou.lock()
                canaux[piste] = lues.canaux
                frequence = lues.echantillonnage
                verrou.unlock()
            } catch {
                verrou.lock(); echec = echec ?? error; verrou.unlock()
            }
        }
        if let echec { throw echec }
        guard canaux.count == Stem.separated.count else { return nil }
        return BanqueDePistes(empreinte: empreinte, sampleRate: frequence, pistes: &canaux)
    }

    /// Écrit les quatre pistes d'une banque, une par fichier.
    ///
    /// **Sous un nom provisoire, renommé à la fin.** L'écriture a lieu derrière la
    /// fenêtre, pendant qu'on travaille déjà sur les pistes : une application fermée au
    /// milieu laisserait sinon deux pistes sur quatre, que la séance suivante prendrait
    /// pour un travail fait.
    public static func ecrire(_ banque: BanqueDePistes, pour empreinte: String) throws {
        guard let dossier = dossier(pour: empreinte) else {
            throw SeparationFailure.cannotWrite(URL(fileURLWithPath: empreinte))
        }
        // Un brouillon d'une fois précédente — l'application fermée en pleine écriture —
        // n'a plus rien à dire et occupe la place d'une piste entière.
        for reste in (try? FileManager.default.contentsOfDirectory(atPath: dossier.path)) ?? []
        where reste.contains(".encours.") {
            try? FileManager.default.removeItem(at: dossier.appendingPathComponent(reste))
        }
        var faits = [(URL, URL)]()
        for piste in banque.ordre {
            guard let canaux = banque.canauxDe(piste),
                  let destination = url(piste, pour: empreinte) else { continue }
            // Le brouillon porte l'extension voulue : c'est elle qui décide du format
            // écrit, et un nom sans extension produirait autre chose sous un nom qui
            // ne le dirait pas.
            let brouillon = dossier.appendingPathComponent(
                "\(piste.rawValue).encours.\(destination.pathExtension)")
            let reel = try ecrire(canaux, echantillonnage: banque.sampleRate, vers: brouillon)
            let cible = destination.deletingPathExtension()
                .appendingPathExtension(reel.pathExtension)
            faits.append((reel, cible))
        }
        guard faits.count == banque.ordre.count else {
            for (brouillon, _) in faits { try? FileManager.default.removeItem(at: brouillon) }
            throw SeparationFailure.cannotWrite(dossier)
        }
        for (brouillon, cible) in faits {
            try? FileManager.default.removeItem(at: cible)
            try FileManager.default.moveItem(at: brouillon, to: cible)
        }
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
        guard let pistes = Storage.pistes,
              url.path.hasPrefix(pistes.path)
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
        guard let pistes = Storage.pistes else { return 0 }
        return poids(de: pistes)
    }

    public static func vider() {
        guard let pistes = Storage.pistes else { return }
        try? FileManager.default.removeItem(at: pistes)
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
        guard let pistes = Storage.pistes else { return 0 }
        let gestionnaire = FileManager.default
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
        guard let dossier = Storage.pistes?.appendingPathComponent(empreinte,
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
            // Les sommes de pistes ont vécu : elles étaient écrites à côté des quatre
            // pistes, sous un nom qui les énumère, et pesaient plus que les pistes
            // elles-mêmes. Le ménage les emporte plutôt que de les laisser attendre.
            if fichier.lastPathComponent.contains(".encours.")
                || fichier.deletingPathExtension().lastPathComponent.contains("+") {
                try? FileManager.default.removeItem(at: fichier)
                continue
            }
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
/// `%APPDATA%` ou sous `~/.local/share`, et écrites en WAV vingt-quatre bits, ne le
/// regarde pas.
public final class RangementSurLePont: ServiceDeSeparation {
    public init() {}

    public var modeleDisponible: Bool { Reseau.disponible }
    public var poidsPresents: Bool { Reseau.fichier != nil }
    public func tailleDuCache() -> Int { RangementDesPistes.taille() }
    public func viderLeCache() { RangementDesPistes.vider() }

    public func estSepare(_ empreinte: String) -> Bool {
        RangementDesPistes.estSepare(empreinte)
    }

    public func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? {
        RangementDesPistes.url(piste, pour: empreinte)
    }

    public func chargerLesPistes(empreinte: String,
                                 fin: @escaping (BanqueDePistes?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let banque = try? RangementDesPistes.banque(pour: empreinte)
            DispatchQueue.main.async { fin(banque) }
        }
    }

    public func oublierLesPistes(empreinte: String) {
        RangementDesPistes.oublier(empreinte)
    }

    public func marquerUtilise(_ empreinte: String) {
        RangementDesPistes.marquerServi(empreinte)
    }

    public func separer(fichier: URL, empreinte: String,
                        avancement: @escaping (SeparationProgress) -> Void,
                        fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                        rangement: @escaping (Error?) -> Void) -> TravailAnnulable {
        let travail = TravailDeSeparation()
        travail.lancer(fichier: fichier, empreinte: empreinte,
                       moteur: SeparateurSurLePont(), avancement: avancement,
                       fin: fin, range: rangement)
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

    /// - Parameters:
    ///   - fin: sur le fil principal, **dès que le réseau a fini** — les pistes ne sont
    ///     pas encore sur le disque.
    ///   - range: sur le fil principal, quand l'écriture est finie.
    ///
    /// L'ordre des deux est tout l'objet de cette classe. Les pistes étaient écrites
    /// avant d'être rendues, et la fenêtre montrait une barre figée pendant tout
    /// l'encodage alors que le son et l'image étaient prêts en mémoire. On rend
    /// d'abord, on range ensuite.
    public func lancer(fichier: URL, empreinte: String, moteur: StemSeparator,
                       avancement: @escaping (SeparationProgress) -> Void,
                       fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                       range: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let banque: BanqueDePistes
            do {
                var pistes = try moteur.separate(
                    fileAt: fichier,
                    progress: { p in DispatchQueue.main.async { avancement(p) } },
                    isCancelled: { self.isCancelled })
                guard !isCancelled else { throw SeparationFailure.cancelled }
                // La fréquence vient du moteur, jamais du fichier d'entrée : c'est
                // exactement la confusion qui faisait jouer les pistes trop vite.
                guard let montee = BanqueDePistes(empreinte: empreinte,
                                                  sampleRate: pistes.sampleRate,
                                                  pistes: &pistes.channels),
                      montee.complete else {
                    throw SeparationFailure.engine(T(.erreurQuatrePistes))
                }
                banque = montee
            } catch {
                DispatchQueue.main.async { fin(.failure(error)) }
                return
            }
            DispatchQueue.main.async { fin(.success(banque)) }

            var echec: Error?
            do {
                try RangementDesPistes.ecrire(banque, pour: empreinte)
                // C'est ici que le dossier grossit, donc ici qu'on fait le ménage — et
                // en épargnant le morceau qu'on vient de calculer, qui serait sinon le
                // premier candidat sur une machine dont le cache est déjà plein.
                RangementDesPistes.marquerServi(empreinte)
                RangementDesPistes.ranger(enGardant: empreinte)
            } catch {
                // Une écriture incomplète laisserait un jeu de pistes que la séance
                // suivante prendrait pour un travail fait. On préfère ne rien garder.
                RangementDesPistes.oublier(empreinte)
                echec = error
            }
            let rapport = echec
            DispatchQueue.main.async { range(rapport) }
        }
    }
}
