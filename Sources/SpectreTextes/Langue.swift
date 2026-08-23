import Foundation

/// Les cinq langues de Spectre.
///
/// Le français est la langue de référence : c'est celle dans laquelle chaque texte
/// est écrit d'abord, celle que le dépôt parle, et celle vers laquelle on retombe
/// quand une clé manque ailleurs. Ce n'est pas la langue par défaut à l'écran —
/// celle-là vient du système, et l'anglais prend la main quand le système parle
/// une sixième langue.
public enum Langue: String, CaseIterable, Codable, Sendable {
    case fr, en, es, de, pl

    /// Le nom de la langue **dans cette langue**. Un sélecteur qui écrirait
    /// « Allemand » à qui ne lit pas le français ne sert à rien.
    public var nomNatif: String {
        switch self {
        case .fr: "Français"
        case .en: "English"
        case .es: "Español"
        case .de: "Deutsch"
        case .pl: "Polski"
        }
    }

    /// La langue reconnue dans une étiquette du système — `fr`, `fr-CA`, `de_DE`,
    /// `pl-PL`. On ne garde que les deux premières lettres : une variante régionale
    /// n'a jamais son propre catalogue, et refuser `fr-CA` faute d'une entrée exacte
    /// donnerait l'anglais à un Québécois.
    public static func reconnue(_ etiquette: String) -> Langue? {
        let code = etiquette.prefix(2).lowercased()
        return Langue(rawValue: String(code))
    }
}
