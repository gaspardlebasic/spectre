import CSDL3
import Foundation
import SpectreCore

// Spectre sous Windows : fenêtre, contexte OpenGL, rendu du spectrogramme.
//
//     SpectreWindows.exe morceau.wav
//     SpectreWindows.exe morceau.wav --rendu image.ppm    dessine une image et sort
//
// ─────────────────────────────────────────────────────────────────────────────
// UN PROGRAMME À FENÊTRE N'A PAS DE CONSOLE
//
// Lancé depuis l'explorateur, ce programme n'a nulle part où écrire : un échec
// au démarrage ne laisse alors *rien*, ce qui est la pire façon de tomber en
// panne. Tout ce qui suit est donc consigné dans `spectre.log`, à côté de
// l'exécutable, en plus de la sortie standard. Un journal qui ne sert à rien
// coûte trois lignes ; son absence coûte une soirée.
// ─────────────────────────────────────────────────────────────────────────────

let executable = URL(fileURLWithPath: CommandLine.arguments[0])
let dossier = executable.deletingLastPathComponent()
let journal = dossier.appendingPathComponent("spectre.log")
try? Data().write(to: journal)

func trace(_ message: String) {
    print(message)
    guard let poignee = try? FileHandle(forWritingTo: journal) else { return }
    defer { try? poignee.close() }
    poignee.seekToEndOfFile()
    poignee.write(Data((message + "\n").utf8))
}

func abandonne(_ message: String) -> Never {
    trace("ÉCHEC : \(message)")
    SDL_Quit()
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let sansTete = arguments.contains("--sans-tete")
var sortieImage: URL?
if let i = arguments.firstIndex(of: "--rendu"), i + 1 < arguments.count {
    sortieImage = URL(fileURLWithPath: arguments[i + 1])
}
let fichiers = arguments.filter { !$0.hasPrefix("--") && $0 != sortieImage?.path }

trace("Spectre — \(executable.lastPathComponent)")

SDL_SetMainReady()
guard SDL_Init(SDL_INIT_VIDEO) else {
    trace("ÉCHEC : SDL_Init — \(String(cString: SDL_GetError()))")
    exit(1)
}
defer { SDL_Quit() }

// Un contexte 3.3 au profil cœur : c'est ce que réclame le nuanceur, et c'est
// disponible sur toute machine Windows depuis quinze ans.
SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, Int32(SDL_GL_CONTEXT_PROFILE_CORE))
SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)

// Rendre une image et sortir n'a pas besoin de montrer la fenêtre : on la garde
// cachée, ce qui évite un clignotement à l'écran.
let cachee = sansTete || sortieImage != nil
let largeurFenetre: Int32 = 1200, hauteurFenetre: Int32 = 700

guard let fenetre = SDL_CreateWindow("Spectre", largeurFenetre, hauteurFenetre,
                                     SPECTRE_WINDOW_OPENGL | SPECTRE_WINDOW_RESIZABLE
                                     | (cachee ? SPECTRE_WINDOW_HIDDEN : 0)) else {
    abandonne("SDL_CreateWindow — \(String(cString: SDL_GetError()))")
}
defer { SDL_DestroyWindow(fenetre) }

guard let contexte = SDL_GL_CreateContext(fenetre) else {
    abandonne("SDL_GL_CreateContext — \(String(cString: SDL_GetError()))")
}
defer { SDL_GL_DestroyContext(contexte) }

var majeure: Int32 = 0, mineure: Int32 = 0
SDL_GL_GetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, &majeure)
SDL_GL_GetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, &mineure)
trace("  SDL \(String(cString: SDL_GetRevision())), pilote « \(String(cString: SDL_GetCurrentVideoDriver())) »")
trace("  contexte OpenGL \(majeure).\(mineure)")

// Le morceau à regarder. Sans argument, la fenêtre s'ouvre noire — ce qui est
// déjà une information : le contexte tient.
var rendu: SpectrogramRenderer?
var vue = Viewport()
var affichage = DisplaySettings()
var spectrogramme = Spectrogram.empty
var lecture: AudioOutput?
var boucle: ClosedRange<Double>?
var teteAuRepos: Double = 0

