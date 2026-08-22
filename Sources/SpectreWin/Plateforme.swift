import Foundation
import SpectreCore
import SpectreModele
import WinSDK

// Ce que Windows répond aux protocoles du modèle.
//
// Le pendant exact de `Sources/SpectreMac/Plateforme.swift`, et il fait la même
// longueur — c'est ce qu'on cherchait en descendant `AppModel` dans le noyau : le
// comportement de l'application vit dans `SpectreModele`, et il ne reste ici que
// de la plomberie.

// MARK: - Les fichiers

extension DecodeurWindows {
    /// Les extensions que ce décodeur ouvre.
    ///
    /// Elles vivent à côté du décodeur plutôt que dans le dialogue : c'est ce qui
    /// empêche celui-ci de proposer un format que le décodeur refuserait ensuite.
    ///
    /// Media Foundation lit tout cela d'origine sur n'importe quelle installation
    /// de Windows 10 ou 11 — FLAC et ALAC compris depuis Windows 10, ce qui évite
    /// d'embarquer un décodeur de plus. La liste est celle du `Décodeur`, pas celle
    /// du système : ajouter une extension ici sans que Media Foundation la lise
    /// ferait proposer un fichier qu'on refuserait ensuite.
    public static var formats: [String] {
        ["wav", "mp3", "m4a", "aac", "mp4", "wma", "flac", "aif", "aiff"]
    }
}

/// Le sélecteur de fichiers du système.
///
/// `GetOpenFileNameW` plutôt que l'`IFileOpenDialog` du modèle COM : le second est
/// ce que Windows 11 recommande et donne le dialogue moderne, mais il s'appelle par
/// tables virtuelles, ce que Swift ne fait pas sans pont C. Le premier est
/// redirigé vers le même dialogue par le système depuis Vista — on obtient donc
/// l'apparence moderne sans écrire une ligne de COM.
public struct DialogueWindows: DialogueFichier {
    /// La fenêtre à qui rattacher le dialogue, pour qu'il soit modal et centré.
    private let fenetre: HWND?

    public init(fenetre: HWND? = nil) {
        self.fenetre = fenetre
    }

    public func choisirUnMorceau() -> URL? {
        // Le filtre est fait de paires terminées par un zéro, la liste entière
        // fermée par un zéro de plus. Une chaîne Swift ne peut pas porter cela : on
        // assemble donc les unités UTF-16 à la main.
        let motifs = DecodeurWindows.formats.map { "*.\($0)" }.joined(separator: ";")
        var filtre = [UInt16]()
        for morceau in ["Fichiers audio (\(motifs))", motifs, "Tous les fichiers", "*.*"] {
            filtre.append(contentsOf: Array(morceau.utf16))
            filtre.append(0)
        }
        filtre.append(0)

        var chemin = [UInt16](repeating: 0, count: 1024)
        var titre = Array("Choisir un fichier audio à transcrire".utf16)
        titre.append(0)

        var choix = OPENFILENAMEW()
        choix.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        choix.hwndOwner = fenetre
        choix.nMaxFile = DWORD(chemin.count)
        // `OFN_NOCHANGEDIR` : sans lui, le dialogue laisse le processus dans le
        // dossier visité, et tout chemin relatif écrit ensuite — un cache, un
        // journal — atterrit chez l'utilisateur au lieu du dossier de travail.
        choix.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR
                            | OFN_EXPLORER)

        let ouvert = filtre.withUnsafeBufferPointer { f -> Bool in
            titre.withUnsafeMutableBufferPointer { t -> Bool in
                chemin.withUnsafeMutableBufferPointer { c -> Bool in
                    choix.lpstrFilter = f.baseAddress
                    choix.lpstrFile = c.baseAddress
                    choix.lpstrTitle = UnsafePointer(t.baseAddress)
                    return GetOpenFileNameW(&choix)
                }
            }
        }
        guard ouvert else { return nil }
        let texte = String(decoding: chemin.prefix { $0 != 0 }, as: UTF16.self)
        return texte.isEmpty ? nil : URL(fileURLWithPath: texte)
    }
}

