import Accelerate
import Foundation

/// La transformée de Fourier à court terme **telle que Demucs l'emploie**, et son
/// inverse, calculées avec Accelerate.
///
/// Ce n'est pas une STFT « en général ». Chaque convention compte, et se tromper sur
/// une seule donne un spectrogramme plausible et faux :
///
/// - fenêtre de Hann **périodique** de 4096, saut de 1024 ;
/// - normalisation en 1/√N à l'aller, √N au retour, si bien que l'aller-retour rend
///   le signal ;
/// - centrage par **réflexion**, appliqué en deux temps — d'abord le rembourrage de
///   `_spec`, puis celui de la STFT elle-même. Les deux ne se cumulent pas en un
///   seul : la seconde réflexion travaille sur ce que la première a produit ;
/// - la raie de Nyquist est retirée, et deux trames de chaque côté.
///
/// Ce travail était jusqu'ici fait *dans* le réseau, par multiplication contre des
/// bases cosinus/sinus figées dans le graphe — 128 Mo de tables, et un coût en N²
/// là où une FFT coûte N log N.
final class DemucsFourier {
    static let nfft = 4096
    static let hop = 1024
    /// Raies conservées : tout sauf Nyquist.
    static let bins = nfft / 2
    /// Rembourrage propre à `_spec`, en plus de celui de la STFT.
    static let margin = hop / 2 * 3          // 1536

    private let log2n = vDSP_Length(12)      // 4096 = 2¹²
    private let setup: FFTSetup
    private let window: [Float]
    /// Somme des carrés de la fenêtre, décalée de saut en saut : c'est par elle
    /// qu'on divise à la reconstruction.
    private let forwardScale: Float
    private let inverseScale: Float

    init?() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        let n = Self.nfft
        // Hann **périodique** : `torch.hann_window` l'est par défaut, et la variante
        // symétrique décalerait toute la reconstruction.
        window = (0..<n).map { 0.5 * (1 - cos(2 * .pi * Float($0) / Float(n))) }
        // `vDSP_fft_zrip` rend deux fois la transformée réelle ; la normalisation en
        // 1/√N de Demucs s'y ajoute.
        forwardScale = 0.5 / Float(n).squareRoot()
        // Au retour : les cases portent déjà le spectre normalisé, et `vDSP_fft_zrip`
        // en sens inverse rend la somme non normalisée. Reste le 1/√N de Demucs.
        // Mesuré plutôt que supposé — un facteur N de trop rendait un signal 4096
        // fois trop faible, ce que le contrôle a montré du premier coup.
        inverseScale = 1 / Float(n).squareRoot()
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Nombre de trames conservées pour un signal de cette longueur.
    static func frames(for length: Int) -> Int { (length + hop - 1) / hop }

    // MARK: Aller

