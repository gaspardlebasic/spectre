import AVFoundation
import Foundation
import SpectreCore
import SpectreMac

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
//
// **En triangles**, comme dans l'application : un accord de sinusoïdes pures n'a
// pas de timbre et ne ressemble à aucun instrument qui aurait pu le jouer. Vérifier
// ici une forme que l'application n'emploie plus reviendrait à ne rien vérifier —
// c'est la forme réellement jouée qui doit ne pas saturer et ne pas claquer.

let voiceCount = 8
var chord = ChordOscillator(sampleRate: sampleRate, voiceCount: voiceCount)
var posed = Set<Int>()

/// Fait avancer l'accord de `seconds` sur les fréquences demandées.
func advance(_ frequencies: [Double], seconds: Double, level: Double = 0.08,
             waveform: ToneWaveform = .triangle) -> [Float] {
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
            chord.render(targets: t, waveform: waveform, into: o, count: o.count)
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
// La fondamentale d'un triangle de sommet 1 vaut 8/π² : c'est elle qu'on mesure,
// le reste du niveau étant parti dans les harmoniques.
let fondamentaleDuTriangle = 8 / (Double.pi * Double.pi)
let attendu = expected * fondamentaleDuTriangle
let heard = triad.map { amplitude(of: $0, in: settled) }
check("les trois notes de l'accord sont toutes là",
      heard.allSatisfy { abs($0 - attendu) < 0.1 * attendu },
      heard.map { String(format: "%.4f", $0) }.joined(separator: "  ")
        + String(format: "  (attendu %.4f)", attendu))
// Et chacune porte son propre timbre : la 3ᵉ harmonique au neuvième de sa
// fondamentale, comme le veut un triangle.
let timbres = triad.map { amplitude(of: 3 * $0, in: settled) / amplitude(of: $0, in: settled) }
check("chaque note porte ses harmoniques de triangle",
      timbres.allSatisfy { abs($0 - 1.0 / 9) < 0.02 },
      timbres.map { String(format: "%.4f", $0) }.joined(separator: "  ")
        + String(format: "  (attendu %.4f)", 1.0 / 9))
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

// La raie désignée dans le spectre passe par le même moteur, sur une seule voix, et
// doit rester une sinusoïde : une raie est une fréquence unique, et lui répondre par
// un timbre ferait entendre des hauteurs que l'image ne montre pas.
let raie = advance([261.626], seconds: 0.3, waveform: .sine)
let raieSettled = raie[(raie.count / 2)...]
let harmoniqueDeTrop = amplitude(of: 3 * 261.626, in: raieSettled)
    / amplitude(of: 261.626, in: raieSettled)
check("la raie désignée reste une sinusoïde pure",
      harmoniqueDeTrop < 0.01,
      String(format: "3ᵉ harmonique à %.5f de la fondamentale", harmoniqueDeTrop))

// Passer de quatre notes à trois : la voix retirée doit s'éteindre en fondu.
let dropped = advance([261.626, 311.127, 391.995], seconds: 0.3)
let gone = amplitude(of: 987.767, in: dropped[(dropped.count * 2 / 3)...])
let before = amplitude(of: 987.767, in: quad[(quad.count / 2)...])
check("une note retirée de l'accord s'en va vraiment",
      gone < 0.02 * before, String(format: "%.5f contre %.4f avant", gone, before))
check("et elle s'en va sans claquer",
      biggestStep(dropped[...]) < 0.02,
      String(format: "plus grand écart entre deux échantillons %.4f", biggestStep(dropped[...])))

// MARK: - La somme des pistes, au moment où le son sort

// Les combinaisons ne sont plus des fichiers : le fil audio somme les pistes cochées
// à chaque bloc, depuis la banque en mémoire. C'est le mélangeur du lecteur qui est
// monté ici — pas une copie —, dans le même rendu hors ligne : ce qui se vérifie, ce
// sont les échantillons qu'entendra vraiment quelqu'un qui décoche une piste.

print("")
print("=== La somme des pistes en mémoire ===")

let frequenceBanque = StemStore.stemSampleRate
let imagesBanque = 4096
/// Une piste par voie, chacune à sa propre fréquence : la somme se reconnaît alors
/// note par note, et une piste qui sort de la mauvaise case s'entend tout de suite.
var pistesDEssai = [Stem: [[Float]]]()
let tons: [Stem: Double] = [.drums: 110, .bass: 220, .other: 440, .vocals: 880]
for piste in Stem.separated {
    let f = tons[piste] ?? 100
    let canal = (0..<imagesBanque).map { i in
        Float(0.2 * sin(2 * .pi * f * Double(i) / frequenceBanque))
    }
    // Le canal droit décalé : un mélangeur qui confondrait les canaux se verrait.
    pistesDEssai[piste] = [canal, canal.map { -$0 }]
}
let banque = BanqueDePistes(empreinte: "essai", sampleRate: frequenceBanque,
                            pistes: &pistesDEssai)!

/// Rend `images` images de la banque à travers le mélangeur du lecteur, hors ligne.
func rendreLaBanque(_ gardées: Set<Stem>, images: Int,
                    boucle: (Int64, Int64)? = nil) -> [[Float]] {
    let source = SourceDeBanque()
    source.installer(banque: banque, masque: banque.masque(gardées))
    source.boucle(boucle)
    source.jouer(true)

    let format = AVAudioFormat(standardFormatWithSampleRate: frequenceBanque, channels: 2)!
    let engine = AVAudioEngine()
    let noeud = source.noeudDeRendu(format: format)
    engine.attach(noeud)
    engine.connect(noeud, to: engine.mainMixerNode, format: format)
    try! engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try! engine.start()
    defer { engine.stop(); source.liberer() }

    var sortie = [[Float]](repeating: [], count: 2)
    let tampon = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                  frameCapacity: 512)!
    var rendues = 0
    while rendues < images {
        let combien = AVAudioFrameCount(min(512, images - rendues))
        guard (try? engine.renderOffline(combien, to: tampon)) == .success else { break }
        let n = Int(tampon.frameLength)
        for c in 0..<2 {
            sortie[c].append(contentsOf:
                UnsafeBufferPointer(start: tampon.floatChannelData![c], count: n))
        }
        rendues += n
    }
    return sortie
}

