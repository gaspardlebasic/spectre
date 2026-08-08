import Foundation

// Vérification de la chaîne d'analyse hors ligne sur des signaux de synthèse.
// Aucun fichier, aucune fenêtre : uniquement du calcul, donc reproductible.

let sampleRate = 48000.0

/// Somme de sinusoïdes, chacune limitée à un intervalle de temps.
func synth(duration: Double,
           _ parts: [(f: Double, amplitude: Double, from: Double, to: Double)]) -> [Float] {
    let n = Int(duration * sampleRate)
    var x = [Float](repeating: 0, count: n)
    for p in parts {
        let i0 = max(0, Int(p.from * sampleRate))
        let i1 = min(n, Int(p.to * sampleRate))
        guard i0 < i1 else { continue }
        let w = 2 * Double.pi * p.f / sampleRate
        for i in i0..<i1 {
            x[i] += Float(p.amplitude * sin(w * Double(i - i0)))
        }
    }
    return x
}

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label) — \(detail)")
    if !ok { failures += 1 }
}

/// Ligne dont la fréquence est la plus proche de `f`.
func bin(of f: Double, _ s: Spectrogram) -> Int {
    min(max(Int(s.layout.bin(of: f).rounded()), 0), s.binCount - 1)
}

/// Niveau maximal atteint par une ligne sur toute la durée.
func peak(_ s: Spectrogram, bin i: Int) -> Float {
    var m = Float(-400)
    for c in 0..<s.columnCount { m = max(m, s.value(column: c, bin: i)) }
    return m
}

/// Instant où la ligne franchit pour la première fois `peak − margin`.
func onset(_ s: Spectrogram, bin i: Int, margin: Float = 6) -> Double {
    let threshold = peak(s, bin: i) - margin
    for c in 0..<s.columnCount where s.value(column: c, bin: i) >= threshold {
        return s.time(ofColumn: c)
    }
    return .nan
}

let settings = AnalysisSettings()

// Deux bouffées rigoureusement simultanées, trois octaves et demie d'écart, plus
// un La₃ isolé pour contrôler le niveau restitué.
let signal = synth(duration: 8, [
    (f: 440, amplitude: 1.0, from: 0.4, to: 1.4),
    (f: 110, amplitude: 0.5, from: 2.5, to: 4.5),
    (f: 1760, amplitude: 0.5, from: 2.5, to: 4.5),
])

print("=== Analyse hors ligne ===")
let started = Date()
let spectrogram = OfflineAnalysis.run(samples: signal, sampleRate: sampleRate, settings: settings)
let elapsed = Date().timeIntervalSince(started)
print(String(format: "  %d colonnes × %d lignes, %.0f Hz…%.0f Hz, %.2f s (×%.0f temps réel)",
             spectrogram.columnCount, spectrogram.binCount,
             spectrogram.layout.minFrequency, spectrogram.layout.maxFrequency,
             elapsed, 8 / elapsed))

check("durée",
      abs(spectrogram.duration - 8) < 0.05,
      String(format: "%.3f s pour 8 s de signal", spectrogram.duration))

// --- Niveau -----------------------------------------------------------------
// Une sinusoïde d'amplitude 1 doit culminer à 0 dB, quelle que soit la fréquence
// et donc quel que soit l'étage du banc qui l'a analysée.
print("\n=== Niveau ===")
let levelAt440 = peak(spectrogram, bin: bin(of: 440, spectrogram))
check("La₃ d'amplitude 1", abs(levelAt440) < 1.5,
      String(format: "%.2f dB (attendu 0)", levelAt440))

// --- Justesse ---------------------------------------------------------------
print("\n=== Justesse ===")
for (frequency, name) in [(110.0, "La₁"), (440.0, "La₃"), (1760.0, "La₅")] {
    let center = bin(of: frequency, spectrogram)
    let window = max(0, center - 6)...min(spectrogram.binCount - 1, center + 6)
    var best = center
    var bestValue = Float(-400)
    for i in window where peak(spectrogram, bin: i) > bestValue {
        bestValue = peak(spectrogram, bin: i)
        best = i
    }
    let found = spectrogram.layout.frequency(atBin: Double(best))
    let cents = 1200 * log2(found / frequency)
    check("\(name) tombe au bon endroit", abs(cents) < 20,
          String(format: "%.1f Hz au lieu de %.1f (%+.0f cents)", found, frequency, cents))
}

