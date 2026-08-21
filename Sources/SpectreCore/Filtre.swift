import Foundation

/// Cellule du second ordre, forme directe transposée II.
///
/// La forme transposée plutôt que la directe : à état égal elle se comporte mieux
/// en flottant, et surtout elle n'a que deux mémoires au lieu de quatre.
public struct Biquad {
    public var b0: Float = 1, b1: Float = 0, b2: Float = 0
    public var a1: Float = 0, a2: Float = 0
    private var s1: Float = 0, s2: Float = 0

    public init() {}

    public mutating func reset() {
        s1 = 0
        s2 = 0
    }

    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        return y
    }

    /// Coefficients d'un passe-haut du second ordre, formulaire d'Audio EQ Cookbook.
    /// `q` vaut 1/√2 pour une réponse de Butterworth — plate dans la bande passante.
    public static func highPass(frequency: Double, sampleRate: Double,
                                q: Double = 0.7071067811865476) -> Biquad {
        var f = Biquad()
        let w0 = 2 * Double.pi * min(max(frequency, 1), sampleRate * 0.49) / sampleRate
        let cs = cos(w0), sn = sin(w0)
        let alpha = sn / (2 * max(q, 1e-3))
        let a0 = 1 + alpha
        f.b0 = Float((1 + cs) / 2 / a0)
        f.b1 = Float(-(1 + cs) / a0)
        f.b2 = Float((1 + cs) / 2 / a0)
        f.a1 = Float(-2 * cs / a0)
        f.a2 = Float((1 - alpha) / a0)
        return f
    }

    public static func lowPass(frequency: Double, sampleRate: Double,
                               q: Double = 0.7071067811865476) -> Biquad {
        var f = Biquad()
        let w0 = 2 * Double.pi * min(max(frequency, 1), sampleRate * 0.49) / sampleRate
        let cs = cos(w0), sn = sin(w0)
        let alpha = sn / (2 * max(q, 1e-3))
        let a0 = 1 + alpha
        f.b0 = Float((1 - cs) / 2 / a0)
        f.b1 = Float((1 - cs) / a0)
        f.b2 = Float((1 - cs) / 2 / a0)
        f.a1 = Float(-2 * cs / a0)
        f.a2 = Float((1 - alpha) / a0)
        return f
    }
}

/// Le filtre de bande de la lecture : n'entendre que ce qu'on regarde.
///
/// Deux passe-haut et deux passe-bas en cascade, soit 24 dB par octave de chaque
/// côté — c'est le gabarit qu'`AVAudioUnitEQ` tient sur macOS, et le remplacer par
/// autre chose changerait ce qu'on entend. Un seul biquad, à 12 dB par octave,
/// laisserait passer la basse voisine qu'on cherche précisément à écarter.
///
/// Comme sur macOS, chaque moitié se retire du chemin quand sa borne touche le
/// bord de l'analyse : un filtre qui ne filtre rien ne doit pas travailler.
public struct BandFilter {
    private var highPass: (Biquad, Biquad)
    private var lowPass: (Biquad, Biquad)
    private var highPassActive = false
    private var lowPassActive = false
    private var sampleRate: Double = 44100

    /// Bande actuellement appliquée, pour ne pas retoucher les coefficients à
    /// chaque image quand rien n'a bougé.
    public private(set) var applied: ClosedRange<Double>?

    public init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        highPass = (Biquad(), Biquad())
        lowPass = (Biquad(), Biquad())
    }

    public mutating func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        let band = applied
        applied = nil
        setBand(band, force: true)
    }

    /// Le seuil d'un dixième de demi-ton est celui de la version macOS : un
    /// mouvement de trackpad produit une consigne par image, et recalculer des
    /// coefficients pour un écart inaudible ne ferait que claquer.
    public mutating func setBand(_ range: ClosedRange<Double>?, force: Bool = false) {
        if !force, let range, let applied,
           abs(log2(range.lowerBound / applied.lowerBound)) < 0.005,
           abs(log2(range.upperBound / applied.upperBound)) < 0.005 { return }
        if !force, range == nil, applied == nil { return }
        applied = range

        guard let range else {
            highPassActive = false
            lowPassActive = false
            return
        }
        let nyquist = sampleRate / 2
        let low = min(max(range.lowerBound, 20), nyquist * 0.95)
        let high = min(max(range.upperBound, low * 1.05), nyquist * 0.95)

        highPassActive = low > 25
        lowPassActive = high < nyquist * 0.9
        if highPassActive {
            let f = Biquad.highPass(frequency: low, sampleRate: sampleRate)
            highPass = (f, f)
        }
        if lowPassActive {
            let f = Biquad.lowPass(frequency: high, sampleRate: sampleRate)
            lowPass = (f, f)
        }
    }

    public mutating func reset() {
        highPass.0.reset(); highPass.1.reset()
        lowPass.0.reset(); lowPass.1.reset()
    }

    public var isBypassed: Bool { !highPassActive && !lowPassActive }

    public mutating func process(_ x: Float) -> Float {
        var y = x
        if highPassActive {
            y = highPass.1.process(highPass.0.process(y))
        }
        if lowPassActive {
            y = lowPass.1.process(lowPass.0.process(y))
        }
        return y
    }

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        guard !isBypassed else { return }
        for i in 0..<buffer.count { buffer[i] = process(buffer[i]) }
    }
}
