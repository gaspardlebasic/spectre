import Foundation
import SpectreDSP

// MARK: - Réglages d'analyse

/// Paramètres qui déterminent la structure de l'analyse (banc multi-résolution + axe
/// des fréquences). Toute modification invalide le spectrogramme calculé.
public struct AnalysisSettings: Equatable, Codable {
    /// Taille de FFT utilisée par chaque étage du banc multi-résolution.
    /// Chaque étage couvre une octave, donc le facteur de qualité vaut
    /// Q ≈ 0.1·N (bas de bande) à 0.2·N (haut de bande).
    public var fftSize: Int = 512

    /// Taille de FFT utilisée quand le mode multi-résolution est désactivé
    /// (une seule fenêtre, constante en secondes, pour tout le spectre).
    public var monoFFTSize: Int = 8192

    /// Analyse multi-résolution : la fenêtre s'allonge quand la fréquence baisse.
    public var multiResolution: Bool = true

    /// Nombre de lignes de sortie par octave (résolution verticale de l'image).
    public var binsPerOctave: Int = 36

    public var minFrequency: Double = 25
    public var maxFrequency: Double = 18000

    /// Nombre de colonnes analysées par seconde (résolution horizontale).
    public var columnsPerSecond: Double = 100

    /// Réattribution spectrale : chaque case dépose son énergie à la fréquence que
    /// sa propre phase désigne, et non au centre de la case qui l'a captée.
    ///
    /// Une raie pure occupe aujourd'hui près de trois lignes — la largeur du lobe de
    /// Hann, quatre cases de FFT, ramenée à l'échelle de l'affichage. Réattribuée,
    /// elle en occupe une. Le prix est double : une seconde FFT par étage, et une
    /// image granuleuse là où le son n'est pas fait de raies (souffle, cymbales),
    /// parce que le bruit se réattribue au hasard au lieu de s'étaler.
    ///
    /// Allumée par défaut. Sur le fichier témoin, la crête de chaque colonne ne
    /// bouge pas — −26,39 dB contre −26,19 — tandis que le niveau moyen de l'image
    /// descend de 4,1 dB : c'est la même énergie dans moins de lignes, donc 4 dB de
    /// contraste gagnés entre les partiels et le fond. L'analyse coûte un tiers de
    /// plus.
    public var reassignment: Bool = true

    /// Constante de temps du lissage temporel, en secondes (0 = aucun lissage).
    /// Hors ligne on n'en veut normalement pas : rien n'oblige à masquer le bruit.
    public var smoothingSeconds: Double = 0

    public init(fftSize: Int = 512, monoFFTSize: Int = 8192, multiResolution: Bool = true,
                binsPerOctave: Int = 36, minFrequency: Double = 25,
                maxFrequency: Double = 18000, columnsPerSecond: Double = 100,
                smoothingSeconds: Double = 0, reassignment: Bool = true) {
        self.fftSize = fftSize
        self.monoFFTSize = monoFFTSize
        self.multiResolution = multiResolution
        self.binsPerOctave = binsPerOctave
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.columnsPerSecond = columnsPerSecond
        self.smoothingSeconds = smoothingSeconds
        self.reassignment = reassignment
    }

    public var layoutKey: [Int] {
        [fftSize, monoFFTSize, multiResolution ? 1 : 0, binsPerOctave,
         Int(minFrequency * 100), Int(maxFrequency * 100),
         Int(columnsPerSecond * 100), Int(smoothingSeconds * 1000),
         reassignment ? 1 : 0]
    }
}

// MARK: - Géométrie de l'axe fréquentiel

public struct BinLayout: Equatable {
    public var binCount: Int = 0
    public var minFrequency: Double = 25
    public var maxFrequency: Double = 18000
    public var binsPerOctave: Double = 36
    public var sampleRate: Double = 48000
    /// Identifiant de génération : change dès que la géométrie change.
    public var key: Int = 0

