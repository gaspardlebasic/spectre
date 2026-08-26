import Foundation

/// Ce qui est retiré d'un rapport avant qu'il ne parte.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// LA RÈGLE, ET POURQUOI ELLE EST UNE FONCTION PLUTÔT QU'UNE INTENTION
///
/// Deux choses ne sortent jamais de la machine de la personne :
///
/// **Le nom du fichier audio.** Le titre d'un morceau dit ce que quelqu'un écoute.
/// Un logiciel de transcription n'a aucune raison de le savoir, et un service tiers
/// encore moins. Le **format**, lui, part : « ‹morceau›.mp3 » dit que le décodeur
/// mp3 a échoué, ce qui est toute la panne, sans dire sur quoi.
///
/// **Le chemin personnel.** `/Users/prénom-nom/…` porte le nom de la personne dans
/// presque tous les rapports de plantage du monde — c'est la fuite la plus banale
/// du genre, et elle passe inaperçue parce qu'elle est dans une trace technique que
/// personne ne relit.
///
/// Une règle de confidentialité qu'aucun harnais ne vérifie est une phrase de
/// documentation. `RapportsCheck` met celle-ci en défaut sur des cas écrits
/// d'avance — un titre avec des espaces, un titre entre guillemets, un chemin
/// Windows, un chemin qui n'est pas sous le dossier personnel.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// LE SENS DANS LEQUEL ON SE TROMPE, ET IL EST CHOISI
///
/// Un nom de fichier peut contenir des espaces, ce qui rend impossible de savoir où
/// il commence : « impossible de lire Santi & Tuğçe.mp3 » ne se distingue pas, pour
/// une machine, de « impossible de lire.mp3 ». On efface donc **jusqu'au dernier
/// séparateur de phrase** — guillemet, deux-points, virgule, parenthèse — plutôt que
/// de s'arrêter au dernier espace.
///
/// Le prix est réel : un message sans ponctuation y perd quelques mots de contexte.
/// Le prix de l'autre côté serait un titre de morceau chez un tiers. Ce n'est pas
/// un arbitrage difficile, mais il est délibéré, et c'est pourquoi il est écrit.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Anonyme {

    /// Les formats que l'application ouvre. La liste n'a pas à être exhaustive :
    /// ce qui n'y figure pas est, au pire, un nom de fichier qui n'est pas un
    /// morceau — et les chemins personnels, eux, sont retirés quelle que soit
    /// l'extension.
    private static let formats = ["mp3", "wav", "flac", "m4a", "m4b", "aac", "ogg",
                                  "oga", "opus", "aiff", "aif", "aifc", "wma",
                                  "caf", "au", "mp4", "mov", "mkv", "webm"]

    /// Ce qui ne peut pas faire partie d'un nom de fichier dans un message : la
    /// ponctuation qui sépare deux idées, et les guillemets des cinq langues.
    private static let bornes = "\\n\\t\"'()\\[\\]{}«»‹›:;,"

    public static func nettoyer(_ texte: String) -> String {
        var propre = texte
        // 1. Le dossier personnel devient `~`, sur les trois systèmes. Ce qui suit
        //    en dépend : la règle 2 ne cherche plus que des chemins en `~`.
        let maison = NSHomeDirectory()
        if maison.count > 3 {
            propre = propre.replacingOccurrences(of: maison, with: "~")
            // Le Mac résout parfois le dossier personnel derrière `/private`, et
            // Foundation rend alors l'un ou l'autre selon l'appel.
            propre = propre.replacingOccurrences(of: "/private~", with: "~")
        }
        // 2. Un chemin personnel ne dit que son extension. Le nom du dossier
        //    n'apprend rien non plus : « ~/Musique/Démos » est déjà une confidence.
        propre = remplacer("~[^\(bornes)]*?\\.([A-Za-z0-9]{1,6})(?=[\\s\(bornes)]|$)",
                           dans: propre, par: "~/‹fichier›.$1")
        // `+` et non `*`, et ce n'est pas une coquetterie : `*` accepte le vide et
        // remplaçait donc une deuxième fois ce que la règle d'au-dessus venait
        // d'écrire — « ~/‹fichier›‹fichier›.mp3 ». Une anonymisation qui repasse sur
        // ses propres marques finit par manger le message.
        propre = remplacer("~[/\\\\][^\\s\(bornes)]+", dans: propre, par: "~/‹fichier›")
        // 3. Un morceau, où qu'il soit rangé. Les séparateurs sont exclus du motif :
        //    « /Volumes/Musique/Mon Titre.mp3 » y perd son titre et garde son
        //    dossier, qui est ce qu'on veut — le dossier peut expliquer une panne
        //    de permission, le titre n'explique rien.
        let listeDesFormats = formats.joined(separator: "|")
        propre = remplacer("[^\(bornes)/\\\\]+\\.(\(listeDesFormats))\\b",
                           dans: propre, par: "‹morceau›.$1", insensible: true)
        // 4. Ce qui resterait du nom de la personne ailleurs que dans son dossier —
        //    un disque externe, un partage réseau, un montage de machine virtuelle.
        let nom = (maison as NSString).lastPathComponent
        if nom.count >= 3 { propre = propre.replacingOccurrences(of: nom, with: "‹personne›") }
        return propre
    }

    /// La forme d'un message, chiffres retirés.
    ///
    /// Sert deux fois, et il faut que ce soit la même : à ne pas écrire deux fois
    /// le même rapport dans un lancement, et à les regrouper à l'arrivée. « Le
    /// décodage s'est arrêté à 12,4 s » et « … à 31,9 s » sont **une** panne ; les
    /// compter pour deux ferait chercher deux fois la même chose.
    public static func empreinte(_ texte: String) -> String {
        var forme = ""
        var chiffreEnCours = false
        for caractere in texte {
            if caractere.isNumber {
                if !chiffreEnCours { forme.append("#") }
                chiffreEnCours = true
            } else {
                chiffreEnCours = false
                forme.append(caractere)
            }
        }
        return forme
    }

    private static func remplacer(_ motif: String, dans texte: String, par quoi: String,
                                  insensible: Bool = false) -> String {
        let options: NSRegularExpression.Options = insensible ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: motif, options: options)
        else { return texte }
        let etendue = NSRange(texte.startIndex..., in: texte)
        return expression.stringByReplacingMatches(in: texte, range: etendue,
                                                   withTemplate: quoi)
    }
}
