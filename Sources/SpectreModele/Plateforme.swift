import Foundation
import SpectreCore
import SpectreTextes
#if canImport(WinSDK)
import WinSDK
#endif

// Ce que le modèle d'application demande au système, et rien de plus.
//
// Tout le comportement de Spectre — le tourne-page, l'aimantation, le tracé de
// boucle, le relevé qui se refait quand on tire un curseur — vit désormais dans ce
// module, qui ne connaît aucune plateforme. Ce fichier est la liste exhaustive de
// ce qu'il ne sait pas faire seul : jouer un son, dessiner une image, ouvrir un
// fichier, séparer des pistes.
//
// La liste est courte, et c'est la mesure du travail. Une seconde plateforme n'a
// que ces protocoles à remplir pour avoir la même application, et non la même
// application réécrite — c'est exactement la dérive qui avait tué le premier
// portage : un second modèle, plus fruste, qui perdait une subtilité par semaine.

// MARK: - Les constantes du modèle

/// Ce que le modèle tient pour acquis, et qui ne dépend d'aucune plateforme.
///
/// Ces valeurs vivaient sur `AppModel`. Elles en sont sorties parce qu'un type
/// générique n'accepte pas de propriété statique stockée — mais la contrainte
/// tombait juste : « tout garder » et la hauteur de la rangée d'accords n'avaient
/// aucune raison de dépendre du moteur audio. `AppModel` les renvoie sous ses
/// anciens noms, si bien que rien de ce qui les lisait n'a changé.
public enum Reglages {
    /// Tout garder, c'est ne rien retirer.
    public static let everything = Set(Stem.separated)
    /// Hauteur de la rangée des noms d'accords, sous l'image. Partagée par le
    /// dessin et par la désignation à la souris — sans quoi la zone sensible et la
    /// zone dessinée finiraient par se décoller.
    public static let chordBandHeight = 18.0

    /// Les paliers de plafond du cache de pistes que le panneau propose.
    ///
    /// Un morceau de sept minutes coûte environ 300 Mo de pistes en vingt-quatre
    /// bits, d'où des paliers qui se comptent en morceaux plutôt qu'en puissances de
    /// deux. Ils sont ici, et non dans la couche d'une plateforme, parce que c'est le
    /// panneau qui les offre et que le panneau est le même partout.
    public static let paliersDeCache = [500_000_000, 1_000_000_000, 2_000_000_000,
                                        5_000_000_000, 10_000_000_000]
}

// MARK: - L'horloge

/// Le temps qui passe, monotone, en secondes.
///
/// Monotone et non calendaire : les animations et les échéances d'enregistrement
/// se moquent de l'heure qu'il est, et un changement d'heure ne doit pas faire
/// sauter un tourne-page. C'est la même horloge que `CACurrentMediaTime` sur macOS
/// — toutes deux comptent depuis le démarrage de la machine — de sorte que le
/// déménagement ne change rien à ce qui était réglé contre elle.
public enum Horloge {
    public static func maintenant() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Temps de processeur consommé par l'application depuis son démarrage, en
    /// secondes, tous fils confondus.
    ///
    /// Ce n'est pas du temps qui passe, c'est du temps qu'on brûle : rapporté au
    /// temps écoulé, il donne la part d'un cœur que l'application occupe — le
    /// nombre même que le gestionnaire des tâches affiche, à ceci près qu'il le
    /// divise par le nombre de fils de la machine. C'est ce que `--repos` mesure,
    /// et la seule façon d'éprouver une consommation au repos sans regarder un
    /// graphique par-dessus l'épaule de quelqu'un.
    ///
    /// Ni `clock()` ni l'horloge ci-dessus ne conviennent : le premier compte le
    /// temps de l'appelant seul sous Windows, la seconde compte les secondes qui
    /// passent, et l'on veut précisément la différence entre les deux.
    public static func tempsProcesseur() -> Double {
        #if canImport(WinSDK)
        var creation = FILETIME(), fin = FILETIME()
        var noyau = FILETIME(), utilisateur = FILETIME()
        guard GetProcessTimes(GetCurrentProcess(), &creation, &fin,
                              &noyau, &utilisateur) else { return 0 }
        // Un `FILETIME` compte les centaines de nanosecondes sur deux mots de
        // trente-deux bits, et il n'est pas aligné : le recomposer à la main est ce
        // que Microsoft demande, et non un `unsafeBitCast` vers un entier de
        // soixante-quatre bits.
        func secondes(_ t: FILETIME) -> Double {
            (Double(t.dwHighDateTime) * 4_294_967_296 + Double(t.dwLowDateTime))
                / 10_000_000
        }
        return secondes(noyau) + secondes(utilisateur)
        #else
        var t = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t) == 0 else { return 0 }
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000
        #endif
    }
}

// MARK: - Le son qui sort

