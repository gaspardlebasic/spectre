import AVFoundation
import Foundation
import SpectreCore
import SpectreMac

// Vérifie l'ossature de la séparation sans modèle et sans interface : le rangement,
// l'écriture des pistes, leur relecture, l'annulation, et le fait qu'un échec ne
// laisse pas derrière lui un jeu de pistes incomplet — que l'application prendrait
// ensuite pour un travail fait.

var failures = 0

func check(_ passed: Bool, _ what: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}

/// Moteur d'essai : sépare grossièrement par bandes. Il ne s'agit pas d'imiter
/// Demucs — seulement de produire quatre signaux distincts qui se rangent, se
/// relisent et se resomment, ce qui est tout ce que l'ossature doit garantir.
struct BandSeparator: StemSeparator {
    var steps = 8
    var failAt: Int?

    func separate(fileAt url: URL,
                  progress: @escaping (SeparationProgress) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> SeparatedStems {
        let source = try loadChannels(from: url)
        let input = source.channels[0]
        let n = input.count

        var low = [Float](repeating: 0, count: n)
        var state: Float = 0
        for i in 0..<n {
            state += 0.02 * (input[i] - state)
            low[i] = state
        }
        let high = zip(input, low).map(-)

        var result: [Stem: [[Float]]] = [:]
        for (k, stem) in Stem.separated.enumerated() {
            for s in 0..<steps {
                if isCancelled() { throw SeparationFailure.cancelled }
                if let failAt, k * steps + s == failAt {
                    throw SeparationFailure.engine("panne simulée")
                }
                progress(SeparationProgress(
                    fraction: Double(k * steps + s) / Double(steps * Stem.separated.count),
                    stage: "Séparation d'essai…"))
                usleep(2000)
            }
            result[stem] = [stem == .bass ? low : high]
        }
        // Ce moteur-ci ne rééchantillonne rien : il rend ce qu'il a lu, à la
        // fréquence où il l'a lu. C'est justement ce que Demucs *ne* fait pas.
        return SeparatedStems(sampleRate: source.sampleRate, channels: result)
    }
}

// MARK: - Terrain d'essai

let rate = 44100.0
let seconds = 1.0
let frames = Int(rate * seconds)
let signal = (0..<frames).map { i -> Float in
    let t = Double(i) / rate
    return Float(0.4 * sin(2 * .pi * 80 * t) + 0.3 * sin(2 * .pi * 3000 * t))
}

let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("separationcheck-\(getpid())", isDirectory: true)
try! FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
let sourceFile = sandbox.appendingPathComponent("essai.caf")
try! StemStore.write([signal], sampleRate: rate, to: sourceFile)

let fingerprint = "verification-\(getpid())"
/// Tout ce que cette vérification laisse sur le disque, à effacer avant de sortir.
///
/// **Et non un `defer`** : le script se termine par `exit`, qui ne les exécute pas.
/// Les jeux de pistes d'essai s'accumulaient donc dans Application Support, un par
/// exécution — ce qui ne se voit qu'en allant les compter.
var aEffacer: [String] = [fingerprint]

func menageFinal() {
    aEffacer.forEach(StemStore.removeStems)
    try? FileManager.default.removeItem(at: sandbox)
}

// MARK: - L'ordre des pistes

print("=== Pistes ===")
check(Stem.separated == [.drums, .bass, .other, .vocals],
      "l'ordre des pistes est celui du modèle",
      Stem.separated.map(\.rawValue).joined(separator: ", "))
check(Stem.allCases.count == 5, "cinq voies dans le sélecteur")
check(StemStore.folder(for: fingerprint)?.lastPathComponent == StemStore.modelName,
      "les pistes portent le nom du modèle qui les a produites",
      StemStore.folder(for: fingerprint)?.lastPathComponent ?? "—")
check(Stem.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.label.isEmpty },
      "chaque voie a un intitulé et un symbole")
check(StemStore.url(.mix, for: fingerprint) == nil,
      "le mixage n'est pas une piste à ranger")
