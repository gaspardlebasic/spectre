import Foundation
import SpectreCore
import SpectreModele
import SpectreToile

// De quoi poser des commandes sur l'image, en Direct2D.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI DU MODE IMMÉDIAT, ET PAS DES CONTRÔLES WIN32
//
// Windows sait faire des curseurs et des cases à cocher : `msctls_trackbar32`,
// `BUTTON`, et une fenêtre fille par commande. C'est ce qu'on ferait pour une
// boîte de dialogue, et ce serait ici une erreur.
//
// Une fenêtre fille est une surface que Windows compose lui-même, **par-dessus la
// chaîne d'échange**. Elle ne peut donc pas être translucide au-dessus du
// spectrogramme, elle arrive avec une image de retard sur ce que le nuanceur vient
// de dessiner, et elle sort du seul tampon que l'application présente — ce qui
// ferait disparaître les réglages de la photographie d'`essai.ps1`, précisément
// l'instrument qui sert à les regarder.
//
// Le panneau est donc dessiné comme le reste : dans le même tampon, en points, par
// le même pinceau que la réglette. Cela coûte d'écrire les commandes soi-même — ce
// fichier — et rend en échange une interface qui est *dans* l'image.
//
// Le mode immédiat, lui, n'est pas un goût : le panneau lit et écrit directement
// dans le modèle, qui est la seule source de vérité. Une hiérarchie de vues avec
// son propre état demanderait de les tenir accordés, et c'est exactement le second
// cerveau que tout ce portage cherche à ne pas fabriquer.
// ─────────────────────────────────────────────────────────────────────────────

/// Un panneau de réglages : le cadre, les commandes, et ce que la souris y fait.
///
/// Il ne connaît aucun réglage en particulier. Ce qu'il montre est décrit à chaque
/// image par `Commandes.swift`, qui l'appelle commande par commande.
///
/// Chaque commande porte son `aide` : la phrase qui était écrite sous elle, et qui
/// paraît maintenant en infobulle quand on la survole — voir `Infobulle.swift`.
/// Elle n'est pas facultative. Une commande dont personne ne sait dire ce qu'elle
/// change n'a rien à faire dans un panneau.
public final class Panneau {
    /// Largeur du panneau, en points. Assez pour qu'un intitulé et sa valeur
    /// tiennent sur une ligne, assez peu pour laisser voir l'image dessous.
    static let largeur = 330.0
    private static let marge = 15.0
    private static let ecart = 10.0

    public init() {}

    public var ouvert = false

    // MARK: L'état d'une image à l'autre

    private var defilement = 0.0
    private var hauteurDuContenu = 0.0
    /// Combien de titres ont été posés dans l'image en cours : le premier n'a pas de
    /// filet au-dessus de lui, les suivants si.
    private var sections = 0
    /// La commande qui tient le glisser en cours — un curseur qu'on tire. Elle garde
    /// la main même quand la souris en sort, sans quoi tirer un curseur un peu vite
    /// le lâcherait en chemin.
    private var actif: String?

    // MARK: Ce que la souris a fait depuis la dernière image

    private var souris = CGPoint(x: -1000, y: -1000)
    private var appuiEnAttente: CGPoint?
    private var molette = 0.0

    // MARK: La géométrie de l'image en cours

    private var pinceau: Pinceau?
    private var infobulle: Infobulle?
    private var gauche = 0.0
    private var haut = 0.0
    private var bas = 0.0
    private var y = 0.0

    private var contenuGauche: Double { gauche + Self.marge }
    private var contenuLargeur: Double { Self.largeur - 2 * Self.marge }

    // MARK: - Ce que la fenêtre lui envoie

    /// Le rectangle qu'il occupe, en points. `hauteurUtile` est la hauteur de la
    /// fenêtre moins la barre d'état : le panneau ne la recouvre pas.
    ///
    /// Il se range **à gauche de la colonne flottante**, comme sur le Mac où le
    /// panneau se déplie à gauche du sélecteur de pistes. Le recouvrir serait
    /// reprendre d'une main ce qu'on vient de donner de l'autre : la colonne est
    /// là pour qu'on change de piste sans ouvrir le panneau, encore faut-il
    /// qu'elle reste visible quand il l'est.
    func cadre(largeurFenetre: Double, hauteurUtile: Double)
        -> (x: Double, y: Double, largeur: Double, hauteur: Double) {
        let marge = 12.0
        let x = largeurFenetre - Self.largeur - Flottant.encombrement
        return (x, marge, Self.largeur, max(hauteurUtile - 2 * marge, 80))
    }

