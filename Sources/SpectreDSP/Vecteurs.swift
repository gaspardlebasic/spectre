#if !SPECTRE_PORTABLE && canImport(Accelerate)
import Accelerate
#endif

/// Les opérations vectorielles dont l'analyse a besoin, et rien d'autre.
///
/// Ce module est **la seule frontière numérique avec la plateforme**. Tout ce qui
/// est au-dessus — le banc d'étages, la compensation du retard, la STFT de Demucs —
/// n'appelle plus Accelerate directement mais ces quelques fonctions. Les porter
/// ailleurs, c'est écrire une seconde implémentation ici et nulle part ailleurs.
///
/// La liste est volontairement courte : sept opérations. Elle a été relevée sur le
/// code existant, pas devinée, et c'est ce qui rend la frontière vérifiable — si
/// `SpectreCore` compile sans `import Accelerate`, il n'en reste rien.
public enum Vector {

    /// `out = a · b`, terme à terme.
    public static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>,
                                into out: UnsafeMutablePointer<Float>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
        vDSP_vmul(a, 1, b, 1, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = a[i] * b[i] }
        #endif
    }

    /// `out = x · scalaire`. La source et la destination peuvent être confondues.
    public static func scale(_ x: UnsafePointer<Float>, by scalar: Float,
                             into out: UnsafeMutablePointer<Float>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
        var s = scalar
        vDSP_vsmul(x, 1, &s, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = x[i] * scalar }
        #endif
    }

    /// `out = x + scalaire`.
    public static func add(_ x: UnsafePointer<Float>, _ scalar: Float,
                           into out: UnsafeMutablePointer<Float>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
        var s = scalar
        vDSP_vsadd(x, 1, &s, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = x[i] + scalar }
        #endif
    }

    /// `dst += src · gain`. Sert au mixage des canaux en mono.
    public static func addScaled(_ src: UnsafePointer<Float>, times gain: Float,
                                 into dst: UnsafeMutablePointer<Float>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
        var g = gain
        vDSP_vsma(src, 1, &g, dst, 1, dst, 1, vDSP_Length(count))
        #else
        for i in 0..<count { dst[i] += src[i] * gain }
        #endif
    }

    /// Carré du module d'un spectre en parties séparées : `out = evens² + odds²`.
    public static func magnitudesSquared(evens: UnsafeMutablePointer<Float>,
                                         odds: UnsafeMutablePointer<Float>,
                                         into out: UnsafeMutablePointer<Float>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
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
    public static func decimatingFIR(_ input: UnsafePointer<Float>,
                                     taps: UnsafePointer<Float>, tapCount: Int,
                                     into out: UnsafeMutablePointer<Float>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
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

    /// Conversion en demi-flottants (IEEE-754 binaire 16), arrondi au plus proche,
    /// pair en cas d'égalité.
    ///
    /// C'est ce qui part sur la carte graphique : la matrice y est stockée en
    /// demi-flottants parce qu'à ces niveaux le pas vaut 0,06 dB — très en dessous
    /// du visible — et que la mémoire occupée est divisée par deux. Une heure de
    /// musique passe ainsi de 400 à 200 Mo.
    ///
    /// La version portable est écrite à la main plutôt que confiée à `Float16`,
    /// pour la raison qui avait déjà fait préférer une FFT maison à PFFFT : ce type
    /// n'existe pas sur toutes les cibles que le noyau doit atteindre, et une
    /// frontière numérique ne se découvre pas absente le jour où l'on compile
    /// ailleurs. Écrite ici, elle se compare à vImage sur le Mac — voir `DSPCheck`.
    public static func demiFlottants(_ x: UnsafePointer<Float>,
                                     into out: UnsafeMutablePointer<UInt16>, count: Int) {
        #if !SPECTRE_PORTABLE && canImport(Accelerate)
        var entree = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: x),
                                   height: 1, width: vImagePixelCount(count),
                                   rowBytes: count * MemoryLayout<Float>.size)
        var sortie = vImage_Buffer(data: out,
                                   height: 1, width: vImagePixelCount(count),
                                   rowBytes: count * MemoryLayout<UInt16>.size)
        vImageConvert_PlanarFtoPlanar16F(&entree, &sortie, 0)
        #else
        for i in 0..<count { out[i] = demiFlottant(x[i]) }
        #endif
    }

    /// Un flottant simple précision vers un demi-flottant, valeur par valeur.
    ///
    /// Les trois cas qui font toute la longueur de cette fonction sont ceux qu'un
    /// simple décalage rate : les sous-normaux, où le bit implicite doit redevenir
    /// explicite ; les NaN, dont la mantisse ne peut pas tomber à zéro sous peine
    /// de les changer en infini ; et l'arrondi, qui peut déborder dans l'exposant —
    /// ce qui est correct, et donne l'infini au bon moment.
    ///
    /// Publique comme l'est `PortableRealFourier`, et pour la même raison : c'est
    /// le chemin portable, et il ne serait pas comparable à celui d'Accelerate si
    /// le harnais ne pouvait pas l'appeler là où Accelerate existe.
    public static func demiFlottant(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let signe = UInt16((bits >> 16) & 0x8000)
        let exposantBrut = Int((bits >> 23) & 0xFF)
        let mantisse = bits & 0x007F_FFFF

        if exposantBrut == 0xFF {
            if mantisse == 0 { return signe | 0x7C00 }
            return signe | 0x7C00 | UInt16(max(mantisse >> 13, 1))
        }

        // Exposant débiaisé de 127, rebiaisé de 15.
        let exposant = exposantBrut - 127 + 15

        if exposant >= 0x1F { return signe | 0x7C00 }

        if exposant <= 0 {
            // Sous-normal. En dessous de 2⁻²⁵ il ne reste rien à représenter, pas
            // même le plus petit sous-normal.
            if exposant < -10 { return signe }
            let complete = mantisse | 0x0080_0000
            let decalage = UInt32(14 - exposant)
            let quotient = complete >> decalage
            let reste = complete & ((UInt32(1) << decalage) - 1)
            let moitie = UInt32(1) << (decalage - 1)
            let arrondi = (reste > moitie || (reste == moitie && quotient & 1 == 1))
                ? quotient + 1 : quotient
            return signe | UInt16(arrondi)
        }

        let reste = mantisse & 0x1FFF
        var demi = UInt16(exposant << 10) | UInt16(mantisse >> 13)
        if reste > 0x1000 || (reste == 0x1000 && demi & 1 == 1) { demi += 1 }
        return signe | demi
    }
}
