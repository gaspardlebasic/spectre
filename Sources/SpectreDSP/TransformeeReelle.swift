#if canImport(Accelerate)
import Accelerate
#endif

// La transformée que le reste du code emploie. Deux implémentations, une seule
// convention — celle de `vDSP_fft_zrip`, décrite sur `PortableRealFourier`.
//
// Les deux sont compilées côte à côte quand la plateforme le permet, et non
// choisies à l'exclusion l'une de l'autre : c'est ce qui permet à `DSPCheck` de
// les faire tourner dans le même processus sur le même signal et de mesurer
// l'écart. Une frontière qu'on ne peut pas comparer des deux côtés n'est qu'une
// promesse.
#if SPECTRE_PORTABLE || !canImport(Accelerate)
public typealias RealFourier = PortableRealFourier
#else
public typealias RealFourier = AccelerateRealFourier
#endif

#if canImport(Accelerate)

/// Transformée réelle par Accelerate. C'est la référence : c'est contre elle que
/// la version portable est mesurée.
public final class AccelerateRealFourier {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    public init?(size n: Int) {
        guard n >= 8, (n & (n - 1)) == 0 else { return nil }
        self.size = n
        self.log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Transformée directe de `size` échantillons réels vers `size/2` cases
    /// complexes. `evens` et `odds` doivent porter `size/2` valeurs.
    public func forward(_ input: UnsafePointer<Float>,
                        evens: UnsafeMutablePointer<Float>,
                        odds: UnsafeMutablePointer<Float>) {
        let half = size / 2
        var split = DSPSplitComplex(realp: evens, imagp: odds)
        UnsafeRawPointer(input).withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    /// Transformée inverse vers `size` échantillons réels.
    ///
    /// **`evens` et `odds` sont détruits au passage** : `vDSP_fft_zrip` travaille
    /// sur place, et l'appelant les remplit de toute façon à chaque trame.
    public func inverse(evens: UnsafeMutablePointer<Float>,
                        odds: UnsafeMutablePointer<Float>,
                        into output: UnsafeMutablePointer<Float>) {
        let half = size / 2
        var split = DSPSplitComplex(realp: evens, imagp: odds)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        UnsafeMutableRawPointer(output).withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
        }
    }
}

#endif