    /// Vrai si ce point tombe dans le panneau ouvert. La fenêtre s'en sert pour ne
    /// pas envoyer au spectrogramme un clic qui visait un curseur.
    public func contient(_ p: CGPoint, largeurFenetre: Double, hauteurUtile: Double) -> Bool {
        guard ouvert else { return false }
        let r = cadre(largeurFenetre: largeurFenetre, hauteurUtile: hauteurUtile)
        return p.x >= r.x && p.x <= r.x + r.largeur
            && p.y >= r.y && p.y <= r.y + r.hauteur
    }

    /// Vrai tant qu'un curseur est tenu. Le geste continue alors même quand la
    /// souris sort du panneau — sans quoi tirer un curseur un peu vite le lâcherait.
    public var glisseEnCours: Bool { actif != nil }

    public func sourisA(_ p: CGPoint) { souris = p }
    public func appuiA(_ p: CGPoint) { souris = p; appuiEnAttente = p }
    public func relache() { actif = nil }
    public func defiler(_ points: Double) { molette += points }
    /// La souris a quitté la fenêtre : plus rien n'est survolé.
    public func sourisPartie() { souris = CGPoint(x: -1000, y: -1000) }

    // MARK: - Le tour de dessin

    /// Dessine le cadre, puis le contenu que `corps` décrit commande par commande.
    public func dessiner(pinceau p: Pinceau, infobulle bulle: Infobulle,
                  largeurFenetre: Double, hauteurUtile: Double,
                  _ corps: (Panneau) -> Void) {
        guard ouvert else { appuiEnAttente = nil; molette = 0; return }
        let r = cadre(largeurFenetre: largeurFenetre, hauteurUtile: hauteurUtile)
        pinceau = p
        infobulle = bulle
        gauche = r.x
        haut = r.y
        bas = r.y + r.hauteur

        // ── Le fond, et pourquoi il est opaque ────────────────────────────────
        //
        // Sur le Mac, les commandes sont en verre et laissent passer l'image : c'est
        // ce qui rend acceptable de poser quelque chose sur un spectrogramme. Le
        // verre y est du flou, et le flou est ce qui efface le détail sans effacer
        // la couleur.
        //
        // Ici il n'y a pas de flou, et une simple transparence n'est pas du verre.
        // Essayé à 95 % : les noms d'accords se lisaient encore **à travers** le
        // panneau, cinq pour cent d'un texte clair sur un fond sombre suffisant à
        // le laisser paraître. Un panneau qu'on lit par-dessus un autre texte n'est
        // pas discret, il est sale.
        p.arrondi(r.x, r.y, r.largeur, r.hauteur, rayon: 8, Pinceau.gris(0.10, 1))
        p.arrondi(r.x, r.y, r.largeur, r.hauteur, rayon: 8, Pinceau.blanc(0.12),
                  epaisseur: 1)

        // Le défilement est borné avec la hauteur relevée à l'image précédente : la
        // hauteur de celle-ci n'est connue qu'une fois le contenu décrit, et un
        // panneau qui n'aurait pas encore été dessiné n'a rien à faire défiler.
        let course = max(hauteurDuContenu - r.hauteur, 0)
        defilement = min(max(defilement - molette, 0), course)
        molette = 0

        y = r.y + Self.marge - defilement
        let depart = y
        sections = 0
        p.decoupe(r.x, r.y, r.largeur, r.hauteur) {
            corps(self)
        }
        hauteurDuContenu = y - depart + Self.marge

        // La glissière, seulement s'il y a de quoi défiler. Un rail permanent dans
        // un panneau qui tient à l'écran est un ornement qui dit quelque chose de
        // faux.
        if course > 0 {
            let hauteurPouce = max(r.hauteur * r.hauteur / hauteurDuContenu, 30)
            let position = r.y + (r.hauteur - hauteurPouce) * (defilement / course)
            p.arrondi(r.x + r.largeur - 5, position, 3, hauteurPouce, rayon: 1.5,
                      Pinceau.blanc(0.22))
        }

        appuiEnAttente = nil
        pinceau = nil
        infobulle = nil
    }

