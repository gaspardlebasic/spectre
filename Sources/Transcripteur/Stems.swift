import AVFoundation
import Foundation

/// Les cinq voies du sélecteur : le mixage tel qu'il est, et les quatre pistes que
/// la séparation isole.
///
/// Choisir une piste ne change pas seulement ce qu'on entend, mais aussi **ce qu'on
/// voit** : le spectrogramme d'une piste isolée a bien moins de partielles qui se
/// croisent, si bien que l'aimantation du curseur tombe enfin sur la bonne raie.
/// C'est là le vrai gain pour une transcription, l'écoute n'en étant que la moitié.
enum Stem: String, CaseIterable, Codable, Identifiable {
    case mix, drums, bass, vocals, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mix: "Mixage"
        case .drums: "Batterie"
        case .bass: "Basse"
        case .vocals: "Voix"
        case .other: "Reste"
        }
    }

    /// Symbole système. Chacun a été vérifié présent : un nom absent ne lève
    /// aucune erreur, il ne dessine simplement rien — et `drum`, le nom qu'on
    /// écrirait d'instinct, n'existe pas sur macOS 14.
    var symbol: String {
        switch self {
        case .mix: "waveform"
        case .drums: "circle.grid.cross"
        case .bass: "hifispeaker"
        case .vocals: "music.mic"
        case .other: "pianokeys"
        }
    }

    var help: String {
        switch self {
        case .mix: "Le morceau tel qu'il est."
        case .drums: "Batterie et percussions seules."
        case .bass: "La basse seule — la piste la mieux isolée, et la plus difficile à relever à l'oreille dans un mixage dense."
        case .vocals: "Le chant seul."
        case .other: "Tout le reste : claviers, guitares, cuivres, cordes."
        }
    }

    /// Les quatre pistes produites par le modèle, **dans l'ordre où il les rend**.
    /// Cet ordre est celui de Demucs et ne doit pas être réarrangé : il indexe
    /// directement la sortie du réseau.
    static let separated: [Stem] = [.drums, .bass, .other, .vocals]

    /// Comment nommer un ensemble de pistes gardées — pour la ligne d'état.
    ///
    /// La sélection étant soustractive, on la dit comme on l'a faite : « sans Voix »
    /// plutôt que « Basse + Batterie + Reste ». On n'énumère ce qui reste que
    /// lorsqu'il en reste moins qu'on n'en a retiré.
    static func label(for stems: Set<Stem>) -> String {
        let kept = separated.filter(stems.contains)
        let dropped = separated.filter { !stems.contains($0) }
        if dropped.isEmpty { return Stem.mix.label }
        if kept.isEmpty { return "silence" }
        if dropped.count < kept.count {
            return "sans " + dropped.map(\.label).joined(separator: " ni ")
        }
        return kept.map(\.label).joined(separator: " + ")
    }
}

/// Les deux variantes de Demucs v4 embarquées.
///
/// Elles séparent les mêmes quatre pistes et ne diffèrent que par la façon dont le
/// travail est réparti : un réseau qui rend tout d'un coup, ou quatre réseaux
/// spécialisés. D'où un rapport de un à quatre sur le temps de calcul.
enum SeparationModel: String, CaseIterable, Codable, Identifiable {
    /// Un seul réseau, qui rend les quatre pistes en un passage.
    case simple = "htdemucs"
    /// Le sac de quatre réseaux affinés, chacun n'ayant appris qu'un instrument.
    /// Sa matrice de pondération est l'identité : le réseau numéro *i* ne fournit
    /// que la source numéro *i*, ses trois autres sorties sont jetées. C'est très
    /// exactement ce qui le rend quatre fois plus lent — et meilleur.
    case fine = "htdemucs_ft"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simple: "Rapide"
        case .fine: "Affiné"
        }
    }

    /// Nombre de parcours du morceau qu'exige cette variante.
    var passes: Int {
        switch self {
        case .simple: 1
        case .fine: Stem.separated.count
        }
    }

    var help: String {
        switch self {
        case .simple:
            "htdemucs : un seul réseau rend les quatre pistes. Environ quatre fois plus rapide, un peu moins net."
        case .fine:
            "htdemucs_ft : un réseau affiné par instrument. Le meilleur résultat, au prix de quatre parcours du morceau."
        }
    }
}

// MARK: - Rangement

