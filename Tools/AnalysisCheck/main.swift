import Foundation
import SpectreCore

// Vérification de la chaîne d'analyse hors ligne sur des signaux de synthèse.
// Aucun fichier, aucune fenêtre : uniquement du calcul, donc reproductible.

let sampleRate = 48000.0

/// Somme de sinusoïdes, chacune limitée à un intervalle de temps.
func synth(duration: Double,
           _ parts: [(f: Double, amplitude: Double, from: Double, to: Double)]) -> [Float] {
    let n = Int(duration * sampleRate)
    var x = [Float](repeating: 0, count: n)
    for p in parts {
        let i0 = max(0, Int(p.from * sampleRate))
        let i1 = min(n, Int(p.to * sampleRate))
        guard i0 < i1 else { continue }
        let w = 2 * Double.pi * p.f / sampleRate
        for i in i0..<i1 {
            x[i] += Float(p.amplitude * sin(w * Double(i - i0)))
        }
    }
    return x
}

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label) — \(detail)")
    if !ok { failures += 1 }
}

/// Ligne dont la fréquence est la plus proche de `f`.
func bin(of f: Double, _ s: Spectrogram) -> Int {
    min(max(Int(s.layout.bin(of: f).rounded()), 0), s.binCount - 1)
}

/// Niveau maximal atteint par une ligne sur toute la durée.
func peak(_ s: Spectrogram, bin i: Int) -> Float {
    var m = Float(-400)
    for c in 0..<s.columnCount { m = max(m, s.value(column: c, bin: i)) }
    return m
}

/// Instant où la ligne franchit pour la première fois `peak − margin`.
func onset(_ s: Spectrogram, bin i: Int, margin: Float = 6) -> Double {
    let threshold = peak(s, bin: i) - margin
    for c in 0..<s.columnCount where s.value(column: c, bin: i) >= threshold {
        return s.time(ofColumn: c)
    }
    return .nan
}

let settings = AnalysisSettings()

// Deux bouffées rigoureusement simultanées, trois octaves et demie d'écart, plus
// un La₃ isolé pour contrôler le niveau restitué.
let signal = synth(duration: 8, [
    (f: 440, amplitude: 1.0, from: 0.4, to: 1.4),
    (f: 110, amplitude: 0.5, from: 2.5, to: 4.5),
    (f: 1760, amplitude: 0.5, from: 2.5, to: 4.5),
])

print("=== Analyse hors ligne ===")
let started = Date()
let spectrogram = OfflineAnalysis.run(samples: signal, sampleRate: sampleRate, settings: settings)
let elapsed = Date().timeIntervalSince(started)
print(String(format: "  %d colonnes × %d lignes, %.0f Hz…%.0f Hz, %.2f s (×%.0f temps réel)",
             spectrogram.columnCount, spectrogram.binCount,
             spectrogram.layout.minFrequency, spectrogram.layout.maxFrequency,
             elapsed, 8 / elapsed))

check("durée",
      abs(spectrogram.duration - 8) < 0.05,
      String(format: "%.3f s pour 8 s de signal", spectrogram.duration))

// --- Niveau -----------------------------------------------------------------
// Une sinusoïde d'amplitude 1 doit culminer à 0 dB, quelle que soit la fréquence
// et donc quel que soit l'étage du banc qui l'a analysée.
print("\n=== Niveau ===")
let levelAt440 = peak(spectrogram, bin: bin(of: 440, spectrogram))
check("La₃ d'amplitude 1", abs(levelAt440) < 1.5,
      String(format: "%.2f dB (attendu 0)", levelAt440))

// --- Justesse ---------------------------------------------------------------
print("\n=== Justesse ===")
for (frequency, name) in [(110.0, "La₁"), (440.0, "La₃"), (1760.0, "La₅")] {
    let center = bin(of: frequency, spectrogram)
    let window = max(0, center - 6)...min(spectrogram.binCount - 1, center + 6)
    var best = center
    var bestValue = Float(-400)
    for i in window where peak(spectrogram, bin: i) > bestValue {
        bestValue = peak(spectrogram, bin: i)
        best = i
    }
    let found = spectrogram.layout.frequency(atBin: Double(best))
    let cents = 1200 * log2(found / frequency)
    check("\(name) tombe au bon endroit", abs(cents) < 20,
          String(format: "%.1f Hz au lieu de %.1f (%+.0f cents)", found, frequency, cents))
}

// --- Recalage temporel ------------------------------------------------------
// C'est le point du passage hors ligne : les deux bouffées démarrent au même
// instant, elles doivent le montrer, alors que leurs fenêtres d'analyse durent
// respectivement ~1,4 s et ~11 ms.
print("\n=== Recalage temporel ===")
let low = onset(spectrogram, bin: bin(of: 110, spectrogram))
let high = onset(spectrogram, bin: bin(of: 1760, spectrogram))
let probe = Analyzer(sampleRate: sampleRate, settings: settings)
let uncompensated = probe.windowSeconds(at: 110) / 2

