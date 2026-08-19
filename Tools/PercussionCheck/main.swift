import Foundation
import SpectreCore

// Relevé de la batterie, vérifié sur un motif de synthèse dont on connaît les
// instants exacts. Aucun fichier, aucune fenêtre : uniquement du calcul.
//
// Le motif est le plus banal qui soit — grosse caisse sur 1 et 3, caisse claire
// sur 2 et 4, charleston sur les croches — parce que c'est celui sur lequel une
// erreur se voit : une caisse claire comptée comme une grosse caisse tombe sur un
// temps où il ne devrait rien y avoir.

let sampleRate = 48000.0
let bpm = 120.0
let beat = 60 / bpm
let bars = 8

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label) — \(detail)")
    if !ok { failures += 1 }
}

/// Générateur déterministe : la vérification doit rendre le même verdict à chaque
/// exécution, et sur chaque machine.
struct Noise {
    var state: UInt64 = 0x5DEECE66D
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
    }
}
var noise = Noise()

// Une demi-seconde de queue, de quoi laisser le dernier coup s'éteindre.
var signal = [Float](repeating: 0,
                     count: Int((Double(bars + 1) * 4 * beat + 0.5) * sampleRate))

func add(at time: Double, _ length: Double, _ sample: (Int, Float) -> Float) {
    let start = Int(time * sampleRate)
    let count = Int(length * sampleRate)
    for k in 0..<count where start + k < signal.count {
        signal[start + k] += sample(k, Float(k) / Float(count))
    }
}

/// Grosse caisse : une sinusoïde qui descend de 90 à 45 Hz en s'éteignant.
///
/// L'attaque monte en 3 ms au lieu de commencer d'un coup. Ce n'est pas une
/// coquetterie : un saut d'amplitude est un clic, donc un spectre plat, et un signal
/// d'essai qui claque dans toutes les bandes ne vérifie plus rien.
func kick(at time: Double, gain: Float = 1) {
    var phase = Float(0)
    let attack = Float(0.003 / 0.30)
    add(at: time, 0.30) { _, t in
        let f = 90 - 45 * t
        phase += 2 * .pi * f / Float(sampleRate)
        let rise = t < attack ? 0.5 * (1 - cos(.pi * t / attack)) : 1
        return gain * sin(phase) * rise * exp(-t * 5)
    }
}

/// Caisse claire : un corps vers 200 Hz, et du bruit tenu entre 200 Hz et 3 kHz —
/// une peau et un timbre, pas du bruit blanc. La bande compte : un bruit blanc
/// aurait autant d'énergie à 60 Hz qu'à 600, ce qu'aucune caisse claire ne fait, et
/// vérifier sur un signal qui n'existe pas ne prouverait rien.
func snare(at time: Double, gain: Float = 1) {
    var phase = Float(0)
    var last: Float = 0, lp1: Float = 0, lp2: Float = 0
    let a = Float(1 - exp(-2 * .pi * 3000 / sampleRate))
    add(at: time, 0.18) { _, t in
        phase += 2 * .pi * 200 / Float(sampleRate)
        let x = noise.next()
        let high = x - last
        last = x
        lp1 += a * (high - lp1)
        lp2 += a * (lp1 - lp2)
        return gain * (0.4 * sin(phase) + 4 * lp2) * exp(-t * 12)
    }
}

/// Charleston : du bruit dérivé deux fois — donc fortement penché vers l'aigu — et
/// qui s'éteint en quelques dizaines de millisecondes.
func hat(at time: Double, gain: Float = 1) {
    var last: Float = 0, before: Float = 0
    add(at: time, 0.08) { _, t in
        let x = noise.next()
        let d = x - 2 * last + before
        before = last
        last = x
        return gain * 0.3 * d * exp(-t * 6)
    }
}

var expectedKicks: [Double] = []
var expectedSnares: [Double] = []
var expectedHats: [Double] = []

// Une mesure de silence en tête : un fichier ne commence jamais par une attaque au
// tout premier échantillon, et une trame centrée sur l'origine n'a pas de trame
// précédente à qui se comparer.
let lead = 4 * beat

for bar in 0..<bars {
    let origin = lead + Double(bar) * 4 * beat
    for (index, position) in [0.0, 2.0].enumerated() {
        // Un coup sur deux joué moitié moins fort : de quoi vérifier que la force
        // rendue suit bien ce qu'on a joué.
        kick(at: origin + position * beat, gain: index == 1 && bar % 2 == 1 ? 0.4 : 1)
        expectedKicks.append(origin + position * beat)
    }
    for position in [1.0, 3.0] {
        snare(at: origin + position * beat)
        expectedSnares.append(origin + position * beat)
    }
    for eighth in 0..<8 {
        let t = origin + Double(eighth) * beat / 2
        hat(at: t, gain: eighth % 2 == 0 ? 1 : 0.6)
        expectedHats.append(t)
    }
}

print("=== Relevé de la batterie ===")
let started = Date()
let track = PercussionDetector.detect(samples: signal, sampleRate: sampleRate)
let elapsed = Date().timeIntervalSince(started)
let duration = Double(signal.count) / sampleRate
print(String(format: "  %d coups sur %.1f s de motif, relevés en %.3f s (×%.0f temps réel)",
             track.hits.count, duration, elapsed, duration / max(elapsed, 1e-6)))

