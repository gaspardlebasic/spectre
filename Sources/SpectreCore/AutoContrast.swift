import Foundation

/// Réglage automatique de l'affichage à partir du contenu du morceau.
///
/// Les valeurs par défaut — noir à −95 dB, clair à −25, pente de 3 dB par octave —
/// sont un compromis pour un signal quelconque. Un enregistrement réel s'en écarte
/// des deux façons possibles : son niveau général n'est pas celui-là, et surtout
/// **sa pente ne l'est pas**. Un piano perd une quinzaine de dB par octave, un mix
/// pop bien moins ; avec une pente unique, ou bien les basses sont blanches et
/// écrasées, ou bien les aigus sont noirs.
///
/// La méthode tient en deux temps :
///
/// 1. pour chaque ligne, deux niveaux — celui du fond (médiane dans le temps) et
///    celui d'une raie franche (95ᵉ centile) ; la pente est ajustée sur les
///    niveaux de raies, de sorte qu'une note grave et une note aiguë de même
///    importance musicale ressortent pareillement ;
/// 2. une fois cette pente appliquée, le noir se pose un peu au-dessus du fond et
///    le clair un peu au-dessus des raies.
///
/// Tout se lit dans la matrice déjà calculée : aucune réanalyse.
public enum AutoContrast {
    /// Niveau atteint quand une note est présente.
    private static let raieQuantile = 0.95
    /// Niveau du fond : ce que la ligne vaut la moitié du temps.
    private static let backgroundQuantile = 0.5
    /// Le noir se pose au-dessus du fond, le clair au-dessus des raies.
    private static let floorMargin = 4.0
    private static let ceilingMargin = 10.0
    /// Une ligne ne compte que si elle voit passer quelque chose : sa raie doit
    /// dépasser son propre fond d'au moins cela.
    ///
    /// C'est le bon critère, et non un seuil absolu : au-dessus de la coupure d'un
    /// mp3, ou dans une bande qu'aucun instrument n'occupe, le 95ᵉ centile vaut le
    /// bruit et pencherait la droite pour rien. Une ligne qui n'a rien à montrer
    /// montre autant en haut qu'en bas de l'échelle.
    private static let liveDepth = 8.0
    /// Bornes de l'histogramme, en dB, et sa finesse.
    private static let lowestDb = -160.0
    private static let step = 0.5
    private static let buckets = 380

    /// Nombre maximal de colonnes lues : au-delà, l'estimation ne s'affine plus.
    private static let maxColumns = 4000

    /// Réglages déduits d'une portion de la matrice — tout le morceau par défaut,
    /// ou seulement ce qu'on a sous les yeux.
    public static func settings(basedOn current: DisplaySettings,
                         in spectrogram: Spectrogram,
                         columns: Range<Int>? = nil,
                         bins: Range<Int>? = nil) -> DisplaySettings? {
        let layout = spectrogram.layout
        let allColumns = 0..<spectrogram.columnCount
        let allBins = 0..<spectrogram.binCount
        let columnRange = (columns ?? allColumns).clamped(to: allColumns)
        let binRange = (bins ?? allBins).clamped(to: allBins)
        guard columnRange.count > 1, binRange.count > 4 else { return nil }

        let stride = max(1, columnRange.count / maxColumns)
        var histograms = [Int32](repeating: 0, count: binRange.count * buckets)
        var sampled = 0

        spectrogram.values.withUnsafeBufferPointer { values in
            histograms.withUnsafeMutableBufferPointer { h in
                var column = columnRange.lowerBound
                while column < columnRange.upperBound {
                    defer { column += stride }
                    sampled += 1
                    let base = column * layout.binCount
                    for (row, bin) in binRange.enumerated() {
                        let db = Double(values[base + bin])
                        let bucket = Int((db - lowestDb) / step)
                        h[row * buckets + min(max(bucket, 0), buckets - 1)] += 1
                    }
                }
            }
        }
        guard sampled > 1 else { return nil }

        // Deux niveaux par ligne, lus dans son histogramme.
        var raies = [Double](repeating: 0, count: binRange.count)
        var background = [Double](repeating: 0, count: binRange.count)
        for row in 0..<binRange.count {
            let slice = histograms[(row * buckets)..<((row + 1) * buckets)]
            raies[row] = quantile(slice, raieQuantile, total: sampled)
            background[row] = quantile(slice, backgroundQuantile, total: sampled)
        }

        // Pente : régression des niveaux de raies sur les octaves, en écartant les
        // bandes où il ne se passe rien.
        func isLive(_ row: Int) -> Bool { raies[row] - background[row] > liveDepth }
        var sumWeight = 0.0, sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for (row, bin) in binRange.enumerated() where isLive(row) {
            let x = octave(ofBin: bin, layout)
            let y = raies[row]
            sumWeight += 1; sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
        }
        guard sumWeight >= 4 else { return nil }
        let denominator = sumWeight * sumXX - sumX * sumX
        let slope = abs(denominator) > 1e-9 ? (sumWeight * sumXY - sumX * sumY) / denominator : 0
        // La pente d'affichage compense celle du signal : après elle, une raie vaut
        // le même niveau à toutes les octaves.
        let tilt = min(max(-slope, -6), 14)

        // Niveaux typiques une fois la pente appliquée.
        var flatRaies: [Double] = []
        var flatBackground: [Double] = []
        for (row, bin) in binRange.enumerated() where isLive(row) {
            let shift = tilt * octave(ofBin: bin, layout)
            flatRaies.append(raies[row] + shift)
            flatBackground.append(background[row] + shift)
        }
        guard let noise = median(flatBackground), let signal = median(flatRaies) else { return nil }

        var settings = current
        settings.tiltDbPerOctave = tilt
        settings.floorDb = noise + floorMargin
        settings.ceilingDb = max(signal + ceilingMargin, settings.floorDb + 18)
        // Un morceau presque uniforme (silence, bruit blanc) ne doit pas produire
        // une plage absurde qui rendrait les curseurs inutilisables.
        settings.ceilingDb = min(settings.ceilingDb, settings.floorDb + 80)
        return settings
    }

    private static func octave(ofBin bin: Int, _ layout: BinLayout) -> Double {
        log2(layout.minFrequency / 1000) + Double(bin) / max(layout.binsPerOctave, 1e-3)
    }

    /// Centile lu dans un histogramme cumulé, interpolé dans son godet.
    private static func quantile(_ histogram: ArraySlice<Int32>, _ fraction: Double,
                                 total: Int) -> Double {
        let target = Double(total) * fraction
        var seen = 0.0
        for (index, count) in histogram.enumerated() {
            let next = seen + Double(count)
            if next >= target, count > 0 {
                let within = (target - seen) / Double(count)
                return lowestDb + (Double(index) + within) * step
            }
            seen = next
        }
        return lowestDb + Double(histogram.count) * step
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
