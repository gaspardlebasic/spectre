import Foundation
import SpectreCore
import SpectreDessin
import SpectreModele
import SpectreToile
import SpectreWin
import WinSDK
import SpectreSeparation
import SpectreSocle
import SpectreSon

// Spectre sous Windows.
//
//     SpectreWindows.exe morceau.wav                      ouvre la fenêtre
//     SpectreWindows.exe morceau.wav --rendu i.ppm        dessine hors écran
//     SpectreWindows.exe morceau.wav --photo i.ppm        ouvre, et photographie
//     SpectreWindows.exe morceau.wav --fluidite 10        fait défiler, et compte
//
// `--taille LARGEURxHAUTEUR` et `--gris` valent pour les deux rendus, et sont ceux
// de `SpectreCLI` : c'est ce qui permet de demander la même image aux deux et de
// les confronter par `ImageCheck`.
//
// `--sans-habillage` retire la réglette, la grille, la batterie et la barre : la
// photographie redevient alors comparable au rendu du processeur, que rien
// n'habille. C'est un instrument, pas un mode d'usage.
//
// `--reglages` ouvre le panneau dès le lancement. Même usage : c'est ce qui permet
// de photographier les commandes, donc d'en juger l'allure sans être devant l'écran.
//
// Avant tout le reste : sans cet appel, rien de ce que les instruments ci-dessus
// impriment n'arriverait jusqu'au terminal — voir `Sources/CPont/console.c`.
rattacherLaConsole()

// Et juste après lui, le journal — dans cet ordre, parce que `rattacherLaConsole()`
// est ce qui décide s'il y a un terminal, et que le journal ne prend la place de la
// sortie d'erreur que lorsqu'il n'y en a pas.
//
// C'est ici que le manque a coûté le plus cher : la v0.4 est partie avec un
// installeur qui ne s'ouvrait pas, l'application écrivait pourquoi, et le message
// n'arrivait nulle part. Voir `docs/PAQUETS.md`.
Journal.ouvrir()

// L'application est assemblée ici, et nulle part ailleurs : le comportement vit
// dans `SpectreModele`, les pièces de Windows dans `SpectreWin`, et ce fichier ne
// fait que les brancher les unes aux autres, puis tourner.

/// Le modèle, muni de ce que Windows lui fournit.
///
/// Le `typealias` fait que tout ce qui écrit `AppModel` continue de l'écrire. Le
/// modèle est générique sur son lecteur — parce que l'interface observe
/// `model.player.speed` et qu'un protocole existentiel romprait ce suivi — mais
/// rien d'autre n'a de raison de porter ce détail.
typealias AppModel = SpectreModele.AppModel<LecteurSurLePont>

// Et le même rebouclage pour ce qui dessine. Ces quatre types sont partagés avec
// Linux et portent donc le lecteur en paramètre ; les rattacher ici une fois fait
// que pas un appel de ce fichier n'a changé quand ils ont déménagé.
typealias Frise = SpectreDessin.Frise<LecteurSurLePont>
typealias Batterie = SpectreDessin.Batterie<LecteurSurLePont>
typealias Barre = SpectreDessin.Barre<LecteurSurLePont>
typealias Commandes = SpectreDessin.Commandes<LecteurSurLePont>
typealias Accueil = SpectreDessin.Accueil<LecteurSurLePont>

extension SpectreModele.AppModel where Lecteur == LecteurSurLePont {
    /// L'assemblage Windows : à chaque protocole du modèle, sa mise en œuvre.
    convenience init(fenetre: HWND?) {
        self.init(lecteur: LecteurSurLePont(),
                  décodeur: DecodeurSurLePont(),
                  sinusoide: SinusoideSurLePont(),
                  pistes: RangementSurLePont(),
                  dialogue: DialogueWindows(fenetre: fenetre),
                  récentsDuSystème: RecentsWindows(),
                  extérieur: ExterieurWindows(),
                  préférences: PreferencesWindows.partagees)
    }
}

// MARK: - Les arguments

