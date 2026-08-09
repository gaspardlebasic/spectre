import AVFoundation
import Accelerate
import Foundation
import OnnxRuntimeBindings

/// Séparation par Demucs v4, exécutée par ONNX Runtime.
///
/// Le réseau travaille sur une **tranche de taille fixe** — 7,8 s de stéréo à
/// 44,1 kHz — parce que c'est ainsi qu'il a été entraîné et exporté. Séparer un
/// morceau consiste donc à le découper, appliquer le réseau tranche par tranche, et
/// recoller le tout en fondu enchaîné.
///
/// Un seul réseau rend les quatre pistes, en un parcours du morceau.
struct DemucsSeparator: StemSeparator {
    /// Longueur de la tranche, en échantillons : `segment × samplerate` du modèle.
    static let segment = 343_980
    static let sampleRate = 44_100.0
    static let channels = 2
    /// Recouvrement entre tranches voisines, comme dans Demucs.
    static let overlap = 0.25

    func separate(fileAt url: URL,
                  progress: @escaping (Double) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> [Stem: [[Float]]] {
        guard StemStore.hasModel else { throw SeparationFailure.modelMissing }

        var mix = try Self.loadForNetwork(url)
        let length = mix[0].count
        guard length > 0 else { throw SeparationFailure.engine("morceau vide") }

        // Demucs travaille sur un signal recentré et réduit, et rend le résultat à
        // la même échelle. Les deux scalaires sont calculés sur la moyenne des
        // canaux, comme dans `separate.py` — pas canal par canal, ce qui
        // déplacerait l'image stéréo.
        let (mean, deviation) = Self.moments(of: mix)
        let shift = Float(-mean), scale = Float(1 / deviation)
        for c in 0..<mix.count {
            // Un seul tampon en entrée **et** en sortie d'un appel vDSP est un
            // accès exclusif violé : Swift n'est alors tenu à rien, et ce qui en
            // sort ici était `nan` de bout en bout. On passe donc par un pointeur
            // unique, qui décrit exactement l'opération sur place voulue.
            mix[c].withUnsafeMutableBufferPointer { buffer in
                let p = buffer.baseAddress!
                var s = shift, m = scale
                vDSP_vsadd(p, 1, &s, p, 1, vDSP_Length(length))
                vDSP_vsmul(p, 1, &m, p, 1, vDSP_Length(length))
            }
        }
        guard mix[0].allSatisfy(\.isFinite) else {
            throw SeparationFailure.engine("signal d'entrée non exploitable")
        }

        let step = Int(Double(Self.segment) * (1 - Self.overlap))
        let starts = Array(stride(from: 0, to: length, by: step))
        let window = Self.transitionWindow()
        let total = Double(starts.count)
        var done = 0.0

        guard let fourier = DemucsFourier() else {
            throw SeparationFailure.engine("transformée de Fourier indisponible")
        }

        let environment: ORTEnv
        do {
            environment = try ORTEnv(loggingLevel: .warning)
        } catch {
            throw SeparationFailure.engine("environnement ONNX indisponible — \(error.localizedDescription)")
        }

        let session = try Self.session(in: environment)

        // Un accumulateur par piste : le réseau les rend toutes ensemble.
        var sums = Stem.separated.map { _ in
            [[Float]](repeating: [Float](repeating: 0, count: length), count: Self.channels)
        }
        var weights = [Float](repeating: 0, count: length)

        for start in starts {
            if isCancelled() { throw SeparationFailure.cancelled }
            let count = min(Self.segment, length - start)
            let voices = try Self.apply(session, fourier: fourier,
                                        to: mix, from: start, count: count)

            // Fondu enchaîné : chaque tranche est pesée par une fenêtre
            // triangulaire, et l'on divise à la fin par la somme des poids. Sans
            // cela, la couture s'entendrait toutes les 5,8 s.
            for (source, _) in Stem.separated.enumerated() {
                for c in 0..<Self.channels {
                    let voice = voices[source * Self.channels + c]
                    for i in 0..<count {
                        sums[source][c][start + i] += window[i] * voice[i]
                    }
                }
            }
            for i in 0..<count { weights[start + i] += window[i] }

            done += 1
            progress(done / total)
        }

        var result: [Stem: [[Float]]] = [:]
        for (source, stem) in Stem.separated.enumerated() {
            // Normalisation par les poids et retour à l'échelle d'origine, en un
            // seul passage.
            for c in 0..<Self.channels {
                for i in 0..<length {
                    let w = weights[i]
                    sums[source][c][i] = w > 0
                        ? sums[source][c][i] / w * Float(deviation) + Float(mean) : 0
                }
            }
            // Une piste non finie ne doit jamais atteindre le disque : elle
            // s'écrirait sans bruit, se relirait sans erreur, et ne se verrait
            // qu'au moment où le spectrogramme resterait noir.
            guard sums[source].allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                throw SeparationFailure.engine("piste « \(stem.label) » non finie")
            }
            result[stem] = sums[source]
        }
        return result
    }

