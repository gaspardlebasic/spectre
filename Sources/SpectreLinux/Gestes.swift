import CSDL
import Foundation
import SpectreCore
import SpectreDessin
import SpectreModele
import SpectreSon

// Les évènements de SDL, traduits en gestes.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUI EST ICI, ET CE QUI N'Y EST PAS
//
// Les gestes eux-mêmes sont dans `SpectreDessin/Gestes.swift`, partagés avec
// Windows : l'aimantation, la boucle, le zoom, la table du clavier. Ce fichier
// remplit les huit fonctions de `SurfaceDeGestes` avec du SDL, et traduit les
// évènements. Il fait cent lignes contre quatre cents à Windows avant le partage,
// et c'est tout ce que l'étape 6 aura coûté.
//
// **Le menu du clic droit n'existe pas encore sous Linux.** Sur Windows c'est un
// menu du système, avec ses items dessinés par lui ; SDL n'en a pas d'équivalent, et
// il n'existe pas de menu contextuel « du bureau » qu'on puisse demander. Tout ce
// qu'il offre s'atteint autrement — la porte des réglages est sur la colonne
// flottante, l'ouverture par Ctrl+O — si bien qu'un clic droit sans effet ne retire
// rien. Le jour où il en faudra un, il se dessinera au `Pinceau` comme le reste, et
// sera alors partagé plutôt que porté.
// ─────────────────────────────────────────────────────────────────────────────

/// La surface SDL : les huit choses que les gestes demandent au système.
final class SurfaceSDL: SurfaceDeGestes {
    private let fenetre: OpaquePointer
    private let modele: AppModel
    private let mesureDeLaFenetre: () -> (largeur: Double, hauteur: Double)
    /// Créés une fois : `SDL_CreateSystemCursor` alloue, et le faire à chaque
    /// mouvement de souris allouerait soixante fois par seconde sur le chemin le
    /// plus chaud de l'application.
    private let fleche: OpaquePointer?
    private let largeur: OpaquePointer?
    private let main: OpaquePointer?
    private var formePosee: FormeDuCurseur?

    private(set) var gestes: Gestes<LecteurSurLePont>!

