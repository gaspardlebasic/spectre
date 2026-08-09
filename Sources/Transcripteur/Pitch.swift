import Foundation

enum Pitch {
    /// Les cinq touches noires, nommées par le haut ou par le bas. Aucune des deux
    /// écritures n'est plus juste que l'autre — c'est la tonalité qui tranche, et
    /// l'application ne la connaît pas — mais les bémols sont plus fréquents dans
    /// la plupart des répertoires, d'où le choix par défaut.
    static let sharpNames = ["Do", "Do♯", "Ré", "Ré♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]
    static let flatNames = ["Do", "Ré♭", "Ré", "Mi♭", "Mi", "Fa", "Sol♭", "Sol", "La♭", "La", "Si♭", "Si"]

    static func names(flats: Bool) -> [String] { flats ? flatNames : sharpNames }

    /// Diapason usuel, en hertz. Toutes les fonctions ci-dessous acceptent une
    /// autre référence : le La₃ ne vaut pas 440 Hz partout ni à toutes les époques.
    static let standardA = 440.0

    static func midi(from frequency: Double, referenceA: Double = standardA) -> Double {
        69 + 12 * log2(frequency / referenceA)
    }

    static func frequency(ofMidi midi: Double, referenceA: Double = standardA) -> Double {
        referenceA * pow(2, (midi - 69) / 12)
    }

    /// Nom de note français, écart en cents, et si on le demande le numéro
    /// d'octave — ex. « La4 +3¢ » ou « La +3¢ ». Au survol on s'en passe : ce qu'on
    /// cherche est la note, et le chiffre se lit déjà sur les repères d'octaves.
    static func noteName(for frequency: Double, referenceA: Double = standardA,
                         flats: Bool = true, withOctave: Bool = true) -> String {
        guard frequency > 0 else { return "—" }
        let m = midi(from: frequency, referenceA: referenceA)
        let rounded = Int(m.rounded())
        let cents = Int(((m - Double(rounded)) * 100).rounded())
        let name = names(flats: flats)[((rounded % 12) + 12) % 12]
        let octave = rounded / 12 - 1
        let sign = cents >= 0 ? "+" : "−"
        return withOctave ? "\(name)\(octave) \(sign)\(abs(cents))¢"
                          : "\(name) \(sign)\(abs(cents))¢"
    }

    /// Fréquences des Do contenues dans l'intervalle donné.
    static func octaveMarkers(from fmin: Double, to fmax: Double,
                              referenceA: Double = standardA) -> [(frequency: Double, label: String)] {
        var result: [(Double, String)] = []
        var octave = -1
        while octave <= 11 {
            let f = frequency(ofMidi: Double((octave + 1) * 12), referenceA: referenceA)
            if f > fmax { break }
            if f >= fmin { result.append((f, "Do\(octave)")) }
            octave += 1
        }
        return result
    }

    /// Écart d'un diapason par rapport à 440 Hz, en cents.
    static func centsFromStandard(_ referenceA: Double) -> Double {
        1200 * log2(referenceA / standardA)
    }
}
