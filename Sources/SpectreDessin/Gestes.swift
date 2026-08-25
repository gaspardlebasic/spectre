import Foundation
import SpectreCore
import SpectreModele

// Ce que la souris et le clavier font au modèle.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE MÊME GESTE, PAS UN GESTE QUI LUI RESSEMBLE
//
// Chaque ligne de ce fichier a son pendant exact dans
// `Sources/Spectre/TimelineView.swift`, et appelle **la même méthode du modèle**.
// C'est la seule discipline qui empêche les applications de diverger : dès qu'un
// geste est réimplémenté au lieu d'être rebranché, il perd une subtilité par mois —
// l'aimantation qu'on relâche, la boucle qu'on rattrape par un bord, le tourne-page
// qu'un défilement annule.
//
// POURQUOI CE FICHIER EST PARTAGÉ, ET CE QUE ÇA A COÛTÉ
//
// Il vivait dans `SpectreWindows` et parlait `WPARAM`, `LPARAM`, `WM_MOUSEWHEEL`.
// En regardant ce qu'il touchait vraiment du système : **huit appels** sur quatre
// cents lignes — la forme du curseur, la capture de la souris, l'état de Ctrl et
// Majuscule, le délai du double-clic, et le réglage « lignes par cran ». Tout le
// reste est du calcul sur le modèle, et n'avait aucune raison d'être écrit deux
// fois.
//
// Ces huit appels sont devenus `SurfaceDeGestes`, que chaque plateforme remplit :
// Win32 avec `SetCursor`, `SetCapture`, `GetKeyState` ; SDL avec `SDL_SetCursor`,
// `SDL_CaptureMouse`, `SDL_GetModState`. Le reste de ce fichier n'a pas bougé d'une
// ligne, et c'est la mesure de ce que la séparation valait.
//
// Ce qui change d'une plateforme à l'autre, ce sont les **touches** :
//
// | geste                          | macOS                | Windows et Linux     |
// |--------------------------------|----------------------|----------------------|
// | zoom sur le temps              | ⌥ ou ⌘ + molette     | Ctrl + molette       |
// | zoom sur les fréquences        | ⇧ + molette          | ⇧ + molette          |
// | tracer une boucle n'importe où | ⇧ + glisser          | ⇧ + glisser          |
// | libérer de la grille           | ⌘ pendant le glisser | Ctrl pendant le glisser |
//
// Ctrl remplace ⌘, ce qui est la correspondance habituelle, et il n'entre en
// conflit avec rien : la molette et le glisser sont deux gestes différents.
// ─────────────────────────────────────────────────────────────────────────────

/// À quelle distance d'un bord de boucle on l'attrape.
public let priseDuBord = 7.0

/// Ce qu'un glisser en cours est en train de faire à la boucle.
enum GlisserDeBoucle {
    case creation(ancre: Double)
    case deplacement(prise: Double)
    case bord(LoopEdge)
}

/// Les trois formes que le curseur prend, et rien de plus.
///
/// Une énumération plutôt qu'un identifiant système : ce que le geste veut dire est
/// « on peut tirer ce bord », pas « `IDC_SIZEWE` ». Chaque plateforme traduit.
public enum FormeDuCurseur {
    case fleche
    /// On peut tirer ce bord horizontalement.
    case largeur
    /// On peut attraper et déplacer.
    case main
}

/// Les touches auxquelles l'application répond.
///
/// Nommées par ce qu'elles sont sur le clavier, et non par ce qu'elles font : c'est
/// `Gestes` qui décide ce qu'elles font, et il le décide au même endroit pour tout
/// le monde. Chaque plateforme n'a plus qu'à traduire son propre code de touche.
public enum ToucheDeSpectre {
    case espace, gauche, droite, echappement
    case crochetOuvrant, crochetFermant
    case l, b, r, o
    case un
}

/// Les huit choses que les gestes demandent au système, et pas une de plus.
public protocol SurfaceDeGestes: AnyObject {
    /// La taille de la zone dessinée, en points.
    var taillePoints: (largeur: Double, hauteur: Double) { get }

    /// Majuscule et Contrôle, maintenant — et non au moment où l'évènement a été
    /// posté. C'est ce qui fait que relâcher Ctrl au milieu d'un glisser réaimante
    /// tout de suite.
    var majuscule: Bool { get }
    var controle: Bool { get }

