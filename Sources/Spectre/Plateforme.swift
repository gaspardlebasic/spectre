import SpectreCore
import SpectreMac
import SpectreModele

/// Le modèle de l'application, muni de ce que macOS lui fournit.
///
/// Le comportement — tout le comportement — vit dans `SpectreModele`, qui ne
/// connaît aucun système. Ce fichier est le seul endroit où l'on dit avec quelles
/// pièces il tourne ici. Le pendant Windows dira la même chose avec les siennes,
/// et l'application sera la même, non une application qui lui ressemble.
///
/// Le `typealias` n'est pas un ornement : il fait que tout ce qui écrivait
/// `AppModel` continue de l'écrire. Le modèle est générique sur son lecteur —
/// parce que SwiftUI observe `model.player.speed` et qu'un protocole existentiel
/// romprait ce suivi — mais l'interface n'a aucune raison de porter ce détail.
typealias AppModel = SpectreModele.AppModel<Player>

extension Preferences: PreferencesGlobales {}

extension SpectreModele.AppModel where Lecteur == Player {
    /// L'assemblage macOS : à chaque protocole du modèle, sa mise en œuvre Apple.
    convenience init() {
        self.init(lecteur: Player(),
                  décodeur: DecodeurApple(),
                  sinusoide: ToneGenerator(),
                  pistes: RangementApple(),
                  dialogue: DialogueApple(),
                  récentsDuSystème: RecentsApple(),
                  extérieur: ExterieurApple(),
                  préférences: Preferences.shared)
    }
}
