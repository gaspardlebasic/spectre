#if canImport(Accelerate)
import Accelerate
#endif

/// Transformée de Fourier réelle, en parties paires et impaires séparées.
///
/// La **convention est celle de `vDSP_fft_zrip`**, et elle est reprise telle quelle
/// plutôt que corrigée : le résultat n'est pas normalisé et vaut deux fois la
/// transformée, la composante continue occupe `evens[0]` et Nyquist `odds[0]`. Ce
/// n'est pas la convention la plus naturelle, mais c'est celle sur laquelle les
/// facteurs d'échelle de l'analyse et de la STFT de Demucs ont été réglés, à la
/// virgule près. Une implémentation ailleurs doit la reproduire — y compris le
/// facteur deux — faute de quoi tout ce qui est au-dessus est à retoucher.
///
/// La taille est fixée à la construction et doit être une puissance de deux.
public final class RealFourier {
    public let size: Int

    #if canImport(Accelerate)
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    #endif

    public init?(size n: Int) {
        guard n >= 8, (n & (n - 1)) == 0 else { return nil }
        self.size = n
        #if canImport(Accelerate)
        self.log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
        #else
        #error("Transformée réelle portable à écrire — voir WINDOWS.md, étape 1 (PFFFT).")
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_destroy_fftsetup(setup)
        #endif
    }

    /// Transformée directe de `size` échantillons réels vers `size/2` cases
    /// complexes. `evens` et `odds` doivent porter `size/2` valeurs.
    public func forward(_ input: UnsafePointer<Float>,
                        evens: UnsafeMutablePointer<Float>,
                        odds: UnsafeMutablePointer<Float>) {
        #if canImport(Accelerate)
        let half = size / 2
        var split = DSPSplitComplex(realp: evens, imagp: odds)
        UnsafeRawPointer(input).withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        #endif
    }

    /// Transformée inverse vers `size` échantillons réels.
    ///
    /// **`evens` et `odds` sont détruits au passage** : `vDSP_fft_zrip` travaille sur
    /// place, et l'appelant les remplit de toute façon à chaque trame.
    public func inverse(evens: UnsafeMutablePointer<Float>,
                        odds: UnsafeMutablePointer<Float>,
                        into output: UnsafeMutablePointer<Float>) {
        #if canImport(Accelerate)
        let half = size / 2
        var split = DSPSplitComplex(realp: evens, imagp: odds)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        UnsafeMutableRawPointer(output).withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
        }
        #endif
    }
}