var morceau: URL?
var rendreDans: String?
var photographierDans: String?
var sansHabillage = false
var reglagesOuverts = false
var mesurerPendant: Double?
var reposPendant: Double?
var tailleVoulue = (largeur: 1200, hauteur: 700)
var arguments = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < arguments.count {
    let argument = arguments[i]
    if argument == "--rendu", i + 1 < arguments.count {
        rendreDans = arguments[i + 1]
        i += 2
    } else if argument == "--fluidite", i + 1 < arguments.count {
        mesurerPendant = Double(arguments[i + 1]) ?? 10
        i += 2
    } else if argument == "--repos", i + 1 < arguments.count {
        reposPendant = Double(arguments[i + 1]) ?? 5
        i += 2
    } else if argument == "--sans-habillage" {
        sansHabillage = true
        i += 1
    } else if argument == "--reglages" {
        reglagesOuverts = true
        i += 1
    } else if argument == "--photo", i + 1 < arguments.count {
        photographierDans = arguments[i + 1]
        i += 2
    } else if argument == "--taille", i + 1 < arguments.count {
        // Le même « 1200x700 » que `SpectreCLI --taille` : c'est ce qui permet de
        // demander aux deux rendus la même image, et donc de les comparer.
        let morceaux = arguments[i + 1].lowercased().split(separator: "x")
        if morceaux.count == 2, let l = Int(morceaux[0]), let h = Int(morceaux[1]),
           l > 0, h > 0 {
            tailleVoulue = (l, h)
        }
        i += 2
    } else if !argument.hasPrefix("--") {
        morceau = URL(fileURLWithPath: argument)
        i += 1
    } else {
        i += 1
    }
}

// MARK: - L'application

/// Ce qui tient la fenêtre, le rendu et le modèle ensemble, et les fait tourner.
///
/// Une classe plutôt que des variables globales : la procédure de fenêtre a besoin
/// de retrouver quelqu'un à qui parler, et un objet est ce qu'elle sait retrouver.
final class Application: EchosDeLaFenetre {
    let fenetre: Fenetre
    let rendu: RenduD3D11
    let modele: AppModel
    let gestes: GestesWindows
    let panneau = Panneau()
    /// Ce qui ne se replie jamais : les quatre pistes et la porte des réglages.
    let flottant = Flottant()
    /// Ce que dit la commande qu'on survole. Partagée par le panneau et la colonne :
    /// il n'y a qu'une souris, donc qu'une bulle à l'écran.
    let infobulle = Infobulle()
    /// La page de lancement, le diaporama du premier lancement et la mise à jour.
    let accueil: Accueil
    let commandes: Commandes
    /// Le titre déjà posé sur la fenêtre. Comparé plutôt que reposé à chaque image :
    /// `SetWindowTextW` fait repeindre la barre de titre, cent vingt fois par seconde
    /// pour rien.
    private var titrePose = ""
    /// Ne compte que si on l'a demandé : mesurer coûte une horloge par image, ce
    /// qui n'est rien, mais garder cent mille intervalles en mémoire pour personne
    /// n'a pas de sens.
    var mesures: Mesures?
    /// Ce qui décide à quelle vitesse la boucle tourne — voir
    /// `SpectreDessin/Cadence.swift`, qui dit le cœur que cela coûtait.
    private var cadence = Cadence()
    /// Ce que la dernière présentation a répondu. Relu par la cadence, et reposé
    /// sans dessiner quand la boucle est arrêtée.
    private var fenetreCachee = false
    /// Compte les images pour `--repos`, quand on le lui demande.
    private var imagesDessinees = 0
    private var enMarche = true
    private var tailleAChanger: (largeur: Int, hauteur: Int)?