    // MARK: - Les commandes

    /// Le titre d'une section, le filet qui la sépare de la précédente, et ce à quoi
    /// la section sert — qui se lit en la survolant.
    func titre(_ texte: String, aide: String) {
        guard let p = pinceau else { return }
        if sections > 0 {
            y += Self.ecart
            if visible(y, 1) {
                p.tracer(contenuGauche, y, gauche + Self.largeur - Self.marge, y,
                         Pinceau.blanc(0.09))
            }
            y += Self.ecart
        }
        sections += 1
        let yLigne = y
        y += 22
        guard visible(yLigne, 22) else { return }
        p.texte(texte, x: contenuGauche, y: yLigne + 8, largeur: contenuLargeur,
                taille: 12, Pinceau.blanc(0.92))
        survol(CGRect(x: contenuGauche, y: yLigne, width: contenuLargeur, height: 20),
               aide)
    }

    /// Une phrase que le panneau doit dire en clair : ce qui n'est pas installé, ce
    /// qui vient d'échouer, ce qui est en train de se calculer.
    ///
    /// Ce n'est pas une explication de réglage — celles-là sont toutes passées en
    /// infobulle. C'est ce qu'on doit lire **sans avoir à chercher où survoler**,
    /// parce qu'aucune commande n'en rend compte.
    func explication(_ texte: String) {
        guard let p = pinceau else { return }
        let hauteur = p.paragraphe(texte, x: contenuGauche, y: y, largeur: contenuLargeur,
                                   taille: 9.5, Pinceau.blanc(0.42),
                                   dessiner: visible(y, 60))
        y += hauteur + 8
    }

    /// Un curseur continu. Rend la nouvelle valeur quand elle vient de changer.
    ///
    /// L'intitulé sert d'identité : deux curseurs de même nom dans le même panneau
    /// se voleraient le glisser, ce qui ne s'est pas produit et ne peut pas se
    /// produire sans qu'on l'ait écrit exprès.
    @discardableResult
    func curseur(_ nom: String, _ valeur: Double, _ plage: ClosedRange<Double>,
                 texte affichage: String, aide: String,
                 actif utilisable: Bool = true) -> Double? {
        guard let p = pinceau else { return nil }
        let hauteurLigne = 31.0
        let yLigne = y
        y += hauteurLigne

        let opacite = utilisable ? 1.0 : 0.4
        if visible(yLigne, hauteurLigne) {
            p.texte(nom, x: contenuGauche, y: yLigne + 8, largeur: contenuLargeur - 60,
                    taille: 11, Pinceau.blanc(0.78 * opacite))
            p.texte(affichage, x: contenuGauche + contenuLargeur - 62, y: yLigne + 8,
                    largeur: 62, taille: 10, Pinceau.blanc(0.55 * opacite),
                    police: .chiffres, alignement: .droite)
        }

        let rail = (x: contenuGauche + 7, largeur: contenuLargeur - 14)
        let yRail = yLigne + 25
        let etendue = max(plage.upperBound - plage.lowerBound, 1e-9)
        var part = min(max((valeur - plage.lowerBound) / etendue, 0), 1)

        // Le rail est fin, le geste ne l'est pas : la zone sensible fait toute la
        // hauteur de la ligne. Viser un trait de trois points à la souris est ce qui
        // rend un curseur pénible, et c'est gratuit à corriger.
        let zone = CGRect(x: contenuGauche, y: yLigne + 14,
                          width: contenuLargeur, height: 20)
        var change: Double?
        if utilisable {
            if let appui = appuiEnAttente, zone.contains(appui) {
                actif = nom
                appuiEnAttente = nil
            }
            if actif == nom {
                part = min(max((souris.x - rail.x) / rail.largeur, 0), 1)
                let nouvelle = plage.lowerBound + part * etendue
                if abs(nouvelle - valeur) > 1e-9 { change = nouvelle }
            }
        }

        if visible(yLigne, hauteurLigne) {
            p.arrondi(rail.x, yRail - 1.5, rail.largeur, 3, rayon: 1.5,
                      Pinceau.blanc(0.16 * opacite))
            if part > 0 {
                p.arrondi(rail.x, yRail - 1.5, rail.largeur * part, 3, rayon: 1.5,
                          Self.accent(opacite))
            }
            let xPouce = rail.x + rail.largeur * part
            p.disque(xPouce, yRail, 7, Pinceau.gris(0.10, opacite))
            p.disque(xPouce, yRail, 6, Pinceau.blanc(0.88 * opacite))
            p.disque(xPouce, yRail, 3.2, Self.accent(opacite))
            // La bulle est proposée sur la ligne entière, intitulé compris : c'est
            // le nom du réglage qu'on survole quand on se demande ce qu'il fait, pas
            // son rail.
            survol(CGRect(x: contenuGauche, y: yLigne, width: contenuLargeur,
                          height: hauteurLigne), aide)
        }
        return change
    }

