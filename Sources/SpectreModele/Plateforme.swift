import Foundation
import SpectreCore

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
    /// Change de fichier sans arrêter le moteur, quand le format s'y prête. Rend
    /// `false` s'il a fallu renoncer — l'appelant recharge alors franchement.
    func replace(with url: URL) -> Bool
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

// MARK: - L'image

/// Le rendu du spectrogramme, vu du modèle : il lui envoie une matrice et la
/// géométrie de son axe des fréquences, rien d'autre.
///
/// Ce que la matrice devient ensuite — une texture Metal, une `Texture2DArray`
/// Direct3D, une texture OpenGL — ne le regarde pas.
public protocol RenduSpectrogramme: AnyObject {
    var layout: BinLayout { get set }
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

    func estSepare(_ empreinte: String) -> Bool
    /// L'emplacement d'une piste isolée, si elle a déjà été produite.
    func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL?
    /// La somme des pistes demandées, fabriquée si besoin puis gardée.
    func urlCombinee(_ pistes: Set<Stem>, empreinte: String) throws -> URL?
    func oublierLesPistes(empreinte: String)
    /// Repousse ce morceau en tête du cache : le plafond efface les plus vieux, et
    /// celui qu'on écoute n'est pas un vieux.
    func marquerUtilise(_ empreinte: String)

    /// Lance la séparation. Les deux rappels arrivent **sur le fil principal**.
    func separer(fichier: URL, empreinte: String,
                 avancement: @escaping (SeparationProgress) -> Void,
                 fin: @escaping (Result<Void, Error>) -> Void) -> TravailAnnulable
}
