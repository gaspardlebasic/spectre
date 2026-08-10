import Foundation

#if os(Windows)
import CMediaFoundation
#endif

/// Ouvrir un fichier son, quel qu'il soit.
///
/// `WAVFile` sait lire le PCM et rien d'autre — c'est déjà ce qu'il faut pour
/// travailler, et cela n'engage aucune bibliothèque. Pour le reste, chaque
/// système a son décodeur : Media Foundation sous Windows, `AVAudioFile` sur
/// macOS (`SpectreMac/AudioFile.swift`, qui n'a pas besoin de passer par ici).
///
/// Le WAV est essayé en premier même quand le système saurait le lire : c'est
/// plus rapide, cela ne réveille pas COM, et surtout cela garantit qu'un fichier
/// non compressé donne exactement le même signal sur les deux plateformes — le
/// socle sur lequel toutes les vérifications croisées reposent.
public enum AudioLoader {

    public typealias Contents = WAVFile.Contents

    public enum Failure: Error, CustomStringConvertible {
        /// Le décodeur du système a refusé le fichier.
        case decoder(String, Int32)
        /// Aucun décodeur ici pour ce qui n'est pas du WAV.
        case unsupported(String)

        public var description: String {
            switch self {
            case .decoder(let quoi, let code):
                return "\(quoi) (code \(code))"
            case .unsupported(let extension_):
                return "Cette version ne lit que le WAV ; « .\(extension_) » demanderait "
                     + "un décodeur que cette plateforme ne fournit pas."
            }
        }
    }

    /// Les extensions que cette plateforme sait ouvrir, pour le dialogue de
    /// fichiers et pour dire non tout de suite plutôt qu'après le décodage.
    public static var supportedExtensions: [String] {
        #if os(Windows)
        // Media Foundation lit ceux-ci d'origine sur toute installation de
        // Windows 10 ou 11. FLAC et ALAC en font partie depuis Windows 10, ce
        // qui évite d'embarquer un décodeur de plus.
        return ["wav", "mp3", "m4a", "aac", "mp4", "wma", "flac", "aif", "aiff"]
        #elseif os(macOS)
        return ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac", "alac", "mp4"]
        #else
        return ["wav"]
        #endif
    }

    public static func load(at url: URL) throws -> Contents {
        let extension_ = url.pathExtension.lowercased()
        if extension_ == "wav" || extension_.isEmpty {
            // Un fichier sans extension, ou nommé `.wav` : on tente le PCM, et
            // s'il n'est pas ce qu'il prétend, le système prend le relais.
            if let contenu = try? WAVFile.read(at: url) { return contenu }
        }

        #if os(Windows)
        return try decodeAvecMediaFoundation(url)
        #else
        // Sur macOS c'est `AudioSource` qui ouvre les fichiers ; ce chemin-ci ne
        // sert qu'aux outils en ligne de commande, qui restent au WAV.
        return try WAVFile.read(at: url)
        #endif
    }

    #if os(Windows)
    private static func decodeAvecMediaFoundation(_ url: URL) throws -> Contents {
        // `spectre_mf_decoder` rend un tableau alloué en C : on le recopie dans
        // un `[Float]` et on le rend immédiatement. Le doublon coûte une fois la
        // taille du signal, le temps d'une copie — et évite d'avoir à porter
        // cette propriété jusque dans le reste de l'application.
        let resultat = url.path.withCString { spectre_mf_decoder($0) }
        guard resultat.code == 0, let bloc = resultat.echantillons else {
            let message = String(cString: spectre_mf_message(resultat.code))
            throw Failure.decoder("« \(url.lastPathComponent) » : \(message)",
                                  Int32(resultat.resultat))
        }
        defer { spectre_mf_liberer(bloc) }

        let images = Int(resultat.images)
        var mono = [Float](UnsafeBufferPointer(start: bloc, count: images))

        // Media Foundation rend l'amorçage du codeur avec le reste ; sur un AAC
        // de six secondes cela fait 48 ms de décalage par rapport à ce que macOS
        // ouvre du même fichier. `GaplessTrim` lit ce que le conteneur déclare et
        // remet les deux systèmes d'accord — voir le détail là-bas.
        if let coupe = GaplessTrim.read(at: url) {
            mono = coupe.apply(to: mono)
        }

        return Contents(sampleRate: resultat.frequence,
                        channels: Int(resultat.canaux),
                        mono: mono)
    }
    #endif
}