    // Les deux échecs possibles sont **dits**, et c'est ce qui manquait. Sans ces
    // messages, une machine sans carte graphique utilisable rend un `exit(1)` muet :
    // pas une fenêtre, pas une ligne, rien. On accuse alors la distribution — une
    // bibliothèque oubliée donne exactement le même silence — et l'on cherche du
    // côté des DLL une panne qui est celle du pilote. Un coureur d'intégration
    // continue a coûté trois exécutions à ce silence-là.
    init?() {
        guard let fenetre = Fenetre(titre: "Spectre", largeur: 1200, hauteur: 700) else {
            Journal.erreur("Windows a refusé d'ouvrir une fenêtre "
                           + "(erreur \(GetLastError())).")
            return nil
        }
        guard let rendu = RenduD3D11(fenetre: UnsafeMutableRawPointer(fenetre.poignee!)) else {
            Journal.erreur("Direct3D 11 n'a pas démarré : pas de carte graphique "
                           + "utilisable, ou un pilote trop ancien.")
            return nil
        }
        self.fenetre = fenetre
        self.rendu = rendu
        self.modele = AppModel(fenetre: fenetre.poignee)
        self.commandes = Commandes(modele: modele,
                                   preferences: PreferencesWindows.partagees)
        self.accueil = Accueil(modele: modele)
        self.gestes = GestesWindows(modele: modele, fenetre: fenetre,
                                    panneau: panneau, flottant: flottant,
                                    accueil: accueil)
        modele.renderer = rendu
        rendu.origineDesTeintes = PreferencesWindows.partagees.hueOrigin
        fenetre.echos = self
        // La surimpression n'est pas indispensable au spectrogramme : si Direct2D
        // manque, l'image reste et l'on perd la réglette. Mieux vaut une application
        // amputée qu'une application qui refuse de s'ouvrir.
        if !rendu.preparerLaSurimpression() {
            Journal.erreur("pas de réglette ni de grille : Direct2D n'a pas démarré.")
        }
        Journal.note("carte : \(rendu.nomDeLaCarte)")
        // La carte part avec les rapports de panne : la moitié de ce qui casse chez
        // les autres casse à cause d'un pilote, et c'est le nom du pilote qui permet
        // de dire « ceux-là, et eux seuls ». Elle n'identifie personne.
        Rapports.carte(rendu.nomDeLaCarte)
    }

    func ouvrir(_ url: URL) {
        modele.open(url)
    }

    /// Le titre suit le morceau, quel que soit le chemin par lequel il est arrivé —
    /// la ligne de commande, le sélecteur de fichiers, un récent du menu.
    ///
    /// Relevé à chaque image et non au moment d'ouvrir : `open` part en tâche de
    /// fond et le nom n'est connu qu'au retour par la file principale. Le poser
    /// aussitôt après l'appel écrivait donc le titre **précédent**.
    private func accorderLeTitre() {
        let voulu = modele.title
        guard voulu != titrePose else { return }
        titrePose = voulu
        fenetre.titre(voulu)
    }

    /// Ouvre la fenêtre, la laisse tourner quelques images, et photographie ce
    /// qu'elle montre — depuis sa propre chaîne d'échange.
    ///
    /// C'est le pendant Windows de `build/essai/fenetre.png` sur le Mac, et il vaut
    /// mieux que lui : l'image ne vient pas de l'écran mais du tampon que la carte
    /// s'apprête à présenter, si bien que rien ne peut la recouvrir et qu'aucune
    /// autorisation n'est à demander. Surtout, elle passe par le chemin de la
    /// *fenêtre* — appareil, chaîne d'échange, présentation — et non par celui du
    /// rendu hors écran, qui n'en éprouve que la moitié.
    func photographier(dans chemin: String, attente: Double = 30) -> Bool {
        fenetre.montrer()
        // On tourne pour de bon jusqu'à ce que la matrice soit là : l'ouverture
        // d'un fichier part en tâche de fond et rend son résultat par la file
        // principale, donc photographier au bout de dix images ne montrerait
        // qu'une fenêtre noire — et ferait accuser le nuanceur.
        let echeance = Horloge.maintenant() + attente
        while Horloge.maintenant() < echeance {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            appliquerLaTaille()
            rendu.attendreLImageSuivante()
            uneImage()
            // On attend que **tout** soit relevé, et pas seulement la matrice : la
            // batterie et les accords arrivent après, et photographier avant les
            // montrerait vides — ce qui se lit comme une ligne cassée plutôt que
            // comme une ligne pas encore remplie. C'est la même attente qu'`essai.sh`
            // observe sur le Mac avant de photographier la fenêtre.
            if modele.spectrogram.columnCount > 0, modele.progress == nil,
               !modele.percussionPending, !modele.chordsPending { break }
        }
        // Sans morceau, il n'y a rien à attendre : c'est la page de lancement — ou le
        // diaporama du premier lancement — qu'on photographie, et elle est prête dès
        // la première image. C'est par là qu'on regarde les deux écrans que tout le
        // reste de l'épreuve ne voit jamais, puisqu'il ouvre toujours un fichier.
        guard modele.source != nil || modele.spectrogram.columnCount > 0 else {
            for _ in 0..<10 {
                viderLaFilePrincipale()
                _ = fenetre.traiterLesMessages()
                appliquerLaTaille()
                rendu.attendreLImageSuivante()
                uneImage()
            }
            uneImageSansPresenter()
            return ecrire(dans: chemin)
        }
        guard modele.spectrogram.columnCount > 0 else {
            Journal.erreur("Rien n'a été analysé en \(Int(attente)) s"
                           + (modele.status.map { " — \($0)" } ?? "") + ".")
            return false
        }

        // La dernière image est dessinée **sans être présentée** : la chaîne est en
        // modèle *flip*, et présenter abandonne le contenu du tampon zéro. Le relire
        // après coup ne rendrait que du noir — ce qui ressemble en tout point à un
        // nuanceur qui ne dessine rien.
        uneImageSansPresenter()
        return ecrire(dans: chemin)
    }

