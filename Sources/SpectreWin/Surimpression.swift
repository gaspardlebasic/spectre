import CPont
import Foundation
import SpectreCore

/// De quoi dessiner par-dessus le spectrogramme, en points.
///
/// Le vocabulaire est celui du `GraphicsContext` de SwiftUI — `remplir`, `tracer`,
/// `texte` — pour que `Surimpression.swift`, du côté de la fenêtre, se lise ligne
/// pour ligne contre `Sources/Spectre/TimelineView.swift`. C'est ce qui permet de
/// vérifier que les deux dessinent la même chose sans traduire mentalement à chaque
/// appel.
public struct Pinceau {
    let pont: OpaquePointer

    /// Une couleur, en `0xRRVVBBAA`. `blanc(0.3)` s'écrit comme `.white.opacity(0.3)`.
    public static func blanc(_ opacite: Double) -> UInt32 { gris(1, opacite) }
    public static func noir(_ opacite: Double) -> UInt32 { gris(0, opacite) }

    public static func gris(_ niveau: Double, _ opacite: Double) -> UInt32 {
        let n = UInt32(min(max(niveau, 0), 1) * 255)
        return n << 24 | n << 16 | n << 8 | UInt32(min(max(opacite, 0), 1) * 255)
    }

    public static func rvb(_ r: Double, _ v: Double, _ b: Double,
                           _ opacite: Double = 1) -> UInt32 {
        UInt32(min(max(r, 0), 1) * 255) << 24
            | UInt32(min(max(v, 0), 1) * 255) << 16
            | UInt32(min(max(b, 0), 1) * 255) << 8
            | UInt32(min(max(opacite, 0), 1) * 255)
    }

    /// Le jaune de la boucle, celui de la version macOS.
    public static func jaune(_ opacite: Double) -> UInt32 { rvb(1, 0.84, 0.04, opacite) }

    public func remplir(_ x: Double, _ y: Double, _ largeur: Double, _ hauteur: Double,
                        _ couleur: UInt32) {
        spectre_surimpression_rectangle(pont, Float(x), Float(y),
                                        Float(largeur), Float(hauteur), couleur)
    }

    public func tracer(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                       _ couleur: UInt32, epaisseur: Double = 0.5,
                       pointille: Bool = false) {
        spectre_surimpression_ligne(pont, Float(x0), Float(y0), Float(x1), Float(y1),
                                    couleur, Float(epaisseur), pointille ? 1 : 0)
    }

    /// Un trait vertical, l'appel le plus fréquent de toute la surimpression.
    public func vertical(x: Double, de y0: Double, a y1: Double,
                         _ couleur: UInt32, epaisseur: Double = 0.5) {
        tracer(x, y0, x, y1, couleur, epaisseur: epaisseur)
    }

    public func cercle(_ x: Double, _ y: Double, rayon: Double,
                       _ couleur: UInt32, epaisseur: Double = 1) {
        spectre_surimpression_cercle(pont, Float(x), Float(y), Float(rayon),
                                     couleur, Float(epaisseur))
    }

    /// Un cadre à angles droits — celui des raies, de la boucle, des accords.
    /// Quand il faut des coins arrondis, c'est `arrondi` qu'on demande.
    public func cadre(_ x: Double, _ y: Double, _ largeur: Double, _ hauteur: Double,
                      _ couleur: UInt32, epaisseur: Double = 1, pointille: Bool = false) {
        tracer(x, y, x + largeur, y, couleur, epaisseur: epaisseur, pointille: pointille)
        tracer(x, y + hauteur, x + largeur, y + hauteur, couleur,
               epaisseur: epaisseur, pointille: pointille)
        tracer(x, y, x, y + hauteur, couleur, epaisseur: epaisseur, pointille: pointille)
        tracer(x + largeur, y, x + largeur, y + hauteur, couleur,
               epaisseur: epaisseur, pointille: pointille)
    }

    /// Remplit une aire fermée. `points` est une suite de couples `x, y`.
    ///
    /// Le contour se referme du dernier point au premier. Un seul appel, quel que
    /// soit le nombre de points — c'est ce qui distingue une courbe d'un empilement
    /// de colonnes, et ce qui a rendu à la ligne de batterie les quarante images par
    /// seconde qu'elle avait coûtées.
    public func aire(_ points: [Double], _ couleur: UInt32) {
        guard points.count >= 6 else { return }
        var flottants = points.map { Float($0) }
        flottants.withUnsafeMutableBufferPointer {
            spectre_surimpression_aire(pont, $0.baseAddress,
                                       Int32($0.count / 2), couleur)
        }
    }