if let chemin = fichiers.first {
    do {
        let audio = try AudioLoader.load(at: URL(fileURLWithPath: chemin))
        trace(String(format: "  %@ — %.1f s à %d Hz",
                     (chemin as NSString).lastPathComponent,
                     audio.duration, Int(audio.sampleRate)))
        spectrogramme = OfflineAnalysis.run(samples: audio.mono,
                                            sampleRate: audio.sampleRate,
                                            settings: AnalysisSettings())
        if let regle = AutoContrast.settings(basedOn: affichage, in: spectrogramme) {
            affichage = regle
        }
        vue = Viewport.fitting(columns: spectrogramme.columnCount,
                               bins: spectrogramme.binCount,
                               size: (width: Double(largeurFenetre),
                                      height: Double(hauteurFenetre)))
        trace("  \(spectrogramme.columnCount) colonnes × \(spectrogramme.binCount) lignes")

        // Le nuanceur est lu à côté de l'exécutable : `build.ps1` l'y dépose, et
        // le garder dehors permet de le retoucher sans reconstruire.
        let voisin = dossier.appendingPathComponent("spectrogramme.glsl")
        let source = FileManager.default.fileExists(atPath: voisin.path)
            ? voisin : URL(fileURLWithPath: "Resources/spectrogramme.glsl")
        trace("  nuanceur : \(source.path)")
        guard let r = SpectrogramRenderer(spectrogram: spectrogramme, shaderPath: source) else {
            abandonne("le rendu n'a pas pu être préparé (voir ci-dessus)")
        }
        rendu = r
        trace("  \(r.description)")

        lecture = AudioOutput(samples: audio.mono, channels: 1,
                              sampleRate: audio.sampleRate)
        if lecture == nil {
            // Pas une raison d'abandonner : on peut regarder sans entendre, et
            // une machine sans carte son reste utile pour lire une image.
            trace("  (pas de sortie audio — on regarde sans écouter)")
        }
    } catch {
        abandonne("\(error)")
    }
}

/// Instant sous la tête de lecture, qu'on lise ou non.
var tete: Double { lecture?.isPlaying == true ? (lecture?.currentTime ?? 0) : teteAuRepos }

/// Dessine une image dans la taille courante de la fenêtre.
@discardableResult
func dessine() -> (largeur: Int, hauteur: Int) {
    var l: Int32 = 0, h: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &l, &h)
    rendu?.draw(viewport: vue, display: affichage,
                size: (width: Int(l), height: Int(h)),
                playhead: spectrogramme.columnCount > 0 ? tete : nil,
                loop: boucle)
    return (Int(l), Int(h))
}

/// Recadre la vue et accorde la bande écoutée à ce qu'on regarde.
///
/// C'est le geste central de l'application : ne pas entendre ce qu'on ne voit
/// pas. `Viewport` sait déjà quelle bande la vue couvre — il n'y a qu'à la lui
/// demander et la donner au filtre.
func recadre(_ taille: (largeur: Int, hauteur: Int)) {
    guard spectrogramme.columnCount > 0 else { return }
    vue.clamp(columns: spectrogramme.columnCount, bins: spectrogramme.binCount,
              size: (width: Double(taille.largeur), height: Double(taille.hauteur)))
    lecture?.setBand(vue.visibleBand(in: spectrogramme.layout,
                                     height: Double(taille.hauteur)))
}

if let sortieImage {
    let taille = dessine()
    guard let rendu else { abandonne("aucun morceau à dessiner") }
    let pixels = rendu.readPixels(width: taille.largeur, height: taille.hauteur)
    do {
        try PPM.write(width: taille.largeur, height: taille.hauteur,
                      pixels: pixels, to: sortieImage)
        trace("  → \(sortieImage.path) (\(taille.largeur)×\(taille.hauteur))")
    } catch {
        abandonne("écriture de l'image : \(error)")
    }
    trace("Fait.")
    exit(0)
}

if sansTete {
    trace("  (sans tête : on s'arrête, la fenêtre n'a pas été montrée)")
    exit(0)
}

