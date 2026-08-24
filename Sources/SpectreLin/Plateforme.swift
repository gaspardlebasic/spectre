import Foundation
import Observation
import SpectreCore
import SpectreModele
import SpectreTextes

// Ce que Linux répond aux protocoles du modèle — le pendant de `SpectreWin` et de
// `SpectreMac`.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUI EST VRAI ICI, ET CE QUI ATTEND SON ÉTAPE
//
// `Sources/SpectreModele/Plateforme.swift` est la liste exhaustive de ce que le
// modèle ne sait pas faire seul. Le portage la remplit dans l'ordre du plan, et ce
// fichier dit à chaque instant où il en est :
//
//   fait      le rendu (`RenduSpectre`), le décodage du WAV, les réglages
//   étape 4   le décodage de tout le reste — libsndfile et libmpg123
//   étape 5   le son qui sort — ALSA
//   étape 7   les réglages écrits sur le disque, aux emplacements XDG
//   étape 8   la séparation — ONNX Runtime
//
// **Ce qui attend ne ment pas.** Un lecteur muet dit qu'il est muet, une séparation
// absente s'annonce absente : le modèle et l'interface savent déjà traiter ces deux
// cas — c'est ce qui arrive sur une machine sans carte son ou sans les poids — et
// les faire passer par ce chemin-là plutôt que par un `fatalError` permet à la
// fenêtre de s'ouvrir et de se juger dès maintenant.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Le décodage

/// Le décodeur de Linux. À l'étape 3, le WAV et rien d'autre.
///
/// Le WAV est lu en Swift, par le noyau, exactement comme sous Windows où il passe
/// avant Media Foundation : c'est plus rapide, et surtout cela garantit qu'un
/// fichier non compressé donne le même signal sur les trois plateformes. C'est le
/// socle des vérifications croisées, et il ne coûte rien.
public struct DecodeurLinux: Décodeur {
    public init() {}

    public func charger(_ url: URL) throws -> AudioSource {
        let contenu = try WAVFile.read(at: url)
        guard !contenu.mono.isEmpty else { throw AudioSource.Failure.empty(url) }
        return AudioSource(url: url,
                           sampleRate: contenu.sampleRate,
                           frameCount: contenu.frameCount,
                           mono: contenu.mono,
                           fingerprint: SessionStore.fingerprint(of: url))
    }
}

// MARK: - Le son qui sort

/// Le lecteur de Linux — **muet jusqu'à l'étape 5**.
///
/// Il n'y a pas de faux-semblant ici : la position ne bouge pas parce que rien ne
/// joue. Le modèle traite déjà ce cas, qui est celui d'une machine sans carte son.
///
/// La barre d'état ne l'annonce pas encore : le dire demanderait une clé dans les
/// cinq catalogues, pour un état qui disparaît à l'étape 5. Ce qui se voit d'ici
/// là, c'est simplement qu'appuyer sur lecture ne fait rien.
@Observable public final class LecteurLinux: LecteurAudio {
    public init() {}

    public private(set) var isPlaying = false
    public var duration = 0.0
    public var message: String?
    public var speed = 1.0
    public var transpose = 0.0
    public var isNeutral: Bool { speed == 1 && transpose == 0 }
    public var volume = 1.0
    public private(set) var currentTime = 0.0
    public private(set) var loop: ClosedRange<Double>?

    public func load(url: URL) {}
    public func charger(_ banque: BanqueDePistes, gardant: Set<Stem>) {}
    public func play(from time: Double?) { if let time { currentTime = time } }
    public func pause() {}
    public func stop() { currentTime = 0 }
    public func toggle(at time: Double) { currentTime = time }
    public func seek(to time: Double) { currentTime = time }
    public func setLoop(_ range: ClosedRange<Double>?) { loop = range }
    public func setBand(_ range: ClosedRange<Double>?) {}
}

/// La sinusoïde d'écoute — muette elle aussi, et pour la même étape.
public final class SinusoideLinux: Sinusoide {
    public init() {}
    public var voixMaximales: Int { 6 }
    public func play(_ frequency: Double?) {}
    public func play(chord frequencies: [Double], waveform: ToneWaveform) {}
    public func stop() {}
}

// MARK: - Les fichiers

/// Le sélecteur de fichiers — **étape 6**, avec le reste des gestes.
///
/// SDL3 en donne un qui passe par le portail XDG quand il est là, donc par le
/// sélecteur du bureau et non par un dialogue à nous. Il est asynchrone, ce que ce
/// protocole n'est pas encore ; les deux se rejoindront quand la boucle
/// d'évènements existera.
public struct DialogueLinux: DialogueFichier {
    public init() {}
    public func choisirUnMorceau() -> URL? { nil }
}

