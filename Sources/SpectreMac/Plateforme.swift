import AppKit
import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele
import UniformTypeIdentifiers

// Ce que macOS répond aux protocoles du modèle.
//
// Le fichier est court, et c'est le résultat qu'on cherchait : le comportement de
// l'application vit dans `SpectreModele`, et il ne reste ici que de la plomberie.
// Le pendant Windows de ce fichier fera la même longueur.

// MARK: - Le son

extension Player: LecteurAudio {}

extension ToneGenerator: Sinusoide {
    public var voixMaximales: Int { Self.maxVoices }
}

// MARK: - L'image

extension SpectrogramRenderer: RenduSpectrogramme {}

// MARK: - Les fichiers

/// Le sélecteur de fichiers du système.
public struct DialogueApple: DialogueFichier {
    public init() {}

    public func choisirUnMorceau() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = T(.dialogueOuvrir)
        panel.message = T(.dialogueChoisirUnMorceau)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Les documents récents du Dock et du menu Pomme.
///
/// Ils doublent `RecentFiles`, qui est la nôtre : celle d'AppKit ne survit pas au
/// redémarrage dans une application qui n'est pas bâtie sur son architecture de
/// documents — vérifié, `NSRecentDocumentRecords` restait vide après une ouverture
/// et une sortie propre. On la nourrit tout de même, parce que c'est elle qu'on
/// consulte par un clic droit sur l'icône du Dock.
public struct RecentsApple: DocumentsRecents {
    public init() {}

    public func noter(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    public func effacer() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

/// Le navigateur et le Finder.
///
/// Deux lignes, et pas de repli : `NSWorkspace` est là depuis toujours, et un
/// échec — une adresse que rien ne sait ouvrir — ne casse rien qui compte.
public struct ExterieurApple: Exterieur {
    public init() {}

    public func ouvrirLaPage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// `activateFileViewerSelecting` et non `open` : on veut le dossier **montré et
    /// désigné** dans une fenêtre du Finder, ce qui est le geste de « Afficher dans
    /// le Finder » ; `open` sur un dossier l'ouvre et laisse chercher lequel c'est.
    public func montrerLeDossier(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - La séparation

extension SeparationJob: TravailAnnulable {}

/// Le rangement des pistes et leur fabrication, réunis comme le modèle les voit.
///
/// Il ne distingue jamais les deux : il demande si un morceau est séparé, la somme
/// de telles pistes, ou le lancement d'un calcul. Que les pistes soient rangées
/// dans Application Support et écrites en CAF ne le regarde pas.
public final class RangementApple: ServiceDeSeparation {
    public init() {}

    public var modeleDisponible: Bool { StemStore.hasModel }
    /// Le moteur d'inférence vient avec le système : rien ne peut manquer d'autre
    /// que les poids, et les deux réponses se confondent.
    public var poidsPresents: Bool { StemStore.hasModel }
    public func tailleDuCache() -> Int { StemStore.cacheSize() }
    public func viderLeCache() { StemStore.emptyCache() }

    public func estSepare(_ empreinte: String) -> Bool {
        StemStore.isSeparated(empreinte)
    }

    public func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? {
        StemStore.url(piste, for: empreinte)
    }

    public func chargerLesPistes(empreinte: String,
                                 fin: @escaping (BanqueDePistes?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let banque = try? StemStore.banque(pour: empreinte)
            DispatchQueue.main.async { fin(banque) }
        }
    }

    public func oublierLesPistes(empreinte: String) {
        StemStore.removeStems(for: empreinte)
    }

    public func marquerUtilise(_ empreinte: String) {
        StemStore.markUsed(empreinte)
    }

    public func separer(fichier: URL, empreinte: String,
                        avancement: @escaping (SeparationProgress) -> Void,
                        fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                        rangement: @escaping (Error?) -> Void) -> TravailAnnulable {
        let travail = SeparationJob()
        travail.run(fileAt: fichier, fingerprint: empreinte,
                    separator: DemucsSeparator(),
                    progress: avancement, completion: fin, stored: rangement)
        return travail
    }
}