check("attaque à 110 Hz", abs(low - 2.5) < 0.12,
      String(format: "%.3f s pour 2,500 s (sans compensation : %.3f s)",
             low, 2.5 + uncompensated))
check("attaque à 1760 Hz", abs(high - 2.5) < 0.05,
      String(format: "%.3f s pour 2,500 s", high))
check("les deux bandes s'accordent", abs(low - high) < 0.12,
      String(format: "%.0f ms d'écart (fenêtres de %.0f ms et %.0f ms)",
             abs(low - high) * 1000,
             probe.windowSeconds(at: 110) * 1000, probe.windowSeconds(at: 1760) * 1000))

// --- Indépendance au découpage ---------------------------------------------
// Le pré-roll doit rendre chaque tranche indépendante de ses voisines : les
// filtres du banc étant à réponse finie, l'égalité doit être *exacte*.
print("\n=== Découpage en tranches ===")
let sliced = OfflineAnalysis.run(samples: signal, sampleRate: sampleRate,
                                 settings: settings, chunkSeconds: 0.7)
var worst = Float(0)
var worstAt = (column: 0, bin: 0)
if sliced.columnCount == spectrogram.columnCount {
    for c in 0..<spectrogram.columnCount {
        for i in 0..<spectrogram.binCount {
            let d = abs(spectrogram.value(column: c, bin: i) - sliced.value(column: c, bin: i))
            if d > worst { worst = d; worstAt = (c, i) }
        }
    }
}
check("même nombre de colonnes", sliced.columnCount == spectrogram.columnCount,
      "\(sliced.columnCount) contre \(spectrogram.columnCount)")
check("valeurs identiques", worst == 0,
      worst == 0 ? "au bit près"
                 : String(format: "écart max %.4f dB (colonne %d, ligne %d)",
                          worst, worstAt.column, worstAt.bin))

// --- Silence ----------------------------------------------------------------
print("\n=== Plancher ===")
// Mesuré assez loin de la dernière note pour que même la fenêtre de 2,7 s des
// graves n'en contienne plus rien : sinon on testerait la physique de l'analyse,
// pas le code.
let quiet = spectrogram.averageSpectrum(from: 6.6, to: 7.4).max() ?? 0
check("le silence reste silencieux", quiet < -120,
      String(format: "%.0f dB, 2 s après la dernière note", quiet))

// --- Tempo ------------------------------------------------------------------
// Un click-track : attaques nettes, tempo connu, accent sur le premier temps.
print("\n=== Tempo ===")
let bpm = 132.0
let beat = 60 / bpm
let firstClick = 0.37
let beatsPerBar = 4

func clickTrack(duration: Double) -> [Float] {
    let n = Int(duration * sampleRate)
    var x = [Float](repeating: 0, count: n)
    var seed: UInt64 = 12345
    func noise() -> Float {          // générateur déterministe : test reproductible
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
    }
    var index = 0
    var time = firstClick
    while time < duration {
        let accent: Float = index % beatsPerBar == 0 ? 1.0 : 0.55
        let start = Int(time * sampleRate)
        let length = Int(0.04 * sampleRate)
        for k in 0..<length where start + k < n {
            x[start + k] += accent * noise() * exp(-Float(k) / Float(length) * 5)
        }
        index += 1
        time += beat
    }
    return x
}

let clicks = OfflineAnalysis.run(samples: clickTrack(duration: 24),
                                 sampleRate: sampleRate, settings: settings)
if let grid = TempoEstimator.estimate(clicks, beatsPerBar: beatsPerBar) {
    check("tempo retrouvé", abs(grid.bpm - bpm) < 1,
          String(format: "%.2f BPM pour %.0f", grid.bpm, bpm))
    // L'estimation ne propose que des entiers : c'est à l'utilisateur d'ajouter
    // les dixièmes s'il en faut.
    check("le tempo estimé est rond", grid.bpm == grid.bpm.rounded(),
          String(format: "%.3f", grid.bpm))

    // Phase : l'origine doit tomber sur un temps, à une fraction de temps près.
    let offset = (grid.origin - firstClick).truncatingRemainder(dividingBy: grid.beatSeconds)
    let phaseError = min(abs(offset), grid.beatSeconds - abs(offset))
    check("temps bien placés", phaseError < 0.04,
          String(format: "%.0f ms d'écart au click", phaseError * 1000))

    // Temps fort : l'origine doit tomber sur un *premier* temps, pas n'importe lequel.
    let barOffset = (grid.origin - firstClick).truncatingRemainder(dividingBy: grid.barSeconds)
    let barError = min(abs(barOffset), grid.barSeconds - abs(barOffset))
    check("premier temps sur l'accent", barError < 0.04,
          String(format: "%.0f ms d'écart à la mesure", barError * 1000))

    check("estimation annoncée comme sûre", grid.confidence > 2.2,
          String(format: "confiance %.1f", grid.confidence))
} else {
    check("tempo retrouvé", false, "aucune estimation")
}

// --- Magnétisme -------------------------------------------------------------
print("\n=== Magnétisme du curseur ===")
var layout = BinLayout()
layout.binCount = 200
layout.minFrequency = 27.5
layout.maxFrequency = 27.5 * pow(2, 200.0 / 36)
layout.binsPerOctave = 36
layout.sampleRate = 48000

