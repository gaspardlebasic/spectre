import Foundation

/// Pilote hors ligne du banc multi-résolution.
///
/// Trois choses deviennent possibles quand on n'analyse plus au fil de l'eau :
///
/// 1. **Le parallélisme.** Le signal est découpé en tranches analysées de front.
///    Chaque tranche est précédée d'un pré-roll — assez long pour que les filtres
///    de décimation aient oublié leur état initial et que toutes les fenêtres
///    soient pleines — dont les colonnes sont ensuite jetées. Les bancs de filtres
///    étant à réponse impulsionnelle *finie*, le résultat est identique, colonne
///    pour colonne, à celui d'une analyse d'un seul tenant. C'est vérifié par
///    `check.sh`, et c'est ce qui autorise à découper sans y regarder.
///
/// 2. **La compensation du retard.** Une colonne causale rend compte des N derniers
///    échantillons : elle décrit donc un instant antérieur d'une demi-fenêtre. Comme
///    la fenêtre double à chaque octave descendue, ce retard vaut 5 ms dans les aigus
///    et près d'une seconde dans les graves — une basse paraît systématiquement en
///    retard sur la caisse claire. Chaque ligne est ici décalée de son propre retard.
///
/// 3. **La queue du fichier.** On prolonge l'analyse par du silence, de quoi que la
///    compensation ait encore des colonnes à lire jusqu'au dernier échantillon.
enum OfflineAnalysis {

    /// Durée visée d'une tranche. La granularité réelle est arrondie à l'alignement
    /// imposé par la cascade de décimation.
    static let defaultChunkSeconds: Double = 30

    static func run(samples: [Float],
                    sampleRate: Double,
                    settings: AnalysisSettings,
                    chunkSeconds: Double = defaultChunkSeconds,
                    progress: ((Double) -> Void)? = nil) -> Spectrogram {

        let probe = Analyzer(sampleRate: sampleRate, settings: settings)
        let layout = probe.layout
        let bins = layout.binCount
        let hop = probe.hopSamples
        let hopSeconds = Double(hop) / sampleRate

        guard bins > 0, samples.count >= hop else {
            return Spectrogram(layout: layout, columnCount: 0,
                               secondsPerColumn: hopSeconds, values: [])
        }

        // Décalage à appliquer à chaque ligne, en colonnes.
        // La colonne brute c décrit l'instant ((c+1)·hop)/fs − W/2 ; on veut que la
        // colonne de sortie t décrive (t+½)·hop/fs, d'où c = t + W/(2·hop) − ½.
        let shifts: [Int] = probe.binDelaySeconds.map {
            max(0, Int(($0 / hopSeconds - 0.5).rounded()))
        }
        let maxShift = shifts.max() ?? 0

        let outputColumns = samples.count / hop
        let rawColumns = outputColumns + maxShift

        // Alignement des tranches : multiple du saut (pour que les colonnes tombent
        // en phase) *et* de 2^(étages−1) (pour que la décimation en cascade attaque
        // sur la même parité d'échantillons qu'une analyse d'un seul tenant).
        let decimationStride = 1 << max(probe.stageCount - 1, 0)
        let alignment = lcm(hop, decimationStride)

        // Pré-roll : de quoi remplir la plus longue fenêtre *et* purger la mémoire
        // des filtres RIF (96 prises à chaque étage, ramenées au rythme d'entrée).
        let warmup = Int(probe.maxWindowSeconds * sampleRate) + Decimator.tapCount * decimationStride * 2
        let preroll = roundUp(warmup, to: alignment)
        let prerollColumns = preroll / hop

        let chunkSamples = max(alignment, roundUp(Int(chunkSeconds * sampleRate), to: alignment))
        let chunkColumns = chunkSamples / hop
        let chunkCount = max(1, (rawColumns + chunkColumns - 1) / chunkColumns)

        var raw = [Float](repeating: -200, count: rawColumns * bins)
        let done = Counter()

        raw.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            let work = { (j: Int) in
                let firstColumn = j * chunkColumns
                let lastColumn = min(firstColumn + chunkColumns, rawColumns)
                guard firstColumn < lastColumn else { return }

                let analyzer = Analyzer(sampleRate: sampleRate, settings: settings)
                // En début de fichier le pré-roll déborde avant l'échantillon 0 : on
                // l'alimente en silence, ce qui laisse l'analyseur dans l'état exact
                // où une analyse partant de 0 le trouverait.
                let start = firstColumn * hop - preroll
                let end = lastColumn * hop

                var emitted = 0
                var target = firstColumn
                feed(samples, from: start, to: end, into: analyzer) { column in
                    defer { emitted += 1 }
                    guard emitted >= prerollColumns, target < lastColumn else { return }
                    (base + target * bins).update(from: column.baseAddress!, count: bins)
                    target += 1
                }
                if let progress {
                    let n = done.increment()
                    progress(Double(n) / Double(chunkCount))
                }
            }
            if chunkCount > 1 {
                DispatchQueue.concurrentPerform(iterations: chunkCount, execute: work)
            } else {
                work(0)
            }
        }

