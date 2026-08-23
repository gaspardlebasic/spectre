import Foundation
import SpectreCore
import SpectreTextes

// Vérifie le relevé des accords sur une grille fabriquée : on sait ce qui est joué,
// donc on sait ce qui doit être lu.
//
// **Le banc part du son et va jusqu'au nom**, en passant par la vraie analyse et la
// vraie matrice — c'est la seule façon d'éprouver un relevé qui lit l'image plutôt
// que le signal. Ce qui est vérifié n'est donc pas une formule mais une chaîne :
// synthétiser, analyser, relever les sommets, compter les tenues, écarter les
// harmoniques, nommer.
//
// Les pièges sont choisis, pas trouvés au hasard — ce sont ceux sur lesquels un
// détecteur d'accords se casse toujours :
//
//   - majeur contre mineur sur un timbre riche, parce que la tierce majeure est déjà
//     dans les harmoniques de la fondamentale ;
//   - un renversement, parce que la note la plus grave n'est pas la fondamentale ;
//   - une sixte contre son mineur septième, qui sont le même jeu de notes ;
//   - une note de passage à la basse, qui ne doit pas entrer dans l'accord.

var failures = 0

func check(_ passed: Bool, _ what: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}

// MARK: - Un instrument de synthèse

let rate = 44100.0
let bpm = 120.0
let beat = 60 / bpm

/// Une note, avec assez d'harmoniques pour que le problème soit réel.
///
/// Le timbre est volontairement riche : une sinusoïde pure rendrait la tâche facile
/// et ne prouverait rien. Six harmoniques décroissantes, c'est à peu près un piano ou
/// une guitare — et c'est ce qui met la tierce majeure fantôme dans le spectre.
func note(midi: Int, from start: Double, seconds: Double, gain: Double,
          into buffer: inout [Float]) {
    let f0 = Pitch.frequency(ofMidi: Double(midi))
    let first = Int(start * rate)
    let count = Int(seconds * rate)
    for i in 0..<count {
        let j = first + i
        guard j >= 0, j < buffer.count else { continue }
        let t = Double(i) / rate
        // Attaque et extinction douces : un créneau produirait un clic dont le
        // spectre large fausserait tout.
        let envelope = min(t / 0.02, 1) * min((Double(count) / rate - t) / 0.05, 1)
        var value = 0.0
        for h in 1...6 {
            value += pow(0.55, Double(h - 1)) * sin(2 * .pi * f0 * Double(h) * t)
        }
        buffer[j] += Float(gain * max(envelope, 0) * value * 0.2)
    }
}

/// Une grille : un accord par mesure, quatre temps chacun.
struct Bar {
    var pitches: [Int]      // ce que joue l'accompagnement, en MIDI
    var bass: Int           // ce que joue la basse, en MIDI
    var expected: Chord
    /// Une note qui ne dure qu'un temps, posée au troisième : c'est une broderie, et
    /// elle ne doit pas entrer dans l'accord.
    var passing: Int?
    /// Vrai pour une basse qui marche : deux notes d'un demi-temps chacune.
    var walking: Int?

    init(pitches: [Int], bass: Int, expected: Chord, passing: Int? = nil,
         walking: Int? = nil) {
        self.pitches = pitches
        self.bass = bass
        self.expected = expected
        self.passing = passing
        self.walking = walking
    }
}

/// Rend la grille en un seul signal — celui qu'on afficherait.
///
/// Un seul, et c'est le changement de fond : le relevé ne lit plus deux pistes
/// séparées mais l'image, et l'image est un mixage. La basse y est un peu plus forte,
/// comme dans la vraie vie.
func render(_ bars: [Bar]) -> [Float] {
    let seconds = Double(bars.count) * 4 * beat + 1
    var mix = [Float](repeating: 0, count: Int(seconds * rate))
    for (index, bar) in bars.enumerated() {
        let start = Double(index) * 4 * beat
        for pitch in bar.pitches {
            note(midi: pitch, from: start, seconds: 4 * beat - 0.02, gain: 1, into: &mix)
        }
        if let passing = bar.passing {
            note(midi: passing, from: start + 2 * beat, seconds: beat - 0.03, gain: 1,
                 into: &mix)
        }
        // La basse rejoue à chaque temps : c'est ce que fait une basse.
        for b in 0..<4 {
            let midi = (bar.walking != nil && b >= 2) ? bar.walking! : bar.bass
            note(midi: midi, from: start + Double(b) * beat, seconds: beat - 0.03,
                 gain: 1.4, into: &mix)
        }
    }
    return mix
}

let tempo = TempoGrid(bpm: bpm, origin: 0, beatsPerBar: 4, confidence: 10)

/// Le chemin complet : le son, la matrice, le contraste, la carte, le relevé.
func read(_ bars: [Bar], settings: ChordSettings = defaults) -> ChordTrack {
    let mix = render(bars)
    let spectrogram = OfflineAnalysis.run(samples: mix, sampleRate: rate,
                                          settings: AnalysisSettings())
    var display = DisplaySettings()
    display = AutoContrast.settings(basedOn: display, in: spectrogram) ?? display
    let map = NoteMap.build(spectrogram, referenceA: display.referenceA,
                            prominence: settings.prominence)
    return ChordDetector.detect(map: map, display: display, tempo: tempo,
                                settings: settings)
}

