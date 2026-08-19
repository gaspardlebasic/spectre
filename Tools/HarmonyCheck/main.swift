import Foundation
import SpectreCore

// Vérifie le relevé des accords sur une grille fabriquée : on sait ce qui est joué,
// donc on sait ce qui doit être lu. Les pièges sont choisis, pas trouvés au hasard —
// ce sont ceux sur lesquels un détecteur d'accords se casse toujours :
//
//   - majeur contre mineur sur un timbre riche, parce que la tierce majeure est déjà
//     dans les harmoniques de la fondamentale ;
//   - un renversement, parce que la note la plus grave n'est pas la fondamentale ;
//   - une pédale de basse sous un accord qui change ;
//   - Do majeur contre La mineur, qui partagent deux notes sur trois.

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
/// Le timbre est volontairement riche : une sinusoïde pure rendrait la tâche
/// facile et ne prouverait rien. Six harmoniques décroissantes, c'est à peu près un
/// piano ou une guitare — et c'est ce qui met la tierce majeure fantôme dans le
/// chromagramme.
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
}

func render(_ bars: [Bar]) -> (bass: [Float], harmony: [Float]) {
    let seconds = Double(bars.count) * 4 * beat + 1
    var bass = [Float](repeating: 0, count: Int(seconds * rate))
    var harmony = [Float](repeating: 0, count: Int(seconds * rate))
    for (index, bar) in bars.enumerated() {
        let start = Double(index) * 4 * beat
        for pitch in bar.pitches {
            note(midi: pitch, from: start, seconds: 4 * beat - 0.02, gain: 1, into: &harmony)
        }
        // La basse rejoue à chaque temps : c'est ce que fait une basse.
        for b in 0..<4 {
            note(midi: bar.bass, from: start + Double(b) * beat,
                 seconds: beat - 0.03, gain: 1.4, into: &bass)
        }
    }
    return (bass, harmony)
}

let tempo = TempoGrid(bpm: bpm, origin: 0, beatsPerBar: 4, confidence: 10)

/// Ce que le relevé donne pour chaque mesure, au temps le plus central.
func read(_ bars: [Bar]) -> [Chord?] {
    let (bass, harmony) = render(bars)
    let track = ChordDetector.detect(bass: bass, harmony: harmony,
                                     sampleRate: rate, tempo: tempo)
    return bars.indices.map { index in
        // Le troisième temps : loin des deux coutures.
        let t = Double(index) * 4 * beat + 2.5 * beat
        return track.segment(at: t)?.chord
    }
}

func nom(_ c: Chord?) -> String { c?.label() ?? "—" }

// MARK: - L'écriture des noms

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
check(Chord(root: 11, quality: .diminished).label() == "Si°", "le diminué",
      Chord(root: 11, quality: .diminished).label())
check(Chord(root: 10, quality: .major).label() == "Si♭", "les bémols par défaut",
      Chord(root: 10, quality: .major).label())
check(Chord.vocabulary.count == 108, "douze fondamentales et neuf couleurs",
      "\(Chord.vocabulary.count) accords")

// MARK: - Les gabarits

print()
print("=== Gabarits harmoniques ===")
let doSeul = ChordDetector.noteTemplate(0)
check(doSeul[0] > doSeul[7] && doSeul[7] > doSeul[4] && doSeul[4] > 0,
      "une note seule porte déjà sa quinte puis sa tierce majeure",
      String(format: "Do %.2f, Sol %.2f, Mi %.2f", doSeul[0], doSeul[7], doSeul[4]))
check(doSeul[1] == 0 && doSeul[6] == 0,
      "et rien sur les degrés qu'aucune harmonique n'atteint")
// C'est la propriété qui fait tout marcher : le gabarit de Do mineur contient un Mi
// fantôme, donc la présence d'un Mi dans le signal ne suffit plus à conclure majeur.
let doMineur = ChordDetector.template(Chord(root: 0, quality: .minor))
let doMajeur = ChordDetector.template(Chord(root: 0, quality: .major))
check(doMineur[4] > 0, "le gabarit mineur contient la tierce majeure fantôme",
      String(format: "%.3f", doMineur[4]))
