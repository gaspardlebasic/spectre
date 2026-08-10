import CMiniaudio
import CStretch
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

    // ── Ralenti et transposition
    //
    // Le vocodeur ne connaît pas la vitesse : elle n'existe que dans le rapport
    // entre ce qu'on lui donne et ce qu'on lui demande, bloc par bloc. Voir
    // `Sources/CStretch/include/spectre_stretch.h`.
    private var stretch: OpaquePointer?
    private var storedSpeed: Double = 1
    private var storedTranspose: Double = 0

    /// Tampons du chemin ralenti, alloués une fois : le rappel audio n'alloue pas.
    private var monoEntree: [Float]
    private var monoSortie: [Float]
    private static let maxImages = 4096

    /// Ni ralenti ni transposé : le fichier tel quel.
    ///
    /// À ×1 et +0, un vocodeur laissé en service continue de découper et recoller
    /// le signal pour un résultat censé être identique — travail inutile, et
    /// surtout irrégulier, ce qui est le pire cas pour une échéance temps réel.
    /// Le retirer du chemin laisse passer les échantillons tels quels. C'est le
    /// même parti que `Player.applyTimePitch` sur macOS.
    public var isNeutral: Bool { storedSpeed == 1 && storedTranspose == 0 }

    public var speed: Double {
        get { lock.lock(); defer { lock.unlock() }; return storedSpeed }
        set {
            lock.lock()
            storedSpeed = min(max(newValue, 1.0 / 32), 4)
            lock.unlock()
        }
    }

    public var transpose: Double {
        get { lock.lock(); defer { lock.unlock() }; return storedTranspose }
        set {
            lock.lock()
            storedTranspose = min(max(newValue, -24), 24)
            if let stretch { spectre_stretch_transposer(stretch, storedTranspose) }
            lock.unlock()
        }
    }

    /// Position de lecture en secondes, relue par l'interface à chaque image.
    ///
    /// Le vocodeur retient une centaine de millisecondes : la chaîne a donc
    /// consommé un peu plus que ce qu'on entend. Sans cette correction, la tête
    /// de lecture précède le son de façon visible dès qu'on ralentit, ce qui est
    /// précisément le moment où l'on regarde le plus attentivement.
    public var currentTime: Double {
        lock.lock(); defer { lock.unlock() }
        guard !isNeutral, let stretch else { return chain.currentTime }
        let retard = Double(Int(spectre_stretch_latence(stretch))) / chain.sampleRate
        return max(chain.currentTime - retard, 0)
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    public init?(samples: [Float], channels: Int, sampleRate: Double) {
        chain = PlaybackChain(samples: samples, channels: channels, sampleRate: sampleRate)
        monoEntree = [Float](repeating: 0, count: AudioOutput.maxImages * 4)
        monoSortie = [Float](repeating: 0, count: AudioOutput.maxImages)
        stretch = spectre_stretch_creer(1, sampleRate)

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
        // Le périphérique d'abord : tant qu'il tourne, son rappel peut être en
        // train de lire ce qu'on s'apprête à libérer.
        if configured { ma_device_uninit(&device) }
        if let stretch { spectre_stretch_detruire(stretch) }
    }

    private func remplir(_ sortie: UnsafeMutablePointer<Float>, frames: Int) {
        let tampon = UnsafeMutableBufferPointer(start: sortie, count: frames * 2)
        lock.lock()
        defer { lock.unlock() }

        guard playing else {
            for i in 0..<tampon.count { tampon[i] = 0 }
            return
        }

        guard !isNeutral, let stretch, frames <= AudioOutput.maxImages else {
            let rendues = chain.render(into: tampon, frames: frames, outputChannels: 2)
            // Arrivé au bout hors boucle, on s'arrête plutôt que de laisser le
            // périphérique tourner sur du silence.
            if rendues < frames { playing = false }
            return
        }

        // Pour rendre `frames` échantillons à la vitesse `v`, il en faut `v` fois
        // plus en entrée. La chaîne — boucle, filtre de bande, position — travaille
        // donc dans le temps du fichier, et le vocodeur seul connaît celui de la
        // sortie.
        let besoin = min(Int((Double(frames) * storedSpeed).rounded()), monoEntree.count)
        var rendues = 0
        monoEntree.withUnsafeMutableBufferPointer { e in
            rendues = chain.render(into: e, frames: besoin, outputChannels: 1)
        }

        monoEntree.withUnsafeBufferPointer { e in
            monoSortie.withUnsafeMutableBufferPointer { s in
                spectre_stretch_traiter(stretch, e.baseAddress, Int32(besoin),
                                        s.baseAddress, Int32(frames))
            }
        }

        // Mono vers stéréo : la même valeur des deux côtés, comme le fait la
        // chaîne elle-même quand elle écrit directement.
        for i in 0..<frames {
            let v = monoSortie[i]
            tampon[i * 2] = v
            tampon[i * 2 + 1] = v
        }

        // La queue du vocodeur vaut encore quelques blocs après la fin du
        // fichier : on ne s'arrête qu'une fois qu'elle est sortie, sinon la fin
        // du morceau est coupée d'une centaine de millisecondes.
        if rendues < besoin {
            silenceRestant -= frames
            if silenceRestant <= 0 { playing = false }
        } else {
            silenceRestant = Int(spectre_stretch_latence(stretch))
        }
    }

    /// Ce qu'il reste à pousser pour vider le vocodeur après la fin du fichier.
    private var silenceRestant = 0

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
        lock.lock()
        chain.seek(to: time)
        // Sans cela le vocodeur recolle l'endroit d'où l'on vient à celui où
        // l'on va : on entend une bouillie d'une centaine de millisecondes à
        // chaque clic, ce qui est justement le geste le plus fréquent.
        if let stretch { spectre_stretch_reinitialiser(stretch) }
        lock.unlock()
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
