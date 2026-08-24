import CSDL
import Foundation
import SpectreCore
import SpectreLin
import SpectreModele
import SpectreToile

// Spectre sous Linux — la fenêtre.
//
//     SpectreLinux morceau.wav                        ouvre la fenêtre
//     SpectreLinux morceau.wav --photo image.ppm      ouvre, photographie, et sort
//     SpectreLinux morceau.wav --taille 1700x343      la taille de l'image
//     SpectreLinux morceau.wav --gris                 sans la palette des notes
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUE CE FICHIER EST, ET CE QU'IL N'EST PAS ENCORE
//
// À l'étape 2 du portage, il ouvre un WAV, l'analyse et montre sa décomposition.
// Rien d'autre : pas de son, pas de gestes, rien de dessiné par-dessus. C'est
// délibéré — chaque étape se juge seule, et une fenêtre qui montre le
// spectrogramme est exactement ce qu'il fallait prouver.
//
// **Le WAV et rien d'autre**, parce que `WAVFile` est dans le noyau et ne dépend
// d'aucun décodeur du système. Ouvrir un MP3 est l'étape 4, et la faire ici
// mélangerait deux questions : « le nuanceur affiche-t-il juste ? » et « le
// décodeur rend-il le bon signal ? ».
//
// Le pendant Windows de ce fichier fait mille lignes. Celui-ci en fait deux cents,
// et l'écart n'est pas une avance : c'est tout ce qui reste à écrire.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Les arguments

let arguments = Array(CommandLine.arguments.dropFirst())
func valeur(_ nom: String) -> String? {
    guard let i = arguments.firstIndex(of: nom), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let positionnels = arguments.filter { !$0.hasPrefix("--") }
    .filter { argument in
        // Ce qui suit une option n'est pas un fichier.
        guard let i = arguments.firstIndex(of: argument), i > 0 else { return true }
        return !arguments[i - 1].hasPrefix("--")
    }

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

// MARK: - L'analyse

let contenu: WAVFile.Contents
do {
    contenu = try WAVFile.read(at: entree)
} catch {
    Journal.erreur("\(error)")
    exit(1)
}

var reglages = AnalysisSettings()
let spectrogramme = OfflineAnalysis.run(samples: contenu.mono,
                                        sampleRate: contenu.sampleRate,
                                        settings: reglages)
guard spectrogramme.columnCount > 0 else {
    Journal.erreur("Le morceau est trop court pour être analysé.")
    exit(1)
}
Journal.note(String(format: "%@ — %.1f s, %d colonnes × %d lignes",
                    entree.lastPathComponent, contenu.duration,
                    spectrogramme.columnCount, spectrogramme.binCount))

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

let largeurDepart = tailleVoulue?.largeur ?? 1200
let hauteurDepart = tailleVoulue?.hauteur ?? 700
// `HIGH_PIXEL_DENSITY` : sans lui, SDL rend une fenêtre en points et le
// spectrogramme sortirait flou sur un écran dense — ce que la version Mac ne fait
// pas, et ce qui se remarque immédiatement sur les raies.
let drapeaux = SpectreFenetreOpenGL | SpectreFenetreRedimensionnable | SpectreFenetreDense
guard let fenetre = SDL_CreateWindow(entree.lastPathComponent,
                                     largeurDepart, hauteurDepart, drapeaux) else {
    Journal.erreur("fenêtre : \(String(cString: SDL_GetError()))")
    exit(1)
}
defer { SDL_DestroyWindow(fenetre) }

guard let rendu = RenduGL(fenetreSDL: UnsafeMutableRawPointer(fenetre)) else {
    exit(1)
}
Journal.note("Carte : \(rendu.nomDeLaCarte)")

// MARK: - Ce qu'on montre

rendu.layout = spectrogramme.layout
rendu.upload(spectrogramme)

/// Le rapport entre pixels et points, tel que le compositeur le donne.
///
/// Tout ce qui se mesure dans le modèle — la position d'une raie, la largeur d'une
/// colonne — se compte en **points** ; le nuanceur, lui, travaille en pixels. C'est
/// le seul endroit où les deux se rencontrent.
func echelleDeLaFenetre() -> Double {
    Double(SDL_GetWindowPixelDensity(fenetre))
}

/// Cadre le morceau entier dans la fenêtre.
///
/// Le même cadrage que celui d'un fichier qu'on vient d'ouvrir sur le Mac : tout le
/// morceau de bout en bout, et toute la hauteur de l'axe des fréquences.
func cadrerEntier() {
    var l: Int32 = 0, h: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &l, &h)
    let echelle = echelleDeLaFenetre()
    let largeurPoints = Double(l) / echelle
    let hauteurPoints = Double(h) / echelle
    guard largeurPoints > 0, hauteurPoints > 0 else { return }

    var vue = Viewport()
    vue.startColumn = 0
    vue.columnsPerPoint = Double(spectrogramme.columnCount) / largeurPoints
    vue.bottomBin = 0
    vue.binsPerPoint = Double(spectrogramme.binCount) / hauteurPoints
    rendu.viewport = vue
}
cadrerEntier()

var affichage = DisplaySettings()
// `--gris` retire la palette des notes. C'est un instrument, pas un mode d'usage :
// il sépare deux questions que la couleur mêle — « les niveaux sont-ils justes ? »
// et « la classe de hauteur est-elle la bonne ? ».
if arguments.contains("--gris") { affichage.colorMap = .gray }
// Le même réglage automatique que dans l'application : sans lui, l'image d'un
// morceau réel est soit blanche soit noire, et ne dit rien.
if let regle = AutoContrast.settings(basedOn: affichage, in: spectrogramme) {
    affichage = regle
}
rendu.display = affichage

// MARK: - La boucle

func dessinerUneImage() {
    var l: Int32 = 0, h: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &l, &h)
    rendu.redimensionner(largeur: Int(l), hauteur: Int(h))
    rendu.dessiner(echelle: echelleDeLaFenetre())
}

// La photographie sort **avant** la boucle d'évènements : c'est ce qui permet de
// juger l'image depuis une machine sans écran, et de la comparer au rendu
// processeur par `ImageCheck`. Voir l'usage en tête de fichier.
if let photo {
    dessinerUneImage()
    if let pixels = rendu.relire() {
        var entete = Data("P6\n\(rendu.largeur) \(rendu.hauteur)\n255\n".utf8)
        entete.append(contentsOf: pixels)
        try? entete.write(to: URL(fileURLWithPath: photo))
        Journal.note("→ \(photo)")
    } else {
        Journal.erreur("la relecture de l'image a échoué")
        exit(1)
    }
    exit(0)
}

var tourne = true
var evenement = SDL_Event()
while tourne {
    while SDL_PollEvent(&evenement) {
        switch SDL_EventType(rawValue: evenement.type) {
        case SDL_EVENT_QUIT:
            tourne = false
        case SDL_EVENT_WINDOW_RESIZED, SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            // Le cadrage suit la fenêtre : ce qu'on voyait de bout en bout le reste
            // quand on l'élargit. Le tourne-page et le zoom sont l'étape 6.
            cadrerEntier()
        case SDL_EVENT_KEY_DOWN:
            if evenement.key.key == SDLK_ESCAPE || evenement.key.key == SDLK_Q {
                tourne = false
            }
        default:
            break
        }
    }
    dessinerUneImage()
    rendu.presenter()
}
