import Accelerate
import Foundation

// MARK: - Réglages d'analyse

/// Paramètres qui déterminent la structure de l'analyse (banc multi-résolution + axe
/// des fréquences). Toute modification invalide le spectrogramme calculé.
struct AnalysisSettings: Equatable, Codable {
    /// Taille de FFT utilisée par chaque étage du banc multi-résolution.
    /// Chaque étage couvre une octave, donc le facteur de qualité vaut
    /// Q ≈ 0.1·N (bas de bande) à 0.2·N (haut de bande).
    var fftSize: Int = 512

    /// Taille de FFT utilisée quand le mode multi-résolution est désactivé
    /// (une seule fenêtre, constante en secondes, pour tout le spectre).
    var monoFFTSize: Int = 8192

    /// Analyse multi-résolution : la fenêtre s'allonge quand la fréquence baisse.
    var multiResolution: Bool = true

    /// Nombre de lignes de sortie par octave (résolution verticale de l'image).
    var binsPerOctave: Int = 36

    var minFrequency: Double = 25
    var maxFrequency: Double = 18000

    /// Nombre de colonnes analysées par seconde (résolution horizontale).
    var columnsPerSecond: Double = 100

    /// Constante de temps du lissage temporel, en secondes (0 = aucun lissage).
    /// Hors ligne on n'en veut normalement pas : rien n'oblige à masquer le bruit.
    var smoothingSeconds: Double = 0

    var layoutKey: [Int] {
        [fftSize, monoFFTSize, multiResolution ? 1 : 0, binsPerOctave,
         Int(minFrequency * 100), Int(maxFrequency * 100),
         Int(columnsPerSecond * 100), Int(smoothingSeconds * 1000)]
    }
}

// MARK: - Géométrie de l'axe fréquentiel

struct BinLayout: Equatable {
    var binCount: Int = 0
    var minFrequency: Double = 25
    var maxFrequency: Double = 18000
    var binsPerOctave: Double = 36
    var sampleRate: Double = 48000
    /// Identifiant de génération : change dès que la géométrie change.
    var key: Int = 0

    var totalOctaves: Double { log2(maxFrequency / minFrequency) }

    func frequency(atBin i: Double) -> Double {
        minFrequency * pow(2, i / binsPerOctave)
    }

    /// Indice de bin (fractionnaire) d'une fréquence.
    func bin(of frequency: Double) -> Double {
        log2(frequency / minFrequency) * binsPerOctave
    }

    /// Position verticale normalisée (0 = grave, 1 = aigu) d'une fréquence.
    func position(of frequency: Double) -> Double {
        log2(frequency / minFrequency) / max(totalOctaves, 1e-9)
    }
}

// MARK: - FFT réelle

private final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var scale: Float          // 1 / (Σw)²  → une sinusoïde d'amplitude 1 donne 0 dB
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]

    init?(n: Int) {
        guard n >= 8, (n & (n - 1)) == 0 else { return nil }
        self.n = n
        self.log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
        // Fenêtre de Hann périodique.
        window = (0..<n).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(n))) }
        let sum = window.reduce(0, +)
        scale = 1 / (sum * sum)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `out` doit contenir n/2 + 1 échantillons ; on y écrit la densité de puissance
    /// normalisée (amplitude² d'une sinusoïde pure au sommet de son pic).
    func power(of input: [Float], into out: inout [Float]) {
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let half = n / 2
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Format « packed » : realp[0] = DC, imagp[0] = Nyquist.
                let dc = rp[0], nyq = ip[0]
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_zvmags(&split, 1, o.baseAddress!, 1, vDSP_Length(half))
                    o[0] = dc * dc
                    o[half] = nyq * nyq
                }
            }
        }
        var s = scale
        out.withUnsafeMutableBufferPointer { o in
            vDSP_vsmul(o.baseAddress!, 1, &s, o.baseAddress!, 1, vDSP_Length(half + 1))
        }
    }
}

// MARK: - Décimateur /2

