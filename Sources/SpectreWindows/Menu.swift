import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele
import SpectreWin
import WinSDK

// Le menu du clic droit — et pourquoi il n'y a pas de barre de menus.
//
// ─────────────────────────────────────────────────────────────────────────────
// Une application Windows ordinaire porte « Fichier ▸ Ouvrir » en haut de sa
// fenêtre. Ici, cette barre prendrait une bande permanente à ce qui est justement
// l'objet du travail — un spectrogramme se lit d'autant mieux qu'il est grand —
// pour trois commandes qu'on emploie une fois par morceau.
//
// Windows 11 admet cela : ses propres applications récentes n'ont plus de barre de
// menus, et rangent leurs commandes derrière un bouton ou un clic droit. Le clic
// droit a l'avantage d'être là où le regard est déjà, et de ne rien coûter à
// l'image. Le clavier reste le chemin rapide, et la barre du bas le rappelle.
//
// **Sans `TPM_RETURNCMD`.** Il rendrait le numéro choisi directement, mais Swift
// importe `TrackPopupMenu` comme rendant un booléen : le numéro se perd. Le menu
// envoie donc son `WM_COMMAND` comme n'importe quel menu, et `Gestes` le retient
// pour l'exécuter **après** la fermeture — ouvrir un dialogue de fichiers depuis
// l'intérieur de la boucle modale du menu emboîterait deux boucles modales, ce qui
// marche jusqu'au jour où cela ne marche plus.
// ─────────────────────────────────────────────────────────────────────────────

/// Les numéros de commande du menu. Les récents occupent la plage qui suit.
enum CommandeDuMenu {
    static let ouvrir: Int = 1
    static let reglages: Int = 2
    static let viderLesRecents: Int = 3
    static let quitter: Int = 4
    /// Le premier morceau récent. `premierRecent + n` désigne le n-ième.
    static let premierRecent: Int = 100
}

/// Construit le menu contextuel et le montre. Ce qu'on y choisit revient par
/// `WM_COMMAND`.
struct MenuContextuel {
    let recents: [URL]
    let panneauOuvert: Bool

    func montrer(dans fenetre: HWND, a point: POINT) {
        guard let menu = CreatePopupMenu() else { return }
        defer { _ = DestroyMenu(menu) }

        ajouter(menu, CommandeDuMenu.ouvrir, T(.winMenuOuvrir))

        if !recents.isEmpty, let sousMenu = CreatePopupMenu() {
            for (i, url) in recents.enumerated() {
                // Le nom seul, pas le chemin : une liste de récents où chaque ligne
                // fait deux cents caractères n'est plus une liste, c'est un mur.
                ajouter(sousMenu, CommandeDuMenu.premierRecent + i,
                        url.lastPathComponent)
            }
            separateur(sousMenu)
            ajouter(sousMenu, CommandeDuMenu.viderLesRecents, T(.winMenuViderLaListe))
            // Détruire le menu parent détruit ses sous-menus : le `defer` ci-dessus
            // suffit, et libérer celui-ci à part le libérerait deux fois.
            T(.winMenuOuvrirRecemment).withUTF16Pointer { texte in
                _ = AppendMenuW(menu, UINT(MF_POPUP),
                                UINT_PTR(UInt(bitPattern: UnsafeRawPointer(sousMenu))),
                                texte)
            }
        }

        separateur(menu)
        ajouter(menu, CommandeDuMenu.reglages,
                panneauOuvert ? T(.winMenuMasquerReglages) : T(.winMenuReglages))
        separateur(menu)
        ajouter(menu, CommandeDuMenu.quitter, T(.winMenuQuitter))

        // Sans cela, le menu ne se referme pas quand on clique ailleurs : Windows
        // l'exige depuis toujours, et l'oubli laisse un menu fantôme à l'écran.
        _ = SetForegroundWindow(fenetre)
        _ = TrackPopupMenu(menu, UINT(TPM_LEFTALIGN | TPM_RIGHTBUTTON),
                           point.x, point.y, 0, fenetre, nil)
    }

    private func ajouter(_ menu: HMENU, _ numero: Int, _ texte: String) {
        texte.withUTF16Pointer { pointeur in
            _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(numero), pointeur)
        }
    }

    private func separateur(_ menu: HMENU) {
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }
}