    /// Relit le tampon que la carte s'apprête à présenter, et l'écrit.
    private func ecrire(dans chemin: String) -> Bool {
        guard let pixels = rendu.relire() else {
            Journal.erreur("La chaîne d'échange n'a rien rendu.")
            return false
        }
        do {
            try PPM.write(width: rendu.largeur, height: rendu.hauteur,
                          pixels: pixels, to: URL(fileURLWithPath: chemin))
        } catch {
            Journal.erreur("\(error)")
            return false
        }
        print("→ \(chemin) (\(rendu.largeur)×\(rendu.hauteur))")
        return true
    }

    // MARK: La boucle

    func tourner() {
        // Les rapports de panne s'ouvrent **ici**, et pas plus tôt : `--photo` et
        // `--fluidite` rendent une image puis s'arrêtent sans jamais passer par cette
        // fonction. Une machine d'intégration continue n'a aucune raison d'envoyer
        // quoi que ce soit, et une panne de coureur n'apprend rien sur les gens qui
        // se servent de l'application. Ce qui part vient d'une fenêtre ouverte devant
        // quelqu'un. Voir `docs/RAPPORTS.md`.
        Rapports.ouvrir()
        fenetre.montrer()
        while enMarche {
            viderLaFilePrincipale()
            if !fenetre.traiterLesMessages() { break }
            appliquerLaTaille()
            unTour()
        }
        modele.applicationVaSeFermer()
        PreferencesWindows.partagees.enregistrerMaintenant()
    }

    /// Un tour de boucle, à l'allure qui convient.
    ///
    /// Trois allures, et trois façons d'attendre. La règle qui choisit est dans
    /// `SpectreDessin/Cadence.swift`, avec la mesure qui l'a fait écrire ; ici il
    /// n'y a que ce que Windows sait faire de chacune.
    private func unTour() {
        switch cadence.allure(quelqueChoseBouge: modele.quelqueChoseBouge,
                              fenetreCachee: fenetreCachee) {
        case .pleine:
            // On dort **avant** de dessiner : l'image montrée porte alors l'état le
            // plus frais possible, et c'est ce qui la garde collée au doigt. Dormir
            // après avoir présenté reviendrait à dessiner un état déjà vieux d'une
            // image.
            rendu.attendreLImageSuivante()
            uneImage()

        case .repos:
            // Et non l'objet d'attente de la chaîne d'échange : il ne sait cadencer
            // qu'au balayage, c'est-à-dire soixante fois par seconde, ce qui est
            // précisément ce qu'on cherche à ne pas faire.
            dormirJusquAUneEntree(Cadence.periodeDeRepos)
            uneImage()

        case .arretee:
            // Rien n'est dessiné, rien n'est présenté. On se réveille seulement
            // pour demander à la carte si la fenêtre est revenue — un `Present` de
            // pur essai, qui ne coûte pas une image.
            dormirJusquAUneEntree(Cadence.periodeCachee)
            rendu.releverSiCachee()
            fenetreCachee = rendu.fenetreCachee
        }
    }