let ridgeBin = 120
let faintBin = 96
var matrix = [Float](repeating: -200, count: 400 * layout.binCount)
for c in 0..<400 {
    // Une raie franche, et une raie pâle plus proche du curseur d'essai.
    matrix[c * layout.binCount + ridgeBin] = -30
    matrix[c * layout.binCount + ridgeBin - 1] = -40
    matrix[c * layout.binCount + ridgeBin + 1] = -38
    matrix[c * layout.binCount + faintBin] = -88
    matrix[c * layout.binCount + faintBin - 1] = -94
    matrix[c * layout.binCount + faintBin + 1] = -94
}
let scene = Spectrogram(layout: layout, columnCount: 400,
                        secondsPerColumn: 0.01, values: matrix)

let size = CGSize(width: 600, height: 400)
var view = Viewport.fitting(columns: 400, bins: layout.binCount,
                            size: (Double(size.width), Double(size.height)))
var settingsDisplay = DisplaySettings()

// Curseur posé entre les deux raies, plus près de la pâle.
let ridgeY = view.point(ofBin: Double(ridgeBin) + 0.5, height: Double(size.height))
let faintY = view.point(ofBin: Double(faintBin) + 0.5, height: Double(size.height))
let cursor = CGPoint(x: 300, y: (ridgeY + faintY) / 2 + (faintY - ridgeY) * 0.12)

if let target = Snapping.nearest(to: cursor, in: scene, viewport: view,
                                 display: settingsDisplay, viewSize: size) {
    let expected = layout.frequency(atBin: Double(ridgeBin))
    let cents = 1200 * log2(target.frequency / expected)
    check("la raie franche l'emporte sur la raie pâle plus proche", abs(cents) < 20,
          String(format: "%.1f Hz (%+.0f cents de la raie visée)", target.frequency, cents))
} else {
    check("la raie franche l'emporte sur la raie pâle plus proche", false, "rien accroché")
}

// Le seuil de noir de l'utilisateur commande : au-dessus des raies, plus rien
// n'attire — c'est la même formule que celle du shader qui décide.
settingsDisplay.floorDb = -20
settingsDisplay.ceilingDb = 0
let inTheDark = Snapping.nearest(to: cursor, in: scene, viewport: view,
                                 display: settingsDisplay, viewSize: size)
check("une région rendue noire n'attire rien", inTheDark == nil,
      inTheDark == nil ? "rien accroché, comme attendu"
                       : String(format: "%.1f Hz accrochés à tort", inTheDark!.frequency))

// Loin de toute raie, on ne s'aimante pas sur quelque chose d'invisible.
settingsDisplay = DisplaySettings()
let farAway = Snapping.nearest(to: CGPoint(x: 300, y: 20), in: scene, viewport: view,
                               display: settingsDisplay, viewSize: size)
check("hors de portée, pas d'aimantation", farAway == nil,
      farAway == nil ? "rien accroché" : "accroché à tort")

// --- Bande écoutée ----------------------------------------------------------
// « N'entendre que ce qu'on regarde » : la bande passante suit la portion visible
// de l'axe des fréquences, et disparaît quand tout le spectre est à l'écran.
print("\n=== Bande écoutée ===")
var full = Viewport.fitting(columns: 400, bins: layout.binCount,
                            size: (Double(size.width), Double(size.height)))
check("tout le spectre visible ne filtre rien",
      full.visibleBand(in: layout, height: Double(size.height)) == nil,
      "aucune bande demandée")

// Zoom sur les deux octaves du bas.
var zoomed = full
zoomed.binsPerPoint = 72 / Double(size.height)
zoomed.bottomBin = 0
if let audible = zoomed.visibleBand(in: layout, height: Double(size.height)) {
    let octaves = log2(audible.upperBound / audible.lowerBound)
    check("zoomer sur les graves restreint la bande", abs(octaves - 2) < 0.05,
          String(format: "%.0f Hz…%.0f Hz, soit %.2f octaves",
                 audible.lowerBound, audible.upperBound, octaves))
} else {
    check("zoomer sur les graves restreint la bande", false, "aucune bande demandée")
}

// La bande suit la vue : la même hauteur d'écran, deux octaves plus haut.
var moved = zoomed
moved.bottomBin = 72
if let a = zoomed.visibleBand(in: layout, height: Double(size.height)),
   let b = moved.visibleBand(in: layout, height: Double(size.height)) {
    check("déplacer la vue déplace la bande",
          abs(log2(b.lowerBound / a.lowerBound) - 2) < 0.05,
          String(format: "%.0f Hz devient %.0f Hz", a.lowerBound, b.lowerBound))
} else {
    check("déplacer la vue déplace la bande", false, "aucune bande demandée")
}

