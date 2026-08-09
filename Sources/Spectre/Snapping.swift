import CoreGraphics
import Foundation

/// Point du spectrogramme sur lequel le curseur s'est aimanté.
struct SnapTarget: Equatable {
    var time: Double
    var frequency: Double
    /// Clarté affichée à ce point (0…1) avec les réglages courants.
    var intensity: Double
    var column: Int
    /// Ligne affinée par interpolation : la fréquence lue est plus fine que le pas
    /// de l'analyse, ce qui rend l'écart en cents utilisable.
    var bin: Double
}

/// Magnétisme du curseur sur les raies du spectrogramme.
///
/// Le point de vue est celui d'un nuage de points : on cherche la *donnée* la plus
/// proche, pas le pixel sous le curseur. Une donnée, ici, est un maximum local le
/// long de l'axe des fréquences — c'est-à-dire une raie : fondamentale ou
/// harmonique.
///
/// Le critère d'éligibilité est **exactement la clarté affichée** : la même formule
/// que le shader, seuil, pente, γ compris. Une région que l'utilisateur a réglée en
/// noir vaut zéro et n'attire donc rien — monter le seuil, c'est retirer du bruit
/// de l'aimant en même temps que de l'image.
enum Snapping {
    /// Clarté en dessous de laquelle un point n'attire pas.
    static let threshold = 0.12
    /// Rayon de recherche autour du curseur, en points.
    static let radius = 36.0
    /// Nombre maximal de colonnes examinées : au dézoom le rayon peut couvrir des
    /// milliers de colonnes, on les échantillonne.
    private static let maxColumns = 48

    /// Clarté affichée d'une valeur, à l'identique du shader.
    static func intensity(db: Float, bin: Double, layout: BinLayout,
                          display: DisplaySettings) -> Double {
        let octave = log2(layout.minFrequency / 1000) + bin / max(layout.binsPerOctave, 1e-3)
        let tilted = Double(db) + display.tiltDbPerOctave * octave
        let span = max(display.ceilingDb - display.floorDb, 1e-3)
        let t = min(max((tilted - display.floorDb) / span, 0), 1)
        return pow(t, display.gamma)
    }

    /// `point` est en points, depuis le coin haut-gauche de la vue.
    static func nearest(to point: CGPoint,
                        in spectrogram: Spectrogram,
                        viewport: Viewport,
                        display: DisplaySettings,
                        viewSize: CGSize) -> SnapTarget? {
        let bins = spectrogram.binCount
        let columns = spectrogram.columnCount
        guard bins > 2, columns > 0 else { return nil }

        let height = Double(viewSize.height)
        let centreColumn = viewport.column(atPoint: Double(point.x))
        let centreBin = viewport.bin(atPoint: Double(point.y), height: height)

        let columnRadius = radius * viewport.columnsPerPoint
        let binRadius = radius * viewport.binsPerPoint
        let firstColumn = max(0, Int((centreColumn - columnRadius).rounded()))
        let lastColumn = min(columns - 1, Int((centreColumn + columnRadius).rounded()))
        guard firstColumn <= lastColumn else { return nil }
        let stride = max(1, (lastColumn - firstColumn + 1) / maxColumns)

        let firstBin = max(1, Int((centreBin - binRadius).rounded()))
        let lastBin = min(bins - 2, Int((centreBin + binRadius).rounded()))
        guard firstBin <= lastBin else { return nil }

        var best: SnapTarget?
        var bestScore = Double.infinity

        var column = firstColumn
        while column <= lastColumn {
            defer { column += stride }
            let base = column * bins
            let x = viewport.point(ofColumn: Double(column))
            for i in firstBin...lastBin {
                let value = spectrogram.values[base + i]
                let below = spectrogram.values[base + i - 1]
                let above = spectrogram.values[base + i + 1]
                // Maximum local strict d'un côté : sur un plateau, une seule ligne
                // est retenue plutôt que toutes.
                guard value >= below, value > above else { continue }

                let t = intensity(db: value, bin: Double(i), layout: spectrogram.layout,
                                  display: display)
                guard t >= threshold else { continue }

                let y = viewport.point(ofBin: Double(i) + 0.5, height: height)
                let dx = x - Double(point.x), dy = y - Double(point.y)
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= radius * 1.4 else { continue }
                // Une raie franche l'emporte sur une raie pâle un peu plus proche,
                // mais jamais au point de renverser un écart net.
                let score = distance * (1 - 0.35 * t)
                guard score < bestScore else { continue }

                bestScore = score
                // Affinage par parabole sur les trois niveaux : la fréquence lue
                // devient plus fine que le pas de l'analyse.
                var refined = Double(i)
                let denominator = Double(below) - 2 * Double(value) + Double(above)
                if abs(denominator) > 1e-9 {
                    let delta = 0.5 * (Double(below) - Double(above)) / denominator
                    refined += min(max(delta, -0.5), 0.5)
                }
                best = SnapTarget(time: spectrogram.time(ofColumn: column),
                                  frequency: spectrogram.layout.frequency(atBin: refined),
                                  intensity: t,
                                  column: column,
                                  bin: refined)
            }
        }
        return best
    }
}