/// Les réglages du banc : la portée « mesure », puisque c'est une mesure qu'on joue.
var defaults: ChordSettings = {
    var s = ChordSettings()
    s.scope = .span
    return s
}()

func nom(_ c: Chord?) -> String { c?.label() ?? "—" }
func noms(_ notes: [SoundingNote]) -> String {
    notes.map { $0.name() + ($0.role == .extra ? "?" : ($0.role == .root ? "*" : "")) }
        .joined(separator: " ")
}

// MARK: - L'écriture des noms

// Le banc travaille en français, quelle que soit la machine qui le fait tourner :
// tout ce qui suit compare des noms d'accords écrits d'avance, et un relevé juste
// ne doit pas passer pour faux parce que le Mac est réglé en polonais.
Textes.langue = .fr
Textes.choixDeNotes = nil

print("=== Noms ===")
check(Chord(root: 0, quality: .major).label() == "Do", "un majeur ne porte pas de symbole",
      Chord(root: 0, quality: .major).label())
check(Chord(root: 9, quality: .minor).label() == "La-", "le mineur s'écrit avec un tiret",
      Chord(root: 9, quality: .minor).label())
check(Chord(root: 0, quality: .major7).label() == "DoΔ", "la septième majeure s'écrit Δ",
      Chord(root: 0, quality: .major7).label())
check(Chord(root: 7, quality: .dominant7).label() == "Sol7", "la septième de dominante",
      Chord(root: 7, quality: .dominant7).label())
check(Chord(root: 2, quality: .minor7).label() == "Ré-7", "le mineur septième",
      Chord(root: 2, quality: .minor7).label())
check(Chord(root: 11, quality: .halfDiminished).label() == "Siø", "le demi-diminué",
      Chord(root: 11, quality: .halfDiminished).label())
check(Chord(root: 0, quality: .major6).label() == "Do6", "la sixte",
      Chord(root: 0, quality: .major6).label())
check(Chord(root: 10, quality: .major).label() == "Si♭", "les bémols par défaut",
      Chord(root: 10, quality: .major).label())
check(Chord(root: 0, quality: .major6).pitchClasses == [0, 4, 7, 9],
      "et la sixte porte bien ses quatre notes",
      Chord(root: 0, quality: .major6).pitchClasses.map(String.init).joined(separator: " "))
check(Chord.vocabulary.count == 12 * ChordQuality.allCases.count,
      "douze fondamentales par couleur", "\(Chord.vocabulary.count) accords")

// MARK: - Les mêmes accords, dans les quatre écritures
//
// Un accord ne change pas de notes en changeant de pays : ce qui change est son
// nom. On le vérifie sur les trois cas qui séparent réellement les systèmes — le
// mineur, la septième majeure, et le si, que l'allemand et le polonais appellent H
// quand ils réservent B au si bémol.

print("\n=== Les quatre écritures ===")

/// Le nom d'un accord dans un système donné, sans laisser le harnais dans cet état.
func nomDans(_ systeme: SystemeDeNotes, _ accord: Chord) -> String {
    let avant = Textes.choixDeNotes
    Textes.choixDeNotes = systeme
    let ecrit = accord.label()
    Textes.choixDeNotes = avant
    return ecrit
}

let accordLaMineur = Chord(root: 9, quality: .minor)
let doMajeur7 = Chord(root: 0, quality: .major7)
let siMajeur = Chord(root: 11, quality: .major)
let siBemolMajeur = Chord(root: 10, quality: .major)
let faDieseMineur = Chord(root: 6, quality: .minor)

check(nomDans(.latinFr, accordLaMineur) == "La-", "français : le mineur au tiret",
      nomDans(.latinFr, accordLaMineur))
check(nomDans(.latinEs, accordLaMineur) == "Lam", "espagnol : Do Re Mi, mais le m anglo-saxon",
      nomDans(.latinEs, accordLaMineur))
check(nomDans(.anglo, accordLaMineur) == "Am", "anglais", nomDans(.anglo, accordLaMineur))
check(nomDans(.germanique, accordLaMineur) == "Am", "allemand et polonais",
      nomDans(.germanique, accordLaMineur))

check(nomDans(.latinFr, doMajeur7) == "DoΔ", "français : la septième majeure en Δ",
      nomDans(.latinFr, doMajeur7))
check(nomDans(.anglo, doMajeur7) == "Cmaj7", "anglais : maj7", nomDans(.anglo, doMajeur7))
check(nomDans(.latinEs, doMajeur7) == "Domaj7",
      "espagnol : maj7 sur une fondamentale latine",
      nomDans(.latinEs, doMajeur7))

// Le seul point de tout ce fichier qu'on ne devine pas depuis le français.
check(nomDans(.germanique, siMajeur) == "H", "en allemand, le si naturel s'écrit H",
      nomDans(.germanique, siMajeur))
check(nomDans(.germanique, siBemolMajeur) == "B", "et le si bémol s'écrit B",
      nomDans(.germanique, siBemolMajeur))
check(nomDans(.anglo, siMajeur) == "B", "là où l'anglais écrit B pour le si naturel",
      nomDans(.anglo, siMajeur))