/// Le moteur audio : ce qu'on entend, et où l'on en est.
///
/// `AnyObject` parce que le modèle le tient et le pilote, et parce que l'interface
/// de macOS observe ses propriétés directement — voir la note sur la généricité
/// dans `AppModel`.
public protocol LecteurAudio: AnyObject {
    var isPlaying: Bool { get }
    var duration: Double { get }
    var message: String? { get set }
    var speed: Double { get set }
    var transpose: Double { get set }
    var isNeutral: Bool { get }
    var volume: Double { get set }
    /// Position réelle de ce qui **s'entend**, et non des échantillons déjà remis
    /// au périphérique : c'est sur elle que la tête de lecture s'aligne.
    var currentTime: Double { get }
    var loop: ClosedRange<Double>? { get }

    func load(url: URL)
    /// Joue **la somme des pistes cochées, depuis la mémoire**.
    ///
    /// Remplace ce qui était un changement de fichier. Les combinaisons n'existent
    /// plus sur le disque : elles se font au moment où le son sort, à partir des
    /// quatre pistes que la banque tient. Rappeler cette méthode avec la même banque
    /// et une autre sélection ne doit rien recharger — c'est tout l'intérêt, et c'est
    /// ce qui rend la bascule d'une piste instantanée.
    func charger(_ banque: BanqueDePistes, gardant: Set<Stem>)
    func play(from time: Double?)
    func pause()
    func stop()
    func toggle(at time: Double)
    func seek(to time: Double)
    func setLoop(_ range: ClosedRange<Double>?)
    /// La bande passante suit la portion visible de l'axe des fréquences. `nil`
    /// retire les filtres du chemin plutôt que de les ouvrir en grand.
    func setBand(_ range: ClosedRange<Double>?)
}

/// La sinusoïde d'écoute : la raie qu'on désigne, et l'accord qu'on survole.
public protocol Sinusoide: AnyObject {
    /// Combien de notes peuvent sonner ensemble. Le relevé en garde les plus
    /// franches et laisse tomber le reste plutôt que de saturer.
    var voixMaximales: Int { get }
    func play(_ frequency: Double?)
    func play(chord frequencies: [Double], waveform: ToneWaveform)
    func stop()
}

// MARK: - Les réglages de l'application

/// Les réglages qui valent pour l'application entière, et non pour un morceau.
///
/// Ils ne sont pas dans la session, qui est écrite par fichier : ce sont des
/// réglages d'*algorithme*, qu'on tourne en écoutant et qu'on veut retrouver au
/// morceau suivant. Où ils sont rangés — `UserDefaults`, la base de registres, un
/// fichier — ne regarde pas le modèle.
public protocol PreferencesGlobales: AnyObject {
    /// La réattribution : l'analyse place l'énergie à sa vraie fréquence plutôt
    /// qu'au centre de la case. Changer ce réglage rend la matrice à refaire.
    var reassignment: Bool { get }
    /// Les huit nombres dont dépend ce qu'une raie doit être pour compter.
    var chords: ChordSettings { get }
    /// La note qui reçoit la première teinte du cycle des quintes.
    var hueOrigin: Int { get }
}

/// Ce que le **panneau de réglages** écrit, par opposition à ce que le modèle lit.
///
/// La distinction n'est pas une précaution : `PreferencesGlobales` est ce dont
/// `AppModel` a besoin pour analyser, et il ne doit rien pouvoir y changer. Le
/// panneau, lui, est une vue — il tourne des boutons, et c'est son métier.
///
/// Ce protocole existe parce que le panneau est **dessiné une seule fois pour
/// toutes les plateformes**. Sans lui, le dessin partagé devrait nommer la classe
/// de réglages d'un système en particulier, et il cesserait aussitôt d'être
/// partagé. Où les valeurs sont rangées — un fichier JSON, la base de registres,
/// `UserDefaults` — ne le regarde toujours pas.
public protocol ReglagesModifiables: PreferencesGlobales {
    /// La langue choisie à la main. `nil` la fait suivre le système.
    var langue: Langue? { get set }
    /// Le système de noms de notes choisi à la main. `nil` le fait suivre la langue.
    var systemeDeNotes: SystemeDeNotes? { get set }
    /// Plafond du dossier des pistes séparées, en octets.
    var cacheLimit: Int { get set }
}

// MARK: - L'image

/// Le rendu du spectrogramme, vu du modèle : il lui envoie une matrice et la
/// géométrie de son axe des fréquences, rien d'autre.
///
/// Ce que la matrice devient ensuite — une texture Metal, une `Texture2DArray`
/// Direct3D, une texture OpenGL — ne le regarde pas.
public protocol RenduSpectrogramme: AnyObject {
    var layout: BinLayout { get set }
    /// Transposition en cours, en demi-tons.
    ///
    /// Elle ne déplace rien : la matrice reste ce qu'elle est, et le nuanceur la lit
    /// au même endroit. Elle décale la seule chose qui parle de hauteur — la palette
    /// des notes —, pour qu'une raie jouée deux demi-tons plus haut porte la couleur
    /// du Ré et non celle du Do. Passer par la géométrie pour l'obtenir déplacerait
    /// aussi la référence de la pente en dB par octave, et l'image entière
    /// changerait de clarté à chaque coup de réglette.
    var demiTons: Double { get set }
    /// Incrémenté à chaque téléversement, pour que la vue sache que l'image a
    /// changé sous elle sans comparer des millions de valeurs.
    var generation: Int { get }
    func upload(_ spectrogram: Spectrogram)
}

