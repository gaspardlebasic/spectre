import AVFoundation
import Foundation
import SpectreCore
import SpectreDSP

/// Le décodeur d'Apple : `AVAudioFile` lit tout ce que macOS sait lire.
///
/// Le contenu qu'il produit, lui, vit dans `SpectreCore` — voir `AudioSource`.
/// Cette séparation est ce qui permet à tout ce qui est au-dessus de ne dépendre
/// que des nombres, et à une seconde plateforme de n'avoir que ce fichier-ci à
/// réécrire.
public struct DecodeurApple: Décodeur {
    public init() {}

    public func charger(_ url: URL) throws -> AudioSource {
        try AudioSource.load(url)
    }
}

extension AudioSource {
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
                // Par la frontière numérique plutôt que par `vDSP_vsma` en clair :
                // c'est exactement l'opération qu'elle porte, et le décodeur de
                // l'autre plateforme mélangera ses canaux avec la même.
                for c in 0..<channels {
                    Vector.addScaled(data[c], times: gain, into: dst, count: n)
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