check(doMajeur[4] > doMineur[4] * 3, "mais bien moins que le majeur ne la porte",
      String(format: "%.3f contre %.3f", doMajeur[4], doMineur[4]))
check(ChordDetector.cosine(doMajeur, doMineur) < 0.95,
      "les deux gabarits restent distincts",
      String(format: "cosinus %.3f", ChordDetector.cosine(doMajeur, doMineur)))

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
let lus = read(grille)
for (bar, chord) in zip(grille, lus) {
    check(chord?.root == bar.expected.root,
          "la fondamentale de \(bar.expected.label()) est trouvée", "lu \(nom(chord))")
}
check(zip(grille, lus).allSatisfy { $0.expected == $1 },
      "les quatre accords sont nommés exactement",
      lus.map(nom).joined(separator: " "))

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
for (bar, chord) in zip(couleurs, teintes) {
    check(chord == bar.expected, "\(bar.expected.label()) sur un timbre à six harmoniques",
          "lu \(nom(chord))")
}

// MARK: - Renversement et pédale

print()
print("=== Ce que la basse tranche ===")
// Do majeur premier renversement : la basse joue Mi. Sans la piste de basse on
// hésiterait ; avec elle, il faut justement ne PAS conclure Mi mineur — les notes
// jouées sont celles de Do, et Mi- demanderait un Sol♯.
let renverse: [Bar] = [
    Bar(pitches: [64, 67, 72], bass: 40, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
]
let renverses = read(renverse)
check(renverses[0]?.root == 0,
      "un renversement reste l'accord de sa fondamentale, pas de sa basse",
      "lu \(nom(renverses[0]))")

// Pédale : la basse reste sur Do pendant que l'accompagnement change. La basse ne
// doit pas imposer sa note à un accord qui ne la contient pas.
let pedale: [Bar] = [
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [65, 69, 72], bass: 36, expected: Chord(root: 5, quality: .major)),
]
let pedales = read(pedale)
check(pedales[0]?.root == 0, "sous la pédale, le premier accord est le sien",
      "lu \(nom(pedales[0]))")
check(pedales[1]?.pitchClasses.contains(5) == true,
      "et le second contient toujours ce qui est joué au-dessus",
      "lu \(nom(pedales[1]))")

// MARK: - Septièmes

print()
print("=== Septièmes ===")
let septiemes: [Bar] = [
    Bar(pitches: [62, 65, 69, 72], bass: 38, expected: Chord(root: 2, quality: .minor7)),
    Bar(pitches: [55, 59, 62, 65], bass: 31, expected: Chord(root: 7, quality: .dominant7)),
    Bar(pitches: [60, 64, 67, 71], bass: 36, expected: Chord(root: 0, quality: .major7)),
    Bar(pitches: [60, 64, 67, 71], bass: 36, expected: Chord(root: 0, quality: .major7)),
]
let lues = read(septiemes)
for (bar, chord) in zip(septiemes, lues) {
    check(chord?.root == bar.expected.root,
          "la fondamentale de \(bar.expected.label())", "lu \(nom(chord))")
}
check(zip(septiemes, lues).filter { $0.expected == $1 }.count >= 3,
      "au moins trois des quatre septièmes sont nommées entièrement",
      lues.map(nom).joined(separator: " "))
// Et l'inverse : une triade ne doit pas s'écrire en septième.
let triades: [Bar] = Array(repeating:
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)), count: 4)
check(read(triades).allSatisfy { $0?.quality == .major },
      "une triade tenue quatre mesures ne devient pas une septième",
      read(triades).map(nom).joined(separator: " "))

// MARK: - Les notes qu'on entoure

print()
print("=== Fondamentales, pas harmoniques ===")

// Un spectre fabriqué, ligne à ligne, sur le vrai découpage du banc : 36 lignes par
// octave. On y pose des notes avec leurs harmoniques et l'on demande lesquelles ont
// été jouées. C'est le seul moyen de savoir si la règle marche — sur un vrai morceau,
// on ne sait pas ce qui a été joué, c'est précisément la question.
let plan = BinLayout(binCount: 343, minFrequency: 25, maxFrequency: 18000,
                     binsPerOctave: 36, sampleRate: 44100)

