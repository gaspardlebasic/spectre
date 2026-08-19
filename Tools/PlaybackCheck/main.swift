import AVFoundation
import Foundation
import SpectreCore

// Vérification de la chaîne de lecture, en rendu hors ligne : aucun périphérique
// audio, donc reproductible partout.
//
// Attention à ce que ce harnais peut et ne peut pas dire. Le rendu hors ligne n'a
// pas d'échéance : il prouve que les échantillons produits sont les bons, jamais
// qu'ils arrivent à temps. Un décrochage en temps réel ne s'y verrait pas. Ce qui
// s'y vérifie, en revanche, c'est la propriété qui met le sujet hors de portée :
// à vitesse et hauteur normales, le traitement est retiré du chemin.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label) — \(detail)")
    if !ok { failures += 1 }
}

let sampleRate = 48000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let url = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-essai.wav")

/// Un signal riche : plusieurs partiels et une attaque franche, de quoi rendre
/// visible le moindre recollage.
var reference = [Float](repeating: 0, count: Int(sampleRate * 4))
for i in 0..<reference.count {
    let t = Double(i) / sampleRate
    var value = 0.0
    for (harmonic, amplitude) in [(1.0, 0.4), (2.0, 0.2), (3.0, 0.12), (7.0, 0.06)] {
        value += amplitude * sin(2 * .pi * 220 * harmonic * t)
    }
    if i % Int(sampleRate / 2) < 64 { value += 0.3 }      // clic toutes les demi-secondes
    reference[i] = Float(value)
}
do {
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(reference.count))!
    buffer.frameLength = buffer.frameCapacity
    reference.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: reference.count)
    }
    try file.write(from: buffer)
}
defer { try? FileManager.default.removeItem(at: url) }

/// Monte la même chaîne que le lecteur — lecteur → filtre de bande → vitesse et
/// hauteur — et en rend `seconds` secondes.
func render(speed: Double, transpose: Double, seconds: Double) -> [Float] {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let band = AVAudioUnitEQ(numberOfBands: 4)
    for (i, parameters) in band.bands.enumerated() {
        parameters.filterType = i < 2 ? .highPass : .lowPass
        parameters.bypass = true
    }
    engine.attach(player); engine.attach(band); engine.attach(timePitch)
    let file = try! AVAudioFile(forReading: url)
    engine.connect(player, to: band, format: file.processingFormat)
    engine.connect(band, to: timePitch, format: file.processingFormat)
    engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)

    try! engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let rate = Detent.speed(speed)
    let cents = Detent.transpose(transpose)
    timePitch.rate = Float(rate)
    timePitch.pitch = Float(cents * 100)
    timePitch.auAudioUnit.shouldBypassEffect = (rate == 1 && cents == 0)

    try! engine.start()
    player.scheduleFile(file, at: nil)
    player.play()

    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var collected = [Float]()
    while collected.count < Int(seconds * sampleRate) {
        guard (try? engine.renderOffline(512, to: out)) == .success else { break }
        let data = out.floatChannelData![0]
        collected.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
    engine.stop()
    return collected
}

/// Plus grand écart avec le fichier d'origine, échantillon par échantillon.
func deviation(_ produced: [Float]) -> Float {
    var worst: Float = 0
    for i in 0..<min(produced.count, reference.count) {
        worst = max(worst, abs(produced[i] - reference[i]))
    }
    return worst
}

print("=== Crans des curseurs ===")
check("×0,996 retombe sur la vitesse normale", Detent.speed(0.996) == 1,
      String(format: "%.3f", Detent.speed(0.996)))
check("×0,93 reste où on l'a mise", Detent.speed(0.93) == 0.93,
      String(format: "%.3f", Detent.speed(0.93)))
check("+0,04 demi-ton retombe sur zéro", Detent.transpose(0.04) == 0,
      String(format: "%.3f", Detent.transpose(0.04)))
check("+2,97 demi-tons s'aimante sur 3", Detent.transpose(2.97) == 3,
      String(format: "%.3f", Detent.transpose(2.97)))
check("+2,5 demi-tons reste entre deux", Detent.transpose(2.5) == 2.5,
      String(format: "%.3f", Detent.transpose(2.5)))

print("\n=== Chaîne de lecture ===")
// La propriété qui compte : à ×1 et +0, rien ne touche au signal. Ce n'est pas
// « presque identique », c'est identique.
let neutral = render(speed: 1, transpose: 0, seconds: 2)
check("à ×1,00 et +0, ce qui sort est le fichier tel quel",
      deviation(neutral) < 1e-5,
      String(format: "écart maximal %.2e", deviation(neutral)))

// Le cran mène au même endroit : c'est tout son intérêt.
let almost = render(speed: 0.996, transpose: 0, seconds: 2)
check("une vitesse dans le cran donne le même résultat",
      deviation(almost) < 1e-5,
      String(format: "écart maximal %.2e", deviation(almost)))

// Hors du cran, l'unité travaille — et le signal en porte la marque.
let slowed = render(speed: 0.9, transpose: 0, seconds: 2)
check("hors du cran, le traitement est bien en service",
      deviation(slowed) > 0.01,
      String(format: "écart maximal %.2f, comme attendu d'un ralenti", deviation(slowed)))
check("le ralenti dure plus longtemps que la source",
      slowed.count >= Int(sampleRate * 2),
      "\(slowed.count) échantillons rendus")