    public init(binCount: Int = 0, minFrequency: Double = 25, maxFrequency: Double = 18000,
                binsPerOctave: Double = 36, sampleRate: Double = 48000, key: Int = 0) {
        self.binCount = binCount
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.binsPerOctave = binsPerOctave
        self.sampleRate = sampleRate
        self.key = key
    }

    public var totalOctaves: Double { log2(maxFrequency / minFrequency) }

    public func frequency(atBin i: Double) -> Double {
        minFrequency * pow(2, i / binsPerOctave)
    }

    /// Indice de bin (fractionnaire) d'une fréquence.
    public func bin(of frequency: Double) -> Double {
        log2(frequency / minFrequency) * binsPerOctave
    }

    /// Position verticale normalisée (0 = grave, 1 = aigu) d'une fréquence.
    public func position(of frequency: Double) -> Double {
        log2(frequency / minFrequency) / max(totalOctaves, 1e-9)
    }
}

// MARK: - FFT réelle

/// Interne au module plutôt que privée au fichier : le relevé de la batterie fait
/// sa propre transformée, à fenêtre courte et constante, et n'a aucune raison d'en
/// réécrire une deuxième.
final class RealFFT {
    let n: Int
    private let transform: RealFourier
    private var window: [Float]
    /// `sin(2πn/N)` : la dérivée de la fenêtre de Hann, au facteur π/N près qui se
    /// simplifie plus bas. Vide quand la réattribution n'est pas demandée.
    private var slope: [Float]
    private var scale: Float          // 1 / (Σw)²  → une sinusoïde d'amplitude 1 donne 0 dB
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var realq: [Float]
    private var imagq: [Float]
    /// La transformée par la fenêtre dérivée est-elle calculée ? Elle double le coût
    /// de l'étage, et ne sert qu'à la réattribution.
    let reassigning: Bool

    init?(n: Int, reassigning: Bool = false) {
        guard let t = RealFourier(size: n) else { return nil }
        self.transform = t
        self.n = n
        self.reassigning = reassigning
        // Fenêtre de Hann périodique.
        window = (0..<n).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(n))) }
        let sum = window.reduce(0, +)
        scale = 1 / (sum * sum)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        slope = reassigning
            ? (0..<n).map { sin(2 * Float.pi * Float($0) / Float(n)) }
            : []
        realq = [Float](repeating: 0, count: reassigning ? n / 2 : 0)
        imagq = [Float](repeating: 0, count: reassigning ? n / 2 : 0)
    }

    /// Fenêtrage puis transformée, dans les tableaux qu'on lui donne.
    private func forward(_ input: [Float], by taper: [Float],
                         real: inout [Float], imag: inout [Float]) {
        windowed.withUnsafeMutableBufferPointer { w in
            Vector.multiply(input, taper, into: w.baseAddress!, count: n)
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                windowed.withUnsafeBufferPointer { w in
                    transform.forward(w.baseAddress!,
                                      evens: rp.baseAddress!, odds: ip.baseAddress!)
                }
            }
        }
    }

    /// `out` doit contenir n/2 + 1 échantillons ; on y écrit la densité de puissance
    /// normalisée (amplitude² d'une sinusoïde pure au sommet de son pic).
    func power(of input: [Float], into out: inout [Float]) {
        forward(input, by: window, real: &realp, imag: &imagp)

        let half = n / 2
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                // Format « packed » : realp[0] = DC, imagp[0] = Nyquist.
                let dc = rp[0], nyq = ip[0]
                out.withUnsafeMutableBufferPointer { o in
                    Vector.magnitudesSquared(evens: rp.baseAddress!, odds: ip.baseAddress!,
                                             into: o.baseAddress!, count: half)
                    o[0] = dc * dc
                    o[half] = nyq * nyq
                }
            }
        }
        out.withUnsafeMutableBufferPointer { o in
            Vector.scale(o.baseAddress!, by: scale, into: o.baseAddress!, count: half + 1)
        }
    }

    /// La puissance, **et** le décalage de réattribution de chaque case, en raies.
    ///
    /// Le décalage se lit dans une seconde transformée, faite avec la *dérivée* de la
    /// fenêtre. Pour une sinusoïde de fréquence f₀ exprimée en raies, la transformée
    /// par la fenêtre vaut X[k] = A·W(k − f₀), et celle par la dérivée
    /// X′[k] = i·2π(k − f₀)/N · X[k] — dériver multiplie par iω, ici comme partout.
    /// Sa partie imaginaire, rapportée à la puissance, livre donc l'écart cherché :
    ///
    ///     f₀ = k − (N/2π) · Im(X′[k] · conj(X[k])) / |X[k]|²
    ///
    /// La dérivée de la fenêtre de Hann vaut (π/N)·sin(2πn/N). On transforme
    /// `sin(2πn/N)` tout court, et le facteur (N/2π)·(π/N) se réduit à un demi.
    ///
    /// Rien ici ne suppose que deux trames se suivent : l'écart se lit **dans une
    /// seule**, sans repliement de phase à démêler, donc sans condition sur le saut.
    /// C'est ce qui rend la méthode utilisable à l'étage 0, où le saut de 480
    /// échantillons dépasse la moitié de la fenêtre.
    ///
    /// Le facteur 2 que `vDSP_fft_zrip` laisse dans les deux transformées se simplifie
    /// dans le rapport : rien à normaliser.
    func power(of input: [Float], into out: inout [Float], offset: inout [Float]) {
        power(of: input, into: &out)
        let half = n / 2
        guard reassigning else {
            for j in 0...half { offset[j] = 0 }
            return
        }
        forward(input, by: slope, real: &realq, imag: &imagq)
        // Continu et Nyquist sont réels : leur phase ne désigne rien.
        offset[0] = 0
        offset[half] = 0
        for j in 1..<half {
            let a = realq[j], b = imagq[j]
            let c = realp[j], d = imagp[j]
            let den = c * c + d * d
            offset[j] = den > 0 ? -0.5 * (b * c - a * d) / den : 0
        }
    }
}

