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

    static let modelName = "htdemucs_ft"
    /// Taille annoncée à l'utilisateur avant de lancer le téléchargement.
    static let modelBytes: Int64 = 336 * 1024 * 1024

    static var modelURL: URL? {
        guard let root else { return nil }
        let folder = root.appendingPathComponent("modeles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(modelName).onnx")
    }

    static var hasModel: Bool {
        guard let modelURL else { return false }
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Adresse d'où télécharger le modèle converti.
    ///
    /// **Encore à renseigner.** Il n'existe pas d'export ONNX officiel de Demucs, et
    /// les dépôts qu'on trouve appartiennent à une constellation de sites fabriqués
    /// pour le référencement : y brancher l'application reviendrait à faire tourner
    /// des poids d'origine inconnue. La conversion se fait depuis les poids officiels
    /// de Meta, une fois, hors ligne ; c'est le fichier produit qu'il faut publier
    /// quelque part, et c'est cette adresse-là qui va ici.
    ///
    /// Tant qu'elle est nulle, l'application propose de désigner le fichier à la
    /// main — ce qui est de toute façon le chemin pour l'essayer avant publication.
    static let modelSource: URL? = nil

    // MARK: Les pistes

    static func folder(for fingerprint: String) -> URL? {
        guard let root else { return nil }
        let folder = root.appendingPathComponent("pistes/\(fingerprint)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(_ stem: Stem, for fingerprint: String) -> URL? {
        guard stem != .mix else { return nil }
        return folder(for: fingerprint)?.appendingPathComponent("\(stem.rawValue).caf")
    }

    /// Les quatre pistes de ce morceau sont-elles déjà sur le disque ?
    static func isSeparated(_ fingerprint: String) -> Bool {
        Stem.separated.allSatisfy { stem in
            guard let url = url(stem, for: fingerprint) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func removeStems(for fingerprint: String) {
        guard let folder = folder(for: fingerprint) else { return }
        try? FileManager.default.removeItem(at: folder)
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
