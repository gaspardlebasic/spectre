import CSDL
import Foundation
import SpectreCore
import SpectreModele
import SpectreTextes
import SpectreSeparation
import SpectreSocle
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
//   fait      le rendu, le décodage, la lecture, la sinusoïde, les gestes,
//             le sélecteur de fichiers, les réglages, les récents du bureau,
//             et la séparation, par ONNX Runtime
//
// Il ne reste donc, dans ce fichier, que ce que Linux répond seul : le sélecteur de
// fichiers, les récents du bureau, et la liste des langues préférées. Tout le reste
// est monté d'un étage au fil des étapes.
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

/// Le sélecteur de fichiers du bureau.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI SDL PLUTÔT QU'UN DIALOGUE À NOUS
///
/// SDL3 parle au **portail XDG** — `org.freedesktop.portal.FileChooser` — quand il
/// est là, et c'est le seul chemin qui marche partout : sous Wayland comme sous X11,
/// dans un Flatpak comme hors de lui, avec le sélecteur de GNOME chez qui a GNOME et
/// celui de KDE chez qui a KDE. Quand le portail manque — une machine sans bureau —
/// SDL se rabat sur `zenity`, et le dit s'il n'est pas là non plus.
///
/// **La conversion d'asynchrone en synchrone se fait ici.** Le protocole du modèle
/// rend une URL ; SDL rappelle une fonction plus tard. On tourne donc la boucle
/// d'évènements jusqu'à la réponse — c'est ce que fait aussi `GetOpenFileNameW` sous
/// Windows, à ceci près que Win32 le fait pour nous et sans le dire.
/// ─────────────────────────────────────────────────────────────────────────────
public struct DialogueLinux: DialogueFichier {
    public init() {}

    /// Ce que le rappel dépose, et que la boucle attend.
    private final class Reponse {
        var choisi: URL?
        var repondu = false
    }

    public func choisirUnMorceau() -> URL? {
        let reponse = Reponse()
        let boite = Unmanaged.passRetained(reponse).toOpaque()

        // Les extensions que les deux décodeurs savent lire. Le filtre est une
        // indication, pas une barrière : le sélecteur laisse toujours choisir « tous
        // les fichiers », et le décodage reconnaît de toute façon par le contenu.
        let extensions = "wav;aiff;aif;flac;ogg;opus;mp3;m4a;aac"
        return extensions.withCString { motifs in
            T(.dialogueChoisirUnMorceau).withCString { titre in
                var filtre = SDL_DialogFileFilter(name: titre, pattern: motifs)
                SDL_ShowOpenFileDialog({ brut, fichiers, _ in
                    guard let brut else { return }
                    let reponse = Unmanaged<Reponse>.fromOpaque(brut)
                        .takeRetainedValue()
                    // `fichiers` nul veut dire une erreur ; un premier élément nul,
                    // que l'utilisateur a renoncé. Les deux se traitent pareil ici —
                    // on n'ouvre rien — mais ce ne sont pas la même chose, et la
                    // première mérite d'être dite.
                    if fichiers == nil {
                        Journal.erreur("le sélecteur de fichiers : "
                                       + String(cString: SDL_GetError()))
                    } else if let premier = fichiers![0] {
                        reponse.choisi = URL(fileURLWithPath: String(cString: premier))
                    }
                    reponse.repondu = true
                }, boite, nil, &filtre, 1, nil, false)

                // La boucle d'attente. `SDL_PumpEvents` et non `SDL_PollEvent` : les
                // évènements qui arrivent pendant que le sélecteur est ouvert doivent
                // rester dans la file pour la boucle principale, qui les lira après.
                // Les vider ici perdrait le redimensionnement fait pendant ce temps.
                while !reponse.repondu {
                    SDL_PumpEvents()
                    SDL_Delay(10)
                }
                return reponse.choisi
            }
        }
    }
}

/// La liste des documents récents du bureau.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// `recently-used.xbel`, ET POURQUOI ON L'ÉCRIT À LA MAIN
///
/// C'est le fichier que GTK et KDE lisent tous les deux pour peupler leur « ouverts
/// récemment » : un XML au format XBEL, dans `$XDG_DATA_HOME`. Il n'y a pas de
/// bibliothèque à appeler qui ne tire pas GTK entier derrière elle, et le format
/// tient en vingt lignes.
///
/// Le portail en ajoute une entrée tout seul quand c'est lui qui a ouvert le
/// fichier. On n'écrit donc que ce qui est venu autrement — la ligne de commande, un
/// double-clic depuis le gestionnaire de fichiers — et un morceau ouvert par le
/// sélecteur n'y figure qu'une fois : les entrées se retrouvent par leur adresse.
/// ─────────────────────────────────────────────────────────────────────────────
public struct RecentsLinux: DocumentsRecents {
    public init() {}

    /// Là où les bureaux le cherchent, `$XDG_DATA_HOME` d'abord.
    static var fichier: URL {
        let environnement = ProcessInfo.processInfo.environment
        let donnees = environnement["XDG_DATA_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share")
        return donnees.appendingPathComponent("recently-used.xbel")
    }

    public func noter(_ url: URL) {
        // Sur un fil de fond : c'est un fichier partagé avec tout le bureau, qui peut
        // faire quelques centaines de kilooctets, et l'ouverture d'un morceau n'a pas
        // à attendre qu'il soit relu et réécrit.
        DispatchQueue.global(qos: .utility).async {
            var entrees = Self.lire()
            let adresse = url.absoluteString
            entrees.removeAll { $0.adresse == adresse }
            entrees.insert(Entree(adresse: adresse, brut: nil), at: 0)
            // Les bureaux en montrent une poignée ; en garder mille ferait grossir un
            // fichier que d'autres applications relisent à chaque ouverture.
            Self.ecrire(Array(entrees.prefix(100)))
        }
    }

