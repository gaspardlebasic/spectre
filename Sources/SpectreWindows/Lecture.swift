import CMiniaudio
import Foundation
import SpectreCore

/// La sortie audio sous Windows.
///
/// miniaudio ouvre le périphérique — WASAPI ici — et appelle un rappel quand il
/// lui faut des échantillons. Tout ce que ce rappel fait tient dans
/// `PlaybackChain`, qui est portable et déjà éprouvée hors ligne : boucle,
/// position, filtre de bande. Ne reste donc ici que la plomberie.
///
/// **Le rappel tourne sur un fil temps réel.** Il ne doit rien allouer, rien
/// verrouiller longtemps, et surtout ne jamais attendre : un rappel en retard,
/// c'est un trou dans le son. D'où le verrou pris et rendu immédiatement, et
/// aucune allocation dans le chemin chaud.
public final class AudioOutput {
    private var device = ma_device()
    private var configured = false

    /// La chaîne, partagée avec le fil de l'interface.
    private var chain: PlaybackChain
    private let lock = NSLock()
    private var playing = false

    /// Position de lecture en secondes, relue par l'interface à chaque image.
    public var currentTime: Double {
        lock.lock(); defer { lock.unlock() }
        return chain.currentTime
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    public init?(samples: [Float], channels: Int, sampleRate: Double) {
        chain = PlaybackChain(samples: samples, channels: channels, sampleRate: sampleRate)

        var config = ma_device_config_init(ma_device_type_playback)
        config.playback.format = ma_format_f32
        config.playback.channels = 2
        // On demande la fréquence du fichier : miniaudio rééchantillonne si le
        // périphérique ne la tient pas, ce qui évite d'avoir à le faire ici.
        config.sampleRate = UInt32(sampleRate)
        config.dataCallback = { pDevice, pOutput, _, frameCount in
            guard let pDevice, let pOutput,
                  let sortie = pDevice.pointee.pUserData else { return }
            let moi = Unmanaged<AudioOutput>.fromOpaque(sortie).takeUnretainedValue()
            moi.remplir(pOutput.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
        }
        config.pUserData = Unmanaged.passUnretained(self).toOpaque()

        guard ma_device_init(nil, &config, &device) == MA_SUCCESS else { return nil }
        configured = true
    }

    deinit {
        if configured { ma_device_uninit(&device) }
    }

    private func remplir(_ sortie: UnsafeMutablePointer<Float>, frames: Int) {
        let tampon = UnsafeMutableBufferPointer(start: sortie, count: frames * 2)
        lock.lock()
        if playing {
            let rendues = chain.render(into: tampon, frames: frames, outputChannels: 2)
            // Arrivé au bout hors boucle, on s'arrête plutôt que de laisser le
            // périphérique tourner sur du silence.
            if rendues < frames { playing = false }
        } else {
            for i in 0..<tampon.count { tampon[i] = 0 }
        }
        lock.unlock()
    }

    public func play(from time: Double? = nil) {
        lock.lock()
        if let time { chain.seek(to: time) }
        playing = true
        lock.unlock()
        if configured { ma_device_start(&device) }
    }

    public func pause() {
        lock.lock(); playing = false; lock.unlock()
        if configured { ma_device_stop(&device) }
    }

    public func toggle(at time: Double) {
        if isPlaying { pause() } else { play(from: time) }
    }

    public func seek(to time: Double) {
        lock.lock(); chain.seek(to: time); lock.unlock()
    }

    public func setLoop(_ range: ClosedRange<Double>?) {
        lock.lock(); chain.setLoop(range); lock.unlock()
    }

    /// La bande écoutée : n'entendre que ce qu'on regarde.
    public func setBand(_ range: ClosedRange<Double>?) {
        lock.lock(); chain.setBand(range); lock.unlock()
    }

    public var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return chain.duration
    }
}
