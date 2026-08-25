import Foundation
import SpectreCore
import SpectreDessin
import SpectreModele
import SpectreSon
import SpectreToile
import SpectreWin
import WinSDK

// Les messages de Windows, traduits en gestes.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUI RESTE ICI, ET POURQUOI SI PEU
//
// Les gestes eux-mêmes — l'aimantation, la boucle, le zoom, la table du clavier —
// sont dans `SpectreDessin/Gestes.swift`, partagés avec Linux. Ce fichier ne fait
// plus que deux choses : traduire `WM_MOUSEWHEEL` et ses semblables en appels
// nommés, et remplir les huit fonctions de `SurfaceDeGestes` avec du Win32.
//
// Le menu du clic droit reste ici en entier, et c'est délibéré : c'est un menu du
// **système**, avec ses items dessinés par lui et sa boucle modale à lui. Rien de
// portable là-dedans.
// ─────────────────────────────────────────────────────────────────────────────

/// La surface Win32, et la traduction des messages.
final class GestesWindows: SurfaceDeGestes {
    private let modele: AppModel
    private let fenetre: Fenetre
    private let panneau: Panneau
    /// Créée après les autres, parce qu'elle prend `self` pour surface. C'est le
    /// seul point d'exclamation du fichier, et il ne survit pas à l'initialisation.
    private(set) var gestes: Gestes<LecteurSurLePont>!
    private var suitLaSouris = false

    init(modele: AppModel, fenetre: Fenetre, panneau: Panneau, flottant: Flottant) {
        self.modele = modele
        self.fenetre = fenetre
        self.panneau = panneau
        self.gestes = Gestes(modele: modele, surface: self,
                             panneau: panneau, flottant: flottant)
    }

    var mesures: Mesures? {
        get { gestes.mesures }
        set { gestes.mesures = newValue }
    }

    func basculerLePanneau() { gestes.basculerLePanneau() }

    // MARK: - Ce que la surface doit savoir faire

    var taillePoints: (largeur: Double, hauteur: Double) { fenetre.taillePoints }

    var majuscule: Bool { GetKeyState(VK_SHIFT) < 0 }
    var controle: Bool { GetKeyState(VK_CONTROL) < 0 }

    var delaiDuDoubleClic: Double { Double(GetDoubleClickTime()) / 1000 }

    var lignesParCranDeMolette: Double {
        var lignes: UINT = 3
        SystemParametersInfoW(UINT(SPI_GETWHEELSCROLLLINES), 0, &lignes, 0)
        return Double(lignes)
    }

    func poserLeCurseur(_ forme: FormeDuCurseur) {
        switch forme {
        case .fleche:  SetCursor(LoadCursorW(nil, curseurFleche))
        case .largeur: SetCursor(LoadCursorW(nil, ressource(32644)))   // IDC_SIZEWE
        case .main:    SetCursor(LoadCursorW(nil, ressource(32649)))   // IDC_HAND
        }
    }

    func capturerLaSouris(_ capturer: Bool) {
        if capturer {
            if let poignee = fenetre.poignee { SetCapture(poignee) }
        } else {
            ReleaseCapture()
        }
    }

    func ouvrirUnFichier() { modele.openPanel() }

    // MARK: - La traduction des messages

    /// Le point sous le curseur, **en points depuis le coin haut-gauche** — comme
    /// dans `Viewport`, et comme dans la vue macOS après conversion.
    private func point(_ l: LPARAM) -> CGPoint {
        CGPoint(x: Double(positionX(l)) / fenetre.echelle,
                y: Double(positionY(l)) / fenetre.echelle)
    }

    /// La position d'un message de molette est en coordonnées **de l'écran**, et non
    /// de la fenêtre. L'oublier ancre le zoom à côté, d'autant plus loin que la
    /// fenêtre est basse sur l'écran.
    private func pointDeLEcran(_ l: LPARAM) -> CGPoint {
        var p = POINT(x: LONG(positionX(l)), y: LONG(positionY(l)))
        if let poignee = fenetre.poignee { ScreenToClient(poignee, &p) }
        return CGPoint(x: Double(p.x) / fenetre.echelle,
                       y: Double(p.y) / fenetre.echelle)
    }

