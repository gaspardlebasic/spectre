import Foundation

/// Fenêtre visible sur le spectrogramme : quel morceau de la matrice occupe la vue.
///
/// L'unité horizontale est la **colonne d'analyse**, la verticale la **ligne**
/// (donc, l'axe étant logarithmique, une fraction constante d'octave). Tout est
/// exprimé en points, pas en pixels : les gestes du trackpad arrivent en points et
/// c'est seulement au moment de remplir les uniformes qu'on tient compte de la
/// densité de l'écran.
struct Viewport: Equatable {
    /// Colonne au bord gauche de la vue.
    var startColumn: Double = 0
    /// Colonnes couvertes par un point : au-dessus de 1, on dézoome.
    var columnsPerPoint: Double = 4
    /// Ligne au bord bas de la vue.
    var bottomBin: Double = 0
    var binsPerPoint: Double = 1

    static let minColumnsPerPoint = 0.005     // ≈ 2 s d'étalement maximal
    static let maxColumnsPerPoint = 400.0

    func endColumn(width: Double) -> Double { startColumn + width * columnsPerPoint }
    func topBin(height: Double) -> Double { bottomBin + height * binsPerPoint }

    // MARK: Conversions

    func point(ofColumn c: Double) -> Double { (c - startColumn) / columnsPerPoint }
    func column(atPoint x: Double) -> Double { startColumn + x * columnsPerPoint }
    /// `y` est compté depuis le **haut** de la vue, comme dans toutes les vues macOS.
    func bin(atPoint y: Double, height: Double) -> Double {
        bottomBin + (height - y) * binsPerPoint
    }
    func point(ofBin b: Double, height: Double) -> Double {
        height - (b - bottomBin) / binsPerPoint
    }

    // MARK: Gestes

    /// Zoom temporel autour d'un point fixe de la vue : la colonne sous le curseur
    /// ne bouge pas d'un pixel, ce qui est la seule façon qu'un zoom au trackpad
    /// paraisse naturel.
    mutating func zoomTime(factor: Double, anchorX: Double) {
        let anchored = column(atPoint: anchorX)
        columnsPerPoint = min(max(columnsPerPoint / factor,
                                  Viewport.minColumnsPerPoint), Viewport.maxColumnsPerPoint)
        startColumn = anchored - anchorX * columnsPerPoint
    }

    mutating func zoomFrequency(factor: Double, anchorY: Double, height: Double) {
        let anchored = bin(atPoint: anchorY, height: height)
        binsPerPoint = min(max(binsPerPoint / factor, 0.02), 8)
        bottomBin = anchored - (height - anchorY) * binsPerPoint
    }

    /// Recadre la vue sur la matrice : on tolère une marge d'un écran de part et
    /// d'autre en temps (agréable pour attraper le début), mais l'axe des
    /// fréquences reste strictement dans les bornes analysées.
    mutating func clamp(columns: Int, bins: Int, size: (width: Double, height: Double)) {
        let visibleColumns = size.width * columnsPerPoint
        if Double(columns) < visibleColumns {
            startColumn = (Double(columns) - visibleColumns) / 2
        } else {
            startColumn = min(max(startColumn, -visibleColumns / 4),
                              Double(columns) - visibleColumns * 0.75)
        }

        let visibleBins = size.height * binsPerPoint
        if Double(bins) <= visibleBins {
            binsPerPoint = Double(bins) / max(size.height, 1)
            bottomBin = 0
        } else {
            bottomBin = min(max(bottomBin, 0), Double(bins) - visibleBins)
        }
    }

    /// Cadrage initial : tout le fichier en largeur, tout le spectre en hauteur.
    static func fitting(columns: Int, bins: Int,
                        size: (width: Double, height: Double)) -> Viewport {
        var v = Viewport()
        v.columnsPerPoint = min(max(Double(columns) / max(size.width, 1),
                                    minColumnsPerPoint), maxColumnsPerPoint)
        v.startColumn = 0
        v.binsPerPoint = Double(max(bins, 1)) / max(size.height, 1)
        v.bottomBin = 0
        return v
    }
}
