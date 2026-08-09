import AVFoundation
import Foundation
import OnnxRuntimeBindings

/// Séparation par Demucs v4 affiné, exécutée par ONNX Runtime.
///
/// Le réseau travaille sur une **tranche de taille fixe** — 7,8 s de stéréo à
/// 44,1 kHz — parce que c'est ainsi qu'il a été entraîné et exporté. Séparer un
/// morceau consiste donc à le découper, appliquer le réseau tranche par tranche, et
/// recoller le tout.
struct DemucsSeparator: StemSeparator {
    /// Longueur de la tranche, en échantillons : `segment × samplerate` du modèle.
    static let segmentSamples = 343_980
    static let sampleRate = 44_100.0
    static let channels = 2

    func separate(fileAt url: URL,
                  progress: @escaping (Double) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> [Stem: [[Float]]] {
        guard StemStore.hasModel else { throw SeparationFailure.modelMissing }

        // Une session par piste : le sac de `htdemucs_ft` est fait de quatre réseaux
        // distincts, chacun n'ayant appris qu'un instrument.
        let environment: ORTEnv
        do {
            environment = try ORTEnv(loggingLevel: .warning)
        } catch {
            throw SeparationFailure.engine("environnement ONNX indisponible — \(error.localizedDescription)")
        }

        var sessions: [Stem: ORTSession] = [:]
        for stem in Stem.separated {
            guard let file = StemStore.modelFile(for: stem) else {
                throw SeparationFailure.modelMissing
            }
            do {
                let options = try ORTSessionOptions()
                // CoreML fait passer le calcul par le GPU et le moteur neuronal.
                // Son refus n'est pas fatal : ONNX Runtime retombe sur les cœurs,
                // plus lentement mais avec le même résultat.
                try? options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
                sessions[stem] = try ORTSession(env: environment,
                                                modelPath: file.path,
                                                sessionOptions: options)
            } catch {
                throw SeparationFailure.modelUnreadable("\(stem.label) — \(error.localizedDescription)")
            }
        }
        _ = sessions
        throw SeparationFailure.engine("le découpage et le recollement restent à écrire")
    }
}