check(Stem.label(for: Set(Stem.separated)) == "Mixage",
      "tout garder, c'est le mixage", Stem.label(for: Set(Stem.separated)))
check(Stem.label(for: [.drums, .bass, .other]) == "sans Voix",
      "retirer une piste se dit par soustraction", Stem.label(for: [.drums, .bass, .other]))
check(Stem.label(for: [.bass, .drums]) == "Batterie + Basse",
      "en garder peu se dit par énumération", Stem.label(for: [.bass, .drums]))

// MARK: - Écriture et relecture

print()
print("=== Rangement ===")
let readBack = try! AudioSource.load(sourceFile)
check(abs(readBack.frameCount - frames) <= 1, "la relecture retrouve la longueur",
      "\(readBack.frameCount) contre \(frames)")
let worst = zip(readBack.mono, signal).map { abs($0 - $1) }.max() ?? 1
check(worst < 1e-6, "l'écriture ne dégrade rien", String(format: "écart maximal %.1e", worst))

// MARK: - Le format compressé

print()
print("=== FLAC et réserve de niveau ===")
// FLAC est un format entier : ce qui dépasse ±1,0 y serait écrêté, et une piste
// séparée dépasse. La réserve doit rendre l'aller-retour exact quand même, et le
// dépassement de la réserve ne doit jamais écrêter en silence.
let compresse = sandbox.appendingPathComponent("essai.flac")
let ecrit = try! StemStore.write([signal], sampleRate: rate, to: compresse)
check(ecrit.pathExtension == "flac", "un nom en .flac donne bien un FLAC", ecrit.lastPathComponent)
let tailleFlac = (try! FileManager.default.attributesOfItem(atPath: ecrit.path)[.size] as! Int)
let tailleCaf = (try! FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as! Int)
check(tailleFlac < tailleCaf, "il occupe moins de place que le CAF flottant",
      String(format: "%.1f Mo contre %.1f", Double(tailleFlac) / 1e6, Double(tailleCaf) / 1e6))
let relu = try! StemStore.readChannels(from: ecrit)
let ecart = zip(relu.channels[0], signal).map { abs($0 - $1) }.max() ?? 1
check(ecart < 1e-5, "l'aller-retour rend le signal, réserve comprise",
      String(format: "écart maximal %.1e", ecart))
check(StemStore.gain(for: ecrit) == 1,
      "hors du dossier des pistes, aucun gain n'est appliqué — un FLAC de la discothèque n'est pas des nôtres")

// Une crête au-delà de la réserve : on refuse de compresser plutôt que d'écrêter.
let enorme = signal.map { $0 * 8 }
let refuge = sandbox.appendingPathComponent("enorme.flac")
let ecritEnorme = try! StemStore.write([enorme], sampleRate: rate, to: refuge)
check(ecritEnorme.pathExtension == "caf",
      "ce qui déborde la réserve retombe sur le CAF flottant", ecritEnorme.lastPathComponent)
let reluEnorme = try! StemStore.readChannels(from: ecritEnorme)
let ecartEnorme = zip(reluEnorme.channels[0], enorme).map { abs($0 - $1) }.max() ?? 1
check(ecartEnorme < 1e-6, "et reste exact au lieu d'être écrêté",
      String(format: "écart maximal %.1e", ecartEnorme))

// MARK: - Le travail complet

print()
print("=== Séparation ===")
var seen: [Double] = []
var done = false
let job = SeparationJob()
job.run(fileAt: sourceFile, fingerprint: fingerprint, separator: BandSeparator(),
        progress: { seen.append($0.fraction) },
        completion: { result in
            check((try? result.get()) != nil, "la séparation aboutit")
            done = true
        })
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

check(StemStore.isSeparated(fingerprint), "les quatre pistes sont sur le disque")
check(seen.count > 4 && seen == seen.sorted(), "l'avancement progresse sans reculer",
      "\(seen.count) relevés")
check(seen.allSatisfy { $0 >= 0 && $0 <= 1 }, "l'avancement reste entre 0 et 1")

