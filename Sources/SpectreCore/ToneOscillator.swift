import Foundation

/// Oscillateur de la sinusoïde d'écoute.
///
/// Séparé du moteur audio pour deux raisons : le bloc de rendu ne doit rien faire
/// d'autre que du calcul, et tout ce qui décide de la qualité du son — glissando,
/// fondus, continuité de la phase — devient vérifiable sans carte son.
///
/// Rien ne saute jamais :
///
/// - la **fréquence** rejoint sa consigne par un filtre du premier ordre, si bien
///   qu'un déplacement de souris s'entend comme un portamento ;
/// - le **gain** fait de même, en plus rapide : sans ce fondu, chaque début et
///   chaque fin de note claquerait ;
/// - la **phase** n'est jamais remise à zéro, y compris quand on repose la
///   fréquence d'un bond — une discontinuité de phase s'entend comme un clic,
///   exactement comme une discontinuité d'amplitude.
public struct ToneOscillator {
    public let sampleRate: Double
    private let glide: Double
    private let fade: Double

    public private(set) var frequency: Double
    public private(set) var gain: Double = 0
    private var phase: Double = 0

    /// - Parameters:
    ///   - glideSeconds: constante de temps du portamento.
    ///   - fadeSeconds: constante de temps des fondus d'entrée et de sortie.
    public init(sampleRate: Double, frequency: Double = 440,
         glideSeconds: Double = 0.02, fadeSeconds: Double = 0.008) {
        self.sampleRate = max(sampleRate, 1)
        self.frequency = frequency
        glide = 1 - exp(-1 / (max(glideSeconds, 1e-6) * self.sampleRate))
        fade = 1 - exp(-1 / (max(fadeSeconds, 1e-6) * self.sampleRate))
    }

    /// Repose la fréquence sans toucher à la phase. Utile pour les grands écarts,
    /// qu'on ne veut pas entendre glisser : traverser l'image de bas en haut
    /// sonnerait comme une sirène.
    public mutating func jump(to frequency: Double) {
        self.frequency = frequency
    }

    /// Un échantillon, en avançant d'un pas vers la consigne.
    ///
    /// C'est l'unité que partagent la sinusoïde seule et l'accord : une voix ne
    /// sait produire qu'un échantillon à la fois, et c'est à l'appelant de décider
    /// s'il l'écrit ou s'il l'additionne à celles des autres voix.
    public mutating func nextSample(targetFrequency: Double, targetGain: Double) -> Double {
        let twoPi = 2 * Double.pi
        frequency += (targetFrequency - frequency) * glide
        gain += (targetGain - gain) * fade
        phase += twoPi * frequency / sampleRate
        if phase > twoPi { phase -= twoPi }
        return sin(phase) * gain
    }

    /// Produit `count` échantillons en tendant vers la consigne.
    public mutating func render(targetFrequency: Double, targetGain: Double,
                         into output: UnsafeMutableBufferPointer<Float>, count: Int) {
        for i in 0..<min(count, output.count) {
            output[i] = Float(nextSample(targetFrequency: targetFrequency,
                                         targetGain: targetGain))
        }
    }
}

/// Plusieurs voix, pour faire entendre un accord entier.
///
/// Chaque voix est une `ToneOscillator` complète : elle garde sa phase, glisse
/// vers sa fréquence et fond son gain comme la sinusoïde seule. Une voix dont la
/// consigne de gain tombe à zéro s'éteint donc en fondu et reste disponible —
/// c'est ce qui permet de passer d'un accord de quatre notes à un de trois sans
/// que la note en trop claque en partant.
///
/// **Le niveau baisse avec le nombre de voix.** Quatre sinusoïdes de même
/// amplitude peuvent aligner leurs phases et sommer quatre fois l'amplitude d'une
/// seule ; sans correction, un accord serait à la fois plus fort et écrêté. La
/// racine du nombre de voix est le compromis d'usage : la puissance reste
/// constante, et le pire cas ne dépasse pas √n fois une voix au lieu de n.
public struct ChordOscillator {
    public let voiceCount: Int
    private var voices: [ToneOscillator]

    public init(sampleRate: Double, voiceCount: Int,
                glideSeconds: Double = 0.02, fadeSeconds: Double = 0.008) {
        self.voiceCount = max(voiceCount, 1)
        voices = (0..<self.voiceCount).map { _ in
            ToneOscillator(sampleRate: sampleRate, glideSeconds: glideSeconds,
                           fadeSeconds: fadeSeconds)
        }
    }

    /// Repose la fréquence d'une voix sans toucher à sa phase.
    public mutating func jump(voice: Int, to frequency: Double) {
        guard voices.indices.contains(voice) else { return }
        voices[voice].jump(to: frequency)
    }

    /// Le niveau que doit porter **chaque** voix pour qu'un accord de `count`
    /// notes sonne aussi fort qu'une note seule à `level`.
    public static func perVoiceLevel(_ level: Double, voices count: Int) -> Double {
        level / Double(max(count, 1)).squareRoot()
    }

    /// Somme les voix dans `output`.
    ///
    /// - Parameter targets: deux `Double` par voix — fréquence puis gain. Un
    ///   tampon plutôt qu'un tableau de couples : ce code tourne dans le bloc de
    ///   rendu audio, où l'on ne veut ni allocation ni comptage de références.
    public mutating func render(targets: UnsafeBufferPointer<Double>,
                                into output: UnsafeMutableBufferPointer<Float>,
                                count: Int) {
        let usable = min(voiceCount, targets.count / 2)
        for i in 0..<min(count, output.count) {
            var sum = 0.0
            for voice in 0..<usable {
                sum += voices[voice].nextSample(targetFrequency: targets[2 * voice],
                                                targetGain: targets[2 * voice + 1])
            }
            output[i] = Float(sum)
        }
    }
}
