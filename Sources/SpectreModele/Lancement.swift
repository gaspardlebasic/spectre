import Foundation
import Observation
import SpectreCore

// Ce qui se passe entre le double-clic sur l'icône et le premier morceau.
//
// ─────────────────────────────────────────────────────────────────────────────
// TROIS CHOSES, ET LEUR ORDRE
//
// 1. **Le diaporama**, une seule fois dans la vie de l'installation : deux
//    diapositives qui montrent ce que l'application sait faire et qu'on ne
//    devinerait pas — la boucle au ralenti, les quatre pistes — et la phrase sur
//    les rapports de panne, qui remplace la modale qu'on montrait avant.
// 2. **La mise à jour**, s'il y en a une. Après le diaporama : quelqu'un qui
//    découvre l'application n'a pas à répondre d'abord à une question sur les
//    numéros de version.
// 3. **La page des morceaux**, dessous, et à chaque lancement. Ce n'est pas une
//    modale : c'est ce que la fenêtre montre tant qu'aucun morceau n'est ouvert.
//
// L'ordre tient donc tout seul, sans machine à états : les deux premières sont des
// couches par-dessus la troisième, et chacune sait si elle est encore là.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUE CETTE PAGE A REMPLACÉ
//
// L'application rouvrait le dernier morceau toute seule. C'était commode le jour
// où l'on retravaille le même passage, et c'était faux tous les autres jours :
// ouvrir Spectre lançait une minute de GPU sur un morceau dont on ne voulait pas,
// et la seule façon d'y échapper était d'être plus rapide que le délai d'une demi-
// seconde. La liste rend le choix, et le rend sans rien coûter — un clic sur la
// première ligne fait exactement ce que faisait l'ouverture automatique.
// ─────────────────────────────────────────────────────────────────────────────

/// Une ligne de la page de lancement.
public struct MorceauRecent: Identifiable, Equatable, Sendable {
    public let url: URL
    /// Le nom du fichier sans son extension : « .mp3 » répété douze fois n'aide
    /// personne à reconnaître un morceau.
    public let nom: String
    /// Ses pistes sont-elles déjà rangées ? C'est ce qui distingue un morceau qu'on
    /// rouvre en deux secondes d'un morceau qui redemandera des minutes — et c'est
    /// aussi ce que la corbeille de la ligne va jeter.
    public let separe: Bool

    public var id: URL { url }

    public init(url: URL, nom: String, separe: Bool) {
        self.url = url
        self.nom = nom
        self.separe = separe
    }
}

/// L'écran d'accueil, le diaporama et la mise à jour : ce que l'application montre
/// avant qu'un morceau soit ouvert.
///
/// Il vit ici et non dans une vue parce que c'est du comportement — quand le
/// diaporama revient, ce que la corbeille emporte, dans quel ordre les couches se
/// présentent. Les trois systèmes le dessinent chacun à sa façon et lisent tous ces
/// propriétés-là.
///
/// **Non générique**, contrairement à `AppModel` : rien ici ne touche au lecteur.
/// C'est ce qui permet à `LancementCheck` de l'éprouver sans monter une carte son.
@Observable public final class Lancement {

    @ObservationIgnored private let pistes: ServiceDeSeparation
    @ObservationIgnored private let exterieur: Exterieur

    public init(pistes: ServiceDeSeparation, exterieur: Exterieur) {
        self.pistes = pistes
        self.exterieur = exterieur
        morceaux = Self.relever(pistes)
        diaporama = Bienvenue.aMontrer
    }

    // MARK: - Le diaporama du premier lancement

    /// Nombre de diapositives. Les textes sont dans `SpectreTextes`, les images
    /// dans les ressources de chaque paquet ; ce nombre est ce qui les compte.
    public static let diapositives = 2

    /// Le diaporama est-il encore à l'écran ?
    public private(set) var diaporama: Bool

    /// La diapositive montrée, de 0 à `diapositives - 1`.
    public private(set) var diapositive = 0

