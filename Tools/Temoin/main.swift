import Foundation
import SpectreCore

// Fabrique le morceau témoin : un WAV de synthèse dont on connaît d'avance le
// tempo, la grille d'accords et le motif de batterie.
//
//     Temoin [sortie.wav] [--mesures N]
//
// Le fichier témoin d'un vrai morceau ne peut pas vivre dans le dépôt — droits,
// poids, et de toute façon il disparaît des Téléchargements. Sans lui, personne
// qui arrive sur ce dépôt ne peut éprouver la chaîne complète : ouvrir un
// fichier, l'analyser, en relever le tempo, les accords et la batterie. Ce
// programme rend cette épreuve possible partout, et deux fois de suite à
// l'identique — la seule source de hasard, le bruit des percussions, vient d'un
// générateur à graine fixe, si bien que le fichier produit est le même octet
// pour octet d'une machine à l'autre.
//
// Ce n'est pas un remplaçant du vrai morceau : une synthèse ne montre ni les
// erreurs de séparation ni ce qu'un enregistrement saturé fait au relevé. C'est
// un plancher — ce qui doit marcher avant qu'on aille écouter de la vraie
// musique.

let arguments = CommandLine.arguments

func valeur(_ nom: String) -> String? {
    guard let i = arguments.firstIndex(of: nom), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let sortie = arguments.dropFirst().first { !$0.hasPrefix("--") && $0 != valeur("--mesures") }
    ?? "build/essai/temoin.wav"
let mesures = valeur("--mesures").flatMap(Int.init) ?? 8

let rate = 44100.0
let bpm = 120.0
let beat = 60 / bpm

// MARK: - La grille

/// Une mesure : ce que joue l'accompagnement, ce que joue la basse, et le nom que
/// le relevé doit rendre.
struct Mesure {
    let accord: String
    let basse: Int
    let notes: [Int]
}

// Do, la mineur, fa, sol — la tournerie la plus banale qui soit, et c'est
// exactement ce qu'on veut : si le relevé se trompe là-dessus, il se trompera
// partout. Les voicings restent serrés autour de do3 pour que les raies tombent
// dans la partie du spectre que l'application montre par défaut.
let grille: [Mesure] = [
    Mesure(accord: "C",  basse: 36, notes: [60, 64, 67]),
    Mesure(accord: "Am", basse: 45, notes: [57, 60, 64]),
    Mesure(accord: "F",  basse: 41, notes: [57, 60, 65]),
    Mesure(accord: "G",  basse: 43, notes: [59, 62, 67]),
]

// MARK: - Les instruments

let durée = Double(mesures) * 4 * beat + 1
var mix = [Float](repeating: 0, count: Int(durée * rate))

/// Une note tenue, avec six harmoniques décroissantes.
///
/// Une sinusoïde pure ne prouverait rien : c'est la tierce majeure fantôme du
/// troisième harmonique qui fait la difficulté d'un relevé d'accords, et il faut
/// donc qu'elle soit là. L'attaque et l'extinction sont adoucies, faute de quoi
/// le créneau étalerait un clic sur tout le spectre.
func note(midi: Int, depuis début: Double, secondes: Double, gain: Double) {
    let f0 = Pitch.frequency(ofMidi: Double(midi))
    let premier = Int(début * rate)
    let combien = Int(secondes * rate)
    guard combien > 0 else { return }
    for i in 0..<combien {
        let j = premier + i
        guard j >= 0, j < mix.count else { continue }
        let t = Double(i) / rate
        let enveloppe = min(t / 0.02, 1) * min((Double(combien) / rate - t) / 0.05, 1)
        var valeur = 0.0
        for h in 1...6 {
            valeur += pow(0.55, Double(h - 1)) * sin(2 * .pi * f0 * Double(h) * t)
        }
        mix[j] += Float(gain * max(enveloppe, 0) * valeur * 0.2)
    }
}

/// Un générateur à graine fixe : deux exécutions doivent rendre le même fichier.
var graine: UInt64 = 0x5065_6175_2064_2ABE
func bruit() -> Double {
    graine = graine &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: graine >> 11)) / Double(1 << 52) * 2 - 1
}

/// La grosse caisse : une sinusoïde qui descend vite, comme une peau tendue.
func caisse(à début: Double) {
    let premier = Int(début * rate)
    let combien = Int(0.18 * rate)
    for i in 0..<combien {
        let j = premier + i
        guard j >= 0, j < mix.count else { continue }
        let t = Double(i) / rate
        let f = 110 * exp(-t * 26) + 42
        mix[j] += Float(exp(-t * 18) * sin(2 * .pi * f * t) * 0.75)
    }
}

