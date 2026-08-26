import CSDL
import Foundation
import SpectreCore
import SpectreDessin
import SpectreLin
import SpectreModele
import SpectreSon
import SpectreTextes
import SpectreToile
import SpectreSeparation
import SpectreSocle

// Spectre sous Linux — la fenêtre.
//
//     SpectreLinux morceau.wav                        ouvre la fenêtre
//     SpectreLinux morceau.wav --photo image.ppm      ouvre, photographie, et sort
//     SpectreLinux morceau.wav --taille 1700x343      la taille de l'image
//     SpectreLinux morceau.wav --gris                 sans la palette des notes
//     SpectreLinux morceau.wav --sans-habillage       ni réglette, ni batterie, ni barre
//     SpectreLinux morceau.wav --reglages             le panneau ouvert dès le départ
//     SpectreLinux morceau.wav --fluidite 5           défile 5 s et chiffre la fluidité
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUE CE FICHIER EST, ET CE QU'IL N'EST PAS ENCORE
//
// L'application est assemblée ici, et nulle part ailleurs : le comportement vit
// dans `SpectreModele`, le dessin dans `SpectreDessin`, les pièces de Linux dans
// `SpectreLin`, et ce fichier ne fait que les brancher les unes aux autres, puis
// tourner.
//
// Ce qui manque encore est dit dans `SpectreLin/Plateforme.swift`, étape par étape.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Le modèle, muni de ce que Linux lui fournit

/// Le `typealias` fait que tout ce qui écrit `AppModel` continue de l'écrire. Le
/// modèle est générique sur son lecteur — parce que l'interface observe
/// `model.player.speed` et qu'un protocole existentiel romprait ce suivi — mais rien
/// d'autre n'a de raison de porter ce détail.
typealias AppModel = SpectreModele.AppModel<LecteurSurLePont>

// Et le même rebouclage pour ce qui dessine. Ces quatre types sont partagés avec
// Windows et portent donc le lecteur en paramètre ; les rattacher ici une fois fait
// que pas un appel de ce fichier ne montre la généricité.
typealias Frise = SpectreDessin.Frise<LecteurSurLePont>
typealias Batterie = SpectreDessin.Batterie<LecteurSurLePont>
typealias Barre = SpectreDessin.Barre<LecteurSurLePont>
typealias Commandes = SpectreDessin.Commandes<LecteurSurLePont>

extension SpectreModele.AppModel where Lecteur == LecteurSurLePont {
    /// L'assemblage Linux : à chaque protocole du modèle, sa mise en œuvre.
    convenience init() {
        self.init(lecteur: LecteurSurLePont(),
                  décodeur: DecodeurSurLePont(),
                  sinusoide: SinusoideSurLePont(),
                  pistes: RangementSurLePont(),
                  dialogue: DialogueLinux(),
                  récentsDuSystème: RecentsLinux(),
                  préférences: PreferencesLinux.partagees)
    }
}

// MARK: - Le journal

// Avant tout le reste : ce qu'on cherche est toujours ce qui s'est dit avant que
// l'application ne se taise. Lancée depuis un terminal, elle continue de parler à
// celui-ci ; lancée depuis le bureau — ce que fait un AppImage double-cliqué — sa
// sortie d'erreur va dans le journal du rangement. Voir `docs/RAPPORTS.md`.
Journal.ouvrir()

// MARK: - Les arguments

let arguments = Array(CommandLine.arguments.dropFirst())
func valeur(_ nom: String) -> String? {
    guard let i = arguments.firstIndex(of: nom), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let positionnels = arguments.enumerated().filter { i, mot in
    !mot.hasPrefix("--") && (i == 0 || !arguments[i - 1].hasPrefix("--"))
}.map(\.element)

guard let premier = positionnels.first else {
    Journal.erreur("usage : SpectreLinux morceau.wav [--photo image.ppm]")
    exit(2)
}
let entree = URL(fileURLWithPath: premier)
let photo = valeur("--photo")

/// `--taille LARGEURxHAUTEUR`, la même option que `SpectreCLI` et que la version
/// Windows : c'est ce qui permet de demander la même image aux trois chemins et de
/// les confronter par `ImageCheck`.
let tailleVoulue: (largeur: Int32, hauteur: Int32)? = valeur("--taille").flatMap {
    let morceaux = $0.lowercased().split(separator: "x")
    guard morceaux.count == 2, let l = Int32(morceaux[0]), let h = Int32(morceaux[1]),
          l > 0, h > 0 else { return nil }
    return (l, h)
}

/// Faux avec `--sans-habillage` : ni réglette, ni grille, ni batterie, ni barre.
///
/// Ce n'est pas un mode d'usage, c'est un instrument. La surimpression couvre une
/// partie de l'image, si bien qu'une photographie habillée ne se compare plus au
/// rendu du processeur : `ImageCheck` trouverait un désaccord partout où passe un
/// trait de grille.
let habille = !arguments.contains("--sans-habillage")

// MARK: - La fenêtre

guard SDL_Init(SDL_INIT_VIDEO) else {
    Journal.erreur("SDL : \(String(cString: SDL_GetError()))")
    exit(1)
}
defer { SDL_Quit() }

// Le contexte est créé par le pont, pas ici — voir l'en-tête de `gl.c` — mais les
// attributs doivent être posés **avant** la fenêtre, et c'est nous qui la créons.
SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, Int32(SDL_GL_CONTEXT_PROFILE_CORE))

