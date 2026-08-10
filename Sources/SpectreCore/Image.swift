import Foundation

/// Écriture d'une image, sans bibliothèque.
///
/// Le format PPM tient en une ligne d'en-tête et des octets bruts. Il est gros et
/// personne ne le distribue — mais il se lit partout (Aperçu, GIMP, ffmpeg), et
/// surtout il n'oblige à embarquer ni zlib ni encodeur PNG sur une plateforme où
/// l'on n'a encore rien. Le jour où le rendu passera par le GPU, ceci ne servira
/// plus qu'aux vérifications ; c'est déjà une raison suffisante de l'avoir.
public enum PPM {

    /// `pixels` est en RVB, trois octets par point, ligne du haut en premier.
    public static func data(width: Int, height: Int, pixels: [UInt8]) -> Data {
        var sortie = Data("P6\n\(width) \(height)\n255\n".utf8)
        sortie.append(contentsOf: pixels)
        return sortie
    }

    public static func write(width: Int, height: Int, pixels: [UInt8], to url: URL) throws {
        try data(width: width, height: height, pixels: pixels).write(to: url)
    }

    public struct Malforme: Error, CustomStringConvertible {
        public let raison: String
        public var description: String { "PPM illisible : \(raison)" }
    }

    /// Relit une image écrite par `write` — ou par n'importe quoi d'autre.
    ///
    /// Sert à comparer deux rendus : celui du GPU relu de la carte, et celui du
    /// processeur. Sans lecture, l'écriture ne prouve rien.
    public static func read(at url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let octets = [UInt8](try Data(contentsOf: url))
        var i = 0
        func estBlanc(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

        // L'en-tête est fait de jetons séparés par des blancs, avec des
        // commentaires possibles entre eux : « P6 », largeur, hauteur, maximum.
        func jeton() throws -> String {
            while i < octets.count {
                if estBlanc(octets[i]) { i += 1; continue }
                if octets[i] == 35 {                       // '#'
                    while i < octets.count, octets[i] != 10 { i += 1 }
                    continue
                }
                break
            }
            let debut = i
            while i < octets.count, !estBlanc(octets[i]) { i += 1 }
            guard i > debut else { throw Malforme(raison: "en-tête tronqué") }
            return String(decoding: octets[debut..<i], as: UTF8.self)
        }

        guard try jeton() == "P6" else { throw Malforme(raison: "ce n'est pas un P6 binaire") }
        guard let l = Int(try jeton()), let h = Int(try jeton()), let maxi = Int(try jeton()),
              l > 0, h > 0 else { throw Malforme(raison: "dimensions absurdes") }
        guard maxi == 255 else { throw Malforme(raison: "seul un maximum de 255 est lu") }
        i += 1                                              // le blanc unique qui suit

        let attendu = l * h * 3
        guard octets.count - i >= attendu else {
            throw Malforme(raison: "\(octets.count - i) octets pour \(attendu) attendus")
        }
        return (l, h, Array(octets[i..<(i + attendu)]))
    }
}

/// Compare deux images de mêmes dimensions.
///
/// Deux rendus d'une même formule ne seront jamais identiques au bit près —
/// l'un interpole, l'autre prend le plus proche voisin — donc l'égalité n'est
/// pas le bon critère. Ce qui se mesure utilement :
///
/// - la **corrélation des profils**, qui attrape une image à l'envers ou
///   décalée : c'est le piège du portage GLSL, et il produit une image
///   parfaitement plausible ;
/// - l'**écart médian**, qui dit si les deux dessinent bien la même chose.
public enum ImageComparison {

    public struct Result {
        public var rowProfile: Double        // corrélation verticale
        public var rowProfileFlipped: Double // la même, image retournée
        public var columnProfile: Double
        public var columnProfileFlipped: Double
        public var pixelCorrelation: Double
        public var medianDifference: Double  // sur 255
        public var meanDifference: Double
        public var withinEight: Double       // part des pixels à moins de 8/255
    }

    public static func compare(_ a: (width: Int, height: Int, pixels: [UInt8]),
                               _ b: (width: Int, height: Int, pixels: [UInt8])) -> Result? {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else {
            return nil
        }
        let l = a.width, h = a.height
        let ga = luminance(a.pixels, count: l * h)
        let gb = luminance(b.pixels, count: l * h)

        var ecarts = [Double](repeating: 0, count: l * h)
        for k in 0..<(l * h) { ecarts[k] = abs(ga[k] - gb[k]) }
        let tries = ecarts.sorted()

        return Result(
            rowProfile: correlation(rows(ga, l, h), rows(gb, l, h)),
            rowProfileFlipped: correlation(rows(ga, l, h), rows(gb, l, h).reversed().map { $0 }),
            columnProfile: correlation(columns(ga, l, h), columns(gb, l, h)),
            columnProfileFlipped: correlation(columns(ga, l, h),
                                              columns(gb, l, h).reversed().map { $0 }),
            pixelCorrelation: correlation(ga, gb),
            medianDifference: tries[tries.count / 2],
            meanDifference: ecarts.reduce(0, +) / Double(ecarts.count),
            withinEight: Double(ecarts.filter { $0 < 8 }.count) / Double(ecarts.count))
    }

