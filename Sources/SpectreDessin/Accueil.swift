import Foundation
import SpectreCore
import SpectreModele
import SpectreTextes
import SpectreToile

// Ce que la fenêtre montre avant qu'un morceau soit ouvert.
//
// ─────────────────────────────────────────────────────────────────────────────
// TROIS DESSINS, UN SEUL ÉTAT
//
// La liste des morceaux déjà travaillés, le diaporama du premier lancement, et la
// modale de mise à jour. Tous trois lisent `modele.lancement` — quand le diaporama
// revient, ce que la corbeille emporte, dans quel ordre les couches se présentent
// est écrit là-bas, dans `SpectreModele/Lancement.swift`, et nulle part ici.
//
// Le jumeau macOS est `Sources/Spectre/Accueil.swift`, en SwiftUI. Les deux dessins
// sont écrits deux fois ; **les textes sortent du même catalogue et l'état du même
// objet**, ce qui est la seule chose qui compte : le jour où la corbeille emportera
// autre chose, elle l'emportera des trois côtés.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUI A REMPLACÉ L'AVIS
//
// Ce fichier a pris la place de `Avis.swift`, qui portait la seule phrase du premier
// lancement — l'envoi des rapports de panne. Elle n'a pas disparu : elle est la
// dernière ligne de la seconde diapositive, dans la teinte qui appelle l'œil, et
// elle ne s'écrit que si quelque chose part vraiment. On informe, on ne demande pas,
// et ce qui **ne part pas** est écrit aussi gros que ce qui part. Voir
// `docs/RAPPORTS.md`.
// ─────────────────────────────────────────────────────────────────────────────

/// La page de lancement, le diaporama et la mise à jour, dessinés.
///
/// Une classe, comme le panneau et la colonne : elle tient ce que la souris a fait
/// depuis l'image d'avant, et rien d'autre. Tout le reste se relit dans le modèle à
/// chaque image.
public final class Accueil<Lecteur: LecteurAudio> {
    private let modele: AppModel<Lecteur>

    public init(modele: AppModel<Lecteur>) { self.modele = modele }

    // MARK: - Les mesures

    /// Assez large pour qu'un titre de morceau tienne sans être coupé, assez étroit
    /// pour que l'œil retrouve le début de la ligne suivante.
    private static var largeurDeLaListe: Double { 420 }
    private static var hauteurDUneLigne: Double { 38 }
    /// Sept lignes, puis la liste s'arrête : douze morceaux dans une fenêtre courte
    /// pousseraient le bouton d'ouverture hors de l'écran, c'est-à-dire la seule
    /// chose à faire quand la liste ne contient pas ce qu'on cherche.
    private static var lignesVisibles: Int { 7 }
    private static var largeurDuCarton: Double { 620 }
    private static var marge: Double { 26 }

    /// Le bleu des boutons principaux — celui de la version macOS, où c'est la
    /// teinte d'accent du système. Les deux fenêtres doivent se ressembler ; elles
    /// ne se ressembleraient pas si l'une avait un bouton gris là où l'autre en a un
    /// bleu.
    private static var bleu: UInt32 { Pinceau.rvb(0.04, 0.48, 1) }

    // MARK: - Ce que la souris a fait depuis la dernière image

    private var souris = CGPoint(x: -1000, y: -1000)
    private var appuiEnAttente: CGPoint?
    /// Vrai le temps que la page se dessine sous une couche : elle se voit encore au
    /// travers du voile, mais elle ne répond plus. Voir `dessinerLaPage`.
    private var sourde = false

    public func sourisA(_ p: CGPoint) { souris = p }
    public func appuiA(_ p: CGPoint) { souris = p; appuiEnAttente = p }
    public func sourisPartie() { souris = CGPoint(x: -1000, y: -1000) }

    // MARK: - Ce que la fenêtre demande

    /// Une couche recouvre-t-elle tout ? Les gestes s'arrêtent alors ici : tant
    /// qu'elle est là, il n'y a rien d'autre à lire ni à cliquer dans la fenêtre.
    public var couvreLaFenetre: Bool {
        modele.lancement.diaporama || modele.lancement.miseAJourAMontrer
    }

    /// La page des morceaux est-elle à montrer ? Elle s'efface dès que l'analyse
    /// commence : deux choses au milieu de la fenêtre, dont l'une dit d'attendre, se
    /// gênent.
    public var pageAMontrer: Bool {
        modele.spectrogram.columnCount == 0 && modele.progress == nil
    }