print("\n=== Accord entendu ===")
// Survoler un nom d'accord le fait sonner. Ce qui se vérifie ici est le signal
// produit, pas le geste : que les hauteurs demandées y soient toutes, qu'aucune
// autre ne s'y invite, qu'un accord ne soit pas plus fort qu'une note seule, et
// qu'une voix qu'on retire s'en aille sans claquer.

let voiceCount = 8
var chord = ChordOscillator(sampleRate: sampleRate, voiceCount: voiceCount)
var posed = Set<Int>()

/// Fait avancer l'accord de `seconds` sur les fréquences demandées.
func advance(_ frequencies: [Double], seconds: Double, level: Double = 0.08) -> [Float] {
    // Deux `Double` par voix, et ils ne veulent pas dire la même chose : une
    // fréquence d'attente pour la première, un gain **nul** pour la seconde. Les
    // remplir d'une seule valeur ferait jouer les voix inutilisées à plein.
    var targets = [Double](repeating: 0, count: 2 * voiceCount)
    for voice in 0..<voiceCount { targets[2 * voice] = 440 }
    let perVoice = ChordOscillator.perVoiceLevel(level, voices: max(frequencies.count, 1))
    for (voice, frequency) in frequencies.enumerated() {
        // Une voix qu'on pose pour la première fois n'a rien à glisser.
        if !posed.contains(voice) { chord.jump(voice: voice, to: frequency); posed.insert(voice) }
        targets[2 * voice] = frequency
        targets[2 * voice + 1] = perVoice
    }
    var output = [Float](repeating: 0, count: Int(sampleRate * seconds))
    targets.withUnsafeBufferPointer { t in
        output.withUnsafeMutableBufferPointer { o in
            chord.render(targets: t, into: o, count: o.count)
        }
    }
    return output
}

/// Amplitude d'une fréquence dans un bloc, par projection sur une sinusoïde.
func amplitude(of frequency: Double, in samples: ArraySlice<Float>) -> Double {
    var real = 0.0, imaginary = 0.0
    for (offset, value) in samples.enumerated() {
        let angle = 2 * .pi * frequency * Double(offset) / sampleRate
        real += Double(value) * cos(angle)
        imaginary += Double(value) * sin(angle)
    }
    return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
}

func rms(_ samples: ArraySlice<Float>) -> Double {
    let total = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (total / Double(samples.count)).squareRoot()
}

func biggestStep(_ samples: ArraySlice<Float>) -> Double {
    var worst = 0.0
    var previous: Float?
    for value in samples {
        if let previous { worst = max(worst, Double(abs(value - previous))) }
        previous = value
    }
    return worst
}

// Do4 – Mi4 – Sol4.
let triad = [261.626, 329.628, 391.995]
let held = advance(triad, seconds: 0.5)
let settled = held[(held.count / 2)...]
let expected = ChordOscillator.perVoiceLevel(0.08, voices: 3)
let heard = triad.map { amplitude(of: $0, in: settled) }
check("les trois notes de l'accord sont toutes là",
      heard.allSatisfy { abs($0 - expected) < 0.1 * expected },
      heard.map { String(format: "%.4f", $0) }.joined(separator: "  ")
        + String(format: "  (attendu %.4f)", expected))
// Entre Mi et Sol il n'y a rien : une voix de trop, un repli, un battement se
// verraient ici. Le seuil n'est pas zéro — une projection sur un bloc fini laisse
// fuir quelques pour cent de ses voisines — mais il discrimine largement ce qu'on
// cherche : une note réellement présente y lirait une fois l'amplitude attendue,
// pas un dixième.
let between = amplitude(of: 360, in: settled)
check("rien ne sonne entre les notes demandées",
      between < 0.15 * expected,
      String(format: "%.5f à 360 Hz, soit %.0f %% d'une note", between,
             100 * between / expected))

// Quatre sinusoïdes de même amplitude peuvent aligner leurs phases ; sans
// correction, un accord serait plus fort qu'une note et finirait par écrêter.
let single = advance([261.626], seconds: 0.4)
// La quatrième note est prise loin des autres — un Si deux octaves plus haut. Ce
// n'est pas de la coquetterie : c'est elle qu'on va retirer, et il faut pouvoir
// mesurer son extinction sans la confondre avec ce que ses voisines laissent fuir
// dans la projection.
let quad = advance([261.626, 311.127, 391.995, 987.767], seconds: 0.4)
let ratio = rms(quad[(quad.count / 2)...]) / rms(single[(single.count / 2)...])
check("un accord ne sonne pas plus fort qu'une note seule",
      abs(ratio - 1) < 0.05, String(format: "%.3f fois la puissance d'une note", ratio))
check("et il ne sature jamais",
      quad.allSatisfy { abs($0) < 1 },
      String(format: "crête %.3f", quad.map { abs(Double($0)) }.max() ?? 0))

// Passer de quatre notes à trois : la voix retirée doit s'éteindre en fondu.
let dropped = advance([261.626, 311.127, 391.995], seconds: 0.3)
let gone = amplitude(of: 987.767, in: dropped[(dropped.count * 2 / 3)...])
let before = amplitude(of: 987.767, in: quad[(quad.count / 2)...])
check("une note retirée de l'accord s'en va vraiment",
      gone < 0.02 * before, String(format: "%.5f contre %.4f avant", gone, before))
check("et elle s'en va sans claquer",
      biggestStep(dropped[...]) < 0.02,
      String(format: "plus grand écart entre deux échantillons %.4f", biggestStep(dropped[...])))

print("")
if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