if let bass = StemStore.url(.bass, for: fingerprint),
   let loaded = try? AudioSource.load(bass) {
    // La piste rangée doit être relisible telle quelle par le reste de
    // l'application : c'est `AudioSource.load` qui alimente l'analyse.
    check(abs(loaded.frameCount - frames) <= 1, "une piste se relit comme un morceau",
          "\(loaded.frameCount) contre \(frames)")
    check(loaded.sampleRate == rate, "la fréquence d'échantillonnage est conservée")
} else {
    check(false, "une piste se relit comme un morceau", "illisible")
}

// MARK: - Combinaisons

print()
print("=== Combinaisons ===")
if let melange = try? StemStore.combined([.bass, .drums], for: fingerprint),
   let somme = try? StemStore.readChannels(from: melange),
   let basse = StemStore.url(.bass, for: fingerprint),
   let batterie = StemStore.url(.drums, for: fingerprint),
   let a = try? StemStore.readChannels(from: basse),
   let b = try? StemStore.readChannels(from: batterie) {
    let attendu = zip(a.channels[0], b.channels[0]).map(+)
    let ecart = zip(somme.channels[0], attendu).map { abs($0 - $1) }.max() ?? 1
    check(ecart < 1e-6, "deux pistes ensemble donnent leur somme",
          String(format: "écart maximal %.1e", ecart))
    check(melange.lastPathComponent == "bass+drums.flac",
          "le nom de la combinaison est trié", melange.lastPathComponent)
    // Deuxième appel : le fichier existe déjà et doit être rendu tel quel.
    let encore = try? StemStore.combined([.drums, .bass], for: fingerprint)
    check(encore == melange, "l'ordre des clics ne fabrique pas deux fichiers")
} else {
    check(false, "deux pistes ensemble donnent leur somme", "combinaison impossible")
}
if let seule = try? StemStore.combined([.vocals], for: fingerprint) {
    check(seule.lastPathComponent == "vocals.flac",
          "une piste seule n'est pas recopiée", seule.lastPathComponent)
}
check((try? StemStore.combined([], for: fingerprint)) ?? nil == nil,
      "une sélection vide ne désigne aucun fichier")

// MARK: - Annulation

print()
print("=== Annulation ===")
StemStore.removeStems(for: fingerprint)
let cancellable = SeparationJob()
var cancelledOutcome: Error?
done = false
cancellable.run(fileAt: sourceFile, fingerprint: fingerprint,
                separator: BandSeparator(steps: 400),
                progress: { _ in },
                completion: { result in
                    if case .failure(let error) = result { cancelledOutcome = error }
                    done = true
                })
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
cancellable.cancel()
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(cancelledOutcome != nil, "l'annulation interrompt le calcul")
check(!StemStore.isSeparated(fingerprint), "elle ne laisse aucune piste derrière elle")

// MARK: - Échec en cours de route

print()
print("=== Panne ===")
StemStore.removeStems(for: fingerprint)
done = false
SeparationJob().run(fileAt: sourceFile, fingerprint: fingerprint,
                    separator: BandSeparator(failAt: 20),
                    progress: { _ in },
                    completion: { result in
                        if case .success = result { check(false, "une panne doit échouer") }
                        done = true
                    })
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(!StemStore.isSeparated(fingerprint),
      "une panne ne laisse pas un jeu de pistes incomplet")

// MARK: - Le plafond du cache

print()
print("=== Ménage du cache ===")
// Trois morceaux d'essai, écrits à des dates différentes. Le ménage doit emporter le
// plus ancien et jamais celui qu'on écoute.
let cobayes = (0..<3).map { "menage-\(getpid())-\($0)" }
for (k, nom) in cobayes.enumerated() {
    for stem in Stem.separated {
        guard let url = StemStore.url(stem, for: nom) else { continue }
        try? StemStore.write([signal], sampleRate: rate, to: url)
    }
    // Le plus petit indice est le plus ancien.
    if let dossier = StemStore.folder(for: nom)?.deletingLastPathComponent() {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(Double(k) * 60 - 10_000)],
            ofItemAtPath: dossier.path)
    }
}
aEffacer.append(contentsOf: cobayes)
check(cobayes.allSatisfy(StemStore.isSeparated), "les trois jeux d'essai sont en place")
// Un plafond nul force le ménage sans dépendre de ce qui traîne sur la machine.
let libere = StemStore.pruneCache(keeping: cobayes.last, limit: 0)
check(libere > 0, "le ménage libère de la place", "\(libere / 1024) Kio")
check(StemStore.isSeparated(cobayes[2]),
      "le morceau qu'on écoute survit au ménage")