    /// Rend `true` quand le message a été traité.
    func repondre(_ message: UINT, _ w: WPARAM, _ l: LPARAM) -> Bool {
        switch Int32(message) {
        case WM_MOUSEWHEEL:
            gestes.molette(a: pointDeLEcran(l), crans: crans(w), horizontale: false)
        case WM_MOUSEHWHEEL:
            gestes.molette(a: pointDeLEcran(l), crans: crans(w), horizontale: true)
        case WM_LBUTTONDOWN:
            gestes.boutonEnfonce(a: point(l))
        case WM_MOUSEMOVE:
            demanderLeMessageDeSortie()
            gestes.sourisDeplacee(a: point(l), boutonEnfonce: w & WPARAM(MK_LBUTTON) != 0)
        case WM_LBUTTONUP:
            gestes.boutonRelache(a: point(l))
        case WM_MOUSELEAVE:
            suitLaSouris = false
            gestes.sourisSortie()
        case WM_RBUTTONUP:
            gestes.clicDroit(a: point(l))
        case WM_COMMAND:
            commandeDuMenu = motBas(UInt64(w))
        case WM_KEYDOWN:
            guard let touche = traduire(w) else { return false }
            return gestes.touche(touche)
        default:
            return false
        }
        return true
    }

    private func crans(_ w: WPARAM) -> Double {
        Double(Int16(truncatingIfNeeded: motHaut(UInt64(w)))) / 120
    }

    /// Les codes de touche virtuelle sont ceux d'un clavier américain ; sur un
    /// clavier français, `[` et `]` ne sont pas là. `WM_CHAR` les donnerait par leur
    /// caractère, mais il ne donne pas les flèches — d'où les deux chemins, et non
    /// un seul.
    private func traduire(_ w: WPARAM) -> ToucheDeSpectre? {
        switch Int32(w) {
        case VK_SPACE:  return .espace
        case VK_LEFT:   return .gauche
        case VK_RIGHT:  return .droite
        case VK_ESCAPE: return .echappement
        case 0xDB:      return .crochetOuvrant   // VK_OEM_4, « [ »
        case 0xDD:      return .crochetFermant   // VK_OEM_6, « ] »
        case 0x4C:      return .l
        case 0x42:      return .b
        case 0x31:      return .un
        case 0x52:      return .r
        case 0x4F:      return .o
        // Le zoom au clavier. `VK_OEM_PLUS` est la touche « = » — celle qui porte
        // « + » avec ⇧ — et les deux suivantes sont celles du pavé numérique.
        case 0xBB, 0x6B: return .plus            // VK_OEM_PLUS, VK_ADD
        case 0xBD, 0x6D: return .moins           // VK_OEM_MINUS, VK_SUBTRACT
        default:        return nil
        }
    }

    /// Windows n'annonce pas la sortie du curseur si on ne la lui a pas demandée, et
    /// la demande vaut pour une seule sortie : il faut la reposer à chaque mouvement.
    /// Sans elle, la note survolée reste affichée après que la souris a quitté la
    /// fenêtre.
    private func demanderLeMessageDeSortie() {
        guard !suitLaSouris, let poignee = fenetre.poignee else { return }
        var suivi = TRACKMOUSEEVENT()
        suivi.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
        suivi.dwFlags = DWORD(TME_LEAVE)
        suivi.hwndTrack = poignee
        if TrackMouseEvent(&suivi) { suitLaSouris = true }
    }

    // MARK: - Le menu du clic droit

    /// Ce que le menu vient de faire choisir. Retenu plutôt qu'exécuté sur-le-champ :
    /// `WM_COMMAND` arrive **pendant** la boucle modale du menu, et ouvrir un
    /// dialogue de fichiers là-dedans emboîterait deux boucles modales.
    private var commandeDuMenu: Int?

    func menuContextuelDemande(a point: CGPoint) {
        guard let poignee = fenetre.poignee else { return }
        var p = POINT(x: LONG(point.x * fenetre.echelle),
                      y: LONG(point.y * fenetre.echelle))
        _ = ClientToScreen(poignee, &p)

        commandeDuMenu = nil
        MenuContextuel(recents: modele.recentFiles, panneauOuvert: panneau.ouvert)
            .montrer(dans: poignee, a: p)
        guard let choix = commandeDuMenu else { return }
        commandeDuMenu = nil

        switch choix {
        case CommandeDuMenu.ouvrir:          modele.openPanel()
        case CommandeDuMenu.reglages:        gestes.basculerLePanneau()
        case CommandeDuMenu.viderLesRecents: modele.clearRecentFiles()
        case CommandeDuMenu.quitter:
            // Par `WM_CLOSE` et non `PostQuitMessage` : c'est le chemin qui passe par
            // `fenetrePeutSeFermer`, donc par l'écriture de la session. Quitter par le
            // menu ne doit pas coûter plus que quitter par la croix.
            _ = PostMessageW(poignee, UINT(WM_CLOSE), 0, 0)
        case CommandeDuMenu.premierRecent...:
            let rang = choix - CommandeDuMenu.premierRecent
            let recents = modele.recentFiles
            guard rang < recents.count else { return }
            modele.open(recents[rang])
        default:
            break
        }
    }
}
