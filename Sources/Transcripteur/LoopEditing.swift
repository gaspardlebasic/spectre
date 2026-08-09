import Foundation

enum LoopEdge { case start, end }

/// Les règles de manipulation de la boucle, séparées de l'interface.
///
/// Ce sont trois gestes différents sur le même objet — tracer, déplacer, tirer une
/// borne — et chacun a sa règle propre. Les rassembler ici les rend vérifiables
/// sans souris.
enum LoopEditing {
    /// Longueur en deçà de laquelle il n'y a plus de boucle du tout.
    static let minimumLength = 0.05

    /// Boucle tracée entre deux instants, dans n'importe quel ordre.
    /// `nil` quand le geste est trop court pour valoir une boucle : c'est ce qui
    /// fait qu'un simple clic dans la réglette efface la boucle en place.
    static func made(from a: Double, to b: Double, duration: Double,
                     snap: (Double) -> Double) -> ClosedRange<Double>? {
        let first = snap(a), second = snap(b)
        let lo = min(max(min(first, second), 0), duration)
        let hi = min(max(max(first, second), 0), duration)
        return hi - lo > minimumLength ? lo...hi : nil
    }

    /// Boucle déplacée en bloc, sa durée inchangée.
    ///
    /// Seul le début s'aimante : caler les deux bornes déformerait le passage
    /// qu'on vient justement de choisir. Et la durée prime sur la position —
    /// arrivé au bout du fichier, la boucle s'arrête plutôt que de se raccourcir.
    static func moved(_ loop: ClosedRange<Double>, startingAt time: Double,
                      duration: Double, snap: (Double) -> Double) -> ClosedRange<Double> {
        let length = loop.upperBound - loop.lowerBound
        let start = min(max(snap(time), 0), max(duration - length, 0))
        return start...(start + length)
    }

    /// Boucle dont on tire une borne, l'autre restant en place.
    ///
    /// La borne tirée ne traverse pas sa voisine : elle s'arrête à la longueur
    /// minimale. Effacer la boucle parce qu'on a tiré un peu trop loin serait une
    /// punition disproportionnée pour un geste qu'on est en train de faire.
    static func resized(_ loop: ClosedRange<Double>, edge: LoopEdge, to time: Double,
                        duration: Double, snap: (Double) -> Double) -> ClosedRange<Double> {
        let moved = min(max(snap(time), 0), duration)
        switch edge {
        case .start:
            return min(moved, loop.upperBound - minimumLength)...loop.upperBound
        case .end:
            return loop.lowerBound...max(moved, loop.lowerBound + minimumLength)
        }
    }
}
