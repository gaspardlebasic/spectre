import Foundation
import SpectreCore
import SpectreModele
import SpectreToile

// Ce que dit une commande qu'on regarde sans y toucher.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI LES EXPLICATIONS ONT QUITTÉ LE PANNEAU
//
// Le panneau a porté ses explications en clair, sous chaque commande, et chaque
// raccourci sur sa propre ligne. C'était juste une fois : à la première ouverture.
// Ensuite on connaît ses réglages, et la phrase qui les décrit n'est plus qu'une
// hauteur à faire défiler entre le tempo et le contraste — au point de rendre le
// panneau deux fois plus long que la fenêtre, pour tourner un seul curseur.
//
// Elles sont donc toutes passées ici, sans en perdre une : survoler une commande
// dit encore ce qu'elle change et par quelle touche on la double. Ce qui reste à
// l'écran est ce qui **se règle**, et rien d'autre. Le panneau macOS a fait le
// même chemin au même moment — voir l'en-tête de `Controls.swift`.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI UN OBJET, ET PAS UN DESSIN SUR PLACE
//
// La bulle doit sortir du panneau : elle se pose à sa gauche, sur le
// spectrogramme, et le panneau dessine sous une découpe qui la couperait net. Elle
// doit aussi passer par-dessus la colonne flottante et la barre d'état, qui sont
// dessinées après lui.
//
// Les commandes se contentent donc de **proposer** — « la souris est sur moi,
// voici ce que j'ai à dire » — et la bulle est tracée en dernier, une fois
// l'image entière posée.
// ─────────────────────────────────────────────────────────────────────────────

/// L'infobulle de l'image en cours : ce qu'une commande survolée a proposé, et le
/// dessin qui s'ensuit une fois le survol assez long.
public final class Infobulle {
    public init() {}

    /// Le temps de survol avant que la bulle paraisse.
    ///
    /// Sans attente, traverser le panneau pour atteindre un curseur ferait clignoter
    /// six bulles en chemin. Une demi-seconde est ce qui sépare un regard d'un
    /// passage — c'est aussi ce que Windows attend pour les siennes.
    private static let delai = 0.5
    private static let largeurMax = 250.0
    private static let marge = 8.0
    private static let taille = 10.5

    /// Ce qu'une commande vient de proposer pour cette image.
    private var propose: (texte: String, ancre: CGRect)?
    /// Ce qui est survolé sans discontinuer, et depuis quand.
    private var tenu: String?
    private var depuis = 0.0

    /// « La souris est sur moi, et voici ce que j'ai à dire. »
    ///
    /// Appelée pendant le dessin, par la commande elle-même : elle seule connaît le
    /// rectangle qu'elle occupe, et c'est ce rectangle que la bulle doit éviter de
    /// recouvrir.
    func proposer(_ texte: String, _ ancre: CGRect) {
        propose = (texte, ancre)
    }

    /// Trace la bulle, s'il y a lieu. À appeler en dernier, après tout le reste.
    public func dessiner(_ p: Pinceau, largeurFenetre: Double, hauteurFenetre: Double) {
        defer { propose = nil }
        guard let propose else { tenu = nil; return }
        // Changer de commande relance le compte. Sans quoi, une fois la première
        // bulle méritée, toutes les suivantes paraîtraient instantanément en
        // glissant le long du panneau.
        if propose.texte != tenu {
            tenu = propose.texte
            depuis = Horloge.maintenant()
            return
        }
        guard Horloge.maintenant() - depuis > Self.delai else { return }

        let surUneLigne = p.largeur(propose.texte, taille: Self.taille)
        let largeurTexte = min(surUneLigne, Self.largeurMax)
        let hauteurTexte = p.paragraphe(propose.texte, x: 0, y: 0,
                                        largeur: largeurTexte, taille: Self.taille,
                                        dessiner: false)
        let largeur = largeurTexte + 2 * Self.marge
        let hauteur = hauteurTexte + 2 * Self.marge

        // À gauche de la commande, parce que tout ce qui porte des infobulles est
        // rangé au bord droit de la fenêtre : la bulle a la place de l'image, et ne
        // recouvre jamais ce qu'on est en train de survoler. À droite seulement si
        // la fenêtre est trop étroite pour l'autre côté.
        var x = propose.ancre.minX - largeur - 10
        if x < 8 { x = min(propose.ancre.maxX + 10, largeurFenetre - largeur - 8) }
        let y = min(max(propose.ancre.midY - hauteur / 2, 8),
                    max(hauteurFenetre - hauteur - 8, 8))

        p.arrondi(x, y, largeur, hauteur, rayon: 6, Pinceau.gris(0.13, 0.97))
        p.arrondi(x, y, largeur, hauteur, rayon: 6, Pinceau.blanc(0.18), epaisseur: 1)
        p.paragraphe(propose.texte, x: x + Self.marge, y: y + Self.marge,
                     largeur: largeurTexte, taille: Self.taille, Pinceau.blanc(0.86))
    }
}
