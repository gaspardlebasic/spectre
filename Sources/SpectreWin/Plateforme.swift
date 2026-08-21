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
    public static var formats: [String] { ["wav"] }
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

/// Les réglages qui valent pour l'application entière.
///
/// Rangés en JSON dans `%APPDATA%\Spectre`, et non dans la base de registres :
/// `ChordSettings` sait déjà s'encoder, le dossier est celui que Windows destine
/// aux réglages d'application, et un fichier se lit quand on cherche pourquoi un
/// réglage ne revient pas.
///
/// L'écriture viendra avec l'étape 8, qui porte les sessions ; pour l'instant les
/// valeurs sont lues si le fichier existe, et sont celles d'origine sinon.
public final class PreferencesWindows: PreferencesGlobales {
    public static let partagees = PreferencesWindows()

    public private(set) var reassignment = true
    public private(set) var chords = ChordSettings()
    public private(set) var hueOrigin = 0

    private init() {
        guard let donnees = try? Data(contentsOf: Self.fichier),
              let lues = try? JSONDecoder().decode(Enregistrement.self, from: donnees)
        else { return }
        reassignment = lues.reassignment
        chords = lues.chords
        hueOrigin = lues.hueOrigin
    }

    private struct Enregistrement: Codable {
        var reassignment: Bool
        var chords: ChordSettings
        var hueOrigin: Int
    }

    static var dossier: URL {
        // `SPECTRE_RANGEMENT` détourne le rangement vers un dossier à soi : c'est ce
        // qui permet à un harnais de ne pas écraser les réglages de l'utilisateur,
        // et `check.sh` comme `essai.sh` le posent déjà sur macOS.
        if let impose = ProcessInfo.processInfo.environment["SPECTRE_RANGEMENT"] {
            return URL(fileURLWithPath: impose)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Spectre", isDirectory: true)
    }

    private static var fichier: URL { dossier.appendingPathComponent("reglages.json") }
}