    /// Vrai sur la dernière : le bouton dit alors « Commencer » et non « Suivant ».
    public var derniereDiapositive: Bool { diapositive >= Self.diapositives - 1 }

    /// Avance d'une diapositive, ou referme quand il n'y en a plus.
    public func suivant() {
        if derniereDiapositive { fermerLeDiaporama() } else { diapositive += 1 }
    }

    /// Referme, et pour de bon : le témoin est écrit sur le disque tout de suite.
    ///
    /// Tout de suite, et non à la fermeture de l'application : quelqu'un dont la
    /// première séance finit par un plantage a quand même vu le diaporama, et le lui
    /// remontrer serait la deuxième mauvaise nouvelle de la journée.
    public func fermerLeDiaporama() {
        guard diaporama else { return }
        diaporama = false
        Bienvenue.montre()
    }

    /// La phrase des rapports de panne est-elle à écrire sur la seconde
    /// diapositive ?
    ///
    /// Faux quand rien ne part — pas d'adresse d'envoi, ou `SPECTRE_RAPPORTS=non`.
    /// Annoncer un envoi qu'on ne fait pas serait une fausse déclaration dans
    /// l'autre sens, et c'est déjà la règle qui valait pour la modale d'avant.
    public var rapportsAAnnoncer: Bool { Rapports.actifs }

    // MARK: - La mise à jour

    /// La version trouvée en face, quand elle est plus récente que celle qui tourne.
    public private(set) var livraison: MiseAJour.Livraison?
    /// La modale a été refermée : on ne repose pas la question de ce lancement-ci.
    ///
    /// **Observé, et il faut qu'il le soit.** Ce drapeau a porté `@ObservationIgnored`
    /// de sa naissance jusqu'à la 0.7, et la modale de mise à jour restait alors
    /// collée à l'écran sur le Mac : les deux boutons faisaient leur travail, mais
    /// SwiftUI n'apprenait jamais que `miseAJourAMontrer` venait de changer, et il n'y
    /// avait plus aucun moyen de refermer la fenêtre. Windows et Linux y échappaient
    /// — eux relisent l'état à chaque image, et se moquent de savoir qui les prévient.
    ///
    /// La leçon vaut pour tout ce qu'on ajoutera ici : ce que la vue lit doit être
    /// observé, et `@ObservationIgnored` est réservé à ce qu'aucune vue ne regarde.
    private var refermee = false

    /// La modale de mise à jour est-elle à l'écran ?
    ///
    /// **Après le diaporama**, et c'est cette ligne qui le dit. Sans elle, quelqu'un
    /// qui installe l'application le jour d'une livraison verrait les deux
    /// superposées.
    ///
    /// Et jamais pour une version écartée : celle-là a reçu sa réponse une fois pour
    /// toutes, la reposer à chaque ouverture ne ferait qu'apprendre à cliquer sans
    /// lire.
    public var miseAJourAMontrer: Bool {
        guard !diaporama, !refermee, let livraison else { return false }
        return livraison.version != MiseAJourEcartee.version
    }

    /// La version qui tourne, telle qu'elle s'écrit dans la modale.
    public var versionCourante: String { Spectre.version }

    /// Referme la modale pour ce lancement-ci, sans rien décider de plus.
    ///
    /// C'est ce que fait Échap, et ce que fait « Télécharger » en partant : le choix
    /// durable, c'est l'autre bouton.
    public func fermerLaMiseAJour() { refermee = true }

    /// « Ignorer cette version » : elle ne sera plus proposée, à aucun lancement.
    ///
    /// Le numéro part sur le disque tout de suite — voir `MiseAJourEcartee`. La
    /// livraison suivante, elle, reposera la question : on écarte une version, pas
    /// les mises à jour.
    public func ignorerCetteVersion() {
        refermee = true
        guard let livraison else { return }
        MiseAJourEcartee.ecarter(livraison.version)
    }

    /// Ouvre la page des versions dans le navigateur, et referme la modale.
    ///
    /// L'application ne télécharge rien et n'installe rien : voir `MiseAJour`, qui
    /// dit pourquoi. Ce qui se passe ensuite est le geste ordinaire — on prend le
    /// paquet, on remplace l'application.
    public func telecharger() {
        guard let livraison else { return }
        refermee = true
        exterieur.ouvrirLaPage(livraison.page)
    }