/// Où vivent le modèle et les pistes produites.
///
/// Tout est dans Application Support, à côté des sessions, et rien dans le dépôt :
/// un modèle pèse des centaines de mégaoctets et n'a pas sa place dans du code
/// versionné.
enum StemStore {
    private static var root: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
        else { return nil }
        return support.appendingPathComponent("Transcripteur", isDirectory: true)
    }

    // MARK: Le modèle

    /// Le réseau chargé d'une piste, pour une variante donnée.
    ///
    /// Les fichiers sont copiés dans le paquet à la construction et **ne sont pas
    /// versionnés** : les poids de Demucs ne sont pas couverts par la licence MIT du
    /// code — son auteur les dit « fournis à des fins scientifiques uniquement »,
    /// parce qu'ils sont entraînés sur MUSDB18. Les rediffuser n'irait pas ; les
    /// convertir pour son propre usage, si. C'est `modele.sh` qui les fabrique.
    ///
    /// Application Support est consulté ensuite, ce qui permet d'essayer un autre
    /// jeu de poids sans reconstruire l'application.
    static func modelFile(for stem: Stem, using variant: SeparationModel) -> URL? {
        guard stem != .mix else { return nil }
        switch variant {
        case .simple:
            return locate("htdemucs")
        case .fine:
            return locate("htdemucs_ft-\(stem.rawValue)")
        }
    }

    private static func locate(_ name: String) -> URL? {
        if let embedded = Bundle.main.url(forResource: name, withExtension: "onnx") {
            return embedded
        }
        guard let root else { return nil }
        let loose = root.appendingPathComponent("modeles/\(name).onnx")
        return FileManager.default.fileExists(atPath: loose.path) ? loose : nil
    }

    /// Un sac n'est utilisable qu'entier : trois réseaux sur quatre ne font pas une
    /// séparation, ils font une piste manquante.
    static func has(_ variant: SeparationModel) -> Bool {
        Stem.separated.allSatisfy { modelFile(for: $0, using: variant) != nil }
    }

    static var installedModels: [SeparationModel] { SeparationModel.allCases.filter(has) }

    // MARK: Les pistes

    /// Les pistes sont rangées **par variante** : les deux modèles peuvent ainsi
    /// coexister sur un même morceau, ce qui est la seule façon de les comparer
    /// sans tout recalculer à chaque bascule.
    static func folder(for fingerprint: String, variant: SeparationModel) -> URL? {
        guard let root else { return nil }
        let folder = root.appendingPathComponent("pistes/\(fingerprint)/\(variant.rawValue)",
                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(_ stem: Stem, for fingerprint: String, variant: SeparationModel) -> URL? {
        guard stem != .mix else { return nil }
        return folder(for: fingerprint, variant: variant)?
            .appendingPathComponent("\(stem.rawValue).caf")
    }

    /// Les quatre pistes de ce morceau sont-elles déjà sur le disque ?
    static func isSeparated(_ fingerprint: String, variant: SeparationModel) -> Bool {
        Stem.separated.allSatisfy { stem in
            guard let url = url(stem, for: fingerprint, variant: variant) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func removeStems(for fingerprint: String, variant: SeparationModel) {
        guard let folder = folder(for: fingerprint, variant: variant) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Combinaisons

    /// Le fichier correspondant à un ensemble de pistes — la piste elle-même quand
    /// il n'y en a qu'une, leur somme sinon.
    ///
    /// Les sommes sont mises en cache à côté des pistes, sous un nom formé des
    /// leurs : réécouter « basse + batterie » ne doit pas coûter une nouvelle
    /// addition sur dix millions d'échantillons. Le nom est trié, de sorte que
    /// l'ordre dans lequel on a cliqué ne fabrique pas deux fichiers pour la même
    /// combinaison.
    static func combined(_ stems: Set<Stem>, for fingerprint: String,
                         variant: SeparationModel) throws -> URL? {
        let wanted = stems.subtracting([.mix]).sorted { $0.rawValue < $1.rawValue }
        guard !wanted.isEmpty else { return nil }
        if wanted.count == 1 { return url(wanted[0], for: fingerprint, variant: variant) }

        guard let folder = folder(for: fingerprint, variant: variant) else { return nil }
        let target = folder.appendingPathComponent(
            wanted.map(\.rawValue).joined(separator: "+") + ".caf")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        var sum: [[Float]] = []
        var rate = 44100.0
        for stem in wanted {
            guard let file = url(stem, for: fingerprint, variant: variant) else { continue }
            let (channels, sampleRate) = try readChannels(from: file)
            rate = sampleRate
            if sum.isEmpty {
                sum = channels
                continue
            }
            // Les pistes viennent du même morceau : mêmes longueurs, même cadence.
            // On se garde tout de même d'un dépassement, plutôt que d'y compter.
            for c in 0..<min(sum.count, channels.count) {
                let n = min(sum[c].count, channels[c].count)
                for i in 0..<n { sum[c][i] += channels[c][i] }
            }
        }
        guard !sum.isEmpty else { return nil }
        try write(sum, sampleRate: rate, to: target)
        return target
    }

    /// Lit un fichier canal par canal, en virgule flottante.
    ///
    /// La boucle est indispensable : `read(into:)` n'est pas tenu de rendre tout ce
    /// qu'on lui demande en une fois, et un seul appel rend 44 032 images sur
    /// 44 100 — une troncature muette que rien ne signale.
    static func readChannels(from url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = Int(format.channelCount)
        var channels = [[Float]](repeating: [], count: count)
        let block: AVAudioFrameCount = 1 << 16
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)
        else { throw SeparationFailure.engine("format illisible") }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for c in 0..<count {
                channels[c].append(contentsOf: UnsafeBufferPointer(
                    start: buffer.floatChannelData![c], count: n))
            }
        }
        return (channels, format.sampleRate)
    }

    /// Écrit une piste en CAF flottant : sans perte, et lisible par `AVAudioFile`
    /// sans réencodage. Un format compressé ferait gagner de la place au prix
    /// d'artefacts ajoutés à ceux de la séparation — exactement ce dont on ne veut
    /// pas quand on va relire ce signal dans un spectrogramme.
    ///
    /// La stéréo est conservée alors que l'analyse, elle, resomme les canaux : elle
    /// ne coûte que de la place, et il serait dommage d'écouter en mono une basse
    /// qu'on vient d'isoler.
    static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard let first = channels.first, !first.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels.count),
                                         interleaved: false)
        else { throw SeparationFailure.cannotWrite(url) }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 1 << 16
        var offset = 0
        while offset < first.count {
            let n = min(block, first.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(n)) else {
                throw SeparationFailure.cannotWrite(url)
            }
            buffer.frameLength = AVAudioFrameCount(n)
            for (c, samples) in channels.enumerated() {
                samples.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![c].update(from: src.baseAddress! + offset, count: n)
                }
            }
            try file.write(from: buffer)
            offset += n
        }
    }
}