// `HIGH_PIXEL_DENSITY` : sans lui, SDL rend une fenêtre en points et le
// spectrogramme sortirait flou sur un écran dense — ce qui se remarque immédiatement
// sur les raies.
let drapeaux = SpectreFenetreOpenGL | SpectreFenetreRedimensionnable | SpectreFenetreDense
guard let fenetre = SDL_CreateWindow(entree.lastPathComponent,
                                     tailleVoulue?.largeur ?? 1200,
                                     tailleVoulue?.hauteur ?? 700, drapeaux) else {
    Journal.erreur("SDL a refusé d'ouvrir une fenêtre : \(String(cString: SDL_GetError()))")
    exit(1)
}
defer { SDL_DestroyWindow(fenetre) }

guard let rendu = RenduGL(fenetreSDL: UnsafeMutableRawPointer(fenetre)) else {
    Journal.erreur("OpenGL 3.3 n'a pas démarré : pas de carte graphique utilisable, "
                   + "ou un pilote trop ancien.")
    exit(1)
}
Journal.note("Carte : \(rendu.nomDeLaCarte)")
// La carte part avec les rapports de panne : la moitié de ce qui casse chez les
// autres casse à cause d'un pilote, et c'est le nom du pilote qui permet de dire
// « ceux-là, et eux seuls ». Elle n'identifie personne.
Rapports.carte(rendu.nomDeLaCarte)

// La surimpression n'est pas indispensable au spectrogramme : si Cairo manque,
// l'image reste et l'on perd la réglette. Mieux vaut une application amputée qu'une
// application qui refuse de s'ouvrir.
let avecSurimpression = habille && rendu.preparerLaSurimpression()

// MARK: - Ce qu'on montre

// La langue avant tout le reste : ce qui s'affiche est traduit, et le catalogue doit
// être posé avant que la première image soit dessinée.
Textes.demarrer(choix: nil, notes: nil,
                etiquettesDuSysteme: PreferencesLinux.languesDuSysteme)

let modele = AppModel()
modele.renderer = rendu
rendu.origineDesTeintes = PreferencesLinux.partagees.hueOrigin
modele.open(entree)

let panneau = Panneau()
if arguments.contains("--reglages") { panneau.ouvert = true }
/// Ce qui ne se replie jamais : les quatre pistes et la porte des réglages.
let flottant = Flottant()
/// La phrase du premier lancement, tant que personne ne l'a lue.
let avis = Avis()
/// Ce que dit la commande qu'on survole. Partagée par le panneau et la colonne : il
/// n'y a qu'une souris, donc qu'une bulle à l'écran.
let infobulle = Infobulle()
let commandes = Commandes(modele: modele, preferences: PreferencesLinux.partagees)

if arguments.contains("--gris") { modele.display.colorMap = .gray }

/// Le rapport entre pixels et points, tel que le compositeur le donne.
///
/// Tout ce qui se mesure dans le modèle — la position d'une raie, la largeur d'une
/// colonne — se compte en **points** ; le nuanceur, lui, travaille en pixels. C'est
/// le seul endroit où les deux se rencontrent.
func echelleDeLaFenetre() -> Double {
    Double(SDL_GetWindowPixelDensity(fenetre))
}

func taillePoints() -> (largeur: Double, hauteur: Double) {
    var l: Int32 = 0, h: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &l, &h)
    let echelle = echelleDeLaFenetre()
    return (Double(l) / echelle, Double(h) / echelle)
}

/// Hauteur de la zone du spectrogramme, en points : la fenêtre moins la ligne de
/// batterie et la barre d'état.
///
/// C'est **cette hauteur-là** que le modèle reçoit, et non celle de la fenêtre : tout
/// ce qu'il calcule — la bande passante du filtre, l'aimantation, le contraste
/// automatique — porte sur ce qu'on voit du spectre, pas sur ce que la fenêtre mesure.
func hauteurDeLImage(_ hauteurTotale: Double) -> Double {
    guard habille else { return hauteurTotale }
    return max(hauteurTotale - hauteurDeLaBatterie - hauteurDeLaBarre, 60)
}

