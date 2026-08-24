import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele
import SpectreToile

// Ce qui reste à l'écran quoi qu'il arrive : les quatre pistes, et la porte des
// réglages.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CELA NE POUVAIT PAS RESTER DANS LE PANNEAU
//
// Sur le Mac, le sélecteur de pistes flotte en permanence sur l'image en verre
// clair, et le panneau se déplie à sa gauche. Le portage l'avait replié dans le
// panneau, faute de verre : sans flou, une colonne posée sur le spectrogramme le
// troue — c'est la note sur l'opacité de `Panneau.swift`.
//
// Sauf que ce n'est pas un réglage qu'on tourne une fois par morceau. Passer du
// mixage à la basse seule, puis à la voix, puis revenir, c'est le geste **du**
// relevé : on le fait vingt fois par minute, et à chaque fois il fallait ouvrir
// le panneau, viser une bascule, le refermer pour revoir l'image qu'on venait de
// changer. Et le bouton des réglages lui-même n'était nulle part : il fallait
// connaître « R », ou trouver le menu du clic droit.
//
// D'où cette colonne. Pas de verre, donc pas de mensonge : un fond sombre franc,
// posé au bord droit, qui prend soixante-deux points de large et laisse tout le
// reste à l'image. Ce qu'on perd, c'est une bande de spectrogramme ; ce qu'on
// gagne, c'est de ne plus ouvrir un panneau pour changer de piste.
// ─────────────────────────────────────────────────────────────────────────────

/// La colonne flottante du bord droit : « Réglages », puis les quatre pistes.
///
/// Elle est dessinée à chaque image comme le panneau, et pour la même raison :
/// elle lit et écrit directement dans le modèle, sans état propre à tenir
/// accordé. Le sien se réduit à ce que la souris a fait depuis l'image d'avant.
public final class Flottant {
    public init() {}

    /// Les mesures sont celles de `StemColumn` sur le Mac, point pour point.
    ///
    /// Elles ne sont pas un goût. La capsule qui entoure les quatre boutons a des
    /// extrémités en demi-cercle, de rayon `largeur / 2`. Pour que le premier et le
    /// dernier bouton **épousent** cette courbe au lieu de la croiser, leur arrondi
    /// extérieur vaut ce rayon moins la marge — c'est la règle des coins
    /// concentriques, et c'est ce qui fait qu'un bouton inscrit dans une capsule n'a
    /// pas l'air d'y avoir été posé de travers.
    ///
    /// Les coins intérieurs, eux, restent francs : deux demi-lunes en vis-à-vis
    /// creuseraient un losange de fond entre deux boutons voisins.
    public static let largeur = 62.0
    /// Marge au bord droit de la fenêtre. La même que celle du panneau, qui vient
    /// se ranger à sa gauche.
    public static let marge = 12.0
    /// Ce que la colonne coûte à la largeur utile : elle-même, sa marge, et l'air
    /// qui la sépare du panneau ouvert.
    public static var encombrement: Double { largeur + marge + ecartAuPanneau }
    public static let ecartAuPanneau = 10.0

    private static let interieur = 4.0
    private static let hauteurBouton = 40.0
    private static let ecart = 3.0
    private static let rayonDome = largeur / 2 - interieur
    private static let rayonInterne = 9.0
    /// Sous la réglette du haut : un clic dans les vingt premiers points trace une
    /// boucle, et la colonne n'a pas à disputer cette bande-là.
    private static let haut = hauteurDeLaReglette + 8

    /// Du haut vers le bas : voix, accompagnement, basse, batterie. C'est l'ordre
    /// des hauteurs, celui qu'on a déjà sous les yeux dans l'image — et non
    /// l'ordre où le réseau rend ses sorties, qui n'a de sens que pour lui. Le
    /// même que `StemColumn` sur le Mac, et il n'y a pas deux bons ordres.
    private static let ordre: [Stem] = [.vocals, .other, .bass, .drums]

    // MARK: Ce que la souris a fait depuis la dernière image

    private var souris = CGPoint(x: -1000, y: -1000)
    private var appuiEnAttente: CGPoint?

    public func sourisA(_ p: CGPoint) { souris = p }
    public func appuiA(_ p: CGPoint) { souris = p; appuiEnAttente = p }
    public func sourisPartie() { souris = CGPoint(x: -1000, y: -1000) }

    // MARK: La géométrie

    private func x(largeurFenetre: Double) -> Double {
        largeurFenetre - Self.largeur - Self.marge
    }

    /// Hauteur totale : le bouton des réglages, un blanc, puis la capsule des
    /// quatre pistes.
    private var hauteur: Double { Self.hauteurBouton + 10 + hauteurDesPistes }

    private var hauteurDesPistes: Double {
        Double(Self.ordre.count) * Self.hauteurBouton
            + Double(Self.ordre.count - 1) * Self.ecart + 2 * Self.interieur
    }

    /// Vrai si ce point tombe sur la colonne. La fenêtre s'en sert pour ne pas
    /// envoyer au spectrogramme un clic qui visait une piste.
    public func contient(_ p: CGPoint, largeurFenetre: Double) -> Bool {
        let gauche = x(largeurFenetre: largeurFenetre)
        return p.x >= gauche && p.x <= gauche + Self.largeur
            && p.y >= Self.haut && p.y <= Self.haut + hauteur
    }

    // MARK: - Le tour de dessin

