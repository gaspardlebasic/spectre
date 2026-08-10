#if canImport(Accelerate)
import Accelerate
#endif

/// Les opérations vectorielles dont l'analyse a besoin, et rien d'autre.
///
/// Ce module est **la seule frontière numérique avec la plateforme**. Tout ce qui
/// est au-dessus — le banc d'étages, la compensation du retard, la STFT de Demucs —
/// n'appelle plus Accelerate directement mais ces quelques fonctions. Les porter
/// ailleurs, c'est écrire une seconde implémentation ici et nulle part ailleurs.
///
/// La liste est volontairement courte : six opérations. Elle a été relevée sur le
/// code existant, pas devinée, et c'est ce qui rend la frontière vérifiable — si
/// `SpectreCore` compile sans `import Accelerate`, il n'en reste rien.
public enum Vector {

    /// `out = a · b`, terme à terme.
    @inlinable
    public static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>,
                                into out: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        vDSP_vmul(a, 1, b, 1, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = a[i] * b[i] }
        #endif
    }

    /// `out = x · scalaire`. La source et la destination peuvent être confondues.
    @inlinable
    public static func scale(_ x: UnsafePointer<Float>, by scalar: Float,
                             into out: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        var s = scalar
        vDSP_vsmul(x, 1, &s, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = x[i] * scalar }
        #endif
    }

    /// `out = x + scalaire`.
    @inlinable
    public static func add(_ x: UnsafePointer<Float>, _ scalar: Float,
                           into out: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        var s = scalar
        vDSP_vsadd(x, 1, &s, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = x[i] + scalar }
        #endif
    }

    /// `dst += src · gain`. Sert au mixage des canaux en mono.
    @inlinable
    public static func addScaled(_ src: UnsafePointer<Float>, times gain: Float,
                                 into dst: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        var g = gain
        vDSP_vsma(src, 1, &g, dst, 1, dst, 1, vDSP_Length(count))
        #else
        for i in 0..<count { dst[i] += src[i] * gain }
        #endif
    }

    /// Carré du module d'un spectre en parties séparées : `out = evens² + odds²`.
    @inlinable
    public static func magnitudesSquared(evens: UnsafeMutablePointer<Float>,
                                         odds: UnsafeMutablePointer<Float>,
                                         into out: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        var split = DSPSplitComplex(realp: evens, imagp: odds)
        vDSP_zvmags(&split, 1, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = evens[i] * evens[i] + odds[i] * odds[i] }
        #endif
    }

    /// Filtrage RIF suivi d'une décimation par 2, en une passe : `out[k]` est le
    /// produit scalaire des `taps` prises de `input` à partir de `2k`.
    ///
    /// L'appelant garantit que `input` porte au moins `2·(count−1) + taps.count`
    /// échantillons — c'est ce que calcule le décimateur avant d'appeler.
    @inlinable
    public static func decimatingFIR(_ input: UnsafePointer<Float>,
                                     taps: UnsafePointer<Float>, tapCount: Int,
                                     into out: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        vDSP_desamp(input, 2, taps, out, vDSP_Length(count), vDSP_Length(tapCount))
        #else
        for k in 0..<count {
            var sum: Float = 0
            let base = 2 * k
            for j in 0..<tapCount { sum += input[base + j] * taps[j] }
            out[k] = sum
        }
        #endif
    }
}
