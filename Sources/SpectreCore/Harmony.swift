import Foundation

/// Relevé des accords : *quand* on en change, et *lequel* on joue.
///
/// Deux pistes séparées y répondent chacune à une moitié, et c'est ce partage qui
/// fait la différence avec un détecteur d'accords ordinaire :
///
/// - **la basse donne la fondamentale.** Presque monophonique, elle tranche les
///   ambiguïtés qui font échouer tout le reste : Do/Mi contre Mi mineur, La mineur 7
///   contre Do sixte — mêmes notes, fondamentale différente, et rien dans le
///   chromagramme ne les sépare ;
/// - **le reste donne la couleur.** Majeur, mineur, septième : c'est l'empilement
///   au-dessus de la basse qui le dit.
///
/// La voix est écartée exprès. Elle porte des notes de passage et des tenues qui
/// n'appartiennent pas à l'accord, et c'est la première source d'ajouts fantômes.
///
/// Comme pour la batterie, ce relevé **ne relit pas la matrice affichée**. Celle-ci
/// est faite pour l'œil : sa fenêtre s'allonge à mesure qu'on descend, et à 130 Hz —
/// le bas de l'accompagnement — elle dure 743 ms, soit une mesure et demie à 120 BPM.
/// Un changement d'accord y serait étalé sur ses voisins. On repart donc du signal,
/// avec deux fenêtres constantes choisies pour la hauteur et non pour l'instant.

// MARK: - Le vocabulaire

/// Ce qu'on sait nommer.
///
/// Le symbole est celui des grilles de jazz, pas la notation littérale : `-` pour la
/// tierce mineure, `Δ` pour la septième majeure, `°` et `ø` pour les diminués. Il
/// s'accole à une fondamentale nommée en français, comme partout ailleurs dans
/// l'application — `La-`, `DoΔ`, `Si-7♭5` s'écrivant `Siø`.
public enum ChordQuality: Int, CaseIterable, Codable, Sendable {
    case major, minor, suspended4, dominant7, minor7, major7
    case halfDiminished, diminished, augmented
    // Ajoutées avec le relevé par raies, et pour une raison précise : `Do6` et
    // `La-7` sont **le même jeu de notes**. Tant qu'on comparait des profils de
    // douze classes, les distinguer était sans espoir et la sixte n'aurait fait
    // qu'ajouter du bruit. Maintenant que la basse est une raie qu'on voit, elle
    // tranche : la même poignée de notes s'écrit `Do6` sur un Do et `La-7` sur un
    // La. Sans elles, un accord de sixte tenu se lisait renversé, avec une
    // fondamentale que rien dans l'image ne soutenait.
    case major6, minor6
    // Les enrichissements, ajoutés quand le relevé par raies a commencé à laisser
    // des neuvièmes et des treizièmes tenues sans nom : elles étaient, et de loin,
    // les premières « notes inexpliquées » du fichier témoin. Un vocabulaire qui ne
    // sait pas les écrire ne les fait pas disparaître de l'image — il oblige
    // seulement à les entourer en pointillés.
    //
    // Les formes retenues sont celles qu'on écrit vraiment sur une grille, pas
    // toutes celles qu'on pourrait former : la onzième de dominante se joue sans
    // tierce (c'est ce qui la distingue d'un `sus4` avec septième), et la treizième
    // se joue sans onzième, qui heurterait sa tierce.
    case add9, minorAdd9, ninth, minorNinth, major9
    case eleventh, minorEleventh, thirteenth

    public var symbol: String {
        switch self {
        case .major: ""
        case .minor: "-"
        case .suspended4: "sus4"
        case .dominant7: "7"
        case .minor7: "-7"
        case .major7: "Δ"
        case .halfDiminished: "ø"
        case .diminished: "°"
        case .augmented: "+"
        case .major6: "6"
        case .minor6: "-6"
        case .add9: "add9"
        case .minorAdd9: "-add9"
        case .ninth: "9"
        case .minorNinth: "-9"
        case .major9: "Δ9"
        case .eleventh: "11"
        case .minorEleventh: "-11"
        case .thirteenth: "13"
        }
    }

    /// Nom entier, pour les endroits où la place ne manque pas.
    public var label: String {
        switch self {
        case .major: "majeur"
        case .minor: "mineur"
        case .suspended4: "suspendu 4"
        case .dominant7: "septième"
        case .minor7: "mineur septième"
        case .major7: "septième majeure"
        case .halfDiminished: "demi-diminué"
        case .diminished: "diminué"
        case .augmented: "augmenté"
        case .major6: "sixte"
        case .minor6: "mineur sixte"
        case .add9: "neuvième ajoutée"
        case .minorAdd9: "mineur neuvième ajoutée"
        case .ninth: "neuvième"
        case .minorNinth: "mineur neuvième"
        case .major9: "septième majeure neuvième"
        case .eleventh: "onzième"
        case .minorEleventh: "mineur onzième"
        case .thirteenth: "treizième"
        }
    }

