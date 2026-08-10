import Foundation
import SpectreCore

// Le filtre de bande, mesuré sur sa réponse plutôt que comparé à `AVAudioUnitEQ`.
//
// Comparer à l'unité d'Apple serait tentant, et ce serait une erreur : son gabarit
// exact n'est pas documenté, si bien que l'égalité ne pourrait être qu'approchée et
// ne dirait rien de ce qu'on cherche. Ce qu'on cherche est nommable : la bande
// passante doit rester plate, la pente doit valoir 24 dB par octave, et une borne
// posée au bord de l'analyse ne doit rien filtrer du tout.

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

let fs = 48000.0

/// Gain du filtre à une fréquence, en dB, mesuré au régime établi sur une
/// sinusoïde — donc sur le filtre tel qu'il tourne, pas sur ses coefficients.
func gainDb(_ filtre: inout BandFilter, at frequency: Double) -> Double {
    let n = 32768
    let amorce = 8192              // le temps que le transitoire s'éteigne
    filtre.reset()
    var crête: Float = 0
    for i in 0..<n {
        let x = Float(sin(2 * .pi * frequency * Double(i) / fs))
        let y = filtre.process(x)
        if i >= amorce { crête = max(crête, abs(y)) }
    }
    return 20 * log10(max(Double(crête), 1e-12))
}

titre("Bande passante")
var filtre = BandFilter(sampleRate: fs)
filtre.setBand(200...2000)
// Le cœur de la bande, à distance des deux coudes.
for f in [400.0, 700.0, 1000.0] {
    let g = gainDb(&filtre, at: f)
    verifie(abs(g) < 0.6, "\(Int(f)) Hz passe sans être touché",
            String(format: "%+.2f dB", g))
}
// Deux Butterworth identiques en cascade descendent déjà à l'approche de la
// borne : à une demi-octave, il manque presque 2 dB. Ce n'est pas un défaut mais
// la forme qu'on reproduit — celle de deux bandes d'`AVAudioUnitEQ` posées à la
// même fréquence. Des facteurs de qualité échelonnés garderaient la bande plate
// jusqu'au coude, et feraient sonner Windows autrement que macOS.
let coude = gainDb(&filtre, at: 1400)
verifie(coude < -1 && coude > -3, "à une demi-octave de la borne, le coude a commencé",
        String(format: "%+.2f dB à 1400 Hz", coude))

titre("Pente")
// Une octave sous la borne basse, puis deux : chaque octave doit coûter 24 dB.
let g200 = gainDb(&filtre, at: 200)
let g100 = gainDb(&filtre, at: 100)
let g50 = gainDb(&filtre, at: 50)
verifie(abs((g100 - g50) - 24) < 3, "24 dB par octave sous la bande",
        String(format: "%.1f dB entre 50 et 100 Hz", g100 - g50))
let g2000 = gainDb(&filtre, at: 2000)
let g4000 = gainDb(&filtre, at: 4000)
let g8000 = gainDb(&filtre, at: 8000)
verifie(abs((g4000 - g8000) - 24) < 3, "24 dB par octave au-dessus",
        String(format: "%.1f dB entre 4000 et 8000 Hz", g4000 - g8000))

titre("Bornes")
verifie(abs(g200 + 6) < 1.5, "la borne basse est à −6 dB",
        String(format: "%+.2f dB à 200 Hz", g200))
verifie(abs(g2000 + 6) < 1.5, "la borne haute est à −6 dB",
        String(format: "%+.2f dB à 2000 Hz", g2000))
// C'est ce qui donne son sens à la bande : ce qu'on a écarté doit l'être
// franchement, sans quoi la basse voisine s'entend encore.
verifie(g50 < -40, "deux octaves plus bas, il ne reste rien",
        String(format: "%.1f dB à 50 Hz", g50))

titre("Retrait du chemin")
var entier = BandFilter(sampleRate: fs)
entier.setBand(nil)
verifie(entier.isBypassed, "aucune bande demandée, aucun filtre en service")

var bordBas = BandFilter(sampleRate: fs)
bordBas.setBand(22...(fs / 2 * 0.95))
verifie(bordBas.isBypassed, "une bande qui couvre toute l'analyse ne filtre rien")

var moitié = BandFilter(sampleRate: fs)
moitié.setBand(22...3000)
verifie(!moitié.isBypassed, "une seule borne suffit à mettre le filtre en service")
let grave = gainDb(&moitié, at: 30)
verifie(abs(grave) < 0.6, "et la borne inutile laisse passer les graves",
        String(format: "%+.2f dB à 30 Hz", grave))

titre("Transparence")
var neutre = BandFilter(sampleRate: fs)
neutre.setBand(nil)
var écart: Float = 0
for i in 0..<4096 {
    let x = Float(sin(2 * .pi * 440 * Double(i) / fs))
    écart = max(écart, abs(neutre.process(x) - x))
}
verifie(écart == 0, "hors service, les échantillons passent tels quels",
        String(format: "écart %.1e", écart))

titre("Consignes répétées")
var stable = BandFilter(sampleRate: fs)
stable.setBand(200...2000)
let avant = gainDb(&stable, at: 1000)
// Un mouvement de trackpad produit une consigne par image : un écart inaudible ne
// doit pas recalculer les coefficients, sans quoi le son claque à chaque geste.
stable.setBand(200.4...2004)
verifie(stable.applied == 200...2000, "un écart inaudible ne retouche rien",
        "bande conservée")
stable.setBand(400...2000)
verifie(stable.applied == 400...2000, "un écart audible est pris en compte")
let après = gainDb(&stable, at: 1000)
verifie(abs(avant - après) < 0.6, "la bande passante reste plate après changement",
        String(format: "%+.2f dB puis %+.2f dB", avant, après))

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
