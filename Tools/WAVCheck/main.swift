import Foundation
import SpectreCore

// Le lecteur WAV, éprouvé sur des fichiers qu'on fabrique et dont on connaît donc
// le contenu exact. Aucun fichier n'est attendu sur le disque : le harnais écrit
// ses propres WAV, ce qui le rend reproductible partout — Windows compris.

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

let fs = 44100.0

/// Fabrique un WAV en mémoire à partir d'échantillons par canal.
func fabrique(canaux: [[Float]], bits: Int, flottant: Bool,
              échantillonnage: Double = fs, avecMétadonnées: Bool = false) -> Data {
    let n = canaux[0].count
    let nc = canaux.count
    let octetsParÉchantillon = bits / 8
    var corps = Data()
    for image in 0..<n {
        for canal in 0..<nc {
            let v = canaux[canal][image]
            if flottant {
                var b = v.bitPattern.littleEndian
                withUnsafeBytes(of: &b) { corps.append(contentsOf: $0) }
            } else if bits == 8 {
                corps.append(UInt8(max(0, min(255, Int((v * 128).rounded()) + 128))))
            } else if bits == 16 {
                var b = Int16(max(-32768, min(32767, Int((v * 32767).rounded())))).littleEndian
                withUnsafeBytes(of: &b) { corps.append(contentsOf: $0) }
            } else if bits == 24 {
                let e = max(-8_388_608, min(8_388_607, Int((v * 8_388_607).rounded())))
                let u = UInt32(bitPattern: Int32(e))
                corps.append(UInt8(u & 0xFF))
                corps.append(UInt8((u >> 8) & 0xFF))
                corps.append(UInt8((u >> 16) & 0xFF))
            } else {
                var b = Int32(max(-2_147_483_648, min(2_147_483_647,
                                                      Int((Double(v) * 2_147_483_647).rounded())))).littleEndian
                withUnsafeBytes(of: &b) { corps.append(contentsOf: $0) }
            }
        }
    }

    func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }

    var fmt = Data()
    fmt.append(u16(flottant ? 3 : 1))
    fmt.append(u16(nc))
    fmt.append(u32(Int(échantillonnage)))
    fmt.append(u32(Int(échantillonnage) * nc * octetsParÉchantillon))
    fmt.append(u16(nc * octetsParÉchantillon))
    fmt.append(u16(bits))

    var morceaux = Data()
    morceaux.append("fmt ".data(using: .ascii)!)
    morceaux.append(u32(fmt.count))
    morceaux.append(fmt)

    if avecMétadonnées {
        // Un morceau de taille impaire, glissé entre `fmt ` et `data` : c'est le
        // cas qui casse un lecteur qui oublie l'octet de bourrage.
        let texte = "Spectre".data(using: .ascii)!      // 7 octets, impair
        morceaux.append("LIST".data(using: .ascii)!)
        morceaux.append(u32(texte.count))
        morceaux.append(texte)
        morceaux.append(UInt8(0))
    }

    morceaux.append("data".data(using: .ascii)!)
    morceaux.append(u32(corps.count))
    morceaux.append(corps)

    var sortie = Data()
    sortie.append("RIFF".data(using: .ascii)!)
    sortie.append(u32(4 + morceaux.count))
    sortie.append("WAVE".data(using: .ascii)!)
    sortie.append(morceaux)
    return sortie
}

/// Une sinusoïde à 440 Hz, un quart de seconde.
let n = Int(fs / 4)
var sinus = [Float](repeating: 0, count: n)
for i in 0..<n {
    let phase: Double = 2 * Double.pi * 440 * Double(i) / fs
    sinus[i] = Float(0.5 * sin(phase))
}

