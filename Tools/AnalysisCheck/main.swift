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

print("")
if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
