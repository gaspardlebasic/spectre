import AVFoundation
import Accelerate
import Foundation
import SpectreCore

/// Le contenu d'un fichier audio ramené à ce dont l'analyse a besoin : un signal
/// mono en virgule flottante, à la fréquence d'échantillonnage du fichier.
///
/// Tout est chargé en mémoire (≈ 10 Mo la minute). C'est la limite assumée de cette
/// première version : au-delà d'une demi-heure il faudra analyser en flux et ne
/// garder que la matrice, bien plus compacte que le signal.
public struct AudioSource {
    public let url: URL
    public let sampleRate: Double
    public let frameCount: Int
    /// Somme des canaux, normalisée : c'est ce que voit l'analyseur.
    public let mono: [Float]
    /// Identifie le morceau indépendamment de l'endroit où il est rangé, pour
    /// retrouver les réglages qu'on lui a donnés la dernière fois.
    public let fingerprint: String?

    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public enum Failure: LocalizedError {
        case unreadable(URL, Error)
        case empty(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let error):
                return "Impossible de lire « \(url.lastPathComponent) » : \(error.localizedDescription)"
            case .empty(let url):
                return "« \(url.lastPathComponent) » ne contient aucun son."
            }
        }
    }

    public static func load(_ url: URL) throws -> AudioSource {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url, error)
        }

        let format = file.processingFormat        // Float32, canaux séparés
        let channels = Int(format.channelCount)
        let blockFrames: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw Failure.empty(url)
        }

        var mono = [Float]()
        mono.reserveCapacity(Int(file.length))
        // La somme des canaux, et — s'il s'agit d'une de nos pistes compressées — le
        // rattrapage de la réserve de niveau, dans la même multiplication.
        let gain = StemStore.gain(for: url) / Float(max(channels, 1))

        // `file.length` est une estimation sur les formats compressés, et `read`
        // préfère lever une erreur plutôt que de renvoyer zéro image quand on
        // dépasse la fin. On s'arrête donc sur la première des deux conditions,
        // et une erreur en fin de course ne compte pas comme un échec.
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: blockFrames)
            } catch {
                if mono.isEmpty { throw Failure.unreadable(url, error) }
                break
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }

            let offset = mono.count
            mono.append(contentsOf: repeatElement(0, count: n))
            mono.withUnsafeMutableBufferPointer { out in
                let dst = out.baseAddress! + offset
                for c in 0..<channels {
                    // vDSP_vsma : dst += src · gain, un canal après l'autre.
                    var g = gain
                    vDSP_vsma(data[c], 1, &g, dst, 1, dst, 1, vDSP_Length(n))
                }
            }
        }

        guard !mono.isEmpty else { throw Failure.empty(url) }
        return AudioSource(url: url,
                           sampleRate: format.sampleRate,
                           frameCount: mono.count,
                           mono: mono,
                           fingerprint: SessionStore.fingerprint(of: url))
    }
}
