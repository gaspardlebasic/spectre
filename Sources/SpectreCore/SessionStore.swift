import Foundation
// Le seul usage est SHA-256 pour l'empreinte d'un fichier. `swift-crypto` expose
// exactement la même API sous un autre nom de module : ailleurs que sur une
// plateforme Apple, il suffira de le déclarer en dépendance du noyau.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Ce qu'on retrouve en rouvrant un fichier.
///
/// Le travail de transcription est long et se fait en plusieurs fois : recaler le
/// premier temps, régler le contraste, poser une boucle sur le passage difficile.
/// Rien de tout cela n'a de sens si c'est à refaire au prochain lancement.
public struct FileSession: Codable, Equatable {
    public var display = DisplaySettings()
    public var tempo: TempoGrid?
    public var loop: ClosedRange<Double>?
    public var playhead: Double = 0
    public var speed: Double = 1
    public var transpose: Double = 0
    public var viewport = Viewport()

    public init(display: DisplaySettings = DisplaySettings(), tempo: TempoGrid? = nil,
                loop: ClosedRange<Double>? = nil, playhead: Double = 0,
                speed: Double = 1, transpose: Double = 0,
                viewport: Viewport = Viewport()) {
        self.display = display
        self.tempo = tempo
        self.loop = loop
        self.playhead = playhead
        self.speed = speed
        self.transpose = transpose
        self.viewport = viewport
    }

    /// La même session, tête de lecture mise à zéro. Sert à décider s'il y a
    /// quelque chose à réécrire : pendant la lecture la position change à chaque
    /// image, et ce n'est pas une raison pour toucher au disque chaque seconde.
    public var withoutPlayhead: FileSession {
        var copy = self
        copy.playhead = 0
        return copy
    }

    /// Décodage **tolérant aux champs manquants**, pour la raison exacte qui vaut
    /// déjà dans `DisplaySettings` — et qui vaut ici encore davantage.
    ///
    /// Le décodage synthétisé par Swift refuse un objet auquel il manque une clé,
    /// même quand la propriété a une valeur par défaut. Or `load` avale l'échec par
    /// un `try?` : ajouter un seul réglage à cette structure — le volume, la piste
    /// écoutée, ce que la prochaine version voudra retenir — rendrait d'un coup
    /// **toutes les sessions déjà écrites illisibles**, pour tous les morceaux. On
    /// retrouverait cadrage, contraste, boucle et grille remis à zéro, sans un mot.
    ///
    /// Le défaut était réel et non théorique : `DisplaySettings` et `ChordSettings`
    /// avaient été protégés, la session qui les contient ne l'était pas. C'est
    /// `SessionCheck` qui l'a trouvé, en relisant une session écrite à la main comme
    /// une version antérieure l'aurait écrite.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FileSession()
        display = try c.decodeIfPresent(DisplaySettings.self, forKey: .display) ?? d.display
        tempo = try c.decodeIfPresent(TempoGrid.self, forKey: .tempo)
        loop = try c.decodeIfPresent(ClosedRange<Double>.self, forKey: .loop)
        playhead = try c.decodeIfPresent(Double.self, forKey: .playhead) ?? d.playhead
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        transpose = try c.decodeIfPresent(Double.self, forKey: .transpose) ?? d.transpose
        viewport = try c.decodeIfPresent(Viewport.self, forKey: .viewport) ?? d.viewport
    }
}

/// Rangement des sessions, une par fichier audio.
public enum SessionStore {

