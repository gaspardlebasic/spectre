import Foundation
import SpectreCore
import SpectreModele
import SpectreMac

/// Relevé d'accords depuis le terminal : `Spectre --accords morceau.mp3`.
///
/// Sert d'abord à régler l'algorithme. Le relevé lit maintenant l'image, et l'image
/// dépend du contraste, des pistes affichées et du zoom : autant de choses qu'on ne
/// peut pas fixer dans un banc d'essai fait de signaux de synthèse. Ici on parcourt
/// le vrai chemin — analyse, contraste automatique, carte des notes, relevé — sur un
/// vrai morceau, et l'on peut faire varier un réglage en lisant la grille qui en
/// sort.
///
/// Options : `--depuis` et `--duree` pour ne regarder qu'un passage, `--tenue`,
/// `--clarte` et `--temps` pour bousculer les réglages, `--mixage` pour lire le
/// mixage entier là où l'application montrerait les pistes moins la batterie, et
/// `--notes` pour écrire sous chaque accord les raies qui l'ont décidé, et
/// `--sans-carte-basse` pour relever sans retirer les harmoniques de la basse.
enum ChordsCommand {
    static func run(path: String, arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        func number(_ name: String) -> Double? { value(name).flatMap(Double.init) }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("Fichier introuvable : \(path)\n".utf8))
            return 1
        }
        guard var source = try? AudioSource.load(url) else {
            FileHandle.standardError.write(Data("Lecture impossible : \(path)\n".utf8))
            return 1
        }

        // Les pistes, comme l'application les montre : tout sauf la batterie, quand
        // elles existent. C'est ce qui est à l'écran qui est relevé, donc c'est ce
        // qu'il faut lire ici pour que les chiffres veuillent dire quelque chose.
        var lu = "mixage"
        var basseSeule: AudioSource?
        let wanted: Set<Stem> = arguments.contains("--sans-voix")
            ? [.bass, .other] : [.bass, .other, .vocals]
        if !arguments.contains("--mixage"), let fingerprint = source.fingerprint,
           StemStore.isSeparated(fingerprint),
           let banque = try? StemStore.banque(pour: fingerprint) {
            // Les combinaisons ne sont plus des fichiers : les quatre pistes montent en
            // mémoire une fois, et toutes les sommes en sortent. C'est aussi ce que
            // fait la fenêtre, donc les chiffres restent comparables.
            source = AudioSource(url: source.url, sampleRate: banque.sampleRate,
                                 frameCount: banque.frameCount,
                                 mono: banque.melangeMono(wanted),
                                 fingerprint: fingerprint)
            lu = wanted.contains(.vocals) ? "pistes sans batterie" : "basse et accompagnement"
            // La basse toute seule : c'est elle qui dira lesquelles de ses raies sont
            // ses propres harmoniques. `--sans-carte-basse` l'écarte, pour mesurer ce
            // qu'elle change.
            if !arguments.contains("--sans-carte-basse") {
                basseSeule = AudioSource(url: source.url, sampleRate: banque.sampleRate,
                                         frameCount: banque.frameCount,
                                         mono: banque.melangeMono([.bass]),
                                         fingerprint: fingerprint)
            }
        }

        let started = Date()
        let spectrogram = OfflineAnalysis.run(samples: source.mono,
                                              sampleRate: source.sampleRate,
                                              settings: AnalysisSettings())
        guard spectrogram.columnCount > 0 else {
            FileHandle.standardError.write(Data("Matrice vide\n".utf8))
            return 1
        }
        guard let tempo = TempoEstimator.estimate(spectrogram), tempo.bpm > 0 else {
            FileHandle.standardError.write(Data("Aucune grille métrique trouvée\n".utf8))
            return 1
        }

        // Le contraste de l'ouverture : celui que l'application mesure sur le morceau
        // entier. Le relevé en dépend, il faut donc partir du même.
        var display = DisplaySettings()
        display = AutoContrast.settings(basedOn: display, in: spectrogram) ?? display

        var settings = ChordSettings()
        settings.scope = arguments.contains("--temps") ? .beat : .span
        switch value("--vocabulaire") {
        case "triades": settings.vocabulary = .triads
        case "septiemes": settings.vocabulary = .sevenths
        case "tout": settings.vocabulary = .all
        case "enrichis": settings.vocabulary = .extended
        default: break
        }
        if let hold = number("--tenue") { settings.hold = hold }
        if let clarity = number("--clarte") { settings.clarity = clarity }
        if let unexplained = number("--inexplique") { settings.unexplainedCost = unexplained }
        if let missing = number("--absente") { settings.missingCost = missing }
        if let rarity = number("--rare") { settings.rarityWeight = rarity }
        if let floor = number("--noir") { display.floorDb = floor }

        let mapStarted = Date()
        if let prominence = number("--nettete") { settings.prominence = prominence }
        if let drop = number("--pente") { settings.harmonicDrop = drop }
        if let slack = number("--marge") { settings.mustExceedParent = slack }
        let map = NoteMap.build(spectrogram, referenceA: display.referenceA,
                                prominence: settings.prominence)
        let bassMap = basseSeule.map { basse -> NoteMap in
            let matrix = OfflineAnalysis.run(samples: basse.mono,
                                             sampleRate: basse.sampleRate,
                                             settings: AnalysisSettings())
            return NoteMap.build(matrix, referenceA: display.referenceA,
                                 prominence: settings.prominence)
        }
        let mapSeconds = Date().timeIntervalSince(mapStarted)

        let detectStarted = Date()
        let track = ChordDetector.detect(map: map, display: display, tempo: tempo,
                                         settings: settings, bass: bassMap)
        let detectSeconds = Date().timeIntervalSince(detectStarted)

        let from = number("--depuis") ?? 0
        let span = number("--duree") ?? .infinity
        let to = span.isFinite ? from + span : .infinity

        print(String(format: "%@ — %.1f s, %@%@, %.1f BPM, %d/4",
                     url.lastPathComponent, spectrogram.duration, lu,
                     bassMap == nil ? "" : " · carte de basse",
                     tempo.bpm, tempo.beatsPerBar))
        print(String(format: "%@ — %d accords", settings.vocabulary.label as NSString,
                     settings.chords.count))
        print(String(format: "contraste %.0f…%.0f dB, pente %.1f dB/octave ; "
                     + "clarté %.2f, tenue %.0f %%",
                     display.floorDb, display.ceilingDb, display.tiltDbPerOctave,
                     settings.clarity, settings.hold * 100))
        print(String(format: "carte %.2f s, relevé %.3f s, analyse comprise %.1f s",
                     mapSeconds, detectSeconds, Date().timeIntervalSince(started)))

        var named = 0
        var lines = 0
        for segment in track.segments {
            if segment.chord != nil { named += 1 }
            guard segment.start >= from, segment.start < to else { continue }
            lines += 1
            let name = segment.chord?.label() ?? "—"
            let notes = segment.notes.map {
                $0.name() + ($0.role == .extra ? "?" : ($0.role == .root ? "*" : ""))
            }.joined(separator: " ")
            print(String(format: "%7.2f  %-6@  %.2f   %@",
                         segment.start, name as NSString, segment.confidence,
                         arguments.contains("--notes") ? notes : ""))
        }
        if lines == 0 { print("(aucun intervalle dans la fenêtre demandée)") }

        // Ce qu'on regarde pour régler : combien d'intervalles reçoivent un nom,
        // combien de raies ont décidé chacun, combien restent inexpliquées, et
        // combien de fois l'accord change — un relevé qui change à chaque mesure est
        // aussi suspect qu'un relevé qui ne change jamais.
        let total = max(track.segments.count, 1)
        let heldCount = track.segments.reduce(0) { $0 + $1.notes.count }
        let extras = track.segments.reduce(0) { $0 + $1.notes.filter { $0.role == .extra }.count }
        let withExtra = track.segments.filter { $0.notes.contains { $0.role == .extra } }.count
        var changes = 0
        for (a, b) in zip(track.segments, track.segments.dropFirst()) where a.chord != b.chord {
            changes += 1
        }
        let sure = track.segments.filter { $0.confidence >= 0.5 }.count
        print(String(format: "%d intervalles, %d nommés (%.0f %%), %d changements",
                     track.segments.count, named, 100 * Double(named) / Double(total), changes))
        print(String(format: "%.1f raies tenues par intervalle, %.1f %% inexpliquées, "
                     + "%.0f %% des intervalles en portent une",
                     Double(heldCount) / Double(total),
                     100 * Double(extras) / Double(max(heldCount, 1)),
                     100 * Double(withExtra) / Double(total)))
        print(String(format: "%.0f %% des noms sont sûrs (marge ≥ 0,5 raie)",
                     100 * Double(sure) / Double(total)))

        // Ce que les raies inexpliquées sont, par rapport à la fondamentale retenue :
        // c'est ce qui dit s'il manque une couleur au vocabulaire ou si ce sont
        // vraiment des notes étrangères.
        var intervals = [Int: Int]()
        for segment in track.segments {
            guard let chord = segment.chord else { continue }
            for note in segment.notes where note.role == .extra {
                let step = ((note.pitchClass - chord.root) % 12 + 12) % 12
                intervals[step, default: 0] += 1
            }
        }
        let degrees = ["fond.", "♭9", "9", "♭3", "3", "11", "♭5", "5", "♭13", "13", "♭7", "7"]
        let ranked = intervals.sorted { $0.value > $1.value }.prefix(6)
        print("inexpliquées : " + ranked.map { "\(degrees[$0.key]) ×\($0.value)" }
                .joined(separator: "  "))
        return 0
    }
}