/// Le nuanceur raisonne en colonnes : la conversion se fait ici, une fois.
func colonne(deLInstant t: Double) -> Double? {
    let matrice = modele.spectrogram
    guard matrice.columnCount > 0, matrice.secondsPerColumn > 0 else { return nil }
    return matrice.column(atTime: t)
}

// MARK: - Une image

func uneImage() {
    var l: Int32 = 0, h: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &l, &h)
    rendu.redimensionner(largeur: Int(l), hauteur: Int(h))

    let echelle = echelleDeLaFenetre()
    let points = taillePoints()
    let hauteurImage = hauteurDeLImage(points.hauteur)
    modele.tick(viewSize: CGSize(width: points.largeur, height: hauteurImage))

    rendu.viewport = modele.viewport
    rendu.display = modele.display
    rendu.teteDeLecture = colonne(deLInstant: modele.playhead)
    rendu.boucle = modele.loop.flatMap { plage in
        guard let debut = colonne(deLInstant: plage.lowerBound),
              let fin = colonne(deLInstant: plage.upperBound), fin > debut
        else { return nil }
        return debut...fin
    }
    // Sans habillage, le spectrogramme prend toute la fenêtre : c'est ce qui rend la
    // photographie comparable au rendu du processeur, qui n'a ni réglette ni ligne de
    // batterie.
    let zone = habille ? hauteurImage : points.hauteur
    rendu.zone(largeur: points.largeur, hauteur: zone, echelle: echelle)
    rendu.dessiner(echelle: echelle)
    guard avecSurimpression else { return }

    // Et par-dessus, tout ce qui est du texte et des traits. Une seule présentation
    // part : Cairo écrit dans une surface que le nuanceur de composition pose sur
    // l'image que la carte vient de remplir.
    rendu.surimprimer(echelle: echelle) { pinceau in
        Frise(modele: modele, pinceau: pinceau,
              largeur: points.largeur, hauteur: hauteurImage).dessiner()
        Batterie(modele: modele, pinceau: pinceau, largeur: points.largeur,
                 haut: hauteurImage, hauteur: hauteurDeLaBatterie).dessiner()
        // Le panneau vient après la frise et avant la barre : il flotte sur l'image,
        // et la barre d'état reste lisible par-dessus tout.
        panneau.dessiner(pinceau: pinceau, infobulle: infobulle,
                         largeurFenetre: points.largeur,
                         hauteurUtile: points.hauteur - hauteurDeLaBarre) {
            commandes.dessiner(dans: $0)
        }
        // La colonne par-dessus le panneau, et non l'inverse : elle est ce qui ne se
        // replie jamais, et le panneau vient se ranger à sa gauche.
        flottant.dessiner(pinceau: pinceau, infobulle: infobulle,
                          largeurFenetre: points.largeur,
                          modele: modele, panneauOuvert: panneau.ouvert) {
            panneau.ouvert.toggle()
        }
        Barre(modele: modele, pinceau: pinceau, largeur: points.largeur,
              haut: points.hauteur - hauteurDeLaBarre,
              hauteur: hauteurDeLaBarre).dessiner()
        // L'infobulle en dernier, et hors de toute découpe : elle se pose à gauche de
        // la commande survolée, donc en dehors du panneau qui la couperait net.
        infobulle.dessiner(pinceau, largeurFenetre: points.largeur,
                           hauteurFenetre: points.hauteur)
        // Et l'avis par-dessus l'infobulle elle-même : tant qu'il est là, il n'y a
        // rien d'autre à lire dans cette fenêtre.
        avis.dessiner(pinceau: pinceau, largeurFenetre: points.largeur,
                      hauteurFenetre: points.hauteur,
                      aMontrer: modele.avisDeRapports)
    }
}

// MARK: - La photographie, et la boucle

// La photographie sort **avant** la boucle d'évènements : c'est ce qui permet de
// juger l'image depuis une machine sans écran, et de la comparer au rendu processeur
// par `ImageCheck`.
if let photo {
    // Quelques tours : l'ouverture est asynchrone — analyse, tempo, accords, batterie
    // arrivent chacun quand ils sont prêts — et photographier la première image
    // rendrait une fenêtre vide.
    // `status` est ce que la barre d'état montre : il porte l'analyse, puis le
    // relevé de la batterie, puis celui des accords, et retombe à rien quand tout est
    // là. Photographier avant, c'est photographier une application à moitié chargée
    // et croire ensuite que la ligne de batterie est cassée.
    var repos = 0
    for _ in 0..<900 {
        viderLaFilePrincipale()
        uneImage()
        if modele.spectrogram.columnCount > 0, modele.status == nil {
            repos += 1
            if repos > 20 { break }
        } else {
            repos = 0
        }
        usleep(10_000)
    }
    uneImage()
    if let pixels = rendu.relire() {
        var image = Data("P6\n\(rendu.largeur) \(rendu.hauteur)\n255\n".utf8)
        image.append(contentsOf: pixels)
        try? image.write(to: URL(fileURLWithPath: photo))
        Journal.note("→ \(photo)")
    } else {
        Journal.erreur("la relecture de l'image a échoué")
        exit(1)
    }
    exit(0)
}