// --- Aimantation de la boucle -----------------------------------------------
// Le pas d'aimantation est celui de la grille dessinée : ce sur quoi les bornes
// se posent est exactement ce qu'on voit.
print("\n=== Aimantation de la boucle ===")
let ruled = TempoGrid(bpm: 120, origin: 0.25, beatsPerBar: 4)
func pas(_ pointsPerBeat: Double) -> String {
    ruled.unit(pointsPerBeat: pointsPerBeat).map { "pas de \($0) temps" } ?? "aucune grille"
}
check("le morceau entier, on se cale sur les phrases", ruled.unit(pointsPerBeat: 3) == 16,
      pas(3))
check("un peu moins dézoomé, sur les mesures", ruled.unit(pointsPerBeat: 8) == 4,
      pas(8))
check("au zoom courant, sur les temps", ruled.unit(pointsPerBeat: 30) == 1,
      pas(30))
check("bien zoomé, sur les doubles croches", ruled.unit(pointsPerBeat: 150) == 0.25,
      pas(150))

// La raison d'être de l'échelon des phrases : aucun échelon ne doit jamais
// dessiner deux traits à moins de trente points l'un de l'autre. C'est ce seuil,
// et non le nom des échelons, qui décide si l'image est lisible ou hachurée.
var tropSerre: [Double] = []
for centieme in 30...20000 {
    let pointsPerBeat = Double(centieme) / 100
    guard let unit = ruled.unit(pointsPerBeat: pointsPerBeat) else { continue }
    // Les temps et leurs subdivisions sont fins et pâles : c'est aux échelons
    // dessinés en trait plein — mesure et phrase — que la règle s'applique.
    guard unit >= 4 else { continue }
    if unit * pointsPerBeat < 30 { tropSerre.append(pointsPerBeat) }
}
check("jamais deux barres à moins de trente points", tropSerre.isEmpty,
      tropSerre.isEmpty ? "sur tout l'intervalle de zoom"
                        : "\(tropSerre.count) densités trop serrées")

// En dessous, plus rien : mieux vaut pas de grille du tout qu'une trame.
check("tout au fond du dézoom, plus de grille", ruled.unit(pointsPerBeat: 1) == nil,
      pas(1))

// Une phrase fait quatre mesures, quelle que soit la signature.
let troisTemps = TempoGrid(bpm: 120, origin: 0, beatsPerBar: 3)
check("une phrase suit la signature", troisTemps.beatsPerPhrase == 12,
      "\(Int(troisTemps.beatsPerPhrase)) temps à 3/4, \(Int(ruled.beatsPerPhrase)) à 4/4")
check("elle s'ouvre à la bonne mesure",
      troisTemps.opensPhrase(12) && !troisTemps.opensPhrase(9) && troisTemps.opensBar(9),
      "la mesure 4 ouvre une phrase, la mesure 3 non")

// Une borne posée n'importe où doit retomber sur un multiple du pas.
let snapped = ruled.snap(3.31, unit: 1)
check("une borne se pose sur la grille",
      abs(ruled.beat(at: snapped) - ruled.beat(at: snapped).rounded()) < 1e-9,
      String(format: "3,310 s → %.3f s (temps %.0f)", snapped, ruled.beat(at: snapped)))
check("elle se pose sur la plus proche", abs(snapped - 3.25) < 1e-9,
      String(format: "%.3f s, entre les temps posés à %.3f et %.3f",
             snapped, ruled.time(ofBeat: 6), ruled.time(ofBeat: 7)))
let free = ruled.snap(3.31, unit: 0)
check("un pas nul laisse la borne libre", free == 3.31,
      String(format: "%.3f s inchangés", free))

// --- Noms de notes ----------------------------------------------------------
print("\n=== Noms de notes ===")
let blackKey = Pitch.frequency(ofMidi: 63)          // touche noire entre Ré et Mi
check("les touches noires se nomment par le bas",
      Pitch.noteName(for: blackKey, flats: true).hasPrefix("Mi♭"),
      Pitch.noteName(for: blackKey, flats: true))
check("et par le haut si on le demande",
      Pitch.noteName(for: blackKey, flats: false).hasPrefix("Ré♯"),
      Pitch.noteName(for: blackKey, flats: false))
check("les touches blanches ne changent pas",
      Pitch.noteName(for: 440, flats: true) == Pitch.noteName(for: 440, flats: false),
      Pitch.noteName(for: 440, flats: true))
check("les deux écritures désignent la même hauteur",
      Pitch.flatNames.count == 12 && Pitch.sharpNames.count == 12,
      "12 noms de chaque côté")

// --- Manipulation de la boucle ----------------------------------------------
// Une boucle posée s'attrape par le corps pour la déplacer, par un bord pour
// l'étendre. Chaque geste a sa règle, et c'est là que les erreurs se logent.
print("\n=== Manipulation de la boucle ===")
let asIs: (Double) -> Double = { $0 }
let onBeats: (Double) -> Double = { ruled.snap($0, unit: 1) }
let piece = 60.0

check("un tracé à l'envers donne la même boucle",
      LoopEditing.made(from: 12, to: 4, duration: piece, snap: asIs) == 4...12,
      "\(LoopEditing.made(from: 12, to: 4, duration: piece, snap: asIs)!)")