    public enum Alignement: Int32 { case gauche = 0, centre = 1, droite = 2 }
    public enum Police: Int32 {
        case interface = 0
        /// Chasse fixe : les chiffres de la réglette doivent avoir la même largeur
        /// d'un instant à l'autre, sinon le temps affiché tremble en défilant.
        case chiffres = 1
    }

    /// `y` est le **milieu** de la ligne, comme `context.draw(Text, at:)` de SwiftUI.
    public func texte(_ contenu: String, x: Double, y: Double, largeur: Double = 400,
                      taille: Double = 11, _ couleur: UInt32 = Pinceau.blanc(1),
                      police: Police = .interface, alignement: Alignement = .gauche) {
        contenu.withUTF16Terminé { pointeur in
            spectre_surimpression_texte(pont, pointeur, Float(x), Float(y),
                                        Float(largeur), Float(taille), couleur,
                                        police.rawValue, alignement.rawValue)
        }
    }

    /// Un paragraphe qui se replie dans `largeur`, et rend la hauteur qu'il occupe.
    ///
    /// `y` est ici le **haut** du bloc, et non le milieu d'une ligne comme pour
    /// `texte` : un texte dont on ignore le nombre de lignes ne peut pas se centrer
    /// sur une ordonnée choisie d'avance. `dessiner: false` se contente de mesurer.
    @discardableResult
    public func paragraphe(_ contenu: String, x: Double, y: Double, largeur: Double,
                           taille: Double = 10,
                           _ couleur: UInt32 = Pinceau.blanc(0.55),
                           police: Police = .interface,
                           dessiner: Bool = true) -> Double {
        contenu.withUTF16Terminé { pointeur in
            Double(spectre_surimpression_paragraphe(pont, pointeur, Float(x), Float(y),
                                                    Float(largeur), Float(taille),
                                                    couleur, police.rawValue,
                                                    dessiner ? 1 : 0))
        }
    }

    /// Un rectangle aux coins arrondis. `epaisseur` à zéro le remplit.
    public func arrondi(_ x: Double, _ y: Double, _ largeur: Double, _ hauteur: Double,
                        rayon: Double, _ couleur: UInt32, epaisseur: Double = 0) {
        spectre_surimpression_arrondi(pont, Float(x), Float(y), Float(largeur),
                                      Float(hauteur), Float(rayon), couleur,
                                      Float(epaisseur))
    }

    /// Un rectangle dont chaque coin a son propre rayon.
    ///
    /// Direct2D sait faire un rectangle arrondi, mais d'un seul rayon pour les
    /// quatre coins. La colonne des pistes en demande deux : le haut du premier
    /// bouton épouse la capsule qui l'entoure, son bas reste franc contre le bouton
    /// suivant — c'est la règle des coins concentriques, et sans elle les deux
    /// boutons extrêmes deviennent des ovales posés dans une capsule.
    ///
    /// Le contour est donc échantillonné et rempli d'un seul chemin. Superposer
    /// deux formes arrondies donnerait le même dessin et une couture partout où
    /// leurs bords se croisent : sur un fond translucide, la double couche se voit.
    public func arrondiInegal(_ x: Double, _ y: Double, _ largeur: Double,
                              _ hauteur: Double,
                              hautGauche: Double, hautDroite: Double,
                              basDroite: Double, basGauche: Double,
                              _ couleur: UInt32) {
        let limite = min(largeur, hauteur) / 2
        func borne(_ r: Double) -> Double { min(max(r, 0), limite) }
        let hg = borne(hautGauche), hd = borne(hautDroite)
        let bd = borne(basDroite), bg = borne(basGauche)
        var points: [Double] = []
        // Six segments par quart de tour : à trente points de rayon, le plus grand
        // que la colonne demande, la corde s'écarte de l'arc de moins d'un dixième
        // de point — en dessous de ce qu'un écran sait montrer.
        func coin(_ cx: Double, _ cy: Double, _ rayon: Double, de: Double, a: Double) {
            for i in 0...6 {
                let angle = de + (a - de) * Double(i) / 6
                points += [cx + cos(angle) * rayon, cy + sin(angle) * rayon]
            }
        }
        coin(x + hg, y + hg, hg, de: .pi, a: 1.5 * .pi)
        coin(x + largeur - hd, y + hd, hd, de: 1.5 * .pi, a: 2 * .pi)
        coin(x + largeur - bd, y + hauteur - bd, bd, de: 0, a: 0.5 * .pi)
        coin(x + bg, y + hauteur - bg, bg, de: 0.5 * .pi, a: .pi)
        aire(points, couleur)
    }

