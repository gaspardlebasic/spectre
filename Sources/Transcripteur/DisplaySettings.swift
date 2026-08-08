import Foundation

enum ColorMap: Int, CaseIterable, Identifiable, Codable {
    case gray = 0, inferno = 1, magma = 2, viridis = 3, turbo = 4, notes = 5
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .gray: return "Niveaux de gris"
        case .inferno: return "Inferno"
        case .magma: return "Magma"
        case .viridis: return "Viridis"
        case .turbo: return "Turbo"
        case .notes: return "Notes (cycle des quintes)"
        }
    }
}

/// Réglages purement visuels : ils s'appliquent dans le shader, donc les modifier
/// retouche instantanément toute l'image, sans réanalyser le son.
struct DisplaySettings: Equatable, Codable {
    /// Niveau (dBFS) rendu noir.
    var floorDb: Double = -95
    /// Niveau (dBFS) rendu clair / saturé.
    var ceilingDb: Double = -25
    /// Correction de courbe appliquée après normalisation.
    var gamma: Double = 0.85
    /// Pente ajoutée à l'affichage, en dB par octave (compense le spectre
    /// décroissant de la plupart des sons naturels).
    var tiltDbPerOctave: Double = 3
    var colorMap: ColorMap = .inferno
    var showGrid: Bool = true

    /// Fréquence du La₃, qui détermine où tombent les bandes de la palette
    /// « notes », les noms de notes et les repères d'octaves.
    var referenceA: Double = 440

    /// Saturation de la palette « notes » (0 = gris, 1 = chroma commune aux douze
    /// teintes, 2 = chaque teinte à son maximum).
    var noteSaturation: Double = 1
}
