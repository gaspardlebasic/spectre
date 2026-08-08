import Foundation

/// Palette dont la teinte dépend de la note jouée.
///
/// Chaque octave est découpée en 12 bandes centrées sur les demi-tons. Les teintes
/// sont réparties sur le cercle chromatique **dans l'ordre du cycle des quintes** :
/// deux notes séparées d'une quinte sont voisines en couleur (Do rouge, Sol orange,
/// Ré jaune…), et deux notes séparées d'un triton — les plus éloignées dans le
/// cycle — reçoivent des teintes diamétralement opposées.
///
/// Les couleurs sont construites en Oklch, espace où la coordonnée L correspond à
/// la clarté perçue. À intensité sonore donnée, les 12 teintes partagent exactement
/// la même clarté et la même chroma : seule la teinte les distingue, si bien qu'une
/// note grave ne paraît ni plus ni moins forte qu'une autre à niveau égal.
enum NotePalette {
    static let pitchClassCount = 12
    /// Nombre de paliers d'intensité de la table.
    static let steps = 128
    /// Clarté Oklab atteinte à pleine intensité. Volontairement en dessous de 1 :
    /// le blanc n'a pas de teinte, et les notes doivent rester identifiables au
    /// maximum du niveau. 0.75 est l'endroit où le gamut sRGB laisse le plus de
    /// chroma commune à l'ensemble des douze teintes.
    static let maxLightness = 0.75
    /// Teinte de Do, en tours. 29° est la teinte Oklch du rouge sRGB.
    private static let baseHue = 29.0 / 360.0
    /// Marge de sécurité sous la limite du gamut sRGB.
    private static let chromaSafety = 0.96
    /// Intensités entre lesquelles la teinte monte en puissance. En dessous, la
    /// couleur reste quasi neutre : sans cela le plancher de bruit — qui occupe
    /// l'essentiel de l'image — se couvre de rayures arc-en-ciel, deux demi-tons
    /// voisins étant presque opposés en teinte.
    private static let chromaFadeIn = 0.18
    private static let chromaFadeFull = 0.58

    /// Rang d'une classe de hauteur dans le cycle des quintes (Do=0, Sol=1, Ré=2…).
    /// 7·p mod 12 inverse la suite des quintes, puisque 7·7 ≡ 1 (mod 12).
    static func circleOfFifthsIndex(_ pitchClass: Int) -> Int {
        ((7 * pitchClass) % 12 + 12) % 12
    }

    static func hueTurns(_ pitchClass: Int) -> Double {
        baseHue + Double(circleOfFifthsIndex(pitchClass)) / Double(pitchClassCount)
    }

    // MARK: Oklch → sRGB