/// La liste de raccourci de la barre des tâches.
///
/// Elle double `RecentFiles`, qui est la nôtre et qui survit au redémarrage. On
/// nourrit tout de même celle du système : c'est elle qu'on consulte par un clic
/// droit sur l'icône épinglée, et ne pas la tenir se remarque.
public struct RecentsWindows: DocumentsRecents {
    public init() {}

    public func noter(_ url: URL) {
        url.path.withCString(encodedAs: UTF16.self) { chemin in
            SHAddToRecentDocs(UINT(SHARD_PATHW.rawValue),
                              UnsafeRawPointer(chemin))
        }
    }

    public func effacer() {
        // Un pointeur nul vide la liste entière : c'est documenté ainsi, et il n'y
        // a pas d'autre chemin pour l'effacer sans toucher au registre.
        SHAddToRecentDocs(UINT(SHARD_PATHW.rawValue), nil)
    }
}

// MARK: - Les réglages

/// Les réglages qui valent pour l'application entière, et non pour un morceau.
///
/// Rangés en JSON dans le dossier de `Storage`, et non dans la base de registres :
/// `ChordSettings` sait déjà s'encoder, c'est là que vivent déjà les sessions et la
/// liste des morceaux récents, et un fichier se lit quand on cherche pourquoi un
/// réglage ne revient pas. Le pendant macOS, lui, passe par `UserDefaults` — ce que
/// le protocole a justement pour rôle de ne pas faire savoir au modèle.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI L'ÉCRITURE EST DIFFÉRÉE
///
/// Tirer un curseur change la valeur à chaque image, soit cent vingt fois par
/// seconde. Écrire le fichier à chaque fois ferait payer un aller-retour au disque
/// pour un réglage qu'on est encore en train de chercher — et le laisserait à
/// moitié écrit si la fenêtre se fermait au mauvais moment.
///
/// On marque donc, et l'on écrit quand la valeur a cessé de bouger. C'est
/// exactement ce que fait `AppModel.autosave` pour les sessions, et pour la même
/// raison. `enregistrerMaintenant` court-circuite l'attente à la fermeture.
/// ─────────────────────────────────────────────────────────────────────────────
public final class PreferencesWindows: PreferencesGlobales {
    public static let partagees = PreferencesWindows()

    public var reassignment = true { didSet { marquer(reassignment != oldValue) } }
    public var chords = ChordSettings() { didSet { marquer(chords != oldValue) } }
    public var hueOrigin = 0 { didSet { marquer(hueOrigin != oldValue) } }

    /// Plafond du dossier des pistes séparées, en octets.
    ///
    /// Hors du protocole, contrairement aux trois autres : le modèle ne demande
    /// jamais la taille d'un cache, c'est le rangement qui la lit. Le réglage vit ici
    /// parce que c'est ici qu'on le retrouve d'une séance à l'autre, et il est reposé
    /// sur le rangement à chaque écriture — le baisser sans faire le ménage ne
    /// servirait à rien avant la prochaine séparation, c'est-à-dire au moment où l'on
    /// aurait justement voulu de la place.
    public var cacheLimit = 1_000_000_000 {
        didSet {
            guard cacheLimit != oldValue else { return }
            marquer(true)
            RangementDesPistes.plafond = cacheLimit
            DispatchQueue.global(qos: .utility).async {
                RangementDesPistes.ranger(enGardant: nil)
            }
        }
    }

    /// Les paliers proposés. Un morceau de sept minutes coûte environ 300 Mo de
    /// pistes en vingt-quatre bits, d'où des paliers qui se comptent en morceaux
    /// plutôt qu'en puissances de deux.
    public static let paliersDeCache = [500_000_000, 1_000_000_000, 2_000_000_000,
                                        5_000_000_000, 10_000_000_000]