/// Filtre passe-bas RIF + décimation par 2. Le gabarit (passante jusqu'à 0.2·fs,
/// coupée à partir de 0.3·fs) garantit qu'aucun repliement ne tombe dans la bande
/// réellement exploitée par l'étage suivant.
final class Decimator {
    private let taps: [Float]
    private var history: [Float]
    private var buffer: [Float] = []
    private var output: [Float] = []

    /// Nombre d'échantillons d'entrée que le filtre met à « oublier » son état initial.
    static let tapCount = 96

    init(tapCount: Int = Decimator.tapCount) {
        let m = tapCount
        let fc: Double = 0.25   // fréquence de coupure normalisée (×fs)
        var h = [Float](repeating: 0, count: m)
        var sum: Double = 0
        for i in 0..<m {
            let t = Double(i) - Double(m - 1) / 2
            let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
            // Fenêtre de Blackman-Harris
            let x = 2 * Double.pi * Double(i) / Double(m - 1)
            let w = 0.35875 - 0.48829 * cos(x) + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x)
            let v = sinc * w
            h[i] = Float(v)
            sum += v
        }
        var g = Float(1 / sum)
        vDSP_vsmul(h, 1, &g, &h, 1, vDSP_Length(m))
        taps = h
        history = [Float](repeating: 0, count: m - 1)
        buffer.reserveCapacity(m + 4096)
        output.reserveCapacity(2048)
    }

    func process(_ x: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: history)
        buffer.append(contentsOf: x)

        let p = taps.count
        let count = buffer.count >= p ? (buffer.count - p) / 2 + 1 : 0
        output.removeAll(keepingCapacity: true)
        if count > 0 {
            output.append(contentsOf: repeatElement(0, count: count))
            output.withUnsafeMutableBufferPointer { o in
                vDSP_desamp(buffer, 2, taps, o.baseAddress!, vDSP_Length(count), vDSP_Length(p))
            }
        }
        let consumed = 2 * count
        history.removeAll(keepingCapacity: true)
        history.append(contentsOf: buffer[consumed...])
        if count > 0 { output.withUnsafeBufferPointer(body) }
    }
}

// MARK: - Étage du banc

private final class Stage {
    let sampleRate: Double
    let n: Int
    private var ring: [Float]
    private var writeIndex = 0
    private var linear: [Float]
    private let fft: RealFFT
    var power: [Float]          // n/2 + 1
    var pendingSamples = 0

    init?(sampleRate: Double, n: Int) {
        guard let f = RealFFT(n: n) else { return nil }
        self.fft = f
        self.sampleRate = sampleRate
        self.n = n
        ring = [Float](repeating: 0, count: n)
        linear = [Float](repeating: 0, count: n)
        power = [Float](repeating: 0, count: n / 2 + 1)
    }

    func append(_ x: UnsafeBufferPointer<Float>) {
        guard let base = x.baseAddress, !x.isEmpty else { return }
        var offset = 0
        var remaining = x.count
        if remaining >= n {           // on ne garde que la fin
            offset = remaining - n
            remaining = n
        }
        ring.withUnsafeMutableBufferPointer { r in
            var w = writeIndex
            var left = remaining
            var src = base + offset
            while left > 0 {
                let chunk = min(left, n - w)
                (r.baseAddress! + w).update(from: src, count: chunk)
                w = (w + chunk) % n
                src += chunk
                left -= chunk
            }
            writeIndex = w
        }
        pendingSamples += x.count
    }

    /// Recalcule le spectre à partir des n derniers échantillons.
    func refresh() {
        linear.withUnsafeMutableBufferPointer { l in
            ring.withUnsafeBufferPointer { r in
                let tail = n - writeIndex
                (l.baseAddress!).update(from: r.baseAddress! + writeIndex, count: tail)
                if writeIndex > 0 {
                    (l.baseAddress! + tail).update(from: r.baseAddress!, count: writeIndex)
                }
            }
        }
        fft.power(of: linear, into: &power)
        pendingSamples = 0
    }
}