    // MARK: Une tranche

    /// Applique le réseau à une tranche et rend ses huit voies — quatre sources,
    /// deux canaux.
    ///
    /// Le graphe ne fait plus les transformées : on lui donne le spectre en même
    /// temps que la forme d'onde — dont sa branche temporelle a besoin — et il rend
    /// le spectre masqué plus cette branche. La transformée inverse et le recollement
    /// des deux branches se font ici.
    private static func apply(_ session: ORTSession, fourier: DemucsFourier,
                              to mix: [[Float]],
                              from start: Int, count: Int) throws -> [[Float]] {
        // La tranche est complétée par du silence quand on arrive au bout : le
        // réseau n'accepte qu'une taille, celle sur laquelle il a été figé.
        var flat = [Float](repeating: 0, count: channels * segment)
        for c in 0..<channels {
            mix[c].withUnsafeBufferPointer { source in
                flat.withUnsafeMutableBufferPointer { destination in
                    (destination.baseAddress! + c * segment)
                        .update(from: source.baseAddress! + start, count: count)
                }
            }
        }

        // Le spectre, rangé comme PyTorch : (canal, raie, trame, réel/imaginaire).
        let bins = DemucsFourier.bins
        let frames = DemucsFourier.frames(for: segment)
        let plane = bins * frames
        var spec = [Float](repeating: 0, count: channels * plane * 2)
        for c in 0..<channels {
            let (real, imaginary) = fourier.spectrogram(
                of: Array(flat[c * segment..<(c + 1) * segment]))
            let base = c * plane * 2
            for k in 0..<plane {
                spec[base + k * 2] = real[k]
                spec[base + k * 2 + 1] = imaginary[k]
            }
        }

        let mixData = NSMutableData(bytes: &flat, length: flat.count * MemoryLayout<Float>.size)
        let specData = NSMutableData(bytes: &spec, length: spec.count * MemoryLayout<Float>.size)
        let inputs = [
            "mix": try ORTValue(tensorData: mixData, elementType: .float,
                                shape: [1, NSNumber(value: channels), NSNumber(value: segment)]),
            "spec": try ORTValue(tensorData: specData, elementType: .float,
                                 shape: [1, NSNumber(value: channels), NSNumber(value: bins),
                                         NSNumber(value: frames), 2]),
        ]
        let outputs = try session.run(withInputs: inputs,
                                      outputNames: ["zout", "xt"], runOptions: nil)
        guard let zout = outputs["zout"], let xt = outputs["xt"] else {
            throw SeparationFailure.engine("le réseau n'a rien rendu")
        }
        let spectra = try zout.tensorData() as Data
        let temporal = try xt.tensorData() as Data

        let voices = Stem.separated.count * channels
        guard spectra.count >= voices * plane * 2 * MemoryLayout<Float>.size,
              temporal.count >= voices * segment * MemoryLayout<Float>.size else {
            throw SeparationFailure.engine("sortie de taille inattendue")
        }

        return spectra.withUnsafeBytes { zBytes -> [[Float]] in
            temporal.withUnsafeBytes { tBytes -> [[Float]] in
                let z = zBytes.bindMemory(to: Float.self)
                let t = tBytes.bindMemory(to: Float.self)
                var real = [Float](repeating: 0, count: plane)
                var imaginary = [Float](repeating: 0, count: plane)
                return (0..<voices).map { v in
                    let base = v * plane * 2
                    for k in 0..<plane {
                        real[k] = z[base + k * 2]
                        imaginary[k] = z[base + k * 2 + 1]
                    }
                    // Les deux branches se rejoignent ici, comme le faisait la
                    // dernière ligne du réseau.
                    let spectral = fourier.signal(real: real, imaginary: imaginary,
                                                  length: segment)
                    var voice = [Float](repeating: 0, count: count)
                    let offset = v * segment
                    for i in 0..<count { voice[i] = spectral[i] + t[offset + i] }
                    return voice
                }
            }
        }
    }

