import AVFoundation
import Foundation
import SpectreCore

// MARK: - Rangement

/// Où vivent le modèle et les pistes produites.
///
/// Tout est dans Application Support, à côté des sessions, et rien dans le dépôt :
/// un modèle pèse des centaines de mégaoctets et n'a pas sa place dans du code
/// versionné.
public enum StemStore {
    private static var root: URL? { Storage.root }

    // MARK: Le modèle

    /// Le modèle embarqué. Un seul réseau, qui rend les quatre pistes d'un coup.
    ///
    /// `htdemucs_ft` — quatre réseaux affinés, un par instrument — a été essayé puis
    /// écarté : quatre fois plus lent et 665 Mo de plus pour un gain qui ne s'entend
    /// pas assez.
    ///
    /// Les fichiers sont copiés dans le paquet à la construction et **ne sont pas
    /// versionnés** : les poids de Demucs ne sont pas couverts par la licence MIT du
    /// code — son auteur les dit « fournis à des fins scientifiques uniquement »,
    /// parce qu'ils sont entraînés sur MUSDB18. Les rediffuser n'irait pas ; les
    /// convertir pour son propre usage, si. C'est `modele.sh` qui les fabrique.
    ///
    /// Application Support est consulté ensuite, ce qui permet d'essayer un autre
    /// jeu de poids sans reconstruire l'application.
    public static let modelName = "htdemucs"

    public static var modelFile: URL? { locate(modelName) }

    private static func locate(_ name: String) -> URL? {
        // `SPECTRE_MODELE` désigne un réseau explicitement. C'est par là que les
        // vérifications atteignent celui du dépôt : elles ne sont pas dans le paquet
        // de l'application et ne verraient donc rien, ce qui les ferait passer sans
        // avoir rien vérifié — la pire des issues.
        if let named = ProcessInfo.processInfo.environment["SPECTRE_MODELE"],
           FileManager.default.fileExists(atPath: named) {
            return URL(fileURLWithPath: named)
        }
        if let embedded = Bundle.main.url(forResource: name, withExtension: "onnx") {
            return embedded
        }
        guard let root else { return nil }
        let loose = root.appendingPathComponent("modeles/\(name).onnx")
        return FileManager.default.fileExists(atPath: loose.path) ? loose : nil
    }

    public static var hasModel: Bool { modelFile != nil }

    // MARK: Les pistes

