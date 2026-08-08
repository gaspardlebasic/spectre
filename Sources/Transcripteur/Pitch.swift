import Foundation

enum Pitch {
    static let names = ["Do", "Do♯", "Ré", "Ré♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]

    /// Diapason usuel, en hertz. Toutes les fonctions ci-dessous acceptent une
    /// autre référence : le La₃ ne vaut pas 440 Hz partout ni à toutes les époques.
    static let standardA = 440.0

    static func midi(from frequency: Double, referenceA: Double = standardA) -> Double {
        69 + 12 * log2(frequency / referenceA)
    }

    static func frequency(ofMidi midi: Double, referenceA: Double = standardA) -> Double {
        referenceA * pow(2, (midi - 69) / 12)
    }

    /// Nom de note français, numéro d'octave (notation scientifique) et écart en
    /// cents, ex. « La4 +3¢ ».
    static func noteName(for frequency: Double, referenceA: Double = standardA) -> String {
        guard frequency > 0 else { return "—" }
        let m = midi(from: frequency, referenceA: referenceA)
        let rounded = Int(m.rounded())
        let cents = Int(((m - Double(rounded)) * 100).rounded())
        let name = names[((rounded % 12) + 12) % 12]
        let octave = rounded / 12 - 1
        let sign = cents >= 0 ? "+" : "−"
        return "\(name)\(octave) \(sign)\(abs(cents))¢"
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
