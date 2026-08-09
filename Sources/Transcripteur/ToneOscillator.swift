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
struct ToneOscillator {
    let sampleRate: Double
    private let glide: Double
    private let fade: Double

    private(set) var frequency: Double
    private(set) var gain: Double = 0
    private var phase: Double = 0

    /// - Parameters:
    ///   - glideSeconds: constante de temps du portamento.
    ///   - fadeSeconds: constante de temps des fondus d'entrée et de sortie.
    init(sampleRate: Double, frequency: Double = 440,
         glideSeconds: Double = 0.02, fadeSeconds: Double = 0.008) {
        self.sampleRate = max(sampleRate, 1)
        self.frequency = frequency
        glide = 1 - exp(-1 / (max(glideSeconds, 1e-6) * self.sampleRate))
        fade = 1 - exp(-1 / (max(fadeSeconds, 1e-6) * self.sampleRate))
    }

    /// Repose la fréquence sans toucher à la phase. Utile pour les grands écarts,
    /// qu'on ne veut pas entendre glisser : traverser l'image de bas en haut
    /// sonnerait comme une sirène.
    mutating func jump(to frequency: Double) {
        self.frequency = frequency
    }

    /// Produit `count` échantillons en tendant vers la consigne.
    mutating func render(targetFrequency: Double, targetGain: Double,
                         into output: UnsafeMutableBufferPointer<Float>, count: Int) {
        let twoPi = 2 * Double.pi
        for i in 0..<min(count, output.count) {
            frequency += (targetFrequency - frequency) * glide
            gain += (targetGain - gain) * fade
            phase += twoPi * frequency / sampleRate
            if phase > twoPi { phase -= twoPi }
            output[i] = Float(sin(phase) * gain)
        }
    }
}