check(!StemStore.isSeparated(cobayes[0]),
      "le plus anciennement ouvert est parti le premier")

// MARK: - La fréquence des pistes rendues

print()
print("=== Fréquence des pistes ===")

/// Un moteur qui **rééchantillonne**, comme le fait Demucs — qui ramène tout à
/// 44,1 kHz quel que soit ce qu'on lui donne.
///
/// C'est le cas que l'ossature ratait : elle écrivait les pistes en leur collant la
/// fréquence du *fichier d'entrée*, pas celle à laquelle le moteur avait travaillé.
/// Sur un morceau à 48 kHz, les pistes sortaient à 44,1 kHz étiquetées 48 kHz —
/// jouées 8,8 % trop vite et un demi-ton et demi trop haut. Invisible tant qu'on
/// n'éprouve l'ossature qu'avec des fichiers à 44,1 kHz et un moteur qui ne
/// rééchantillonne pas.
struct ResamplingSeparator: StemSeparator {
    let outputRate: Double

    func separate(fileAt url: URL,
                  progress: @escaping (SeparationProgress) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> SeparatedStems {
        let source = try loadChannels(from: url)
        let ratio = outputRate / source.sampleRate
        let count = Int(Double(source.channels[0].count) * ratio)
        // Un rééchantillonnage au plus simple : on n'éprouve pas sa qualité, on
        // éprouve que sa fréquence est dite et respectée.
        let resampled = (0..<count).map { i -> Float in
            source.channels[0][min(Int(Double(i) / ratio), source.channels[0].count - 1)]
        }
        var result: [Stem: [[Float]]] = [:]
        for stem in Stem.separated { result[stem] = [resampled] }
        return SeparatedStems(sampleRate: outputRate, channels: result)
    }
}

// Le terrain d'essai est à 48 kHz — c'est tout le sujet.
let rate48 = 48000.0
let source48 = sandbox.appendingPathComponent("quarante-huit.caf")
let signal48 = (0..<Int(rate48 * 2)).map { i -> Float in
    Float(0.4 * sin(2 * .pi * 440 * Double(i) / rate48))
}
try! StemStore.write([signal48], sampleRate: rate48, to: source48)

let empreinte48 = "verification-48-\(getpid())"
defer { StemStore.removeStems(for: empreinte48) }
done = false
SeparationJob().run(fileAt: source48, fingerprint: empreinte48,
                    separator: ResamplingSeparator(outputRate: 44100),
                    progress: { _ in },
                    completion: { _ in done = true })
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

if let piste = StemStore.url(.drums, for: empreinte48),
   let relue = try? StemStore.readChannels(from: piste) {
    check(abs(relue.sampleRate - 44100) < 1,
          "la piste porte la fréquence du moteur, pas celle du fichier",
          String(format: "%.0f Hz (le fichier d'entrée est à %.0f)", relue.sampleRate, rate48))
    // Le vrai symptôme : une durée qui a changé. C'est ce qu'on entend.
    let duree = Double(relue.channels[0].count) / relue.sampleRate
    check(abs(duree - 2.0) < 0.02, "et la piste dure aussi longtemps que le morceau",
          String(format: "%.3f s au lieu de 2,000", duree))
} else {
    check(false, "la piste se relit", "illisible")
}
// Et le garde-fou : un jeu de pistes à la mauvaise fréquence ne doit pas passer pour
// utilisable, sans quoi les fichiers déjà écrits de travers resserviraient toujours.
let empreinteFausse = "verification-fausse-\(getpid())"
defer { StemStore.removeStems(for: empreinteFausse) }
for stem in Stem.separated {
    if let url = StemStore.url(stem, for: empreinteFausse) {
        _ = try? StemStore.write([signal48], sampleRate: rate48, to: url)
    }
}
check(!StemStore.isSeparated(empreinteFausse),
      "des pistes à 48 kHz ne comptent pas comme calculées : elles seront refaites")

// MARK: - Les deux chemins du vrai moteur

// Tout ce qui précède éprouve l'ossature, avec un moteur d'essai. Ici c'est Demucs
// lui-même, sur ses deux routes : le GPU et les cœurs. Le calcul se fait en
// demi-précision d'un côté et en simple de l'autre, si bien qu'on n'attend pas
// l'égalité au bit près — on attend que l'écart reste inaudible. Une accélération
// dont on ne peut pas mesurer l'écart avec la route lente n'est qu'une promesse.
//
// Sauté quand le modèle n'est pas installé : c'est le cas sur la machine
// d'intégration, où ces centaines de mégaoctets n'ont pas leur place.
print()
print("=== Les deux chemins ===")
if !StemStore.hasModel {
    print("  · modèle absent, comparaison sautée")
} else {
    // Trois secondes suffisent : le réseau complète la tranche par du silence, et
    // c'est une tranche entière qui est calculée de toute façon.
    let essai = (0..<Int(rate * 3)).map { i -> Float in
        let t = Double(i) / rate
        let frappe = t.truncatingRemainder(dividingBy: 0.5) < 0.02 ? 1.0 : 0.0
        return Float(0.5 * frappe * sin(2 * .pi * 60 * t)
                     + 0.25 * sin(2 * .pi * 220 * t)
                     + 0.15 * sin(2 * .pi * 1500 * t))
    }
    let melange = sandbox.appendingPathComponent("deux-chemins.caf")
    try! StemStore.write([essai], sampleRate: rate, to: melange)

    func separe(accelerated: Bool) -> SeparatedStems? {
        try? DemucsSeparator(accelerated: accelerated)
            .separate(fileAt: melange, progress: { _ in }, isCancelled: { false })
    }
    if let rapide = separe(accelerated: true), let lent = separe(accelerated: false) {
        check(Set(rapide.channels.keys) == Set(Stem.separated),
              "les deux rendent les quatre pistes")
        // La fréquence rendue est celle du réseau, pas celle du fichier : c'est
        // l'invariant dont la violation faisait jouer les pistes 8,8 % trop vite.
        check(rapide.sampleRate == DemucsSeparator.sampleRate,
              "le moteur annonce la fréquence à laquelle il a travaillé",
              String(format: "%.0f Hz", rapide.sampleRate))
        var pire = 0.0, echelle = 0.0
        for stem in Stem.separated {
            guard let a = rapide.channels[stem]?.first,
                  let b = lent.channels[stem]?.first else { continue }
            echelle = max(echelle, Double(b.map(abs).max() ?? 0))
            pire = max(pire, Double(zip(a, b).map { abs($0 - $1) }.max() ?? 0))
        }
        // Un pour cent de l'amplitude, soit −40 dB. C'est très large devant ce qui
        // est mesuré — de l'ordre de −80 dB — et c'est fait exprès : ce contrôle est
        // là pour attraper une panne franche, pas pour figer un chiffre. La
        // demi-précision qui déborde, ou deux tranches qui se mêlent, donnent des
        // écarts cent fois plus grands.
        check(echelle > 0.01, "la route lente produit bien quelque chose",
              String(format: "crête %.3f", echelle))
        check(pire < 0.01 * echelle, "le GPU rend la même chose que les cœurs",
              String(format: "écart maximal %.5f, soit %.2f %% de l'échelle",
                     pire, 100 * pire / max(echelle, 1e-9)))
    } else {
        check(false, "les deux chemins aboutissent", "au moins un a échoué")
    }
}

menageFinal()

print()
print(failures == 0 ? "Tout est bon." : "\(failures) vérification(s) en échec.")
exit(failures == 0 ? 0 : 1)