    /// Demi-tons au-dessus de la fondamentale.
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .suspended4: [0, 5, 7]
        case .dominant7: [0, 4, 7, 10]
        case .minor7: [0, 3, 7, 10]
        case .major7: [0, 4, 7, 11]
        case .halfDiminished: [0, 3, 6, 10]
        case .diminished: [0, 3, 6]
        case .augmented: [0, 4, 8]
        case .major6: [0, 4, 7, 9]
        case .minor6: [0, 3, 7, 9]
        case .add9: [0, 2, 4, 7]
        case .minorAdd9: [0, 2, 3, 7]
        case .ninth: [0, 2, 4, 7, 10]
        case .minorNinth: [0, 2, 3, 7, 10]
        case .major9: [0, 2, 4, 7, 11]
        // Sans tierce : c'est ce qui fait la onzième de dominante, et ce qui la
        // sépare d'un `sus4` à septième.
        case .eleventh: [0, 2, 5, 7, 10]
        case .minorEleventh: [0, 2, 3, 5, 7, 10]
        // Sans onzième, qui heurterait la tierce.
        case .thirteenth: [0, 2, 4, 7, 9, 10]
        }
    }

    /// Ce qu'il en coûte de préférer cette couleur à une triade.
    ///
    /// Il fallait ce prix quand le relevé comparait des profils : une septième
    /// contient sa triade, donc lui ressemblait autant *plus* une note, et un morceau
    /// entier se retrouvait écrit en septièmes. Le relevé par raies n'en a plus
    /// besoin — une septième qu'on ne voit pas coûte déjà une note absente — d'où un
    /// poids **nul par défaut** : ces prix ne servent plus qu'à ceux qui veulent
    /// forcer la main au vocabulaire. Voir `ChordSettings.rarityWeight`.
    var rarity: Double {
        switch self {
        case .major, .minor: 0
        case .dominant7, .minor7: 0.02
        case .major7, .suspended4: 0.03
        case .halfDiminished: 0.05
        case .diminished, .augmented: 0.07
        case .major6, .minor6: 0.04
        case .add9, .minorAdd9: 0.05
        case .ninth, .minorNinth, .major9: 0.06
        case .eleventh, .minorEleventh: 0.08
        case .thirteenth: 0.09
        }
    }
}

/// Une fondamentale et une couleur. `root` vaut 0 pour Do.
public struct Chord: Equatable, Hashable, Sendable {
    public var root: Int
    public var quality: ChordQuality

    public init(root: Int, quality: ChordQuality) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
    }

    /// Toutes les classes de hauteur de l'accord.
    public var pitchClasses: [Int] {
        quality.intervals.map { (root + $0) % 12 }
    }

    /// `La-`, `DoΔ`, `Sol7`. Les bémols par défaut, comme le reste de l'application :
    /// aucune des deux écritures n'est plus juste, c'est la tonalité qui tranche et
    /// on ne la connaît pas.
    public func label(flats: Bool = true) -> String {
        Pitch.names(flats: flats)[root] + quality.symbol
    }

    /// Tous les accords que le détecteur sait nommer — douze fondamentales par
    /// couleur. Le vocabulaire réellement employé se règle : voir
    /// `ChordSettings.Vocabulary`.
    public static let vocabulary: [Chord] = (0..<12).flatMap { root in
        ChordQuality.allCases.map { Chord(root: root, quality: $0) }
    }
}

// MARK: - Le relevé

/// Un accord tenu sur un intervalle de temps.
///
/// `confidence` est la **marge** entre le meilleur accord et le premier qui n'en est
/// pas une simple variante : elle sert à dessiner pâle ce qui n'est pas sûr. Un
/// détecteur qui affirme tout du même ton finit par n'être plus cru du tout.
public struct ChordSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// `nil` quand il ne se joue rien d'harmonique — un solo de batterie, un silence.
    public var chord: Chord?
    public var confidence: Double
    /// Les raies tenues sur lesquelles le nom a été décidé, à leur octave.
    ///
    /// Gardées avec le segment, et non recalculées à l'affichage. C'est ce qui rend
    /// impossible le désaccord entre le nom et ce qu'on entoure : il n'y a qu'un
    /// seul relevé, et le survol le montre tel quel.
    public var notes: [SoundingNote]

    public init(start: Double, end: Double, chord: Chord?, confidence: Double,
                notes: [SoundingNote] = []) {
        self.start = start
        self.end = end
        self.chord = chord
        self.confidence = confidence
        self.notes = notes
    }
}

/// La suite des accords : un par temps, ou un par mesure — voir `ChordSettings.Scope`.
///
/// **Relevée à une portée fixe, quel que soit le zoom.** L'affichage, lui, se
/// raréfie : au cadrage d'ensemble on ne montre qu'un nom par mesure ou par phrase.
/// C'est la même discipline que la grille et l'aimantation de la boucle — ce qu'on
/// voit est un sous-ensemble de ce qui est calculé, jamais un autre calcul.
public struct ChordTrack: Sendable {
    /// Contigus, dans l'ordre, un par temps.
    public let segments: [ChordSegment]

    /// Numéro du temps que porte `segments[0]`, compté depuis le premier temps fort
    /// de la grille — donc **négatif** quand le morceau commence avant lui.
    ///
    /// Sans lui, regrouper les temps par mesure revient à les compter depuis le
    /// début du fichier, qui n'a aucune raison de tomber sur un « un ». Les noms
    /// s'écrivaient alors à côté des barres de mesure, en avance de ce qui sépare le
    /// premier temps du premier temps fort : sur un morceau dont la grille commence à
    /// 1,637 s, deux temps entiers. C'est l'erreur qu'on entend avant de la voir —
    /// l'accord change à l'écran une mesure trop tôt.
    public let firstBeat: Int

    /// Vrai quand les segments sont **déjà** à leur portée définitive — une mesure
    /// entière, ou le passage sélectionné. L'affichage ne les regroupe alors plus :
    /// regrouper par mesure des segments qui sont des mesures reviendrait à compter
    /// les temps deux fois, et à écrire un nom sur quatre.
    public let grouped: Bool

    public init(segments: [ChordSegment], firstBeat: Int = 0, grouped: Bool = false) {
        self.segments = segments
        self.firstBeat = firstBeat
        self.grouped = grouped
    }

