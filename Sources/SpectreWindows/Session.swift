import Foundation
import SpectreCore

/// Ce que Spectre retient d'un morceau à l'autre.
///
/// `SessionStore` fait tout le travail et ne connaît aucun système : empreinte
/// du fichier, encodage, écriture atomique. Foundation range le dossier sous
/// `%APPDATA%\Spectre` ici et sous `~/Library/Application Support/Spectre` sur
/// macOS — c'est la seule différence, et elle est invisible d'ici.
///
/// Reste la question du *quand*. Écrire à chaque image serait absurde ; écrire
/// seulement à la fermeture perdrait tout si l'application tombe. La règle est
/// donc celle de macOS : dès qu'un réglage change, on attend une seconde de
/// calme avant d'écrire, et la tête de lecture ne compte pas comme un
/// changement — elle bouge soixante fois par seconde pendant la lecture et
/// déclencherait une écriture continue à elle seule.
struct SessionSuivie {
    private var empreinte: String?
    private var enregistree: FileSession?
    private var changeeDepuis: Date?

    /// Le morceau change : on écrit ce qui reste du précédent, et on rend ce
    /// qu'on sait du nouveau.
    mutating func ouvre(_ url: URL, courante: () -> FileSession) -> FileSession? {
        ecris(courante())
        empreinte = SessionStore.fingerprint(of: url)
        enregistree = empreinte.flatMap { SessionStore.load($0) }
        changeeDepuis = nil
        return enregistree
    }

    /// À appeler à chaque image. N'écrit que si quelque chose a changé, et
    /// seulement une fois le calme revenu.
    mutating func suit(_ courante: FileSession, maintenant: Date = Date()) {
        guard empreinte != nil else { return }
        guard courante.withoutPlayhead != enregistree?.withoutPlayhead else {
            changeeDepuis = nil
            return
        }
        guard let depuis = changeeDepuis else {
            changeeDepuis = maintenant
            return
        }
        guard maintenant.timeIntervalSince(depuis) > 1 else { return }
        ecris(courante)
    }

    /// Sans attendre — à la fermeture, ou avant d'ouvrir autre chose.
    mutating func ecris(_ courante: FileSession) {
        guard let empreinte, courante != enregistree else { return }
        SessionStore.save(courante, for: empreinte)
        enregistree = courante
        changeeDepuis = nil
    }
}
