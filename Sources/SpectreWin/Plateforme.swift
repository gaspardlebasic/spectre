import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele
import SpectreSeparation
import WinSDK
import SpectreSon

// Ce que Windows répond aux protocoles du modèle.
//
// Le pendant exact de `Sources/SpectreMac/Plateforme.swift`, et il fait la même
// longueur — c'est ce qu'on cherchait en descendant `AppModel` dans le noyau : le
// comportement de l'application vit dans `SpectreModele`, et il ne reste ici que
// de la plomberie.

// MARK: - Les fichiers

extension DecodeurSurLePont {
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
        let motifs = DecodeurSurLePont.formats.map { "*.\($0)" }.joined(separator: ";")
        var filtre = [UInt16]()
        for morceau in ["Fichiers audio (\(motifs))", motifs, "Tous les fichiers", "*.*"] {
            filtre.append(contentsOf: Array(morceau.utf16))
            filtre.append(0)
        }
        filtre.append(0)

        var chemin = [UInt16](repeating: 0, count: 1024)
        var titre = Array(T(.dialogueChoisirUnMorceau).utf16)
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

/// Les réglages de l'application sous Windows.
///
/// Le magasin lui-même — le JSON, l'écriture différée, la langue qu'on repose — est
/// dans `SpectreModele/ReglagesEnregistres.swift`, partagé avec Linux : de tout ce
/// fichier, **deux choses** touchaient Windows, et ce sont les deux qui restent ici.
public enum PreferencesWindows {
    public static let partagees = ReglagesEnregistres(
        languesDuSysteme: { languesDuSysteme },
        plafondChange: { plafond in
            RangementDesPistes.plafond = plafond
            DispatchQueue.global(qos: .utility).async {
                RangementDesPistes.ranger(enGardant: nil)
            }
        })

    /// Ce que Windows dit préférer, de la plus souhaitée à la moins.
    ///
    /// `GetUserPreferredUILanguages` et non la locale de formatage : ce sont deux
    /// réglages distincts sous Windows, et c'est bien la langue *d'affichage* qu'on
    /// veut — une machine peut compter à l'allemande et s'afficher en anglais.
    ///
    /// La fonction s'appelle deux fois : une première pour savoir la taille du
    /// tampon, une seconde pour le remplir. Le résultat est une suite de chaînes
    /// terminées par un zéro, elle-même close par un zéro — c'est la convention des
    /// « multi-strings » de Win32, et il faut la défaire à la main.
    public static var languesDuSysteme: [String] {
        var nombre: ULONG = 0
        var taille: ULONG = 0
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &nombre, nil,
                                          &taille), taille > 0 else { return [] }
        var tampon = [WCHAR](repeating: 0, count: Int(taille))
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &nombre, &tampon,
                                          &taille) else { return [] }
        var etiquettes: [String] = []
        var courante: [WCHAR] = []
        for unite in tampon {
            if unite == 0 {
                if courante.isEmpty { break }        // le zéro final de la suite
                etiquettes.append(String(decoding: courante, as: UTF16.self))
                courante = []
            } else {
                courante.append(unite)
            }
        }
        return etiquettes
    }
}