    /// Une touche pendant qu'une couche est là. Rend `true` quand elle a été prise.
    ///
    /// N'importe quelle touche fait avancer le diaporama, et Échap le referme : sans
    /// cela, l'espace qu'on presse pour le chasser lancerait la lecture d'un morceau
    /// qu'on n'a pas encore ouvert.
    public func touche(_ touche: ToucheDeSpectre) -> Bool {
        let lancement = modele.lancement
        if lancement.diaporama {
            if touche == .echappement { lancement.fermerLeDiaporama() } else { lancement.suivant() }
            return true
        }
        if lancement.miseAJourAMontrer {
            // Échap referme pour cette séance seulement : une touche pressée au
            // hasard ne doit pas écarter une version pour toujours.
            if touche == .echappement { lancement.fermerLaMiseAJour() }
            else { lancement.telecharger() }
            return true
        }
        return false
    }

    // MARK: - La page des morceaux

    /// La liste des morceaux déjà ouverts, et de quoi en reprendre un.
    ///
    /// Elle remplace la phrase « Ouvrir un fichier » qui tenait cette place, et
    /// l'ouverture automatique du dernier morceau qui la recouvrait aussitôt. La
    /// première ligne *est* le dernier morceau : ce qui se faisait tout seul se fait
    /// d'un clic, et les neuf autres fois on choisit.
    public func dessinerLaPage(_ p: Pinceau, largeur: Double, hauteur: Double) {
        // La page est dessinée **avant** les couches, dans la même image. Tant qu'une
        // couche recouvre la fenêtre, l'appui est à elle : le lire ici le lui volerait,
        // et « Suivant » comme « Passer » resteraient sans effet — c'est le défaut que
        // Windows et Linux ont porté, le Mac y échappant parce que là, c'est SwiftUI
        // qui range les clics.
        //
        // Et rien n'est jeté ici : `dessinerLesCouches` est appelée à chaque image,
        // après tout le reste, et c'est **le seul endroit** où l'appui de l'image
        // expire. Un second endroit qui jetterait, c'est très exactement le défaut
        // qu'on vient de réparer.
        sourde = couvreLaFenetre
        defer { sourde = false }
        let morceaux = modele.lancement.morceaux
        let lignes = min(morceaux.count, Self.lignesVisibles)
        let hauteurDeLaListe = morceaux.isEmpty ? 24
                             : Double(lignes) * Self.hauteurDUneLigne
        let total = 24 + 14 + hauteurDeLaListe + 26 + 34 + 10 + 16

        let l = min(Self.largeurDeLaListe, largeur - 60)
        let x = (largeur - l) / 2
        var y = (hauteur - total) / 2

        p.texte(T(.lancementReprendre), x: x + 12, y: y + 12, largeur: l, taille: 14,
                Pinceau.blanc(0.85))
        y += 24 + 14

        if morceaux.isEmpty {
            p.texte(T(.lancementAucunMorceau), x: x + 12, y: y + 12, largeur: l,
                    taille: 11, Pinceau.blanc(0.5))
        }
        for morceau in morceaux.prefix(lignes) {
            ligne(p, morceau, x: x, y: y, largeur: l)
            y += Self.hauteurDUneLigne
        }
        y += hauteurDeLaListe - Double(lignes) * Self.hauteurDUneLigne + 26

        // Le bouton d'ouverture, centré sous la liste : c'est la seule chose à faire
        // quand elle ne contient pas ce qu'on cherche.
        let largeurDuBouton = 190.0
        let zone = CGRect(x: x + (l - largeurDuBouton) / 2, y: y,
                          width: largeurDuBouton, height: 34)
        if presse(zone) { modele.openPanel() }
        p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: 8,
                  zone.contains(souris) ? Pinceau.rvb(0.16, 0.56, 1) : Self.bleu)
        p.texte(T(.lancementOuvrirUnFichier), x: zone.minX, y: zone.midY,
                largeur: zone.width, taille: 11.5, Pinceau.blanc(0.95),
                alignement: .centre)
        y += 34 + 10
        p.texte(T(.winFriseOuvrir), x: x, y: y + 8, largeur: l, taille: 10,
                Pinceau.blanc(0.45), alignement: .centre)
    }

    private func ligne(_ p: Pinceau, _ morceau: MorceauRecent,
                       x: Double, y: Double, largeur: Double) {
        let zone = CGRect(x: x, y: y, width: largeur, height: Self.hauteurDUneLigne - 2)
        // La corbeille n'apparaît qu'au survol : une corbeille par ligne en
        // permanence ferait d'une liste de douze morceaux une liste de douze boutons
        // de suppression.
        let survolee = zone.contains(souris)
        let corbeille = CGRect(x: zone.maxX - 34, y: zone.minY + 8, width: 22, height: 22)

        if let appui = appuiPris(dans: zone) {
            // La corbeille d'abord : elle est **dans** la ligne, et un clic dessus
            // qui rouvrirait le morceau serait le contraire de ce qu'on demandait.
            if corbeille.contains(appui) {
                modele.lancement.oublier(morceau.url)
            } else {
                modele.open(morceau.url)
            }
            return
        }

        if survolee {
            p.arrondi(zone.minX, zone.minY, zone.width, zone.height, rayon: 7,
                      Pinceau.blanc(0.10))
        }
        // Le nom seul quand rien n'est séparé, le nom relevé d'une ligne quand la
        // seconde a quelque chose à dire : centrer les deux ensemble, puis n'en
        // écrire qu'une, ferait sauter le nom d'une ligne à l'autre.
        let milieu = zone.midY
        if morceau.separe {
            p.texte(morceau.nom, x: zone.minX + 12, y: milieu - 6,
                    largeur: zone.width - 50, taille: 12, Pinceau.blanc(0.9))
            p.texte(T(.lancementSepare), x: zone.minX + 12, y: milieu + 8,
                    largeur: zone.width - 50, taille: 9.5, Pinceau.blanc(0.4))
        } else {
            p.texte(morceau.nom, x: zone.minX + 12, y: milieu,
                    largeur: zone.width - 50, taille: 12, Pinceau.blanc(0.9))
        }
        if survolee {
            Icone.corbeille.dessiner(p, cx: corbeille.midX, cy: corbeille.midY,
                                     Pinceau.blanc(corbeille.contains(souris) ? 0.95 : 0.55))
        }
    }

    // MARK: - Les couches

    /// Le diaporama puis la mise à jour, par-dessus tout le reste.
    ///
    /// L'ordre n'est pas dans ces deux lignes : `Lancement` ne rend la seconde
    /// visible que lorsque la première est refermée. Ici, on empile.
    public func dessinerLesCouches(_ p: Pinceau, largeurFenetre: Double,
                                   hauteurFenetre: Double) {
        // **Le seul endroit où l'appui de l'image expire**, et il vient en dernier :
        // ce qui n'a touché aucun bouton est jeté ici. Un appui gardé d'une image à
        // l'autre agirait à retardement, sur la page ou la couche qui se trouve là à
        // ce moment-là — et ce ne serait pas celle qu'on visait.
        defer { appuiEnAttente = nil }
        if modele.lancement.diaporama {
            diaporama(p, largeurFenetre: largeurFenetre, hauteurFenetre: hauteurFenetre)
        } else if modele.lancement.miseAJourAMontrer {
            miseAJour(p, largeurFenetre: largeurFenetre, hauteurFenetre: hauteurFenetre)
        }
    }

    /// La hauteur du cadre qui reçoit la capture, par diapositive.
    ///
    /// Deux nombres écrits en clair, parce que les deux captures n'ont pas la même
    /// forme : la première est une fenêtre entière, la seconde une bande de vingt
    /// points de haut. Un cadre unique laisserait la seconde flotter au milieu d'un
    /// grand vide. Le pont, lui, centre l'image à ses proportions dans ce qu'on lui
    /// donne — il ne l'étire jamais.
    ///
    /// Une propriété calculée, et non stockée : un type générique n'accepte pas de
    /// propriété statique stockée. La contrainte tombe juste — deux nombres écrits
    /// dans le corps d'un `var` ne coûtent rien de plus qu'un tableau constant.
    private static var hauteursDesCaptures: [Double] { [250, 110] }

    private func diaporama(_ p: Pinceau, largeurFenetre: Double, hauteurFenetre: Double) {
        let lancement = modele.lancement
        let rang = lancement.diapositive
        let largeur = min(Self.largeurDuCarton, largeurFenetre - 60)
        let interieur = largeur - 2 * Self.marge

        let titre = rang == 0 ? T(.bienvenueTitreBoucle) : T(.bienvenueTitrePistes)
        let corps = rang == 0 ? T(.bienvenueCorpsBoucle) : T(.bienvenueCorpsPistes)
        // La seconde phrase de la première diapositive parle du tempo ; celle de la
        // seconde annonce l'envoi des rapports — et ne s'écrit que si quelque chose
        // part vraiment.
        let second = rang == 0 ? T(.bienvenueTempoBoucle)
                   : (lancement.rapportsAAnnoncer ? T(.bienvenueRapports) : "")

        // Mesuré avant d'être dessiné : la hauteur du carton dépend du nombre de
        // lignes, qui dépend de la langue. En allemand le même paragraphe en prend
        // une de plus, et un carton dont la hauteur serait écrite en dur couperait
        // sa dernière phrase — dans une langue que l'auteur ne relit pas.
        let hauteurCorps = p.paragraphe(corps, x: 0, y: 0, largeur: interieur,
                                        taille: 11.5, dessiner: false)
        let hauteurSecond = second.isEmpty ? 0
            : p.paragraphe(second, x: 0, y: 0, largeur: interieur, taille: 11.5,
                           dessiner: false) + 12
        let hauteurCapture = Self.hauteursDesCaptures[min(rang, Self.hauteursDesCaptures.count - 1)]
        let hauteur = hauteurCapture + Self.marge + 22 + 12 + hauteurCorps
                    + hauteurSecond + Self.marge + 34 + Self.marge

        let x = (largeurFenetre - largeur) / 2
        let y = (hauteurFenetre - hauteur) / 2

        p.remplir(0, 0, largeurFenetre, hauteurFenetre, Pinceau.noir(0.72))
        p.arrondi(x, y, largeur, hauteur, rayon: 16, Pinceau.gris(0.12, 0.99))
        p.arrondi(x, y, largeur, hauteur, rayon: 16, Pinceau.blanc(0.14), epaisseur: 1)

        // Un fond derrière la capture, qui remplit la largeur du carton : sans lui,
        // la bande de vingt points de la seconde diapositive flotterait au milieu du
        // carton comme une erreur.
        p.remplir(x, y, largeur, hauteurCapture, Pinceau.noir(0.45))
        if let capture = Ressources.capture(rang) {
            p.image(capture.path, x: x + 10, y: y + 10,
                    largeur: largeur - 20, hauteur: hauteurCapture - 20)
        }

        var curseur = y + hauteurCapture + Self.marge
        p.texte(titre, x: x + Self.marge, y: curseur + 9, largeur: interieur,
                taille: 14, Pinceau.blanc(0.95))
        curseur += 22 + 12
        curseur += p.paragraphe(corps, x: x + Self.marge, y: curseur,
                                largeur: interieur, taille: 11.5, Pinceau.blanc(0.78))
        if !second.isEmpty {
            curseur += 12
            // La même taille que ce qui précède, et pour la phrase des rapports une
            // teinte qui appelle l'œil : ce qu'on annonce d'un envoi automatique
            // n'est pas une note de bas de page.
            let couleur = rang == 0 ? Pinceau.blanc(0.78)
                                    : Pinceau.rvb(0.62, 0.86, 0.70, 0.95)
            curseur += p.paragraphe(second, x: x + Self.marge, y: curseur,
                                    largeur: interieur, taille: 11.5, couleur)
        }

        pied(p, x: x, y: y + hauteur - Self.marge - 34, largeur: largeur)
    }

    /// « Passer » à gauche, les points au milieu, « Suivant » à droite.
    private func pied(_ p: Pinceau, x: Double, y: Double, largeur: Double) {
        let lancement = modele.lancement

        let passer = CGRect(x: x + Self.marge, y: y, width: 70, height: 34)
        if presse(passer) { lancement.fermerLeDiaporama(); return }
        p.texte(T(.bienvenuePasser), x: passer.minX, y: passer.midY,
                largeur: passer.width, taille: 11.5,
                Pinceau.blanc(passer.contains(souris) ? 0.8 : 0.5))

        // Deux points, pour dire qu'il y a une suite et où l'on en est : un bouton
        // « Suivant » seul ne dit pas combien il en reste.
        let ecart = 12.0
        let debut = x + largeur / 2 - ecart * Double(Lancement.diapositives - 1) / 2
        for rang in 0..<Lancement.diapositives {
            p.disque(debut + ecart * Double(rang), y + 17, 3,
                     Pinceau.blanc(rang == lancement.diapositive ? 0.85 : 0.25))
        }

        let nom = lancement.derniereDiapositive ? T(.bienvenueCommencer)
                                                : T(.bienvenueSuivant)
        let largeurDuBouton = max(110.0, p.largeur(nom, taille: 11.5) + 40)
        let suivant = CGRect(x: x + largeur - Self.marge - largeurDuBouton, y: y,
                             width: largeurDuBouton, height: 34)
        if presse(suivant) { lancement.suivant(); return }
        p.arrondi(suivant.minX, suivant.minY, suivant.width, suivant.height, rayon: 8,
                  suivant.contains(souris) ? Pinceau.rvb(0.16, 0.56, 1) : Self.bleu)
        p.texte(nom, x: suivant.minX, y: suivant.midY, largeur: suivant.width,
                taille: 11.5, Pinceau.blanc(0.95), alignement: .centre)
    }

    /// « Spectre 0.6 est disponible ». Un numéro, deux boutons, et rien d'autre.
    ///
    /// Elle ne télécharge rien et n'installe rien : « Télécharger » ouvre la page des
    /// versions dans le navigateur. Voir `SpectreCore/MiseAJour.swift`, qui dit
    /// pourquoi l'application demande et pourquoi elle ne fait que demander.
    private func miseAJour(_ p: Pinceau, largeurFenetre: Double, hauteurFenetre: Double) {
        let lancement = modele.lancement
        guard let livraison = lancement.livraison else { return }

        // Les deux boutons sont mesurés avant que le carton ait une largeur : en
        // allemand « Diese Version überspringen » prend le double de « Später », et
        // une largeur écrite en dur le ferait déborder dans une langue que l'auteur
        // ne relit pas.
        let largeurIgnorer = max(110.0, p.largeur(T(.majIgnorer), taille: 11.5) + 32)
        let largeurTelecharger = max(130.0, p.largeur(T(.majTelecharger), taille: 11.5) + 32)
        let largeur = min(max(440, 2 * Self.marge + largeurIgnorer + 10 + largeurTelecharger),
                          largeurFenetre - 60)
        let interieur = largeur - 2 * Self.marge

        let corps = T(.majCorps, lancement.versionCourante)
        let hauteurCorps = p.paragraphe(corps, x: 0, y: 0, largeur: interieur,
                                        taille: 11.5, dessiner: false)
        let hauteur = Self.marge + 22 + 12 + hauteurCorps + Self.marge + 34 + Self.marge
        let x = (largeurFenetre - largeur) / 2
        let y = (hauteurFenetre - hauteur) / 2

        p.remplir(0, 0, largeurFenetre, hauteurFenetre, Pinceau.noir(0.62))
        p.arrondi(x, y, largeur, hauteur, rayon: 16, Pinceau.gris(0.12, 0.99))
        p.arrondi(x, y, largeur, hauteur, rayon: 16, Pinceau.blanc(0.14), epaisseur: 1)

        var curseur = y + Self.marge
        p.texte(T(.majTitre, livraison.version), x: x + Self.marge, y: curseur + 9,
                largeur: interieur, taille: 14, Pinceau.blanc(0.95))
        curseur += 22 + 12
        p.paragraphe(corps, x: x + Self.marge, y: curseur, largeur: interieur,
                     taille: 11.5, Pinceau.blanc(0.72))

        let bas = y + hauteur - Self.marge - 34
        let telecharger = CGRect(x: x + largeur - Self.marge - largeurTelecharger, y: bas,
                                 width: largeurTelecharger, height: 34)
        let ignorer = CGRect(x: telecharger.minX - 10 - largeurIgnorer, y: bas,
                             width: largeurIgnorer, height: 34)

        if presse(ignorer) { lancement.ignorerCetteVersion(); return }
        if presse(telecharger) { lancement.telecharger(); return }

        p.arrondi(ignorer.minX, ignorer.minY, ignorer.width, ignorer.height,
                  rayon: 8, Pinceau.blanc(ignorer.contains(souris) ? 0.16 : 0.09))
        p.texte(T(.majIgnorer), x: ignorer.minX, y: ignorer.midY,
                largeur: ignorer.width, taille: 11.5, Pinceau.blanc(0.85),
                alignement: .centre)

        p.arrondi(telecharger.minX, telecharger.minY, telecharger.width,
                  telecharger.height, rayon: 8,
                  telecharger.contains(souris) ? Pinceau.rvb(0.16, 0.56, 1) : Self.bleu)
        p.texte(T(.majTelecharger), x: telecharger.minX, y: telecharger.midY,
                largeur: telecharger.width, taille: 11.5, Pinceau.blanc(0.95),
                alignement: .centre)
    }

    /// Ce rectangle vient-il d'être cliqué ? Consomme l'appui, comme le panneau.
    private func presse(_ zone: CGRect) -> Bool { appuiPris(dans: zone) != nil }

    /// L'appui de cette image, s'il tombe là. Le consomme.
    ///
    /// Le seul chemin par lequel la page et les couches lisent un clic — et donc le
    /// seul endroit où `sourde` a besoin d'être regardé.
    private func appuiPris(dans zone: CGRect) -> CGPoint? {
        guard !sourde, let appui = appuiEnAttente, zone.contains(appui) else { return nil }
        appuiEnAttente = nil
        return appui
    }
}