    /// Depuis quand un réglage a changé sans avoir été écrit. `nil` : rien à écrire.
    private var enAttenteDepuis: Double?

    private init() {
        guard let donnees = try? Data(contentsOf: Self.fichier),
              let lues = try? JSONDecoder().decode(Enregistrement.self, from: donnees)
        else { return }
        reassignment = lues.reassignment
        chords = lues.chords
        hueOrigin = lues.hueOrigin
        cacheLimit = lues.cacheLimit
        // Posé à la main : les observateurs de propriété ne sont pas appelés pour une
        // affectation faite dans l'initialiseur de la classe qui les déclare. Sans
        // cette ligne, le plafond relu du fichier ne serait appliqué qu'à la première
        // fois où l'on y toucherait — c'est-à-dire jamais chez qui l'a réglé une fois.
        RangementDesPistes.plafond = cacheLimit
        // Relire n'est pas modifier : sans cela, le premier tour de boucle
        // réécrirait le fichier avec ce qu'il vient d'en sortir.
        enAttenteDepuis = nil
    }

    private func marquer(_ aChange: Bool) {
        guard aChange else { return }
        if enAttenteDepuis == nil { enAttenteDepuis = Horloge.maintenant() }
    }

    /// À appeler une fois par image. Écrit quand plus rien ne bouge depuis une
    /// demi-seconde.
    public func enregistrerSiBesoin() {
        guard let depuis = enAttenteDepuis,
              Horloge.maintenant() - depuis > 0.5 else { return }
        enregistrerMaintenant()
    }

    /// Écrit sans attendre — la fenêtre se ferme, et quitter ne doit rien coûter.
    public func enregistrerMaintenant() {
        guard enAttenteDepuis != nil else { return }
        enAttenteDepuis = nil
        let contenu = Enregistrement(reassignment: reassignment, chords: chords,
                                     hueOrigin: hueOrigin, cacheLimit: cacheLimit)
        let encodeur = JSONEncoder()
        // Lisible : ce fichier est le seul endroit où l'on peut aller voir pourquoi
        // un réglage ne revient pas, et une ligne unique de mille caractères ne s'y
        // prête pas.
        encodeur.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let donnees = try? encodeur.encode(contenu) else { return }
        try? FileManager.default.createDirectory(at: Self.dossier,
                                                 withIntermediateDirectories: true)
        try? donnees.write(to: Self.fichier, options: .atomic)
    }

    /// Décodage tolérant aux champs manquants, pour la raison qui vaut déjà dans
    /// `DisplaySettings` : un réglage ajouté ne doit pas effacer en silence tous
    /// ceux qui étaient déjà écrits.
    private struct Enregistrement: Codable {
        var reassignment: Bool
        var chords: ChordSettings
        var hueOrigin: Int
        var cacheLimit: Int

        init(reassignment: Bool, chords: ChordSettings, hueOrigin: Int, cacheLimit: Int) {
            self.reassignment = reassignment
            self.chords = chords
            self.hueOrigin = hueOrigin
            self.cacheLimit = cacheLimit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reassignment = try c.decodeIfPresent(Bool.self, forKey: .reassignment) ?? true
            chords = try c.decodeIfPresent(ChordSettings.self, forKey: .chords)
                ?? ChordSettings()
            hueOrigin = try c.decodeIfPresent(Int.self, forKey: .hueOrigin) ?? 0
            cacheLimit = try c.decodeIfPresent(Int.self, forKey: .cacheLimit)
                ?? 1_000_000_000
        }
    }

    /// Le même dossier que les sessions et les morceaux récents — donc le même
    /// `SPECTRE_RANGEMENT`, qui est ce par quoi un harnais évite d'écraser les
    /// réglages de l'utilisateur.
    static var dossier: URL {
        Storage.root ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static var fichier: URL { dossier.appendingPathComponent("reglages.json") }
}