    /// Les pistes sont rangées sous le nom du modèle qui les a produites. Ce n'est
    /// plus un choix offert, mais la trace reste utile : changer de modèle un jour
    /// ne doit pas faire resservir en silence des pistes calculées par l'ancien.
    public static func folder(for fingerprint: String) -> URL? {
        guard let root else { return nil }
        let folder = root.appendingPathComponent("pistes/\(fingerprint)/\(modelName)",
                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public static func url(_ stem: Stem, for fingerprint: String) -> URL? {
        guard stem != .mix, let folder = folder(for: fingerprint) else { return nil }
        return existing(named: stem.rawValue, in: folder)
    }

    /// Le fichier d'un nom donné, quel que soit son format.
    ///
    /// Le FLAC d'aujourd'hui, ou le CAF flottant d'hier : les pistes déjà calculées
    /// représentent des minutes de GPU par morceau, et changer de format n'est pas une
    /// raison de les jeter. Quand ni l'un ni l'autre n'existe, c'est le chemin
    /// d'écriture qui est rendu — donc le FLAC.
    static func existing(named name: String, in folder: URL) -> URL {
        let compressed = folder.appendingPathComponent("\(name).flac")
        if FileManager.default.fileExists(atPath: compressed.path) { return compressed }
        let uncompressed = folder.appendingPathComponent("\(name).caf")
        if FileManager.default.fileExists(atPath: uncompressed.path) { return uncompressed }
        return compressed
    }

    // MARK: La réserve de niveau

    /// De combien les pistes compressées sont écrites en dessous, et remontées à la
    /// lecture.
    ///
    /// FLAC est un format **entier** : tout ce qui dépasse ±1,0 y est écrêté. Or une
    /// piste séparée dépasse — 1,19 mesuré sur la batterie comme sur le reste du
    /// fichier témoin, soit 361 échantillons abîmés sur la seule batterie, d'une
    /// erreur allant jusqu'à 0,19. On écrit donc six décibels plus bas et l'on remonte
    /// à la lecture. Il reste vingt-deux bits utiles, soit un plancher à −132 dB :
    /// trente-sept décibels sous le plus bas que l'affichage sache montrer, et
    /// l'aller-retour est exact à 1,2 × 10⁻⁷ près — la précision d'un flottant.
    ///
    /// Deux et non quatre : la réserve doit couvrir les crêtes réelles, pas rassurer.
    /// Ce qui dépasserait quand même n'est pas écrêté en silence — voir `write`.
    public static let compressedHeadroom: Float = 2

    /// Le gain à appliquer en lisant ce fichier.
    ///
    /// La réserve pour **nos** pistes compressées, rien pour le reste : un FLAC de la
    /// discothèque n'a pas été écrit par nous et n'a aucune raison d'être remonté de
    /// six décibels. D'où la double condition — l'extension *et* l'emplacement.
    public static func gain(for url: URL) -> Float {
        guard url.pathExtension.lowercased() == "flac", let root else { return 1 }
        return url.path.hasPrefix(root.appendingPathComponent("pistes").path)
            ? compressedHeadroom : 1
    }

    /// Les quatre pistes de ce morceau sont-elles déjà sur le disque ?
    /// Fréquence à laquelle les pistes rangées doivent être : celle du réseau, la
    /// seule à laquelle il travaille.
    public static let stemSampleRate = 44_100.0

    /// Un jeu de pistes utilisable existe-t-il pour ce morceau ?
    ///
    /// Les quatre fichiers, **et à la bonne fréquence**. Ce second point répare après
    /// coup un jeu de pistes écrit de travers : les pistes ont longtemps été
    /// étiquetées avec la fréquence du fichier d'origine au lieu de celle du réseau,
    /// si bien qu'un morceau à 48 kHz produisait des pistes à 44,1 kHz annoncées
    /// 48 kHz — jouées 8,8 % trop vite et un demi-ton et demi trop haut. Le défaut est
    /// corrigé à l'écriture ; les fichiers déjà sur le disque, eux, sont faux et rien
    /// dans leur contenu ne le dit. Les ignorer les fait recalculer, ce qui est la
    /// seule issue — et cela ne coûte rien aux morceaux déjà justes.
    public static func isSeparated(_ fingerprint: String) -> Bool {
        Stem.separated.allSatisfy { stem in
            guard let url = url(stem, for: fingerprint),
                  FileManager.default.fileExists(atPath: url.path) else { return false }
            guard let file = try? AVAudioFile(forReading: url) else { return false }
            return abs(file.processingFormat.sampleRate - stemSampleRate) < 1
        }
    }

    /// Efface les pistes d'un morceau, **et le dossier qui les portait**.
    ///
    /// Ne retirer que le sous-dossier du modèle laissait derrière lui une coquille
    /// vide par morceau — invisible tant qu'on ne les compte pas, et le ménage du
    /// cache les parcourt maintenant une à une.
    public static func removeStems(for fingerprint: String) {
        guard let root else { return }
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent("pistes/\(fingerprint)", isDirectory: true))
    }

    // MARK: La banque

    /// Relit les quatre pistes et les monte en mémoire, d'un seul bloc.
    ///
    /// Les quatre lectures se font **de front** : elles sont indépendantes, chacune
    /// coûte huit ou neuf dixièmes de seconde sur un morceau de huit minutes, et les
    /// enchaîner ferait attendre trois secondes et demie là où il en faut une.
    ///
    /// Rend `nil` dès qu'une des quatre manque : une banque incomplète ferait jouer un
    /// morceau amputé sans que rien ne le dise.
    public static func banque(pour fingerprint: String) throws -> BanqueDePistes? {
        var canaux = [Stem: [[Float]]]()
        var frequence = stemSampleRate
        var échec: Error?
        let verrou = NSLock()

        DispatchQueue.concurrentPerform(iterations: Stem.separated.count) { i in
            let stem = Stem.separated[i]
            guard let url = url(stem, for: fingerprint),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                let lues = try readChannels(from: url)
                verrou.lock()
                canaux[stem] = lues.channels
                frequence = lues.sampleRate
                verrou.unlock()
            } catch {
                verrou.lock(); échec = échec ?? error; verrou.unlock()
            }
        }
        if let échec { throw échec }
        guard canaux.count == Stem.separated.count else { return nil }
        return BanqueDePistes(empreinte: fingerprint, sampleRate: frequence,
                              pistes: &canaux)
    }

