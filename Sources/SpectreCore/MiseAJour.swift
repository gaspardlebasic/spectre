import Foundation
// Même raison que dans `Enveloppe` : sur le Mac `URLSession` est dans Foundation,
// ailleurs elle est dans un module à part que la bibliothèque d'exécution de Swift
// porte des deux côtés.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Y a-t-il une version plus récente que celle qui tourne ?
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI L'APPLICATION LE DEMANDE ELLE-MÊME
///
/// Spectre se distribue par une page de releases, et rien ne prévient qui l'a
/// installée. Une correction de panne peut donc rester six mois sur le serveur
/// pendant que la panne, elle, continue chez les gens — et c'est le même angle mort
/// que celui des rapports de panne, pris par l'autre bout : là on n'apprend pas ce
/// qui casse, ici on ne répare pas ce qu'on a appris.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// CE QUE CELA N'EST PAS
///
/// **Ce n'est pas une mise à jour automatique.** Rien ne se télécharge, rien ne
/// s'installe, rien ne remplace l'application : on demande un numéro, et si celui
/// d'en face est plus grand, on ouvre la page dans le navigateur. Le geste reste
/// entier à qui l'exécute — c'est le même parti que le reste du dépôt, où
/// l'application ne fait rien qu'on ne lui ait demandé sauf dire ce qui casse.
///
/// **Rien n'attend le réseau.** La question part sur un fil à part, quelques
/// secondes après l'ouverture ; sans réponse, sans réseau, ou sans page de
/// releases, la fenêtre est exactement celle d'avant.
///
/// **Rien ne sort de la machine.** Une requête `GET` sur une adresse publique, sans
/// jeton, sans identifiant, sans le moindre champ à nous. GitHub voit une adresse
/// IP demander un fichier JSON, ce que voit n'importe quel serveur web.
///
/// `SPECTRE_MAJ` remplace l'adresse — c'est par là que `LancementCheck` travaille —
/// et `non` retire la question entièrement, pour qui ne veut pas qu'on la pose.
/// ─────────────────────────────────────────────────────────────────────────────
public enum MiseAJour {

    /// L'adresse du dépôt. Publique et en lecture seule, comme la page qu'elle décrit.
    public static let adresseDuDepot =
        "https://api.github.com/repos/gaspardlebasic/spectre/releases/latest"

    /// Ce qu'on a trouvé en face : un numéro, et la page où le prendre.
    public struct Livraison: Equatable, Sendable {
        public let version: String
        public let page: URL

        public init(version: String, page: URL) {
            self.version = version
            self.page = page
        }
    }

    // MARK: - La comparaison

