import Foundation
import SpectreCore
import SpectreModele
import SpectreMac

// Chronomètre l'ouverture d'un morceau, étape par étape.
//
// Ce que la fenêtre montre pendant ce temps-là tient en trois lignes — « Lecture du
// fichier… », « Analyse… », « Séparation des pistes : 0 % » — et la dernière reste
// figée près d'une minute. Ce harnais dit où passent ces minutes, en parcourant
// exactement les mêmes appels que `AppModel.open` puis `AppModel.separate`, dans le
// même ordre. Rien n'est simulé.
//
// Il travaille dans un rangement à part (`SPECTRE_RANGEMENT`) : mesurer ne doit pas
// chasser du cache les pistes des vrais morceaux.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("Usage : Chrono morceau.mp3\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: arguments[1])
let ouvertureSeulement = arguments.contains("--ouverture")
let pistesSeulement = arguments.contains("--pistes")
guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write(Data("Fichier introuvable : \(url.path)\n".utf8))
    exit(1)
}

func maintenant() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

let départ = maintenant()
var lignes: [(String, Double, Double)] = []   // étape, durée, instant de fin

@discardableResult
func mesure<T>(_ quoi: String, _ bloc: () throws -> T) rethrows -> T {
    let t0 = maintenant()
    let valeur = try bloc()
    let t1 = maintenant()
    lignes.append((quoi, t1 - t0, t1 - départ))
    FileHandle.standardError.write(Data(
        String(format: "  %-52s %7.2f s\n", (quoi as NSString).utf8String!, t1 - t0).utf8))
    return valeur
}

func note(_ quoi: String, _ durée: Double) {
    lignes.append((quoi, durée, maintenant() - départ))
    FileHandle.standardError.write(Data(
        String(format: "  %-52s %7.2f s\n", (quoi as NSString).utf8String!, durée).utf8))
}

let réglages = AnalysisSettings(reassignment: true)

// ── Ce que fait `open` ───────────────────────────────────────────────────────

print("── Ouverture ──")
let source = try mesure("Décodage du fichier (« Lecture du fichier… »)") {
    try DecodeurApple().charger(url)
}
print(String(format: "   %.0f s de musique, %.0f Hz, empreinte %@",
             source.duration, source.sampleRate, source.fingerprint ?? "—"))

var premièreColonne: Double?
let t0Analyse = maintenant()
let mixage = mesure("Analyse du mixage (« Analyse… »)") {
    OfflineAnalysis.run(samples: source.mono, sampleRate: source.sampleRate,
                        settings: réglages) { _ in
        if premièreColonne == nil { premièreColonne = maintenant() - t0Analyse }
    }
}
if let premièreColonne {
    print(String(format: "   premier pourcentage affiché après %.2f s", premièreColonne))
}
print("   \(mixage.columnCount) colonnes, \(mixage.layout.binCount) lignes, "
      + String(format: "%.1f ms par colonne", mixage.secondsPerColumn * 1000))
mesure("Relevé du tempo") { _ = TempoEstimator.estimate(mixage) }
mesure("Contraste d'ouverture") { _ = AutoContrast.settings(basedOn: DisplaySettings(), in: mixage) }
mesure("Carte des notes du mixage (accords)") {
    _ = NoteMap.build(mixage, referenceA: 440, prominence: ChordSettings().prominence)
}
mesure("Relevé de batterie sur le mixage") {
    _ = PercussionDetector.detect(samples: source.mono, sampleRate: source.sampleRate)
}

// ── Ce que fait `separate` ───────────────────────────────────────────────────

if ouvertureSeulement { exit(0) }

// Le détail des deux moments muets, mesuré sur des pistes déjà calculées : lire un
// FLAC, en écrire un, et ce que coûte la somme par rapport à ses lectures.
if pistesSeulement {
    guard let empreinte = source.fingerprint else { exit(1) }
    print("── Pistes déjà là ──")
    for piste in Stem.separated {
        guard let fichier = StemStore.url(piste, for: empreinte),
              FileManager.default.fileExists(atPath: fichier.path) else { continue }
        let lues = try mesure("Lecture FLAC « \(piste.rawValue) »") {
            try StemStore.readChannels(from: fichier)
        }
        let ailleurs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chrono-\(piste.rawValue).flac")
        try? FileManager.default.removeItem(at: ailleurs)
        mesure("Écriture FLAC « \(piste.rawValue) »") {
            _ = try? StemStore.write(lues.channels, sampleRate: lues.sampleRate, to: ailleurs)
        }
        try? FileManager.default.removeItem(at: ailleurs)
    }
    let vues: Set<Stem> = Set(Stem.separated).subtracting([.drums])
    let montée = try mesure("Montée des quatre pistes en mémoire") {
        try StemStore.banque(pour: empreinte)
    }
    if let montée {
        print(String(format: "   %.0f Mo en mémoire", Double(montée.poids) / 1e6))
        mesure("Somme des trois pistes en mémoire (mono)") {
            _ = montée.melangeMono(vues)
        }
    }
    exit(0)
}