    /// Une bascule, à la manière de Windows 11 : une capsule et son pouce. Rend la
    /// nouvelle valeur au moment où l'on clique.
    @discardableResult
    func bascule(_ nom: String, _ valeur: Bool, aide: String,
                 actif utilisable: Bool = true) -> Bool? {
        guard let p = pinceau else { return nil }
        let hauteurLigne = 28.0
        let yLigne = y
        y += hauteurLigne

        let largeurCapsule = 38.0
        let hauteurCapsule = 20.0
        let xCapsule = contenuGauche + contenuLargeur - largeurCapsule
        let yCapsule = yLigne + 3
        let zone = CGRect(x: contenuGauche, y: yLigne, width: contenuLargeur,
                          height: hauteurLigne)
        let opacite = utilisable ? 1.0 : 0.4

        var change: Bool?
        if utilisable, let appui = appuiEnAttente, zone.contains(appui) {
            appuiEnAttente = nil
            change = !valeur
        }
        let montre = change ?? valeur

        if visible(yLigne, hauteurLigne) {
            p.texte(nom, x: contenuGauche, y: yLigne + hauteurLigne / 2,
                    largeur: contenuLargeur - largeurCapsule - 10, taille: 11,
                    Pinceau.blanc(0.78 * opacite))
            p.arrondi(xCapsule, yCapsule, largeurCapsule, hauteurCapsule,
                      rayon: hauteurCapsule / 2,
                      montre ? Self.accent(opacite) : Pinceau.blanc(0.10 * opacite))
            if !montre {
                p.arrondi(xCapsule, yCapsule, largeurCapsule, hauteurCapsule,
                          rayon: hauteurCapsule / 2, Pinceau.blanc(0.35 * opacite),
                          epaisseur: 1)
            }
            let xPouce = montre ? xCapsule + largeurCapsule - 10 : xCapsule + 10
            p.disque(xPouce, yCapsule + hauteurCapsule / 2, 6,
                     montre ? Pinceau.blanc(0.95) : Pinceau.blanc(0.7 * opacite))
            survol(zone, aide)
        }
        return change
    }

    /// Un choix court, en une rangée de segments : les temps par mesure, les bémols
    /// contre les dièses.
    @discardableResult
    func segments(_ nom: String?, _ options: [String], _ index: Int,
                  aide: String) -> Int? {
        guard let p = pinceau else { return nil }
        let yIntitule = y
        if let nom, visible(y, 18) {
            p.texte(nom, x: contenuGauche, y: y + 8, largeur: contenuLargeur,
                    taille: 11, Pinceau.blanc(0.78))
        }
        if nom != nil { y += 20 }

        let hauteurLigne = 26.0
        let yLigne = y
        y += hauteurLigne + 6
        let largeurSegment = contenuLargeur / Double(max(options.count, 1))
        var retenu: Int?
        if visible(yLigne, hauteurLigne) {
            p.arrondi(contenuGauche, yLigne, contenuLargeur, hauteurLigne, rayon: 5,
                      Pinceau.blanc(0.07))
            survol(CGRect(x: contenuGauche, y: yIntitule, width: contenuLargeur,
                          height: yLigne + hauteurLigne - yIntitule), aide)
        }
        for (i, option) in options.enumerated() {
            let x = contenuGauche + largeurSegment * Double(i)
            let zone = CGRect(x: x, y: yLigne, width: largeurSegment, height: hauteurLigne)
            if let appui = appuiEnAttente, zone.contains(appui) {
                appuiEnAttente = nil
                retenu = i
            }
            guard visible(yLigne, hauteurLigne) else { continue }
            let coche = i == (retenu ?? index)
            if coche {
                p.arrondi(x + 2, yLigne + 2, largeurSegment - 4, hauteurLigne - 4,
                          rayon: 4, Self.accent(1))
            }
            p.texte(option, x: x, y: yLigne + hauteurLigne / 2, largeur: largeurSegment,
                    taille: 10.5, Pinceau.blanc(coche ? 0.98 : 0.62),
                    alignement: .centre)
        }
        return retenu
    }