check("un geste trop court n'est pas une boucle",
      LoopEditing.made(from: 4, to: 4.02, duration: piece, snap: asIs) == nil,
      "aucune boucle")

let shifted = LoopEditing.moved(4...12, startingAt: 20.4, duration: piece, snap: onBeats)
check("déplacer conserve la durée",
      abs((shifted.upperBound - shifted.lowerBound) - 8) < 1e-9,
      String(format: "%.3f s, comme avant", shifted.upperBound - shifted.lowerBound))
check("seul le début s'aimante",
      abs(ruled.beat(at: shifted.lowerBound) - ruled.beat(at: shifted.lowerBound).rounded()) < 1e-9,
      String(format: "début à %.3f s (temps %.0f), fin à %.3f s",
             shifted.lowerBound, ruled.beat(at: shifted.lowerBound), shifted.upperBound))

let pushed = LoopEditing.moved(4...12, startingAt: 58, duration: piece, snap: asIs)
check("arrivée au bout, la boucle s'arrête au lieu de se raccourcir",
      pushed == 52...60,
      String(format: "%.0f s…%.0f s", pushed.lowerBound, pushed.upperBound))

let stretched = LoopEditing.resized(4...12, edge: .end, to: 30, duration: piece, snap: asIs)
check("tirer la fin étend la boucle", stretched == 4...30,
      String(format: "%.0f s…%.0f s", stretched.lowerBound, stretched.upperBound))

let crossed = LoopEditing.resized(4...12, edge: .start, to: 40, duration: piece, snap: asIs)
check("une borne ne traverse pas sa voisine",
      abs(crossed.upperBound - crossed.lowerBound - LoopEditing.minimumLength) < 1e-9,
      String(format: "arrêtée à %.0f ms de l'autre bord",
             (crossed.upperBound - crossed.lowerBound) * 1000))

// --- Contraste automatique --------------------------------------------------
// Une matrice fabriquée dont on connaît la pente : des raies qui perdent 9 dB par
// octave sur un fond plat. Le réglage doit retrouver cette pente, et surtout
// rendre une note grave et une note aiguë également claires — c'est tout l'objet.
print("\n=== Contraste automatique ===")
var slopeLayout = BinLayout()
slopeLayout.binCount = 200
slopeLayout.minFrequency = 27.5
slopeLayout.binsPerOctave = 36
slopeLayout.maxFrequency = 27.5 * pow(2, 200.0 / 36)
slopeLayout.sampleRate = 48000

let trueSlope = -9.0                      // dB par octave
let backgroundDb: Float = -100
func raieLevel(_ bin: Int) -> Float { Float(-30 + trueSlope * Double(bin) / 36) }

func slopeScene(withDeadBand: Bool) -> Spectrogram {
    var values = [Float](repeating: backgroundDb, count: 600 * slopeLayout.binCount)
    for c in 0..<600 {
        for bin in Swift.stride(from: 0, to: 180, by: 12) where c < 180 {
            values[c * slopeLayout.binCount + bin] = raieLevel(bin)
        }
        if withDeadBand {
            // Une bande forte mais immobile — un souffle, un artefact de codec :
            // elle ne doit pas peser sur la pente, puisqu'il ne s'y passe rien.
            for bin in 180..<200 { values[c * slopeLayout.binCount + bin] = -35 }
        }
    }
    return Spectrogram(layout: slopeLayout, columnCount: 600,
                       secondsPerColumn: 0.01, values: values)
}

let plain = DisplaySettings()
if let tuned = AutoContrast.settings(basedOn: plain, in: slopeScene(withDeadBand: false)) {
    check("la pente du morceau est retrouvée",
          abs(tuned.tiltDbPerOctave + trueSlope) < 1,
          String(format: "%.1f dB/octave pour compenser %.0f", tuned.tiltDbPerOctave, trueSlope))

    // Le point de la manœuvre : la même note, quatre octaves plus bas, aussi claire.
    let lowBin = 12, highBin = 156
    let lowIntensity = Snapping.intensity(db: raieLevel(lowBin), bin: Double(lowBin),
                                          layout: slopeLayout, display: tuned)
    let highIntensity = Snapping.intensity(db: raieLevel(highBin), bin: Double(highBin),
                                           layout: slopeLayout, display: tuned)
    check("graves et aigus ressortent pareillement",
          abs(lowIntensity - highIntensity) < 0.06,
          String(format: "clarté %.2f à %.0f Hz, %.2f à %.0f Hz",
                 lowIntensity, slopeLayout.frequency(atBin: Double(lowBin)),
                 highIntensity, slopeLayout.frequency(atBin: Double(highBin))))
    check("les raies sont franchement visibles", lowIntensity > 0.55,
          String(format: "clarté %.2f", lowIntensity))

    let backgroundIntensity = Snapping.intensity(db: backgroundDb, bin: 100,
                                                 layout: slopeLayout, display: tuned)
    check("le fond reste noir", backgroundIntensity == 0,
          String(format: "clarté %.3f", backgroundIntensity))

    if let withDead = AutoContrast.settings(basedOn: plain, in: slopeScene(withDeadBand: true)) {
        check("une bande forte mais immobile ne fausse pas la pente",
              abs(withDead.tiltDbPerOctave - tuned.tiltDbPerOctave) < 0.5,
              String(format: "%.1f contre %.1f dB/octave",
                     withDead.tiltDbPerOctave, tuned.tiltDbPerOctave))
    }
} else {
    check("la pente du morceau est retrouvée", false, "aucun réglage proposé")
}

