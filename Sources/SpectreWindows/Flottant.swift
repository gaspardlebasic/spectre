import Foundation
import SpectreCore
import SpectreModele
import SpectreWin

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
// posé au bord droit, qui prend soixante-huit points de large et laisse tout le
// reste à l'image. Ce qu'on perd, c'est une bande de spectrogramme ; ce qu'on
// gagne, c'est de ne plus ouvrir un panneau pour changer de piste.
// ─────────────────────────────────────────────────────────────────────────────

/// La colonne flottante du bord droit : « Réglages », puis les quatre pistes.
///
/// Elle est dessinée à chaque image comme le panneau, et pour la même raison :
/// elle lit et écrit directement dans le modèle, sans état propre à tenir
/// accordé. Le sien se réduit à ce que la souris a fait depuis l'image d'avant.
final class Flottant {
    /// Largeur de la colonne, en points. « Batterie » et « Réglages » y tiennent
    /// à dix points de corps, ce qui fixe la valeur : plus étroit, il faudrait
    /// abréger l'un des deux, et une piste abrégée ne se reconnaît plus d'un coup
    /// d'œil.
    static let largeur = 68.0
    /// Marge au bord droit de la fenêtre. La même que celle du panneau, qui vient
    /// se ranger à sa gauche.
    static let marge = 12.0
    /// Ce que la colonne coûte à la largeur utile : elle-même, sa marge, et l'air
    /// qui la sépare du panneau ouvert.
    static var encombrement: Double { largeur + marge + ecartAuPanneau }
    static let ecartAuPanneau = 10.0

    private static let interieur = 4.0
    private static let hauteurBouton = 34.0
    private static let ecart = 3.0
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

    func sourisA(_ p: CGPoint) { souris = p }
    func appuiA(_ p: CGPoint) { souris = p; appuiEnAttente = p }
    func sourisPartie() { souris = CGPoint(x: -1000, y: -1000) }

    // MARK: La géométrie

    private func x(largeurFenetre: Double) -> Double {
        largeurFenetre - Self.largeur - Self.marge
    }

    /// Hauteur totale : le bouton des réglages, un blanc, puis la capsule des
    /// quatre pistes.
    private var hauteur: Double {
        let pistes = Double(Self.ordre.count) * Self.hauteurBouton
            + Double(Self.ordre.count - 1) * Self.ecart + 2 * Self.interieur
        return Self.hauteurBouton + 10 + pistes
    }

    /// Vrai si ce point tombe sur la colonne. La fenêtre s'en sert pour ne pas
    /// envoyer au spectrogramme un clic qui visait une piste.
    func contient(_ p: CGPoint, largeurFenetre: Double) -> Bool {
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
    func dessiner(pinceau p: Pinceau, largeurFenetre: Double, modele: AppModel,
                  panneauOuvert: Bool, basculerLesReglages: () -> Void) {
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
        bouton(p, zoneReglages, texte: "Réglages", allume: panneauOuvert,
               utilisable: true, rayon: Self.hauteurBouton / 2)

        // ── La capsule des quatre pistes ──────────────────────────────────────
        let yPistes = yReglages + Self.hauteurBouton + 10
        let hauteurPistes = Double(Self.ordre.count) * Self.hauteurBouton
            + Double(Self.ordre.count - 1) * Self.ecart + 2 * Self.interieur
        p.arrondi(gauche, yPistes, Self.largeur, hauteurPistes,
                  rayon: Self.largeur / 2, Pinceau.gris(0.10, 0.62))
        p.arrondi(gauche, yPistes, Self.largeur, hauteurPistes,
                  rayon: Self.largeur / 2, Pinceau.blanc(0.16), epaisseur: 1)

        let vide = modele.spectrogram.columnCount == 0
        for (rang, piste) in Self.ordre.enumerated() {
            let y = yPistes + Self.interieur
                + Double(rang) * (Self.hauteurBouton + Self.ecart)
            let zone = CGRect(x: gauche + Self.interieur, y: y,
                              width: Self.largeur - 2 * Self.interieur,
                              height: Self.hauteurBouton)
            let cochee = modele.selection.contains(piste)
            // La sélection dit ce qu'on **garde**. La dernière piste cochée ne se
            // décoche pas : il ne resterait rien à écouter.
            let utilisable = !vide && modele.selection != [piste]
            if utilisable, let appui = appuiEnAttente, zone.contains(appui) {
                appuiEnAttente = nil
                modele.toggle(piste)
            }
            // Les coins extérieurs épousent la capsule, les intérieurs sont
            // francs : c'est la règle des coins concentriques, la même que sur le
            // Mac, et c'est ce qui fait qu'un bouton inscrit dans une capsule n'a
            // pas l'air d'y avoir été posé de travers.
            let extreme = rang == 0 || rang == Self.ordre.count - 1
            bouton(p, zone, texte: piste.label,
                   allume: modele.selection.contains(piste), utilisable: utilisable,
                   rayon: extreme ? Self.largeur / 2 - Self.interieur : 9,
                   fondEteint: false)
        }
    }

    // MARK: - Le détail

    /// Un bouton de la colonne : sa pastille, son état, son intitulé centré.
    private func bouton(_ p: Pinceau, _ zone: CGRect, texte: String, allume: Bool,
                        utilisable: Bool, rayon: Double, fondEteint: Bool = true) {
        let survole = utilisable && zone.contains(souris)
        let opacite = utilisable || allume ? 1.0 : 0.45

        if allume {
            p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: rayon,
                      Pinceau.blanc(0.20))
        } else if fondEteint || survole {
            p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: rayon,
                      Pinceau.gris(0.10, survole ? 0.80 : 0.62))
        }
        if fondEteint, !allume {
            p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: rayon,
                      Pinceau.blanc(0.16), epaisseur: 1)
        }
        p.texte(texte, x: zone.minX, y: zone.midY, largeur: zone.width, taille: 10,
                Pinceau.blanc((allume ? 0.96 : 0.66) * opacite),
                alignement: .centre)
    }
}