    /// Une rangée de boutons de largeur égale. Rend l'indice de celui qu'on vient de
    /// presser.
    ///
    /// `inactifs` grise ceux qui n'ont rien à faire — « Aux mesures » sans tempo
    /// relevé, « Effacer » sans boucle. Les cacher ferait sauter la rangée d'une
    /// image à l'autre, et l'on ne saurait plus que la commande existe.
    @discardableResult
    func boutons(_ noms: [String], aides: [String], inactifs: Set<Int> = []) -> Int? {
        guard let p = pinceau, !noms.isEmpty else { return nil }
        let hauteurLigne = 28.0
        let yLigne = y
        y += hauteurLigne + 6
        let ecart = 6.0
        let largeurBouton =
            (contenuLargeur - ecart * Double(noms.count - 1)) / Double(noms.count)
        var presse: Int?
        for (i, nom) in noms.enumerated() {
            let x = contenuGauche + (largeurBouton + ecart) * Double(i)
            let utilisable = !inactifs.contains(i)
            let zone = CGRect(x: x, y: yLigne, width: largeurBouton, height: hauteurLigne)
            if utilisable, let appui = appuiEnAttente, zone.contains(appui) {
                appuiEnAttente = nil
                presse = i
            }
            guard visible(yLigne, hauteurLigne) else { continue }
            bouton(p, zone, nom, utilisable: utilisable)
            if i < aides.count { survol(zone, aides[i]) }
        }
        return presse
    }

    /// Un élément d'une rangée — voir `rangee`.
    enum Piece {
        /// Rien, et pas même la place de rien.
        ///
        /// Une pièce qui ne paraît que dans certains cas — le signe qui prévient
        /// d'une estimation peu franche — laisse sa place plutôt que de disparaître
        /// du tableau : les indices que `rangee` rend ne bougent alors pas selon ce
        /// que le morceau se trouve être.
        case rien
        /// Un mot posé là : un intitulé, une unité.
        case mot(String)
        /// Une valeur, en chiffres à chasse fixe.
        case valeur(String)
        /// Un signe qui attire l'œil, et dont l'infobulle dit ce qu'il annonce.
        case alerte(String, aide: String)
        /// Un bouton, avec ce que son infobulle dit et s'il y a lieu de le presser.
        case bouton(String, aide: String, actif: Bool = true)
    }

    /// Une rangée : tout ce qui répond à une même question, sur une seule ligne.
    /// Rend l'indice de la pièce qu'on vient de presser.
    ///
    /// Les pièces sont posées de gauche à droite, chacune à sa largeur — au
    /// contraire de `boutons`, qui partage la largeur du panneau en parts égales.
    /// C'est ce qui permet de tenir le tempo entier sur une ligne : le chiffre, les
    /// deux flèches, la signature, le premier temps et de quoi relancer
    /// l'estimation. Sur une ligne parce que c'est **une** question — sur quelle
    /// grille ce morceau est-il écrit — et qu'on y répond d'un coup.
    @discardableResult
    func rangee(_ pieces: [Piece]) -> Int? {
        guard let p = pinceau else { return nil }
        let hauteurLigne = 30.0
        let hauteurBouton = 24.0
        let yLigne = y
        y += hauteurLigne
        let dessine = visible(yLigne, hauteurLigne)
        let milieu = yLigne + hauteurLigne / 2

        var x = contenuGauche
        var presse: Int?
        for (i, piece) in pieces.enumerated() {
            switch piece {
            case .rien:
                break

            case .mot(let texte):
                let l = p.largeur(texte, taille: 10.5)
                if dessine {
                    p.texte(texte, x: x, y: milieu, largeur: l + 2, taille: 10.5,
                            Pinceau.blanc(0.55))
                }
                x += l + 7

            case .valeur(let texte):
                let l = p.largeur(texte, taille: 11.5, police: .chiffres)
                if dessine {
                    p.texte(texte, x: x, y: milieu, largeur: l + 2, taille: 11.5,
                            Pinceau.blanc(0.92), police: .chiffres)
                }
                x += l + 7

            case .alerte(let signe, let aide):
                let l = p.largeur(signe, taille: 12)
                if dessine {
                    p.texte(signe, x: x, y: milieu, largeur: l + 2, taille: 12,
                            Pinceau.rvb(1, 0.68, 0.2, 1))
                    survol(CGRect(x: x - 3, y: yLigne, width: l + 8,
                                  height: hauteurLigne), aide)
                }
                x += l + 7

            case .bouton(let nom, let aide, let utilisable):
                // Quatorze points d'air autour de l'intitulé, contre dix-huit dans
                // une rangée de largeurs égales : le tempo tient sur une ligne à ce
                // prix-là, et une ligne est ce qui fait qu'on y répond d'un coup.
                let largeur = max(p.largeur(nom, taille: 10.5) + 14, hauteurBouton)
                let zone = CGRect(x: x, y: milieu - hauteurBouton / 2,
                                  width: largeur, height: hauteurBouton)
                if utilisable, let appui = appuiEnAttente, zone.contains(appui) {
                    appuiEnAttente = nil
                    presse = i
                }
                if dessine {
                    bouton(p, zone, nom, utilisable: utilisable)
                    survol(zone, aide)
                }
                x += largeur + 5
            }
        }
        return presse
    }

