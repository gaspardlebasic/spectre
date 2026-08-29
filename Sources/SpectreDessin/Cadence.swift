import Foundation
import SpectreModele

// À quelle vitesse la boucle doit tourner, et pourquoi elle ne doit pas toujours
// tourner à fond.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE FICHIER EXISTE
//
// Sous Windows et sous Linux, la boucle dessinait une image complète à chaque
// tour, sans jamais se demander si quelque chose avait changé. Tant que la fenêtre
// est devant quelqu'un qui fait défiler son morceau, c'est exactement ce qu'il
// faut. Le reste du temps, c'est un cœur brûlé pour redessiner la même image.
//
// Deux mesures l'ont montré, sur un i5 de huitième génération — quatre cœurs, huit
// fils :
//
// - **Fenêtre au second plan, rien en lecture : 15 % du processeur.** Quinze pour
//   cent de huit fils, c'est *un cœur plein*. La chaîne d'échange Direct3D est
//   « waitable » : l'objet d'attente est signalé quand la carte accepte une image
//   de plus. Quand la fenêtre est recouverte, `Present` rend `DXGI_STATUS_OCCLUDED`
//   sans rien mettre en file — l'objet reste donc signalé en permanence, l'attente
//   ne dort plus, et la boucle part à la vitesse du processeur pour dessiner des
//   images que personne ne verra jamais. Le code *savait* que la fenêtre était
//   cachée : `Rendu.fenetreCachee` était relevé à chaque image, et ne servait qu'à
//   noter le relevé de fluidité comme suspect. Personne n'en avait tiré la
//   conséquence évidente.
// - **Fenêtre devant, rien en lecture : soixante images par seconde**, chacune
//   avec son `tick` de modèle, son nuanceur, et toute la surimpression Direct2D —
//   la frise, la batterie, les accords, le panneau, la barre — remise à plat, mot
//   pour mot identique à la précédente.
//
// D'où ce fichier : une règle, une seule, partagée par les deux plateformes.
// Il ne connaît ni Windows ni SDL — il rend une allure, et chaque boucle sait
// comment dormir chez elle.
//
// CE QU'IL NE FAIT PAS. Il ne cherche pas à savoir *ce qui* a changé dans l'image.
// Un dessin qui se souviendrait de ce qu'il a tracé serait plus fin et beaucoup
// plus fragile : une seule chose oubliée, et l'écran se fige sans qu'aucun essai
// ne le dise. Ici, le pire cas est qu'une image tarde d'un dixième de seconde —
// ce qui se rattrape tout seul au tour suivant.
// ─────────────────────────────────────────────────────────────────────────────

/// À quelle allure la boucle doit tourner, maintenant.
public enum Allure: Equatable {
    /// Quelque chose bouge : la cadence de l'écran, et rien de moins. C'est la
    /// seule allure où l'on attend le balayage.
    case pleine
    /// Rien ne bouge, mais quelqu'un regarde. On dessine assez souvent pour qu'un
    /// changement paraisse tout de suite, et assez rarement pour ne rien coûter.
    case repos
    /// Personne ne regarde : la fenêtre est réduite, ou entièrement recouverte. On
    /// ne dessine plus du tout, et l'on ne se réveille que pour savoir si elle est
    /// revenue.
    case arretee
}

/// La règle : ce qui décide de l'allure, et le temps qu'on dort dans chacune.
///
/// Une structure et non un calcul libre, parce qu'elle porte un état — l'instant
/// de la dernière entrée — et parce que `CadenceCheck` l'éprouve sans fenêtre,
/// sans carte graphique et sans système. C'est la seule façon de vérifier une
/// consommation au repos depuis une machine où l'on ne peut pas ouvrir de fenêtre.
public struct Cadence {
    /// Combien de temps la pleine cadence survit à la dernière entrée.
    ///
    /// Une seconde, et non zéro : l'infobulle paraît après un délai passé immobile
    /// au-dessus d'une commande, et le pointeur ne bouge plus pendant ce
    /// délai-là. Retomber au repos entre-temps ferait paraître la bulle en retard,
    /// ce qui se lit comme une application qui traîne. C'est aussi ce qui laisse
    /// l'élan d'un défilement s'éteindre à pleine cadence.
    public static let sursisDUnGeste = 1.0

    /// La période au repos : dix images par seconde.
    ///
    /// Ce n'est pas une cadence d'affichage, c'est un filet. Rien ne bouge, donc
    /// ces dix images sont dix fois la même ; elles ne servent qu'à rattraper ce
    /// que la règle aurait pu ne pas voir — une piste qui finit de charger, un
    /// message qui tombe de la file principale. Un dixième de seconde de retard ne
    /// se voit pas sur une image immobile, et six fois moins d'images valent six
    /// fois moins de processeur.
    public static let periodeDeRepos = 0.1

