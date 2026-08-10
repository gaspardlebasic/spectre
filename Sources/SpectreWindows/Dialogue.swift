import CSDL3
import Foundation
import SpectreCore

/// Le dialogue d'ouverture de fichier, celui de Windows.
///
/// SDL le montre sans bloquer et rappelle une fonction quand c'est fini —
/// **possiblement sur un autre fil**, ce que la documentation dit et qu'il ne
/// faut pas prendre à la légère : recharger un morceau depuis là toucherait au
/// contexte OpenGL depuis un fil qui ne le possède pas, et le pilote a le droit
/// de refuser. On dépose donc le chemin, et la boucle principale le ramasse à
/// l'image suivante.
enum Dialogue {

    private static let verrou = NSLock()
    private static var enAttente: String?
    private static var ouvert = false

    /// Le chemin choisi, une seule fois.
    static func recupere() -> String? {
        verrou.lock(); defer { verrou.unlock() }
        let chemin = enAttente
        enAttente = nil
        return chemin
    }

    static func ouvrir(fenetre: OpaquePointer?) {
        verrou.lock()
        // Deux dialogues ouverts en même temps, c'est une fenêtre orpheline que
        // l'utilisateur ne sait plus à quoi rattacher.
        if ouvert { verrou.unlock(); return }
        ouvert = true
        verrou.unlock()

        // SDL attend des motifs sans point, séparés par des points-virgules.
        // `AudioLoader` sait déjà ce que cette plateforme ouvre : une seule
        // liste, et le dialogue ne peut pas proposer ce que le décodeur refuse.
        let motifs = AudioLoader.supportedExtensions.joined(separator: ";")
        motifs.withCString { p in
            "Fichiers audio".withCString { nom in
                var filtre = SDL_DialogFileFilter(name: nom, pattern: p)
                SDL_ShowOpenFileDialog(rappel, nil, fenetre, &filtre, 1, nil, false)
            }
        }
    }

    /// Le rappel est une fonction C : pas de capture, donc tout passe par les
    /// variables ci-dessus.
    private static let rappel: SDL_DialogFileCallback = { _, liste, _ in
        verrou.lock()
        ouvert = false
        // `liste` nul signale une erreur, une liste vide une annulation. Ni
        // l'une ni l'autre n'est un incident.
        if let liste, let premier = liste.pointee {
            enAttente = String(cString: premier)
        }
        verrou.unlock()
    }
}