    public static let empty = ChordTrack(segments: [])
    public var isEmpty: Bool { segments.isEmpty }

    public func segment(at time: Double) -> ChordSegment? {
        segments.first { time >= $0.start && time < $0.end }
    }

    /// Ce qu'il faut écrire dans un intervalle, à une résolution donnée.
    ///
    /// `everyBeats` vient de l'échelle de la grille : 1 pour un nom par temps, 4 pour
    /// un par mesure, 16 pour un par phrase. Les segments voisins qui portent le même
    /// accord fusionnent, si bien qu'une harmonie tenue quatre mesures s'écrit une
    /// fois, à son début, et non quatre fois de suite.
    ///
    /// Le nom retenu pour un groupe est celui qui **dure le plus longtemps** dedans,
    /// pas celui du premier temps : une anacrouse ne doit pas nommer la mesure.
    public func labels(from t0: Double, to t1: Double,
                       grouping everyBeats: Int) -> [ChordSegment] {
        guard !segments.isEmpty else { return [] }
        // Déjà à leur portée : il ne reste qu'à fondre les répétitions.
        if grouped {
            return merged(segments.filter { $0.end >= t0 && $0.start <= t1 })
        }
        let step = max(everyBeats, 1)
        var grouped = [ChordSegment]()
        var index = 0
        while index < segments.count {
            // Les groupes tombent sur les frontières **métriques**, pas tous les
            // `step` temps depuis le début du fichier. Le premier peut donc être
            // court — c'est une levée, et une levée ne nomme pas la mesure suivante.
            let beat = firstBeat + index
            let toBoundary = step - ((beat % step) + step) % step
            let slice = segments[index..<min(index + toBoundary, segments.count)]
            index += toBoundary
            guard let first = slice.first, let last = slice.last else { continue }
            guard last.end >= t0, first.start <= t1 else { continue }

            // Le plus long, à égalité le plus sûr.
            var held = [Chord: (span: Double, confidence: Double)]()
            for s in slice {
                guard let chord = s.chord else { continue }
                let previous = held[chord] ?? (0, 0)
                held[chord] = (previous.span + (s.end - s.start),
                               max(previous.confidence, s.confidence))
            }
            let best = held.max { a, b in
                a.value.span != b.value.span ? a.value.span < b.value.span
                                             : a.value.confidence < b.value.confidence
            }
            grouped.append(ChordSegment(start: first.start, end: last.end,
                                        chord: best?.key,
                                        confidence: best?.value.confidence ?? 0,
                                        notes: common(slice)))
        }

        return merged(grouped)
    }

