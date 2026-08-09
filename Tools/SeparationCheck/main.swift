import AVFoundation
import Foundation

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
                  progress: @escaping (Double) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> [Stem: [[Float]]] {
        let input = try loadChannels(from: url).channels[0]
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
                progress(Double(k * steps + s) / Double(steps * Stem.separated.count))
                usleep(2000)
            }
            result[stem] = [stem == .bass ? low : high]
        }
        return result
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
defer { StemStore.removeStems(for: fingerprint); try? FileManager.default.removeItem(at: sandbox) }

// MARK: - L'ordre des pistes

print("=== Pistes ===")
check(Stem.separated == [.drums, .bass, .other, .vocals],
      "l'ordre des pistes est celui du modèle",
      Stem.separated.map(\.rawValue).joined(separator: ", "))
check(Stem.allCases.count == 5, "cinq voies dans le sélecteur")
check(Stem.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.label.isEmpty },
      "chaque voie a un intitulé et un symbole")
check(StemStore.url(.mix, for: fingerprint) == nil,
      "le mixage n'est pas une piste à ranger")

// MARK: - Écriture et relecture

print()
print("=== Rangement ===")
let readBack = try! AudioSource.load(sourceFile)
check(abs(readBack.frameCount - frames) <= 1, "la relecture retrouve la longueur",
      "\(readBack.frameCount) contre \(frames)")
let worst = zip(readBack.mono, signal).map { abs($0 - $1) }.max() ?? 1
check(worst < 1e-6, "l'écriture ne dégrade rien", String(format: "écart maximal %.1e", worst))

// MARK: - Le travail complet

print()
print("=== Séparation ===")
var seen: [Double] = []
var done = false
let job = SeparationJob()
job.run(fileAt: sourceFile, fingerprint: fingerprint, separator: BandSeparator(),
        progress: { seen.append($0) },
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

print()
print(failures == 0 ? "Tout est bon." : "\(failures) vérification(s) en échec.")
exit(failures == 0 ? 0 : 1)