    /// Une ligne de texte simple — un relevé, un état, ce qu'aucune commande ne dit.
    func note(_ texte: String, valeur: String? = nil) {
        guard let p = pinceau else { return }
        let hauteurLigne = 22.0
        let yLigne = y
        y += hauteurLigne
        guard visible(yLigne, hauteurLigne) else { return }
        p.texte(texte, x: contenuGauche, y: yLigne + hauteurLigne / 2,
                largeur: contenuLargeur - 90, taille: 10.5, Pinceau.blanc(0.6))
        if let valeur {
            p.texte(valeur, x: contenuGauche + contenuLargeur - 90,
                    y: yLigne + hauteurLigne / 2, largeur: 90, taille: 10.5,
                    Pinceau.blanc(0.85), police: .chiffres, alignement: .droite)
        }
    }

    /// Un peu d'air entre deux groupes qui n'ont pas mérité un titre chacun.
    func air(_ points: Double = 6) { y += points }

    // MARK: - Le détail

    /// Le bleu de l'application : celui de la barre d'avancement, et celui que
    /// Windows emploie pour l'accent par défaut.
    private static func accent(_ opacite: Double) -> UInt32 {
        Pinceau.rvb(0.35, 0.65, 1.0, opacite)
    }

    /// Le fond, le liseré et l'intitulé d'un bouton — les mêmes qu'il soit dans une
    /// rangée de largeurs égales ou dans une rangée libre.
    private func bouton(_ p: Pinceau, _ zone: CGRect, _ nom: String,
                        utilisable: Bool) {
        let survole = utilisable && zone.contains(souris)
        let opacite = utilisable ? 1.0 : 0.35
        p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: 5,
                  Pinceau.blanc((survole ? 0.16 : 0.09) * opacite))
        p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: 5,
                  Pinceau.blanc(0.14 * opacite), epaisseur: 1)
        p.texte(nom, x: zone.minX, y: zone.midY, largeur: zone.width, taille: 10.5,
                Pinceau.blanc(0.85 * opacite), alignement: .centre)
    }

    /// Propose l'infobulle de cette commande, si la souris est dessus.
    ///
    /// Le rectangle est celui de la commande, et non celui du curseur : c'est ce que
    /// la bulle doit éviter de recouvrir — on survole un réglage pour lire ce qu'il
    /// fait, pas pour le perdre de vue.
    private func survol(_ zone: CGRect, _ aide: String) {
        guard !aide.isEmpty, zone.contains(souris), souris.y >= haut, souris.y <= bas
        else { return }
        infobulle?.proposer(aide, zone)
    }

    /// Une commande hors du cadre est décrite mais pas dessinée : la découpe la
    /// couperait de toute façon, et un panneau de mille points de haut passerait son
    /// temps à mesurer du texte qu'on ne voit pas.
    private func visible(_ yLigne: Double, _ hauteur: Double) -> Bool {
        yLigne + hauteur >= haut && yLigne <= bas
    }
}