    private func appliquerLaTaille() {
        guard let taille = tailleAChanger else { return }
        tailleAChanger = nil
        rendu.redimensionner(largeur: taille.largeur, hauteur: taille.hauteur)
    }

    private func uneImage() {
        uneImageSansPresenter()
        rendu.presenter()
        fenetreCachee = rendu.fenetreCachee
        imagesDessinees += 1
        mesures?.uneImage()
        if rendu.fenetreCachee { mesures?.uneImageCachee() }
        accorderLeTitre()
        // Les réglages d'application s'écrivent quand ils ont cessé de bouger. Le
        // tour de boucle est le seul endroit qui passe assez souvent pour le savoir
        // — voir `PreferencesWindows`.
        PreferencesWindows.partagees.enregistrerSiBesoin()
    }

    /// Hauteur de la zone du spectrogramme, en points : la fenêtre moins la ligne de
    /// batterie et la barre d'état.
    ///
    /// C'est **cette hauteur-là** que le modèle reçoit, et non celle de la fenêtre :
    /// tout ce qu'il calcule — la bande passante du filtre, l'aimantation, le
    /// contraste automatique — porte sur ce qu'on voit du spectre, pas sur ce que la
    /// fenêtre mesure.
    private func hauteurDeLImage(_ hauteurTotale: Double) -> Double {
        guard habille else { return hauteurTotale }
        return max(hauteurTotale - hauteurDeLaBatterie - hauteurDeLaBarre, 60)
    }

    /// Faux avec `--sans-habillage` : ni réglette, ni grille, ni batterie, ni barre.
    ///
    /// Ce n'est pas un mode d'usage, c'est un instrument. La surimpression couvre
    /// une partie de l'image, si bien qu'une photographie habillée ne se compare
    /// plus au rendu du processeur : `ImageCheck` trouverait un désaccord partout où
    /// passe un trait de grille. Sans habillage, la photographie éprouve exactement
    /// ce qu'elle éprouvait avant l'étape 7 — le chemin de la fenêtre, de bout en
    /// bout — et reste mesurable.
    var habille = true

