import CSDL3
import Foundation
import SpectreCore

// Ouverture d'une fenêtre et d'un contexte OpenGL, et rien de plus.
//
// C'est délibérément minuscule : ce qu'on cherche à établir ici n'est pas le
// rendu mais la **plomberie** — que SDL3 se laisse voir depuis Swift, que
// l'édition de liens aboutisse, que la DLL se trouve à l'exécution, et qu'un
// contexte 3.3 soit accordé par le pilote. Rien de tout cela ne se devine ; tout
// se compile ou ne se compile pas.
//
// Le rendu du spectrogramme viendra au-dessus : le nuanceur est déjà traduit
// dans `Resources/spectrogramme.glsl`, et `SpectrogramImage` donne l'arbitre qui
// dira si le GPU rend la même chose que le processeur.

// À lancer depuis une vraie session de bureau. Piloté par `prlctl exec`, qui
// s'exécute en session SYSTEM sans bureau interactif, le backend vidéo Windows
// de SDL tombe sur une violation d'accès avant même de rendre la main — ce n'est
// pas un défaut d'ici, et le pilote factice le montre : avec
// `SDL_VIDEODRIVER=dummy`, `SDL_Init` réussit et c'est `SDL_CreateWindow` qui
// refuse proprement, faute d'OpenGL.
SDL_SetMainReady()

guard SDL_Init(SDL_INIT_VIDEO) else {
    FileHandle.standardError.write(Data("SDL_Init : \(String(cString: SDL_GetError()))\n".utf8))
    exit(1)
}
defer { SDL_Quit() }

// Un contexte 3.3 au profil cœur : c'est ce que réclame le nuanceur, et c'est
// disponible sur toute machine Windows depuis quinze ans.
SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, Int32(SDL_GL_CONTEXT_PROFILE_CORE))
SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)

let sansTete = ProcessInfo.processInfo.arguments.contains("--sans-tete")

guard let fenetre = SDL_CreateWindow("Spectre", 1200, 700,
                                     SPECTRE_WINDOW_OPENGL | SPECTRE_WINDOW_RESIZABLE
                                     | (sansTete ? SPECTRE_WINDOW_HIDDEN : 0)) else {
    FileHandle.standardError.write(Data("SDL_CreateWindow : \(String(cString: SDL_GetError()))\n".utf8))
    exit(1)
}
defer { SDL_DestroyWindow(fenetre) }

guard let contexte = SDL_GL_CreateContext(fenetre) else {
    FileHandle.standardError.write(Data("SDL_GL_CreateContext : \(String(cString: SDL_GetError()))\n".utf8))
    exit(1)
}
defer { SDL_GL_DestroyContext(contexte) }

var majeure: Int32 = 0, mineure: Int32 = 0
SDL_GL_GetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, &majeure)
SDL_GL_GetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, &mineure)
print("  SDL \(String(cString: SDL_GetRevision()))")
print("  contexte OpenGL \(majeure).\(mineure) sur « \(String(cString: SDL_GetCurrentVideoDriver())) »")

// Sans écran — dans une machine virtuelle pilotée en ligne de commande, ou en
// intégration continue — on s'arrête ici : la plomberie est établie, et rester
// dans une boucle d'évènements sans personne pour la fermer ne prouve rien.
if sansTete {
    print("  (sans tête : on s'arrête, la fenêtre n'a pas été montrée)")
    exit(0)
}

// Le morceau à regarder. Sans argument, la fenêtre reste noire — ce qui est déjà
// une information : le contexte tient.
var rendu: SpectrogramRenderer?
var vue = Viewport()
var affichage = DisplaySettings()

let fichiers = ProcessInfo.processInfo.arguments.dropFirst().filter { !$0.hasPrefix("--") }
if let chemin = fichiers.first {
    do {
        let audio = try WAVFile.read(at: URL(fileURLWithPath: chemin))
        let spectrogramme = OfflineAnalysis.run(samples: audio.mono,
                                                sampleRate: audio.sampleRate,
                                                settings: AnalysisSettings())
        if let regle = AutoContrast.settings(basedOn: affichage, in: spectrogramme) {
            affichage = regle
        }
        vue = Viewport.fitting(columns: spectrogramme.columnCount,
                               bins: spectrogramme.binCount,
                               size: (width: 1200, height: 700))
        // Le nuanceur est lu à côté de l'exécutable : `build.ps1` l'y dépose.
        let voisin = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("spectrogramme.glsl")
        let source = FileManager.default.fileExists(atPath: voisin.path)
            ? voisin
            : URL(fileURLWithPath: "Resources/spectrogramme.glsl")
        rendu = SpectrogramRenderer(spectrogram: spectrogramme, shaderPath: source)
        if rendu == nil { exit(1) }
        print(String(format: "  %d colonnes × %d lignes", spectrogramme.columnCount,
                     spectrogramme.binCount))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

var fini = false
var evenement = SDL_Event()
while !fini {
    while SDL_PollEvent(&evenement) {
        if evenement.type == SDL_EVENT_QUIT.rawValue { fini = true }
        if evenement.type == SDL_EVENT_KEY_DOWN.rawValue,
           evenement.key.key == SDLK_ESCAPE { fini = true }
    }
    var largeur: Int32 = 0, hauteur: Int32 = 0
    SDL_GetWindowSizeInPixels(fenetre, &largeur, &hauteur)
    rendu?.draw(viewport: vue, display: affichage,
                size: (width: Int(largeur), height: Int(hauteur)))
    SDL_GL_SwapWindow(fenetre)
    SDL_Delay(16)
}