    /// Le délai en secondes en deçà duquel deux clics n'en font qu'un.
    var delaiDuDoubleClic: Double { get }

    /// Combien de lignes vaut un cran de molette, d'après les réglages du système.
    /// Une valeur en dur ferait défiler trop vite chez qui a réglé finement, et
    /// c'est le genre de détail qui distingue une application native.
    var lignesParCranDeMolette: Double { get }

    func poserLeCurseur(_ forme: FormeDuCurseur)

    /// Garder la souris pendant un glisser. Sans capture, tirer une boucle jusqu'au
    /// bord de la fenêtre — ce qu'on fait à chaque fois — lâche le geste dès qu'on
    /// sort.
    func capturerLaSouris(_ capturer: Bool)

    /// Le clic droit. La suite ne regarde pas les gestes : Windows ouvre un menu du
    /// système, et une autre plateforme fera autrement — ou rien.
    func menuContextuelDemande(a: CGPoint)

    /// Ouvrir un fichier ; le seul appel du clavier qui passe par le système.
    func ouvrirUnFichier()
}

/// Traduit les gestes en appels au modèle.
///
/// Un objet plutôt que des fonctions libres : un glisser a un état, et cet état doit
/// vivre entre deux évènements.
public final class Gestes<Lecteur: LecteurAudio> {
    private let modele: AppModel<Lecteur>
    private unowned let surface: any SurfaceDeGestes
    private let panneau: Panneau
    private let flottant: Flottant
    private var glisser: GlisserDeBoucle?
    private var dernierClic = 0.0
    private var dernierClicX = 0.0

    /// Posé chaque fois qu'une entrée arrive, pour que la mesure de latence sache
    /// depuis quand on attend une image.
    public var mesures: Mesures?

    public init(modele: AppModel<Lecteur>, surface: any SurfaceDeGestes,
                panneau: Panneau, flottant: Flottant) {
        self.modele = modele
        self.surface = surface
        self.panneau = panneau
        self.flottant = flottant
    }

    /// Hauteur que le panneau peut occuper : la fenêtre moins la barre d'état, qu'il
    /// ne recouvre pas — c'est là que se lit ce que le modèle a à dire, y compris
    /// pendant qu'on tourne un réglage.
    private var hauteurUtile: Double {
        max(surface.taillePoints.hauteur - hauteurDeLaBarre, 80)
    }

    /// Vrai quand ce point tombe dans le panneau ouvert.
    private func dansLePanneau(_ p: CGPoint) -> Bool {
        panneau.contient(p, largeurFenetre: surface.taillePoints.largeur,
                         hauteurUtile: hauteurUtile)
    }

    /// Vrai quand ce point tombe sur la colonne flottante — le sélecteur de pistes et
    /// le bouton des réglages, qui sont là en permanence.
    private func surLaColonne(_ p: CGPoint) -> Bool {
        flottant.contient(p, largeurFenetre: surface.taillePoints.largeur)
    }

    private var majuscule: Bool { surface.majuscule }
    private var controle: Bool { surface.controle }

    // MARK: La molette

    /// Un cran de molette à ce point. `crans` vaut 1 par cran vers le haut ; les
    /// pavés tactiles en donnent des fractions, et c'est ce qui rend le défilement
    /// continu.
    public func molette(a p: CGPoint, crans: Double, horizontale: Bool) {
        mesures?.uneEntree()

        // Le panneau défile pour lui-même quand la molette le survole. Sans cela, la
        // liste des réglages serait la seule chose de la fenêtre qu'on ne pourrait
        // pas faire défiler — et l'image, elle, zoomerait sous un panneau immobile.
        if !horizontale, dansLePanneau(p) {
            panneau.defiler(crans * 48)
            return
        }
        // Rien sous la colonne : elle ne défile pas, et zoomer l'image par-dessous
        // ferait bouger ce qu'elle cache sans qu'on l'ait visé.
        if surLaColonne(p) { return }

        // Seize points par ligne : la hauteur d'une ligne de texte, qui est l'unité
        // dans laquelle ce réglage s'exprime.
        let deplacement = crans * max(surface.lignesParCranDeMolette, 1) * 16

        let hauteur = max(Double(modele.viewSize.height), 1)
        if majuscule {
            modele.viewport.zoomFrequency(factor: exp(deplacement * 0.006),
                                          anchorY: p.y, height: hauteur)
        } else if controle {
            // Le pincement d'un pavé tactile de précision arrive ici : Windows le
            // traduit lui-même en Ctrl + molette, si bien qu'il n'y a rien de plus à
            // écrire pour l'obtenir.
            modele.viewport.zoomTime(factor: exp(deplacement * 0.006), anchorX: p.x)
        } else if horizontale {
            modele.viewport.startColumn += deplacement * modele.viewport.columnsPerPoint
        } else {
            modele.viewport.bottomBin += deplacement * modele.viewport.binsPerPoint
        }
        modele.cancelTurn()
        modele.clampViewport()
    }

