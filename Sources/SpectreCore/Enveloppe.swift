import Foundation
// Sur le Mac, `URLSession` est dans Foundation ; ailleurs elle est dans un module
// à part, que la bibliothèque d'exécution de Swift porte des deux côtés. C'est la
// seule ligne de tout le noyau qui distingue les systèmes, et elle ne distingue
// qu'un nom de module.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Le format d'un rapport, et le fil qui le porte.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// SANS BIBLIOTHÈQUE, ET POURQUOI C'EST MOINS CHER
///
/// Le protocole d'envoi de Sentry est du HTTP ordinaire : un objet JSON posté à
/// une adresse, avec un en-tête d'authentification d'une ligne. L'écrire ici coûte
/// ce fichier ; prendre une bibliothèque coûterait **trois** bibliothèques — une
/// par système — à trouver, à empaqueter et à tenir à jour, pour trois
/// comportements qui se ressembleraient sans être les mêmes.
///
/// Surtout, cela garde la règle du dépôt : le noyau ne connaît aucun système, et
/// les trois plateformes obtiennent la même chose plutôt qu'une chose qui se
/// ressemble.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// LA PORTE DE SORTIE, NOTÉE MAINTENANT PLUTÔT QU'APRÈS
///
/// **GlitchTip parle le même protocole**, et s'héberge soi-même pour rien. Le jour
/// où le quota gêne, ou bien l'idée d'envoyer cela chez un tiers, **une seule
/// adresse change** — la constante ci-dessous, et rien d'autre dans ce fichier. Ce
/// choix-ci n'engage donc pas, et c'est la raison pour laquelle le type s'appelle
/// `Enveloppe` et non `Sentry`.
///
/// L'adresse — le « DSN » — est faite pour vivre dans le programme livré, au vu de
/// tous : elle n'autorise qu'à envoyer, jamais à lire.
/// ─────────────────────────────────────────────────────────────────────────────
enum Enveloppe {

    /// L'adresse du dépôt.
    ///
    /// Elle est écrite en clair dans le programme livré, et c'est ainsi qu'un DSN se
    /// distribue : **il n'autorise qu'à envoyer, jamais à lire**. Quelqu'un qui la
    /// recopie peut nous envoyer de faux rapports, et rien d'autre — ni voir les
    /// nôtres, ni toucher au projet. C'est aussi pourquoi elle n'a rien à faire dans
    /// un secret d'intégration continue : un secret qu'on livre dans le binaire n'en
    /// est pas un, et le cacher ne ferait qu'égarer celui qui le cherchera.
    ///
    /// La région est celle de l'Union européenne — `ingest.de.sentry.io` — parce que
    /// c'est là que le compte a été ouvert. Elle ne change rien au protocole.
    ///
    /// Vide, tout ce fichier devient inerte : rien ne part, rien n'est écrit sur le
    /// disque de personne, et l'avis du premier lancement ne s'affiche pas.
    /// `SPECTRE_RAPPORTS` la remplace, et c'est par là que `RapportsCheck` travaille.
    static let adresseDuDepot =
        "https://3739714d4c1e339d8a460b1a8f351adb@o4511976221704192.ingest.de.sentry.io/4511976230813776"

    /// Ce qu'un DSN contient : de quoi fabriquer une adresse et un en-tête.
    ///
    /// `https://<clé>@<hôte>/<projet>` — trois morceaux, et le chemin d'envoi s'en
    /// déduit. On accepte `http://` pour une seule raison : le harnais poste sur
    /// une boucle locale, et lui imposer un certificat n'éprouverait que OpenSSL.
    struct Adresse {
        let cle: String
        let url: URL

        init?(_ texte: String) {
            guard !texte.isEmpty, let brut = URL(string: texte),
                  let schema = brut.scheme, schema == "https" || schema == "http",
                  let hote = brut.host, let cle = brut.user, !cle.isEmpty
            else { return nil }
            let projet = brut.path.split(separator: "/").last.map(String.init) ?? ""
            guard !projet.isEmpty else { return nil }
            let port = brut.port.map { ":\($0)" } ?? ""
            guard let assemblee = URL(string: "\(schema)://\(hote)\(port)/api/\(projet)/envelope/")
            else { return nil }
            self.cle = cle
            self.url = assemblee
        }

        func entetes(version: String) -> [String: String] {
            ["Content-Type": "application/x-sentry-envelope",
             "X-Sentry-Auth": "Sentry sentry_version=7, "
                            + "sentry_client=spectre/\(version), sentry_key=\(cle)"]
        }
    }