    private func uneImageSansPresenter() {
        let points = fenetre.taillePoints
        let hauteurImage = hauteurDeLImage(points.hauteur)
        modele.tick(viewSize: CGSize(width: points.largeur, height: hauteurImage))
        rendu.viewport = modele.viewport
        rendu.display = modele.display
        rendu.origineDesTeintes = PreferencesWindows.partagees.hueOrigin
        rendu.teteDeLecture = colonne(deLInstant: modele.playhead)
        rendu.boucle = modele.loop.flatMap { plage in
            guard let debut = colonne(deLInstant: plage.lowerBound),
                  let fin = colonne(deLInstant: plage.upperBound), fin > debut
            else { return nil }
            return debut...fin
        }
        // Sans habillage, le spectrogramme prend toute la fenêtre : c'est ce qui rend
        // la photographie comparable au rendu du processeur, qui n'a ni réglette ni
        // ligne de batterie. Voir `--sans-habillage`.
        let zone = habille ? hauteurImage : points.hauteur
        rendu.zone(largeur: points.largeur, hauteur: zone, echelle: fenetre.echelle)
        rendu.dessiner(echelle: fenetre.echelle)
        guard habille else { return }

        // Et par-dessus, tout ce qui est du texte et des traits. Une seule
        // présentation part : Direct2D écrit dans le tampon que le nuanceur vient de
        // remplir.
        rendu.surimprimer(echelle: fenetre.echelle) { pinceau in
            Frise(modele: modele, pinceau: pinceau,
                  largeur: points.largeur, hauteur: hauteurImage).dessiner()
            // La page de lancement au milieu de l'image, tant qu'il n'y a rien à
            // montrer. Sous la colonne des pistes et sous le panneau, qui restent
            // atteignables : ce n'est pas une modale, c'est ce que la fenêtre montre
            // quand elle est vide.
            if accueil.pageAMontrer {
                accueil.dessinerLaPage(pinceau, largeur: points.largeur,
                                       hauteur: hauteurImage)
            }
            Batterie(modele: modele, pinceau: pinceau, largeur: points.largeur,
                     haut: hauteurImage, hauteur: hauteurDeLaBatterie).dessiner()
            // Le panneau vient après la frise et avant la barre : il flotte sur
            // l'image, et la barre d'état reste lisible par-dessus tout — c'est là
            // que se dit ce qui se passe pendant qu'on tourne un réglage.
            panneau.dessiner(pinceau: pinceau, infobulle: infobulle,
                             largeurFenetre: points.largeur,
                             hauteurUtile: points.hauteur - hauteurDeLaBarre) {
                commandes.dessiner(dans: $0)
            }
            // La colonne par-dessus le panneau, et non l'inverse : elle est ce qui
            // ne se replie jamais, et le panneau vient se ranger à sa gauche.
            flottant.dessiner(pinceau: pinceau, infobulle: infobulle,
                              largeurFenetre: points.largeur,
                              modele: modele, panneauOuvert: panneau.ouvert) {
                gestes.basculerLePanneau()
            }
            Barre(modele: modele, pinceau: pinceau, largeur: points.largeur,
                  haut: points.hauteur - hauteurDeLaBarre,
                  hauteur: hauteurDeLaBarre).dessiner()
            // L'infobulle en dernier, et hors de toute découpe : elle se pose à
            // gauche de la commande survolée, donc en dehors du panneau qui la
            // couperait net, et par-dessus la colonne et la barre qui viennent
            // d'être dessinées.
            infobulle.dessiner(pinceau, largeurFenetre: points.largeur,
                               hauteurFenetre: points.hauteur)
            // Et les couches du lancement par-dessus l'infobulle elle-même : tant
            // que le diaporama ou la mise à jour est là, il n'y a rien d'autre à
            // lire dans cette fenêtre.
            accueil.dessinerLesCouches(pinceau, largeurFenetre: points.largeur,
                                       hauteurFenetre: points.hauteur)
        }
    }

    /// Le nuanceur raisonne en colonnes, comme tout le reste du rendu : la
    /// conversion se fait ici, une fois, plutôt que dans le nuanceur qui n'a que
    /// faire des secondes.
    private func colonne(deLInstant t: Double) -> Double? {
        let matrice = modele.spectrogram
        guard matrice.columnCount > 0, matrice.secondsPerColumn > 0 else { return nil }
        return matrice.column(atTime: t)
    }

    // MARK: Ce que la fenêtre fait savoir

    func fenetreRedimensionnee(largeur: Int, hauteur: Int) {
        tailleAChanger = (largeur, hauteur)
    }

    func fenetreChangeDEchelle(_ echelle: Double) {
        let pixels = fenetre.taillePixels
        tailleAChanger = (pixels.largeur, pixels.hauteur)
    }

    func fenetreDemandeUneImage() {
        // Windows tourne dans sa propre boucle pendant qu'on tire un bord de la
        // fenêtre, et la nôtre ne reprend qu'au relâchement. Redessiner d'ici est ce
        // qui empêche l'image de rester figée pendant tout ce temps — ce qui se lit
        // comme un plantage.
        appliquerLaTaille()
        uneImage()
    }

    func fenetrePeutSeFermer() -> Bool {
        enMarche = false
        return true
    }

    func fenetreRecoitUneEntree(_ message: UINT, _ w: WPARAM, _ l: LPARAM) -> Bool {
        gestes.mesures = mesures
        // Une main sur la fenêtre remet la boucle à pleine cadence, et pour une
        // seconde — même si le geste n'est pas compris. C'est ici, et non dans le
        // modèle : un modèle ne sait pas qu'une souris existe.
        cadence.uneEntree()
        return gestes.repondre(message, w, l)
    }

    // MARK: La fluidité