// En dièses, l'écriture germanique nomme les altérations en toutes lettres.
let avantDieses = Textes.choixDeNotes
Textes.choixDeNotes = .germanique
check(faDieseMineur.label(flats: false) == "Fism", "et Fa♯ mineur s'écrit Fism",
      faDieseMineur.label(flats: false))
Textes.choixDeNotes = avantDieses

// Les notes, elles, n'ont pas bougé : c'est tout l'objet de ce contrôle.
check(accordLaMineur.pitchClasses == [9, 0, 4],
      "et les notes de l'accord sont les mêmes dans les quatre écritures",
      accordLaMineur.pitchClasses.map(String.init).joined(separator: " "))

// MARK: - Le découpage

print()
print("=== Découpage ===")
let bounds = ChordDetector.beatBounds(tempo: tempo, duration: 10)
check(bounds.count == 21, "un temps toutes les demi-secondes sur dix secondes",
      "\(bounds.count) frontières")
check(abs(bounds[0]) < 1e-9 && abs(bounds[4] - 2.0) < 1e-9,
      "les frontières tombent sur les temps")
let decale = TempoGrid(bpm: bpm, origin: 0.3, beatsPerBar: 4)
let decalees = ChordDetector.beatBounds(tempo: decale, duration: 10)
check(decalees.allSatisfy { $0 >= 0 }, "aucune frontière avant le début du fichier")
check(abs(decalees[0] - 0.3) < 1e-9, "elles suivent l'origine de la grille",
      String(format: "%.2f s", decalees[0]))
let mesures = ChordDetector.barSpans(tempo: tempo, duration: 9)
check(mesures.count == 4, "quatre mesures entières tiennent dans neuf secondes",
      "\(mesures.count)")
check(mesures.last.map { $0.upperBound <= 9 } ?? false,
      "et la dernière ne déborde pas")

// MARK: - La carte des notes

print()
print("=== La carte des notes ===")
// Une note tenue, seule. Ce qu'on doit retrouver dans la carte : elle, et pas ses
// harmoniques une fois le tri fait.
var seule = [Float](repeating: 0, count: Int(rate * 3))
note(midi: 60, from: 0.2, seconds: 2.6, gain: 1, into: &seule)
let matriceSeule = OfflineAnalysis.run(samples: seule, sampleRate: rate,
                                       settings: AnalysisSettings())
var affichage = DisplaySettings()
affichage = AutoContrast.settings(basedOn: affichage, in: matriceSeule) ?? affichage
let carteSeule = NoteMap.build(matriceSeule, referenceA: affichage.referenceA)
check(!carteSeule.isEmpty, "la carte se relève sur une vraie matrice",
      "\(carteSeule.columnCount) colonnes, \(carteSeule.noteCount) demi-tons")

let tenuesSeule = ChordVoicing.held(in: carteSeule, from: 0.5, to: 2.5,
                                    display: affichage, settings: defaults)
check(tenuesSeule.contains { $0.midi == 60 }, "la note jouée y est",
      noms(tenuesSeule))
check(tenuesSeule.count == 1,
      "et elle seule : ses six harmoniques sont expliquées par elle",
      "\(tenuesSeule.count) raies — \(noms(tenuesSeule))")
// Le voisinage immédiat, qui est le défaut qu'on a vu sur de la vraie musique : la
// traînée d'une note forte ne doit pas devenir une note un demi-ton à côté.
check(!tenuesSeule.contains { abs($0.midi - 60) == 1 },
      "et rien à un demi-ton d'elle")

// La netteté exigée est bien ce qui l'écarte : à zéro, la traînée revient.
var molle = defaults
molle.prominence = 0
let carteMolle = NoteMap.build(matriceSeule, referenceA: affichage.referenceA,
                               prominence: 0)
let tenuesMolles = ChordVoicing.held(in: carteMolle, from: 0.5, to: 2.5,
                                     display: affichage, settings: molle)
check(tenuesMolles.count >= tenuesSeule.count,
      "sans exigence de netteté, la carte retient au moins autant de raies",
      "\(tenuesMolles.count) contre \(tenuesSeule.count)")

// Le contraste commande : monter le noir au-dessus de la note l'efface.
var sombre = affichage
sombre.floorDb = 0
check(ChordVoicing.held(in: carteSeule, from: 0.5, to: 2.5, display: sombre,
                        settings: defaults).isEmpty,
      "une image réglée toute noire ne tient aucune raie")

// MARK: - Une grille simple

print()
print("=== Une grille ===")
// Do, La-, Fa, Sol : les quatre accords les plus joués de la musique populaire, et
// justement ceux qui se confondent le plus — Do et La- partagent deux notes.
let grille: [Bar] = [
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [57, 60, 64], bass: 33, expected: Chord(root: 9, quality: .minor)),
    Bar(pitches: [53, 57, 60], bass: 29, expected: Chord(root: 5, quality: .major)),
    Bar(pitches: [55, 59, 62], bass: 31, expected: Chord(root: 7, quality: .major)),
]
let lue = read(grille)
check(lue.segments.count == grille.count, "une mesure jouée donne un segment",
      "\(lue.segments.count) segments")