// MARK: - Les fichiers

/// Choisir un fichier à ouvrir, par le sélecteur du système.
public protocol DialogueFichier {
    func choisirUnMorceau() -> URL?
}

/// La liste des documents récents **du système** — celle du Dock sur macOS, celle
/// de la barre des tâches sous Windows.
///
/// Elle double `RecentFiles`, qui est la nôtre et qui, elle, survit au
/// redémarrage. On nourrit tout de même celle du système : c'est elle qu'on
/// consulte par un clic droit sur l'icône, et ne pas la tenir se remarque.
public protocol DocumentsRecents {
    func noter(_ url: URL)
    func effacer()
}

/// Ce qui sort de l'application : une page dans le navigateur, un dossier dans
/// l'explorateur de fichiers.
///
/// Deux gestes, et ils ne se ressemblent que de loin : `NSWorkspace` d'un côté,
/// `ShellExecuteW` de l'autre, `xdg-open` du troisième. Le modèle, lui, ne connaît
/// que « la page des versions » et « le dossier des pistes ».
public protocol Exterieur {
    /// Ouvre une adresse dans le navigateur de l'utilisateur. Sert à la mise à
    /// jour, qui propose une page et ne télécharge rien elle-même.
    func ouvrirLaPage(_ url: URL)
    /// Montre un dossier dans l'explorateur de fichiers.
    func montrerLeDossier(_ url: URL)
}

// MARK: - La séparation

// `SeparationProgress` est dans `SpectreCore` : ce n'est pas une notion du modèle
// d'application mais du calcul lui-même, et le noyau qui découpe les tranches est
// le premier à devoir en rendre compte.

/// De quoi arrêter un calcul devenu inutile.
///
/// Fermer un morceau ne doit pas attendre la fin d'une séparation qui portait sur
/// lui : l'annulation est consultée entre deux tranches.
public protocol TravailAnnulable: AnyObject {
    var isCancelled: Bool { get }
    func cancel()
}

/// La séparation des pistes, et leur rangement — les deux ensemble, parce que le
/// modèle ne les distingue jamais.
///
/// Il demande « ce morceau est-il séparé ? », « donne-moi la somme de ces
/// pistes-là », « sépare celui-ci ». Que les pistes soient rangées dans
/// Application Support ou dans `%APPDATA%`, écrites en CAF ou en WAV flottant, ne
/// change rien à ces trois questions.
public protocol ServiceDeSeparation: AnyObject {
    /// Faux quand les poids ne sont pas là : la séparation est alors annoncée
    /// absente plutôt que tentée puis échouée.
    var modeleDisponible: Bool { get }

    /// Les **poids** sont-ils là, indépendamment du moteur qui les fait tourner ?
    ///
    /// Distinct de `modeleDisponible`, qui exige les deux. Le panneau doit pouvoir
    /// dire *lequel des deux* manque : sous Windows la séparation demande aussi ONNX
    /// Runtime, et « poids absents » envoie chercher au mauvais endroit quand c'est
    /// la bibliothèque qui n'est pas là. Sur macOS le moteur est dans le système, et
    /// les deux réponses se confondent.
    var poidsPresents: Bool { get }

    /// Ce que le dossier des pistes occupe, en octets — ce que le panneau affiche à
    /// côté du plafond.
    func tailleDuCache() -> Int

    /// Jette tout le dossier des pistes. Ce qui part se recalcule ; c'est quelques
    /// minutes, pas une perte.
    func viderLeCache()

    func estSepare(_ empreinte: String) -> Bool
    /// L'emplacement d'une piste isolée, si elle a déjà été produite.
    func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL?
    /// Relit les quatre pistes rangées et les remonte en mémoire. Le rappel arrive
    /// **sur le fil principal** ; `nil` si l'une des quatre manque ou ne se lit pas.
    ///
    /// C'est la seule lecture de fichiers de toute la séance : ce qui suit — les
    /// combinaisons qu'on écoute, les images qu'on analyse — se fait dans la banque.
    func chargerLesPistes(empreinte: String,
                          fin: @escaping (BanqueDePistes?) -> Void)
    func oublierLesPistes(empreinte: String)
    /// Repousse ce morceau en tête du cache : le plafond efface les plus vieux, et
    /// celui qu'on écoute n'est pas un vieux.
    func marquerUtilise(_ empreinte: String)

    /// Lance la séparation. Les trois rappels arrivent **sur le fil principal**.
    ///
    /// `fin` rend les pistes **dès que le réseau a fini**, sans attendre qu'elles
    /// soient sur le disque : c'est ce qui retire une vingtaine de secondes à
    /// l'attente. L'écriture en FLAC continue derrière, et `rangement` dit quand elle
    /// est finie — d'ici là, fermer l'application perdrait le calcul.
    func separer(fichier: URL, empreinte: String,
                 avancement: @escaping (SeparationProgress) -> Void,
                 fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                 rangement: @escaping (Error?) -> Void) -> TravailAnnulable
}
