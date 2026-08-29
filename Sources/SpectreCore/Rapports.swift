import Foundation

/// Ce que Spectre raconte de ses pannes, et à qui.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI CELA PART TOUT SEUL
///
/// L'application sort de la machine de son auteur. Les gens qui l'installeront ont
/// d'autres cartes graphiques, d'autres cartes son, d'autres versions du système —
/// et **aucun d'eux ne cliquera sur « Signaler un problème »**. Un rapport qu'il
/// faut vouloir envoyer n'est jamais envoyé, et une panne qu'on n'apprend pas est
/// une panne qu'on ne corrige pas : elle se paie en désinstallations silencieuses,
/// sans qu'un mot revienne. Voir `docs/RAPPORTS.md`, qui pose l'arbitrage en
/// entier — y compris ce qu'il coûte.
///
/// Ce fichier-ci fait l'étape 2 de ce plan : **les pannes que l'application détecte
/// déjà**. Un fichier qui ne se décode pas, les poids de Demucs absents, ONNX
/// Runtime introuvable, la séparation qui s'arrête au milieu. Tout cela est déjà
/// su — l'application le dit dans la barre du bas, puis l'oublie. Il n'y a donc ni
/// gestionnaire de signaux ni symboles à trouver : il n'y a qu'à ne plus oublier.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// CE QUI NE PART JAMAIS
///
/// **Le nom du fichier audio.** Le titre d'un morceau dit ce que quelqu'un écoute,
/// et ce n'est pas notre affaire — c'est même exactement ce qu'un logiciel de
/// transcription n'a aucune raison de savoir. **Le chemin personnel** non plus :
/// `/Users/prénom-nom/…` porte le nom de la personne dans presque tous les rapports
/// de plantage du monde, et c'est la fuite la plus banale du genre.
///
/// Ce n'est pas une intention, c'est une fonction : `Anonyme.nettoyer(_:)`, et
/// `RapportsCheck` la met en défaut sur des cas écrits d'avance. Une règle de
/// confidentialité qu'aucun harnais ne vérifie est une phrase de documentation.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// CE QUI EST INTERDIT ICI, ET QUI SE VOIT DANS LA FORME
///
/// **Rien n'attend le réseau.** L'application s'ouvre, analyse et joue sans
/// connexion, exactement comme avant ce fichier : `signaler(_:)` écrit sur le
/// disque et rend la main immédiatement. Un fil séparé, réveillé de temps en temps,
/// fait les envois. S'il n'y a pas de réseau, la file attend le lancement suivant ;
/// ce qui n'est pas parti au bout de trois jours est jeté.
///
/// **Un plantage dans une boucle de dessin enverrait mille rapports en une
/// minute** et viderait le quota du mois avant qu'on ait lu le premier. D'où trois
/// garde-fous, et pas un seul : la même panne est **comptée** plutôt que répétée,
/// un lancement n'écrit pas plus de huit rapports distincts, et une journée pas
/// plus de quarante.
///
/// **Rien ne part tant qu'il n'y a pas d'adresse.** Sans DSN — c'est le cas du
/// dépôt tel qu'il est — `actifs` est faux, la file n'est pas écrite, et le
/// diaporama du premier lancement n'annonce rien. Une application qui annoncerait un
/// envoi qu'elle ne fait pas serait pire que muette.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Rapports {

    // MARK: - Ce qu'on remonte

    public enum Niveau: String, Sendable {
        /// Une panne dont l'application se relève : elle le dit dans la barre du bas.
        case erreur = "error"
        /// Une panne dont elle ne se relève pas.
        case fatal = "fatal"
    }

    /// Un rapport, tel qu'il attend sur le disque entre deux lancements.
    ///
    /// Il est écrit **déjà nettoyé** : ce qui n'a pas le droit de partir n'a pas
    /// non plus le droit d'être posé sur le disque de quelqu'un sous un nom de
    /// fichier que le prochain lancement enverra sans le relire.
    struct Rapport: Codable {
        var identifiant: String
        var quand: Double
        var niveau: String
        var quoi: String
        var origine: String
        var version: String
        var systeme: String
        var architecture: String
        var carte: String?
        var machine: String
        /// La même panne comptée plutôt que répétée. Vaut 1 la première fois.
        var repetitions: Int
    }

    // MARK: - L'ouverture

    /// À appeler au lancement, juste après `Journal.ouvrir()`.
    ///
    /// C'est ce qui distingue l'application de tout le reste : les vérifications,
    /// les commandes en ligne et les harnais tirent le même noyau et n'appellent
    /// pas ceci. Rien ne part donc de nulle part ailleurs que de la fenêtre, et
    /// c'est vrai par construction plutôt que par une liste d'exceptions.
    /// `envoiEnFond` n'est faux que pour `RapportsCheck` : il ouvre et referme une
    /// dizaine de fois dans un seul processus, et un fil d'envoi par ouverture
    /// posterait au milieu du contrôle suivant. Il appelle `envoyerLaFile()`
    /// lui-même, quand il est prêt à regarder ce qui part.
    public static func ouvrir(version: String = Spectre.version, dsn: String? = nil,
                              envoiEnFond: Bool = true) {
        verrou.lock()
        defer { verrou.unlock() }
        guard adresse == nil else { return }
        self.version = version
        // `SPECTRE_RAPPORTS` remplace l'adresse du dépôt, et **`non` la retire** :
        // c'est par là que les harnais et la recette lancent la vraie application
        // sans que rien ne parte et sans que le diaporama du premier lancement
        // n'annonce un envoi qui n'aura pas lieu. Une épreuve qui poste chez
        // Sentry à chaque passage salit les seules données qu'on ait.
        let texte = dsn ?? ProcessInfo.processInfo.environment["SPECTRE_RAPPORTS"]
            ?? Enveloppe.adresseDuDepot
        guard texte != "non", let analysee = Enveloppe.Adresse(texte) else { return }
        adresse = analysee
        dossier = Storage.root?.appendingPathComponent("rapports", isDirectory: true)
        if let dossier {
            try? FileManager.default.createDirectory(at: dossier,
                                                     withIntermediateDirectories: true)
        }
        guard envoiEnFond else { return }
        let fil = Thread { boucleDEnvoi() }
        fil.name = "Spectre — rapports"
        // Et sa pile est celle par défaut. Une pile réduite avait été posée ici, pour
        // quelques dizaines de kilo-octets : c'est exactement le genre d'économie qui
        // se paie en débordement de pile chez quelqu'un d'autre, dans Foundation, sur
        // le seul des trois systèmes où l'on n'a pas regardé. Ce fil dort presque tout
        // le temps ; ce qu'il coûte n'est pas ce qu'on cherche à réduire.
        fil.start()
    }

    /// Vrai quand l'adresse est là, donc quand quelque chose peut partir.
    public static var actifs: Bool {
        verrou.lock()
        defer { verrou.unlock() }
        return adresse != nil
    }

    /// La carte graphique, dès que le rendu la connaît.
    ///
    /// Elle vaut cher dans un rapport : la moitié de ce qui casse chez les autres
    /// casse à cause d'un pilote, et le nom du pilote est ce qui permet de dire
    /// « ceux-là, et eux seuls ». Elle n'identifie personne.
    public static func carte(_ nom: String) {
        verrou.lock()
        carteGraphique = nom
        verrou.unlock()
    }

    // MARK: - Signaler

    /// Remonte une panne que l'application vient de détecter.
    ///
    /// `#fileID` et non `#file` : le premier vaut « SpectreCore/Separation.swift »,
    /// le second le chemin complet sur la machine qui a compilé — c'est-à-dire le
    /// nom de l'auteur, dans chaque rapport, ce que ce fichier passe justement son
    /// temps à retirer d'ailleurs.
    public static func signaler(_ quoi: String,
                                niveau: Niveau = .erreur,
                                fichier: String = #fileID,
                                ligne: Int = #line) {
        verrou.lock()
        defer { verrou.unlock() }
        guard adresse != nil, let dossier else { return }

        let propre = Anonyme.nettoyer(quoi)
        let origine = "\(fichier):\(ligne)"
        let empreinte = Anonyme.empreinte(propre) + " " + origine

        // La même panne, comptée. Le fichier déjà écrit est réécrit avec un
        // compteur de plus : c'est un rapport qui dit « quarante fois », et non
        // quarante rapports qui disent la même chose.
        if let dejaVue = duLancement[empreinte] {
            var rapport = dejaVue
            rapport.repetitions += 1
            duLancement[empreinte] = rapport
            poser(rapport, dans: dossier)
            return
        }
        guard duLancement.count < plafondParLancement else { return }
        guard consommerLeQuotaDuJour(dans: dossier) else { return }

        let rapport = Rapport(identifiant: Enveloppe.numeroDEvenement(),
                              quand: Date().timeIntervalSince1970,
                              niveau: niveau.rawValue,
                              quoi: propre,
                              origine: origine,
                              version: version,
                              systeme: ProcessInfo.processInfo.operatingSystemVersionString,
                              architecture: architecture,
                              carte: carteGraphique,
                              machine: numeroDeMachine(dans: dossier),
                              repetitions: 1)
        duLancement[empreinte] = rapport
        poser(rapport, dans: dossier)
        // Sous le verrou du réveil, et non à côté : un signal envoyé pendant que le
        // fil s'apprête à attendre se perdrait, et le rapport dormirait deux minutes
        // de plus. Deux minutes ne sont rien ; le motif, lui, se recopie.
        reveil.lock()
        reveil.signal()
        reveil.unlock()
    }

    // L'avis du premier lancement vivait ici, et n'y vit plus : c'est désormais la
    // seconde diapositive du diaporama qui porte la phrase, et `Bienvenue` — dans
    // `SessionStore.swift` — qui tient le témoin. La raison du déménagement est que
    // le diaporama se montre **même quand rien ne part** : lié à l'adresse d'envoi,
    // il aurait disparu chez qui construit le dépôt sans DSN, emportant avec lui la
    // présentation de l'application. Ce qui reste ici est `actifs`, que le diaporama
    // consulte pour savoir s'il a quelque chose à annoncer.

    // MARK: - L'envoi, derrière

    /// Ce qui poste vraiment. Remplaçable, et c'est tout l'intérêt : `RapportsCheck`
    /// y met une fonction qui garde ce qu'on lui donne, et éprouve alors la file,
    /// les plafonds, l'enveloppe et l'anonymisation **sans réseau**, donc partout et
    /// sans jamais rien envoyer à personne.
    public static var poste: ((URL, [String: String], Data) -> Int)?

    private static func boucleDEnvoi() {
        // L'application d'abord. Une fenêtre qui met une seconde de plus à s'ouvrir
        // parce qu'un fil tire sur la carte réseau est un mauvais échange, et la
        // file n'est pas pressée : elle a déjà attendu un lancement entier.
        Thread.sleep(forTimeInterval: 4)
        while true {
            envoyerLaFile()
            reveil.lock()
            reveil.wait(until: Date().addingTimeInterval(120))
            reveil.unlock()
        }
    }

    /// Envoie ce qui attend, jette ce qui a trop attendu.
    ///
    /// Publique pour le seul harnais : il ne peut pas se permettre d'attendre le
    /// réveil du fil, et un contrôle qui dort quatre secondes pour rien est un
    /// contrôle qu'on finit par sauter.
    public static func envoyerLaFile() {
        verrou.lock()
        let ou = dossier
        let quelleAdresse = adresse
        verrou.unlock()
        guard let ou, let quelleAdresse else { return }

        let gestionnaire = FileManager.default
        let fichiers = (try? gestionnaire.contentsOfDirectory(at: ou,
                                                              includingPropertiesForKeys: nil))
            ?? []
        for fichier in fichiers where fichier.pathExtension == "rapport" {
            guard let donnees = try? Data(contentsOf: fichier),
                  let rapport = try? JSONDecoder().decode(Rapport.self, from: donnees)
            else {
                // Illisible : un rapport à demi écrit par un lancement qui est mort
                // en l'écrivant. Il n'apprendra rien à personne, et il resterait là
                // pour toujours.
                try? gestionnaire.removeItem(at: fichier)
                continue
            }
            if Date().timeIntervalSince1970 - rapport.quand > perime {
                try? gestionnaire.removeItem(at: fichier)
                continue
            }
            let corps = Enveloppe.enveloppe(rapport)
            let code = (poste ?? Enveloppe.poster)(quelleAdresse.url,
                                                  quelleAdresse.entetes(version: version),
                                                  corps)
            // Reçu, ou refusé pour de bon : dans les deux cas il ne repartira pas.
            // Un 4xx est presque toujours notre faute — enveloppe malformée, quota
            // dépassé — et le renvoyer cent fois ne le rendra pas meilleur.
            if (200..<300).contains(code) || (400..<500).contains(code) {
                try? gestionnaire.removeItem(at: fichier)
            } else {
                // Le réseau, ou le service. On s'arrête là : les suivants
                // échoueraient pareil, et la file est de toute façon relue au
                // prochain réveil.
                break
            }
        }
    }

    // MARK: - Le disque

    private static func poser(_ rapport: Rapport, dans dossier: URL) {
        // `.rapport`, et surtout pas `.json` : le compteur du jour et le numéro de
        // machine vivent dans le même dossier, et l'envoi efface tout ce qu'il n'a
        // pas su relire. Une extension à part est ce qui distingue la file de ce qui
        // la gouverne.
        let fichier = dossier.appendingPathComponent("\(rapport.identifiant).rapport",
                                                     isDirectory: false)
        guard let donnees = try? JSONEncoder().encode(rapport) else { return }
        try? donnees.write(to: fichier, options: .atomic)
    }

    /// Le numéro de machine : tiré au sort une fois, gardé, sans aucun lien avec la
    /// personne.
    ///
    /// Il sert à une seule chose, mais elle est décisive : savoir si trente
    /// rapports viennent de trente personnes ou d'une seule qui relance trente
    /// fois. Sans lui, on corrige d'abord ce qui n'arrive qu'à un.
    private static func numeroDeMachine(dans dossier: URL) -> String {
        if let deja = memoireDuNumero { return deja }
        let fichier = dossier.appendingPathComponent("machine.txt", isDirectory: false)
        if let texte = try? String(contentsOf: fichier, encoding: .utf8) {
            let propre = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            if !propre.isEmpty {
                memoireDuNumero = propre
                return propre
            }
        }
        let neuf = Enveloppe.numeroDEvenement()
        try? Data((neuf + "\n").utf8).write(to: fichier, options: .atomic)
        memoireDuNumero = neuf
        return neuf
    }

    /// Le plafond de la journée, tenu dans un fichier parce qu'il doit survivre à
    /// une application qu'on rouvre — c'est précisément quand elle plante en
    /// boucle qu'on la rouvre en boucle.
    private static func consommerLeQuotaDuJour(dans dossier: URL) -> Bool {
        let fichier = dossier.appendingPathComponent("compte.json", isDirectory: false)
        let jour = Int(Date().timeIntervalSince1970 / 86_400)
        var compte = [String: Int]()
        if let donnees = try? Data(contentsOf: fichier),
           let lu = try? JSONDecoder().decode([String: Int].self, from: donnees) {
            compte = lu
        }
        if compte["jour"] != jour { compte = ["jour": jour, "nombre": 0] }
        guard (compte["nombre"] ?? 0) < plafondParJour else { return false }
        compte["nombre"] = (compte["nombre"] ?? 0) + 1
        if let donnees = try? JSONEncoder().encode(compte) {
            try? donnees.write(to: fichier, options: .atomic)
        }
        return true
    }

    // MARK: - L'état

    /// Un seul verrou pour tout : `signaler` peut venir de n'importe quel fil —
    /// l'analyse, la séparation, le rendu — et le fil d'envoi lit pendant ce
    /// temps-là. Il n'y a pas assez de trafic ici pour que la finesse rapporte.
    private static let verrou = NSLock()
    private static let reveil = NSCondition()

    private static var adresse: Enveloppe.Adresse?
    private static var dossier: URL?
    private static var version = Spectre.version
    private static var carteGraphique: String?
    private static var memoireDuNumero: String?
    /// `nil` tant que le disque n'a pas été interrogé.
    /// Ce que ce lancement-ci a déjà signalé, par empreinte.
    private static var duLancement = [String: Rapport]()

    private static let plafondParLancement = 8
    private static let plafondParJour = 40
    /// Trois jours. Passé ce délai, une panne dont personne n'a de nouvelles est
    /// une panne dont la version a peut-être déjà changé.
    private static let perime: Double = 3 * 86_400

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "inconnue"
        #endif
    }

    // MARK: - Le harnais

    /// Remet tout à zéro : la file, les compteurs, l'adresse.
    ///
    /// N'existe que pour `RapportsCheck`, qui doit pouvoir rejouer une dizaine de
    /// fois la même situation dans un seul processus. L'application, elle, ouvre
    /// une fois et ne referme jamais.
    public static func remiseAZeroPourLeHarnais() {
        verrou.lock()
        defer { verrou.unlock() }
        adresse = nil
        dossier = nil
        carteGraphique = nil
        memoireDuNumero = nil
        duLancement = [:]
    }

    /// Ce qui attend sur le disque, du plus ancien au plus récent. Pour le harnais.
    public static func fileEnAttente() -> [String] {
        verrou.lock()
        let ou = dossier
        verrou.unlock()
        guard let ou else { return [] }
        let fichiers = (try? FileManager.default.contentsOfDirectory(at: ou,
                                                                     includingPropertiesForKeys: nil))
            ?? []
        return fichiers.filter { $0.pathExtension == "rapport" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(Rapport.self, from: $0) }
            .sorted { $0.quand < $1.quand }
            .map { "\($0.quoi) [\($0.repetitions)] \($0.origine)" }
    }
}