    /// Dessine la colonne et applique ce qu'on vient d'y cliquer.
    ///
    /// `basculerLesReglages` plutôt qu'un drapeau à poser : ouvrir le panneau
    /// remet aussi `pointerOverControls` d'aplomb, et cette logique-là vit dans
    /// `Gestes`. Une seule façon d'ouvrir le panneau, quel que soit le geste.
    public func dessiner<Lecteur: LecteurAudio>(
        pinceau p: Pinceau, infobulle: Infobulle, largeurFenetre: Double,
        modele: AppModel<Lecteur>, panneauOuvert: Bool,
        basculerLesReglages: () -> Void) {
        defer { appuiEnAttente = nil }
        let gauche = x(largeurFenetre: largeurFenetre)

        // ── Le bouton des réglages ────────────────────────────────────────────
        //
        // Il reste là quand le panneau est ouvert, allumé, et le referme : sur le
        // Mac il se replie *dans* le panneau, ce qui suppose de faire tenir deux
        // formes de verre pour une seule. Ici, une capsule qui s'allume dit la
        // même chose et se reclique au même endroit.
        let yReglages = Self.haut
        let zoneReglages = CGRect(x: gauche, y: yReglages, width: Self.largeur,
                                  height: Self.hauteurBouton)
        if let appui = appuiEnAttente, zoneReglages.contains(appui) {
            appuiEnAttente = nil
            basculerLesReglages()
        }
        let capsule = Self.hauteurBouton / 2
        bouton(p, zoneReglages, icone: .reglages, texte: T(.panneauReglages),
               allume: panneauOuvert, utilisable: true,
               hautGauche: capsule, hautDroite: capsule,
               basDroite: capsule, basGauche: capsule, fondEteint: true)
        survol(infobulle, zoneReglages, T(.panneauOuvrirAideWin))

        // ── La capsule des quatre pistes ──────────────────────────────────────
        let yPistes = yReglages + Self.hauteurBouton + 10
        p.arrondi(gauche, yPistes, Self.largeur, hauteurDesPistes,
                  rayon: Self.largeur / 2, Pinceau.gris(0.10, 0.62))
        p.arrondi(gauche, yPistes, Self.largeur, hauteurDesPistes,
                  rayon: Self.largeur / 2, Pinceau.blanc(0.16), epaisseur: 1)

        let vide = modele.spectrogram.columnCount == 0
        for (rang, piste) in Self.ordre.enumerated() {
            let y = yPistes + Self.interieur
                + Double(rang) * (Self.hauteurBouton + Self.ecart)
            let zone = CGRect(x: gauche + Self.interieur, y: y,
                              width: Self.largeur - 2 * Self.interieur,
                              height: Self.hauteurBouton)
            // La sélection dit ce qu'on **garde**. La dernière piste cochée ne se
            // décoche pas : il ne resterait rien à écouter.
            let utilisable = !vide && modele.selection != [piste]
            if utilisable, let appui = appuiEnAttente, zone.contains(appui) {
                appuiEnAttente = nil
                modele.toggle(piste)
            }
            let premier = rang == 0
            let dernier = rang == Self.ordre.count - 1
            bouton(p, zone, icone: Icone.pour(piste), texte: piste.label,
                   allume: modele.selection.contains(piste), utilisable: utilisable,
                   hautGauche: premier ? Self.rayonDome : Self.rayonInterne,
                   hautDroite: premier ? Self.rayonDome : Self.rayonInterne,
                   basDroite: dernier ? Self.rayonDome : Self.rayonInterne,
                   basGauche: dernier ? Self.rayonDome : Self.rayonInterne,
                   fondEteint: false)
            survol(infobulle, zone, piste.help + T(.pisteDecocherAide))
        }
    }

    // MARK: - Le détail

    /// Un bouton de la colonne : sa pastille, son icône, son intitulé.
    ///
    /// L'icône n'est pas un ornement. À soixante-deux points de large, l'intitulé
    /// tient en neuf points de corps et se lit de près ; la forme, elle, se reconnaît
    /// du coin de l'œil, et c'est ce qu'on demande à un sélecteur qu'on touche vingt
    /// fois par minute sans quitter l'image des yeux.
    private func bouton(_ p: Pinceau, _ zone: CGRect, icone: Icone, texte: String,
                        allume: Bool, utilisable: Bool,
                        hautGauche: Double, hautDroite: Double,
                        basDroite: Double, basGauche: Double, fondEteint: Bool) {
        let survole = utilisable && zone.contains(souris)
        let opacite = utilisable || allume ? 1.0 : 0.45

        func fond(_ couleur: UInt32) {
            p.arrondiInegal(zone.minX, zone.minY, zone.width, zone.height,
                            hautGauche: hautGauche, hautDroite: hautDroite,
                            basDroite: basDroite, basGauche: basGauche, couleur)
        }
        if allume {
            fond(Pinceau.blanc(0.20))
        } else if fondEteint || survole {
            fond(Pinceau.gris(0.10, survole ? 0.80 : 0.62))
        }
        if fondEteint, !allume {
            p.arrondi(zone.minX, zone.minY, zone.width, zone.height,
                      rayon: hautGauche, Pinceau.blanc(0.16), epaisseur: 1)
        }

        let encre = Pinceau.blanc((allume ? 0.96 : 0.62) * opacite)
        icone.dessiner(p, cx: zone.midX, cy: zone.midY - 6, encre)
        p.texte(texte, x: zone.minX, y: zone.midY + 12, largeur: zone.width, taille: 9,
                encre, alignement: .centre)
    }

    /// Propose l'infobulle de ce bouton, si la souris est dessus.
    private func survol(_ infobulle: Infobulle, _ zone: CGRect, _ aide: String) {
        guard zone.contains(souris) else { return }
        infobulle.proposer(aide, zone)
    }
}
