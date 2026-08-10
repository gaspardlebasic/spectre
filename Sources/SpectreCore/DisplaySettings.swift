import Foundation

public enum ColorMap: Int, CaseIterable, Identifiable, Codable {
    case gray = 0, inferno = 1, magma = 2, viridis = 3, turbo = 4, notes = 5
    public var id: Int { rawValue }
    public var label: String {
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
public struct DisplaySettings: Equatable, Codable {
    /// Niveau (dBFS) rendu noir.
    public var floorDb: Double = -95
    /// Niveau (dBFS) rendu clair / saturé.
    public var ceilingDb: Double = -25
    /// Correction de courbe appliquée après normalisation.
    public var gamma: Double = 0.85
    /// Pente ajoutée à l'affichage, en dB par octave (compense le spectre
    /// décroissant de la plupart des sons naturels).
    public var tiltDbPerOctave: Double = 3
    /// La palette des notes par défaut : c'est la seule qui dise *quoi* est joué
    /// et pas seulement *combien fort*.
    public var colorMap: ColorMap = .notes
    public var showGrid: Bool = true

    /// Nommer les touches noires par le bas (Mi♭) plutôt que par le haut (Ré♯).
    public var useFlats: Bool = true

    /// Fréquence du La₃, qui détermine où tombent les bandes de la palette
    /// « notes », les noms de notes et les repères d'octaves.
    public var referenceA: Double = 440

    /// Saturation de la palette « notes » (0 = gris, 1 = chroma commune aux douze
    /// teintes, 2 = chaque teinte à son maximum). Au-delà de 1, les teintes
    /// gagnent en franchise ce qu'elles perdent en chroma égale : sur de la
    /// musique réelle, où les raies sont fines et se détachent mal, le compromis
    /// vaut la peine.
    public var noteSaturation: Double = 1.4

    public init(floorDb: Double = -95, ceilingDb: Double = -25, gamma: Double = 0.85,
                tiltDbPerOctave: Double = 3, colorMap: ColorMap = .notes,
                showGrid: Bool = true, useFlats: Bool = true,
                referenceA: Double = 440, noteSaturation: Double = 1.4) {
        self.floorDb = floorDb
        self.ceilingDb = ceilingDb
        self.gamma = gamma
        self.tiltDbPerOctave = tiltDbPerOctave
        self.colorMap = colorMap
        self.showGrid = showGrid
        self.useFlats = useFlats
        self.referenceA = referenceA
        self.noteSaturation = noteSaturation
    }
}