titre("Profondeurs")
for (bits, flottant, tolérance) in [(8, false, 0.01), (16, false, 4e-5),
                                    (24, false, 2e-7), (32, false, 2e-7),
                                    (32, true, 0.0)] {
    let data = fabrique(canaux: [sinus], bits: bits, flottant: flottant)
    do {
        let lu = try WAVFile.decode(data)
        var écart: Float = 0
        for i in 0..<n { écart = max(écart, abs(lu.mono[i] - sinus[i])) }
        let nom = flottant ? "flottant 32 bits" : "\(bits) bits entier"
        verifie(lu.frameCount == n && Double(écart) <= tolérance, nom,
                String(format: "%d images, écart %.1e", lu.frameCount, écart))
    } catch {
        verifie(false, "\(bits) bits", "\(error)")
    }
}

titre("Canaux")
// Deux canaux opposés : leur moyenne doit être nulle. C'est le contrôle qui
// distingue une vraie moyenne d'une simple prise du premier canal.
let opposé = sinus.map { -$0 }
do {
    let lu = try WAVFile.decode(fabrique(canaux: [sinus, opposé], bits: 32, flottant: true))
    var crête: Float = 0
    for v in lu.mono { crête = max(crête, abs(v)) }
    verifie(lu.channels == 2 && crête == 0, "deux canaux opposés s'annulent",
            String(format: "crête %.1e sur %d images", crête, lu.frameCount))
} catch {
    verifie(false, "stéréo", "\(error)")
}

do {
    // Un canal muet : la moyenne doit valoir la moitié, pas le tout.
    let muet = [Float](repeating: 0, count: n)
    let lu = try WAVFile.decode(fabrique(canaux: [sinus, muet], bits: 32, flottant: true))
    var écart: Float = 0
    for i in 0..<n { écart = max(écart, abs(lu.mono[i] - sinus[i] / 2)) }
    verifie(écart == 0, "un canal muet divise le niveau par deux",
            String(format: "écart %.1e", écart))
} catch {
    verifie(false, "canal muet", "\(error)")
}

titre("Morceaux intercalaires")
do {
    let lu = try WAVFile.decode(fabrique(canaux: [sinus], bits: 16, flottant: false,
                                         avecMétadonnées: true))
    verifie(lu.frameCount == n, "un morceau de taille impaire est enjambé",
            "\(lu.frameCount) images")
} catch {
    verifie(false, "morceau intercalaire", "\(error)")
}

titre("Fréquence et durée")
do {
    let lu = try WAVFile.decode(fabrique(canaux: [sinus], bits: 16, flottant: false,
                                         échantillonnage: 48000))
    verifie(lu.sampleRate == 48000, "la fréquence d'échantillonnage est celle du fichier",
            "\(Int(lu.sampleRate)) Hz")
    verifie(abs(lu.duration - Double(n) / 48000) < 1e-9, "la durée s'en déduit",
            String(format: "%.4f s", lu.duration))
} catch {
    verifie(false, "en-tête", "\(error)")
}

titre("Refus")
// Ce qui n'est pas lisible doit le dire, et non rendre du bruit.
for (nom, data) in [("ce n'est pas du RIFF", Data("PAS UN WAV DU TOUT".utf8)),
                    ("un fichier vide", Data())] {
    do {
        _ = try WAVFile.decode(data)
        verifie(false, nom, "aucune erreur levée")
    } catch {
        verifie(true, nom, "\(error)")
    }
}

titre("Aller au disque")
// Le numéro du processus vient de Foundation et non de `getpid()` : sous Windows
// ce nom-là est déprécié au profit de `_getpid`, et la chaîne le signale à chaque
// compilation. Un avertissement qu'on apprend à ne plus voir finit par en cacher
// un vrai.
let chemin = FileManager.default.temporaryDirectory
    .appendingPathComponent("spectre-essai-\(ProcessInfo.processInfo.processIdentifier).wav")
do {
    try fabrique(canaux: [sinus], bits: 24, flottant: false).write(to: chemin)
    let lu = try WAVFile.read(at: chemin)
    verifie(lu.frameCount == n, "un fichier écrit puis relu revient entier",
            "\(lu.frameCount) images")
    try? FileManager.default.removeItem(at: chemin)
} catch {
    verifie(false, "lecture depuis le disque", "\(error)")
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