    /// Empreinte d'un fichier : taille, début et fin.
    ///
    /// Ni le chemin ni le nom n'en font partie, si bien qu'un morceau rangé
    /// ailleurs ou renommé retrouve ses réglages. Deux copies identiques les
    /// partagent — ce qui est le comportement souhaitable, c'est la même musique.
    /// Hacher le fichier entier serait plus sûr encore, mais ferait payer une
    /// seconde de lecture à chaque ouverture pour un gain théorique.
    public static func fingerprint(of url: URL) -> String? {
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

    public static func load(_ fingerprint: String) -> FileSession? {
        guard let url = directory?.appendingPathComponent("\(fingerprint).json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        // Un fichier illisible — écrit par une version antérieure, ou abîmé — ne
        // doit jamais empêcher d'ouvrir le morceau : on repart des réglages
        // courants, ce qui est exactement ce qui se passe pour un fichier neuf.
        return try? JSONDecoder().decode(FileSession.self, from: data)
    }

    public static func save(_ session: FileSession, for fingerprint: String) {
        guard let url = directory?.appendingPathComponent("\(fingerprint).json"),
              let data = try? JSONEncoder().encode(session)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Les derniers morceaux ouverts, du plus récent au plus ancien.
///
/// **Écrite par nous**, à côté des sessions. `NSDocumentController` tient bien une
/// liste analogue — celle du Dock et du menu Pomme — et on continue de la nourrir,
/// mais elle ne retient rien d'un lancement à l'autre dans une application qui n'est
/// pas bâtie sur son architecture de documents : vérifié, `NSRecentDocumentRecords`
/// restait vide après une ouverture et une sortie propre. Or rouvrir le dernier
/// morceau au démarrage demande une liste sur laquelle on peut compter.
public enum RecentFiles {
    /// Assez pour couvrir une séance, assez peu pour tenir dans un menu.
    public static let limit = 12

    private static var file: URL? {
        Storage.root?.appendingPathComponent("recents.json")
    }

    /// Ceux qui existent encore : on ne propose pas d'ouvrir ce qui a été déplacé.
    public static func all() -> [URL] {
        guard let file, let data = try? Data(contentsOf: file),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths.map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Met un morceau en tête, sans le compter deux fois.
    ///
    /// La comparaison porte sur le chemin résolu : ouvrir le même fichier par un
    /// alias ou par un chemin relatif ne doit pas fabriquer deux entrées.
    public static func note(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var kept = [resolved] + all().filter {
            $0.resolvingSymlinksInPath().standardizedFileURL != resolved
        }
        if kept.count > limit { kept = Array(kept.prefix(limit)) }
        write(kept)
    }

    public static func clear() { write([]) }

    /// Retire un morceau de la liste.
    ///
    /// La page de lancement s'en sert : y jeter une ligne veut dire « je n'y
    /// reviendrai pas », et les pistes séparées de ce morceau — trois cents
    /// mégaoctets par morceau — s'en vont avec elle. C'est le modèle qui enchaîne
    /// les deux, ce rangement-ci ne connaît pas les pistes.
    public static func remove(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        write(all().filter {
            $0.resolvingSymlinksInPath().standardizedFileURL != resolved
        })
    }

    private static func write(_ urls: [URL]) {
        guard let file, let data = try? JSONEncoder().encode(urls.map(\.path)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// Où l'application range ce qu'elle garde d'un morceau à l'autre.
public enum Storage {
    /// `SPECTRE_RANGEMENT` déplace tout le rangement ailleurs.
    ///
    /// C'est par là que les vérifications travaillent, et ce n'est pas un confort.
    /// Elles écrivaient jusqu'ici dans le vrai dossier : elles y séparaient des
    /// morceaux d'essai, ce qui **déclenchait le plafond du cache** et faisait
    /// disparaître les pistes des vrais morceaux — des minutes de GPU effacées en
    /// lançant `check.sh`. Un harnais qui abîme ce qu'il est censé protéger n'est pas
    /// un harnais.
    public static var root: URL? {
        if let ailleurs = ProcessInfo.processInfo.environment["SPECTRE_RANGEMENT"] {
            let folder = URL(fileURLWithPath: ailleurs, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder,
                                                     withIntermediateDirectories: true)
            return folder
        }
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
        else { return nil }
        let folder = support.appendingPathComponent("Spectre", isDirectory: true)
        adoptFormerName(at: support, into: folder)
        return folder
    }

    /// Le dossier des pistes séparées.
    ///
    /// Écrit **ici et une seule fois** parce que trois choses en dépendent et qu'un
    /// désaccord entre elles serait invisible : les deux rangements — celui de macOS
    /// et celui des deux autres portages — y écrivent, et le panneau de réglages
    /// propose d'aller le voir. Le jour où l'un des trois construirait le chemin de
    /// son côté, le bouton ouvrirait un dossier vide sans rien dire.
    public static var pistes: URL? {
        guard let root else { return nil }
        let folder = root.appendingPathComponent("pistes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
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

/// Le diaporama du premier lancement a-t-il été vu ?
///
/// ─────────────────────────────────────────────────────────────────────────────
/// UN TÉMOIN SUR LE DISQUE, ET NON UN RÉGLAGE
///
/// Le témoin vivait dans `Rapports`, du temps où le premier lancement n'avait
/// qu'une phrase à dire — celle de l'envoi des pannes. Le diaporama la contient
/// désormais, avec deux autres choses à montrer, et il se montre **même quand rien
/// ne part** : le lier à l'adresse d'envoi ferait disparaître la présentation de
/// l'application chez qui construit le dépôt sans DSN.
///
/// Un fichier vide plutôt qu'une clé dans les réglages, pour que `SPECTRE_RANGEMENT`
/// suffise à donner un premier lancement neuf à qui veut le revoir — c'est ce dont
/// `LancementCheck` se sert, et c'est aussi le geste qu'on indique à quelqu'un qui
/// demande comment revoir la présentation.
///
/// Et `SPECTRE_BIENVENUE=non` le retire, comme `SPECTRE_RAPPORTS=non` retire les
/// envois : les épreuves photographient la fenêtre, et un diaporama qui la couvre
/// entièrement — c'est son métier — ne laisserait rien à regarder. Elles tournent
/// dans un rangement neuf, donc chacune serait un premier lancement.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Bienvenue {
    private static var temoin: URL? {
        Storage.root?.appendingPathComponent("bienvenue-vue", isDirectory: false)
    }

    /// Relu du disque une seule fois : les deux systèmes qui dessinent eux-mêmes
    /// leur interface posent la question à chaque image, soit cent vingt fois par
    /// seconde, et un appel de fichier par image est le genre de coût qu'on ne
    /// remarque que sur la machine la plus lente.
    private static var dejaVu: Bool?

    public static var aMontrer: Bool {
        guard ProcessInfo.processInfo.environment["SPECTRE_BIENVENUE"] != "non",
              let temoin else { return false }
        if dejaVu == nil { dejaVu = FileManager.default.fileExists(atPath: temoin.path) }
        return !(dejaVu ?? true)
    }

    /// Le diaporama a été vu. Il ne reviendra plus, sur aucun lancement.
    public static func montre() {
        dejaVu = true
        guard let temoin else { return }
        try? Data("vu\n".utf8).write(to: temoin, options: .atomic)
    }

    /// Rend au processus un premier lancement neuf. N'existe que pour le harnais,
    /// qui doit rejouer la question après avoir changé de rangement.
    public static func oublierPourLeHarnais() { dejaVu = nil }
}

/// La version dont on ne veut plus entendre parler.
///
/// « Ignorer cette version » a remplacé « Plus tard », qui ne valait que pour le
/// lancement en cours : la question revenait donc à chaque ouverture, et la seule
/// façon d'en sortir était de mettre à jour. Un numéro écrit sur le disque suffit à
/// la retirer — et la retire **pour cette version-là seulement**, ce qui est tout
/// l'intérêt : la livraison suivante repose la question, une fois.
///
/// Même forme que `Bienvenue`, et pour la même raison : les deux systèmes qui
/// dessinent eux-mêmes leur interface posent la question à chaque image.
public enum MiseAJourEcartee {
    private static var temoin: URL? {
        Storage.root?.appendingPathComponent("maj-ecartee", isDirectory: false)
    }

    /// `nil` tant qu'on n'a pas lu le disque, `""` quand il n'y a rien à y lire :
    /// deux états qu'un simple `String?` confondrait, et la confusion coûterait une
    /// lecture de fichier par image.
    private static var lue: String?

    /// Le numéro écarté, ou `nil` si aucun ne l'est.
    public static var version: String? {
        if lue == nil {
            lue = temoin.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let valeur = lue ?? ""
        return valeur.isEmpty ? nil : valeur
    }

    /// Cette version ne sera plus proposée. Écrit tout de suite, comme le témoin du
    /// diaporama : une séance qui finit mal ne doit pas reposer la question.
    public static func ecarter(_ version: String) {
        lue = version
        guard let temoin else { return }
        try? Data((version + "\n").utf8).write(to: temoin, options: .atomic)
    }

    /// Rend au processus un disque neuf. N'existe que pour le harnais.
    public static func oublierPourLeHarnais() { lue = nil }
}
