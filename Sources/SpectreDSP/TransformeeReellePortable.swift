import Foundation

/// Transformée de Fourier réelle en Swift pur, **à la convention de
/// `vDSP_fft_zrip`** — facteur deux compris, composante continue et Nyquist
/// empaquetées dans la case 0.
///
/// Reproduire cette convention plutôt que la corriger est ce qui permet de
/// changer d'implémentation sans retoucher une seule ligne au-dessus : ni les
/// facteurs d'échelle de l'analyse, ni ceux de la STFT de Demucs — réglés à la
/// virgule près contre PyTorch — ne s'aperçoivent du changement.
///
/// Le procédé est classique : une FFT complexe de N/2 points sur les échantillons
/// pairs et impairs pris pour parties réelle et imaginaire, puis un dépaquetage.
/// Une transformée réelle coûte ainsi la moitié d'une complexe.
public final class PortableRealFourier {
    public let size: Int
    private let half: Int
    private let complex: ComplexFFT
    /// e^(−2πik/N), k = 0…N/2−1 : la rotation qui recombine pairs et impairs.
    private let cosN: [Float]
    private let sinN: [Float]
    /// Espace de travail, alloué une fois : la transformée est appelée des
    /// milliers de fois par morceau analysé.
    private let zr: UnsafeMutablePointer<Float>
    private let zi: UnsafeMutablePointer<Float>

    public init?(size n: Int) {
        guard n >= 8, (n & (n - 1)) == 0, let c = ComplexFFT(n: n / 2) else { return nil }
        size = n
        half = n / 2
        complex = c
        var cs = [Float](repeating: 0, count: n / 2)
        var sn = [Float](repeating: 0, count: n / 2)
        for k in 0..<(n / 2) {
            let a = 2 * Double.pi * Double(k) / Double(n)
            cs[k] = Float(cos(a))
            sn[k] = Float(sin(a))
        }
        cosN = cs
        sinN = sn
        zr = .allocate(capacity: n / 2)
        zi = .allocate(capacity: n / 2)
        zr.initialize(repeating: 0, count: n / 2)
        zi.initialize(repeating: 0, count: n / 2)
    }

    deinit {
        zr.deallocate()
        zi.deallocate()
    }

    public func forward(_ input: UnsafePointer<Float>,
                        evens: UnsafeMutablePointer<Float>,
                        odds: UnsafeMutablePointer<Float>) {
        let m = half
        for k in 0..<m {
            zr[k] = input[2 * k]
            zi[k] = input[2 * k + 1]
        }
        complex.run(real: zr, imaginary: zi, sign: -1)

        // Case 0 : la composante continue et Nyquist, toutes deux réelles, y
        // logent ensemble. C'est ce qui fait tenir N/2+1 raies dans N/2 cases.
        let z0r = zr[0], z0i = zi[0]
        evens[0] = 2 * (z0r + z0i)
        odds[0] = 2 * (z0r - z0i)

        for k in 1..<m {
            let ar = zr[k], ai = zi[k]
            let br = zr[m - k], bi = -zi[m - k]          // conj(Z[m−k])
            // Pairs et impairs se relisent dans Z par symétrie hermitienne.
            let er = 0.5 * (ar + br), ei = 0.5 * (ai + bi)
            let dr = 0.5 * (ar - br), di = 0.5 * (ai - bi)
            let orr = di, ori = -dr                      // −i·(dr + i·di)
            let wr = cosN[k], wi = -sinN[k]              // e^(−2πik/N)
            evens[k] = 2 * (er + orr * wr - ori * wi)
            odds[k] = 2 * (ei + orr * wi + ori * wr)
        }
    }

    /// Somme **non normalisée** : le résultat vaut Σ P̃[k]·e^(+2πikn/N) sur le
    /// spectre complet reconstruit par symétrie hermitienne. C'est exactement ce
    /// que rend `vDSP_fft_zrip` en sens inverse, et donc ce sur quoi les facteurs
    /// d'échelle de l'appelant comptent.
    public func inverse(evens: UnsafeMutablePointer<Float>,
                        odds: UnsafeMutablePointer<Float>,
                        into output: UnsafeMutablePointer<Float>) {
        let m = half
        let p0 = evens[0], pNyquist = odds[0]
        zr[0] = p0 + pNyquist
        zi[0] = p0 - pNyquist

        for k in 1..<m {
            let pr = evens[k], pi = odds[k]
            let qr = evens[m - k], qi = -odds[m - k]     // conj(P[m−k])
            let vr = cosN[k], vi = sinN[k]               // e^(+2πik/N)
            // (1 + i·V) et (1 − i·V), les deux poids du repliement.
            let ar = 1 - vi, ai = vr
            let br = 1 + vi, bi = -vr
            zr[k] = pr * ar - pi * ai + qr * br - qi * bi
            zi[k] = pr * ai + pi * ar + qr * bi + qi * br
        }
        complex.run(real: zr, imaginary: zi, sign: 1)

        for k in 0..<m {
            output[2 * k] = zr[k]
            output[2 * k + 1] = zi[k]
        }
    }
}
