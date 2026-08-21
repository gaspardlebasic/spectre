import Foundation

/// Les cinq voies du sélecteur : le mixage tel qu'il est, et les quatre pistes que
/// la séparation isole.
///
/// Choisir une piste ne change pas seulement ce qu'on entend, mais aussi **ce qu'on
/// voit** : le spectrogramme d'une piste isolée a bien moins de partielles qui se
/// croisent, si bien que l'aimantation du curseur tombe enfin sur la bonne raie.
/// C'est là le vrai gain pour une transcription, l'écoute n'en étant que la moitié.
public enum Stem: String, CaseIterable, Codable, Identifiable {
    case mix, drums, bass, vocals, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mix: "Mixage"
        case .drums: "Batterie"
        case .bass: "Basse"
        case .vocals: "Voix"
        case .other: "Reste"
        }
    }

    /// Symbole système. Chacun a été vérifié présent : un nom absent ne lève
    /// aucune erreur, il ne dessine simplement rien — et `drum`, le nom qu'on
    /// écrirait d'instinct, n'existe pas sur macOS 14.
    ///
    /// Ce sont des noms de SF Symbols, donc d'Apple, dans un fichier qui ne connaît
    /// aucun système. Ce n'est pas une entorse : ce ne sont que des chaînes, et
    /// c'est ce qui permet à l'énumération entière de descendre ici. Une autre
    /// plateforme les traduit dans sa propre police d'icônes plutôt que de tenir
    /// une seconde liste de pistes.
    public var symbol: String {
        switch self {
        case .mix: "waveform"
        case .drums: "circle.grid.cross"
        case .bass: "hifispeaker"
        case .vocals: "music.mic"
        case .other: "pianokeys"
        }
    }

    public var help: String {
        switch self {
        case .mix: "Le morceau tel qu'il est."
        case .drums: """
            Batterie et percussions.
            Une fois les pistes séparées, elle ne se voit plus dans le spectrogramme : elle nourrit les trois lignes du bas, qui disent d'elle ce qu'un spectre ne sait pas dire.
            Décochée, on ne l'entend plus et ces lignes restent vides.
            """
        case .bass: "La basse seule — la piste la mieux isolée, et la plus difficile à relever à l'oreille dans un mixage dense."
        case .vocals: "Le chant seul."
        case .other: "Tout le reste : claviers, guitares, cuivres, cordes."
        }
    }

    /// Les quatre pistes produites par le modèle, **dans l'ordre où il les rend**.
    /// Cet ordre est celui de Demucs et ne doit pas être réarrangé : il indexe
    /// directement la sortie du réseau.
    public static let separated: [Stem] = [.drums, .bass, .other, .vocals]

    /// Comment nommer un ensemble de pistes gardées — pour la ligne d'état.
    ///
    /// La sélection étant soustractive, on la dit comme on l'a faite : « sans Voix »
    /// plutôt que « Basse + Batterie + Reste ». On n'énumère ce qui reste que
    /// lorsqu'il en reste moins qu'on n'en a retiré.
    public static func label(for stems: Set<Stem>) -> String {
        let kept = separated.filter(stems.contains)
        let dropped = separated.filter { !stems.contains($0) }
        if dropped.isEmpty { return Stem.mix.label }
        if kept.isEmpty { return "silence" }
        if dropped.count < kept.count {
            return "sans " + dropped.map(\.label).joined(separator: " ni ")
        }
        return kept.map(\.label).joined(separator: " + ")
    }
}