    /// Une portion d'anneau. Les angles sont en radians, comptés depuis la droite
    /// et croissant vers le bas — le sens de l'axe des ordonnées de la fenêtre.
    ///
    /// `cercle` cerne un tour entier ; il n'y a pas de primitive pour un morceau de
    /// tour, et le berceau du microphone en est un.
    public func arc(_ cx: Double, _ cy: Double, rayon: Double, epaisseur: Double,
                    de: Double, a: Double, _ couleur: UInt32) {
        let pas = max(Int(abs(a - de) * 6), 4)
        let externe = rayon + epaisseur / 2, interne = rayon - epaisseur / 2
        var points: [Double] = []
        for i in 0...pas {
            let angle = de + (a - de) * Double(i) / Double(pas)
            points += [cx + cos(angle) * externe, cy + sin(angle) * externe]
        }
        for i in stride(from: pas, through: 0, by: -1) {
            let angle = de + (a - de) * Double(i) / Double(pas)
            points += [cx + cos(angle) * interne, cy + sin(angle) * interne]
        }
        aire(points, couleur)
    }

    /// Un disque plein.
    ///
    /// `cercle` cerne — c'est ce que la réglette lui demande — et un carré dont
    /// l'arrondi vaut la moitié du côté *est* un disque : cela évite d'ajouter une
    /// primitive au pont pour les pouces des curseurs et les points des icônes.
    public func disque(_ cx: Double, _ cy: Double, _ rayon: Double, _ couleur: UInt32) {
        arrondi(cx - rayon, cy - rayon, rayon * 2, rayon * 2, rayon: rayon, couleur)
    }

    /// Restreint le dessin à un rectangle, le temps du bloc.
    ///
    /// Apparié par construction : une découpe posée et non reprise fait échouer la
    /// fin du dessin, et c'est l'image entière — spectrogramme compris — qui
    /// disparaît alors sans un mot.
    public func decoupe(_ x: Double, _ y: Double, _ largeur: Double, _ hauteur: Double,
                        _ corps: () -> Void) {
        spectre_surimpression_decouper(pont, Float(x), Float(y), Float(largeur),
                                       Float(hauteur))
        corps()
        spectre_surimpression_recoller(pont)
    }

    public func largeur(_ contenu: String, taille: Double = 11,
                        police: Police = .interface) -> Double {
        contenu.withUTF16Terminé { pointeur in
            Double(spectre_surimpression_largeur_texte(pont, pointeur, Float(taille),
                                                       police.rawValue))
        }
    }

    /// Une étiquette lisible par-dessus n'importe quoi : un fond sombre, puis le
    /// texte. Les graves du spectrogramme sont la partie la plus dense de l'image,
    /// et c'est exactement là que les noms tombent.
    @discardableResult
    public func etiquette(_ contenu: String, x: Double, y: Double, taille: Double = 11,
                          _ couleur: UInt32 = Pinceau.blanc(1),
                          fond: UInt32 = Pinceau.noir(0.75),
                          police: Police = .interface) -> Double {
        let l = largeur(contenu, taille: taille, police: police)
        remplir(x - 3, y - taille * 0.8, l + 6, taille * 1.6, fond)
        texte(contenu, x: x, y: y, largeur: l + 2, taille: taille, couleur, police: police)
        return l
    }
}

extension String {
    /// Le texte en UTF-16 terminé par un zéro, ce que DirectWrite attend.
    func withUTF16Terminé<T>(_ corps: (UnsafePointer<UInt16>) -> T) -> T {
        var unites = Array(utf16)
        unites.append(0)
        return unites.withUnsafeBufferPointer { corps($0.baseAddress!) }
    }
}

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