    /// La période fenêtre cachée : quatre réveils par seconde, sans rien dessiner.
    ///
    /// On ne peut pas simplement attendre un message : sous Windows, une fenêtre
    /// cesse d'être recouverte sans qu'aucun message ne nous parvienne. Il faut
    /// donc aller le demander — d'où un réveil, mais un réveil qui ne coûte qu'un
    /// appel et pas une image.
    public static let periodeCachee = 0.25

    /// Instant de la dernière entrée. Très loin dans le passé au départ : rien ne
    /// justifie de démarrer à pleine cadence sur une fenêtre que personne n'a
    /// encore touchée.
    private var derniereEntree = -1e9

    public init() {}

    /// Une entrée vient d'arriver — molette, clic, touche, menu.
    public mutating func uneEntree() { derniereEntree = Horloge.maintenant() }

    /// L'allure, maintenant.
    ///
    /// - `quelqueChoseBouge` : ce que le modèle dit de lui-même — voir
    ///   `AppModel.quelqueChoseBouge`.
    /// - `fenetreCachee` : ce que la présentation précédente a répondu.
    ///
    /// La fenêtre cachée l'emporte sur tout le reste, **lecture comprise** : un
    /// morceau qui joue derrière une autre fenêtre s'entend, il ne se regarde pas.
    /// Le son ne passe pas par cette boucle.
    public func allure(quelqueChoseBouge: Bool, fenetreCachee: Bool,
                       maintenant: Double = Horloge.maintenant()) -> Allure {
        if fenetreCachee { return .arretee }
        if quelqueChoseBouge { return .pleine }
        if maintenant - derniereEntree < Self.sursisDUnGeste { return .pleine }
        return .repos
    }
}

// MARK: - Ce que coûte une fenêtre qui ne fait rien

/// Le relevé de repos : combien d'images, et combien de processeur, pour une
/// application à laquelle on ne demande rien.
///
/// C'est le pendant de `Mesures` à l'autre bout de l'échelle. `Mesures` répond à
/// « est-ce que ça suit quand on tire dessus » ; celui-ci répond à « est-ce que ça
/// dort quand on la laisse tranquille ». La seconde question n'avait jamais été
/// posée, et c'est pour cela qu'un cœur brûlait derrière une fenêtre recouverte.
///
/// Comme `Mesures`, il ne connaît aucun système : chaque plateforme lui donne des
/// nombres, et il en fait un rapport comparable d'une machine à l'autre.
public enum Repos {
    /// Une passe : un état de fenêtre, et ce qu'il a coûté.
    public struct Passe {
        /// Ce que la passe éprouvait, en clair. Français : c'est un relevé qu'on
        /// lit, pas un texte d'interface.
        public let nom: String
        public let secondes: Double
        public let images: Int
        /// Temps de processeur consommé pendant la passe, tous fils confondus.
        public let processeur: Double

        public init(nom: String, secondes: Double, images: Int, processeur: Double) {
            self.nom = nom
            self.secondes = secondes
            self.images = images
            self.processeur = processeur
        }

        /// Images par seconde.
        public var cadence: Double { secondes > 0 ? Double(images) / secondes : 0 }
        /// Part d'un cœur, en pourcentage. C'est le nombre honnête : celui du
        /// gestionnaire des tâches est celui-ci divisé par le nombre de fils, ce
        /// qui fait passer un cœur plein pour « 15 % » sur une machine à huit fils
        /// et laisse croire à un détail.
        public var partDUnCoeur: Double {
            secondes > 0 ? 100 * processeur / secondes : 0
        }
    }

    /// Le rapport, tel qu'il s'imprime.
    public static func rapport(_ passes: [Passe], fils: Int) -> String {
        var lignes: [String] = []
        let largeur = passes.map(\.nom.count).max() ?? 0
        for passe in passes {
            let nom = passe.nom.padding(toLength: max(largeur, passe.nom.count),
                                        withPad: " ", startingAt: 0)
            lignes.append(String(format: "  %@   %5d images (%5.1f/s)   "
                                 + "%5.2f s de processeur   %5.1f %% d'un cœur",
                                 nom, passe.images, passe.cadence,
                                 passe.processeur, passe.partDUnCoeur))
        }
        // Le nombre de fils est dit, sans quoi le pourcentage ne se compare à rien :
        // c'est très exactement le malentendu qui a laissé passer le défaut.
        let note = fils > 1
            ? "\n  \(fils) fils sur cette machine : 100 % d'un cœur s'y lit "
              + String(format: "%.0f", 100 / Double(fils))
              + " % dans le gestionnaire des tâches."
            : ""
        return "Au repos\n" + lignes.joined(separator: "\n") + "\n" + note
    }
}
