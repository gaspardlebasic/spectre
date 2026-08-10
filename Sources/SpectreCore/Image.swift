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