check("une matrice vide ne propose rien",
      AutoContrast.settings(basedOn: plain, in: Spectrogram.empty) == nil,
      "aucun réglage, et rien ne casse")

// --- Réglages conservés -----------------------------------------------------
print("\n=== Réglages conservés ===")
var session = FileSession()
session.display.floorDb = -73
session.display.useFlats = false
session.tempo = TempoGrid(bpm: 96.5, origin: 1.25, beatsPerBar: 3)
session.loop = 12.5...20.25
session.playhead = 41.5
session.speed = 0.6
session.viewport.startColumn = 1234

let encoded = try! JSONEncoder().encode(session)
let decoded = try! JSONDecoder().decode(FileSession.self, from: encoded)
check("aller-retour fidèle", decoded == session,
      "\(encoded.count) octets")
check("la tête de lecture est exclue de la comparaison",
      { var other = session; other.playhead = 3; return other.withoutPlayhead == session.withoutPlayhead }(),
      "seule elle peut bouger sans déclencher d'écriture")

// L'empreinte ignore le chemin : un morceau rangé ailleurs garde ses réglages.
let temporary = FileManager.default.temporaryDirectory
let contents = Data((0..<200_000).map { UInt8($0 % 251) })
let a = temporary.appendingPathComponent("empreinte-a.bin")
let b = temporary.appendingPathComponent("empreinte-b.bin")
let c = temporary.appendingPathComponent("empreinte-c.bin")
try! contents.write(to: a)
try! contents.write(to: b)
try! (contents.dropLast() + Data([9])).write(to: c)
defer { for u in [a, b, c] { try? FileManager.default.removeItem(at: u) } }

check("le même morceau rangé ailleurs a la même empreinte",
      SessionStore.fingerprint(of: a) == SessionStore.fingerprint(of: b),
      String(SessionStore.fingerprint(of: a)?.prefix(16) ?? "—"))
check("un autre contenu a une autre empreinte",
      SessionStore.fingerprint(of: a) != SessionStore.fingerprint(of: c),
      String(SessionStore.fingerprint(of: c)?.prefix(16) ?? "—"))
check("un fichier absent n'a pas d'empreinte",
      SessionStore.fingerprint(of: temporary.appendingPathComponent("néant.bin")) == nil,
      "aucune, et rien ne casse")

// --- Sinusoïde d'écoute -----------------------------------------------------
// Ce qui compte n'est pas qu'une sinusoïde sorte, mais qu'elle sorte *sans clic* :
// une discontinuité d'amplitude ou de phase s'entend immédiatement, et le geste
// consiste justement à déplacer la souris en continu.
print("\n=== Sinusoïde d'écoute ===")
let toneRate = 48000.0

func renderTone(_ oscillator: inout ToneOscillator,
                frequency: Double, gain: Double, seconds: Double,
                waveform: ToneWaveform = .sine) -> [Float] {
    let count = Int(seconds * toneRate)
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer {
        oscillator.render(targetFrequency: frequency, targetGain: gain,
                          waveform: waveform, into: $0, count: count)
    }
    return out
}

/// Fréquence mesurée par comptage des passages par zéro montants.
func measuredFrequency(_ x: [Float]) -> Double {
    var first = -1.0, last = -1.0, crossings = 0
    for i in 1..<x.count where x[i - 1] <= 0 && x[i] > 0 {
        // Interpolation linéaire du passage : sans elle, la résolution serait
        // limitée à l'échantillon et la mesure inutilisable.
        let t = Double(i - 1) + Double(-x[i - 1]) / Double(x[i] - x[i - 1])
        if first < 0 { first = t } else { last = t; crossings += 1 }
    }
    guard crossings > 0, last > first else { return .nan }
    return Double(crossings) * toneRate / (last - first)
}

/// Plus grand écart entre deux échantillons voisins, rapporté à ce qu'exige la
/// sinusoïde elle-même : au-delà de 1, il y a saut.
func discontinuity(_ x: [Float], frequency: Double, gain: Double) -> Double {
    let expected = 2 * Double.pi * frequency / toneRate * gain
    var worst = 0.0
    for i in 1..<x.count { worst = max(worst, abs(Double(x[i] - x[i - 1]))) }
    return worst / max(expected, 1e-12)
}

var oscillator = ToneOscillator(sampleRate: toneRate, frequency: 440)
let attack = renderTone(&oscillator, frequency: 440, gain: 0.16, seconds: 0.05)
let steady = renderTone(&oscillator, frequency: 440, gain: 0.16, seconds: 1)

check("la fréquence demandée est celle qui sort",
      abs(measuredFrequency(steady) - 440) < 0.5,
      String(format: "%.2f Hz pour 440", measuredFrequency(steady)))