// MARK: - Les gestes

let surface = SurfaceSDL(fenetre: fenetre, modele: modele, panneau: panneau,
                         flottant: flottant, taillePoints: taillePoints)

// MARK: - Le relevé de fluidité

/// Fait défiler l'image pendant `secondes`, et rend le compte de ce que cela a coûté.
///
/// Le défilement est **posté à notre propre fenêtre** en vrais évènements de molette :
/// le geste traverse donc exactement le même chemin qu'un doigt sur le pavé —
/// traduction, modèle, recadrage, nuanceur, présentation. Piloter le viewport
/// directement mesurerait le rendu, pas l'application. C'est le même protocole que
/// sous Windows, et c'est ce qui rend les deux relevés comparables.
func mesurerLaFluidite(secondes: Double) -> String {
    let compteur = Mesures(cadence: cadenceDeLEcran(fenetre))
    surface.gestes.mesures = compteur

    // On laisse d'abord l'analyse finir : mesurer pendant qu'un cœur calcule la
    // matrice donnerait le coût de l'analyse, pas celui du défilement.
    for _ in 0..<600 {
        viderLaFilePrincipale()
        uneImage()
        rendu.presenter()
        if modele.spectrogram.columnCount > 0, modele.status == nil { break }
    }
    compteur.recommencer()

    let points = taillePoints()
    let debut = Horloge.maintenant()
    var sens = 1.0
    var evenement = SDL_Event()
    while Horloge.maintenant() - debut < secondes {
        // Un aller-retour plutôt qu'un défilement d'un seul côté : arrivé au bout du
        // morceau, le recadrage retient l'image et l'on mesurerait alors une
        // application qui ne bouge plus.
        var molette = SDL_MouseWheelEvent()
        molette.type = SDL_EVENT_MOUSE_WHEEL
        molette.windowID = SDL_GetWindowID(fenetre)
        molette.x = Float(sens)
        molette.mouse_x = Float(points.largeur / 2)
        molette.mouse_y = Float(points.hauteur / 2)
        var pousse = SDL_Event()
        pousse.wheel = molette
        SDL_PushEvent(&pousse)

        while SDL_PollEvent(&evenement) { _ = surface.repondre(evenement) }
        viderLaFilePrincipale()
        uneImage()
        rendu.presenter()
        compteur.uneImage()

        // Le nombre de colonnes visibles se déduit de la largeur : le viewport ne
        // porte que son origine et son échelle, la fenêtre porte le reste.
        let visibles = points.largeur * modele.viewport.columnsPerPoint
        if modele.viewport.startColumn <= 0 { sens = 1 }
        if modele.viewport.startColumn + visibles
            >= Double(modele.spectrogram.columnCount) { sens = -1 }
    }
    surface.gestes.mesures = nil
    return compteur.rapport(carte: rendu.nomDeLaCarte)
}

if let demande = valeur("--fluidite"), let secondes = Double(demande) {
    print(mesurerLaFluidite(secondes: secondes))
    modele.applicationVaSeFermer()
    exit(0)
}

// MARK: - La boucle

// Les rapports de panne s'ouvrent **ici**, et pas plus haut : au-dessus de cette
// ligne se trouvent la photographie et le relevé de fluidité, qui rendent une image
// puis s'arrêtent. Une machine d'intégration continue n'a aucune raison d'envoyer
// quoi que ce soit, et une panne de coureur n'apprend rien sur les gens qui se
// servent de l'application. Ce qui part vient d'une fenêtre ouverte devant
// quelqu'un. Voir `docs/RAPPORTS.md`.
Rapports.ouvrir()

var tourne = true
var evenement = SDL_Event()
while tourne {
    while SDL_PollEvent(&evenement) {
        if !surface.repondre(evenement) { tourne = false }
    }
    viderLaFilePrincipale()
    uneImage()
    rendu.presenter()
    // Une fois par image : les réglages ne s'écrivent que quand ils ont cessé de
    // bouger — voir l'en-tête de `ReglagesEnregistres`.
    PreferencesLinux.partagees.enregistrerSiBesoin()
}
modele.applicationVaSeFermer()
PreferencesLinux.partagees.enregistrerMaintenant()