    /// Oklch vers sRGB linéaire (composantes non bornées : hors gamut si < 0 ou > 1).
    static func linearRGB(lightness L: Double, chroma C: Double, hueTurns h: Double)
        -> (r: Double, g: Double, b: Double) {
        let angle = h * 2 * .pi
        let a = C * cos(angle)
        let b = C * sin(angle)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// sRGB linéaire vers Oklab (sert à vérifier la clarté et la teinte obtenues).
    static func oklab(linear r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func oklabLightness(linear r: Double, _ g: Double, _ b: Double) -> Double {
        oklab(linear: r, g, b).L
    }

    /// Teinte Oklch d'une couleur sRGB encodée gamma, en degrés.
    static func hueDegrees(sRGB r: Double, _ g: Double, _ b: Double) -> Double {
        let lab = oklab(linear: decodeGamma(r), decodeGamma(g), decodeGamma(b))
        let angle = atan2(lab.b, lab.a) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }

    /// Écart angulaire entre deux teintes, en degrés (0…180).
    static func hueSeparation(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    static func encodeGamma(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func decodeGamma(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: Construction de la table

    /// Plus grande chroma restant dans le gamut sRGB pour cette clarté et cette teinte.
    static func maxChroma(lightness L: Double, hueTurns h: Double) -> Double {
        var low = 0.0, high = 0.44
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let c = linearRGB(lightness: L, chroma: mid, hueTurns: h)
            let inside = c.r >= 0 && c.r <= 1 && c.g >= 0 && c.g <= 1 && c.b >= 0 && c.b <= 1
            if inside { low = mid } else { high = mid }
        }
        return low
    }

    /// Chroma utilisable par *toutes* les teintes à cette clarté. La prendre commune
    /// est ce qui garantit que seule la teinte distingue deux notes de même niveau.
    static func commonChroma(lightness L: Double) -> Double {
        var minimum = Double.greatestFiniteMagnitude
        for p in 0..<pitchClassCount {
            minimum = min(minimum, maxChroma(lightness: L, hueTurns: hueTurns(p)))
        }
        return minimum * chromaSafety
    }

    /// Limites de chroma précalculées pour chaque palier d'intensité : la recherche
    /// de gamut est trop lente pour être refaite à chaque mouvement de curseur.
    private struct ChromaProfile {
        var common: [Double]          // par palier
        var perHue: [[Double]]        // par palier, puis par classe de hauteur
    }

    private static let profile: ChromaProfile = {
        var common = [Double](repeating: 0, count: steps)
        var perHue = [[Double]](repeating: [Double](repeating: 0, count: pitchClassCount),
                                count: steps)
        for i in 0..<steps {
            let L = maxLightness * Double(i) / Double(steps - 1)
            var minimum = Double.greatestFiniteMagnitude
            for p in 0..<pitchClassCount {
                let c = maxChroma(lightness: L, hueTurns: hueTurns(p)) * chromaSafety
                perHue[i][p] = c
                minimum = min(minimum, c)
            }
            common[i] = minimum
        }
        return ChromaProfile(common: common, perHue: perHue)
    }()

    /// Chroma retenue pour une teinte, un palier d'intensité et un réglage de
    /// saturation. Jusqu'à 1, les douze teintes restent à chroma égale ; au-delà,
    /// chacune progresse vers son propre maximum — la clarté n'en dépend jamais.
    static func chroma(step: Int, pitchClass: Int, saturation: Double) -> Double {
        let i = min(max(step, 0), steps - 1)
        let common = profile.common[i]
        let s = max(saturation, 0)
        if s <= 1 { return common * s }
        let reach = min(s - 1, 1)
        return common + (profile.perHue[i][pitchClass] - common) * reach
    }

    /// Proportion de chroma appliquée à une intensité donnée (0 dans le bruit de
    /// fond, 1 dès qu'il y a du signal). N'affecte que la saturation : la clarté,
    /// elle, reste strictement proportionnelle à l'intensité.
    static func chromaFade(intensity t: Double) -> Double {
        let x = min(max((t - chromaFadeIn) / (chromaFadeFull - chromaFadeIn), 0), 1)
        return x * x * (3 - 2 * x)      // smoothstep
    }

    /// Couleur sRGB (0…1, encodée gamma) d'une note à une intensité donnée.
    static func color(pitchClass: Int, intensity t: Double, saturation: Double = 1)
        -> (r: Double, g: Double, b: Double) {
        let clamped = min(max(t, 0), 1)
        let step = Int((clamped * Double(steps - 1)).rounded())
        let L = maxLightness * clamped
        let C = chroma(step: step, pitchClass: pitchClass, saturation: saturation)
            * chromaFade(intensity: clamped)
        let c = linearRGB(lightness: L, chroma: C, hueTurns: hueTurns(pitchClass))
        return (encodeGamma(c.r), encodeGamma(c.g), encodeGamma(c.b))
    }

    /// Table RGBA8 de `steps` colonnes (intensité) sur 12 lignes (classe de hauteur).
    static func makeTable(saturation: Double = 1) -> [UInt8] {
        var table = [UInt8](repeating: 255, count: steps * pitchClassCount * 4)
        for i in 0..<steps {
            let t = Double(i) / Double(steps - 1)
            let L = maxLightness * t
            let fade = chromaFade(intensity: t)
            for p in 0..<pitchClassCount {
                let C = chroma(step: i, pitchClass: p, saturation: saturation) * fade
                let c = linearRGB(lightness: L, chroma: C, hueTurns: hueTurns(p))
                let offset = (p * steps + i) * 4
                table[offset] = UInt8((encodeGamma(c.r) * 255).rounded())
                table[offset + 1] = UInt8((encodeGamma(c.g) * 255).rounded())
                table[offset + 2] = UInt8((encodeGamma(c.b) * 255).rounded())
                table[offset + 3] = 255
            }
        }
        return table
    }
}