/// Pose une note et ses harmoniques dans un spectre en dB.
func pose(_ midi: Int, at level: Float, harmonics: Int = 6, into spectre: inout [Float]) {
    for h in 1...harmonics {
        let f = Pitch.frequency(ofMidi: Double(midi)) * Double(h)
        guard f > plan.minFrequency, f < plan.maxFrequency else { continue }
        let centre = Int(plan.bin(of: f).rounded())
        // Une raie occupe trois lignes, comme dans le vrai banc.
        for d in -1...1 where centre + d >= 0 && centre + d < spectre.count {
            // Décroissance de 8 dB par rang : un timbre ordinaire.
            let value = level - 8 * Float(h - 1) - Float(abs(d)) * 3
            spectre[centre + d] = max(spectre[centre + d], value)
        }
    }
}

func noms(_ notes: [SoundingNote]) -> String {
    notes.map { $0.name() }.joined(separator: " ")
}

// Une seule note, richement harmonique. Do3 = 48. Ses harmoniques tombent sur Do4
// (2ᵉ), Sol4 (3ᵉ), Do5 (4ᵉ), Mi5 (5ᵉ) — donc sur les trois notes de Do majeur.
// C'est le pire cas, et celui qu'on rencontre tout le temps.
var seule = [Float](repeating: -120, count: plan.binCount)
pose(48, at: -20, into: &seule)
let seulement = ChordVoicing.sounding(Chord(root: 0, quality: .major), in: seule, layout: plan)
check(seulement.count == 1, "une note seule ne donne qu'une note, pas sa série",
      noms(seulement).isEmpty ? "aucune" : noms(seulement))
check(seulement.first?.midi == 48, "et c'est bien la fondamentale", noms(seulement))
check(seulement.first?.isRoot == true, "reconnue comme fondamentale de l'accord")

// Trois notes réellement jouées : Do3, Mi3, Sol3. Chacune traîne ses harmoniques,
// qui retombent sur les mêmes classes — il faut les trois, et rien de plus.
var triade = [Float](repeating: -120, count: plan.binCount)
pose(48, at: -20, into: &triade)
pose(52, at: -22, into: &triade)
pose(55, at: -24, into: &triade)
let troisNotes = ChordVoicing.sounding(Chord(root: 0, quality: .major), in: triade, layout: plan)
check(troisNotes.map(\.midi) == [48, 52, 55], "une triade jouée donne ses trois notes",
      noms(troisNotes))

// Le cas inverse, celui que la règle doit épargner : un doublement à l'octave. Do4
// est joué *plus fort* que ne le voudrait la seule harmonique de Do3, donc quelqu'un
// joue là.
var doublee = [Float](repeating: -120, count: plan.binCount)
pose(48, at: -30, into: &doublee)
pose(60, at: -18, into: &doublee)
let deux = ChordVoicing.sounding(Chord(root: 0, quality: .major), in: doublee, layout: plan)
check(deux.map(\.midi).contains(60) && deux.map(\.midi).contains(48),
      "une octave jouée plus fort que l'harmonique se voit", noms(deux))

// Une note étrangère à l'accord n'est pas montrée, même forte.
var etrangere = [Float](repeating: -120, count: plan.binCount)
pose(49, at: -18, harmonics: 1, into: &etrangere)   // Do♯3
let hors = ChordVoicing.sounding(Chord(root: 0, quality: .major), in: etrangere, layout: plan)
check(hors.isEmpty, "ce qui n'appartient pas à l'accord n'est pas entouré",
      noms(hors).isEmpty ? "rien" : noms(hors))