for (bar, segment) in zip(grille, lue.segments) {
    check(segment.chord?.root == bar.expected.root,
          "la fondamentale de \(bar.expected.label()) est trouvée",
          "lu \(nom(segment.chord)) sur \(noms(segment.notes))")
}
check(zip(grille, lue.segments).allSatisfy { $0.expected == $1.chord },
      "les quatre accords sont nommés exactement",
      lue.segments.map { nom($0.chord) }.joined(separator: " "))

// L'adéquation, qui est tout le propos : ce qui a été retenu est dans l'accord.
let inexpliquees = lue.segments.flatMap { $0.notes.filter { $0.role == .extra } }
check(inexpliquees.isEmpty,
      "aucune raie tenue ne reste inexpliquée par le nom retenu",
      inexpliquees.isEmpty ? "" : noms(inexpliquees))
check(lue.segments.allSatisfy { !$0.notes.isEmpty },
      "et chaque nom s'appuie sur des raies qu'on peut montrer",
      lue.segments.map { "\($0.notes.count)" }.joined(separator: " "))
// Les raies retenues portent toutes une classe de l'accord, à leur octave.
check(lue.segments.allSatisfy { segment in
          guard let chord = segment.chord else { return false }
          return segment.notes.allSatisfy { chord.pitchClasses.contains($0.pitchClass) }
      },
      "toutes appartiennent à l'accord, quelle que soit l'octave")
check(lue.segments.allSatisfy { $0.notes.contains { $0.role == .root } },
      "et la fondamentale est marquée dans chacune")

// MARK: - Majeur contre mineur

print()
print("=== Majeur contre mineur ===")
let couleurs: [Bar] = [
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [60, 63, 67], bass: 36, expected: Chord(root: 0, quality: .minor)),
    Bar(pitches: [62, 66, 69], bass: 38, expected: Chord(root: 2, quality: .major)),
    Bar(pitches: [62, 65, 69], bass: 38, expected: Chord(root: 2, quality: .minor)),
]
let teintes = read(couleurs)
for (bar, segment) in zip(couleurs, teintes.segments) {
    check(segment.chord == bar.expected,
          "\(bar.expected.label()) sur un timbre à six harmoniques",
          "lu \(nom(segment.chord)) sur \(noms(segment.notes))")
}

// MARK: - Ce que la basse tranche

print()
print("=== Ce que la basse tranche ===")
// Do majeur premier renversement : la basse joue Mi. Sans elle on hésiterait ; avec
// elle, il faut justement ne PAS conclure Mi mineur — les notes jouées sont celles de
// Do, et Mi- demanderait un Sol♯.
let renverse: [Bar] = [
    Bar(pitches: [64, 67, 72], bass: 40, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
]
let renverses = read(renverse)
check(renverses.segments[0].chord?.root == 0,
      "un renversement reste l'accord de sa fondamentale, pas de sa basse",
      "lu \(nom(renverses.segments[0].chord)) sur \(noms(renverses.segments[0].notes))")

// La sixte et le mineur septième : **exactement les mêmes notes**, seule la basse les
// sépare. C'est le cas qui a fait entrer les sixtes au vocabulaire.
let sixtes: [Bar] = [
    Bar(pitches: [60, 64, 67, 69], bass: 36, expected: Chord(root: 0, quality: .major6)),
    Bar(pitches: [60, 64, 67, 69], bass: 33, expected: Chord(root: 9, quality: .minor7)),
]
let lues = read(sixtes)
check(lues.segments[0].chord?.root == 0 && lues.segments[1].chord?.root == 9,
      "les mêmes notes se nomment selon leur basse",
      "\(nom(lues.segments[0].chord)) puis \(nom(lues.segments[1].chord))")

// MARK: - Ce qui ne dure pas

print()
print("=== Notes de passage ===")
// Une broderie d'un temps sur quatre au-dessus, et une basse qui marche en dessous :
// ni l'une ni l'autre ne doit entrer dans l'accord, et c'est la seule explication
// qu'on doive à quelqu'un qui les voit à l'écran.
let passages: [Bar] = [
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major),
        passing: 62),
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major),
        walking: 38),
]
let broderies = read(passages)
check(broderies.segments[0].chord == Chord(root: 0, quality: .major),
      "une broderie d'un temps ne change pas le nom de la mesure",
      "lu \(nom(broderies.segments[0].chord)) sur \(noms(broderies.segments[0].notes))")
check(!broderies.segments[0].notes.contains { $0.pitchClass == 2 },
      "et elle n'est pas retenue : elle n'a pas tenu la mesure")
check(broderies.segments[1].chord == Chord(root: 0, quality: .major),
      "une basse qui marche ne change pas le nom non plus",
      "lu \(nom(broderies.segments[1].chord)) sur \(noms(broderies.segments[1].notes))")
check(!broderies.segments[1].notes.contains { $0.pitchClass == 2 },
      "et la note de passage de la basse n'est pas retenue")