check("l'attaque part de zéro", abs(attack[0]) < 1e-4,
      String(format: "premier échantillon à %.5f", abs(attack[0])))
check("le fondu d'entrée ne claque pas",
      discontinuity(attack, frequency: 440, gain: 0.16) < 1.05,
      String(format: "×%.2f de l'écart attendu entre deux échantillons",
             discontinuity(attack, frequency: 440, gain: 0.16)))
let reached = steady.suffix(1000).map { abs($0) }.max() ?? 0
check("le niveau visé est atteint", abs(Double(reached) - 0.16) < 0.005,
      String(format: "%.3f pour 0,160", reached))

// Glissando : la consigne saute d'une quinte, le signal doit y aller en glissant
// et sans rupture de phase.
let glide = renderTone(&oscillator, frequency: 660, gain: 0.16, seconds: 0.2)
check("le glissando arrive à destination",
      abs(measuredFrequency(Array(glide.suffix(4800))) - 660) < 1,
      String(format: "%.1f Hz après 200 ms", measuredFrequency(Array(glide.suffix(4800)))))
check("le glissando ne rompt pas la phase",
      discontinuity(glide, frequency: 660, gain: 0.16) < 1.05,
      String(format: "×%.2f de l'écart attendu",
             discontinuity(glide, frequency: 660, gain: 0.16)))

// Grand écart : la fréquence est reposée d'un bond plutôt que glissée, mais la
// phase, elle, ne doit toujours pas sauter.
oscillator.jump(to: 3000)
let leap = renderTone(&oscillator, frequency: 3000, gain: 0.16, seconds: 0.05)
check("un saut d'octave ne claque pas non plus",
      discontinuity(leap, frequency: 3000, gain: 0.16) < 1.05,
      String(format: "×%.2f de l'écart attendu",
             discontinuity(leap, frequency: 3000, gain: 0.16)))

// Le moteur est mis en pause 200 ms après le relâchement : d'ici là le son doit
// être éteint pour de bon, sans quoi la pause elle-même couperait dans le vif.
let released = renderTone(&oscillator, frequency: 3000, gain: 0, seconds: 0.1)
let residual = Double(released.suffix(480).map { abs($0) }.max() ?? 1) / 0.16
check("le fondu de sortie éteint le son avant la pause du moteur",
      residual < 1e-4,
      String(format: "%.0f dB sous le niveau, 100 ms après le relâchement",
             20 * log10(max(residual, 1e-12))))
check("le fondu de sortie ne claque pas",
      discontinuity(released, frequency: 3000, gain: 0.16) < 1.05,
      String(format: "×%.2f de l'écart attendu",
             discontinuity(released, frequency: 3000, gain: 0.16)))

// MARK: Le triangle des accords
//
// Survoler un nom d'accord le fait entendre, et pas en sinusoïdes : un empilement
// de sinusoïdes pures n'a pas de timbre et ne ressemble à aucun instrument qui
// aurait pu jouer l'accord. Ce qu'on vérifie ici, c'est que la forme est bien un
// triangle — harmoniques impaires en 1/n² — sans les deux défauts qui guettent une
// forme anguleuse produite échantillon par échantillon : le repliement, et le
// changement de niveau en passant d'une forme à l'autre.
print("\n=== Triangle des accords ===")

/// Amplitude à une fréquence donnée, par produit scalaire avec sinus et cosinus.
func amplitude(_ x: [Float], at frequency: Double) -> Double {
    var re = 0.0, im = 0.0
    for (i, v) in x.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(i) / toneRate
        re += Double(v) * cos(phase)
        im += Double(v) * sin(phase)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(x.count)
}

var triangleOscillator = ToneOscillator(sampleRate: toneRate, frequency: 220)
let triangleAttack = renderTone(&triangleOscillator, frequency: 220, gain: 0.16,
                                seconds: 0.05, waveform: .triangle)
let triangleSteady = renderTone(&triangleOscillator, frequency: 220, gain: 0.16,
                                seconds: 1, waveform: .triangle)

check("le triangle sonne à la fréquence demandée",
      abs(measuredFrequency(triangleSteady) - 220) < 0.5,
      String(format: "%.2f Hz pour 220", measuredFrequency(triangleSteady)))
check("il part de zéro comme la sinusoïde", abs(triangleAttack[0]) < 1e-4,
      String(format: "premier échantillon à %.5f", abs(triangleAttack[0])))

// Le sommet, et c'est ce qui compte à l'usage : passer de la sinusoïde au triangle
// ne doit pas changer le volume de l'écoute.
let sommetTriangle = Double(triangleSteady.suffix(20000).map { abs($0) }.max() ?? 0)
// Le manque est la queue des harmoniques qu'on ne calcule pas : elle ne pèse qu'au
// sommet de la forme, et 2,5 % de sommet ne s'entendent pas.
let ecartSommet = abs(sommetTriangle - 0.16) / 0.16
check("son sommet est celui d'une sinusoïde de même gain, à 3 % près",
      ecartSommet < 0.03,
      String(format: "%.3f pour 0,160", sommetTriangle))