    /// Écrit les quatre pistes d'une banque, une par fichier.
    ///
    /// **Sous un nom provisoire, renommé à la fin.** L'écriture a lieu derrière la
    /// fenêtre, pendant qu'on travaille déjà sur les pistes : une application fermée
    /// au milieu laisserait sinon deux pistes sur quatre, que la séance suivante
    /// prendrait pour un travail fait — et l'on écouterait un morceau sans basse sans
    /// que rien ne l'explique.
    public static func ecrire(_ banque: BanqueDePistes, pour fingerprint: String) throws {
        guard let folder = folder(for: fingerprint) else {
            throw SeparationFailure.cannotWrite(URL(fileURLWithPath: fingerprint))
        }
        // Un brouillon d'une fois précédente — l'application fermée en pleine écriture —
        // n'a plus rien à dire et occupe la place d'une piste entière.
        for reste in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where reste.contains(".encours.") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(reste))
        }
        var écrits = [(URL, URL)]()
        for stem in banque.ordre {
            guard let canaux = banque.canauxDe(stem),
                  let destination = url(stem, for: fingerprint) else { continue }
            // Le brouillon porte l'extension voulue : c'est elle qui décide du format
            // écrit, et un nom sans extension aurait produit du PCM brut sous un nom de
            // FLAC — un jeu de pistes complet, illisible, et que rien n'aurait signalé.
            let brouillon = folder.appendingPathComponent(
                ".\(stem.rawValue).encours.\(destination.pathExtension)")
            let réel = try write(canaux, sampleRate: banque.sampleRate, to: brouillon)
            // `write` choisit parfois le CAF flottant plutôt que le FLAC : c'est le
            // chemin qu'il rend qui décide de l'extension finale, pas celui qu'on
            // avait demandé.
            let cible = destination.deletingPathExtension()
                .appendingPathExtension(réel.pathExtension)
            écrits.append((réel, cible))
        }
        guard écrits.count == banque.ordre.count else {
            for (brouillon, _) in écrits { try? FileManager.default.removeItem(at: brouillon) }
            throw SeparationFailure.cannotWrite(folder)
        }
        for (brouillon, cible) in écrits {
            try? FileManager.default.removeItem(at: cible)
            try FileManager.default.moveItem(at: brouillon, to: cible)
        }
    }

    /// Lit un fichier canal par canal, en virgule flottante.
    ///
    /// La boucle est indispensable : `read(into:)` n'est pas tenu de rendre tout ce
    /// qu'on lui demande en une fois, et un seul appel rend 44 032 images sur
    /// 44 100 — une troncature muette que rien ne signale.
    public static func readChannels(from url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = Int(format.channelCount)
        // Nos pistes compressées sont écrites six décibels plus bas ; on les remonte
        // ici, une fois pour toutes, de sorte que personne d'autre n'ait à le savoir.
        let restore = gain(for: url)
        var channels = [[Float]](repeating: [], count: count)
        // La place est réservée d'avance. Sans cela, `append` double sa capacité à
        // chaque débordement : sur les quatre pistes d'un morceau de huit minutes,
        // c'est jusqu'à six cent soixante mégaoctets alloués pour rien, au moment
        // précis où la banque en demande autant.
        for c in 0..<count { channels[c].reserveCapacity(Int(file.length)) }
        let block: AVAudioFrameCount = 1 << 16
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)
        else { throw SeparationFailure.engine("format illisible") }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for c in 0..<count {
                let source = buffer.floatChannelData![c]
                if restore != 1 {
                    for i in 0..<n { source[i] *= restore }
                }
                channels[c].append(contentsOf: UnsafeBufferPointer(start: source, count: n))
            }
        }
        return (channels, format.sampleRate)
    }

    /// Écrit une piste, **en FLAC quand le nom le demande**, en CAF flottant sinon.
    ///
    /// FLAC divise la place par deux et demi — 660 Mo de pistes pour un morceau de
    /// sept minutes en deviennent 250 — sans rien perdre : c'est un format sans perte,
    /// et la réserve de niveau règle le seul écueil, l'écrêtage au-dessus de ±1,0.
    ///
    /// **Ce qui ne tient pas dans la réserve n'est pas écrêté en silence** : cette
    /// piste-là s'écrit en CAF flottant, exact, et la fonction rend le chemin qu'elle
    /// a réellement écrit. Mieux vaut un fichier gros qu'un fichier faux, et c'est le
    /// genre de faute qui ne se verrait qu'au moment de relire un spectrogramme.
    ///
    /// La stéréo est conservée alors que l'analyse, elle, resomme les canaux : elle
    /// ne coûte que de la place, et il serait dommage d'écouter en mono une basse
    /// qu'on vient d'isoler.
    @discardableResult
    public static func write(_ channels: [[Float]], sampleRate: Double,
                             to url: URL) throws -> URL {
        guard let first = channels.first, !first.isEmpty else {
            throw SeparationFailure.cannotWrite(url)
        }
        var target = url
        var scale: Float = 1
        if url.pathExtension.lowercased() == "flac" {
            // **La même question qu'à la lecture, posée à la même fonction.** Écrire
            // avec une réserve que la relecture ne rattrape pas rendrait un signal six
            // décibels trop bas, silencieusement — et c'est exactement ce qui est
            // arrivé la première fois : `write` décidait sur l'extension, `gain` sur
            // l'extension *et* l'emplacement. Un FLAC exporté hors de nos dossiers
            // s'écrit donc à pleine échelle, et son plafond est 1,0 ; une de nos
            // pistes s'écrit avec la réserve, et son plafond est la réserve.
            let restore = gain(for: url)
            let peak = channels.reduce(Float(0)) { max($0, $1.map(abs).max() ?? 0) }
            if peak < restore {
                scale = 1 / restore
            } else {
                target = url.deletingPathExtension().appendingPathExtension("caf")
            }
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels.count),
                                         interleaved: false)
        else { throw SeparationFailure.cannotWrite(target) }
        let settings: [String: Any] = target.pathExtension.lowercased() == "flac"
            ? [AVFormatIDKey: kAudioFormatFLAC,
               AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: channels.count]
            : format.settings

        try? FileManager.default.removeItem(at: target)
        // Le fichier est refermé **avant** de rendre la main : l'en-tête d'un FLAC ne
        // s'écrit qu'à la fermeture, et le relire pendant qu'il est ouvert échoue sur
        // un format inconnu. Diagnostiqué exactement comme ça.
        var file: AVAudioFile? = try AVAudioFile(forWriting: target, settings: settings)
        defer { file = nil }
        let block = 1 << 16
        var offset = 0
        while offset < first.count {
            let n = min(block, first.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(n)) else {
                throw SeparationFailure.cannotWrite(target)
            }
            buffer.frameLength = AVAudioFrameCount(n)
            for (c, samples) in channels.enumerated() {
                samples.withUnsafeBufferPointer { src in
                    let destination = buffer.floatChannelData![c]
                    destination.update(from: src.baseAddress! + offset, count: n)
                    if scale != 1 {
                        for i in 0..<n { destination[i] *= scale }
                    }
                }
            }
            try file?.write(from: buffer)
            offset += n
        }
        return target
    }

    // MARK: Le plafond du cache

    /// Au-delà, les morceaux les moins récemment ouverts s'en vont.
    ///
    /// Un morceau de sept minutes coûte environ 250 Mo de pistes compressées : le
    /// plafond en garde donc trois ou quatre, ce qui couvre une séance de travail.
    /// Ce qui est jeté se recalcule — c'est une demi-minute de GPU, pas une perte.
    /// Réglable depuis le panneau des préférences ; un gigaoctet tant que personne
    /// n'y a touché.
    public static var cacheLimit = 1_000_000_000

    /// Ce que le dossier des pistes occupe, en octets.
    public static func cacheSize() -> Int {
        guard let root else { return 0 }
        let pistes = root.appendingPathComponent("pistes", isDirectory: true)
        guard let walk = FileManager.default.enumerator(
            at: pistes, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in walk {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }

    /// Jette toutes les pistes séparées.
    ///
    /// Ce sont des minutes de GPU, mais elles se refont : c'est un cache, et un cache
    /// qu'on ne peut pas vider est un dossier qui grossit.
    public static func emptyCache() {
        guard let root else { return }
        let pistes = root.appendingPathComponent("pistes", isDirectory: true)
        try? FileManager.default.removeItem(at: pistes)
    }

    /// Ramène le dossier des pistes sous le plafond.
    ///
    /// Un morceau s'en va **entier** : il ne servirait à rien de garder trois pistes
    /// sur quatre, `isSeparated` demandant les quatre. Le plus anciennement ouvert
    /// part le premier, et celui qu'on écoute ne part jamais — c'est la seule règle
    /// qui compte, et sans elle on jetterait ce qu'on vient de calculer.
    /// - Parameter limit: le plafond, `cacheLimit` par défaut. Il n'est explicite que
    ///   pour la vérification, qui doit pouvoir déclencher le ménage sans dépendre de
    ///   ce que la machine héberge déjà.
    @discardableResult
    public static func pruneCache(keeping fingerprint: String?,
                                  limit: Int = cacheLimit) -> Int {
        guard let root else { return 0 }
        let manager = FileManager.default
        let pistes = root.appendingPathComponent("pistes", isDirectory: true)
        guard let entries = try? manager.contentsOfDirectory(
            at: pistes, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }

        var songs = [(url: URL, size: Int, used: Date)]()
        var total = 0
        for entry in entries {
            var size = 0
            if let walk = manager.enumerator(at: entry, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let file as URL in walk {
                    // Les sommes de pistes ont vécu : elles étaient écrites à côté des
                    // quatre pistes, sous un nom qui les énumère, et représentaient
                    // ici soixante pour cent du cache. Elles se refont maintenant en
                    // mémoire au moment où le son sort. Le ménage les emporte au
                    // passage plutôt que de laisser des gigaoctets attendre qu'on
                    // efface le dossier à la main.
                    if file.lastPathComponent.contains(".encours.")
                        || file.deletingPathExtension().lastPathComponent.contains("+") {
                        try? manager.removeItem(at: file)
                        continue
                    }
                    size += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                }
            }
            let used = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            songs.append((entry, size, used))
            total += size
        }

        var freed = 0
        for song in songs.sorted(by: { $0.used < $1.used }) where total > limit {
            guard song.url.lastPathComponent != fingerprint else { continue }
            try? manager.removeItem(at: song.url)
            total -= song.size
            freed += song.size
        }
        return freed
    }

    /// Marque un morceau comme servi, pour qu'il ne parte pas le premier.
    ///
    /// Relire un fichier ne change pas sa date : sans ce coup de pouce, l'ordre du
    /// ménage serait celui des calculs et non celui des écoutes, et le morceau sur
    /// lequel on travaille depuis une heure passerait pour le plus vieux.
    public static func markUsed(_ fingerprint: String) {
        guard let folder = root?.appendingPathComponent("pistes/\(fingerprint)",
                                                        isDirectory: true),
              FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: folder.path)
    }
}
