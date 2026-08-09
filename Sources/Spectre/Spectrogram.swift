import Foundation

/// Matrice temps × fréquence, en dB, calculée une fois pour toutes sur un fichier.
///
/// Les valeurs sont stockées **par colonne** : `values[colonne * binCount + ligne]`.
/// Une colonne est donc contiguë en mémoire, ce qui permet de la téléverser
/// telle quelle vers le GPU et de découper la matrice en tuiles sans recopie.
///
/// Contrairement au spectrogramme temps réel, chaque valeur est ici recalée sur
/// l'instant qu'elle décrit réellement : le retard d'une demi-fenêtre, qui varie
/// d'une octave à l'autre, a été compensé à l'analyse.
struct Spectrogram {
    let layout: BinLayout
    /// Nombre de colonnes réellement exploitables.
    let columnCount: Int
    let secondsPerColumn: Double
    /// Peut contenir quelques colonnes de plus que `columnCount` (résidu de la
    /// compensation de retard) : ne jamais s'en servir pour itérer.
    let values: [Float]

    var binCount: Int { layout.binCount }
    var duration: Double { Double(columnCount) * secondsPerColumn }

    /// Instant décrit par une colonne (son milieu).
    func time(ofColumn c: Int) -> Double { (Double(c) + 0.5) * secondsPerColumn }

    /// Colonne (fractionnaire) correspondant à un instant.
    func column(atTime t: Double) -> Double { t / secondsPerColumn - 0.5 }

    func value(column c: Int, bin i: Int) -> Float {
        guard c >= 0, c < columnCount, i >= 0, i < binCount else { return -200 }
        return values[c * binCount + i]
    }

    /// Spectre moyen (en dB) sur un intervalle de temps, ligne par ligne.
    /// Moyenne faite en puissance, seule façon correcte d'additionner des dB.
    func averageSpectrum(from t0: Double, to t1: Double) -> [Float] {
        let c0 = max(0, Int(column(atTime: min(t0, t1)).rounded()))
        let c1 = min(columnCount - 1, Int(column(atTime: max(t0, t1)).rounded()))
        guard c0 <= c1 else { return [Float](repeating: -200, count: binCount) }
        var acc = [Double](repeating: 0, count: binCount)
        for c in c0...c1 {
            for i in 0..<binCount {
                acc[i] += pow(10, Double(values[c * binCount + i]) / 10)
            }
        }
        let n = Double(c1 - c0 + 1)
        return acc.map { Float(10 * log10(max($0 / n, 1e-20))) }
    }

    static let empty = Spectrogram(layout: BinLayout(), columnCount: 0,
                                   secondsPerColumn: 0.01, values: [])
}