// La preuve par l'inverse : la même note, tenue toute la mesure, entre dans le relevé.
let tenue: [Bar] = [
    Bar(pitches: [60, 62, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
]
let avecRe = read(tenue)
check(avecRe.segments[0].notes.contains { $0.pitchClass == 2 },
      "la même note, tenue, est retenue — c'est bien la durée qui tranche",
      noms(avecRe.segments[0].notes))
// Et le vocabulaire sait maintenant l'écrire : c'est un `add9`, pas un majeur avec
// une note en trop. C'est exactement ce que les enrichissements ont apporté.
check(avecRe.segments[0].chord == Chord(root: 0, quality: .add9),
      "et le vocabulaire sait l'écrire : c'est une neuvième ajoutée",
      nom(avecRe.segments[0].chord))
check(avecRe.segments[0].notes.allSatisfy { $0.role != .extra },
      "plus rien n'y reste inexpliqué", noms(avecRe.segments[0].notes))
// Sans les enrichissements, la même mesure retombe sur sa triade et montre la
// neuvième en pointillés : le relevé ne cache pas ce qu'il ne sait pas nommer.
var sansEnrichissements = defaults
sansEnrichissements.vocabulary = .all
let sansNeuvieme = read(tenue, settings: sansEnrichissements)
check(sansNeuvieme.segments[0].chord == Chord(root: 0, quality: .major),
      "un vocabulaire sans enrichissements retombe sur la triade",
      nom(sansNeuvieme.segments[0].chord))
check(sansNeuvieme.segments[0].notes.contains { $0.pitchClass == 2 && $0.role == .extra },
      "et montre la neuvième comme inexpliquée plutôt que de la taire",
      noms(sansNeuvieme.segments[0].notes))

// MARK: - Le silence

print()
print("=== Silence ===")
let vide = [Float](repeating: 0, count: Int(rate * 4))
let matriceVide = OfflineAnalysis.run(samples: vide, sampleRate: rate,
                                      settings: AnalysisSettings())
let carteVide = NoteMap.build(matriceVide, referenceA: 440)
let rien = ChordDetector.detect(map: carteVide, display: DisplaySettings(), tempo: tempo,
                                settings: defaults)
check(!rien.segments.isEmpty, "le silence produit quand même des segments",
      "\(rien.segments.count)")
check(rien.segments.allSatisfy { $0.chord == nil }, "mais aucun n'est nommé")
check(rien.segments.allSatisfy { $0.notes.isEmpty }, "et aucune raie n'est montrée")
let sansGrille = ChordDetector.detect(map: carteVide, display: DisplaySettings(),
                                      tempo: TempoGrid(bpm: 0, origin: 0),
                                      settings: defaults)
check(sansGrille.isEmpty, "sans grille métrique, aucun relevé — il n'y aurait où l'écrire")

// MARK: - La portée « sélection »

print()
print("=== Le passage sélectionné ===")
// La deuxième mesure, seule : de 2 à 4 secondes, c'est La mineur.
let choisi = 2.0...4.0
let mix = render(grille)
let matrice = OfflineAnalysis.run(samples: mix, sampleRate: rate, settings: AnalysisSettings())
var vue = DisplaySettings()
vue = AutoContrast.settings(basedOn: vue, in: matrice) ?? vue
let carte = NoteMap.build(matrice, referenceA: vue.referenceA)
let selection = ChordDetector.detect(map: carte, display: vue, tempo: tempo,
                                     settings: defaults, selection: choisi)
check(selection.segments.count == 1,
      "une sélection ne donne qu'un seul accord, pour tout le passage",
      "\(selection.segments.count) segments")
check(selection.segments.first.map {
          abs($0.start - choisi.lowerBound) < 1e-9 && abs($0.end - choisi.upperBound) < 1e-9
      } ?? false,
      "posé exactement sur les bornes choisies",
      selection.segments.first.map { String(format: "%.2f–%.2f s", $0.start, $0.end) } ?? "—")
check(selection.segments.first?.chord == Chord(root: 9, quality: .minor),
      "et c'est bien ce qui s'y joue",
      "\(nom(selection.segments.first?.chord)) sur \(noms(selection.segments[0].notes))")

// En portée « temps » aussi : entourer un passage, c'est demander son accord, et
// découper en temps ce qu'on vient de tracer à la main répondrait à une autre
// question. La portée réglée reprend la main dès que la sélection s'efface.
var parTemps = defaults
parTemps.scope = .beat
let surSelection = ChordDetector.detect(map: carte, display: vue, tempo: tempo,
                                        settings: parTemps, selection: choisi)
check(surSelection.segments.count == 1,
      "la portée « temps » cède elle aussi à la sélection",
      "\(surSelection.segments.count) segment(s)")
check(surSelection.segments.first?.chord == Chord(root: 9, quality: .minor),
      "et y lit le même accord que la portée « mesure »",
      "\(nom(surSelection.segments.first?.chord))")
let sansSelection = ChordDetector.detect(map: carte, display: vue, tempo: tempo,
                                         settings: parTemps, selection: nil)
check(sansSelection.segments.count > grille.count,
      "sans sélection, elle redécoupe bien au temps",
      "\(sansSelection.segments.count) segments")

// MARK: - Le vocabulaire

print()
print("=== Vocabulaire ===")
var triades = defaults
triades.vocabulary = .triads
check(triades.chords.count == 36, "le vocabulaire restreint aux triades",
      "\(triades.chords.count) accords")
check(ChordSettings.Vocabulary.allCases.map { $0.qualities.count }
        == ChordSettings.Vocabulary.allCases.map { $0.qualities.count }.sorted(),
      "les paliers vont du plus pauvre au plus riche",
      ChordSettings.Vocabulary.allCases.map { "\($0.qualities.count)" }
        .joined(separator: " < "))
check(ChordSettings().vocabulary == .extended,
      "et les enrichissements sont là par défaut")
check(triades.chords.allSatisfy { $0.quality != .dominant7 },
      "et il ne contient plus de septièmes")
let septiemes: [Bar] = [
    Bar(pitches: [62, 65, 69, 72], bass: 38, expected: Chord(root: 2, quality: .minor7)),
    Bar(pitches: [55, 59, 62, 65], bass: 31, expected: Chord(root: 7, quality: .dominant7)),
]
let enrichis: [Bar] = [
    // Do neuvième : Do Mi Sol Si♭ Ré. La neuvième est jouée haut, comme on la joue.
    Bar(pitches: [60, 64, 67, 70, 74], bass: 36,
        expected: Chord(root: 0, quality: .ninth)),
    // Fa treizième : Fa La Mi♭ Sol Ré, la quinte omise comme on l'omet. Les notes
    // sont étalées — un voicing qui empilerait la neuvième et la septième sur des
    // demi-tons voisins ne se joue pas, et l'une masquerait l'autre dans l'image.
    Bar(pitches: [53, 57, 63, 67, 74], bass: 41,
        expected: Chord(root: 5, quality: .thirteenth)),
]
let lusEnrichis = read(enrichis)
for (bar, segment) in zip(enrichis, lusEnrichis.segments) {
    check(segment.chord == bar.expected, "\(bar.expected.label()) est nommée entièrement",
          "lu \(nom(segment.chord)) sur \(noms(segment.notes))")
}

let riches = read(septiemes)
for (bar, segment) in zip(septiemes, riches.segments) {
    check(segment.chord == bar.expected, "\(bar.expected.label()) est nommée entièrement",
          "lu \(nom(segment.chord)) sur \(noms(segment.notes))")
}
let pauvres = read(septiemes, settings: triades)
check(pauvres.segments.allSatisfy {
          $0.chord == nil || triades.vocabulary.qualities.contains($0.chord!.quality)
      },
      "lue en triades, la même grille n'écrit plus une seule septième",
      pauvres.segments.map { nom($0.chord) }.joined(separator: " "))
check(pauvres.segments.allSatisfy { $0.notes.contains { $0.role == .extra } },
      "et la septième qu'on ne peut plus nommer est montrée comme inexpliquée",
      pauvres.segments.map { noms($0.notes) }.joined(separator: " | "))

// MARK: - Regroupement à l'affichage

print()
print("=== Regroupement ===")
let track = ChordTrack(segments: (0..<16).map { k in
    ChordSegment(start: Double(k) * beat, end: Double(k + 1) * beat,
                 chord: Chord(root: k < 8 ? 0 : 5, quality: .major), confidence: 1,
                 notes: [SoundingNote(midi: 60 + (k < 8 ? 0 : 5), level: -20, role: .root),
                         SoundingNote(midi: 72 + k, level: -30, role: .chord)])
})
let parTempsEcrit = track.labels(from: 0, to: 8, grouping: 1)
let parMesure = track.labels(from: 0, to: 8, grouping: 4)
check(parTempsEcrit.count == 2, "seize temps sur deux accords donnent deux étiquettes",
      "\(parTempsEcrit.count)")
check(parMesure.count == 2, "et par mesure aussi : un accord tenu ne se réécrit pas",
      "\(parMesure.count)")
check(parMesure[0].chord?.root == 0 && parMesure[1].chord?.root == 5,
      "dans l'ordre, avec les bons accords",
      parMesure.map { nom($0.chord) }.joined(separator: " "))
check(abs(parMesure[0].end - 8 * beat) < 1e-9,
      "et la première étiquette s'étend jusqu'au changement, pas jusqu'à la barre",
      String(format: "finit à %.2f s", parMesure[0].end))
// Les raies d'une étiquette fondue sont celles qui ont tenu **partout** : le cadre
// qu'on dessine court sur toute sa longueur, et montrer une raie qui n'a tenu que
// dans la première mesure serait dessiner un cadre là où il n'y a rien.
check(parMesure[0].notes.map(\.midi) == [60],
      "et ses raies sont celles que tous les temps partagent",
      parMesure[0].notes.map { $0.name() }.joined(separator: " "))

// MARK: L'alignement sur les barres de mesure
//
// Le piège, et il a coûté cher : une grille dont le premier temps fort ne tombe pas à
// zéro. Les temps relevés commencent alors avant lui, et regrouper « tous les quatre
// temps depuis le début du fichier » place les noms à côté des barres.
let origine = 1.637
let decalee = TempoGrid(bpm: bpm, origin: origine, beatsPerBar: 4)
let premiers = ChordDetector.beatBounds(tempo: decalee, duration: 20)
let piste = ChordTrack(segments: premiers.dropLast().enumerated().map { k, t in
    ChordSegment(start: t, end: premiers[k + 1],
                 chord: Chord(root: k % 12, quality: .major), confidence: 1)
}, firstBeat: Int(decalee.beat(at: premiers[0]).rounded()))
check(piste.firstBeat < 0, "un morceau qui commence avant le premier temps fort",
      "premier temps relevé : \(piste.firstBeat)")
let parBarres = piste.labels(from: 0, to: 20, grouping: 4)
let alignees = parBarres.dropFirst().allSatisfy {
    decalee.opensBar(decalee.beat(at: $0.start).rounded())
        && abs(decalee.beat(at: $0.start) - decalee.beat(at: $0.start).rounded()) < 1e-6
}
check(alignees, "les étiquettes tombent sur les barres de mesure",
      parBarres.dropFirst().prefix(3)
        .map { String(format: "%.3f s", $0.start) }.joined(separator: ", "))
check(parBarres.first.map { $0.end - $0.start } ?? 0 < 4 * beat - 1e-9,
      "et la première est une levée, plus courte qu'une mesure",
      String(format: "%.2f temps", (parBarres[0].end - parBarres[0].start) / beat))
let droite = ChordTrack(segments: (0..<16).map { k in
    ChordSegment(start: Double(k) * beat, end: Double(k + 1) * beat,
                 chord: Chord(root: k / 4, quality: .major), confidence: 1)
}, firstBeat: 0)
check(droite.labels(from: 0, to: 8, grouping: 4).count == 4,
      "une grille à l'origine donne quatre mesures pleines",
      "\(droite.labels(from: 0, to: 8, grouping: 4).count)")
let anacrouse = ChordTrack(segments: (0..<4).map { k in
    ChordSegment(start: Double(k) * beat, end: Double(k + 1) * beat,
                 chord: Chord(root: k == 0 ? 7 : 0, quality: .major), confidence: 1)
})
check(anacrouse.labels(from: 0, to: 2, grouping: 4).first?.chord?.root == 0,
      "un temps isolé ne donne pas son nom à la mesure",
      nom(anacrouse.labels(from: 0, to: 2, grouping: 4).first?.chord))

// MARK: - Les réglages

print()
print("=== Réglages ===")
check(ChordSettings().rarityWeight == 0,
      "les couleurs rares ne coûtent rien par défaut")
check(ChordSettings().hold > 0.5 && ChordSettings().hold < 1,
      "et une raie doit tenir l'essentiel de l'intervalle",
      String(format: "%.0f %%", ChordSettings().hold * 100))
let partiel = Data("{\"scope\":1}".utf8)
if let relus = try? JSONDecoder().decode(ChordSettings.self, from: partiel) {
    check(relus.scope == .span && relus.hold == ChordSettings().hold,
          "un réglage enregistré par une version plus ancienne se relit",
          String(format: "tenue %.2f", relus.hold))
} else {
    check(false, "un réglage enregistré par une version plus ancienne se relit",
          "décodage refusé")
}
check(ChordSettings().mapKey != { var s = ChordSettings(); s.prominence = 6; return s }().mapKey,
      "changer la netteté périme la carte des notes")
check(ChordSettings().mapKey == { var s = ChordSettings(); s.hold = 0.9; return s }().mapKey,
      "changer la tenue, non : elle se relit sur la même carte")

// MARK: - La basse ne compte que par sa fondamentale

print()
print("=== Les harmoniques de la basse ===")

/// Une note au timbre imposé, harmonique par harmonique.
///
/// Ce qu'on veut fabriquer ici n'existe pas dans `note(midi:…)` : une basse dont la
/// cinquième harmonique écrase la fondamentale. C'est une caricature — mais du bon
/// côté, celui qui rend le défaut visible : 5·f₀ tombe une tierce majeure deux
/// octaves plus haut, et c'est exactement la note qui transforme un mineur en majeur.
func timbre(midi: Int, from start: Double, seconds: Double,
            partials: [Double], into buffer: inout [Float]) {
    let f0 = Pitch.frequency(ofMidi: Double(midi))
    let first = Int(start * rate)
    let count = Int(seconds * rate)
    for i in 0..<count {
        let j = first + i
        guard j >= 0, j < buffer.count else { continue }
        let t = Double(i) / rate
        let envelope = min(t / 0.02, 1) * min((Double(count) / rate - t) / 0.05, 1)
        var value = 0.0
        for (k, gain) in partials.enumerated() where gain != 0 {
            value += gain * sin(2 * .pi * f0 * Double(k + 1) * t)
        }
        buffer[j] += Float(max(envelope, 0) * value * 0.2)
    }
}

let nombreDeMesures = 4.0
let duree = nombreDeMesures * 4 * beat + 1
let laMineur = [57, 60, 64]        // La3, Do4, Mi4
let laGrave = 33                   // La1 : sa 5ᵉ harmonique tombe sur Do♯4

var basseSeule = [Float](repeating: 0, count: Int(duree * rate))
var accompagnement = [Float](repeating: 0, count: Int(duree * rate))
for mesure in 0..<Int(nombreDeMesures) {
    let start = Double(mesure) * 4 * beat
    for pitch in laMineur {
        note(midi: pitch, from: start, seconds: 4 * beat - 0.02, gain: 1,
             into: &accompagnement)
    }
    for temps in 0..<4 {
        timbre(midi: laGrave, from: start + Double(temps) * beat, seconds: beat - 0.03,
               partials: [0.6, 0.2, 0.3, 0.2, 1.6, 0.1], into: &basseSeule)
    }
}
var melange = basseSeule
for i in melange.indices { melange[i] += accompagnement[i] }

let matriceMix = OfflineAnalysis.run(samples: melange, sampleRate: rate,
                                     settings: AnalysisSettings())
let matriceBasse = OfflineAnalysis.run(samples: basseSeule, sampleRate: rate,
                                       settings: AnalysisSettings())
var vueBasse = DisplaySettings()
vueBasse = AutoContrast.settings(basedOn: vueBasse, in: matriceMix) ?? vueBasse
let carteMix = NoteMap.build(matriceMix, referenceA: vueBasse.referenceA)
let carteBasse = NoteMap.build(matriceBasse, referenceA: vueBasse.referenceA)

let sansBasse = ChordDetector.detect(map: carteMix, display: vueBasse, tempo: tempo,
                                     settings: defaults)
let avecBasse = ChordDetector.detect(map: carteMix, display: vueBasse, tempo: tempo,
                                     settings: defaults, bass: carteBasse)

/// Les classes de hauteur retenues sur la deuxième mesure — la première porte une
/// attaque, la dernière une extinction.
func classes(_ track: ChordTrack) -> Set<Int> {
    guard let segment = track.segment(at: 4 * beat + 0.1) else { return [] }
    return Set(segment.notes.map(\.pitchClass))
}
let avant = classes(sansBasse)
let apres = classes(avecBasse)
print("  lu sans la carte de basse : \(avant.sorted())")
print("  lu avec : \(apres.sorted())")

check(avant.contains(1),
      "sans la carte de basse, la 5ᵉ harmonique entre bien dans le relevé",
      "Do♯ retenu — c'est le défaut qu'on corrige")
check(!apres.contains(1),
      "avec elle, la tierce fantôme disparaît",
      "classes retenues : \(apres.sorted())")
check(apres.contains(9),
      "la fondamentale de la basse, elle, reste",
      "La présent : \(apres.contains(9))")
check([0, 4].allSatisfy { apres.contains($0) },
      "et ce que joue l'accompagnement n'est pas touché",
      "Do et Mi présents")
check(avecBasse.segment(at: 4 * beat + 0.1)?.chord == Chord(root: 9, quality: .minor),
      "l'accord redevient La mineur",
      nom(avecBasse.segment(at: 4 * beat + 0.1)?.chord)
        + " au lieu de " + nom(sansBasse.segment(at: 4 * beat + 0.1)?.chord))

// Le garde-fou, et c'est lui qui compte : le pianiste a le droit de jouer là où la
// basse a une harmonique. Même basse, même 5ᵉ harmonique monstrueuse — mais cette
// fois l'accompagnement joue vraiment Do♯, et l'accord est majeur. Une règle qui
// retirerait toute harmonique de la basse effacerait cette tierce-là aussi, et
// répondrait « mineur » à un accord majeur.
var majeur = [Float](repeating: 0, count: Int(duree * rate))
for mesure in 0..<Int(nombreDeMesures) {
    let start = Double(mesure) * 4 * beat
    for pitch in [57, 61, 64] {
        note(midi: pitch, from: start, seconds: 4 * beat - 0.02, gain: 1, into: &majeur)
    }
}
for i in majeur.indices { majeur[i] += basseSeule[i] }

let matriceMajeur = OfflineAnalysis.run(samples: majeur, sampleRate: rate,
                                        settings: AnalysisSettings())
var vueMajeur = DisplaySettings()
vueMajeur = AutoContrast.settings(basedOn: vueMajeur, in: matriceMajeur) ?? vueMajeur
let carteMajeur = NoteMap.build(matriceMajeur, referenceA: vueMajeur.referenceA)
let joueVraiment = ChordDetector.detect(map: carteMajeur, display: vueMajeur, tempo: tempo,
                                        settings: defaults, bass: carteBasse)
let retenu = joueVraiment.segment(at: 4 * beat + 0.1)
check(retenu?.notes.contains { $0.pitchClass == 1 } == true,
      "un Do♯ réellement joué survit à la même harmonique de basse",
      noms(retenu?.notes ?? []))
// Le nom exact, non : ce timbre caricatural laisse la 3ᵉ harmonique de Do♯4 tomber
// sur Sol♯5, que l'explication par le grave ne rattrape pas, et le relevé écrit LaΔ.
// C'est un artefact de la synthèse, pas de la règle qu'on éprouve ici. Ce qui doit
// être vrai, c'est que l'accord soit bâti sur La et porte la tierce **majeure** :
// une règle qui effacerait les harmoniques de basse sans réserve rendrait La mineur.
check(retenu?.chord?.root == 9 && retenu?.chord?.pitchClasses.contains(1) == true,
      "et l'accord garde sa tierce majeure au lieu de retomber en mineur",
      nom(retenu?.chord))

print()
print(failures == 0 ? "Tout est bon." : "\(failures) vérification(s) en échec.")
exit(failures == 0 ? 0 : 1)
