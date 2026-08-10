import CImGui
import CSDL3
import Foundation
import SpectreCore

// Spectre sous Windows : fenêtre, contexte OpenGL, rendu du spectrogramme,
// lecture, interface.
//
//     SpectreWindows.exe                          ouvre une fenêtre vide
//     SpectreWindows.exe morceau.mp3
//     SpectreWindows.exe morceau.wav --rendu image.ppm    dessine et sort
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

// ═══════════════════════════════════════════════════════════════════════ L'état

var rendu: SpectrogramRenderer?
var vue = Viewport()
var affichage = DisplaySettings()
var spectrogramme = Spectrogram.empty
var lecture: AudioOutput?
var boucle: ClosedRange<Double>?
var boucleActive = true
var tempo: TempoGrid?
var teteAuRepos: Double = 0
var nomDuMorceau: String?
var panneauAffichage = false
var vitesse: Double = 1
var transposition: Double = 0
var taille = (largeur: Int(largeurFenetre), hauteur: Int(hauteurFenetre))

/// Le nuanceur est lu à côté de l'exécutable : `build.ps1` l'y dépose, et le
/// garder dehors permet de le retoucher sans reconstruire.
let sourceNuanceur: URL = {
    let voisin = dossier.appendingPathComponent("spectrogramme.glsl")
    return FileManager.default.fileExists(atPath: voisin.path)
        ? voisin : URL(fileURLWithPath: "Resources/spectrogramme.glsl")
}()

/// Instant sous la tête de lecture, qu'on lise ou non.
var tete: Double { lecture?.isPlaying == true ? (lecture?.currentTime ?? 0) : teteAuRepos }

/// Recadre la vue et accorde la bande écoutée à ce qu'on regarde.
///
/// C'est le geste central de l'application : ne pas entendre ce qu'on ne voit
/// pas. `Viewport` sait déjà quelle bande la vue couvre — il n'y a qu'à la lui
/// demander et la donner au filtre.
func recadre() {
    guard spectrogramme.columnCount > 0 else { return }
    vue.clamp(columns: spectrogramme.columnCount, bins: spectrogramme.binCount,
              size: (width: Double(taille.largeur), height: Double(taille.hauteur)))
    lecture?.setBand(vue.visibleBand(in: spectrogramme.layout,
                                     height: Double(taille.hauteur)))
}

/// Ouvre un morceau. Tout ce qui dépendait du précédent est refait ; les
/// réglages d'affichage sont gardés, puis recalés sur le nouveau contenu.
@discardableResult
func charge(_ chemin: String) -> Bool {
    do {
        let audio = try AudioLoader.load(at: URL(fileURLWithPath: chemin))
        trace(String(format: "  %@ — %.1f s à %d Hz",
                     (chemin as NSString).lastPathComponent,
                     audio.duration, Int(audio.sampleRate)))

        let matrice = OfflineAnalysis.run(samples: audio.mono,
                                          sampleRate: audio.sampleRate,
                                          settings: AnalysisSettings())
        guard matrice.columnCount > 0 else {
            trace("  (morceau trop court pour être analysé)")
            return false
        }
        guard let r = SpectrogramRenderer(spectrogram: matrice, shaderPath: sourceNuanceur) else {
            trace("  ÉCHEC : le rendu n'a pas pu être préparé (voir ci-dessus)")
            return false
        }

        // La sortie précédente est arrêtée avant d'en ouvrir une autre : deux
        // périphériques qui jouent ensemble, c'est le morceau d'avant qui
        // continue par-dessus le nouveau.
        lecture?.pause()
        lecture = AudioOutput(samples: audio.mono, channels: 1, sampleRate: audio.sampleRate)
        if lecture == nil {
            trace("  (pas de sortie audio — on regarde sans écouter)")
        } else {
            // Le ralenti choisi vaut pour le morceau suivant : on ne le remet pas
            // à ×1 dans le dos de qui vient de le régler.
            lecture?.speed = vitesse
            lecture?.transpose = transposition
        }

        spectrogramme = matrice
        rendu = r
        nomDuMorceau = (chemin as NSString).lastPathComponent
        boucle = nil
        teteAuRepos = 0
        if let regle = AutoContrast.settings(basedOn: affichage, in: matrice) { affichage = regle }
        vue = Viewport.fitting(columns: matrice.columnCount, bins: matrice.binCount,
                               size: (width: Double(taille.largeur),
                                      height: Double(taille.hauteur)))
        tempo = TempoEstimator.estimate(matrice)
        trace("  \(matrice.columnCount) colonnes × \(matrice.binCount) lignes")
        trace("  \(r.description)")
        recadre()
        return true
    } catch {
        trace("  ÉCHEC : \(error)")
        return false
    }
}

if let chemin = fichiers.first { charge(chemin) }

