import Foundation
import SpectreCore
import SpectreModele
import SpectreWin
import WinSDK

// Ce que la souris et le clavier font au modèle.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE MÊME GESTE, PAS UN GESTE QUI LUI RESSEMBLE
//
// Chaque ligne de ce fichier a son pendant exact dans
// `Sources/Spectre/TimelineView.swift`, et appelle **la même méthode du modèle**.
// C'est la seule discipline qui empêche les deux applications de diverger : dès
// qu'un geste est réimplémenté au lieu d'être rebranché, il perd une subtilité par
// mois — l'aimantation qu'on relâche, la boucle qu'on rattrape par un bord, le
// tourne-page qu'un défilement annule.
//
// Ce qui change d'une plateforme à l'autre, ce sont les **touches**, et rien
// d'autre :
//
// | geste                        | macOS        | Windows |
// |------------------------------|--------------|---------|
// | zoom sur le temps            | ⌥ ou ⌘ + molette | Ctrl + molette |
// | zoom sur les fréquences      | ⇧ + molette  | ⇧ + molette |
// | tracer une boucle n'importe où | ⇧ + glisser | ⇧ + glisser |
// | libérer de la grille         | ⌘ pendant le glisser | Ctrl pendant le glisser |
//
// Ctrl remplace ⌘, ce qui est la correspondance habituelle, et il n'entre en
// conflit avec rien : la molette et le glisser sont deux gestes différents.
// ─────────────────────────────────────────────────────────────────────────────

/// Hauteur de la réglette du haut, en points. La même valeur que dans la vue
/// macOS : c'est elle qui décide où un glisser trace une boucle plutôt que de
/// déplacer la tête.
let hauteurDeLaReglette = 20.0
/// À quelle distance d'un bord de boucle on l'attrape.
let priseDuBord = 7.0

/// Ce qu'un glisser en cours est en train de faire à la boucle.
enum GlisserDeBoucle {
    case creation(ancre: Double)
    case deplacement(prise: Double)
    case bord(LoopEdge)
}

/// Traduit les messages de Windows en appels au modèle.
///
/// Un objet plutôt que des fonctions libres : un glisser a un état, et cet état
/// doit vivre entre deux messages.
final class Gestes {
    private let modele: AppModel
    private let fenetre: Fenetre
    private var glisser: GlisserDeBoucle?
    private var suitLaSouris = false
    private var dernierClic = 0.0
    private var dernierClicX = 0.0

    /// Posé chaque fois qu'une entrée arrive, pour que la mesure de latence sache
    /// depuis quand on attend une image.
    var mesures: Mesures?

    init(modele: AppModel, fenetre: Fenetre) {
        self.modele = modele
        self.fenetre = fenetre
    }

    /// Le point sous le curseur, **en points depuis le coin haut-gauche** — comme
    /// dans `Viewport`, et comme dans la vue macOS après conversion.
    private func point(_ l: LPARAM) -> CGPoint {
        CGPoint(x: Double(positionX(l)) / fenetre.echelle,
                y: Double(positionY(l)) / fenetre.echelle)
    }

    private var majuscule: Bool { GetKeyState(VK_SHIFT) < 0 }
    private var controle: Bool { GetKeyState(VK_CONTROL) < 0 }

    /// Rend `true` quand le message a été traité.
    func repondre(_ message: UINT, _ w: WPARAM, _ l: LPARAM) -> Bool {
        mesures?.uneEntree()
        switch Int32(message) {
        case WM_MOUSEWHEEL:      molette(w, l, horizontale: false); return true
        case WM_MOUSEHWHEEL:     molette(w, l, horizontale: true); return true
        case WM_LBUTTONDOWN:     boutonEnfonce(l); return true
        case WM_MOUSEMOVE:       sourisDeplacee(w, l); return true
        case WM_LBUTTONUP:       boutonRelache(l); return true
        case WM_MOUSELEAVE:      sourisSortie(); return true
        case WM_KEYDOWN:         return touche(w)
        default:                 return false
        }
    }

    // MARK: La molette