    /// Un accord tenu ne se réécrit pas à chaque groupe.
    private func merged(_ groups: some Sequence<ChordSegment>) -> [ChordSegment] {
        var result = [ChordSegment]()
        for segment in groups {
            if let previous = result.last, previous.chord == segment.chord,
               previous.chord != nil, abs(previous.end - segment.start) < 1e-6 {
                result[result.count - 1].end = segment.end
                result[result.count - 1].confidence = max(previous.confidence,
                                                          segment.confidence)
                result[result.count - 1].notes = Self.shared(previous.notes, segment.notes)
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// Les raies tenues pendant **tout** ce que le groupe couvre.
    ///
    /// L'intersection, et non la réunion. Une étiquette couvre parfois quatre
    /// mesures ; l'entourage qu'on dessine au survol court sur toute cette longueur,
    /// et montrer une raie qui n'a tenu que dans la première serait dessiner un
    /// cadre là où il n'y a rien à voir. Ce qui reste est ce qui est vrai partout.
    private static func shared(_ a: [SoundingNote], _ b: [SoundingNote]) -> [SoundingNote] {
        let second = Dictionary(b.map { ($0.midi, $0) }, uniquingKeysWith: { x, _ in x })
        return a.compactMap { note in
            guard let other = second[note.midi] else { return nil }
            var kept = note
            kept.level = max(note.level, other.level)
            kept.presence = min(note.presence, other.presence)
            return kept
        }
    }

    private func common(_ slice: ArraySlice<ChordSegment>) -> [SoundingNote] {
        guard var kept = slice.first?.notes else { return [] }
        for segment in slice.dropFirst() { kept = Self.shared(kept, segment.notes) }
        return kept
    }
}

// MARK: - Les raies tenues

/// Une raie de l'image, retenue par le relevé.
///
/// C'est l'unité de tout ce qui suit : le relevé ne travaille plus sur un profil de
/// douze classes de hauteur mais sur des **raies**, celles-là mêmes qu'on voit à
/// l'écran, à l'octave où on les voit.
public struct SoundingNote: Equatable, Sendable {
    /// Ce que la raie est devenue dans l'accord retenu.
    public enum Role: Int, Sendable, Equatable {
        /// La fondamentale.
        case root
        /// Une autre note de l'accord.
        case chord
        /// Une raie tenue que l'accord retenu **ne contient pas**. On la montre
        /// quand même : elle a compté dans la décision, et la cacher laisserait à
        /// l'écran un trait franc dont rien n'expliquerait l'absence.
        case extra
    }

    /// Numéro MIDI : 60 = Do4.
    public var midi: Int
    /// Niveau moyen de la raie pendant qu'elle est visible, en dB.
    public var level: Float
    public var role: Role
    /// Part de l'intervalle pendant laquelle la raie est visible, de 0 à 1.
    public var presence: Double

    public init(midi: Int, level: Float, role: Role = .chord, presence: Double = 1) {
        self.midi = midi
        self.level = level
        self.role = role
        self.presence = presence
    }

    public var isRoot: Bool { role == .root }
    public var pitchClass: Int { ((midi % 12) + 12) % 12 }
    public func name(flats: Bool = true) -> String {
        Pitch.names(flats: flats)[pitchClass] + "\(midi / 12 - 1)"
    }
}

/// La carte des notes : pour chaque demi-ton et chaque colonne, le sommet de la raie
/// qui s'y trouve, ou rien.
///
/// C'est la pièce qui remplace le chromagramme, et le changement n'est pas
/// technique. Un chromagramme replie tout le spectre en douze nombres : on y perd
/// l'octave, on y mélange les fondamentales et leurs harmoniques, et surtout **on ne
/// peut plus montrer ce sur quoi la décision a porté**. Une carte de notes garde
/// chaque raie là où elle est, si bien que tout ce que le relevé retient peut être
/// entouré à l'écran, à sa place, dans son octave.
///
/// Elle se lit dans la **matrice affichée**, et non dans le son : c'est la condition
/// de l'accord de l'image et du nom. Ce qui n'est pas dans l'image ne compte pas ; ce
/// qui y est franc et tenu compte forcément.
public struct NoteMap: Sendable {
    /// Registre lu : Mi1 à Do7. En dessous, l'analyse est trop étalée dans le temps
    /// pour dire quoi que ce soit d'un accord ; au-dessus, il n'y a plus que des
    /// harmoniques.
    public static let range = (low: 28, high: 96)

    public let low: Int
    public let high: Int
    public let columnCount: Int
    public let secondsPerColumn: Double
    public let referenceA: Double
    /// Le niveau, en dB, du sommet de chaque demi-ton, colonne par colonne :
    /// `levels[(midi - low) * columnCount + column]`. `-.infinity` là où aucune raie
    /// n'a son sommet dans ce demi-ton.
    ///
    /// Rangé par demi-ton et non par colonne, à l'inverse de la matrice : ce qu'on
    /// demandera toujours à cette carte, c'est « pendant combien de temps ce
    /// demi-ton a-t-il été là », donc une ligne entière d'un coup.
    public let levels: [Float]
    /// L'octave de chaque demi-ton, comptée depuis 1 kHz — l'échelle où s'applique
    /// la pente d'affichage.
    public let octaves: [Double]

    public var noteCount: Int { high - low + 1 }
    public var isEmpty: Bool { columnCount == 0 || levels.isEmpty }
    public var duration: Double { Double(columnCount) * secondsPerColumn }

    public static let empty = NoteMap(low: 0, high: -1, columnCount: 0,
                                      secondsPerColumn: 0.01, referenceA: Pitch.standardA,
                                      levels: [], octaves: [])

    /// De combien une raie doit rester sous sa voisine d'un demi-ton pour n'être que
    /// sa traînée, en dB.
    ///
    /// Le complément indispensable de la netteté, et il a fallu une note de synthèse
    /// tenue pour le voir : la traînée d'une fenêtre d'analyse n'est pas une pente
    /// lisse, elle ondule. Un Do4 seul, à −14 dB, laisse à un demi-ton au-dessus un
    /// vrai maximum local à −48, encadré de creux à −63 et −58 — nettement saillant,
    /// donc, et pourtant personne ne joue là. Aucune exigence de netteté ne peut
    /// l'écarter : c'est un sommet franc. Ce qui le trahit est son **écart à la
    /// note d'à côté** : trente-quatre décibels. Deux demi-tons réellement joués
    /// ensemble ne sont jamais si loin l'un de l'autre.
    ///
    /// Vingt décibels, et non réglable : ce n'est pas un goût musical mais une
    /// propriété de la fenêtre d'analyse, la même pour toute la musique.
    public static let masking: Float = 20
    /// Jusqu'à combien de demi-tons de distance la traînée porte.
    ///
    /// Deux, et c'est le grave qui l'impose : à 65 Hz un demi-ton vaut quatre hertz,
    /// et la traînée d'une note de basse déborde donc largement sur son voisin. Une
    /// note de basse seule se lisait ainsi comme une septième, la fausse raie tombant
    /// deux demi-tons plus bas qu'elle.
    public static let maskingReach = 2

    /// Relève les sommets d'une matrice, demi-ton par demi-ton.
    ///
    /// - Parameter prominence: de combien un sommet doit redescendre **des deux
    ///   côtés** avant le demi-ton voisin. Deux demi-tons réellement joués côte à
    ///   côte ont ce creux entre eux ; la traînée d'une note forte, non. Voir
    ///   `ChordSettings.prominence`.
    ///
    /// Un sommet, et pas une somme : une raie est un **maximum local** le long de
    /// l'axe des fréquences, exactement comme pour l'aimantation du curseur.
    public static func build(_ spectrogram: Spectrogram,
                             referenceA: Double = Pitch.standardA,
                             prominence: Double = ChordSettings().prominence,
                             low: Int = NoteMap.range.low,
                             high: Int = NoteMap.range.high) -> NoteMap {
        let layout = spectrogram.layout
        let bins = layout.binCount
        let columns = spectrogram.columnCount
        guard bins > 3, columns > 0, high >= low else { return .empty }

        // Les lignes qui appartiennent à chaque demi-ton, une fois pour toutes.
        var spans = [(first: Int, last: Int)]()
        var octaves = [Double]()
        for midi in low...high {
            let centre = Pitch.frequency(ofMidi: Double(midi), referenceA: referenceA)
            let lo = layout.bin(of: Pitch.frequency(ofMidi: Double(midi) - 0.5,
                                                    referenceA: referenceA))
            let hi = layout.bin(of: Pitch.frequency(ofMidi: Double(midi) + 0.5,
                                                    referenceA: referenceA))
            let first = max(1, Int(lo.rounded(.up)))
            let last = min(bins - 2, Int(hi.rounded(.down)))
            spans.append((first, last))
            octaves.append(log2(centre / 1000))
        }

        // Un demi-ton, en lignes : c'est la distance à laquelle on va chercher les
        // creux qui encadrent un sommet.
        let step = max(1, Int((layout.binsPerOctave / 12).rounded()))
        let mustStandOut = Float(prominence)
        let count = high - low + 1
        var levels = [Float](repeating: -.infinity, count: count * columns)
        spectrogram.values.withUnsafeBufferPointer { values in
            levels.withUnsafeMutableBufferPointer { out in
                for column in 0..<columns {
                    let base = column * bins
                    for note in 0..<count {
                        let span = spans[note]
                        guard span.first <= span.last else { continue }
                        var peak = -Float.infinity
                        for i in span.first...span.last {
                            let value = values[base + i]
                            guard value > peak else { continue }
                            // Sommet strict d'un côté : sur un plateau, une seule
                            // ligne est retenue plutôt que toutes.
                            guard value >= values[base + i - 1],
                                  value > values[base + i + 1] else { continue }
                            // Et qui domine les creux jusqu'au demi-ton voisin.
                            var left = Float.infinity, right = Float.infinity
                            for d in 1...step {
                                if i - d >= 0 { left = min(left, values[base + i - d]) }
                                if i + d < bins { right = min(right, values[base + i + d]) }
                            }
                            guard value - max(left, right) >= mustStandOut else { continue }
                            peak = value
                        }
                        out[note * columns + column] = peak
                    }
                    // La traînée du voisin : une raie très en dessous de son demi-ton
                    // voisin n'est pas une note, c'est le flanc de celui-là. On lit
                    // les niveaux avant de les effacer, sans quoi une raie effacée ne
                    // protégerait plus la suivante.
                    var kept = [Float](repeating: 0, count: count)
                    for note in 0..<count { kept[note] = out[note * columns + column] }
                    for note in 0..<count {
                        let level = kept[note]
                        guard level > -.infinity else { continue }
                        var loudest = -Float.infinity
                        for d in 1...maskingReach {
                            if note - d >= 0 { loudest = max(loudest, kept[note - d]) }
                            if note + d < count { loudest = max(loudest, kept[note + d]) }
                        }
                        if loudest - level > masking {
                            out[note * columns + column] = -.infinity
                        }
                    }
                }
            }
        }
        return NoteMap(low: low, high: high, columnCount: columns,
                       secondsPerColumn: spectrogram.secondsPerColumn,
                       referenceA: referenceA, levels: levels, octaves: octaves)
    }

    /// Le niveau, en dB, à partir duquel un demi-ton est **visible** à l'écran.
    ///
    /// La formule est celle du shader, retournée : le seuil de clarté devient un
    /// seuil de décibels, et la comparaison qui suit est une comparaison de nombres
    /// plutôt qu'une exponentiation par demi-ton et par colonne. C'est ce qui permet
    /// de refaire le relevé entier pendant qu'on tire le curseur de contraste.
    public func visibilityFloor(display: DisplaySettings, clarity: Double) -> [Float] {
        let span = max(display.ceilingDb - display.floorDb, 1e-3)
        let gamma = max(display.gamma, 1e-3)
        let needed = display.floorDb + span * pow(min(max(clarity, 0), 1), 1 / gamma)
        return octaves.map { Float(needed - display.tiltDbPerOctave * $0) }
    }

    public func column(atTime t: Double) -> Double { t / max(secondsPerColumn, 1e-9) - 0.5 }
}

/// Les raies tenues sur un intervalle, et ce qu'elles font d'un accord.
public enum ChordVoicing {
    /// Combien d'harmoniques on essaie comme explication d'une raie.
    static let harmonicCount = 6

    /// Les raies **tenues** d'un intervalle : celles qui sont visibles pendant
    /// (presque) toute sa durée, une fois retirées celles qu'une raie plus grave
    /// explique.
    ///
    /// Les deux règles, et il n'y en a pas d'autres :
    ///
    /// 1. **la tenue.** Une raie qui n'occupe pas l'intervalle entier n'est pas une
    ///    note de l'accord — c'est une note de passage, une broderie, une anticipation
    ///    du bassiste sur la barre. C'est exactement ce qu'on veut dire quand on dit
    ///    qu'un accord *dure* : ce qui change en cours de route n'en fait pas partie ;
    /// 2. **l'explication par le grave.** Une note isolée peuple le spectre bien
    ///    au-delà d'elle-même : son octave, sa quinte à la douzième, sa tierce majeure
    ///    deux octaves plus haut. Une raie qui s'explique par une raie plus grave —
    ///    tenue elle aussi, et au moins aussi forte — est sa conséquence et non un
    ///    choix du musicien.
    ///
    /// « Au moins aussi fort » est la nuance qui sauve le cas inverse : une harmonique
    /// est plus faible que sa fondamentale. Une raie franchement *plus forte* que la
    /// note qui pourrait l'expliquer contient donc autre chose — quelqu'un joue là
    /// aussi — et elle est gardée. C'est ce qui permet à un accord doublé à l'octave
    /// de montrer ses deux octaves.
    public static func held(in map: NoteMap, from t0: Double, to t1: Double,
                            display: DisplaySettings,
                            settings: ChordSettings = ChordSettings()) -> [SoundingNote] {
        guard !map.isEmpty, t1 > t0 else { return [] }
        let first = max(0, Int(map.column(atTime: t0).rounded(.up)))
        let last = min(map.columnCount - 1, Int(map.column(atTime: t1).rounded(.down)))
        guard first <= last else { return [] }
        let total = Double(last - first + 1)
        let floors = map.visibilityFloor(display: display, clarity: settings.clarity)

        // Présence et niveau moyen de chaque demi-ton.
        var candidates = [SoundingNote]()
        var levels = [Int: Float]()
        map.levels.withUnsafeBufferPointer { values in
            for note in 0..<map.noteCount {
                let floor = floors[note]
                let row = note * map.columnCount
                var seen = 0
                var sum = 0.0
                for column in first...last where values[row + column] >= floor {
                    seen += 1
                    sum += Double(values[row + column])
                }
                guard seen > 0 else { continue }
                let level = Float(sum / Double(seen))
                let midi = map.low + note
                levels[midi] = level
                guard Double(seen) / total >= settings.hold else { continue }
                candidates.append(SoundingNote(midi: midi, level: level,
                                               presence: Double(seen) / total))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // L'explication par le grave. On ne regarde que des parents **tenus** : une
        // note brève ne peut pas expliquer une note tenue, elle n'a pas duré assez.
        let heldLevels = Dictionary(uniqueKeysWithValues: candidates.map { ($0.midi, $0.level) })
        func explained(_ note: SoundingNote) -> Bool {
            for h in 2...harmonicCount {
                let rank = log2(Double(h))
                let parent = note.midi - Int((12 * rank).rounded())
                guard let parentLevel = heldLevels[parent] else { continue }
                // Ce qu'on attend de cette harmonique-là, plus la marge : au-dessus,
                // la raie contient autre chose que l'harmonique.
                let expected = Double(parentLevel) - settings.harmonicDrop * rank
                if Double(note.level) <= expected + settings.mustExceedParent { return true }
            }
            return false
        }
        return candidates.filter { !explained($0) }.sorted { $0.midi < $1.midi }
    }

    /// Ce que ces raies rapportent à chaque accord du vocabulaire.
    ///
    /// Le compte est celui qu'on ferait à la main, et c'est tout l'intérêt : chaque
    /// classe de hauteur tenue qui **est** dans l'accord rapporte un point ; chaque
    /// classe tenue que l'accord ne contient pas en coûte un — c'est le prix de
    /// laisser à l'écran une raie franche que le nom n'explique pas ; chaque note de
    /// l'accord qu'on ne voit **pas** coûte un demi-point, parce qu'une quinte
    /// omise ou masquée est chose commune et une tierce inventée non.
    public static func scores(for notes: [SoundingNote],
                              settings: ChordSettings) -> [Double] {
        let vocabulary = settings.chords
        guard !notes.isEmpty else {
            return [Double](repeating: -.infinity, count: vocabulary.count)
        }
        let classes = Set(notes.map(\.pitchClass))
        let bass = notes.first?.pitchClass
        return vocabulary.map { chord in
            let tones = Set(chord.pitchClasses)
            var score = 0.0
            for c in classes { score += tones.contains(c) ? 1 : -settings.unexplainedCost }
            for c in tones where !classes.contains(c) { score -= settings.missingCost }
            if let bass {
                if bass == chord.root { score += settings.bassAgreement }
                else if !tones.contains(bass) { score -= settings.bassContradiction }
            }
            return score - chord.quality.rarity * settings.rarityWeight
        }
    }

    /// Marque chaque raie selon ce que l'accord retenu en fait.
    public static func roles(_ notes: [SoundingNote], in chord: Chord?) -> [SoundingNote] {
        guard let chord else { return notes.map { var n = $0; n.role = .extra; return n } }
        let tones = Set(chord.pitchClasses)
        return notes.map { note in
            var marked = note
            marked.role = note.pitchClass == chord.root ? .root
                : (tones.contains(note.pitchClass) ? .chord : .extra)
            return marked
        }
    }
}

// MARK: - Détection

/// Devine les accords à partir des raies de l'image.
///
/// Le principe tient en une phrase : **l'accord est fait des raies qu'on voit, et de
/// rien d'autre.** Le relevé lit la matrice affichée — celle-là même, avec ses
/// réglages de contraste — y cherche les raies tenues pendant tout l'intervalle,
/// écarte celles qu'une raie plus grave explique, et nomme ce qui reste.
///
/// D'où trois propriétés qu'un relevé par corrélation ne peut pas offrir :
///
/// - **tout ce qui a compté peut être montré.** Survoler un nom entoure les raies
///   retenues, à leur octave, et les fait entendre. Il n'y a pas de traduction entre
///   ce qui a décidé et ce qui s'affiche : c'est le même objet ;
/// - **ce qui n'a pas compté s'explique en un mot.** Une raie franche que le nom
///   ignore n'a que trois raisons de l'être : elle n'a pas duré tout l'intervalle
///   (note de passage, anticipation de la basse), elle est l'harmonique d'une note
///   plus grave, ou elle est tenue mais étrangère à l'accord — et dans ce dernier cas
///   elle est montrée quand même, entourée en pointillés ;
/// - **régler le contraste change le relevé**, et c'est voulu. Le noir de l'image est
///   la frontière entre ce qui est joué et ce qui ne l'est pas. Le monter, c'est
///   décider que les traits pâles ne comptent pas, et le relevé suit — ce qu'on voit
///   est ce qui est lu.
///
/// La contrepartie assumée : le relevé lit **les pistes affichées**. Masquer la voix
/// retire ses tenues du relevé, ce qui est très souvent ce qu'on veut ; montrer le
/// mixage entier les y remet. L'ancien relevé lisait toujours basse et
/// accompagnement, quoi qu'on affiche — c'était défendable, mais incompatible avec la
/// promesse d'ici.
public enum ChordDetector {

    /// - Parameters:
    ///   - map: la carte des notes de la matrice affichée.
    ///   - display: les réglages d'affichage, dont dépend ce qui est visible.
    ///   - tempo: la grille sans laquelle il n'y a ni découpage ni endroit où écrire.
    ///   - selection: le passage sélectionné, s'il y en a un. N'est lu qu'en portée
    ///     « mesure » : c'est là qu'il devient l'unique intervalle relevé.
    public static func detect(map: NoteMap, display: DisplaySettings,
                              tempo: TempoGrid,
                              settings: ChordSettings = ChordSettings(),
                              selection: ClosedRange<Double>? = nil) -> ChordTrack {
        guard !map.isEmpty, tempo.bpm > 0 else { return .empty }
        let duration = map.duration

        switch settings.scope {
        case .beat:
            let bounds = beatBounds(tempo: tempo, duration: duration)
            guard bounds.count > 1 else { return .empty }
            let spans = (0..<(bounds.count - 1)).map { bounds[$0]...bounds[$0 + 1] }
            let read = spans.map { held(in: map, span: $0, display: display, settings: settings) }
            let scores = read.map { ChordVoicing.scores(for: $0, settings: settings) }
            let chosen = viterbi(scores, vocabulary: settings.chords,
                                 changeCost: settings.changeCost)
            return track(spans: spans, notes: read, scores: scores, chosen: chosen,
                         settings: settings, grouped: false,
                         firstBeat: Int(tempo.beat(at: bounds[0]).rounded()))
        case .span:
            var spans: [ClosedRange<Double>]
            if let selection, selection.upperBound - selection.lowerBound > LoopEditing.minimumLength {
                let lo = max(selection.lowerBound, 0)
                let hi = min(selection.upperBound, duration)
                guard hi > lo else { return .empty }
                spans = [lo...hi]
            } else {
                spans = barSpans(tempo: tempo, duration: duration)
            }
            guard !spans.isEmpty else { return .empty }
            let read = spans.map { held(in: map, span: $0, display: display, settings: settings) }
            let scores = read.map { ChordVoicing.scores(for: $0, settings: settings) }
            // Aucun lissage : une mesure entière porte assez de preuves pour se
            // décider seule, et un passage qu'on a sélectionné à la main ne doit
            // surtout pas hériter de ses voisins.
            let chosen = scores.map { column -> Int? in
                var best = -Double.infinity
                var argument = -1
                for j in column.indices where column[j] > best { best = column[j]; argument = j }
                return argument >= 0 && best > -.infinity ? argument : nil
            }
            return track(spans: spans, notes: read, scores: scores, chosen: chosen,
                         settings: settings, grouped: true,
                         firstBeat: Int(tempo.beat(at: spans[0].lowerBound).rounded()))
        }
    }

    private static func held(in map: NoteMap, span: ClosedRange<Double>,
                             display: DisplaySettings,
                             settings: ChordSettings) -> [SoundingNote] {
        ChordVoicing.held(in: map, from: span.lowerBound, to: span.upperBound,
                          display: display, settings: settings)
    }

    private static func track(spans: [ClosedRange<Double>], notes: [[SoundingNote]],
                              scores: [[Double]], chosen: [Int?],
                              settings: ChordSettings, grouped: Bool,
                              firstBeat: Int) -> ChordTrack {
        let vocabulary = settings.chords
        var segments = [ChordSegment]()
        segments.reserveCapacity(spans.count)
        for k in spans.indices {
            let chord = chosen[k].map { vocabulary[$0] }
            segments.append(ChordSegment(start: spans[k].lowerBound,
                                         end: spans[k].upperBound,
                                         chord: chord,
                                         confidence: margin(scores[k], vocabulary: vocabulary,
                                                            chosen: chosen[k]),
                                         notes: ChordVoicing.roles(notes[k], in: chord)))
        }
        return ChordTrack(segments: segments, firstBeat: firstBeat, grouped: grouped)
    }

    // MARK: Le découpage

    /// Les frontières de temps qui tombent dans le morceau.
    ///
    /// Le premier temps fort n'est pas à zéro : la grille a une origine, et on part du
    /// premier temps qui la suit dans le fichier.
    public static func beatBounds(tempo: TempoGrid, duration: Double) -> [Double] {
        let first = (tempo.beat(at: 0)).rounded(.up)
        var bounds = [Double]()
        var beat = first
        while true {
            let t = tempo.time(ofBeat: beat)
            if t > duration { break }
            if t >= 0 { bounds.append(t) }
            beat += 1
            // Une grille absurde ne doit pas faire tourner la boucle indéfiniment.
            if bounds.count > 100_000 { break }
        }
        return bounds
    }

    /// Les mesures entières qui tombent dans le morceau.
    ///
    /// Entières : une mesure tronquée par le début ou la fin du fichier n'est pas une
    /// mesure, et lui donner un nom d'accord reviendrait à juger une harmonie sur un
    /// fragment sans dire qu'il en est un.
    public static func barSpans(tempo: TempoGrid, duration: Double) -> [ClosedRange<Double>] {
        let perBar = Double(max(tempo.beatsPerBar, 1))
        guard tempo.bpm > 0, duration > 0 else { return [] }
        var spans = [ClosedRange<Double>]()
        var bar = (tempo.beat(at: 0) / perBar).rounded(.down)
        while true {
            let start = tempo.time(ofBeat: bar * perBar)
            let end = tempo.time(ofBeat: (bar + 1) * perBar)
            if start > duration { break }
            if start >= 0, end <= duration { spans.append(start...end) }
            bar += 1
            if spans.count > 100_000 { break }
        }
        return spans
    }

    // MARK: Le lissage

    /// Ce qu'il en coûte de passer d'un accord au suivant.
    ///
    /// Zéro pour rester. Sinon un prix, réduit selon la parenté : changer de couleur
    /// sur la même fondamentale est presque gratuit (Do puis Do7), une quinte est la
    /// cadence la plus fréquente de toute la musique tonale, un relatif vient juste
    /// après. Un accord à un triton coûte plein tarif.
    ///
    /// N'a de sens qu'à la portée « temps » : un temps isolé ne porte pas assez de
    /// raies tenues pour se décider seul. Une mesure, si.
    static func transition(_ a: Chord, _ b: Chord, changeCost: Double) -> Double {
        if a == b { return 0 }
        if a.root == b.root { return changeCost * 0.35 }
        let distance = (((b.root - a.root) % 12) + 12) % 12
        switch distance {
        case 5, 7: return changeCost * 0.6       // quinte, quarte
        case 3, 9: return changeCost * 0.75      // relatif
        case 2, 10: return changeCost * 0.85     // ton
        default: return changeCost
        }
    }

    /// Le meilleur chemin dans la suite des temps.
    ///
    /// Un temps muet (`-∞` partout) coupe la chaîne : ce qui vient après ne doit pas
    /// hériter de ce qui venait avant un silence de huit mesures.
    static func viterbi(_ scores: [[Double]], vocabulary: [Chord],
                        changeCost: Double) -> [Int?] {
        let states = vocabulary.count
        guard !scores.isEmpty, states > 0 else { return [] }
        var costs = [Double](repeating: 0, count: states * states)
        for i in 0..<states {
            for j in 0..<states {
                costs[i * states + j] = transition(vocabulary[i], vocabulary[j],
                                                   changeCost: changeCost)
            }
        }

        var best = [Double](repeating: -.infinity, count: states)
        var came = [[Int]]()
        var live = false
        for k in scores.indices {
            let silent = scores[k].allSatisfy { $0 == -.infinity }
            var next = [Double](repeating: -.infinity, count: states)
            var from = [Int](repeating: -1, count: states)
            if silent {
                came.append(from)
                best = [Double](repeating: -.infinity, count: states)
                live = false
                continue
            }
            for j in 0..<states {
                if !live {
                    next[j] = scores[k][j]
                    continue
                }
                var top = -Double.infinity
                var argument = -1
                for i in 0..<states where best[i] > -.infinity {
                    let candidate = best[i] - costs[i * states + j]
                    if candidate > top { top = candidate; argument = i }
                }
                next[j] = top + scores[k][j]
                from[j] = argument
            }
            came.append(from)
            best = next
            live = true
        }

        // Remontée.
        var path = [Int?](repeating: nil, count: scores.count)
        var cursor: Int? = nil
        for k in stride(from: scores.count - 1, through: 0, by: -1) {
            let silent = scores[k].allSatisfy { $0 == -.infinity }
            if silent { cursor = nil; continue }
            if cursor == nil {
                var top = -Double.infinity
                var argument = -1
                let column = k == scores.count - 1 ? best
                    : recompute(scores, upTo: k, costs: costs, states: states)
                for j in 0..<states where column[j] > top { top = column[j]; argument = j }
                cursor = argument >= 0 ? argument : nil
            }
            path[k] = cursor
            if let c = cursor, came[k].indices.contains(c) {
                cursor = came[k][c] >= 0 ? came[k][c] : nil
            }
        }
        return path
    }

    /// Recalcule la colonne de scores cumulés à un temps donné.
    ///
    /// N'arrive qu'aux fins de chaîne — juste avant un silence — donc quelques fois
    /// par morceau, jamais dans la boucle chaude.
    private static func recompute(_ scores: [[Double]], upTo k: Int,
                                  costs: [Double], states: Int) -> [Double] {
        var best = [Double](repeating: -.infinity, count: states)
        var live = false
        for step in 0...k {
            if scores[step].allSatisfy({ $0 == -.infinity }) {
                best = [Double](repeating: -.infinity, count: states)
                live = false
                continue
            }
            var next = [Double](repeating: -.infinity, count: states)
            for j in 0..<states {
                if !live { next[j] = scores[step][j]; continue }
                var top = -Double.infinity
                for i in 0..<states where best[i] > -.infinity {
                    top = max(top, best[i] - costs[i * states + j])
                }
                next[j] = top + scores[step][j]
            }
            best = next
            live = true
        }
        return best
    }

    /// Écart entre l'accord retenu et le meilleur qui ne partage pas sa fondamentale.
    ///
    /// Comparer au second tout court ne dirait rien : le second est presque toujours
    /// la même harmonie d'une couleur voisine — Do et DoΔ — et cette hésitation-là
    /// n'est pas une incertitude sur ce qu'on entend. Ce qui mérite d'être signalé,
    /// c'est de ne pas savoir *sur quoi* l'accord est bâti.
    ///
    /// L'unité est la raie : un point d'écart, c'est une note tenue de différence.
    static func margin(_ scores: [Double], vocabulary: [Chord], chosen: Int?) -> Double {
        guard let chosen, scores.indices.contains(chosen),
              scores[chosen] > -.infinity else { return 0 }
        let root = vocabulary[chosen].root
        var rival = -Double.infinity
        for i in scores.indices where vocabulary[i].root != root {
            rival = max(rival, scores[i])
        }
        guard rival > -.infinity else { return 1 }
        return min(max(scores[chosen] - rival, 0), 1)
    }
}