    public func effacer() {
        // Rien : cette liste est celle du bureau, et elle porte ce que d'autres
        // applications y ont mis. « Vider mes récents » dans Spectre vide les nôtres
        // — la liste que `RecentFiles` tient — et n'a pas à jeter ceux du navigateur
        // de fichiers avec.
    }

    /// Une entrée du fichier, **gardée telle qu'elle était écrite**.
    ///
    /// Le premier jet ne relisait que l'adresse et la date, et réécrivait le reste
    /// à partir d'elles. Il a suffi d'un essai pour le voir : GNOME écrit ses dates
    /// avec les fractions de seconde, que le lecteur ISO 8601 de Foundation refuse,
    /// et toutes les entrées des autres applications retombaient à 1970 — soit,
    /// pour un bureau qui trie par date, au fond de la liste.
    ///
    /// Garder le texte d'origine coûte une chaîne par entrée et rend le problème
    /// sans objet : ce qu'on n'a pas écrit, on ne le réécrit pas. L'icône, le type
    /// MIME, la liste des programmes qui ont ouvert le fichier — tout cela traverse
    /// intact.
    struct Entree {
        var adresse: String
        /// L'élément `<bookmark>` entier, tel qu'il était dans le fichier. `nil`
        /// pour celles qu'on vient d'ajouter.
        var brut: String?
    }

    static func lire() -> [Entree] {
        guard let texte = try? String(contentsOf: fichier, encoding: .utf8) else {
            return []
        }
        var entrees: [Entree] = []
        var reste = Substring(texte)
        while let ouverture = reste.range(of: "<bookmark ") {
            let apres = reste[ouverture.lowerBound...]
            // Où finit la balise ouvrante. Chercher « /> » dans tout ce qui suit ne
            // marche pas : un signet de GNOME porte un `<mime:mime-type …/>` à
            // l'intérieur, et l'on couperait l'entrée en son milieu. Le seul « /> »
            // qui compte est celui qui **ferme la balise ouvrante**, donc celui qui
            // tombe sur le premier « > ».
            guard let finDeLaBalise = apres.firstIndex(of: ">") else { break }
            let borne: Substring.Index
            if apres[apres.index(before: finDeLaBalise)] == "/" {
                borne = apres.index(after: finDeLaBalise)
            } else if let ferme = apres.range(of: "</bookmark>") {
                // Un signet fermé par une balise porte l'icône, le type MIME et la
                // liste des programmes qui l'ont ouvert. Tout cela doit traverser.
                borne = ferme.upperBound
            } else {
                break
            }
            let element = String(apres[apres.startIndex..<borne])
            if let adresse = valeur(de: "href", dans: element) {
                entrees.append(Entree(adresse: adresse, brut: element))
            }
            reste = apres[borne...]
        }
        return entrees
    }

    private static func valeur(de attribut: String, dans texte: String) -> String? {
        guard let debut = texte.range(of: "\(attribut)=\"") else { return nil }
        guard let fin = texte[debut.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(texte[debut.upperBound..<fin])
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func ecrire(_ entrees: [Entree]) {
        let formateur = ISO8601DateFormatter()
        let maintenant = formateur.string(from: Date())
        var texte = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xbel version="1.0"
              xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks"
              xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">

        """
        for entree in entrees {
            if let brut = entree.brut {
                texte += "  " + brut + "\n"
            } else {
                let adresse = entree.adresse.replacingOccurrences(of: "&", with: "&amp;")
                texte += """
                  <bookmark href="\(adresse)" added="\(maintenant)" \
                modified="\(maintenant)" visited="\(maintenant)"/>

                """
            }
        }
        texte += "</xbel>\n"
        try? FileManager.default.createDirectory(
            at: fichier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? texte.write(to: fichier, atomically: true, encoding: .utf8)
    }
}

// MARK: - Les réglages

/// Les réglages de l'application sous Linux.
///
/// Le magasin lui-même — le JSON, l'écriture différée, la langue qu'on repose — est
/// dans `SpectreModele/ReglagesEnregistres.swift`, partagé avec Windows. De tout ce
/// qu'il fait, **une seule chose** est propre à Linux, et c'est ce qui reste ici :
/// savoir quelles langues l'utilisateur préfère.
///
/// Le fichier va dans `Storage.root`, que Foundation fait tomber sous Linux sur
/// `~/.local/share/Spectre` — l'emplacement XDG des données d'application. Rien à
/// écrire pour cela, et `SessionCheck` le mesure.
public enum PreferencesLinux {
    public static let partagees = ReglagesEnregistres(
        languesDuSysteme: { languesDuSysteme },
        plafondChange: { plafond in
            RangementDesPistes.plafond = plafond
            DispatchQueue.global(qos: .utility).async {
                RangementDesPistes.ranger(enGardant: nil)
            }
        })

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
}

// MARK: - La séparation

// Le rangement des pistes et le moteur d'inférence **ne sont plus ici** : ils sont
// dans `SpectreSeparation`, où Windows les partage. Ces deux fichiers vivaient dans
// `SpectreWin` et n'importaient déjà pas `WinSDK` ; de tout ce qu'ils font, seul le
// chargement de la bibliothèque touchait le système, et il tient en trois lignes
// d'`onnx.c`.
//
// Le service que le modèle reçoit s'appelle `RangementSurLePont`, et c'est ce que
// `SpectreLinux/main.swift` assemble.
