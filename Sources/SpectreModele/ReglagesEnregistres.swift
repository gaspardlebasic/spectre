import Foundation
import SpectreCore
import SpectreTextes

// Les réglages qui valent pour l'application entière, et qui se retrouvent au
// lancement suivant.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE FICHIER EST PARTAGÉ
//
// Il vivait dans `SpectreWin`, et le portage Linux allait le recopier. En regardant
// ce qu'il touchait vraiment du système : **deux choses**. La liste des langues que
// l'utilisateur préfère — `GetUserPreferredUILanguages` là, les variables
// d'environnement ici — et le plafond du cache, qu'il faut reposer sur le rangement
// des pistes, lequel n'est pas le même des deux côtés.
//
// Les deux sont devenues des paramètres de l'initialiseur. Tout le reste — le JSON,
// l'écriture différée, le décodage tolérant, la langue qu'on repose — n'a pas bougé
// d'une ligne et n'est plus écrit qu'une fois.
//
// Où le fichier est rangé ne demande rien de particulier non plus : `Storage.root`
// donne déjà le bon dossier sur les trois systèmes — Application Support sur macOS,
// `%APPDATA%` sous Windows, `~/.local/share` sous Linux, qui est l'emplacement XDG.
//
// POURQUOI L'ÉCRITURE EST DIFFÉRÉE
//
// Tirer un curseur change la valeur à chaque image, soit cent vingt fois par
// seconde. Écrire le fichier à chaque fois ferait payer un aller-retour au disque
// pour un réglage qu'on est encore en train de chercher — et le laisserait à moitié
// écrit si la fenêtre se fermait au mauvais moment.
//
// On marque donc, et l'on écrit quand la valeur a cessé de bouger. C'est exactement
// ce que fait `AppModel.autosave` pour les sessions, et pour la même raison.
// `enregistrerMaintenant` court-circuite l'attente à la fermeture.
// ─────────────────────────────────────────────────────────────────────────────

public final class ReglagesEnregistres: ReglagesModifiables {
    /// Ce que le système dit préférer, de la plus souhaitée à la moins. Rendu par la
    /// plateforme, qui est la seule à savoir le demander.
    private let languesDuSysteme: () -> [String]

    /// Le plafond du cache, reposé sur le rangement des pistes de la plateforme.
    ///
    /// Le baisser sans faire le ménage ne servirait à rien avant la prochaine
    /// séparation — c'est-à-dire au moment où l'on aurait justement voulu de la
    /// place. C'est donc au rangement de réagir, et il n'est pas le même partout.
    private let plafondChange: (Int) -> Void

    /// La réattribution spectrale — voir `AnalysisSettings.reassignment`.
    ///
    /// Une constante, et non un réglage : elle est ce qui fait qu'un partiel tient
    /// sur une ligne au lieu de trois, et rien de ce qu'on gagne à l'éteindre — un
    /// peu de temps d'analyse, un fond moins granuleux — ne vaut l'image qu'elle
    /// rend. Un interrupteur qu'on ne touche jamais est un interrupteur qui coûte à
    /// lire.
    public let reassignment = true

    /// Les réglages du relevé d'accords, à leurs valeurs d'origine.
    ///
    /// Ils ont eu leur section dans le panneau — douze curseurs et leurs
    /// explications. Ce sont des poids de fonction de coût : on ne les règle pas, on
    /// les accorde, et les accorder demande d'entendre ce qu'ils changent sur
    /// plusieurs morceaux. Les valeurs d'origine sont celles qui ont gagné cet
    /// accord ; les exposer ne servait qu'à les défaire.
    public let chords = ChordSettings()

    /// Classe de hauteur qui reçoit la première teinte du cycle des quintes. Relue
    /// d'une séance à l'autre, mais réglable seulement depuis la fenêtre ⌘, du Mac.
    public var hueOrigin = 0 { didSet { marquer(hueOrigin != oldValue) } }

    /// La langue choisie à la main. `nil` — le défaut — la fait suivre le système.
    ///
    /// Reposer `Textes` à chaque écriture, et pas seulement l'enregistrer : le
    /// catalogue est un état global que lisent des étages qui ne connaissent pas
    /// cette classe. Le panneau étant redessiné à chaque image, le changement se voit
    /// à l'image suivante.
    public var langue: Langue? {
        didSet {
            guard langue != oldValue else { return }
            marquer(true)
            appliquerLaLangue()
        }
    }