// MARK: - Décimateur /2

/// Filtre passe-bas RIF + décimation par 2. Le gabarit (passante jusqu'à 0.2·fs,
/// coupée à partir de 0.3·fs) garantit qu'aucun repliement ne tombe dans la bande
/// réellement exploitée par l'étage suivant.
public final class Decimator {
    private let taps: [Float]
    private var history: [Float]
    private var buffer: [Float] = []
    private var output: [Float] = []

    /// Nombre d'échantillons d'entrée que le filtre met à « oublier » son état initial.
    public static let tapCount = 96

    public init(tapCount: Int = Decimator.tapCount) {
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
        let g = Float(1 / sum)
        h.withUnsafeMutableBufferPointer {
            Vector.scale($0.baseAddress!, by: g, into: $0.baseAddress!, count: m)
        }
        taps = h
        history = [Float](repeating: 0, count: m - 1)
        buffer.reserveCapacity(m + 4096)
        output.reserveCapacity(2048)
    }

    public func process(_ x: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: history)
        buffer.append(contentsOf: x)

        let p = taps.count
        let count = buffer.count >= p ? (buffer.count - p) / 2 + 1 : 0
        output.removeAll(keepingCapacity: true)
        if count > 0 {
            output.append(contentsOf: repeatElement(0, count: count))
            output.withUnsafeMutableBufferPointer { o in
                Vector.decimatingFIR(buffer, taps: taps, tapCount: p,
                                     into: o.baseAddress!, count: count)
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
    public let sampleRate: Double
    public let n: Int
    private var ring: [Float]
    private var writeIndex = 0
    private var linear: [Float]
    private let fft: RealFFT
    public var power: [Float]          // n/2 + 1
    /// Décalage de réattribution, en raies de FFT. Vide quand elle est éteinte.
    public var offset: [Float]
    public var pendingSamples = 0

    public init?(sampleRate: Double, n: Int, reassigning: Bool) {
        guard let f = RealFFT(n: n, reassigning: reassigning) else { return nil }
        self.fft = f
        self.sampleRate = sampleRate
        self.n = n
        ring = [Float](repeating: 0, count: n)
        linear = [Float](repeating: 0, count: n)
        power = [Float](repeating: 0, count: n / 2 + 1)
        offset = [Float](repeating: 0, count: reassigning ? n / 2 + 1 : 0)
    }

    public func append(_ x: UnsafeBufferPointer<Float>) {
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
    public func refresh() {
        linear.withUnsafeMutableBufferPointer { l in
            ring.withUnsafeBufferPointer { r in
                let tail = n - writeIndex
                (l.baseAddress!).update(from: r.baseAddress! + writeIndex, count: tail)
                if writeIndex > 0 {
                    (l.baseAddress! + tail).update(from: r.baseAddress!, count: writeIndex)
                }
            }
        }
        if fft.reassigning {
            fft.power(of: linear, into: &power, offset: &offset)
        } else {
            fft.power(of: linear, into: &power)
        }
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
public final class Analyzer {
    /// Ce qu'un étage possède : les lignes d'affichage qui lui reviennent, et les
    /// cases de FFT qu'il faut parcourir pour les remplir.
    ///
    /// Nécessaire à la réattribution seule. La lecture ordinaire va de la ligne vers
    /// la case ; la réattribution va de la case vers la ligne, et il faut alors dire
    /// où l'étage a le droit de déposer. Sans cette limite, chaque partiel serait
    /// compté autant de fois qu'il y a d'étages sous lui.
    struct StageSpan {
        var firstBin = 0
        var lastBin = -1
        var loFFT = 0
        var hiFFT = -1
    }

    public struct BinMapping {
        var stage: Int32 = 0
        var lo: Int32 = 0
        var hi: Int32 = 0
        var frac: Float = 0
        var useMax: Bool = false
    }

    public let settings: AnalysisSettings
    public let layout: BinLayout
    private var stages: [Stage] = []
    private var decimators: [Decimator] = []
    private var mapping: [BinMapping] = []
    private var spans: [StageSpan] = []
    /// La colonne en puissance linéaire, avant lissage et avant décibels.
    private var raw: [Float]
    private var smoothed: [Float]
    private var column: [Float]
    private var alpha: Float = 0
    public let hopSamples: Int
    private var samplesSinceColumn = 0

    /// Durée de la fenêtre d'analyse de chaque ligne, en secondes.
    public private(set) var binWindowSeconds: [Double] = []
    /// Retard de chaque ligne par rapport à l'instant réel (une demi-fenêtre).
    public var binDelaySeconds: [Double] { binWindowSeconds.map { $0 / 2 } }
    /// La plus longue fenêtre du banc : durée du régime transitoire à l'amorçage.
    public private(set) var maxWindowSeconds: Double = 0

    public init(sampleRate: Double, settings: AnalysisSettings) {
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

        raw = [Float](repeating: 0, count: count)
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
            guard let s = Stage(sampleRate: sr, n: n,
                                reassigning: settings.reassignment) else { break }
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

        spans = (0..<stages.count).map { k in
            var span = StageSpan()
            var first = Int.max, last = -1, lo = Int.max, hi = -1
            for (i, m) in mapping.enumerated() where Int(m.stage) == k {
                first = min(first, i)
                last = max(last, i)
                lo = min(lo, Int(m.lo))
                hi = max(hi, Int(m.hi))
            }
            guard last >= 0 else { return span }
            span.firstBin = first
            span.lastBin = last
            // Deux cases de marge : le lobe d'une raie posée au bord de la bande
            // déborde au-dehors, et c'est de là qu'elle revient une fois réattribuée.
            span.loFFT = max(1, lo - 2)
            span.hiFFT = min(stages[k].n / 2 - 1, hi + 2)
            return span
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
    public func windowSeconds(at frequency: Double) -> Double {
        guard !stages.isEmpty else { return 0 }
        let k: Int
        if settings.multiResolution {
            k = min(max(Int(floor(log2(0.2 * layout.sampleRate / frequency))), 0), stages.count - 1)
        } else {
            k = 0
        }
        return Double(stages[k].n) / stages[k].sampleRate
    }

    public var stageCount: Int { stages.count }

    /// Consomme un bloc audio mono et émet les colonnes de spectre complétées.
    /// Une colonne tombe exactement tous les `hopSamples` échantillons consommés,
    /// ce qui garantit que deux analyses partant de positions multiples du saut
    /// produisent les mêmes colonnes.
    public func process(_ samples: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) {
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

        if settings.reassignment { scatter() } else { gather() }

        let a = alpha
        for i in 0..<column.count {
            var v = raw[i]
            if a > 0 {
                smoothed[i] = a * smoothed[i] + (1 - a) * v
                v = smoothed[i]
            }
            column[i] = 10 * log10f(max(v, 1e-20))
        }
    }

    /// La lecture ordinaire : chaque ligne va chercher ce qui lui revient.
    private func gather() {
        for i in 0..<raw.count {
            let m = mapping[i]
            let p = stages[Int(m.stage)].power
            if m.useMax {
                var v: Float = 0
                var j = Int(m.lo)
                let hi = Int(m.hi)
                while j <= hi {
                    if p[j] > v { v = p[j] }
                    j += 1
                }
                raw[i] = v
            } else {
                let lo = Int(m.lo)
                raw[i] = p[lo] * (1 - m.frac) + p[lo + 1] * m.frac
            }
        }
    }

    /// La réattribution : chaque case va porter sa puissance là où sa phase dit que
    /// la raie se trouve vraiment.
    ///
    /// Trois précautions, et chacune répare un défaut visible :
    ///
    /// - **le dépôt est partagé** entre les deux lignes voisines, au prorata. Déposer
    ///   dans la plus proche ferait sauter d'une ligne à l'autre un partiel dont la
    ///   fréquence dérive à peine — un vibrato deviendrait un escalier ;
    /// - **le décalage est borné à deux cases.** Au-delà d'un demi-lobe, il ne
    ///   désigne plus une raie : c'est du bruit entre deux pics, dont la phase tourne
    ///   sans rien vouloir dire ;
    /// - **un étage ne dépose que chez lui.** Un partiel est présent dans tous les
    ///   étages qui le contiennent, et sans cette limite il serait compté autant de
    ///   fois.
    ///
    /// Le facteur 2/3 : par Parseval, une sinusoïde répand sur son lobe de Hann trois
    /// demis de la puissance qu'elle atteint au sommet. Rassembler ce lobe en un point
    /// donnerait donc +1,8 dB ; on le rend. Reste, quand le dépôt tombe pile entre
    /// deux lignes, jusqu'à 1,2 dB de creux — le prix du partage.
    private func scatter() {
        for i in 0..<raw.count { raw[i] = 0 }
        for k in 0..<stages.count {
            let span = spans[k]
            guard span.hiFFT >= span.loFFT, span.lastBin >= span.firstBin else { continue }
            let s = stages[k]
            let hzPerBin = s.sampleRate / Double(s.n)
            s.power.withUnsafeBufferPointer { p in
                s.offset.withUnsafeBufferPointer { d in
                    for j in span.loFFT...span.hiFFT {
                        let v = p[j]
                        guard v > 1e-19 else { continue }
                        let delta = min(max(Double(d[j]), -2), 2)
                        let f = (Double(j) + delta) * hzPerBin
                        guard f > 0 else { continue }
                        let x = layout.bin(of: f)
                        guard x > -1, x < Double(raw.count) else { continue }
                        let i0 = Int(x.rounded(.down))
                        let frac = Float(x - Double(i0))
                        if i0 >= span.firstBin, i0 <= span.lastBin {
                            raw[i0] += v * (1 - frac)
                        }
                        if i0 + 1 >= span.firstBin, i0 + 1 <= span.lastBin {
                            raw[i0 + 1] += v * frac
                        }
                    }
                }
            }
        }
        raw.withUnsafeMutableBufferPointer { o in
            Vector.scale(o.baseAddress!, by: 2.0 / 3.0, into: o.baseAddress!, count: o.count)
        }
    }
}