// Le noir de l'image fait plancher. Le défaut, trouvé à l'usage : une raie très en
// dessous de ce que l'écran montre était entourée et nommée à un endroit
// parfaitement noir — et, pire, elle expliquait ensuite comme sa propre harmonique la
// vraie note deux octaves plus haut, qui disparaissait du même coup.
//
// Les niveaux sont ceux qu'il faut pour que le **plancher visible soit le seul** à
// trancher : le fantôme est à 27 dB sous la note la plus forte, donc dans la plage
// dynamique, mais 17 dB sous le noir de l'écran. Sans cette précaution le contrôle
// serait creux — l'écart relatif suffirait à l'écarter et l'on ne vérifierait rien.
var fantome = [Float](repeating: -120, count: plan.binCount)
pose(30, at: -68, harmonics: 1, into: &fantome)   // Sol♭1, invisible à l'écran
pose(54, at: -41, harmonics: 4, into: &fantome)   // Sol♭3, la vraie note
let sansPlancher = ChordVoicing.sounding(Chord(root: 6, quality: .major),
                                         in: fantome, layout: plan)
let avecPlancher = ChordVoicing.sounding(Chord(root: 6, quality: .major),
                                         in: fantome, layout: plan, visibleFloor: -51)
check(avecPlancher.allSatisfy { $0.level > -51 },
      "rien n'est entouré sous le noir de l'image", noms(avecPlancher))
check(avecPlancher.map(\.midi).contains(54),
      "et la vraie note, elle, reste entourée", noms(avecPlancher))
check(sansPlancher.count >= avecPlancher.count,
      "sans plancher, il y en aurait davantage — c'était le défaut",
      "\(noms(sansPlancher)) contre \(noms(avecPlancher))")

// Le silence ne produit rien.
let vide2 = [Float](repeating: -120, count: plan.binCount)
check(ChordVoicing.sounding(Chord(root: 0, quality: .major), in: vide2, layout: plan).isEmpty,
      "un spectre plat ne donne aucune note")
check(ChordVoicing.sounding(Chord(root: 0, quality: .major), in: [], layout: plan).isEmpty,
      "et un spectre absent non plus")

// Les noms sont ceux du reste de l'application, octave comprise.
check(SoundingNote(midi: 60, level: 0, isRoot: true).name() == "Do4",
      "les notes sont nommées comme partout ailleurs",
      SoundingNote(midi: 60, level: 0, isRoot: true).name())
check(SoundingNote(midi: 58, level: 0, isRoot: false).name() == "Si♭3",
      "bémols compris", SoundingNote(midi: 58, level: 0, isRoot: false).name())

// MARK: - Ponctualité

print()
print("=== Ponctualité ===")
// Les fenêtres sont longues — 186 ms pour l'accompagnement, 372 pour la basse — et
// centrées sur leur trame. Une trame posée juste avant un changement voit donc déjà
// un peu de l'accord suivant. La question est de savoir si ça suffit à faire basculer
// le temps d'avant : un accord annoncé un temps trop tôt est pire qu'inutile, on
// pose les doigts au mauvais moment.
let ponctuel: [Bar] = [
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [60, 64, 67], bass: 36, expected: Chord(root: 0, quality: .major)),
    Bar(pitches: [53, 57, 60], bass: 29, expected: Chord(root: 5, quality: .major)),
    Bar(pitches: [53, 57, 60], bass: 29, expected: Chord(root: 5, quality: .major)),
]
let (bassePonctuelle, harmoniePonctuelle) = render(ponctuel)
let pistePonctuelle = ChordDetector.detect(bass: bassePonctuelle,
                                           harmony: harmoniePonctuelle,
                                           sampleRate: rate, tempo: tempo)
// Le changement tombe au début de la troisième mesure, soit le temps 8.
let changement = 8 * beat
let avant = pistePonctuelle.segment(at: changement - beat / 2)?.chord
let apres = pistePonctuelle.segment(at: changement + beat / 2)?.chord
check(avant?.root == 0, "le dernier temps avant le changement porte encore l'ancien accord",
      "lu \(nom(avant))")
check(apres?.root == 5, "le premier temps après porte le nouveau", "lu \(nom(apres))")
// Et l'instant exact du basculement, mesuré : le premier temps qui porte Fa.
let premierFa = pistePonctuelle.segments.first { $0.chord?.root == 5 }
check(premierFa.map { abs($0.start - changement) < 1e-6 } ?? false,
      "le basculement tombe pile sur le temps du changement",
      premierFa.map { String(format: "%.3f s au lieu de %.3f", $0.start, changement) } ?? "jamais")