// --- Recalage temporel ------------------------------------------------------
// C'est le point du passage hors ligne : les deux bouffées démarrent au même
// instant, elles doivent le montrer, alors que leurs fenêtres d'analyse durent
// respectivement ~1,4 s et ~11 ms.
print("\n=== Recalage temporel ===")
let low = onset(spectrogram, bin: bin(of: 110, spectrogram))
let high = onset(spectrogram, bin: bin(of: 1760, spectrogram))
let probe = Analyzer(sampleRate: sampleRate, settings: settings)
let uncompensated = probe.windowSeconds(at: 110) / 2

check("attaque à 110 Hz", abs(low - 2.5) < 0.12,
      String(format: "%.3f s pour 2,500 s (sans compensation : %.3f s)",
             low, 2.5 + uncompensated))
check("attaque à 1760 Hz", abs(high - 2.5) < 0.05,
      String(format: "%.3f s pour 2,500 s", high))
check("les deux bandes s'accordent", abs(low - high) < 0.12,
      String(format: "%.0f ms d'écart (fenêtres de %.0f ms et %.0f ms)",
             abs(low - high) * 1000,
             probe.windowSeconds(at: 110) * 1000, probe.windowSeconds(at: 1760) * 1000))

// --- Indépendance au découpage ---------------------------------------------
// Le pré-roll doit rendre chaque tranche indépendante de ses voisines : les
// filtres du banc étant à réponse finie, l'égalité doit être *exacte*.
print("\n=== Découpage en tranches ===")
let sliced = OfflineAnalysis.run(samples: signal, sampleRate: sampleRate,
                                 settings: settings, chunkSeconds: 0.7)
var worst = Float(0)
var worstAt = (column: 0, bin: 0)
if sliced.columnCount == spectrogram.columnCount {
    for c in 0..<spectrogram.columnCount {
        for i in 0..<spectrogram.binCount {
            let d = abs(spectrogram.value(column: c, bin: i) - sliced.value(column: c, bin: i))
            if d > worst { worst = d; worstAt = (c, i) }
        }
    }
}
check("même nombre de colonnes", sliced.columnCount == spectrogram.columnCount,
      "\(sliced.columnCount) contre \(spectrogram.columnCount)")
check("valeurs identiques", worst == 0,
      worst == 0 ? "au bit près"
                 : String(format: "écart max %.4f dB (colonne %d, ligne %d)",
                          worst, worstAt.column, worstAt.bin))

// --- Silence ----------------------------------------------------------------
print("\n=== Plancher ===")
// Mesuré assez loin de la dernière note pour que même la fenêtre de 2,7 s des
// graves n'en contienne plus rien : sinon on testerait la physique de l'analyse,
// pas le code.
let quiet = spectrogram.averageSpectrum(from: 6.6, to: 7.4).max() ?? 0
check("le silence reste silencieux", quiet < -120,
      String(format: "%.0f dB, 2 s après la dernière note", quiet))

// --- Tempo ------------------------------------------------------------------
// Un click-track : attaques nettes, tempo connu, accent sur le premier temps.
print("\n=== Tempo ===")
let bpm = 132.0
let beat = 60 / bpm
let firstClick = 0.37
let beatsPerBar = 4

func clickTrack(duration: Double) -> [Float] {
    let n = Int(duration * sampleRate)
    var x = [Float](repeating: 0, count: n)
    var seed: UInt64 = 12345
    func noise() -> Float {          // générateur déterministe : test reproductible
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
    }
    var index = 0
    var time = firstClick
    while time < duration {
        let accent: Float = index % beatsPerBar == 0 ? 1.0 : 0.55
        let start = Int(time * sampleRate)
        let length = Int(0.04 * sampleRate)
        for k in 0..<length where start + k < n {
            x[start + k] += accent * noise() * exp(-Float(k) / Float(length) * 5)
        }
        index += 1
        time += beat
    }
    return x
}

let clicks = OfflineAnalysis.run(samples: clickTrack(duration: 24),
                                 sampleRate: sampleRate, settings: settings)