/// Dessine une image dans la taille courante de la fenêtre.
@discardableResult
func dessine() -> (largeur: Int, hauteur: Int) {
    var l: Int32 = 0, h: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &l, &h)
    rendu?.draw(viewport: vue, display: affichage,
                size: (width: Int(l), height: Int(h)),
                playhead: spectrogramme.columnCount > 0 ? tete : nil,
                loop: boucleActive ? boucle : nil)
    return (Int(l), Int(h))
}

// ═════════════════════════════════════════════ dessiner une image et s'en aller

if let sortieImage {
    let t = dessine()
    guard let rendu else { abandonne("aucun morceau à dessiner") }
    let pixels = rendu.readPixels(width: t.largeur, height: t.hauteur)
    do {
        try PPM.write(width: t.largeur, height: t.hauteur, pixels: pixels, to: sortieImage)
        trace("  → \(sortieImage.path) (\(t.largeur)×\(t.hauteur))")
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

// ═════════════════════════════════════════════════════════════════ l'interface

// La fenêtre peut être sur un écran à forte densité : sans cela l'interface y
// serait deux fois trop petite, alors que le spectrogramme, lui, se compte en
// pixels et n'a rien à mettre à l'échelle.
let echelle = SDL_GetWindowDisplayScale(fenetre)
if spectre_ui_demarrer(UnsafeMutableRawPointer(fenetre),
                       UnsafeMutableRawPointer(contexte),
                       echelle > 0 ? echelle : 1) == 0 {
    abandonne("l'interface n'a pas pu démarrer")
}
defer { spectre_ui_arreter() }
trace(String(format: "  interface prête (échelle %.2f)", echelle))

trace("""
  fenêtre ouverte
    espace         lire / mettre en pause      clic      poser la tête de lecture
    molette        défiler dans le temps       Ctrl+     zoomer sur le temps
    Maj+molette    défiler en fréquence        Alt+      zoomer sur les fréquences
    [ et ]         borner la boucle            B         caler la boucle sur les mesures
    L              boucler ou non              Échap     effacer la boucle, ou quitter
    Ctrl+O         ouvrir un morceau           K         contraste automatique
    T              premier temps ici           Origine   revenir au début
    0              vitesse et hauteur normales
""")

// ══════════════════════════════════════════════════════════════════ les gestes

/// Instant sous le curseur, en secondes.
func instant(_ x: Float) -> Double {
    spectrogramme.time(ofColumn: Int(vue.column(atPoint: Double(x)).rounded()))
}

func lireOuPause() {
    if lecture?.isPlaying == true {
        teteAuRepos = lecture?.currentTime ?? 0
        lecture?.pause()
    } else {
        lecture?.play(from: teteAuRepos)
    }
}

func contrasteAuto() {
    if let regle = AutoContrast.settings(basedOn: affichage, in: spectrogramme) {
        affichage = regle
    }
}

func borne(debut: Bool) {
    guard spectrogramme.duration > 0 else { return }
    if debut {
        boucle = LoopEditing.made(from: tete, to: boucle?.upperBound ?? spectrogramme.duration,
                                  duration: spectrogramme.duration, snap: { $0 })
    } else {
        boucle = LoopEditing.made(from: boucle?.lowerBound ?? 0, to: tete,
                                  duration: spectrogramme.duration, snap: { $0 })
    }
}

/// Étend la boucle aux mesures entières qui la contiennent. Sans grille il n'y a
/// rien à caler : l'action est alors sans effet, comme sur macOS.
func caleSurMesures() {
    guard let b = boucle, let grille = tempo, grille.barSeconds > 0 else { return }
    let premiere = (grille.beat(at: b.lowerBound) / Double(grille.beatsPerBar)).rounded(.down)
    let derniere = (grille.beat(at: b.upperBound) / Double(grille.beatsPerBar)).rounded(.up)
    boucle = LoopEditing.made(from: grille.time(ofBeat: premiere * Double(grille.beatsPerBar)),
                              to: grille.time(ofBeat: derniere * Double(grille.beatsPerBar)),
                              duration: spectrogramme.duration, snap: { $0 })
}

func premierTempsIci() {
    if tempo != nil { tempo?.origin = tete } else { tempo = TempoGrid(bpm: 120, origin: tete) }
}

var fini = false
var evenement = SDL_Event()
var boucleAppliquee: ClosedRange<Double>?
var activeAppliquee = true
var vitesseAppliquee: Double = 1
var transpositionAppliquee: Double = 0
var premiereImage = true
recadre()

while !fini {
    while SDL_PollEvent(&evenement) {
        // L'interface voit tout en premier et dit ce qu'elle a pris. Sans cela,
        // un clic sur un bouton déplacerait aussi la tête de lecture, et taper
        // dans une réglette piloterait la lecture.
        let prisParInterface = spectre_ui_evenement(&evenement) != 0

        // Les identifiants d'évènements sont énumérés en `Int32` côté SDL et lus
        // en `UInt32` dans la structure : la conversion est explicite, faute de
        // quoi Swift refuse la comparaison.
        switch evenement.type {
        case UInt32(SDL_EVENT_QUIT.rawValue):
            fini = true

        case UInt32(SDL_EVENT_KEY_DOWN.rawValue) where !prisParInterface:
            let ctrl = (UInt32(SDL_GetModState()) & SDL_KMOD_CTRL) != 0
            switch evenement.key.key {
            case SDLK_ESCAPE:
                // Échap efface la boucle s'il y en a une — sinon il quitte. Le
                // geste le plus courant passe avant le plus définitif.
                if boucle != nil { boucle = nil } else { fini = true }
            case SDLK_SPACE: lireOuPause()
            case SDLK_LEFTBRACKET: borne(debut: true)
            case SDLK_RIGHTBRACKET: borne(debut: false)
            case SDLK_B: caleSurMesures()
            case SDLK_K: contrasteAuto()
            case SDLK_L: boucleActive.toggle()
            case SDLK_T: premierTempsIci()
            case SDLK_0: vitesse = 1; transposition = 0
            case SDLK_O where ctrl: Dialogue.ouvrir(fenetre: fenetre)
            case SDLK_HOME:
                teteAuRepos = 0
                lecture?.seek(to: 0)
            default:
                break
            }

        case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue) where !prisParInterface:
            let t = instant(evenement.button.x)
            teteAuRepos = t
            lecture?.seek(to: t)

        // Le pavé tactile de précision remonte ses gestes comme des évènements de
        // molette à fort taux : la navigation reste fluide sans code particulier.
        case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue) where !prisParInterface:
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
            recadre()

        case UInt32(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED.rawValue):
            recadre()

        default:
            break
        }
    }

    // Le morceau choisi dans le dialogue est ramassé ici, sur le fil qui possède
    // le contexte OpenGL — voir `Dialogue`.
    if let choisi = Dialogue.recupere() { charge(choisi) }

    spectre_ui_nouvelle_image()
    let demandes = Interface.dessine(largeur: Float(taille.largeur),
                                     nom: nomDuMorceau,
                                     tete: tete, duree: spectrogramme.duration,
                                     enLecture: lecture?.isPlaying == true,
                                     boucle: boucle,
                                     boucleActive: &boucleActive,
                                     vitesse: &vitesse,
                                     transposition: &transposition,
                                     tempo: &tempo,
                                     affichage: &affichage,
                                     panneauAffichage: &panneauAffichage)

    if demandes.ouvrir { Dialogue.ouvrir(fenetre: fenetre) }
    if demandes.lireOuPause { lireOuPause() }
    if demandes.revenirAuDebut { teteAuRepos = 0; lecture?.seek(to: 0) }
    if demandes.bornerDebut { borne(debut: true) }
    if demandes.bornerFin { borne(debut: false) }
    if demandes.calerSurMesures { caleSurMesures() }
    if demandes.effacerBoucle { boucle = nil }
    if demandes.contrasteAuto { contrasteAuto() }
    if demandes.premierTempsIci { premierTempsIci() }
    if demandes.recalculerTempo, spectrogramme.columnCount > 0 {
        // L'estimation prend une fraction de seconde sur un morceau ordinaire :
        // la faire ici coûte une image sautée, ce qui vaut mieux qu'un fil de
        // plus et l'état partagé qui va avec.
        tempo = TempoEstimator.estimate(spectrogramme, beatsPerBar: tempo?.beatsPerBar ?? 4)
    }

    // Vitesse et transposition ne descendent que lorsqu'elles changent, pour la
    // même raison que la boucle.
    if vitesse != vitesseAppliquee { vitesseAppliquee = vitesse; lecture?.speed = vitesse }
    if transposition != transpositionAppliquee {
        transpositionAppliquee = transposition
        lecture?.transpose = transposition
    }

    // La boucle n'est portée au lecteur que lorsqu'elle change : la lui redonner
    // à chaque image prendrait le verrou soixante fois par seconde sous le nez
    // du fil temps réel.
    if boucle != boucleAppliquee || boucleActive != activeAppliquee {
        boucleAppliquee = boucle
        activeAppliquee = boucleActive
        lecture?.setLoop(boucleActive ? boucle : nil)
    }

    taille = dessine()
    spectre_ui_dessiner()
    if premiereImage {
        // Ce que le journal doit dire pour qu'on sache, à distance, que
        // l'interface a bien été dessinée et pas seulement démarrée.
        trace("  première image : \(spectre_ui_sommets()) sommets d'interface, "
            + "barre de \(Int(spectre_ui_hauteur_barre())) points")
        premiereImage = false
    }
    SDL_GL_SwapWindow(fenetre)
    SDL_Delay(16)
}