print("── Séparation ──")
guard let empreinte = source.fingerprint else { exit(1) }
let moteur = DemucsSeparator()

var étapes: [(String, Double)] = []           // libellé, instant
var tranches: [Double] = []                   // instants de fin de tranche
let t0Sép = maintenant()
var dernièreÉtape = ""

let pistes = try moteur.separate(fileAt: url, progress: { p in
    let t = maintenant() - t0Sép
    if p.stage != dernièreÉtape {
        étapes.append((p.stage, t))
        dernièreÉtape = p.stage
    }
    if p.fraction > 0 { tranches.append(t) }
}, isCancelled: { false })

// Les bornes viennent des rappels d'avancement : ce sont exactement les instants où
// la fenêtre change de message.
let finDécodage = étapes.count > 1 ? étapes[1].1 : 0
note("Décodage stéréo 44,1 kHz pour le réseau", finDécodage)
if étapes.count > 1 { print("   puis : « \(étapes[1].0) »") }

let médiane: Double = {
    guard tranches.count > 2 else { return 0 }
    let écarts = zip(tranches.dropFirst(), tranches).map(-).sorted()
    return écarts[écarts.count / 2]
}()
let premièreTranche = tranches.first ?? 0
note("Ouverture du réseau (le long moment muet)", max(premièreTranche - finDécodage - médiane, 0))
let finTranches = tranches.last ?? premièreTranche
note("Les \(tranches.count) tranches (\(String(format: "%.2f", médiane)) s l'une)",
     finTranches - premièreTranche + médiane)

var canaux = pistes.channels
let banque = mesure("Montée des pistes en mémoire") {
    BanqueDePistes(empreinte: empreinte, sampleRate: pistes.sampleRate, pistes: &canaux)
}
guard let banque else { exit(1) }
print(String(format: "   %.0f Mo en mémoire", Double(banque.poids) / 1e6))

// ── Ce que fait `show` une fois la séparation finie ──────────────────────────
//
// Tout ce qui suit est désormais **devant** l'utilisateur : le son et l'image sont
// prêts à la fin de cette section. L'écriture en FLAC, elle, est passée derrière et
// se mesure à part, plus bas.

print("── Après la séparation ──")
let vues: Set<Stem> = Set(Stem.separated).subtracting([.drums])
let mono = mesure("Somme « basse + accompagnement + voix » en mémoire") {
    banque.melangeMono(vues)
}
let matrice = mesure("Analyse de la somme (« Analyse de … »)") {
    OfflineAnalysis.run(samples: mono, sampleRate: banque.sampleRate, settings: réglages)
}
mesure("Carte des notes de la nouvelle image") {
    _ = NoteMap.build(matrice, referenceA: 440, prominence: ChordSettings().prominence)
}
mesure("Relevé de batterie sur la piste isolée") {
    _ = PercussionDetector.detect(samples: banque.melangeMono([.drums]),
                                  sampleRate: banque.sampleRate)
}

print("── Derrière la fenêtre ──")
mesure("Écriture des quatre pistes en FLAC (en fond)") {
    try? StemStore.ecrire(banque, pour: empreinte)
}
mesure("Rangement du cache") {
    StemStore.markUsed(empreinte)
    StemStore.pruneCache(keeping: empreinte)
}

// ── Le compte ────────────────────────────────────────────────────────────────

let total = maintenant() - départ
print("")
print("| Étape | Durée | Cumul |")
print("|---|---:|---:|")
for (quoi, durée, cumul) in lignes {
    print(String(format: "| %@ | %.2f s | %.0f s |", quoi, durée, cumul))
}
print(String(format: "| **Total** | **%.0f s** | |", total))
print(String(format: "Morceau de %.0f s → ×%.2f temps réel.", source.duration, total / source.duration))