trace("""
  fenêtre ouverte
    espace         lire / mettre en pause      clic      poser la tête de lecture
    molette        défiler dans le temps       Ctrl+     zoomer sur le temps
    Maj+molette    défiler en fréquence        Alt+      zoomer sur les fréquences
    [ et ]         borner la boucle            Échap     effacer la boucle, ou quitter
""")

var fini = false
var evenement = SDL_Event()
var taille = (largeur: Int(largeurFenetre), hauteur: Int(hauteurFenetre))
recadre(taille)

/// Instant sous le curseur, en secondes.
func instant(_ x: Float) -> Double {
    spectrogramme.time(ofColumn: Int(vue.column(atPoint: Double(x)).rounded()))
}

while !fini {
    while SDL_PollEvent(&evenement) {
        // Les identifiants d'évènements sont énumérés en `Int32` côté SDL et lus
        // en `UInt32` dans la structure : la conversion est explicite, faute de
        // quoi Swift refuse la comparaison.
        switch evenement.type {
        case UInt32(SDL_EVENT_QUIT.rawValue):
            fini = true

        case UInt32(SDL_EVENT_KEY_DOWN.rawValue):
            switch evenement.key.key {
            case SDLK_ESCAPE:
                // Échap efface la boucle s'il y en a une — sinon il quitte. Le
                // geste le plus courant passe avant le plus définitif.
                if boucle != nil { boucle = nil; lecture?.setLoop(nil) } else { fini = true }
            case SDLK_SPACE:
                if lecture?.isPlaying == true {
                    teteAuRepos = lecture?.currentTime ?? 0
                    lecture?.pause()
                } else {
                    lecture?.play(from: teteAuRepos)
                }
            case SDLK_LEFTBRACKET:
                boucle = LoopEditing.made(from: tete, to: boucle?.upperBound ?? spectrogramme.duration,
                                          duration: spectrogramme.duration, snap: { $0 })
                lecture?.setLoop(boucle)
            case SDLK_RIGHTBRACKET:
                boucle = LoopEditing.made(from: boucle?.lowerBound ?? 0, to: tete,
                                          duration: spectrogramme.duration, snap: { $0 })
                lecture?.setLoop(boucle)
            case SDLK_HOME:
                teteAuRepos = 0
                lecture?.seek(to: 0)
            default:
                break
            }

        case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue):
            let t = instant(evenement.button.x)
            teteAuRepos = t
            lecture?.seek(to: t)

        // Le pavé tactile de précision remonte ses gestes comme des évènements de
        // molette à fort taux : la navigation reste fluide sans code particulier.
        case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue):
            var x: Float = 0, y: Float = 0
            SDL_GetMouseState(&x, &y)
            // `SDL_Keymod` est un UInt16 nu et les constantes des UInt32 : la
            // conjonction demande de les ramener au même type.
            let mods = UInt32(SDL_GetModState())
            let ctrl = (mods & SDL_KMOD_CTRL) != 0
            let maj = (mods & SDL_KMOD_SHIFT) != 0
            let alt = (mods & SDL_KMOD_ALT) != 0
            let pas = Double(evenement.wheel.y != 0 ? evenement.wheel.y : evenement.wheel.x)

            if ctrl {
                // Zoom ancré sous le curseur : la colonne qu'on regarde ne bouge
                // pas d'un pixel, seule façon qu'un zoom paraisse naturel.
                vue.zoomTime(factor: pow(1.18, pas), anchorX: Double(x))
            } else if alt {
                vue.zoomFrequency(factor: pow(1.18, pas), anchorY: Double(y),
                                  height: Double(taille.hauteur))
            } else if maj {
                vue.bottomBin += pas * 12 * vue.binsPerPoint
            } else {
                vue.startColumn -= pas * 60 * vue.columnsPerPoint
            }
            recadre(taille)

        case UInt32(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED.rawValue):
            recadre(taille)

        default:
            break
        }
    }
    taille = dessine()
    SDL_GL_SwapWindow(fenetre)
    SDL_Delay(16)
}