if let grid = TempoEstimator.estimate(clicks, beatsPerBar: beatsPerBar) {
    check("tempo retrouvé", abs(grid.bpm - bpm) < 1,
          String(format: "%.2f BPM pour %.0f", grid.bpm, bpm))

    // Phase : l'origine doit tomber sur un temps, à une fraction de temps près.
    let offset = (grid.origin - firstClick).truncatingRemainder(dividingBy: grid.beatSeconds)
    let phaseError = min(abs(offset), grid.beatSeconds - abs(offset))
    check("temps bien placés", phaseError < 0.04,
          String(format: "%.0f ms d'écart au click", phaseError * 1000))

    // Temps fort : l'origine doit tomber sur un *premier* temps, pas n'importe lequel.
    let barOffset = (grid.origin - firstClick).truncatingRemainder(dividingBy: grid.barSeconds)
    let barError = min(abs(barOffset), grid.barSeconds - abs(barOffset))
    check("premier temps sur l'accent", barError < 0.04,
          String(format: "%.0f ms d'écart à la mesure", barError * 1000))

    check("estimation annoncée comme sûre", grid.confidence > 2.2,
          String(format: "confiance %.1f", grid.confidence))
} else {
    check("tempo retrouvé", false, "aucune estimation")
}

// --- Magnétisme -------------------------------------------------------------
print("\n=== Magnétisme du curseur ===")
var layout = BinLayout()
layout.binCount = 200
layout.minFrequency = 27.5
layout.maxFrequency = 27.5 * pow(2, 200.0 / 36)
layout.binsPerOctave = 36
layout.sampleRate = 48000

let ridgeBin = 120
let faintBin = 96
var matrix = [Float](repeating: -200, count: 400 * layout.binCount)
for c in 0..<400 {
    // Une raie franche, et une raie pâle plus proche du curseur d'essai.
    matrix[c * layout.binCount + ridgeBin] = -30
    matrix[c * layout.binCount + ridgeBin - 1] = -40
    matrix[c * layout.binCount + ridgeBin + 1] = -38
    matrix[c * layout.binCount + faintBin] = -88
    matrix[c * layout.binCount + faintBin - 1] = -94
    matrix[c * layout.binCount + faintBin + 1] = -94
}
let scene = Spectrogram(layout: layout, columnCount: 400,
                        secondsPerColumn: 0.01, values: matrix)

let size = CGSize(width: 600, height: 400)
var view = Viewport.fitting(columns: 400, bins: layout.binCount,
                            size: (Double(size.width), Double(size.height)))
var settingsDisplay = DisplaySettings()

// Curseur posé entre les deux raies, plus près de la pâle.
let ridgeY = view.point(ofBin: Double(ridgeBin) + 0.5, height: Double(size.height))
let faintY = view.point(ofBin: Double(faintBin) + 0.5, height: Double(size.height))
let cursor = CGPoint(x: 300, y: (ridgeY + faintY) / 2 + (faintY - ridgeY) * 0.12)

if let target = Snapping.nearest(to: cursor, in: scene, viewport: view,
                                 display: settingsDisplay, viewSize: size) {
    let expected = layout.frequency(atBin: Double(ridgeBin))
    let cents = 1200 * log2(target.frequency / expected)
    check("la raie franche l'emporte sur la raie pâle plus proche", abs(cents) < 20,
          String(format: "%.1f Hz (%+.0f cents de la raie visée)", target.frequency, cents))
} else {
    check("la raie franche l'emporte sur la raie pâle plus proche", false, "rien accroché")
}

// Le seuil de noir de l'utilisateur commande : au-dessus des raies, plus rien
// n'attire — c'est la même formule que celle du shader qui décide.
settingsDisplay.floorDb = -20
settingsDisplay.ceilingDb = 0
let inTheDark = Snapping.nearest(to: cursor, in: scene, viewport: view,
                                 display: settingsDisplay, viewSize: size)
check("une région rendue noire n'attire rien", inTheDark == nil,
      inTheDark == nil ? "rien accroché, comme attendu"
                       : String(format: "%.1f Hz accrochés à tort", inTheDark!.frequency))

// Loin de toute raie, on ne s'aimante pas sur quelque chose d'invisible.
settingsDisplay = DisplaySettings()
let farAway = Snapping.nearest(to: CGPoint(x: 300, y: 20), in: scene, viewport: view,
                               display: settingsDisplay, viewSize: size)
check("hors de portée, pas d'aimantation", farAway == nil,
      farAway == nil ? "rien accroché" : "accroché à tort")

print("")
if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
