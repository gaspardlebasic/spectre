import AVFoundation
import Foundation
import SpectreCore

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
public final class ToneGenerator {
    /// Assez pour l'accord le plus fourni que le relevé sait entourer.
    public static let maxVoices = 8

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    /// Deux `Double` par voix : fréquence visée, puis gain visé.
    private let controls =
        UnsafeMutablePointer<Double>.allocate(capacity: 2 * ToneGenerator.maxVoices)
    private var release: DispatchWorkItem?

    /// Niveau de la sinusoïde. Assez pour s'entendre par-dessus rien, assez peu
    /// pour ne pas couvrir la musique quand on écoute les deux.
    ///
    /// Une sinusoïde pure s'entend bien plus fort qu'un signal musical de même
    /// amplitude — toute son énergie tient dans une seule bande critique. D'où ce
    /// niveau volontairement bas : 0,08, soit 6 dB sous le réglage d'origine.
    private let level = 0.08

    /// État du thread audio, touché nulle part ailleurs.
    private var oscillator: ChordOscillator

    public init() {
        for voice in 0..<Self.maxVoices {
            controls[2 * voice] = 440
            controls[2 * voice + 1] = 0
        }

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48000
        oscillator = ChordOscillator(sampleRate: sampleRate, voiceCount: Self.maxVoices)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return }

        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first,
                  let samples = first.mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            let count = Int(frameCount)
            let targets = UnsafeBufferPointer(start: self.controls,
                                              count: 2 * Self.maxVoices)
            self.oscillator.render(targets: targets,
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
    public func play(_ frequency: Double?) {
        guard let frequency, frequency > 0 else { return stopImmediately() }
        play(chord: [frequency])
    }

    /// Fait sonner plusieurs hauteurs ensemble.
    ///
    /// Les voix en trop ne sont pas coupées mais **ramenées à zéro** : elles
    /// s'éteignent alors dans le même fondu que tout le reste. Couper net une voix
    /// qui sonnait s'entendrait comme un clic, exactement au moment où l'on passe
    /// d'un accord à un autre.
    public func play(chord frequencies: [Double]) {
        release?.cancel()
        release = nil
        let wanted = frequencies.filter { $0 > 0 }.prefix(Self.maxVoices)
        guard !wanted.isEmpty else { return silence() }

        let perVoice = ChordOscillator.perVoiceLevel(level, voices: wanted.count)
        for (voice, frequency) in wanted.enumerated() {
            // Un saut de plus d'une octave ne se glisse pas, il se repose : sinon
            // on entend une sirène en traversant l'image de bas en haut. Une voix
            // muette n'a rien à glisser non plus — elle se pose où on la veut.
            if controls[2 * voice + 1] == 0
                || abs(log2(frequency / controls[2 * voice])) > 1 {
                oscillator.jump(voice: voice, to: frequency)
            }
            controls[2 * voice] = frequency
            controls[2 * voice + 1] = perVoice
        }
        for voice in wanted.count..<Self.maxVoices { controls[2 * voice + 1] = 0 }
        start()
    }

    /// Coupe le son en fondu, puis arrête le moteur si on n'y revient pas.
    public func stop() {
        silence()
        let work = DispatchWorkItem { [weak self] in self?.engine.pause() }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func silence() {
        for voice in 0..<Self.maxVoices { controls[2 * voice + 1] = 0 }
    }

    /// Comme `stop()`, mais sans changer l'état d'une extinction déjà programmée :
    /// c'est le chemin de la sinusoïde d'écoute, appelée à chaque mouvement de
    /// souris et qui n'a pas à relancer un compte à rebours à chaque fois.
    private func stopImmediately() { silence() }

    private func start() {
        guard source != nil, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Spectre : sinusoïde d'écoute indisponible — \(error)")
        }
    }
}
