import Foundation
import SpectreCore
import SpectreModele
import SpectreToile

// La ligne de batterie, sous le spectrogramme.
//
// Le pendant de `Sources/Spectre/DrumLaneView.swift`, aux mêmes dimensions et avec
// les mêmes règles. Elle partage l'axe des temps du spectrogramme, à la colonne
// près : zoomer, défiler et poser une boucle continuent donc de valoir pour elle,
// et un coup se lit à l'aplomb de ce qui l'a produit dans l'image.

public struct Batterie<Lecteur: LecteurAudio> {
    let modele: AppModel<Lecteur>
    let pinceau: Pinceau
    let largeur: Double
    /// Ordonnée du haut de la bande, dans la fenêtre.
    let haut: Double
    let hauteur: Double

    /// Hauteur d'une ligne, et espace entre deux. Les mêmes que sur le Mac.
    private let hauteurDeRangee = 17.0
    private let ecart = 1.0
    private let margeHaute = 4.0
    /// Largeur du couloir des intitulés, à gauche.
    private let couloir = 26.0

    public init(modele: AppModel<Lecteur>, pinceau: Pinceau,
                largeur: Double, haut: Double, hauteur: Double) {
        self.modele = modele
        self.pinceau = pinceau
        self.largeur = largeur
        self.haut = haut
        self.hauteur = hauteur
    }

    public func dessiner() {
        pinceau.remplir(0, haut, largeur, hauteur, Pinceau.noir(0.92))
        pinceau.tracer(0, haut + 0.25, largeur, haut + 0.25, Pinceau.blanc(0.16))
        guard modele.spectrogram.columnCount > 0 else { return }

        // Pendant la séparation, la ligne reste vide. Elle *pourrait* montrer le
        // relevé du mixage, mais ce relevé-là est approximatif et sera remplacé dans
        // la minute par celui de la piste de batterie isolée : l'afficher reviendrait
        // à faire lire deux fois deux rythmes différents.
        if !modele.calculEnCours {
            for voie in DrumVoice.allCases {
                courbe(voie)
                coups(voie)
            }
        }
        boucle()
        intitules()
        teteDeLecture()
        if let avis = modele.drumLaneNotice {
            pinceau.texte(avis, x: 0, y: haut + hauteur / 2, largeur: largeur,
                          taille: 10, Pinceau.blanc(0.55), alignement: .centre)
        }
    }

    private func rangee(_ voie: DrumVoice) -> (haut: Double, bas: Double) {
        let y = haut + margeHaute + Double(voie.rawValue) * (hauteurDeRangee + ecart)
        return (y, y + hauteurDeRangee)
    }

    private func couleur(_ voie: DrumVoice, _ opacite: Double) -> UInt32 {
        let c = voie.color
        return Pinceau.rvb(c.r, c.g, c.b, opacite)
    }

    /// La hauteur d'un pixel est le **maximum** de ce que la courbe fait sur sa
    /// largeur, jamais la moyenne — la même règle que le nuanceur du spectrogramme,
    /// et pour la même raison : une attaque est brève et s'effacerait dès qu'on
    /// regarde le morceau en entier.
    ///
    /// **Une aire, et un seul appel.**
    ///
    /// La première version dessinait une colonne d'un point de large par abscisse,
    /// faute d'aire dans le pont : trois mille six cents rectangles par image, et le
    /// relevé de fluidité est tombé de 120 à 76 images par seconde le jour où la
    /// ligne de batterie est arrivée. C'est la mesure de l'étape 6 qui l'a dit, et
    /// c'est exactement ce pour quoi elle existe — à l'œil, l'image était la même.
    private func courbe(_ voie: DrumVoice) {
        let percussion = modele.percussion
        guard !percussion.isEmpty else { return }
        let r = rangee(voie)

        // Le relevé, la fenêtre visible et l'échelle des temps sont pris **une fois**
        // avant la boucle, et non à chaque abscisse.
        //
        // Ce n'est pas de l'avarice : `AppModel` est `@Observable`, et chaque lecture
        // d'une de ses propriétés passe par le suivi des dépendances. Douze cents
        // abscisses fois trois voies fois trois propriétés faisaient onze mille
        // lectures suivies par image, pour une courbe qui tient en deux nombres —
        // l'instant du bord gauche, et ce qu'un point vaut en secondes. Le temps est
        // affine en l'abscisse ; il n'y avait rien à demander au modèle.
        let instantGauche = modele.time(atPoint: 0)
        let parPoint = modele.time(atPoint: 1) - instantGauche

        var contour: [Double] = [0, r.bas]
        contour.reserveCapacity(Int(largeur) * 2 + 8)
        var x = 0.0
        while x <= largeur {
            defer { x += 1 }
            let t0 = instantGauche + x * parPoint
            let valeur = Double(percussion.level(voie, from: t0, to: t0 + parPoint))
            contour.append(x)
            contour.append(r.bas - valeur * (hauteurDeRangee - 1))
        }
        contour.append(largeur)
        contour.append(r.bas)
        pinceau.aire(contour, couleur(voie, 0.22))
    }

    /// Les coups. La force se lit à la fois sur la hauteur et sur l'opacité : l'une
    /// seule ne se voit pas assez sur dix-sept points de haut.
    ///
    /// **Un trait droit, fin**, et le même pour les trois voies : trois lignes qui
    /// répondent à la même question doivent se lire de la même façon, sans quoi l'œil
    /// croit que la différence veut dire quelque chose.
    private func coups(_ voie: DrumVoice) {
        let r = rangee(voie)
        let depuis = modele.time(atPoint: -4)
        let jusqua = modele.time(atPoint: largeur + 4)
        let epaisseur = 1.5
        for coup in modele.percussion.hits(from: depuis, to: jusqua) where coup.voice == voie {
            let x = modele.point(ofTime: coup.time)
            let h = (0.42 + 0.58 * Double(coup.strength)) * (hauteurDeRangee - 2)
            pinceau.remplir(x - epaisseur / 2, r.bas - h, epaisseur, h,
                            couleur(voie, 0.5 + 0.5 * Double(coup.strength)))
        }
    }

    /// Les intitulés vivent sur un fond opaque : posés à même les traits, ils
    /// deviennent illisibles dès qu'un charleston joue les doubles croches.
    private func intitules() {
        for voie in DrumVoice.allCases {
            let r = rangee(voie)
            pinceau.remplir(0, r.haut, couloir, hauteurDeRangee, Pinceau.noir(0.72))
            pinceau.texte(voie.short, x: 0, y: (r.haut + r.bas) / 2, largeur: couloir,
                          taille: 9, couleur(voie, 0.9), alignement: .centre)
        }
    }

    /// Ce qui est hors de la boucle s'assombrit, comme dans l'image au-dessus.
    private func boucle() {
        guard let plage = modele.loop else { return }
        let x0 = modele.point(ofTime: plage.lowerBound)
        let x1 = modele.point(ofTime: plage.upperBound)
        let dehors = Pinceau.noir(modele.loopEnabled ? 0.42 : 0.18)
        pinceau.remplir(0, haut, max(x0, 0), hauteur, dehors)
        pinceau.remplir(min(x1, largeur), haut, max(largeur - x1, 0), hauteur, dehors)
    }

    private func teteDeLecture() {
        let x = modele.point(ofTime: modele.playhead)
        guard x >= 0, x <= largeur else { return }
        pinceau.vertical(x: x, de: haut, a: haut + hauteur, Pinceau.blanc(0.85),
                         epaisseur: 1)
    }
}