    /// Spectre d'un signal, rangé raie par raie : `real[bin * frames + frame]`.
    ///
    /// C'est la disposition de PyTorch, et celle qu'attend le réseau.
    func spectrogram(of signal: [Float]) -> (real: [Float], imaginary: [Float]) {
        let n = Self.nfft
        let kept = Self.frames(for: signal.count)
        let padded = Self.reflect(signal,
                                  left: Self.margin,
                                  right: Self.margin + kept * Self.hop - signal.count)
        // Le centrage de la STFT : encore une réflexion, d'une demi-fenêtre.
        let centred = Self.reflect(padded, left: n / 2, right: n / 2)
        let total = 1 + (centred.count - n) / Self.hop      // vaut `kept + 4`

        var real = [Float](repeating: 0, count: Self.bins * kept)
        var imaginary = [Float](repeating: 0, count: Self.bins * kept)
        var frame = [Float](repeating: 0, count: n)
        var evens = [Float](repeating: 0, count: n / 2)
        var odds = [Float](repeating: 0, count: n / 2)

        // Les deux premières trames et les deux dernières sont écartées par `_spec` :
        // on ne les calcule pas.
        for f in 0..<total where f >= 2 && f < 2 + kept {
            let start = f * Self.hop
            vDSP_vmul(Array(centred[start..<start + n]), 1, window, 1, &frame, 1, vDSP_Length(n))
            evens.withUnsafeMutableBufferPointer { er in
                odds.withUnsafeMutableBufferPointer { oi in
                    var split = DSPSplitComplex(realp: er.baseAddress!, imagp: oi.baseAddress!)
                    frame.withUnsafeBufferPointer { raw in
                        raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            let column = f - 2
            // `zrip` range la composante continue et Nyquist ensemble dans la case 0.
            // Nyquist étant justement la raie qu'on jette, il ne reste qu'à remettre
            // la partie imaginaire du continu à zéro.
            real[column] = evens[0] * forwardScale
            imaginary[column] = 0
            for k in 1..<Self.bins {
                real[k * kept + column] = evens[k] * forwardScale
                imaginary[k * kept + column] = odds[k] * forwardScale
            }
        }
        return (real, imaginary)
    }

    // MARK: Retour

    /// Reconstruit un signal de `length` échantillons à partir de son spectre.
    func signal(real: [Float], imaginary: [Float], length: Int) -> [Float] {
        let n = Self.nfft
        let kept = Self.frames(for: length)
        let total = kept + 4                       // les deux trames de garde de chaque côté
        let span = (total - 1) * Self.hop + n

        var accumulated = [Float](repeating: 0, count: span)
        var envelope = [Float](repeating: 0, count: span)
        var evens = [Float](repeating: 0, count: n / 2)
        var odds = [Float](repeating: 0, count: n / 2)
        var frame = [Float](repeating: 0, count: n)
        let squared = window.map { $0 * $0 }

        for f in 0..<total {
            let column = f - 2
            if column >= 0 && column < kept {
                // Nyquist est nulle : la case 0 ne porte donc que la composante
                // continue, dans sa partie réelle.
                evens[0] = real[column]
                odds[0] = 0
                for k in 1..<Self.bins {
                    evens[k] = real[k * kept + column]
                    odds[k] = imaginary[k * kept + column]
                }
            } else {
                // Trame de garde : un spectre nul, donc rien à ajouter.
                for k in 0..<n / 2 { evens[k] = 0; odds[k] = 0 }
            }

            evens.withUnsafeMutableBufferPointer { er in
                odds.withUnsafeMutableBufferPointer { oi in
                    var split = DSPSplitComplex(realp: er.baseAddress!, imagp: oi.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    frame.withUnsafeMutableBufferPointer { raw in
                        raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2))
                        }
                    }
                }
            }

            let start = f * Self.hop
            for i in 0..<n {
                accumulated[start + i] += frame[i] * window[i] * inverseScale
                envelope[start + i] += squared[i]
            }
        }

        // Division par l'enveloppe, puis on retire la demi-fenêtre du centrage et le
        // rembourrage de `_spec`.
        let offset = n / 2 + Self.margin
        var result = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let j = offset + i
            guard j < span else { break }
            let e = envelope[j]
            result[i] = e > 1e-8 ? accumulated[j] / e : 0
        }
        return result
    }

    // MARK: Rembourrage

    /// Réflexion sans répétition du bord : `[1,2,3]` rembourré de 2 à gauche donne
    /// `[3,2,1,2,3]`, comme `numpy` et `torch`.
    static func reflect(_ x: [Float], left: Int, right: Int) -> [Float] {
        guard x.count > 1 else { return [Float](repeating: x.first ?? 0,
                                                count: left + x.count + right) }
        var out = [Float]()
        out.reserveCapacity(left + x.count + right)
        for i in stride(from: left, to: 0, by: -1) { out.append(x[i % (x.count - 1)]) }
        out.append(contentsOf: x)
        let last = x.count - 1
        for i in 1...max(right, 1) where right > 0 { out.append(x[last - i % last]) }
        return out
    }
}
