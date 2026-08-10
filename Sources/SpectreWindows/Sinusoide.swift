import CMiniaudio
import Foundation
import SpectreCore

/// Sinusoïde d'écoute, jouée pendant qu'on tient le curseur sur une raie.
///
/// Entendre la hauteur qu'on désigne est le geste qui manque à un spectrogramme :
/// l'œil repère une raie, l'oreille confirme que c'est bien elle qu'on cherchait.
///
/// Le son lui-même vient de `ToneOscillator`, partagé avec macOS et vérifié hors
/// audio par `Tools/PlaybackCheck` : glissando, fondus, continuité de la phase.
/// Ne reste ici que le branchement — un second périphérique, à côté de celui du
/// morceau, comme sur macOS où c'est un second nœud du moteur.
///
/// **Les consignes traversent la frontière du fil temps réel par deux `Double`
/// alignés**, lus sans verrou. C'est le même parti que `ToneGenerator` : un
/// verrou pris par le fil de l'interface pendant que le fil audio l'attend, ce
/// sont des échantillons manqués.
public final class ToneOutput {
    private var device = ma_device()
    private var configured = false

    /// [0] = fréquence visée, [1] = gain visé.
    private let consignes = UnsafeMutablePointer<Double>.allocate(capacity: 2)
    private var oscillateur: ToneOscillator
    private var enMarche = false

    /// Niveau de la sinusoïde. Assez pour s'entendre par-dessus rien, assez peu
    /// pour ne pas couvrir la musique quand on écoute les deux.
    ///
    /// Une sinusoïde pure s'entend bien plus fort qu'un signal musical de même
    /// amplitude — toute son énergie tient dans une seule bande critique.
    private let niveau = 0.08

    public init?(sampleRate: Double = 48000) {
        consignes[0] = 440
        consignes[1] = 0
        oscillateur = ToneOscillator(sampleRate: sampleRate)

        var config = ma_device_config_init(ma_device_type_playback)
        config.playback.format = ma_format_f32
        config.playback.channels = 1
        config.sampleRate = UInt32(sampleRate)
        config.dataCallback = { pDevice, pOutput, _, frameCount in
            guard let pDevice, let pOutput,
                  let moi = pDevice.pointee.pUserData else { return }
            let sortie = Unmanaged<ToneOutput>.fromOpaque(moi).takeUnretainedValue()
            sortie.remplir(pOutput.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
        }
        config.pUserData = Unmanaged.passUnretained(self).toOpaque()

        guard ma_device_init(nil, &config, &device) == MA_SUCCESS else {
            consignes.deallocate()
            return nil
        }
        configured = true
    }

    deinit {
        if configured { ma_device_uninit(&device) }
        consignes.deallocate()
    }

    private func remplir(_ sortie: UnsafeMutablePointer<Float>, frames: Int) {
        oscillateur.render(targetFrequency: consignes[0], targetGain: consignes[1],
                           into: UnsafeMutableBufferPointer(start: sortie, count: frames),
                           count: frames)
    }

    /// Fait sonner une fréquence, ou fait taire si elle est nulle. Appeler aussi
    /// souvent qu'on veut : c'est le glissando qui absorbe les écarts.
    public func play(_ frequency: Double?) {
        guard let frequency, frequency > 0 else { return silence() }

        // Un saut de plus d'une octave ne se glisse pas, il se repose : sinon on
        // entend une sirène en traversant l'image de bas en haut.
        if abs(log2(frequency / consignes[0])) > 1 { oscillateur.jump(to: frequency) }
        consignes[0] = frequency
        consignes[1] = niveau
        demarre()
    }

    /// Coupe en fondu. Le périphérique continue de tourner sur du silence : le
    /// rouvrir à chaque raie coûterait plus cher que de le laisser ouvert, et
    /// s'entendrait — un démarrage de périphérique n'est pas instantané.
    public func stop() { silence() }

    private func silence() { consignes[1] = 0 }

    private func demarre() {
        guard configured, !enMarche else { return }
        if ma_device_start(&device) == MA_SUCCESS { enMarche = true }
    }
}
