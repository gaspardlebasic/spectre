import Foundation

/// Crans des curseurs de lecture.
///
/// Un curseur continu ne retrouve jamais sa valeur neutre : il s'arrête à ×0,996,
/// que l'affichage arrondit en « ×1.00 ». On croit être revenu à la normale sans
/// l'être, et le vocodeur de phase continue de travailler pour un écart inaudible
/// — c'est exactement là qu'il est le plus irrégulier, puisqu'il n'a presque rien
/// à faire mais doit tout de même recoller le signal de loin en loin.
///
/// D'où un cran : à l'approche de la valeur neutre, on y tombe exactement. La
/// valeur affichée redevient alors la vérité, et le traitement peut être retiré
/// du chemin du signal.
public enum Detent {
    /// Largeur du cran autour de la vitesse normale.
    private static let speedWidth = 0.02
    /// Largeur du cran autour de chaque demi-ton entier.
    private static let transposeWidth = 0.1

    public static func speed(_ value: Double) -> Double {
        if abs(value - 1) < speedWidth { return 1 }
        return (value * 100).rounded() / 100
    }

    /// La transposition s'aimante sur les demi-tons entiers — ce qu'on veut
    /// presque toujours — sans interdire les valeurs intermédiaires, qui servent
    /// à recaler un enregistrement désaccordé.
    public static func transpose(_ value: Double) -> Double {
        let nearest = value.rounded()
        if abs(value - nearest) < transposeWidth { return nearest }
        return (value * 100).rounded() / 100
    }
}