    init(fenetre: OpaquePointer, modele: AppModel, panneau: Panneau, flottant: Flottant,
         taillePoints: @escaping () -> (largeur: Double, hauteur: Double)) {
        self.fenetre = fenetre
        self.modele = modele
        self.mesureDeLaFenetre = taillePoints
        self.fleche = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_DEFAULT)
        self.largeur = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_EW_RESIZE)
        self.main = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_POINTER)
        self.gestes = Gestes(modele: modele, surface: self,
                             panneau: panneau, flottant: flottant)
    }

    deinit {
        for curseur in [fleche, largeur, main] {
            if let curseur { SDL_DestroyCursor(curseur) }
        }
    }

    var taillePoints: (largeur: Double, hauteur: Double) { mesureDeLaFenetre() }

    private var modificateurs: SDL_Keymod { SDL_GetModState() }
    var majuscule: Bool { modificateurs & SpectreMajuscule != 0 }
    var controle: Bool { modificateurs & SpectreControle != 0 }

    /// Une demi-seconde, en dur.
    ///
    /// C'est le réglage de Windows par défaut, et celui de GNOME. Ni X11 ni Wayland
    /// ne le publient à qui n'est pas une bibliothèque de widgets : le lire
    /// vraiment demanderait de parler à GSettings, donc de dépendre de GTK pour un
    /// nombre. Le jour où quelqu'un se plaindra, ce sera un réglage de Spectre.
    var delaiDuDoubleClic: Double { 0.5 }

    /// SDL rend déjà la molette en crans, et Wayland comme X11 laissent le
    /// compositeur appliquer le réglage de l'utilisateur avant nous. Trois lignes
    /// par cran est alors la valeur qu'attend tout le monde.
    var lignesParCranDeMolette: Double { 3 }

    func poserLeCurseur(_ forme: FormeDuCurseur) {
        // Reposer le même curseur soixante fois par seconde fait un aller-retour au
        // serveur d'affichage pour rien, et sous X11 cela se voit au scintillement.
        guard formePosee != forme else { return }
        formePosee = forme
        switch forme {
        case .fleche:  if let fleche { SDL_SetCursor(fleche) }
        case .largeur: if let largeur { SDL_SetCursor(largeur) }
        case .main:    if let main { SDL_SetCursor(main) }
        }
    }

    func capturerLaSouris(_ capturer: Bool) { SDL_CaptureMouse(capturer) }

    func menuContextuelDemande(a point: CGPoint) {
        // Voir l'en-tête : il n'y a pas de menu sous Linux, et rien de ce qu'il
        // offrirait n'est hors d'atteinte autrement.
    }

    func ouvrirUnFichier() { modele.openPanel() }

    // MARK: - La traduction des évènements

    /// Rend `false` quand l'évènement demande la fermeture.
    func repondre(_ e: SDL_Event) -> Bool {
        switch SDL_EventType(rawValue: e.type) {
        case SDL_EVENT_QUIT:
            return false
        case SDL_EVENT_MOUSE_WHEEL:
            let p = CGPoint(x: Double(e.wheel.mouse_x), y: Double(e.wheel.mouse_y))
            // Les deux axes plutôt qu'un : un pavé tactile en donne les deux à la
            // fois, et n'en lire qu'un fait un défilement qui accroche en diagonale.
            if e.wheel.y != 0 {
                gestes.molette(a: p, crans: Double(e.wheel.y), horizontale: false)
            }
            if e.wheel.x != 0 {
                gestes.molette(a: p, crans: Double(e.wheel.x), horizontale: true)
            }
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            let p = CGPoint(x: Double(e.button.x), y: Double(e.button.y))
            if e.button.button == UInt8(SDL_BUTTON_RIGHT) {
                gestes.clicDroit(a: p)
            } else if e.button.button == UInt8(SDL_BUTTON_LEFT) {
                gestes.boutonEnfonce(a: p)
            }
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if e.button.button == UInt8(SDL_BUTTON_LEFT) {
                gestes.boutonRelache(a: CGPoint(x: Double(e.button.x),
                                                y: Double(e.button.y)))
            }
        case SDL_EVENT_MOUSE_MOTION:
            let presse = e.motion.state & SpectreBoutonGauche != 0
            gestes.sourisDeplacee(a: CGPoint(x: Double(e.motion.x),
                                             y: Double(e.motion.y)),
                                  boutonEnfonce: presse)
        case SDL_EVENT_WINDOW_MOUSE_LEAVE:
            gestes.sourisSortie()
        case SDL_EVENT_KEY_DOWN:
            // Échap ferme la boucle avant d'être une touche de geste **seulement**
            // quand il n'y a pas de boucle à effacer : sinon Échap effacerait la
            // boucle et quitterait du même coup, ce qui est le contraire de ce qu'on
            // attend d'une touche d'annulation.
            if e.key.key == SDLK_ESCAPE, modele.loop == nil { return false }
            if e.key.key == SDLK_Q, controle { return false }
            if let touche = traduire(e.key.key) { _ = gestes.touche(touche) }
        default:
            break
        }
        return true
    }

    /// SDL donne la touche par son **symbole**, c'est-à-dire par le caractère que la
    /// disposition du clavier y a posé. C'est ce qui rend `[` et `]` justes sur un
    /// clavier français, là où Windows oblige à passer par les codes d'un clavier
    /// américain — voir la note du côté Windows.
    private func traduire(_ touche: SDL_Keycode) -> ToucheDeSpectre? {
        switch touche {
        case SDLK_SPACE:        return .espace
        case SDLK_LEFT:         return .gauche
        case SDLK_RIGHT:        return .droite
        case SDLK_ESCAPE:       return .echappement
        case SDLK_LEFTBRACKET:  return .crochetOuvrant
        case SDLK_RIGHTBRACKET: return .crochetFermant
        case SDLK_L:            return .l
        case SDLK_B:            return .b
        case SDLK_1:            return .un
        case SDLK_R:            return .r
        case SDLK_O:            return .o
        default:                return nil
        }
    }
}

/// La cadence de l'écran, en hertz, telle que le compositeur la déclare.
///
/// Zéro quand il ne la déclare pas — ce qui arrive sous Wayland dans une machine
/// virtuelle — et `Mesures` prend alors 60. Le relevé le dit, plutôt que de faire
/// comme s'il savait.
func cadenceDeLEcran(_ fenetre: OpaquePointer) -> Double {
    let ecran = SDL_GetDisplayForWindow(fenetre)
    guard let mode = SDL_GetCurrentDisplayMode(ecran) else { return 0 }
    return Double(mode.pointee.refresh_rate)
}
