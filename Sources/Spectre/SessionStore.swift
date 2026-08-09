import CryptoKit
import Foundation

/// Ce qu'on retrouve en rouvrant un fichier.
///
/// Le travail de transcription est long et se fait en plusieurs fois : recaler le
/// premier temps, régler le contraste, poser une boucle sur le passage difficile.
/// Rien de tout cela n'a de sens si c'est à refaire au prochain lancement.
struct FileSession: Codable, Equatable {
    var display = DisplaySettings()
    var tempo: TempoGrid?
    var loop: ClosedRange<Double>?
    var playhead: Double = 0
    var speed: Double = 1
    var transpose: Double = 0
    var viewport = Viewport()

    /// La même session, tête de lecture mise à zéro. Sert à décider s'il y a
    /// quelque chose à réécrire : pendant la lecture la position change à chaque
    /// image, et ce n'est pas une raison pour toucher au disque chaque seconde.
    var withoutPlayhead: FileSession {
        var copy = self
        copy.playhead = 0
        return copy
    }
}

/// Rangement des sessions, une par fichier audio.
enum SessionStore {

    /// Empreinte d'un fichier : taille, début et fin.
    ///
    /// Ni le chemin ni le nom n'en font partie, si bien qu'un morceau rangé
    /// ailleurs ou renommé retrouve ses réglages. Deux copies identiques les
    /// partagent — ce qui est le comportement souhaitable, c'est la même musique.
    /// Hacher le fichier entier serait plus sûr encore, mais ferait payer une
    /// seconde de lecture à chaque ouverture pour un gain théorique.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return nil }

        var digest = SHA256()
        withUnsafeBytes(of: UInt64(size).littleEndian) { digest.update(data: Data($0)) }
        if let head = try? handle.read(upToCount: chunk) { digest.update(data: head) }
        if size > 2 * chunk {
            try? handle.seek(toOffset: UInt64(size - chunk))
            if let tail = try? handle.readToEnd() { digest.update(data: tail) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var directory: URL? {
        guard let root = Storage.root else { return nil }
        let folder = root.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func load(_ fingerprint: String) -> FileSession? {
        guard let url = directory?.appendingPathComponent("\(fingerprint).json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        // Un fichier illisible — écrit par une version antérieure, ou abîmé — ne
        // doit jamais empêcher d'ouvrir le morceau : on repart des réglages
        // courants, ce qui est exactement ce qui se passe pour un fichier neuf.
        return try? JSONDecoder().decode(FileSession.self, from: data)
    }

    static func save(_ session: FileSession, for fingerprint: String) {
        guard let url = directory?.appendingPathComponent("\(fingerprint).json"),
              let data = try? JSONEncoder().encode(session)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Où l'application range ce qu'elle garde d'un morceau à l'autre.
enum Storage {
    static var root: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
        else { return nil }
        let folder = support.appendingPathComponent("Spectre", isDirectory: true)
        adoptFormerName(at: support, into: folder)
        return folder
    }

    /// L'application s'est appelée Transcripteur. Ses sessions et ses pistes — des
    /// heures de calcul — sont rangées sous l'ancien nom : on reprend le dossier tel
    /// quel plutôt que de faire tout recommencer.
    ///
    /// Ne fait rien dès que le nouveau dossier existe, donc au plus une fois.
    private static func adoptFormerName(at support: URL, into folder: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path) else { return }
        let former = support.appendingPathComponent("Transcripteur", isDirectory: true)
        guard manager.fileExists(atPath: former.path) else { return }
        try? manager.moveItem(at: former, to: folder)
    }
}