// MARK: - Analyseur multi-résolution

/// Banc d'étages en cascade : l'étage 0 travaille à la fréquence d'échantillonnage
/// d'entrée, chaque étage suivant sur un signal décimé par 2. Un étage de rang k
/// couvre l'octave [0.1·fs_k, 0.2·fs_k[ ; l'étage 0 couvre en plus tout ce qui est
/// au-dessus, jusqu'à Nyquist.
///
/// À taille de FFT constante, la fenêtre d'analyse dure N/fs_k secondes : elle double
/// à chaque octave descendue. On obtient donc un nombre de périodes analysées
/// constant (Q ≈ 0.1·N … 0.2·N), soit une bonne résolution dans les graves et une
/// excellente résolution temporelle dans les aigus.
///
/// L'analyseur reste strictement causal : une colonne rend compte des N derniers
/// échantillons reçus, donc d'un instant antérieur d'une demi-fenêtre. Hors ligne,
/// `binDelaySeconds` permet d'annuler ce décalage — voir `OfflineAnalysis`.
final class Analyzer {
    struct BinMapping {
        var stage: Int32 = 0
        var lo: Int32 = 0
        var hi: Int32 = 0
        var frac: Float = 0
        var useMax: Bool = false
    }

    let settings: AnalysisSettings
    let layout: BinLayout
    private var stages: [Stage] = []
    private var decimators: [Decimator] = []
    private var mapping: [BinMapping] = []
    private var smoothed: [Float]
    private var column: [Float]
    private var alpha: Float = 0
    let hopSamples: Int
    private var samplesSinceColumn = 0

    /// Durée de la fenêtre d'analyse de chaque ligne, en secondes.
    private(set) var binWindowSeconds: [Double] = []
    /// Retard de chaque ligne par rapport à l'instant réel (une demi-fenêtre).
    var binDelaySeconds: [Double] { binWindowSeconds.map { $0 / 2 } }
    /// La plus longue fenêtre du banc : durée du régime transitoire à l'amorçage.
    private(set) var maxWindowSeconds: Double = 0

    init(sampleRate: Double, settings: AnalysisSettings) {
        self.settings = settings

        let nyquist = sampleRate / 2
        let fmax = min(settings.maxFrequency, nyquist * 0.98)
        let fmin = max(min(settings.minFrequency, fmax / 2), 4)
        let bpo = Double(settings.binsPerOctave)
        let octaves = log2(fmax / fmin)
        let count = max(8, Int((octaves * bpo).rounded()) + 1)

        var l = BinLayout()
        l.binCount = count
        l.minFrequency = fmin
        l.maxFrequency = fmax
        l.binsPerOctave = bpo
        l.sampleRate = sampleRate
        var hasher = Hasher()
        hasher.combine(settings.layoutKey)
        hasher.combine(Int(sampleRate))
        l.key = hasher.finalize()
        self.layout = l

        smoothed = [Float](repeating: 0, count: count)
        column = [Float](repeating: -200, count: count)
        hopSamples = max(1, Int((sampleRate / max(settings.columnsPerSecond, 1)).rounded()))

        // Construction des étages.
        let n = settings.multiResolution ? settings.fftSize : settings.monoFFTSize
        let stageCount: Int
        if settings.multiResolution {
            // Assez d'étages pour que la fréquence la plus basse tombe dans une bande.
            let k = Int(floor(log2(0.2 * sampleRate / fmin)))
            stageCount = min(max(k + 1, 1), 14)
        } else {
            stageCount = 1
        }
        for k in 0..<stageCount {
            let sr = sampleRate / pow(2, Double(k))
            guard let s = Stage(sampleRate: sr, n: n) else { break }
            stages.append(s)
            if k > 0 { decimators.append(Decimator()) }
        }

        // Table de correspondance ligne d'affichage → (étage, indices FFT).
        mapping = (0..<count).map { i in
            let f = l.frequency(atBin: Double(i))
            var m = BinMapping()
            let k: Int
            if settings.multiResolution {
                k = min(max(Int(floor(log2(0.2 * sampleRate / f))), 0), stages.count - 1)
            } else {
                k = 0
            }
            m.stage = Int32(k)
            let sr = stages[k].sampleRate
            let nk = Double(stages[k].n)
            let maxBin = stages[k].n / 2

            let half = pow(2, 0.5 / bpo)
            let bLo = (f / half) * nk / sr
            let bHi = (f * half) * nk / sr
            let iLo = Int(ceil(bLo)), iHi = Int(floor(bHi))
            if iHi > iLo {
                m.useMax = true
                m.lo = Int32(min(max(iLo, 0), maxBin))
                m.hi = Int32(min(max(iHi, 0), maxBin))
            } else {
                let center = f * nk / sr
                let base = min(max(Int(floor(center)), 0), maxBin - 1)
                m.useMax = false
                m.lo = Int32(base)
                m.hi = Int32(base + 1)
                m.frac = Float(center - Double(base))
            }
            return m
        }

        binWindowSeconds = mapping.map { m in
            let s = stages[Int(m.stage)]
            return Double(s.n) / s.sampleRate
        }
        maxWindowSeconds = binWindowSeconds.max() ?? 0

        setSmoothing(settings.smoothingSeconds)
    }