    /// Le système de noms de notes choisi à la main. `nil` le fait suivre la langue.
    public var systemeDeNotes: SystemeDeNotes? {
        didSet {
            guard systemeDeNotes != oldValue else { return }
            marquer(true)
            appliquerLaLangue()
        }
    }

    /// Plafond du dossier des pistes séparées, en octets.
    public var cacheLimit = 1_000_000_000 {
        didSet {
            guard cacheLimit != oldValue else { return }
            marquer(true)
            plafondChange(cacheLimit)
        }
    }

    /// Depuis quand un réglage a changé sans avoir été écrit. `nil` : rien à écrire.
    private var enAttenteDepuis: Double?

    public init(languesDuSysteme: @escaping () -> [String],
                plafondChange: @escaping (Int) -> Void) {
        self.languesDuSysteme = languesDuSysteme
        self.plafondChange = plafondChange

        guard let donnees = try? Data(contentsOf: Self.fichier),
              let lues = try? JSONDecoder().decode(Enregistrement.self, from: donnees)
        else { return }
        hueOrigin = lues.hueOrigin
        cacheLimit = lues.cacheLimit
        langue = lues.langue.flatMap(Langue.init(rawValue:))
        systemeDeNotes = lues.systemeDeNotes.flatMap(SystemeDeNotes.init(rawValue:))
        // Posés à la main : les observateurs de propriété ne sont pas appelés pour
        // une affectation faite dans l'initialiseur de la classe qui les déclare.
        // Sans ces deux lignes, le plafond et la langue relus du fichier ne
        // s'appliqueraient qu'à la première fois où l'on y toucherait — c'est-à-dire
        // jamais chez qui les a réglés une fois.
        plafondChange(cacheLimit)
        appliquerLaLangue()
        // Relire n'est pas modifier : sans cela, le premier tour de boucle
        // réécrirait le fichier avec ce qu'il vient d'en sortir.
        enAttenteDepuis = nil
    }

    public func appliquerLaLangue() {
        Textes.demarrer(choix: langue, notes: systemeDeNotes,
                        etiquettesDuSysteme: languesDuSysteme())
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
        let contenu = Enregistrement(hueOrigin: hueOrigin, cacheLimit: cacheLimit,
                                     langue: langue?.rawValue,
                                     systemeDeNotes: systemeDeNotes?.rawValue)
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
    /// `DisplaySettings` : un réglage ajouté ne doit pas effacer en silence tous ceux
    /// qui étaient déjà écrits.
    ///
    /// La tolérance vaut aussi dans l'autre sens : les fichiers déjà écrits portent
    /// `reassignment` et `chords`, qui ne sont plus des réglages. Les clés inconnues
    /// sont simplement ignorées, et le fichier se rangera tout seul à la première
    /// écriture.
    private struct Enregistrement: Codable {
        var hueOrigin: Int
        var cacheLimit: Int
        /// Absents quand le réglage suit le système : « pas de choix » et « le
        /// premier choix de la liste » ne sont pas la même chose, et un entier ne
        /// sait pas les distinguer.
        var langue: String?
        var systemeDeNotes: Int?

        init(hueOrigin: Int, cacheLimit: Int, langue: String?, systemeDeNotes: Int?) {
            self.hueOrigin = hueOrigin
            self.cacheLimit = cacheLimit
            self.langue = langue
            self.systemeDeNotes = systemeDeNotes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hueOrigin = try c.decodeIfPresent(Int.self, forKey: .hueOrigin) ?? 0
            cacheLimit = try c.decodeIfPresent(Int.self, forKey: .cacheLimit)
                ?? 1_000_000_000
            langue = try c.decodeIfPresent(String.self, forKey: .langue)
            systemeDeNotes = try c.decodeIfPresent(Int.self, forKey: .systemeDeNotes)
        }
    }

    /// Le même dossier que les sessions et les morceaux récents — donc le même
    /// `SPECTRE_RANGEMENT`, qui est ce par quoi un harnais évite d'écraser les
    /// réglages de l'utilisateur.
    public static var dossier: URL {
        Storage.root ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public static var fichier: URL { dossier.appendingPathComponent("reglages.json") }
}