    // MARK: La souris

    /// Un glisser dans la réglette du haut — ou avec ⇧ n'importe où — trace la
    /// boucle ; partout ailleurs, il déplace la tête de lecture et fait sonner la
    /// raie désignée.
    private func traceUneBoucle(_ p: CGPoint) -> Bool {
        p.y <= hauteurDeLaReglette || majuscule
    }

    /// Ce qu'un clic à cet endroit ferait à la boucle existante : rien, la déplacer,
    /// ou tirer l'une de ses bornes.
    private func prise(_ p: CGPoint) -> GlisserDeBoucle? {
        guard let boucle = modele.loop, p.y <= hauteurDeLaReglette else { return nil }
        let x0 = modele.point(ofTime: boucle.lowerBound)
        let x1 = modele.point(ofTime: boucle.upperBound)
        if abs(p.x - x0) <= priseDuBord { return .bord(.start) }
        if abs(p.x - x1) <= priseDuBord { return .bord(.end) }
        if p.x > x0, p.x < x1 {
            return .deplacement(prise: modele.time(atPoint: p.x) - boucle.lowerBound)
        }
        return nil
    }

    public func boutonEnfonce(a p: CGPoint) {
        mesures?.uneEntree()

        // Le panneau d'abord : un clic qui visait un curseur ne doit pas déplacer la
        // tête de lecture par-dessous. La souris est capturée comme pour un glisser
        // de boucle, faute de quoi tirer un curseur jusqu'au bord du panneau le
        // lâcherait en chemin.
        if dansLePanneau(p) {
            surface.capturerLaSouris(true)
            panneau.appuiA(p)
            return
        }

        // La colonne ensuite, et pour la même raison : cocher une piste ne doit pas
        // déplacer la tête de lecture par-dessous. Pas de capture ici — ses boutons
        // se pressent, ils ne se tirent pas.
        if surLaColonne(p) {
            flottant.appuiA(p)
            return
        }

        modele.cancelTurn()

        // Le double-clic dans la réglette efface la boucle. Windows sait le dire
        // lui-même, et SDL aussi, mais chacun à sa condition — un drapeau de classe
        // là, un champ d'évènement ici. On le compte donc soi-même, ce qui évite de
        // faire dépendre un geste d'un réglage posé ailleurs, et le fait tomber
        // pareil des deux côtés.
        let maintenant = Horloge.maintenant()
        let doubleClic = maintenant - dernierClic < surface.delaiDuDoubleClic
            && abs(p.x - dernierClicX) < 4
        dernierClic = maintenant
        dernierClicX = p.x

        if doubleClic, p.y <= hauteurDeLaReglette {
            modele.loop = nil
            glisser = nil
            return
        }

        surface.capturerLaSouris(true)

        if traceUneBoucle(p) {
            // Une boucle déjà posée s'attrape : par le corps pour la déplacer, par un
            // bord pour l'étendre. Ailleurs, le glisser en trace une nouvelle.
            glisser = prise(p) ?? .creation(ancre: modele.time(atPoint: p.x))
        } else {
            modele.seek(to: modele.time(atPoint: p.x))
            modele.beginProbe(at: p)
        }
    }

