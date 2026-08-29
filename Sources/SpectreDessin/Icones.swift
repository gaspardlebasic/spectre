import Foundation
import SpectreCore
import SpectreToile

// Les icônes de la colonne flottante, dessinées au trait.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI ELLES NE VIENNENT PAS D'UNE POLICE
//
// `Stem.symbol` nomme des SF Symbols, et le fichier qui les porte prévoit qu'une
// autre plateforme « les traduise dans sa propre police d'icônes ». Windows en a
// une — Segoe Fluent Icons, Segoe MDL2 Assets avant elle — et la traduction s'y
// arrête à mi-chemin : elle a bien un microphone et un haut-parleur, elle n'a ni
// clavier de piano ni batterie. Un nom de glyphe absent ne lève aucune erreur, il
// laisse un carré vide à la place de l'icône ; deux boutons sur quatre seraient
// donc muets, et c'est précisément ceux-là qu'on reconnaît le moins par leur seul
// intitulé.
//
// Elles sont donc tracées, comme tout le reste de cette interface. Cinq formes de
// quinze points, faites des mêmes primitives que les curseurs et les bascules —
// et rien à installer sur la machine de personne.
// ─────────────────────────────────────────────────────────────────────────────

/// Une icône de la colonne, dessinée dans un carré d'environ quinze points.
///
/// Chacune répond au SF Symbol que `Stem` nomme, et ne s'en écarte que de ce que
/// quinze points imposent : trois touches de piano plutôt que sept, quatre points
/// dans le cercle de la batterie plutôt qu'une grille entière.
enum Icone {
    /// `slider.horizontal.3` — la porte des réglages.
    case reglages
    /// `music.mic` — la voix.
    case voix
    /// `pianokeys` — tout le reste : claviers, guitares, cuivres, cordes.
    case reste
    /// `hifispeaker` — la basse.
    case basse
    /// `circle.grid.cross` — la batterie.
    case batterie
    /// `waveform` — le morceau tel qu'il est.
    case mixage
    /// `trash` — retirer un morceau de la page de lancement, et jeter ses pistes.
    case corbeille

    /// L'icône d'une piste. La correspondance suit `Stem.symbol`, symbole pour
    /// symbole : il n'y a pas deux listes de pistes, seulement deux façons de les
    /// dessiner.
    static func pour(_ piste: Stem) -> Icone {
        switch piste {
        case .vocals: .voix
        case .other: .reste
        case .bass: .basse
        case .drums: .batterie
        case .mix: .mixage
        }
    }

    /// Trace l'icône, centrée sur ce point.
    func dessiner(_ p: Pinceau, cx: Double, cy: Double, _ couleur: UInt32) {
        switch self {
        case .reglages:
            // Trois rails et leurs pouces, chacun à sa place : c'est ce qui
            // distingue l'icône d'un empilement de traits.
            for (dy, dx) in [(-4.6, 1.6), (0.0, -2.6), (4.6, 3.0)] {
                p.tracer(cx - 6.5, cy + dy, cx + 6.5, cy + dy, couleur, epaisseur: 1.4)
                p.disque(cx + dx, cy + dy, 2.4, couleur)
            }

        case .voix:
            p.arrondi(cx - 2.6, cy - 7.5, 5.2, 9.6, rayon: 2.6, couleur)
            p.arc(cx, cy - 1.4, rayon: 5.3, epaisseur: 1.4, de: 0, a: .pi, couleur)
            p.tracer(cx, cy + 4, cx, cy + 7, couleur, epaisseur: 1.4)
            p.tracer(cx - 3, cy + 7, cx + 3, cy + 7, couleur, epaisseur: 1.4)

        case .reste:
            // Trois touches blanches et deux noires. Moins que sur un clavier, assez
            // pour qu'on en reconnaisse un à quatorze points de large.
            p.arrondi(cx - 6.5, cy - 6, 13, 12, rayon: 1.5, couleur, epaisseur: 1.2)
            p.tracer(cx - 2.2, cy - 6, cx - 2.2, cy + 6, couleur, epaisseur: 1)
            p.tracer(cx + 2.2, cy - 6, cx + 2.2, cy + 6, couleur, epaisseur: 1)
            p.remplir(cx - 3.4, cy - 6, 2.4, 7, couleur)
            p.remplir(cx + 1, cy - 6, 2.4, 7, couleur)

        case .basse:
            p.arrondi(cx - 4.6, cy - 7, 9.2, 14, rayon: 2, couleur, epaisseur: 1.2)
            p.cercle(cx, cy - 2.4, rayon: 2.5, couleur, epaisseur: 1.2)
            p.disque(cx, cy + 3.8, 1.2, couleur)

        case .batterie:
            p.cercle(cx, cy, rayon: 6.6, couleur, epaisseur: 1.2)
            for (dx, dy) in [(0.0, -3.3), (3.3, 0.0), (0.0, 3.3), (-3.3, 0.0)] {
                p.disque(cx + dx, cy + dy, 1.3, couleur)
            }

        case .mixage:
            for (i, hauteur) in [3.0, 6.5, 4.5, 7.0, 3.5].enumerated() {
                let x = cx - 6 + Double(i) * 3
                p.tracer(x, cy - hauteur, x, cy + hauteur, couleur, epaisseur: 1.4)
            }

        case .corbeille:
            // Le couvercle, son anse, la cuve et deux stries. Deux stries et non
            // trois : à quatorze points de large, la troisième se confond avec les
            // bords de la cuve et l'icône devient un rectangle hachuré.
            p.tracer(cx - 6, cy - 4, cx + 6, cy - 4, couleur, epaisseur: 1.3)
            p.tracer(cx - 2.4, cy - 6.4, cx + 2.4, cy - 6.4, couleur, epaisseur: 1.3)
            p.tracer(cx - 2.4, cy - 6.4, cx - 2.4, cy - 4, couleur, epaisseur: 1.3)
            p.tracer(cx + 2.4, cy - 6.4, cx + 2.4, cy - 4, couleur, epaisseur: 1.3)
            p.tracer(cx - 4.4, cy - 4, cx - 3.6, cy + 6.6, couleur, epaisseur: 1.3)
            p.tracer(cx + 4.4, cy - 4, cx + 3.6, cy + 6.6, couleur, epaisseur: 1.3)
            p.tracer(cx - 3.6, cy + 6.6, cx + 3.6, cy + 6.6, couleur, epaisseur: 1.3)
            p.tracer(cx - 1.4, cy - 1.6, cx - 1.4, cy + 4, couleur, epaisseur: 1)
            p.tracer(cx + 1.4, cy - 1.6, cx + 1.4, cy + 4, couleur, epaisseur: 1)
        }
    }
}
