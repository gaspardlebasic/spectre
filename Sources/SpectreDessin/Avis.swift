import Foundation
import SpectreCore
import SpectreTextes
import SpectreToile

// La phrase du premier lancement : Spectre enverra ses pannes.
//
// ─────────────────────────────────────────────────────────────────────────────
// ON INFORME, ON NE DEMANDE PAS — ET LA FORME DIT LAQUELLE DES DEUX
//
// Pas de case à cocher, et ce n'est pas une négligence : une case décochée par
// défaut ne serait cochée par personne — c'est la même impasse que le bouton
// « Signaler un problème » que personne ne clique — et une case cochée par défaut
// serait un consentement de façade, ce qui est pire que de le dire franchement. La
// case viendra si l'application trouve un public ; à ce moment-là le nombre de
// personnes concernées change la nature de la chose. Voir `docs/RAPPORTS.md`.
//
// Il reste qu'une application dont le parti pris affiché est le hors ligne ne peut
// pas se mettre à téléphoner en silence. D'où ceci : **au milieu, une fois, et
// impossible à manquer**. Le fond est assombri pour que rien d'autre ne se lise
// pendant qu'elle est là — ce n'est pas une bannière qu'on chasse d'un coin de
// l'œil.
//
// **Ce qui ne part pas y est écrit aussi gros que ce qui part.** C'est la moitié
// qui décide si les gens gardent l'application installée, et la cacher en petits
// caractères reviendrait à ne pas l'avoir écrite.
//
// Le pendant macOS est dans `Sources/Spectre/Controls.swift`, en SwiftUI, et dit
// mot pour mot la même chose : les textes sortent du même catalogue.
// ─────────────────────────────────────────────────────────────────────────────

/// L'avis, dessiné par-dessus tout le reste tant que personne ne l'a lu.
public struct Avis {
    public init() {}

    /// La largeur du carton. Assez étroit pour que les lignes se lisent, assez
    /// large pour que le texte ne fasse pas dix lignes dans une fenêtre étroite.
    private static let largeurDuCarton = 460.0
    private static let marge = 26.0

    /// Dessine l'avis. Ne fait rien s'il n'y a rien à dire.
    public func dessiner(pinceau: Pinceau, largeurFenetre: Double,
                         hauteurFenetre: Double, aMontrer: Bool) {
        guard aMontrer else { return }

        let largeur = min(Self.largeurDuCarton, largeurFenetre - 60)
        let interieur = largeur - 2 * Self.marge
        let corps = T(.avisRapportsCorps)
        let secret = T(.avisRapportsSecret)

        // Mesuré avant d'être dessiné : la hauteur du carton dépend du nombre de
        // lignes, qui dépend de la langue. En allemand le même paragraphe en prend
        // une de plus, et un carton dont la hauteur serait écrite en dur couperait
        // sa dernière phrase — dans une langue que l'auteur ne relit pas.
        let hauteurCorps = pinceau.paragraphe(corps, x: 0, y: 0, largeur: interieur,
                                              taille: 11.5, dessiner: false)
        let hauteurSecret = pinceau.paragraphe(secret, x: 0, y: 0, largeur: interieur,
                                               taille: 11.5, dessiner: false)
        let hauteur = Self.marge + 22 + 14 + hauteurCorps + 14 + hauteurSecret
                    + 22 + 30 + Self.marge

        let x = (largeurFenetre - largeur) / 2
        let y = (hauteurFenetre - hauteur) / 2

        // Tout le reste s'efface derrière : tant que cette phrase est là, il n'y a
        // rien d'autre à lire.
        pinceau.remplir(0, 0, largeurFenetre, hauteurFenetre, Pinceau.noir(0.62))
        pinceau.arrondi(x, y, largeur, hauteur, rayon: 14, Pinceau.gris(0.12, 0.99))
        pinceau.arrondi(x, y, largeur, hauteur, rayon: 14, Pinceau.blanc(0.14),
                        epaisseur: 1)

        var curseur = y + Self.marge
        pinceau.texte(T(.avisRapportsTitre), x: x + Self.marge, y: curseur + 9,
                      largeur: interieur, taille: 14, Pinceau.blanc(0.92))
        curseur += 22 + 14

        curseur += pinceau.paragraphe(corps, x: x + Self.marge, y: curseur,
                                      largeur: interieur, taille: 11.5,
                                      Pinceau.blanc(0.72))
        curseur += 14
        // La même taille que ce qui précède, et une teinte qui appelle l'œil : ce
        // qui ne part pas n'est pas une note de bas de page.
        curseur += pinceau.paragraphe(secret, x: x + Self.marge, y: curseur,
                                      largeur: interieur, taille: 11.5,
                                      Pinceau.rvb(0.62, 0.86, 0.70, 0.95))
        curseur += 22

        let largeurDuBouton = 150.0
        let xBouton = x + (largeur - largeurDuBouton) / 2
        pinceau.arrondi(xBouton, curseur, largeurDuBouton, 30, rayon: 8,
                        Pinceau.blanc(0.14))
        pinceau.texte(T(.avisRapportsCompris), x: xBouton, y: curseur + 15,
                      largeur: largeurDuBouton, taille: 11.5, Pinceau.blanc(0.9),
                      alignement: .centre)
    }
}
