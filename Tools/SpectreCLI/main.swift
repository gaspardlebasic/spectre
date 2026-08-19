import Foundation
import SpectreCore

// Spectre en ligne de commande : un morceau entre, une image sort.
//
//     SpectreCLI morceau.wav [image.ppm]
//
// C'est l'application réduite à ce qu'elle a d'essentiel — décoder, analyser,
// régler le contraste, dessiner — sans fenêtre, sans carte son, sans GPU. Sur
// macOS elle fait double emploi avec l'application ; sur une plateforme dont
// l'interface n'est pas encore écrite, c'est le premier endroit où l'on voit que
// tout le reste marche.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("""
        usage : SpectreCLI <fichier> [sortie.ppm] [--taille LxH]

        Analyse un morceau et écrit son spectrogramme. Le contraste est réglé
        automatiquement sur son contenu, comme le fait ⌘K dans l'application.

        Format lu ici : wav.

        `--taille` impose les dimensions de l'image. C'est ce qui permet de
        comparer ce dessin-ci, fait sur le processeur, à celui que le GPU produit
        dans la même fenêtre : à taille égale, les deux images doivent se
        ressembler, et l'écart se mesure au lieu de se juger à l'œil.

        """.utf8))
    exit(2)
}

// Une taille imposée, éventuellement — sinon on la déduit du spectrogramme.
var tailleVoulue: (largeur: Int, hauteur: Int)?
if let i = arguments.firstIndex(of: "--taille"), i + 1 < arguments.count {
    let morceaux = arguments[i + 1].lowercased().split(separator: "x")
    if morceaux.count == 2, let l = Int(morceaux[0]), let h = Int(morceaux[1]), l > 0, h > 0 {
        tailleVoulue = (l, h)
    } else {
        FileHandle.standardError.write(Data("--taille attend « LARGEURxHAUTEUR », par exemple 1200x700.\n".utf8))
        exit(2)
    }
}

let positionnels = arguments.dropFirst().enumerated().filter { indice, valeur in
    guard !valeur.hasPrefix("--") else { return false }
    // La valeur qui suit `--taille` n'est pas un fichier.
    let precedent = indice == 0 ? "" : arguments[indice]
    return precedent != "--taille"
}.map(\.element)

guard let premier = positionnels.first else {
    FileHandle.standardError.write(Data("Il manque le fichier à analyser.\n".utf8))
    exit(2)
}
let entrée = URL(fileURLWithPath: premier)
let sortie = positionnels.count >= 2
    ? URL(fileURLWithPath: positionnels[1])
    : entrée.deletingPathExtension().appendingPathExtension("ppm")

let début = Date()

let fichier: WAVFile.Contents
do {
    // Le WAV et rien d'autre : ce chemin-ci ne dépend d'aucun décodeur du
    // système, ce qui est tout son intérêt. L'application, elle, ouvre n'importe
    // quel format par `AudioSource` et AVFoundation.
    fichier = try WAVFile.read(at: entrée)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

print(String(format: "  %@ — %.1f s, %d canal(aux) à %d Hz",
             entrée.lastPathComponent, fichier.duration,
             fichier.channels, Int(fichier.sampleRate)))

let réglages = AnalysisSettings()
let spectrogramme = OfflineAnalysis.run(samples: fichier.mono,
                                        sampleRate: fichier.sampleRate,
                                        settings: réglages)
let analyse = Date().timeIntervalSince(début)
guard spectrogramme.columnCount > 0 else {
    FileHandle.standardError.write(Data("Le morceau est trop court pour être analysé.\n".utf8))
    exit(1)
}
print(String(format: "  %d colonnes × %d lignes, %.0f Hz…%.0f Hz, analysé en %.2f s (×%.0f temps réel)",
             spectrogramme.columnCount, spectrogramme.binCount,
             spectrogramme.layout.minFrequency, spectrogramme.layout.maxFrequency,
             analyse, fichier.duration / max(analyse, 1e-9)))

// Le même réglage automatique que dans l'application : sans lui, l'image d'un
// morceau réel est soit blanche soit noire, et ne dit rien.
var affichage = DisplaySettings()
if let réglé = AutoContrast.settings(basedOn: affichage, in: spectrogramme) {
    affichage = réglé
    print(String(format: "  contraste : %.0f dB…%.0f dB, pente %.1f dB/octave",
                 affichage.floorDb, affichage.ceilingDb, affichage.tiltDbPerOctave))
}

if let grille = TempoEstimator.estimate(spectrogramme) {
    let sûreté = grille.confidence >= 2.2 ? "" : " (peu sûr)"
    print(String(format: "  tempo : %.0f BPM, premier temps à %.3f s%@",
                 grille.bpm, grille.origin, sûreté))
} else {
    print("  tempo : indéterminé")
}

// Une image large mais pas démesurée : au-delà, chaque colonne d'analyse occupe
// moins d'un pixel et l'on ne gagne rien.
let largeur = tailleVoulue?.largeur ?? min(max(spectrogramme.columnCount, 400), 4000)
let hauteur = tailleVoulue?.hauteur ?? min(max(spectrogramme.binCount, 200), 1200)
let pixels = SpectrogramImage.render(spectrogramme, display: affichage,
                                     width: largeur, height: hauteur)
do {
    try PPM.write(width: largeur, height: hauteur, pixels: pixels, to: sortie)
    print("  → \(sortie.path) (\(largeur)×\(hauteur))")
} catch {
    FileHandle.standardError.write(Data("Écriture impossible : \(error)\n".utf8))
    exit(1)
}
