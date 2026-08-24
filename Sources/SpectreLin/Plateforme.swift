import Foundation
import SpectreCore
import SpectreModele
import SpectreTextes
import SpectreSon

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
//   fait      le rendu, le décodage, la lecture, la sinusoïde, les réglages
//   étape 6   la souris, le clavier, le sélecteur de fichiers
//   étape 7   les réglages écrits sur le disque, aux emplacements XDG
//   étape 8   la séparation — ONNX Runtime
//
// **Ce qui attend ne ment pas.** Une séparation absente s'annonce absente : le
// modèle et l'interface savent déjà traiter ce cas — c'est celui d'une machine sans
// les poids — et le faire passer par ce chemin-là plutôt que par un `fatalError`
// permet à la fenêtre de s'ouvrir et de se juger dès maintenant.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Le son

// Le décodage, la lecture et la sinusoïde d'écoute **ne sont plus ici** : ils sont
// dans `SpectreSon`, où Windows les partage. Ce qui change d'un système à l'autre
// est un étage plus bas — `decodage.c` contre `mediafoundation.c`, `alsa.c` contre
// `wasapi.c` — et les deux exportent les mêmes noms.
//
// Les trois types s'appellent `DecodeurSurLePont`, `LecteurSurLePont` et
// `SinusoideSurLePont`, et c'est ce que `SpectreLinux/main.swift` assemble.

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
