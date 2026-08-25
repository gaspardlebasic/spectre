import CPont
import Foundation
import SpectreToile
import SpectreSocle
import SpectreCore

// Ce qui attache le pinceau à Direct2D. Le pinceau lui-même est dans
// `SpectreToile`, où Linux le partage — voir l'en-tête qui y est écrit.

extension RenduD3D11 {
    /// Prépare Direct2D. À appeler une fois, après la création du rendu.
    public func preparerLaSurimpression() -> Bool {
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        let ok = erreur.withUnsafeMutableBufferPointer {
            spectre_surimpression_preparer(pontBrut, $0.baseAddress)
        }
        if ok == 0 { Journal.erreur(String(cString: erreur)) }
        return ok != 0
    }

    /// Restreint le spectrogramme à une zone, en points. Le reste de la fenêtre
    /// revient à la surimpression — c'est là que va la ligne de batterie.
    ///
    /// La zone est retenue, et pas seulement transmise : le nuanceur en a besoin lui
    /// aussi. Il retourne l'axe vertical par `tailleVue.y`, et lui donner la hauteur
    /// de la *fenêtre* alors qu'il ne dessine que dans la zone décale toute l'image
    /// vers le bas — d'exactement ce que la ligne de batterie occupe.
    public func zone(largeur: Double, hauteur: Double, echelle: Double) {
        zoneEnPoints = (largeur, hauteur)
        spectre_rendu_zone(pontBrut, Int32(largeur * echelle), Int32(hauteur * echelle))
    }

    /// Dessine par-dessus. Le bloc reçoit un pinceau qui compte en points.
    public func surimprimer(echelle: Double, _ corps: (Pinceau) -> Void) {
        spectre_surimpression_echelle(pontBrut, Float(echelle))
        spectre_surimpression_debuter(pontBrut)
        corps(Pinceau(pont: pontBrut))
        spectre_surimpression_finir(pontBrut)
    }
}