    public func sourisDeplacee(a p: CGPoint, boutonEnfonce presse: Bool) {
        mesures?.uneEntree()
        panneau.sourisA(p)
        flottant.sourisA(p)

        // Le panneau est posé **sur** l'image : sans ce garde-fou, viser un curseur
        // ferait afficher par-dessous la note et la fréquence du point qu'il cache.
        // C'est le même `pointerOverControls` que la vue macOS pose au survol de ses
        // commandes flottantes.
        let survole = dansLePanneau(p) || panneau.glisseEnCours || surLaColonne(p)
        if modele.pointerOverControls != survole { modele.pointerOverControls = survole }
        if survole {
            surface.poserLeCurseur(.fleche)
            return
        }

        if presse {
            modele.hover = p
            // Ctrl enfoncé pendant le geste libère les bornes de la grille — le
            // pendant de ⌘ sur le Mac.
            let aimante = !controle
            let instant = modele.time(atPoint: p.x)
            switch glisser {
            case .creation(let ancre):
                modele.setLoop(from: ancre, to: instant, snapping: aimante)
            case .deplacement(let prise):
                modele.moveLoop(startingAt: instant - prise, snapping: aimante)
            case .bord(let bord):
                modele.dragLoop(edge: bord, to: instant, snapping: aimante)
            case nil:
                modele.seek(to: instant)
            }
            return
        }

        guard !modele.pointerOverControls else { return }
        modele.hover = p
        curseur(p)
    }

    public func boutonRelache(a p: CGPoint) {
        mesures?.uneEntree()
        surface.capturerLaSouris(false)
        let tenaitUnReglage = panneau.glisseEnCours
        panneau.relache()
        glisser = nil
        modele.endProbe()
        guard !tenaitUnReglage else { return }
        curseur(p)
    }

    /// La souris a quitté la fenêtre. Sans cela, la note survolée reste affichée
    /// après le départ du curseur, ce qui se lit comme une image figée.
    public func sourisSortie() {
        modele.hover = nil
        panneau.sourisPartie()
        flottant.sourisPartie()
        surface.poserLeCurseur(.fleche)
    }

    public func clicDroit(a p: CGPoint) {
        mesures?.uneEntree()
        surface.menuContextuelDemande(a: p)
    }

    /// Le curseur annonce ce qui va se passer : sans cela, rien ne laisse deviner
    /// qu'une boucle posée se rattrape.
    private func curseur(_ p: CGPoint) {
        switch prise(p) {
        case .bord:        surface.poserLeCurseur(.largeur)
        case .deplacement: surface.poserLeCurseur(.main)
        default:           surface.poserLeCurseur(.fleche)
        }
    }

    // MARK: Le clavier

    /// Rend `true` quand la touche a été traitée.
    public func touche(_ touche: ToucheDeSpectre) -> Bool {
        mesures?.uneEntree()
        let majuscule = self.majuscule
        // Ctrl+O est le raccourci d'ouverture partout ; il passe donc avant tout le
        // reste, y compris le « O » nu qui n'est lié à rien.
        if controle, touche == .o {
            surface.ouvrirUnFichier()
            return true
        }
        switch touche {
        case .espace:         modele.togglePlayback()
        case .gauche:         modele.seek(to: modele.playhead - (majuscule ? 5 : 1))
        case .droite:         modele.seek(to: modele.playhead + (majuscule ? 5 : 1))
        case .echappement:    modele.loop = nil
        case .crochetOuvrant: modele.setLoopStart(at: modele.playhead)
        case .crochetFermant: modele.setLoopEnd(at: modele.playhead)
        case .l:              modele.loopEnabled.toggle()
        case .b:              modele.snapLoopToBars()
        case .un:             modele.setDownbeatAtPlayhead()
        case .r:              basculerLePanneau()
        case .o:              return false
        }
        return true
    }

    /// Ouvre ou referme le panneau des réglages.
    ///
    /// `pointerOverControls` est remis d'aplomb ici et pas seulement au mouvement
    /// suivant : refermer le panneau au clavier, curseur immobile là où il était,
    /// laisserait sinon l'image muette — plus de note survolée, plus de raie
    /// désignée — jusqu'à ce qu'on bouge la souris, ce qui se lit comme une panne.
    public func basculerLePanneau() {
        panneau.ouvert.toggle()
        if !panneau.ouvert { modele.pointerOverControls = false }
    }
}