    /// Fait défiler l'image pendant `secondes`, et rend le compte de ce que cela a
    /// coûté.
    ///
    /// Le défilement est **posté à notre propre fenêtre** en vrais messages de
    /// molette : le geste traverse donc exactement le même chemin qu'un doigt sur
    /// le pavé — procédure de fenêtre, traduction, modèle, recadrage, nuanceur,
    /// présentation. Piloter le viewport directement mesurerait le rendu, pas
    /// l'application.
    func mesurerLaFluidite(secondes: Double) -> String {
        let compteur = Mesures(cadence: cadenceDeLEcran())
        mesures = compteur
        fenetre.montrer()

        // On laisse d'abord l'analyse finir : mesurer pendant qu'un cœur calcule la
        // matrice donnerait le coût de l'analyse, pas celui du défilement.
        let limite = Horloge.maintenant() + 30
        while modele.spectrogram.columnCount == 0, Horloge.maintenant() < limite {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            rendu.attendreLImageSuivante()
            uneImage()
        }
        // Une seconde de chauffe, jetée. La chaîne d'échange met quelques images à
        // se caler sur le balayage, et la première image après l'analyse porte
        // encore le téléversement de la matrice — des centaines de mégaoctets vers
        // la carte, qui n'ont rien à voir avec le défilement qu'on mesure.
        let chauffe = Horloge.maintenant() + 1
        while Horloge.maintenant() < chauffe {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            rendu.attendreLImageSuivante()
            uneImage()
        }
        compteur.recommencer()

        let echeance = Horloge.maintenant() + secondes
        var sens = 1
        var tours = 0
        while Horloge.maintenant() < echeance {
            // Un cran de molette à chaque image, et l'on change de sens de temps en
            // temps pour rester dans la matrice plutôt que de buter contre son bord.
            tours += 1
            if tours % 120 == 0 { sens = -sens }
            if let poignee = fenetre.poignee {
                let cran = WPARAM(UInt32(bitPattern: Int32(sens * 120) << 16))
                PostMessageW(poignee, UINT(WM_MOUSEHWHEEL), cran, 0)
            }
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            appliquerLaTaille()
            rendu.attendreLImageSuivante()
            uneImage()
        }
        mesures = nil
        return compteur.rapport(carte: rendu.nomDeLaCarte)
    }

    // MARK: Le repos

    /// Ce que coûte l'application quand on ne lui demande rien — devant, puis
    /// réduite.
    ///
    /// **La fenêtre est réduite par programme**, et c'est tout l'intérêt : le
    /// défaut d'origine ne se voyait qu'application au second plan, c'est-à-dire
    /// dans l'état où personne ne regarde jamais un relevé. `ShowWindow` met la
    /// fenêtre dans cet état-là sans qu'une main y soit pour rien, et la mesure
    /// revient toute seule. Voir `SpectreDessin/Cadence.swift`.
    ///
    /// On laisse d'abord l'analyse finir, comme le relevé de fluidité : mesurer un
    /// repos pendant qu'un cœur calcule la matrice mesurerait l'analyse.
    func mesurerLeRepos(secondes: Double) -> String {
        fenetre.montrer()
        let limite = Horloge.maintenant() + 30
        while Horloge.maintenant() < limite {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            appliquerLaTaille()
            rendu.attendreLImageSuivante()
            uneImage()
            if modele.spectrogram.columnCount > 0 || modele.source == nil,
               modele.progress == nil, !modele.percussionPending,
               !modele.chordsPending { break }
        }

        func passe(_ nom: String, secondes: Double) -> Repos.Passe {
            // Une demi-seconde jetée avant de compter : la fenêtre vient de changer
            // d'état, et l'allure met un tour ou deux à retomber.
            let chauffe = Horloge.maintenant() + 0.5
            while Horloge.maintenant() < chauffe {
                viderLaFilePrincipale()
                _ = fenetre.traiterLesMessages()
                unTour()
            }
            imagesDessinees = 0
            let departHorloge = Horloge.maintenant()
            let departProcesseur = Horloge.tempsProcesseur()
            while Horloge.maintenant() - departHorloge < secondes {
                viderLaFilePrincipale()
                _ = fenetre.traiterLesMessages()
                unTour()
            }
            return Repos.Passe(nom: nom,
                               secondes: Horloge.maintenant() - departHorloge,
                               images: imagesDessinees,
                               processeur: Horloge.tempsProcesseur() - departProcesseur)
        }

        var relevés: [Repos.Passe] = []
        relevés.append(passe("fenêtre devant, rien en lecture", secondes: secondes))
        if let poignee = fenetre.poignee {
            ShowWindow(poignee, SW_MINIMIZE)
            relevés.append(passe("fenêtre réduite", secondes: secondes))
            ShowWindow(poignee, SW_RESTORE)
        }
        return Repos.rapport(relevés, fils: ProcessInfo.processInfo.activeProcessorCount)
    }
}