/// La caisse claire : du bruit filtré grossièrement, plus un timbre à 190 Hz.
func claire(à début: Double) {
    let premier = Int(début * rate)
    let combien = Int(0.14 * rate)
    var précédent = 0.0
    for i in 0..<combien {
        let j = premier + i
        guard j >= 0, j < mix.count else { continue }
        let t = Double(i) / rate
        let brut = bruit()
        // Passe-haut du pauvre : la différence de deux échantillons successifs.
        let filtré = brut - précédent * 0.75
        précédent = brut
        let corps = sin(2 * .pi * 190 * t) * 0.3
        mix[j] += Float(exp(-t * 30) * (filtré * 0.5 + corps) * 0.55)
    }
}

/// La charleston : très court, très aigu, sur chaque croche.
func charleston(à début: Double) {
    let premier = Int(début * rate)
    let combien = Int(0.05 * rate)
    var précédent = 0.0
    for i in 0..<combien {
        let j = premier + i
        guard j >= 0, j < mix.count else { continue }
        let t = Double(i) / rate
        let brut = bruit()
        let filtré = brut - précédent * 0.95
        précédent = brut
        mix[j] += Float(exp(-t * 70) * filtré * 0.22)
    }
}

// MARK: - Le morceau

for mesure in 0..<mesures {
    let accord = grille[mesure % grille.count]
    let début = Double(mesure) * 4 * beat

    for hauteur in accord.notes {
        note(midi: hauteur, depuis: début, secondes: 4 * beat - 0.02, gain: 1)
    }
    // La basse rejoue à chaque temps : c'est ce que fait une basse, et c'est ce
    // qui donne au relevé sa fondamentale.
    for temps in 0..<4 {
        note(midi: accord.basse, depuis: début + Double(temps) * beat,
             secondes: beat - 0.03, gain: 1.4)
    }
    // Grosse caisse aux temps 1 et 3, claire aux temps 2 et 4, charleston aux
    // croches — le motif que tout relevé de batterie doit savoir rendre.
    caisse(à: début)
    caisse(à: début + 2 * beat)
    claire(à: début + beat)
    claire(à: début + 3 * beat)
    for croche in 0..<8 {
        charleston(à: début + Double(croche) * beat / 2)
    }
}

// MARK: - L'écriture

// Une normalisation par la crête, pas par la moyenne : le but n'est pas d'être
// fort, c'est de ne jamais saturer — un écrêtage ajouterait des harmoniques
// qu'on n'a pas demandées et fausserait le relevé qu'on prétend éprouver.
let crête = mix.map { abs($0) }.max() ?? 1
let facteur = crête > 0 ? 0.89 / crête : 1

var octets = Data()
func ajouter(_ texte: String) { octets.append(contentsOf: Array(texte.utf8)) }
func ajouter16(_ v: Int) { octets.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
func ajouter32(_ v: Int) {
    octets.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                               UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
}

let canaux = 2, bits = 16
let images = mix.count
let taillePCM = images * canaux * bits / 8

ajouter("RIFF"); ajouter32(36 + taillePCM); ajouter("WAVE")
ajouter("fmt "); ajouter32(16)
ajouter16(1)                                  // PCM
ajouter16(canaux)
ajouter32(Int(rate))
ajouter32(Int(rate) * canaux * bits / 8)      // octets par seconde
ajouter16(canaux * bits / 8)                  // alignement d'une image
ajouter16(bits)
ajouter("data"); ajouter32(taillePCM)

// Stéréo, les deux canaux identiques : le morceau est un mixage mono, mais un
// fichier stéréo est ce que l'application rencontre dans la vraie vie, et c'est
// donc ce chemin-là qu'il faut faire emprunter au décodeur.
octets.reserveCapacity(octets.count + taillePCM)
for échantillon in mix {
    let v = max(-1, min(1, Double(échantillon) * Double(facteur)))
    let entier = Int(v * 32767)
    ajouter16(entier & 0xFFFF)
    ajouter16(entier & 0xFFFF)
}

let url = URL(fileURLWithPath: sortie)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
do {
    try octets.write(to: url)
} catch {
    FileHandle.standardError.write(Data("Écriture impossible : \(error)\n".utf8))
    exit(1)
}

let noms = (0..<mesures).map { grille[$0 % grille.count].accord }.joined(separator: " ")
print("""
    → \(url.path)
      \(String(format: "%.1f", durée)) s, \(Int(rate)) Hz, \(canaux) canaux, \(bits) bits
      tempo attendu   : \(Int(bpm)) BPM, 4 temps par mesure
      grille attendue : \(noms)
      batterie        : grosse caisse aux temps 1 et 3, claire aux 2 et 4, \
    charleston aux croches
    """)
