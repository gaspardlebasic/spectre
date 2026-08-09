import AVFoundation
import Foundation

/// Sinusoïde d'écoute, jouée pendant qu'on tient le curseur sur une raie.
///
/// Entendre la hauteur qu'on désigne est le geste qui manque à un spectrogramme :
/// l'œil repère une raie, l'oreille confirme que c'est bien elle qu'on cherchait.
///
/// Deux précautions le rendent utilisable en continu :
///
/// - la **fréquence glisse** au lieu de sauter, si bien qu'un déplacement de
///   souris s'entend comme un portamento et non comme une suite de clics ;
/// - le **gain monte et descend en fondu**, sinon chaque début et chaque fin de
///   note claquerait.
///
/// Le son lui-même est produit par `ToneOscillator`, à part et sans audio, de
/// sorte que la qualité du signal se vérifie hors ligne. Ici il ne reste que le
/// branchement : le moteur, et le passage des consignes.
///
/// Ces consignes traversent la frontière du thread audio par une petite zone
/// allouée à part : le bloc de rendu n'y fait que des lectures de `Double`
/// alignés, sans verrou ni allocation — les deux choses qu'on ne peut pas se
/// permettre là où un retard s'entend.
final class ToneGenerator {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    /// [0] = fréquence visée, [1] = gain visé.
    private let controls = UnsafeMutablePointer<Double>.allocate(capacity: 2)
    private var release: DispatchWorkItem?

    /// Niveau de la sinusoïde. Assez pour s'entendre par-dessus rien, assez peu
    /// pour ne pas couvrir la musique quand on écoute les deux.
    private let level = 0.16

    /// État du thread audio, touché nulle part ailleurs.
    private var oscillator: ToneOscillator

    init() {
        controls[0] = 440
        controls[1] = 0

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48000
        oscillator = ToneOscillator(sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return }

        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first,
                  let samples = first.mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            let count = Int(frameCount)
            self.oscillator.render(targetFrequency: self.controls[0],
                                   targetGain: self.controls[1],
                                   into: UnsafeMutableBufferPointer(start: samples, count: count),
                                   count: count)
            // Les autres canaux reçoivent la copie du premier.
            for buffer in list.dropFirst() {
                buffer.mData?.assumingMemoryBound(to: Float.self)
                    .update(from: samples, count: count)
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    deinit {
        engine.stop()
        controls.deallocate()
    }

    /// Fait sonner une fréquence, ou fait taire si elle est nulle. Appeler aussi
    /// souvent qu'on veut : c'est le glissando qui absorbe les écarts.
    func play(_ frequency: Double?) {
        release?.cancel()
        release = nil
        guard let frequency, frequency > 0 else { return silence() }

        // Un saut de plus d'une octave ne se glisse pas, il se repose : sinon on
        // entend une sirène en traversant l'image de bas en haut.
        if abs(log2(frequency / controls[0])) > 1 { oscillator.jump(to: frequency) }
        controls[0] = frequency
        controls[1] = level
        start()
    }

    /// Coupe le son en fondu, puis arrête le moteur si on n'y revient pas.
    func stop() {
        silence()
        let work = DispatchWorkItem { [weak self] in self?.engine.pause() }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func silence() { controls[1] = 0 }

    private func start() {
        guard source != nil, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Transcripteur : sinusoïde d'écoute indisponible — \(error)")
        }
    }
}