    private static func session(in environment: ORTEnv) throws -> ORTSession {
        guard let file = StemStore.modelFile else {
            throw SeparationFailure.modelMissing
        }
        do {
            let options = try ORTSessionOptions()
            // **Pas de CoreML ici**, et c'est mesuré, pas supposé. CoreML calcule en
            // demi-précision : ce réseau contient une constante de 4,1 × 10¹¹ —
            // la normalisation de la transformée inverse — qui déborde des 65 504
            // que ce format supporte. Elle devient infinie, et toute la piste avec.
            // C'est la même limite qui avait fait échouer la conversion hors ligne.
            //
            // Le processeur n'y perd rien, au contraire : sur ce modèle il est deux
            // fois plus rapide (1,7 s contre 3,4 s par tranche) et charge la session
            // en 0,3 s au lieu de 18. Le repli est ici le meilleur chemin.
            return try ORTSession(env: environment, modelPath: file.path,
                                  sessionOptions: options)
        } catch {
            throw SeparationFailure.modelUnreadable(error.localizedDescription)
        }
    }

    // MARK: Préparation du signal

    /// Fenêtre triangulaire de recollement, telle que Demucs la construit : elle
    /// monte jusqu'au milieu puis redescend, si bien que deux tranches voisines se
    /// relaient sans saut.
    static func transitionWindow() -> [Float] {
        let half = segment / 2
        var window = [Float](repeating: 0, count: segment)
        for i in 0..<half { window[i] = Float(i + 1) }
        for i in half..<segment { window[i] = Float(segment - i) }
        let peak = Float(half)
        for i in 0..<segment { window[i] /= peak }
        return window
    }

    /// Moyenne et écart-type du signal moyenné sur les canaux.
    ///
    /// Calculés à la main plutôt qu'avec `vDSP_normalize`, dont la variante sans
    /// tampon de sortie n'est pas ce qu'on croit — et en double précision, parce
    /// qu'une somme de dix millions de carrés en simple précision perd ses derniers
    /// chiffres bien avant la fin.
    static func moments(of mix: [[Float]]) -> (Double, Double) {
        let length = mix[0].count
        guard length > 0, !mix.isEmpty else { return (0, 1) }
        var total = 0.0, totalSquares = 0.0
        for i in 0..<length {
            var averaged = 0.0
            for channel in mix { averaged += Double(channel[i]) }
            averaged /= Double(mix.count)
            total += averaged
            totalSquares += averaged * averaged
        }
        let mean = total / Double(length)
        let variance = max(totalSquares / Double(length) - mean * mean, 0)
        let deviation = variance.squareRoot()
        // Un signal parfaitement plat donnerait un écart-type nul : on ne divise
        // pas par lui.
        return (mean, deviation > 1e-8 ? deviation : 1)
    }

    /// Charge le morceau tel que le réseau l'attend : stéréo, 44,1 kHz, flottant.
    ///
    /// Le rééchantillonnage n'est pas une politesse — le réseau a appris à cette
    /// fréquence-là, et lui donner du 48 kHz reviendrait à lui présenter une musique
    /// transposée d'un demi-ton et jouée trop vite.
    static func loadForNetwork(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw SeparationFailure.engine("format d'entrée inutilisable") }

        let block: AVAudioFrameCount = 1 << 16
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: block),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: block * 2)
        else { throw SeparationFailure.engine("tampons indisponibles") }

        var result = [[Float]](repeating: [], count: channels)
        var finished = false
        while !finished {
            var failure: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &failure) { _, outStatus in
                input.frameLength = 0
                if file.framePosition < file.length {
                    try? file.read(into: input, frameCount: block)
                }
                if input.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let failure { throw SeparationFailure.engine(failure.localizedDescription) }

            let produced = Int(output.frameLength)
            if produced > 0, let data = output.floatChannelData {
                for c in 0..<channels {
                    result[c].append(contentsOf:
                        UnsafeBufferPointer(start: data[c], count: produced))
                }
            }
            if status == .endOfStream || status == .error { finished = true }
            if status == .inputRanDry && produced == 0 { finished = true }
        }
        guard !result[0].isEmpty else { throw SeparationFailure.engine("aucun échantillon lu") }
        return result
    }
}