// MARK: - Silence

print()
print("=== Silence ===")
let vide = [Float](repeating: 0, count: Int(rate * 4))
let rien = ChordDetector.detect(bass: vide, harmony: vide, sampleRate: rate, tempo: tempo)
check(!rien.segments.isEmpty, "le silence produit quand même des segments",
      "\(rien.segments.count)")
check(rien.segments.allSatisfy { $0.chord == nil }, "mais aucun n'est nommé")
let sansGrille = ChordDetector.detect(bass: vide, harmony: vide, sampleRate: rate,
                                      tempo: TempoGrid(bpm: 0, origin: 0))
check(sansGrille.isEmpty, "sans grille métrique, aucun relevé — il n'y aurait où l'écrire")

// MARK: - Regroupement à l'affichage

print()
print("=== Regroupement ===")
let track = ChordTrack(segments: (0..<16).map { k in
    ChordSegment(start: Double(k) * beat, end: Double(k + 1) * beat,
                 chord: Chord(root: k < 8 ? 0 : 5, quality: .major), confidence: 1)
})
let parTemps = track.labels(from: 0, to: 8, grouping: 1)
let parMesure = track.labels(from: 0, to: 8, grouping: 4)
check(parTemps.count == 2, "seize temps sur deux accords donnent deux étiquettes",
      "\(parTemps.count)")
check(parMesure.count == 2, "et par mesure aussi : un accord tenu ne se réécrit pas",
      "\(parMesure.count)")
check(parMesure[0].chord?.root == 0 && parMesure[1].chord?.root == 5,
      "dans l'ordre, avec les bons accords",
      parMesure.map { nom($0.chord) }.joined(separator: " "))
// Les huit premiers temps portent Do : l'étiquette couvre les deux mesures d'un
// coup, et s'arrête là où Fa commence — pas au bout de la première mesure.
check(abs(parMesure[0].end - 8 * beat) < 1e-9,
      "et la première étiquette s'étend jusqu'au changement, pas jusqu'à la barre",
      String(format: "finit à %.2f s", parMesure[0].end))
// MARK: L'alignement sur les barres de mesure
//
// Le piège, et il a coûté cher : une grille dont le premier temps fort ne tombe pas
// à zéro. Les temps relevés commencent alors avant lui, et regrouper « tous les
// quatre temps depuis le début du fichier » place les noms à côté des barres — en
// avance d'exactement ce qui sépare les deux. À l'écran l'accord change une mesure
// trop tôt, ce qui s'entend avant de se voir.
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
// Chaque étiquette, sauf éventuellement la première (une levée), doit commencer sur
// un temps fort.
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
// Sans décalage, rien ne change : la levée est vide et tous les groupes font quatre.
let droite = ChordTrack(segments: (0..<16).map { k in
    ChordSegment(start: Double(k) * beat, end: Double(k + 1) * beat,
                 chord: Chord(root: k / 4, quality: .major), confidence: 1)
}, firstBeat: 0)
check(droite.labels(from: 0, to: 8, grouping: 4).count == 4,
      "une grille à l'origine donne quatre mesures pleines",
      "\(droite.labels(from: 0, to: 8, grouping: 4).count)")

// Le nom d'un groupe est le plus long, pas le premier : une anacrouse ne nomme pas
// la mesure.
let anacrouse = ChordTrack(segments: (0..<4).map { k in
    ChordSegment(start: Double(k) * beat, end: Double(k + 1) * beat,
                 chord: Chord(root: k == 0 ? 7 : 0, quality: .major), confidence: 1)
})
check(anacrouse.labels(from: 0, to: 2, grouping: 4).first?.chord?.root == 0,
      "un temps isolé ne donne pas son nom à la mesure",
      nom(anacrouse.labels(from: 0, to: 2, grouping: 4).first?.chord))

print()
print(failures == 0 ? "Tout est bon." : "\(failures) vérification(s) en échec.")
exit(failures == 0 ? 0 : 1)