/// Le coup de cette voie le plus proche d'un instant, s'il y en a un assez près.
func nearest(_ voice: DrumVoice, of time: Double, within tolerance: Double) -> DrumHit? {
    track.hits(of: voice).min { abs($0.time - time) < abs($1.time - time) }
        .flatMap { abs($0.time - time) <= tolerance ? $0 : nil }
}

/// Écart moyen et écart maximal d'une voie à ses instants attendus.
func report(_ voice: DrumVoice, expected: [Double], tolerance: Double = 0.03) {
    let found = track.hits(of: voice)
    check("\(voice.label) : nombre de coups",
          found.count == expected.count,
          "\(found.count) relevés pour \(expected.count) joués")

    var worst = 0.0
    var bias = 0.0
    var missing = 0
    for time in expected {
        guard let hit = nearest(voice, of: time, within: tolerance) else { missing += 1; continue }
        worst = max(worst, abs(hit.time - time))
        // Le biais est **signé** : c'est lui qui dit si la correction de fenêtre est
        // la bonne, là où une moyenne de valeurs absolues ne dirait que son ampleur.
        bias += hit.time - time
    }
    check("\(voice.label) : instants",
          missing == 0 && worst <= tolerance,
          missing > 0
            ? "\(missing) coup(s) manquant(s) à ±\(Int(tolerance * 1000)) ms"
            : String(format: "biais %+.1f ms, au pire %.1f ms",
                     bias / Double(expected.count) * 1000, worst * 1000))
}

print("\n=== Instants ===")
report(.kick, expected: expectedKicks)
report(.snare, expected: expectedSnares)
report(.cymbal, expected: expectedHats)

// --- Diaphonie ---------------------------------------------------------------
// La vraie difficulté n'est pas de trouver les coups mais de ne pas les compter
// deux fois : une caisse claire pleine de bruit large ne doit pas allumer aussi la
// ligne de la grosse caisse, sinon la lecture rythmique est fausse.
print("\n=== Diaphonie ===")
let falseKicks = expectedSnares.compactMap { nearest(.kick, of: $0, within: 0.03) }
check("aucune grosse caisse sur les temps de caisse claire",
      falseKicks.isEmpty,
      falseKicks.isEmpty ? "les 2 et 4 sont vides" : "\(falseKicks.count) coup(s) en trop")

let falseSnares = expectedKicks.compactMap { time -> DrumHit? in
    // Les croches de charleston tombent partout, y compris sur les temps de
    // grosse caisse : seule la ligne de caisse claire doit y rester vide.
    nearest(.snare, of: time, within: 0.03)
}
check("aucune caisse claire sur les temps de grosse caisse",
      falseSnares.isEmpty,
      falseSnares.isEmpty ? "les 1 et 3 sont vides" : "\(falseSnares.count) coup(s) en trop")

// --- Force -------------------------------------------------------------------
// Un coup joué moitié moins fort doit se dessiner plus pâle. C'est tout ce qu'on
// demande à cette grandeur : un ordre, pas une mesure.
print("\n=== Force ===")
var accented: [Double] = []
var soft: [Double] = []
for bar in 0..<bars where bar % 2 == 1 {
    soft.append(lead + Double(bar) * 4 * beat + 2 * beat)
}
for bar in 0..<bars where bar % 2 == 0 {
    accented.append(lead + Double(bar) * 4 * beat + 2 * beat)
}
func meanStrength(_ voice: DrumVoice, at times: [Double]) -> Double {
    let values = times.compactMap { nearest(voice, of: $0, within: 0.03)?.strength }
    guard !values.isEmpty else { return .nan }
    return values.reduce(0, +) / Double(values.count)
}
let strongKick = meanStrength(.kick, at: accented)
let softKick = meanStrength(.kick, at: soft)
check("un coup joué moitié moins fort se dessine plus pâle",
      softKick < strongKick * 0.8,
      String(format: "%.2f contre %.2f", softKick, strongKick))

check("les forces restent entre 0 et 1",
      track.hits.allSatisfy { $0.strength >= 0 && $0.strength <= 1 },
      "\(track.hits.count) coups")

// --- Silence -----------------------------------------------------------------
// Une piste vide ne doit rien produire : c'est ce qui arrive quand on demande la
// batterie d'un morceau qui n'en a pas, et un plancher de bruit régulier
// dessinerait alors une rythmique imaginaire.
print("\n=== Silence ===")
var quiet = Noise()
let hush = (0..<Int(8 * sampleRate)).map { _ in quiet.next() * 1e-4 }
let nothing = PercussionDetector.detect(samples: hush, sampleRate: sampleRate)
check("un souffle seul ne donne aucun coup", nothing.hits.isEmpty,
      "\(nothing.hits.count) coup(s)")

// --- Courbes -----------------------------------------------------------------
// Ce qui se dessine en fond des lignes doit tenir dans l'échelle des forces, et
// culminer là où les coups ont été trouvés.
print("\n=== Courbes ===")
check("une courbe par voie, à l'échelle des forces",
      track.curves.count == DrumVoice.allCases.count
        && track.curves.allSatisfy { $0.allSatisfy { $0 >= 0 && $0 <= 1 } },
      "\(track.curves.count) courbes")

let onBeat = track.level(.kick, from: lead, to: lead + 0.05)
let offBeat = track.level(.kick, from: lead + beat * 0.6, to: lead + beat * 0.9)
check("la courbe de grosse caisse culmine sur les coups",
      onBeat > offBeat * 2,
      String(format: "%.2f sur le coup, %.2f entre deux", onBeat, offBeat))

print()
if failures == 0 {
    print("Tout est conforme.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