    private func setSmoothing(_ tau: Double) {
        if tau <= 0.0005 {
            alpha = 0
        } else {
            alpha = Float(exp(-1.0 / (tau * settings.columnsPerSecond)))
        }
    }

    /// Durée de la fenêtre d'analyse (en secondes) utilisée pour une fréquence donnée.
    func windowSeconds(at frequency: Double) -> Double {
        guard !stages.isEmpty else { return 0 }
        let k: Int
        if settings.multiResolution {
            k = min(max(Int(floor(log2(0.2 * layout.sampleRate / frequency))), 0), stages.count - 1)
        } else {
            k = 0
        }
        return Double(stages[k].n) / stages[k].sampleRate
    }

    var stageCount: Int { stages.count }

    /// Consomme un bloc audio mono et émet les colonnes de spectre complétées.
    /// Une colonne tombe exactement tous les `hopSamples` échantillons consommés,
    /// ce qui garantit que deux analyses partant de positions multiples du saut
    /// produisent les mêmes colonnes.
    func process(_ samples: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) {
        guard let base = samples.baseAddress else { return }
        var offset = 0
        while offset < samples.count {
            let take = min(hopSamples - samplesSinceColumn, samples.count - offset)
            feed(UnsafeBufferPointer(start: base + offset, count: take), from: 0)
            offset += take
            samplesSinceColumn += take
            if samplesSinceColumn >= hopSamples {
                samplesSinceColumn = 0
                makeColumn()
                column.withUnsafeBufferPointer(emit)
            }
        }
    }

    private func feed(_ x: UnsafeBufferPointer<Float>, from k: Int) {
        guard !x.isEmpty, k < stages.count else { return }
        stages[k].append(x)
        guard k + 1 < stages.count else { return }
        decimators[k].process(x) { [self] decimated in
            feed(decimated, from: k + 1)
        }
    }

    private func makeColumn() {
        for s in stages where s.pendingSamples > 0 { s.refresh() }

        let a = alpha
        for i in 0..<column.count {
            let m = mapping[i]
            let p = stages[Int(m.stage)].power
            var v: Float
            if m.useMax {
                v = 0
                var j = Int(m.lo)
                let hi = Int(m.hi)
                while j <= hi {
                    if p[j] > v { v = p[j] }
                    j += 1
                }
            } else {
                let lo = Int(m.lo)
                v = p[lo] * (1 - m.frac) + p[lo + 1] * m.frac
            }
            if a > 0 {
                smoothed[i] = a * smoothed[i] + (1 - a) * v
                v = smoothed[i]
            }
            column[i] = 10 * log10f(max(v, 1e-20))
        }
    }
}