// MARK: - Le rendu hors écran

// `--rendu` fait le travail d'une fenêtre sans en ouvrir une : c'est ce qui permet
// de mesurer l'image là où il n'y a pas de bureau, et de la comparer au rendu
// processeur par `ImageCheck`.
if let sortie = rendreDans {
    guard let morceau else {
        Journal.erreur("« --rendu » demande un fichier à rendre.")
        exit(2)
    }
    guard let rendu = RenduD3D11(largeur: tailleVoulue.largeur,
                                hauteur: tailleVoulue.hauteur) else { exit(1) }
    let source: AudioSource
    do {
        source = try DecodeurSurLePont().charger(morceau)
    } catch {
        Journal.erreur("\(error)")
        exit(1)
    }
    let reglages = AnalysisSettings(reassignment: PreferencesWindows.partagees.reassignment)
    let matrice = OfflineAnalysis.run(samples: source.mono,
                                      sampleRate: source.sampleRate,
                                      settings: reglages)
    rendu.layout = matrice.layout
    rendu.upload(matrice)
    rendu.viewport = Viewport.fitting(columns: matrice.columnCount, bins: matrice.binCount,
                                      size: (Double(tailleVoulue.largeur),
                                             Double(tailleVoulue.hauteur)))
    // Le même réglage automatique que dans l'application, et que dans `SpectreCLI`.
    // Sans lui les deux rendus ne comparent plus la même chose : l'image du GPU
    // sort avec le contraste d'origine et celle du processeur avec le contraste
    // réglé, ce qui se lit comme un désaccord de nuanceur alors que la formule est
    // la même des deux côtés.
    if let regle = AutoContrast.settings(basedOn: rendu.display, in: matrice) {
        rendu.display = regle
    }
    // `--gris`, comme `SpectreCLI --gris` : voir là-bas pourquoi la palette des
    // notes empêche de comparer deux rendus sur leur géométrie.
    if arguments.contains("--gris") { rendu.display.colorMap = .gray }
    rendu.dessiner(echelle: 1)
    guard let pixels = rendu.relire() else {
        Journal.erreur("La carte n'a rien rendu.")
        exit(1)
    }
    do {
        try PPM.write(width: tailleVoulue.largeur, height: tailleVoulue.hauteur, pixels: pixels,
                      to: URL(fileURLWithPath: sortie))
    } catch {
        Journal.erreur("\(error)")
        exit(1)
    }
    print("→ \(sortie)")
    exit(0)
}

// MARK: - La fenêtre

guard let application = Application() else { exit(1) }
application.habille = !sansHabillage
// Le panneau est fermé au lancement — on ouvre l'application pour regarder une
// image, pas pour régler quelque chose. `--reglages` sert à le photographier : c'est
// le seul moyen d'en juger l'allure sans être devant la machine.
application.panneau.ouvert = reglagesOuverts
if let morceau { application.ouvrir(morceau) }
if let photographierDans {
    exit(application.photographier(dans: photographierDans) ? 0 : 1)
}
if let mesurerPendant {
    print(application.mesurerLaFluidite(secondes: mesurerPendant))
    exit(0)
}
if let reposPendant {
    print(application.mesurerLeRepos(secondes: reposPendant))
    exit(0)
}
// La question de la version, posée au dépôt sur un fil à part. C'est le même appel
// que sur le Mac.
//
// Seulement sur le chemin de la fenêtre : `--photo` et `--fluidite` rendent une
// image puis s'arrêtent, et une machine d'intégration continue n'a aucune raison
// d'interroger GitHub. C'est la même règle que pour `Rapports.ouvrir` — ce qui sort
// de la machine sort d'une fenêtre ouverte devant quelqu'un.
application.modele.demarrer()
application.tourner()