    /// Un numéro d'évènement : trente-deux chiffres hexadécimaux, sans tirets.
    /// Sert aussi de numéro de machine — même forme, même absence de sens.
    static func numeroDEvenement() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Le corps de la requête : trois lignes, dont deux d'en-tête.
    ///
    /// La longueur déclarée est celle des **octets** et non des caractères. Une
    /// panne dont le message porte un accent — c'est-à-dire à peu près toutes,
    /// ici — serait sinon tronquée à l'arrivée, et l'on aurait un service qui
    /// refuse en silence les seuls rapports intéressants.
    static func enveloppe(_ rapport: Rapports.Rapport) -> Data {
        let evenement = Data(corps(rapport).utf8)
        let tete = ligne(["event_id": rapport.identifiant,
                          "sent_at": ISO8601DateFormatter().string(from: Date())])
        let entete = ligne(["type": "event",
                            "content_type": "application/json",
                            "length": evenement.count])
        var corps = tete
        corps.append(entete)
        corps.append(evenement)
        corps.append(0x0a)
        return corps
    }

    private static func ligne(_ objet: [String: Any]) -> Data {
        var donnees = (try? JSONSerialization.data(withJSONObject: objet)) ?? Data("{}".utf8)
        donnees.append(0x0a)
        return donnees
    }

    /// L'évènement lui-même.
    ///
    /// `fingerprint` est ce qui décide du regroupement à l'arrivée, et il est posé
    /// à la main plutôt que laissé au service : deux fois la même panne sur deux
    /// machines doivent faire **un** sujet qui dit « deux personnes », et non deux
    /// sujets qui disent chacun « une fois ». C'est l'endroit du programme plus la
    /// forme du message, chiffres retirés — la même normalisation que celle qui sert
    /// à ne pas écrire deux fois le même rapport.
    private static func corps(_ rapport: Rapports.Rapport) -> String {
        let objet: [String: Any] = [
            "event_id": rapport.identifiant,
            "timestamp": rapport.quand,
            "platform": "native",
            "level": rapport.niveau,
            "logger": "spectre",
            "release": "spectre@\(rapport.version)",
            "message": ["formatted": rapport.quoi],
            "fingerprint": [rapport.origine, Anonyme.empreinte(rapport.quoi)],
            "user": ["id": rapport.machine],
            "tags": etiquettes(rapport),
            "contexts": contextes(rapport),
        ]
        let donnees = (try? JSONSerialization.data(withJSONObject: objet)) ?? Data("{}".utf8)
        return String(decoding: donnees, as: UTF8.self)
    }

    private static func etiquettes(_ rapport: Rapports.Rapport) -> [String: String] {
        var etiquettes = ["systeme": nomDuSysteme,
                          "architecture": rapport.architecture,
                          "origine": rapport.origine]
        if rapport.repetitions > 1 { etiquettes["repetitions"] = "\(rapport.repetitions)" }
        if let carte = rapport.carte { etiquettes["carte"] = carte }
        return etiquettes
    }

    private static func contextes(_ rapport: Rapports.Rapport) -> [String: Any] {
        var contextes: [String: Any] = [
            "os": ["name": nomDuSysteme, "version": rapport.systeme],
            "device": ["arch": rapport.architecture],
        ]
        if let carte = rapport.carte { contextes["gpu"] = ["name": carte] }
        return contextes
    }

    static var nomDuSysteme: String {
        #if os(Windows)
        return "Windows"
        #elseif os(Linux)
        return "Linux"
        #elseif canImport(Darwin)
        return "macOS"
        #else
        return "inconnu"
        #endif
    }

    // MARK: - Le fil

    /// Poste, et rend le code que le service a répondu. Zéro quand rien n'a abouti.
    ///
    /// **Bloquant, et volontairement.** Il n'y a qu'un seul appelant — le fil des
    /// rapports, qui n'a rien d'autre à faire —, et une file d'attente qui envoie
    /// un rapport à la fois est plus simple à raisonner qu'un jeu de fermetures
    /// dont l'ordre dépend du réseau. La minute d'attente est celle du fil, pas
    /// celle de la fenêtre.
    static func poster(_ url: URL, _ entetes: [String: String], _ corps: Data) -> Int {
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.httpBody = corps
        for (nom, valeur) in entetes { requete.setValue(valeur, forHTTPHeaderField: nom) }
        requete.timeoutInterval = 15

        // Le code passe par une boîte plutôt que par une variable capturée : le
        // compilateur refuse la seconde en mode Swift 6 — écrire depuis le fil du
        // réseau dans la pile d'un autre fil — et il a raison même s'il ne le refuse
        // pas encore ici. Le sémaphore fait la barrière : personne ne lit la boîte
        // avant que l'écriture ne soit finie.
        final class Reponse: @unchecked Sendable { var code = 0 }
        let reponse = Reponse()
        let attente = DispatchSemaphore(value: 0)
        let tache = URLSession.shared.dataTask(with: requete) { _, brute, _ in
            reponse.code = (brute as? HTTPURLResponse)?.statusCode ?? 0
            attente.signal()
        }
        tache.resume()
        // Un cran au-dessus du délai de la requête : si la couche réseau ne rend
        // jamais la main, ce fil-ci ne doit pas rester bloqué pour l'éternité.
        _ = attente.wait(timeout: .now() + 30)
        return reponse.code
    }
}
