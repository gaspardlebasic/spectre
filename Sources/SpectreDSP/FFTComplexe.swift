import Foundation

/// FFT complexe de Cooley-Tukey, base 2, en place, sur parties séparées.
///
/// Rien d'original : entrelacement par inversion de bits, puis des papillons
/// d'étage en étage, avec une table de rotations calculée une fois. C'est la
/// brique sur laquelle la transformée réelle portable est construite.
///
/// Le sens est passé en argument plutôt que figé dans deux fonctions jumelles :
/// seul le signe de la partie imaginaire de la rotation change, et écrire deux
/// fois le même code pour un signe est le meilleur moyen d'en corriger un seul
/// le jour où il faudra y revenir.
final class ComplexFFT {
    let n: Int
    private let levels: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init?(n: Int) {
        guard n >= 2, (n & (n - 1)) == 0 else { return nil }
        self.n = n
        levels = Int(log2(Double(n)).rounded())

        var c = [Float](repeating: 0, count: n / 2)
        var s = [Float](repeating: 0, count: n / 2)
        for i in 0..<(n / 2) {
            let a = 2 * Double.pi * Double(i) / Double(n)
            c[i] = Float(cos(a))
            s[i] = Float(sin(a))
        }
        cosTable = c
        sinTable = s

        var r = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var v = 0
            var x = i
            for _ in 0..<levels {
                v = (v << 1) | (x & 1)
                x >>= 1
            }
            r[i] = v
        }
        reversed = r
    }

    /// `sign` vaut −1 pour la transformée directe (e^−2πikm/n) et +1 pour
    /// l'inverse. **Aucune normalisation** n'est appliquée dans un sens ni dans
    /// l'autre : c'est l'appelant qui sait quelle convention il sert.
    func run(real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>,
             sign: Float) {
        for i in 0..<n {
            let j = reversed[i]
            if j > i {
                let tr = real[i]; real[i] = real[j]; real[j] = tr
                let ti = imaginary[i]; imaginary[i] = imaginary[j]; imaginary[j] = ti
            }
        }

        var size = 2
        while size <= n {
            let half = size / 2
            let step = n / size
            var block = 0
            while block < n {
                var k = 0
                for j in block..<(block + half) {
                    let wr = cosTable[k]
                    let wi = sign * sinTable[k]
                    let l = j + half
                    let tr = real[l] * wr - imaginary[l] * wi
                    let ti = real[l] * wi + imaginary[l] * wr
                    real[l] = real[j] - tr
                    imaginary[l] = imaginary[j] - ti
                    real[j] += tr
                    imaginary[j] += ti
                    k += step
                }
                block += size
            }
            size <<= 1
        }
    }
}