func ecartMax(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).map { abs($0 - $1) }.max() ?? 1
}

let attenduTout = banque.melangeStereo(Set(Stem.separated))
let renduTout = rendreLaBanque(Set(Stem.separated), images: 2048)
check("tout coché rend la somme des quatre pistes",
      ecartMax(renduTout[0], Array(attenduTout[0].prefix(renduTout[0].count))) < 1e-6,
      String(format: "écart %.1e", ecartMax(renduTout[0],
                                            Array(attenduTout[0].prefix(renduTout[0].count)))))
check("et le canal droit reste le canal droit",
      ecartMax(renduTout[1], Array(attenduTout[1].prefix(renduTout[1].count))) < 1e-6,
      String(format: "écart %.1e", ecartMax(renduTout[1],
                                            Array(attenduTout[1].prefix(renduTout[1].count)))))

let sansVoix: Set<Stem> = [.drums, .bass, .other]
let attenduSansVoix = banque.melangeStereo(sansVoix)
let renduSansVoix = rendreLaBanque(sansVoix, images: 2048)
check("décocher une piste la retire vraiment du son",
      ecartMax(renduSansVoix[0], Array(attenduSansVoix[0].prefix(renduSansVoix[0].count))) < 1e-6,
      String(format: "écart %.1e",
             ecartMax(renduSansVoix[0], Array(attenduSansVoix[0].prefix(renduSansVoix[0].count)))))
check("et ce n'est pas le même son qu'avec elle",
      ecartMax(renduSansVoix[0], Array(renduTout[0].prefix(renduSansVoix[0].count))) > 0.01,
      "les deux rendus diffèrent")

let uneSeule = rendreLaBanque([.bass], images: 1024)
let attenduBasse = banque.melangeStereo([.bass])
check("une piste seule est elle-même",
      ecartMax(uneSeule[0], Array(attenduBasse[0].prefix(uneSeule[0].count))) < 1e-6,
      String(format: "écart %.1e",
             ecartMax(uneSeule[0], Array(attenduBasse[0].prefix(uneSeule[0].count)))))

let rien = rendreLaBanque([], images: 512)
check("rien de coché ne rend que du silence",
      rien[0].allSatisfy { $0 == 0 }, "silence")

// La boucle est tenue par le fil audio lui-même : elle doit repartir à son début
// sans un trou ni une image de trop.
let bouclé = rendreLaBanque(Set(Stem.separated), images: 1536, boucle: (0, 512))
var tourJuste = true
for i in 512..<1536 where abs(bouclé[0][i] - bouclé[0][i % 512]) > 1e-6 { tourJuste = false }
check("la boucle repart exactement à son début", tourJuste,
      "trois tours de 512 images identiques")

// La fin du morceau : du silence, et pas une relecture depuis le début.
let jusquAuBout = rendreLaBanque(Set(Stem.separated), images: imagesBanque + 512)
check("la fin du morceau est du silence, pas un retour au début",
      jusquAuBout[0][imagesBanque...].allSatisfy { $0 == 0 },
      "\(jusquAuBout[0].count - imagesBanque) images de silence")

print("")
if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