/// La liste des documents récents du système — **étape 7**.
///
/// Sous Linux c'est `~/.local/share/recently-used.xbel`, que les bureaux lisent.
/// `RecentFiles`, qui est la nôtre et qui survit au redémarrage, marche déjà : ce
/// qui manque ici ne fait que priver le menu du bureau.
public struct RecentsLinux: DocumentsRecents {
    public init() {}
    public func noter(_ url: URL) {}
    public func effacer() {}
}

// MARK: - Les réglages

/// Les réglages qui valent pour l'application entière.
///
/// **En mémoire jusqu'à l'étape 7**, où ils prendront un fichier aux emplacements
/// XDG. Tout le reste est vrai : le panneau les tourne, la langue s'applique, et le
/// choix se voit à l'image suivante.
public final class PreferencesLinux: ReglagesModifiables {
    public static let partagees = PreferencesLinux()

    /// La réattribution : une constante, comme sur les deux autres plateformes.
    /// Elle est ce qui fait qu'un partiel tient sur une ligne au lieu de trois, et
    /// rien de ce qu'on gagne à l'éteindre ne vaut l'image qu'elle rend.
    public let reassignment = true
    public let chords = ChordSettings()
    public var hueOrigin = 0

    public var langue: Langue? {
        didSet {
            guard langue != oldValue else { return }
            appliquerLaLangue()
        }
    }
    public var systemeDeNotes: SystemeDeNotes? {
        didSet {
            guard systemeDeNotes != oldValue else { return }
            appliquerLaLangue()
        }
    }
    public var cacheLimit = 1_000_000_000

    private init() {}

    private func appliquerLaLangue() {
        Textes.demarrer(choix: langue, notes: systemeDeNotes,
                        etiquettesDuSysteme: Self.languesDuSysteme)
    }

    /// Ce que le système dit préférer, de la plus souhaitée à la moins.
    ///
    /// `LANGUAGE` d'abord — c'est la variable que les bureaux posent pour dire une
    /// *liste* — puis `LC_ALL`, `LC_MESSAGES` et `LANG`, qui n'en portent qu'une.
    /// Les suffixes de jeu de caractères et de variante se retirent : `fr_FR.UTF-8`
    /// est une étiquette de locale, `fr-FR` une étiquette de langue.
    public static var languesDuSysteme: [String] {
        let environnement = ProcessInfo.processInfo.environment
        var brutes: [String] = []
        if let liste = environnement["LANGUAGE"], !liste.isEmpty {
            brutes += liste.split(separator: ":").map(String.init)
        }
        for nom in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let valeur = environnement[nom], !valeur.isEmpty { brutes.append(valeur) }
        }
        var etiquettes: [String] = []
        for brute in brutes {
            let sansJeu = brute.split(separator: ".").first.map(String.init) ?? brute
            let sansVariante = sansJeu.split(separator: "@").first.map(String.init) ?? sansJeu
            let etiquette = sansVariante.replacingOccurrences(of: "_", with: "-")
            if etiquette != "C" && etiquette != "POSIX" && !etiquettes.contains(etiquette) {
                etiquettes.append(etiquette)
            }
        }
        return etiquettes
    }

    /// Sans effet tant que les réglages ne sont pas écrits — étape 7. La fenêtre
    /// l'appelle déjà, pour que le jour venu il n'y ait rien à brancher.
    public func enregistrerSiBesoin() {}
    public func enregistrerMaintenant() {}
}

// MARK: - La séparation

/// De quoi arrêter un calcul qui n'a pas commencé.
public final class TravailLinux: TravailAnnulable {
    public init() {}
    public private(set) var isCancelled = false
    public func cancel() { isCancelled = true }
}

/// Le rangement des pistes séparées — **étape 8**.
///
/// `modeleDisponible` est faux, et c'est exactement ce que répond une machine où les
/// poids ne sont pas là : l'interface annonce la séparation absente au lieu de la
/// tenter puis d'échouer. Rien à traiter de particulier, donc, le jour où ce sera
/// vrai.
public final class RangementLinux: ServiceDeSeparation {
    public init() {}

    public var modeleDisponible: Bool { false }
    public var poidsPresents: Bool { false }
    public func tailleDuCache() -> Int { 0 }
    public func viderLeCache() {}

    public func estSepare(_ empreinte: String) -> Bool { false }
    public func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? { nil }
    public func chargerLesPistes(empreinte: String,
                                 fin: @escaping (BanqueDePistes?) -> Void) {
        DispatchQueue.main.async { fin(nil) }
    }
    public func oublierLesPistes(empreinte: String) {}
    public func marquerUtilise(_ empreinte: String) {}

    public func separer(fichier: URL, empreinte: String,
                        avancement: @escaping (SeparationProgress) -> Void,
                        fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                        rangement: @escaping (Error?) -> Void) -> TravailAnnulable {
        let travail = TravailLinux()
        DispatchQueue.main.async {
            fin(.failure(SeparationFailure.modelMissing))
        }
        return travail
    }
}