    private func molette(_ w: WPARAM, _ l: LPARAM, horizontale: Bool) {
        // La position d'un message de molette est en coordonnées **de l'écran**, et
        // non de la fenêtre. L'oublier ancre le zoom à côté, d'autant plus loin que
        // la fenêtre est basse sur l'écran.
        var p = POINT(x: LONG(positionX(l)), y: LONG(positionY(l)))
        if let poignee = fenetre.poignee { ScreenToClient(poignee, &p) }
        let x = Double(p.x) / fenetre.echelle
        let y = Double(p.y) / fenetre.echelle

        let crans = Double(Int16(truncatingIfNeeded: motHaut(UInt64(w)))) / 120

        // Combien de lignes vaut un cran, d'après les réglages de l'utilisateur.
        // Une valeur en dur ferait défiler trop vite chez qui a réglé finement, et
        // c'est le genre de détail qui distingue une application native.
        var lignes: UINT = 3
        SystemParametersInfoW(UINT(SPI_GETWHEELSCROLLLINES), 0, &lignes, 0)
        // Seize points par ligne : la hauteur d'une ligne de texte, qui est l'unité
        // dans laquelle Windows exprime ce réglage.
        let deplacement = crans * Double(max(lignes, 1)) * 16

        let hauteur = max(Double(modele.viewSize.height), 1)
        if majuscule {
            modele.viewport.zoomFrequency(factor: exp(deplacement * 0.006),
                                          anchorY: y, height: hauteur)
        } else if controle {
            // Le pincement d'un pavé tactile de précision arrive ici : Windows le
            // traduit lui-même en Ctrl + molette, si bien qu'il n'y a rien de plus à
            // écrire pour l'obtenir.
            modele.viewport.zoomTime(factor: exp(deplacement * 0.006), anchorX: x)
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

    private func boutonEnfonce(_ l: LPARAM) {
        let p = point(l)
        modele.cancelTurn()

        // Le double-clic dans la réglette efface la boucle. Windows sait le dire
        // lui-même par `WM_LBUTTONDBLCLK`, mais seulement si la classe de fenêtre
        // porte `CS_DBLCLKS` ; on le compte ici, ce qui évite de faire dépendre un
        // geste d'un drapeau posé ailleurs.
        let maintenant = Horloge.maintenant()
        let doubleClic = maintenant - dernierClic < Double(GetDoubleClickTime()) / 1000
            && abs(p.x - dernierClicX) < 4
        dernierClic = maintenant
        dernierClicX = p.x

        if doubleClic, p.y <= hauteurDeLaReglette {
            modele.loop = nil
            glisser = nil
            return
        }

        // La souris est capturée : sans cela, tirer une boucle jusqu'au bord de la
        // fenêtre — ce qu'on fait à chaque fois — lâche le geste dès qu'on sort.
        if let poignee = fenetre.poignee { SetCapture(poignee) }

        if traceUneBoucle(p) {
            // Une boucle déjà posée s'attrape : par le corps pour la déplacer, par un
            // bord pour l'étendre. Ailleurs, le glisser en trace une nouvelle.
            glisser = prise(p) ?? .creation(ancre: modele.time(atPoint: p.x))
        } else {
            modele.seek(to: modele.time(atPoint: p.x))
            modele.beginProbe(at: p)
        }
    }

    private func sourisDeplacee(_ w: WPARAM, _ l: LPARAM) {
        let p = point(l)
        demanderLeMessageDeSortie()

        if w & WPARAM(MK_LBUTTON) != 0 {
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

        // Les commandes flottantes sont posées sur l'image et reçoivent les
        // mouvements qui les survolent. Sans ce garde-fou, viser un bouton ferait
        // afficher par-dessous la note et la fréquence du point qu'il cache.
        guard !modele.pointerOverControls else { return }
        modele.hover = p
        curseur(p)
    }

    private func boutonRelache(_ l: LPARAM) {
        ReleaseCapture()
        glisser = nil
        modele.endProbe()
        curseur(point(l))
    }

    private func sourisSortie() {
        suitLaSouris = false
        modele.hover = nil
        SetCursor(LoadCursorW(nil, curseurFleche))
    }

    /// Windows n'annonce pas la sortie du curseur si on ne la lui a pas demandée, et
    /// la demande vaut pour une seule sortie : il faut la reposer à chaque
    /// mouvement. Sans elle, la note survolée reste affichée après que la souris a
    /// quitté la fenêtre.
    private func demanderLeMessageDeSortie() {
        guard !suitLaSouris, let poignee = fenetre.poignee else { return }
        var suivi = TRACKMOUSEEVENT()
        suivi.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
        suivi.dwFlags = DWORD(TME_LEAVE)
        suivi.hwndTrack = poignee
        if TrackMouseEvent(&suivi) { suitLaSouris = true }
    }

    /// Le curseur annonce ce qui va se passer : sans cela, rien ne laisse deviner
    /// qu'une boucle posée se rattrape.
    private func curseur(_ p: CGPoint) {
        switch prise(p) {
        case .bord:         SetCursor(LoadCursorW(nil, ressource(32644)))   // IDC_SIZEWE
        case .deplacement:  SetCursor(LoadCursorW(nil, ressource(32649)))   // IDC_HAND
        default:            SetCursor(LoadCursorW(nil, curseurFleche))
        }
    }

    // MARK: Le clavier

    private func touche(_ w: WPARAM) -> Bool {
        let majuscule = self.majuscule
        switch Int32(w) {
        case VK_SPACE:  modele.togglePlayback()
        case VK_LEFT:   modele.seek(to: modele.playhead - (majuscule ? 5 : 1))
        case VK_RIGHT:  modele.seek(to: modele.playhead + (majuscule ? 5 : 1))
        case VK_ESCAPE: modele.loop = nil
        // Les codes de touche virtuelle sont ceux d'un clavier américain ; sur un
        // clavier français, `[` et `]` ne sont pas là. `WM_CHAR` les donnerait par
        // leur caractère, mais il ne donne pas les flèches — d'où les deux chemins,
        // et non un seul.
        case 0xDB:      modele.setLoopStart(at: modele.playhead)   // VK_OEM_4, « [ »
        case 0xDD:      modele.setLoopEnd(at: modele.playhead)     // VK_OEM_6, « ] »
        case 0x4C:      modele.loopEnabled.toggle()                // L
        case 0x42:      modele.snapLoopToBars()                    // B
        case 0x31:      modele.setDownbeatAtPlayhead()             // 1
        default:        return false
        }
        return true
    }
}