    /// Pose la question au dépôt, sur un fil à part.
    ///
    /// Appelée une fois par lancement, par la plateforme, quand la fenêtre est déjà
    /// là. La réponse revient par la file principale : c'est un état observé, et il
    /// se change là où l'interface le lit.
    public func chercherUneMiseAJour() {
        MiseAJour.chercher { [weak self] trouvee in
            guard let trouvee else { return }
            DispatchQueue.main.async { self?.proposer(trouvee) }
        }
    }

    /// Pose la version trouvée, d'où qu'elle vienne.
    ///
    /// Séparée de la recherche, et publique, parce que c'est **le seul point où cet
    /// état change** : ce qui l'observe se lit d'un coup d'œil, et `LancementCheck`
    /// éprouve l'ordre des couches sans monter de réseau ni de file principale.
    public func proposer(_ trouvee: MiseAJour.Livraison) { livraison = trouvee }

    // MARK: - Les morceaux déjà ouverts

    /// Du plus récent au plus ancien, ceux qui existent encore.
    public private(set) var morceaux: [MorceauRecent]

    /// Relit la liste. À appeler quand un morceau s'ouvre : il passe alors en tête.
    public func rafraichir() { morceaux = Self.relever(pistes) }

    /// Retire un morceau de la liste, **et jette ses pistes séparées**.
    ///
    /// Les deux ensemble, et c'est le sens du geste : la corbeille d'une ligne veut
    /// dire « je n'y reviendrai pas », et ce morceau occupe alors trois cents
    /// mégaoctets de pistes qui ne servent plus à personne. Retirer la ligne en
    /// laissant les pistes ferait de cette page un endroit où l'on croit faire de la
    /// place sans en faire.
    ///
    /// Le fichier audio, lui, n'est pas touché. Il n'est pas à nous.
    public func oublier(_ url: URL) {
        if let empreinte = SessionStore.fingerprint(of: url) {
            pistes.oublierLesPistes(empreinte: empreinte)
        }
        RecentFiles.remove(url)
        rafraichir()
    }

    /// Vide la liste entière, sans toucher aux pistes.
    ///
    /// C'est « Vider le menu », qui est un geste de rangement et non de ménage : on
    /// ne veut plus voir la liste, on ne demande pas à recalculer des heures de GPU.
    /// La corbeille d'une ligne, elle, dit le contraire — voir `oublier`.
    public func toutOublier() {
        RecentFiles.clear()
        rafraichir()
    }

    /// L'empreinte est relevée ici, une fois par ligne et non à chaque image : elle
    /// coûte deux lectures de 64 ko par fichier, ce qui ne se voit pas une fois et
    /// se verrait cent vingt fois par seconde sur les systèmes qui dessinent
    /// eux-mêmes leur interface.
    private static func relever(_ pistes: ServiceDeSeparation) -> [MorceauRecent] {
        RecentFiles.all().map { url in
            let empreinte = SessionStore.fingerprint(of: url)
            return MorceauRecent(url: url,
                                 nom: url.deletingPathExtension().lastPathComponent,
                                 separe: empreinte.map { pistes.estSepare($0) } ?? false)
        }
    }

    // MARK: - Le dossier des pistes

    /// Montre dans l'explorateur de fichiers le dossier où les pistes sont rangées.
    ///
    /// Le panneau de réglages dit ce que ce dossier occupe et sait le vider ; il
    /// manquait de pouvoir simplement aller voir — pour reprendre une piste isolée
    /// dans un autre logiciel, ou pour comprendre où sont passés les gigaoctets.
    public func montrerLeDossierDesPistes() {
        guard let dossier = Storage.pistes else { return }
        exterieur.montrerLeDossier(dossier)
    }

    /// Vrai quand il y a un dossier à montrer.
    public var dossierDesPistesExiste: Bool { Storage.pistes != nil }
}