    private static func luminance(_ p: [UInt8], count: Int) -> [Double] {
        var sortie = [Double](repeating: 0, count: count)
        for k in 0..<count {
            sortie[k] = 0.299 * Double(p[k * 3]) + 0.587 * Double(p[k * 3 + 1])
                      + 0.114 * Double(p[k * 3 + 2])
        }
        return sortie
    }

    private static func rows(_ g: [Double], _ l: Int, _ h: Int) -> [Double] {
        (0..<h).map { y in g[(y * l)..<((y + 1) * l)].reduce(0, +) / Double(l) }
    }

    private static func columns(_ g: [Double], _ l: Int, _ h: Int) -> [Double] {
        (0..<l).map { x in
            var s = 0.0
            for y in 0..<h { s += g[y * l + x] }
            return s / Double(h)
        }
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .nan }
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for k in 0..<a.count {
            let x = a[k] - ma, y = b[k] - mb
            num += x * y; da += x * x; db += y * y
        }
        let d = (da * db).squareRoot()
        return d > 0 ? num / d : .nan
    }
}

/// Rend un spectrogramme en image, sur le processeur.
///
/// C'est la même formule que le nuanceur — seuil, pente, γ — reprise ici pour deux
/// raisons : vérifier hors écran ce que le GPU affiche, et donner une image sur une
/// plateforme dont le rendu n'est pas encore écrit. Toute divergence entre les deux
/// serait un défaut ; la formule vit donc à un seul endroit, `Snapping.intensity`,
/// qui sert déjà d'arbitre au magnétisme du curseur.
public enum SpectrogramImage {

    /// - Parameters:
    ///   - width: largeur voulue ; les colonnes sont moyennées ou répétées pour y tenir.
    ///   - height: hauteur voulue ; les lignes de même.
    public static func render(_ spectrogram: Spectrogram,
                              display: DisplaySettings,
                              width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: max(width, 1) * max(height, 1) * 3)
        let colonnes = spectrogram.columnCount
        let lignes = spectrogram.binCount
        guard colonnes > 0, lignes > 0, width > 0, height > 0 else { return pixels }

        for y in 0..<height {
            // L'origine est en bas : les graves en bas, comme à l'écran.
            let bin = Double(height - 1 - y) / Double(height) * Double(lignes)
            let i = min(max(Int(bin), 0), lignes - 1)
            for x in 0..<width {
                let colonne = min(max(Int(Double(x) / Double(width) * Double(colonnes)), 0),
                                  colonnes - 1)
                let db = spectrogram.value(column: colonne, bin: i)
                let t = Snapping.intensity(db: db, bin: Double(i),
                                           layout: spectrogram.layout, display: display)
                let (r, v, b) = couleur(t: t, bin: Double(i), spectrogram: spectrogram,
                                        display: display)
                let p = (y * width + x) * 3
                pixels[p] = r
                pixels[p + 1] = v
                pixels[p + 2] = b
            }
        }
        return pixels
    }

    private static func couleur(t: Double, bin: Double, spectrogram: Spectrogram,
                                display: DisplaySettings) -> (UInt8, UInt8, UInt8) {
        func octet(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 1) * 255) }

        guard display.colorMap == .notes else {
            // Les autres palettes sont des dégradés que le nuanceur calcule ; en
            // attendant le rendu GPU, le gris rend compte de l'essentiel.
            return (octet(t), octet(t), octet(t))
        }
        // Palette « notes » : la teinte vient de la hauteur, la clarté du niveau.
        // On passe par `NotePalette.color`, celle-là même qui remplit la table
        // envoyée au GPU — une seule définition des couleurs, pas deux.
        let f = spectrogram.layout.frequency(atBin: bin)
        let midi = Pitch.midi(from: f, referenceA: display.referenceA)
        let classe = Int(midi.rounded())
        let pitchClass = ((classe % 12) + 12) % 12
        let (r, v, b) = NotePalette.color(pitchClass: pitchClass, intensity: t,
                                          saturation: display.noteSaturation)
        return (octet(r), octet(v), octet(b))
    }
}