        // Recalage : chaque ligne remonte de son propre retard. On lit toujours plus
        // loin qu'on n'écrit, donc la substitution en place est sûre.
        if maxShift > 0 {
            raw.withUnsafeMutableBufferPointer { m in
                let p = m.baseAddress!
                for t in 0..<outputColumns {
                    let dst = p + t * bins
                    for i in 0..<bins where shifts[i] > 0 {
                        dst[i] = p[(t + shifts[i]) * bins + i]
                    }
                }
            }
        }

        return Spectrogram(layout: layout,
                           columnCount: outputColumns,
                           secondsPerColumn: hopSeconds,
                           values: raw)
    }

    /// Alimente l'analyseur avec `samples[start..<end]`, en complétant par du silence
    /// ce qui déborde du fichier (avant 0 comme après la fin).
    ///
    /// Les blocs sont des multiples entiers du saut : l'analyseur découpe alors le
    /// signal exactement de la même façon quel que soit l'endroit où la tranche
    /// commence, donc les filtres reçoivent partout les mêmes longueurs et le
    /// résultat est identique **au bit près** à celui d'une analyse d'un seul tenant.
    private static func feed(_ samples: [Float], from start: Int, to end: Int,
                             into analyzer: Analyzer,
                             emit: (UnsafeBufferPointer<Float>) -> Void) {
        let hop = analyzer.hopSamples
        let blockSize = max(hop, (1 << 14) / hop * hop)
        var silence = [Float](repeating: 0, count: blockSize)
        var position = start
        samples.withUnsafeBufferPointer { src in
            while position < end {
                let stop = min(position + blockSize, end)
                if position >= 0 && stop <= samples.count {
                    analyzer.process(UnsafeBufferPointer(start: src.baseAddress! + position,
                                                         count: stop - position), emit: emit)
                } else {
                    // Bloc à cheval sur une bordure : on le compose échantillon par
                    // échantillon, ce qui n'arrive qu'au tout début et à la toute fin.
                    let count = stop - position
                    for k in 0..<count {
                        let index = position + k
                        silence[k] = (index >= 0 && index < samples.count) ? src[index] : 0
                    }
                    silence.withUnsafeBufferPointer {
                        analyzer.process(UnsafeBufferPointer(start: $0.baseAddress!, count: count),
                                         emit: emit)
                    }
                }
                position = stop
            }
        }
    }

    private static func roundUp(_ value: Int, to multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        return (value + multiple - 1) / multiple * multiple
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        guard a > 0, b > 0 else { return max(a, b, 1) }
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return a / x * b
    }
}

/// Compteur partagé entre les tranches, pour l'avancement.
private final class Counter {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