    /// `candidate` est-elle plus récente que `courante` ?
    ///
    /// Les numéros du dépôt sont faits de nombres séparés par des points, avec un
    /// `v` devant sur l'étiquette et pas dans `Version.swift` — d'où le nettoyage.
    /// La comparaison se fait **nombre par nombre** et non sur le texte : « 0.10 »
    /// est plus récente que « 0.9 », ce qu'un tri alphabétique dit exactement à
    /// l'envers. Le jour où le dépôt passera de 0.9 à 0.10 est le jour où cette
    /// ligne comptera, et ce n'est pas un jour où l'on veut relire ce fichier.
    ///
    /// Ce qui n'est pas un nombre — `v0.6-beta`, `0.6rc1` — s'arrête au premier
    /// caractère étranger plutôt que de faire échouer la comparaison entière : une
    /// étiquette mal formée ne doit pas proposer une mise à jour vers rien.
    ///
    /// Pure, et publique pour cette seule raison : `LancementCheck` la repasse sur
    /// une dizaine de couples, sans réseau.
    public static func plusRecente(_ candidate: String, que courante: String) -> Bool {
        let a = nombres(candidate), b = nombres(courante)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let gauche = i < a.count ? a[i] : 0
            let droite = i < b.count ? b[i] : 0
            if gauche != droite { return gauche > droite }
        }
        return false
    }

    private static func nombres(_ etiquette: String) -> [Int] {
        var propre = etiquette.trimmingCharacters(in: .whitespacesAndNewlines)
        if propre.first == "v" || propre.first == "V" { propre.removeFirst() }
        var sortie: [Int] = []
        for morceau in propre.split(separator: ".", omittingEmptySubsequences: false) {
            let chiffres = morceau.prefix { $0.isNumber }
            guard !chiffres.isEmpty, let valeur = Int(chiffres) else { break }
            sortie.append(valeur)
            // Un suffixe collé au nombre — le `rc1` de `0.6rc1` — arrête la lecture
            // là : ce qui suit ne se compare pas à des nombres.
            if chiffres.count != morceau.count { break }
        }
        return sortie
    }

    // MARK: - La question

    /// Ce qui interroge vraiment. Remplaçable, et c'est tout l'intérêt :
    /// `LancementCheck` y met une fonction qui rend un JSON écrit à la main, et
    /// éprouve alors la lecture de la réponse **sans réseau**, donc partout.
    public static var demande: ((URL) -> Data?)?

    /// Cherche, sur un fil à part, et rappelle avec ce qu'on a trouvé — `nil` quand
    /// il n'y a rien de plus récent, pas de réseau, ou pas d'adresse.
    ///
    /// Le rappel n'arrive **pas** sur le fil principal : c'est à l'appelant de s'y
    /// remettre, parce que lui seul sait par quelle file il y retourne. Le modèle le
    /// fait ; c'est écrit là-bas.
    ///
    /// `politesse` est le temps qu'on laisse à la fenêtre avant de tirer sur la
    /// carte réseau. Il n'est explicite que pour le harnais, qui pose la question
    /// une dizaine de fois et n'a pas de fenêtre à ménager.
    public static func chercher(courante: String = Spectre.version,
                                politesse: Double = 3,
                                fin: @escaping (Livraison?) -> Void) {
        let texte = ProcessInfo.processInfo.environment["SPECTRE_MAJ"] ?? adresseDuDepot
        guard texte != "non", let adresse = URL(string: texte) else { return fin(nil) }

        let fil = Thread {
            // L'application d'abord, comme pour les rapports : une fenêtre qui met
            // une seconde de plus à s'ouvrir parce qu'un fil tire sur la carte réseau
            // est un mauvais échange, et la question n'est pas pressée.
            if politesse > 0 { Thread.sleep(forTimeInterval: politesse) }
            fin(lire(adresse, courante: courante))
        }
        fil.name = "Spectre — mise à jour"
        fil.stackSize = 512 * 1024
        fil.start()
    }

    private static func lire(_ adresse: URL, courante: String) -> Livraison? {
        guard let donnees = (demande ?? interroger)(adresse),
              let release = try? JSONDecoder().decode(Release.self, from: donnees),
              let etiquette = release.tag_name,
              plusRecente(etiquette, que: courante)
        else { return nil }
        // La page de la release, ou la page des releases : l'une ou l'autre mène au
        // téléchargement, et une adresse absente ne doit pas retirer l'avis.
        let page = release.html_url.flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/gaspardlebasic/spectre/releases/latest")
        guard let page else { return nil }
        // Le `v` de l'étiquette ne s'affiche pas : ce qu'on montre à côté de « vous
        // avez la 0.5 » doit s'écrire comme elle.
        var numero = etiquette
        if numero.first == "v" || numero.first == "V" { numero.removeFirst() }
        return Livraison(version: numero, page: page)
    }

    /// Ce que GitHub rend, et les deux seuls champs qu'on en lit. Tous les autres —
    /// il y en a une cinquantaine — sont ignorés par le décodeur, ce qui est très
    /// exactement ce qu'on veut d'une réponse qu'on ne contrôle pas.
    private struct Release: Decodable {
        var tag_name: String?
        var html_url: String?
    }

    private static func interroger(_ adresse: URL) -> Data? {
        var requete = URLRequest(url: adresse)
        requete.httpMethod = "GET"
        // L'API de GitHub refuse une requête sans agent, et demande cet en-tête-là
        // pour figer la version du format qu'elle rend.
        requete.setValue("Spectre/\(Spectre.version)", forHTTPHeaderField: "User-Agent")
        requete.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        requete.timeoutInterval = 10

        // La même boîte que dans `Enveloppe`, et pour la même raison : le compilateur
        // refuse en mode Swift 6 qu'un fil écrive dans la pile d'un autre, et il a
        // raison. Le sémaphore fait la barrière.
        final class Reponse: @unchecked Sendable { var corps: Data? }
        let reponse = Reponse()
        let attente = DispatchSemaphore(value: 0)
        let tache = URLSession.shared.dataTask(with: requete) { donnees, brute, _ in
            if (brute as? HTTPURLResponse)?.statusCode == 200 { reponse.corps = donnees }
            attente.signal()
        }
        tache.resume()
        _ = attente.wait(timeout: .now() + 20)
        return reponse.corps
    }
}
