import Foundation

/// Où sont les fichiers qui voyagent avec l'application.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// TROIS SYSTÈMES, DEUX ENDROITS, UNE FONCTION
///
/// Le paquet macOS range ses ressources dans `Contents/Resources` ; les
/// distributions Windows et Linux les posent à côté de l'exécutable. Ce sont les
/// deux seuls endroits, et les essayer l'un après l'autre coûte moins qu'un `#if`
/// par plateforme — d'autant que `Bundle.main.resourceURL` rend justement le dossier
/// de l'exécutable là où il n'y a pas de paquet.
///
/// Le modèle des poids de Demucs ne passe pas par ici : il a trois emplacements à
/// lui, dont une variable d'environnement et le rangement de l'utilisateur, et
/// `Demucs.fichier` les connaît. Ce qui passe par ici est ce qui est **toujours**
/// dans le paquet, et dont l'absence n'est pas une situation à traiter mais un
/// paquet mal assemblé — ou une exécution depuis `.build`, où il n'y a pas de
/// paquet du tout.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Ressources {

    /// Le fichier `nom` s'il voyage avec l'application, `nil` sinon.
    ///
    /// L'appelant décide de ce que vaut l'absence. Pour les captures du diaporama,
    /// elle vaut « on montre le texte sans l'image » : une présentation amputée reste
    /// une présentation, et refuser de s'ouvrir serait la pire des réponses.
    public static func fichier(_ nom: String) -> URL? {
        let gestionnaire = FileManager.default
        for dossier in [Bundle.main.resourceURL, dossierDeLExecutable] {
            guard let candidat = dossier?.appendingPathComponent(nom) else { continue }
            if gestionnaire.fileExists(atPath: candidat.path) { return candidat }
        }
        return nil
    }

    private static var dossierDeLExecutable: URL? {
        Bundle.main.executablePath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
    }

    /// Les deux captures du diaporama du premier lancement.
    ///
    /// Nommées ici plutôt que dans chacune des deux interfaces qui les dessinent :
    /// ce sont les mêmes fichiers, copiés sous les mêmes noms par les trois scripts
    /// d'assemblage, et un nom qui divergerait d'un côté ferait disparaître l'image
    /// sur un seul système — c'est-à-dire là où personne ne la cherche.
    public static let captures = ["diapo-boucle.png", "diapo-pistes.png"]

    /// La capture d'une diapositive, si le paquet la porte.
    public static func capture(_ rang: Int) -> URL? {
        guard captures.indices.contains(rang) else { return nil }
        return fichier(captures[rang])
    }
}