// Le spectre : impaires en 1/n², paires absentes.
let fondamentale = amplitude(triangleSteady, at: 220)
let troisieme = amplitude(triangleSteady, at: 660)
let cinquieme = amplitude(triangleSteady, at: 1100)
let deuxieme = amplitude(triangleSteady, at: 440)
check("la 3ᵉ harmonique vaut le neuvième de la fondamentale",
      abs(troisieme / fondamentale - 1.0 / 9) < 0.01,
      String(format: "%.4f pour %.4f", troisieme / fondamentale, 1.0 / 9))
check("la 5ᵉ en vaut le vingt-cinquième",
      abs(cinquieme / fondamentale - 1.0 / 25) < 0.005,
      String(format: "%.4f pour %.4f", cinquieme / fondamentale, 1.0 / 25))
check("et les harmoniques paires sont absentes",
      deuxieme / fondamentale < 0.01,
      String(format: "%.5f de la fondamentale", deuxieme / fondamentale))

// Le repliement : une note aiguë n'a plus la place de porter ses harmoniques. Elles
// doivent disparaître, et non revenir se poser dans le grave sur des hauteurs qui
// n'ont rien à voir avec la note — ce que ferait un triangle calculé par sa formule
// géométrique.
var aigu = ToneOscillator(sampleRate: toneRate, frequency: 9000)
_ = renderTone(&aigu, frequency: 9000, gain: 0.16, seconds: 0.05, waveform: .triangle)
let aiguSteady = renderTone(&aigu, frequency: 9000, gain: 0.16, seconds: 0.5,
                            waveform: .triangle)
// Toutes les hauteurs sondées de 300 Hz en 300 Hz, sauf la note elle-même.
var replie = 0.0
for k in 1...40 {
    let f = Double(k) * 300
    if abs(f - 9000) < 400 { continue }
    replie = max(replie, amplitude(aiguSteady, at: f))
}
let partReplie = replie / amplitude(aiguSteady, at: 9000)
check("une note aiguë ne replie aucune harmonique ailleurs dans le spectre",
      partReplie < 0.01,
      String(format: "%.5f de la fondamentale, au plus fort des autres hauteurs",
             partReplie))

// Et la sinusoïde, elle, n'a pas changé : c'est le son de la raie qu'on désigne
// dans le spectre, et une raie est une fréquence unique.
// Un oscillateur neuf : celui d'au-dessus vient de glisser d'une octave, et une
// fréquence qui bouge étale son spectre — on mesurerait le glissando, pas la forme.
var raie = ToneOscillator(sampleRate: toneRate, frequency: 440)
_ = renderTone(&raie, frequency: 440, gain: 0.16, seconds: 0.05)
let sinusoide = renderTone(&raie, frequency: 440, gain: 0.16, seconds: 0.5)
check("la raie désignée reste une sinusoïde pure",
      amplitude(sinusoide, at: 1320) / amplitude(sinusoide, at: 440) < 0.01,
      String(format: "3ᵉ harmonique à %.5f de la fondamentale",
             amplitude(sinusoide, at: 1320) / amplitude(sinusoide, at: 440)))

print("")
print("\n=== Rotation de la palette ===")
// Faire commencer la série des couleurs à une autre note ne doit **rien** changer à
// ce qui la fonde : deux notes proches dans le cycle des quintes restent proches en
// couleur, un triton reste en opposition. La rotation s'applique dans le cycle, pas
// sur le cercle chromatique — seul l'ancrage bouge.
func teintes(_ origine: Int) -> [Double] {
    (0..<12).map { NotePalette.hueTurns($0, origin: origine) }
}
/// Distance sur le cercle : 0,95 et 0,05 sont voisines, pas opposées. Comparer les
/// teintes sans ce repliement donnait un faux échec, la faute étant dans le contrôle.
func ecartCirculaire(_ x: Double, _ y: Double) -> Double {
    let d = abs(x - y).truncatingRemainder(dividingBy: 1)
    return min(d, 1 - d)
}
let teintesDo = teintes(0)
for origine in [3, 7, 11] {
    let tournees = teintes(origine)
    var pire = 0.0
    for a in 0..<12 {
        for b in 0..<12 {
            pire = max(pire, abs(ecartCirculaire(teintesDo[a], teintesDo[b])
                                 - ecartCirculaire(tournees[a], tournees[b])))
        }
    }
    check("la rotation sur \(Pitch.flatNames[origine]) conserve tous les écarts de teinte",
          pire < 1e-9, String(format: "écart maximal %.2e", pire))
    check("et \(Pitch.flatNames[origine]) reçoit bien la première teinte",
          abs(tournees[origine] - teintesDo[0]) < 1e-9,
          String(format: "%.3f tour", tournees[origine]))
}
check("les douze teintes restent distinctes après rotation",
      Set(teintes(5).map { String(format: "%.6f", $0) }).count == 12,
      "\(Set(teintes(5).map { String(format: "%.6f", $0) }).count) teintes")

if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
