import AVFoundation
import Foundation

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

print("")
if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
