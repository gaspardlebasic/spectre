import CPont
import Foundation
import SpectreCore
import SpectreModele

/// La sinusoïde d'écoute : la raie qu'on désigne, et l'accord qu'on survole.
///
/// `ChordOscillator` fait tout le son, et il est dans le noyau — c'est le même
/// oscillateur que sur le Mac, avec les mêmes glissandos et les mêmes fondus. Ce
/// fichier n'est qu'un périphérique et un rappel, et il reprend la même façon de
/// traverser la frontière du fil audio que `SpectreMac/ToneGenerator` : **un
/// tampon de nombres, et aucune propriété lue à deux endroits.**
public final class SinusoideWindows: Sinusoide {

    /// Douze voix : c'est ce qu'il faut pour un accord de sept notes avec ses
    /// doublures, et couper les plus hautes donnerait à entendre autre chose que ce
    /// qui est entouré.
    public static let voix = 12

    /// Deux `Double` par voix — fréquence visée, puis gain visé — et une case de
    /// plus, en queue, pour la forme d'onde. Elle traverse par le même chemin que
    /// le reste plutôt que d'être lue sur une propriété que deux fils toucheraient
    /// en même temps.
    private static let caseDeLaForme = 2 * SinusoideWindows.voix
    private let commandes =
        UnsafeMutablePointer<Double>.allocate(capacity: 2 * SinusoideWindows.voix + 1)

    /// Niveau de la sinusoïde. Assez pour s'entendre par-dessus rien, assez peu pour
    /// ne pas couvrir la musique quand on écoute les deux.
    ///
    /// Une sinusoïde pure s'entend bien plus fort qu'un signal musical de même
    /// amplitude — toute son énergie tient dans une seule bande critique. D'où ce
    /// niveau volontairement bas, le même que sur le Mac.
    private let niveau = 0.08

    /// État du fil audio, touché nulle part ailleurs.
    private var oscillateur: ChordOscillator
    private let verrou = NSLock()
    private var sortie: OpaquePointer?

    public var voixMaximales: Int { Self.voix }

    public init() {
        for voie in 0..<Self.voix {
            commandes[2 * voie] = 440
            commandes[2 * voie + 1] = 0
        }
        commandes[Self.caseDeLaForme] = Double(ToneWaveform.sine.rawValue)

        // 48 kHz : c'est la fréquence de mélange de presque tout périphérique
        // Windows, donc celle qui évite un rééchantillonnage. Et contrairement à la
        // lecture, rien ici n'est compté en images d'un fichier — la fréquence
        // exacte n'a aucune conséquence.
        let frequence = 48000.0
        oscillateur = ChordOscillator(sampleRate: frequence, voiceCount: Self.voix)

        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        let contexte = Unmanaged.passUnretained(self).toOpaque()
        sortie = erreur.withUnsafeMutableBufferPointer { tampon in
            spectre_sortie_ouvrir(frequence, rappelDeLaSinusoide, contexte, tampon.baseAddress)
        }
        if sortie == nil {
            Journal.erreur("sinusoïde : \(String(cString: erreur))")
        }
    }

    deinit {
        if let sortie { spectre_sortie_fermer(sortie) }
        commandes.deallocate()
    }

    /// Fait sonner une fréquence, ou fait taire si elle est nulle. Appeler aussi
    /// souvent qu'on veut : c'est le glissando qui absorbe les écarts.
    ///
    /// Une sinusoïde, et rien d'autre : c'est le chemin de la raie désignée dans le
    /// spectre, où le son doit être la fréquence pointée et pas un timbre bâti
    /// dessus.
    public func play(_ frequency: Double?) {
        guard let frequency, frequency > 0 else { return taire() }
        play(chord: [frequency], waveform: .sine)
    }

    /// Fait sonner plusieurs hauteurs ensemble.
    ///
    /// Les voix en trop ne sont pas coupées mais **ramenées à zéro** : elles
    /// s'éteignent alors dans le même fondu que tout le reste. Couper net une voix
    /// qui sonnait s'entendrait comme un clic, exactement au moment où l'on passe
    /// d'un accord à un autre.
    public func play(chord frequencies: [Double], waveform: ToneWaveform = .triangle) {
        let voulues = frequencies.filter { $0 > 0 }.prefix(Self.voix)
        guard !voulues.isEmpty else { return taire() }
        commandes[Self.caseDeLaForme] = Double(waveform.rawValue)

        let parVoix = ChordOscillator.perVoiceLevel(niveau, voices: voulues.count)
        for (voie, frequence) in voulues.enumerated() {
            // Un saut de plus d'une octave ne se glisse pas, il se repose : sinon on
            // entend une sirène en traversant l'image de bas en haut. Une voix
            // muette n'a rien à glisser non plus — elle se pose où on la veut.
            if commandes[2 * voie + 1] == 0
                || abs(log2(frequence / commandes[2 * voie])) > 1 {
                verrou.lock()
                oscillateur.jump(voice: voie, to: frequence)
                verrou.unlock()
            }
            commandes[2 * voie] = frequence
            commandes[2 * voie + 1] = parVoix
        }
        for voie in voulues.count..<Self.voix { commandes[2 * voie + 1] = 0 }
        if let sortie { spectre_sortie_jouer(sortie) }
    }

    public func stop() { taire() }

    /// Les gains passent à zéro, et le fondu de l'oscillateur fait le reste. Le
    /// périphérique, lui, continue de tourner sur du silence : le rouvrir à chaque
    /// note coûterait bien plus que de le laisser rendre des zéros.
    private func taire() {
        for voie in 0..<Self.voix { commandes[2 * voie + 1] = 0 }
    }

    fileprivate func remplir(_ destination: UnsafeMutablePointer<Float>,
                             images: Int, canaux: Int) -> Int {
        verrou.lock()
        defer { verrou.unlock() }
        let mono = UnsafeMutableBufferPointer(start: destination, count: images)
        let cibles = UnsafeBufferPointer(start: commandes, count: 2 * Self.voix)
        let forme = ToneWaveform(rawValue: Int(commandes[Self.caseDeLaForme])) ?? .sine
        oscillateur.render(targets: cibles, waveform: forme, into: mono, count: images)

        if canaux > 1 {
            var i = images - 1
            while i >= 0 {
                let v = destination[i]
                for c in 0..<canaux { destination[i * canaux + c] = v }
                i -= 1
            }
        }
        return images
    }
}

private let rappelDeLaSinusoide: SpectreRemplir = { destination, images, canaux, contexte in
    guard let destination, let contexte else { return 0 }
    let sinusoide = Unmanaged<SinusoideWindows>.fromOpaque(contexte).takeUnretainedValue()
    return Int32(sinusoide.remplir(destination, images: Int(images), canaux: Int(canaux)))
}
