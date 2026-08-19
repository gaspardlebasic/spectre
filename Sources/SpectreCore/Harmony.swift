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
        }
    }

    /// Ce qu'il en coûte de préférer cette couleur à une triade.
    ///
    /// Sans ce prix, le vocabulaire le plus riche gagne toujours : une septième
    /// contient sa triade, donc lui ressemble autant *plus* une note. Un morceau
    /// entier se retrouverait écrit en septièmes, ce qui est faux et illisible. On ne
    /// paie pas la complexité pour la punir, mais pour exiger qu'elle se justifie.
    var rarity: Double {
        switch self {
        case .major, .minor: 0
        case .dominant7, .minor7: 0.02
        case .major7, .suspended4: 0.03
        case .halfDiminished: 0.05
        case .diminished, .augmented: 0.07
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

    /// Les 108 accords que le détecteur sait nommer.
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

    public init(start: Double, end: Double, chord: Chord?, confidence: Double) {
        self.start = start
        self.end = end
        self.chord = chord
        self.confidence = confidence
    }
}

/// La suite des accords, un par temps.
///
/// **Toujours relevée au temps, quel que soit le zoom.** L'affichage, lui, se
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

    public init(segments: [ChordSegment], firstBeat: Int = 0) {
        self.segments = segments
        self.firstBeat = firstBeat
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
                                        confidence: best?.value.confidence ?? 0))
        }

        // Un accord tenu ne se réécrit pas à chaque groupe.
        var result = [ChordSegment]()
        for segment in grouped {
            if let previous = result.last, previous.chord == segment.chord,
               previous.chord != nil, abs(previous.end - segment.start) < 1e-6 {
                result[result.count - 1].end = segment.end
                result[result.count - 1].confidence = max(previous.confidence,
                                                          segment.confidence)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}

// MARK: - Où l'accord sonne

/// Une note de l'accord telle qu'on l'entend vraiment, et où.
public struct SoundingNote: Equatable, Sendable {
    /// Numéro MIDI : 60 = Do4.
    public var midi: Int
    /// Niveau relevé, en dB.
    public var level: Float
    /// Vrai si c'est la fondamentale de l'accord.
    public var isRoot: Bool

    public init(midi: Int, level: Float, isRoot: Bool) {
        self.midi = midi
        self.level = level
        self.isRoot = isRoot
    }

    public var pitchClass: Int { ((midi % 12) + 12) % 12 }
    public func name(flats: Bool = true) -> String {
        Pitch.names(flats: flats)[pitchClass] + "\(midi / 12 - 1)"
    }
}

/// Retrouve, dans le spectre, les notes de l'accord qui sont **jouées**.
///
/// Le point délicat est de ne pas montrer les harmoniques. Une note isolée peuple le
/// spectre bien au-delà d'elle-même : son octave, sa quinte à la douzième, sa tierce
/// majeure deux octaves plus haut. Entourer tout ce qui, dans l'image, appartient aux
/// classes de hauteur de l'accord reviendrait à entourer une forêt de traits dont
/// presque aucun n'a été joué — et pour un accord majeur, dont les harmoniques
/// tombent justement sur ses propres notes, ce serait le pire des cas.
///
/// La règle appliquée est celle qu'on emploierait à l'oreille : **une raie qui
/// s'explique par une raie plus grave n'est pas une note**. Pour chaque candidate on
/// regarde les hauteurs dont elle serait la 2ᵉ, 3ᵉ… 6ᵉ harmonique ; si l'une d'elles
/// sonne au moins aussi fort, la candidate est sa conséquence et non un choix du
/// musicien.
///
/// « Au moins aussi fort » est la nuance qui sauve le cas inverse : une harmonique
/// est plus faible que sa fondamentale. Une raie *plus forte* que la note qui
/// pourrait l'expliquer contient donc autre chose — quelqu'un joue là aussi — et elle
/// est gardée. C'est ce qui permet à un accord serré, doublé à l'octave, de montrer
/// ses deux octaves.
public enum ChordVoicing {
    /// Registre exploré : Mi1 à Do7. En dessous, l'analyse est trop étalée dans le
    /// temps pour dire quoi que ce soit d'un accord ; au-dessus, il n'y a plus que
    /// des harmoniques.
    public static let range = (low: 28, high: 96)
    /// Écart au plus fort en dessous duquel une raie n'est plus une note mais un fond.
    ///
    /// Trente décibels, et non quarante-deux comme au premier jet. Quarante-deux était
    /// une plage d'ingénieur, pas une plage de musicien : sur un vrai morceau, le
    /// demi-ton le plus fort du registre étant à −41 dB, le seuil tombait à −83 dB et
    /// laissait passer des raies trente décibels sous la note qu'on cherchait.
    private static let dynamicRange: Float = 30
    /// Sous ce niveau, il ne se passe rien du tout et l'on n'entoure rien.
    ///
    /// Un seuil **absolu**, en plus de l'écart relatif — et il est indispensable. Le
    /// relatif seul se moque de l'échelle : dans un silence numérique, où toutes les
    /// lignes valent −120 dB, chacune est à zéro décibel de la plus forte et passe
    /// pour une note. Un accord survolé pendant un silence entourait ainsi ses trois
    /// notes sur toute la hauteur de l'image. Même raisonnement que le plancher du
    /// relevé de la batterie.
    private static let silenceFloor: Float = -90
    /// Combien d'harmoniques on essaie comme explication.
    private static let harmonicCount = 6
    /// De combien une raie doit **dépasser** la note qui l'expliquerait pour être
    /// gardée quand même.
    ///
    /// Neuf décibels, et le chiffre vient de la mesure, pas du principe. « Plus forte
    /// que sa fondamentale supposée » ne suffit pas : sur un vrai mixage, l'octave et
    /// la douzième d'une note grave sont *couramment* plus fortes que sa fondamentale
    /// — une basse rayonne mal son premier partiel. Avec ce seuil-là à zéro, un accord
    /// de trois notes s'entourait de sept cercles, la même note revenant à quatre
    /// octaves. Il faut un écart franc pour croire que quelqu'un joue là aussi.
    private static let mustExceedParent: Float = 9

    /// - Parameters:
    ///   - spectrum: un spectre en dB, ligne par ligne, tel que
    ///     `Spectrogram.averageSpectrum` le rend.
    ///   - visibleFloor: le **noir de l'image**, en dB. Rien de plus sombre que lui
    ///     n'est entouré.
    ///
    ///     C'est la correction d'un défaut qui n'avait rien de théorique. Le seuil ne
    ///     tenait qu'à l'écart au plus fort, sans aucun rapport avec ce qui est
    ///     affiché : sur un morceau où le demi-ton le plus fort valait −41 dB, une
    ///     raie à −80 dB passait pour une note. Elle était entourée et nommée, à un
    ///     endroit parfaitement noir à l'écran — et pire, elle expliquait ensuite
    ///     comme sa propre harmonique la vraie note, deux octaves plus haut, qui
    ///     disparaissait du même coup. Entourer ce que l'image ne montre pas est un
    ///     mensonge ; on prend donc le plus exigeant des deux seuils.
    public static func sounding(_ chord: Chord, in spectrum: [Float], layout: BinLayout,
                                referenceA: Double = Pitch.standardA,
                                visibleFloor: Float = -.infinity,
                                limit: Int = 8) -> [SoundingNote] {
        guard !spectrum.isEmpty, layout.binCount == spectrum.count else { return [] }

        // Un niveau par demi-ton : le sommet des lignes qui lui appartiennent. Le banc
        // en compte trois par demi-ton, assez pour qu'une note un peu fausse tombe
        // encore dedans.
        var levels = [Int: Float]()
        for midi in range.low...range.high {
            let f = Pitch.frequency(ofMidi: Double(midi), referenceA: referenceA)
            guard f > layout.minFrequency, f < layout.maxFrequency else { continue }
            let lo = layout.bin(of: Pitch.frequency(ofMidi: Double(midi) - 0.5,
                                                    referenceA: referenceA))
            let hi = layout.bin(of: Pitch.frequency(ofMidi: Double(midi) + 0.5,
                                                    referenceA: referenceA))
            let first = max(0, Int(lo.rounded(.up)))
            let last = min(layout.binCount - 1, Int(hi.rounded(.down)))
            guard first <= last else { continue }
            var peak = -Float.infinity
            for i in first...last { peak = max(peak, spectrum[i]) }
            levels[midi] = peak
        }
        guard let loudest = levels.values.max(), loudest > silenceFloor else { return [] }
        let floor = max(loudest - dynamicRange, silenceFloor, visibleFloor)

        // Une note est un **sommet** : plus forte que ses deux demi-tons voisins.
        // Sans cette exigence, le flanc d'une raie large compterait comme une note de
        // plus, un demi-ton à côté.
        let classes = Set(chord.pitchClasses)
        var candidates = [SoundingNote]()
        for (midi, level) in levels where level > floor {
            guard classes.contains(((midi % 12) + 12) % 12) else { continue }
            let below = levels[midi - 1] ?? -.infinity
            let above = levels[midi + 1] ?? -.infinity
            guard level >= below, level >= above else { continue }
            candidates.append(SoundingNote(midi: midi, level: level,
                                           isRoot: ((midi % 12) + 12) % 12 == chord.root))
        }

        // L'élimination des harmoniques. On regarde toutes les hauteurs présentes, pas
        // seulement les candidates : une note de l'accord peut très bien être la
        // cinquième harmonique d'une basse étrangère à l'accord.
        func explained(_ note: SoundingNote) -> Bool {
            for h in 2...harmonicCount {
                let parent = note.midi - Int((12 * log2(Double(h))).rounded())
                guard let parentLevel = levels[parent], parentLevel > floor else { continue }
                if parentLevel >= note.level - mustExceedParent { return true }
            }
            return false
        }

        // Rien d'autre. Une classe dont toutes les occurrences s'expliquent ne donne
        // aucun cercle — et c'est voulu, même si l'accord la contient : ce serait
        // entourer une harmonique en prétendant montrer une note jouée. Une note de
        // l'accord qu'on ne voit pas entourée est une information, pas un oubli.
        return Array(candidates.filter { !explained($0) }
                        .sorted { $0.midi < $1.midi }.prefix(limit))
    }
}

// MARK: - Détection

/// Devine les accords à partir des pistes de basse et d'accompagnement.
///
/// En quatre temps.
///
/// **1. Deux chromagrammes, pas un.** Chaque piste est repliée en douze classes de
/// hauteur, mais sur des registres et avec des fenêtres différents : la basse là où
/// elle vit et avec la finesse qu'exige le grave, l'accompagnement dans les trois
/// octaves où se rangent les accords.
///
/// **2. Un cumul par temps.** La grille métrique découpe le morceau ; un accord se
/// décide sur un temps entier et non sur une trame de 46 ms. Les trames sont pesées
/// en cloche à l'intérieur du temps, pour que celles qui débordent sur le voisin
/// comptent moins.
///
/// **3. Des gabarits qui contiennent leurs propres harmoniques.** C'est le point
/// délicat. Un gabarit binaire — « Do majeur, c'est Do, Mi, Sol » — est faux dans le
/// monde réel : la 3ᵉ harmonique d'une note tombe sur sa quinte et la 5ᵉ sur sa
/// tierce majeure, si bien qu'un Do mineur seul fait apparaître un Mi qui n'est pas
/// joué, et que tout accord semble contenir sa quinte. Les gabarits d'ici portent
/// donc la série harmonique de chacune de leurs notes. On ne corrige plus le
/// mensonge après coup : on l'attend.
///
/// **4. Un passage de Viterbi.** Rester coûte zéro, changer coûte — et changer vers
/// un voisin du cycle des quintes coûte moins que vers un accord lointain. Sans lui,
/// un détecteur sans mémoire fait clignoter Do et La- d'un temps sur l'autre, ce qui
/// est à la fois le symptôme le plus visible et le plus agaçant.
public enum ChordDetector {
    /// Fenêtre de l'accompagnement : 8192 points, 186 ms à 44,1 kHz, une ligne tous
    /// les 5,4 Hz. Un demi-ton fait 7,8 Hz à Do3, le bas du registre retenu : les
    /// demi-tons y sont donc séparés, tout juste.
    public static let harmonyWindow = 8192
    /// Fenêtre de la basse : deux fois plus longue, parce qu'une octave plus bas les
    /// demi-tons sont deux fois plus serrés. 372 ms — plus qu'un temps rapide, et
    /// c'est la limite assumée : une basse qui bouge à la double croche n'est pas
    /// lue note à note, seulement sa teneur sur le temps.
    public static let bassWindow = 8192
    /// Grille commune aux deux, comme pour la batterie : 2048 points, 46 ms.
    public static let hop = 2048

    /// Registre de l'accompagnement : Do3 à Do6. Plus bas, les fenêtres deviendraient
    /// trop longues ; plus haut, on ne trouve que des harmoniques.
    private static let harmonyRange = (low: 48, high: 84)          // MIDI
    /// Registre de la basse : Mi2 à Mi4. Mi1, la corde grave, n'y est pas — sa
    /// fondamentale à 41 Hz demanderait 700 ms de fenêtre — mais son octave y est, et
    /// une octave est la même classe de hauteur.
    private static let bassRange = (low: 40, high: 64)

    /// Combien d'harmoniques portent les gabarits, et de combien elles décroissent.
    ///
    /// Six : au-delà, la 7ᵉ tombe à un tiers de ton de la septième mineure et ferait
    /// passer toute note isolée pour un accord de septième.
    private static let harmonicCount = 6
    private static let harmonicDecay = 0.6

    /// Ce que rapporte une basse qui confirme la fondamentale, et ce que coûte une
    /// basse étrangère à l'accord.
    private static let bassAgreement = 0.35
    private static let bassInversion = 0.12
    private static let bassContradiction = 0.20
    /// Prix d'un changement d'accord d'un temps au suivant.
    private static let changeCost = 0.55
    /// Sous ce niveau, rapporté au plein du morceau, on n'écrit rien.
    private static let silenceFloor: Float = 0.02
    /// Part d'un temps lue pour la **basse**, comptée depuis son début. Voir `pool`.
    ///
    /// L'accompagnement, lui, se lit en entier : c'est la basse qui anticipe, pas les
    /// accords. Un clavier ou une guitare posent leur accord sur le temps et le
    /// tiennent ; réduire aussi leur fenêtre ne ferait que leur retirer la moitié de
    /// leurs preuves, et le relevé y perdait effectivement son tonique — `Do-` tombait
    /// de 153 à 84 occurrences sur le fichier témoin.
    private static let bassOnsetFraction = 0.55

    /// - Parameters:
    ///   - bass: la piste de basse, en mono.
    ///   - harmony: l'accompagnement — la piste « reste », en mono.
    ///   - tempo: la grille sans laquelle il n'y a ni découpage ni endroit où écrire.
    public static func detect(bass: [Float], harmony: [Float], sampleRate: Double,
                              tempo: TempoGrid,
                              referenceA: Double = Pitch.standardA) -> ChordTrack {
        guard sampleRate > 0, tempo.bpm > 0, !harmony.isEmpty else { return .empty }
        let duration = Double(max(bass.count, harmony.count)) / sampleRate
        let bounds = beatBounds(tempo: tempo, duration: duration)
        guard bounds.count > 1 else { return .empty }

        let frameCount = Int(duration * sampleRate / Double(hop)) + 1
        let secondsPerFrame = Double(hop) / sampleRate
        let harmonyChroma = chroma(harmony, sampleRate: sampleRate, window: harmonyWindow,
                                   range: harmonyRange, frameCount: frameCount,
                                   referenceA: referenceA)
        let bassChroma = chroma(bass, sampleRate: sampleRate, window: bassWindow,
                                range: bassRange, frameCount: frameCount,
                                referenceA: referenceA)

        // Le plein du morceau sert de référence au silence, comme le contraste
        // automatique déduit son noir de la matrice au lieu de le fixer d'avance.
        let loudest = harmonyChroma.map { $0.reduce(0, +) }.max() ?? 0
        let floor = loudest * silenceFloor

        // Chaque flux écarte sa propre demi-fenêtre : la basse voit deux fois plus
        // loin que l'accompagnement, elle doit donc reculer deux fois plus.
        let harmonyClearance = Double(harmonyWindow) / sampleRate / 2
        let bassClearance = Double(bassWindow) / sampleRate / 2

        var pooled = [[Float]](), bassPooled = [[Float]](), alive = [Bool]()
        for k in 0..<(bounds.count - 1) {
            let h = pool(harmonyChroma, from: bounds[k], to: bounds[k + 1],
                         secondsPerFrame: secondsPerFrame, clearance: harmonyClearance)
            pooled.append(normalized(h))
            bassPooled.append(normalized(pool(bassChroma, from: bounds[k], to: bounds[k + 1],
                                              secondsPerFrame: secondsPerFrame,
                                              clearance: bassClearance,
                                              onset: bassOnsetFraction)))
            alive.append(h.reduce(0, +) > floor)
        }

        let templates = Chord.vocabulary.map { template($0) }
        let roots = (0..<12).map { noteTemplate($0) }

        // Les scores d'émission, un tableau par temps.
        var scores = [[Double]]()
        for k in pooled.indices {
            guard alive[k] else {
                scores.append([Double](repeating: -.infinity, count: Chord.vocabulary.count))
                continue
            }
            let bassClass = strongest(bassPooled[k], against: roots)
            scores.append(Chord.vocabulary.enumerated().map { index, chord in
                var s = Double(cosine(pooled[k], templates[index]))
                if let bassClass {
                    if bassClass == chord.root { s += bassAgreement }
                    else if chord.pitchClasses.contains(bassClass) { s += bassInversion }
                    else { s -= bassContradiction }
                }
                return s - chord.quality.rarity
            })
        }

        let chosen = viterbi(scores)
        var segments = [ChordSegment]()
        for k in pooled.indices {
            let chord = chosen[k].map { Chord.vocabulary[$0] }
            segments.append(ChordSegment(start: bounds[k], end: bounds[k + 1],
                                         chord: chord,
                                         confidence: margin(scores[k], chosen: chosen[k])))
        }
        // Le numéro du premier temps, pour que le regroupement à l'affichage sache où
        // sont les barres de mesure.
        return ChordTrack(segments: segments,
                          firstBeat: Int(tempo.beat(at: bounds[0]).rounded()))
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

    // MARK: Le chromagramme

    /// Replie le signal en douze classes de hauteur, trame par trame.
    ///
    /// Chaque demi-ton du registre reçoit l'énergie des lignes de la transformée qui
    /// tombent à moins d'un demi-ton de lui, pondérées en triangle — puis toutes les
    /// octaves d'une même note s'additionnent. Les hauteurs viennent de `Pitch`, donc
    /// du diapason réglé : un morceau enregistré au La 432 se replie sur ses propres
    /// demi-tons et non sur ceux de quelqu'un d'autre.
    static func chroma(_ samples: [Float], sampleRate: Double, window: Int,
                       range: (low: Int, high: Int), frameCount: Int,
                       referenceA: Double) -> [[Float]] {
        let empty = [[Float]](repeating: [Float](repeating: 0, count: 12), count: frameCount)
        guard let fft = RealFFT(n: window), samples.count > window else { return empty }
        let half = window / 2
        let binHz = sampleRate / Double(window)

        // Pour chaque demi-ton : les lignes concernées et leur poids.
        var taps = [(cls: Int, lo: Int, hi: Int, weights: [Float])]()
        for midi in range.low...range.high {
            let centre = Pitch.frequency(ofMidi: Double(midi), referenceA: referenceA)
            let lower = Pitch.frequency(ofMidi: Double(midi) - 0.5, referenceA: referenceA)
            let upper = Pitch.frequency(ofMidi: Double(midi) + 0.5, referenceA: referenceA)
            let lo = max(1, Int((lower / binHz).rounded(.up)))
            let hi = min(half, Int((upper / binHz).rounded(.down)))
            guard lo <= hi else { continue }
            let weights = (lo...hi).map { i -> Float in
                let f = Double(i) * binHz
                // Triangle : plein au centre du demi-ton, nul à ses bords.
                let d = abs(log2(f / centre)) * 12
                return Float(max(0, 1 - d * 2))
            }
            taps.append((cls: ((midi % 12) + 12) % 12, lo: lo, hi: hi, weights: weights))
        }
        guard !taps.isEmpty else { return empty }

        var out = [[Float]]()
        out.reserveCapacity(frameCount)
        var spectrum = [Float](repeating: 0, count: half + 1)
        var frame = [Float](repeating: 0, count: window)
        for f in 0..<frameCount {
            gather(samples, centre: f * hop, into: &frame)
            fft.power(of: frame, into: &spectrum)
            var bins = [Float](repeating: 0, count: 12)
            for tap in taps {
                var sum: Float = 0
                for (k, i) in (tap.lo...tap.hi).enumerated() {
                    sum += spectrum[i] * tap.weights[k]
                }
                // La racine : on travaille en amplitude, pas en puissance. Sur une
                // puissance, la note la plus forte écrase toutes les autres et un
                // accord ne se distingue plus de sa basse.
                bins[tap.cls] += sum.squareRoot()
            }
            out.append(bins)
        }
        return out
    }

    /// Recopie une fenêtre **centrée**, complétée de silence aux deux bouts — la même
    /// convention que le relevé de la batterie, pour que deux fenêtres de longueurs
    /// différentes se comparent sans recalage.
    private static func gather(_ samples: [Float], centre: Int, into frame: inout [Float]) {
        let n = frame.count
        let start = centre - n / 2
        for i in 0..<n {
            let j = start + i
            frame[i] = (j >= 0 && j < samples.count) ? samples[j] : 0
        }
    }

    /// Cumule les trames d'un temps, en **écartant celles dont la fenêtre déborde**.
    ///
    /// C'est le point qui décide de la ponctualité, et il a fallu de la vraie musique
    /// pour le voir. Une trame est centrée sur son instant, mais elle *voit* une demi-
    /// fenêtre de part et d'autre — 93 ms pour l'accompagnement, 186 pour la basse.
    /// Les dernières trames d'un temps voient donc déjà le temps suivant, et pas
    /// n'importe quoi : son **attaque**, la partie la plus forte d'une note de basse.
    /// Pendant ce temps la note du temps courant, elle, s'est éteinte depuis un demi-
    /// temps. Le nouvel accord gagnait ainsi le temps d'avant, et l'on voyait le
    /// changement arriver une croche trop tôt — assez pour poser les doigts au mauvais
    /// moment. Une pondération en cloche n'y suffit pas : elle réduit le poids, mais
    /// une attaque franche l'emporte quand même sur une note qui meurt.
    ///
    /// On retire donc une demi-fenêtre à chaque bout, comme le relevé de la batterie
    /// écarte la bavure d'une attaque en attendant une demi-fenêtre avant de regarder.
    /// Ce qui reste ne contient plus un seul échantillon du temps voisin.
    ///
    /// Le retrait est plafonné au tiers du temps : sur un tempo rapide, ou avec la
    /// fenêtre longue de la basse, il ne resterait sinon rien du tout. Le débordement
    /// revient alors, et la cloche reprend son rôle — moins bien, mais c'est le prix
    /// d'une résolution en hauteur qu'on ne peut pas payer autrement.
    ///
    /// **Et l'on ne lit que le début du temps.** C'est le second enseignement de la
    /// vraie musique, et il est musical plus que numérique : un bassiste pose très
    /// souvent la fondamentale du prochain accord *avant* la barre — une anticipation,
    /// mesurée à 370 ms sur le fichier témoin. Le temps qui précède la barre contient
    /// alors majoritairement l'accord suivant, et le lire en entier revient à annoncer
    /// le changement un temps trop tôt. Or ce qu'une grille doit dire, c'est l'accord
    /// **au moment où l'on pose les doigts** : l'anticipation appartient à l'accord
    /// qu'elle annonce, pas au temps où elle tombe. On lit donc la première moitié du
    /// temps, celle qui décide de ce qu'on joue dessus.
    static func pool(_ frames: [[Float]], from t0: Double, to t1: Double,
                     secondsPerFrame: Double, clearance: Double,
                     onset: Double = 1) -> [Float] {
        var sum = [Float](repeating: 0, count: 12)
        guard secondsPerFrame > 0, t1 > t0, !frames.isEmpty else { return sum }
        let span = t1 - t0
        let margin = min(clearance, span / 3)
        let lo = t0 + margin, hi = min(t0 + onset * span, t1 - margin)
        let f0 = max(0, Int((lo / secondsPerFrame).rounded(.up)))
        let f1 = min(frames.count - 1, Int((hi / secondsPerFrame).rounded(.down)))
        guard hi > lo, f0 <= f1 else {
            // Un temps plus court que ce qu'on retire — tempo rapide, fenêtre longue.
            // On prend alors la trame la mieux placée : celle du premier tiers, qui
            // reste celle qui décide de ce qu'on joue sur ce temps.
            let f = min(max(Int(((t0 + span / 3) / secondsPerFrame).rounded()), 0),
                        frames.count - 1)
            return frames[f]
        }
        for f in f0...f1 {
            let position = (Double(f) * secondsPerFrame - lo) / max(hi - lo, 1e-9)
            let weight = Float(0.5 * (1 - cos(2 * .pi * min(max(position, 0), 1))))
            // Une seule trame retenue : la cloche vaudrait zéro et effacerait le temps.
            for c in 0..<12 { sum[c] += frames[f][c] * (f0 == f1 ? 1 : weight) }
        }
        return sum
    }

    // MARK: Les gabarits
    //
    // Publics comme le sont `TempoEstimator.onsetEnvelope` ou `DemucsSeparator.moments` :
    // ce sont les pièces sur lesquelles porte la vérification, et une pièce qu'on ne
    // peut pas interroger seule ne se vérifie que par ses effets.

    /// Profil attendu d'une note isolée, harmoniques comprises.
    ///
    /// Pour une note de classe 0, cela donne 1,82 sur elle-même, 0,44 sur sa quinte
    /// (3ᵉ et 6ᵉ harmoniques) et 0,13 sur sa tierce majeure (5ᵉ). C'est très
    /// exactement pourquoi un chromagramme brut fait passer les mineurs pour des
    /// majeurs : la quinte et la tierce majeure sont **déjà là** sans que personne
    /// les joue.
    public static func noteTemplate(_ pitchClass: Int) -> [Float] {
        var t = [Float](repeating: 0, count: 12)
        add(note: pitchClass, into: &t, gain: 1)
        return normalized(t)
    }

    public static func template(_ chord: Chord) -> [Float] {
        var t = [Float](repeating: 0, count: 12)
        for interval in chord.quality.intervals {
            add(note: chord.root + interval, into: &t, gain: 1)
        }
        return normalized(t)
    }

    private static func add(note: Int, into t: inout [Float], gain: Float) {
        for h in 1...harmonicCount {
            // La h-ième harmonique est à 12·log₂(h) demi-tons — arrondi à la classe la
            // plus proche, ce qui est faux de 31 cents pour la 7ᵉ et exact pour les
            // puissances de deux. C'est la raison de s'arrêter à six.
            let semitones = Int((12 * log2(Double(h))).rounded())
            let cls = (((note + semitones) % 12) + 12) % 12
            t[cls] += gain * Float(pow(harmonicDecay, Double(h - 1)))
        }
    }

    // MARK: Comparaison

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return [Float](repeating: 0, count: v.count) }
        return v.map { $0 / norm }
    }

    /// Cosinus de deux profils déjà normalisés.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    /// La classe de hauteur que la basse désigne, ou `nil` si elle ne dit rien.
    ///
    /// Comparée à des gabarits de note isolée plutôt que lue au maximum du
    /// chromagramme : une basse porte sa propre quinte dans ses harmoniques, et sur
    /// un son riche ce faux pic dépasse parfois le vrai.
    static func strongest(_ chroma: [Float], against roots: [[Float]]) -> Int? {
        guard chroma.contains(where: { $0 > 0 }) else { return nil }
        var best = 0
        var bestScore = -Float.infinity
        for c in 0..<12 {
            let s = cosine(chroma, roots[c])
            if s > bestScore { bestScore = s; best = c }
        }
        return bestScore > 0 ? best : nil
    }

    // MARK: Le lissage

    /// Ce qu'il en coûte de passer d'un accord au suivant.
    ///
    /// Zéro pour rester. Sinon un prix, réduit selon la parenté : changer de couleur
    /// sur la même fondamentale est presque gratuit (Do puis Do7), une quinte est la
    /// cadence la plus fréquente de toute la musique tonale, un relatif vient juste
    /// après. Un accord à un triton coûte plein tarif.
    static func transition(_ a: Chord, _ b: Chord) -> Double {
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
    static func viterbi(_ scores: [[Double]]) -> [Int?] {
        let states = Chord.vocabulary.count
        guard !scores.isEmpty, states > 0 else { return [] }
        // Table de transitions, calculée une fois : 108 × 108 valeurs.
        var costs = [Double](repeating: 0, count: states * states)
        for i in 0..<states {
            for j in 0..<states {
                costs[i * states + j] = transition(Chord.vocabulary[i], Chord.vocabulary[j])
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
                // Fin de chaîne : le meilleur état de ce temps-là.
                var top = -Double.infinity
                var argument = -1
                let column = k == scores.count - 1 ? best : recompute(scores, upTo: k, costs: costs)
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
                                  costs: [Double]) -> [Double] {
        let states = Chord.vocabulary.count
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
    static func margin(_ scores: [Double], chosen: Int?) -> Double {
        guard let chosen, scores.indices.contains(chosen),
              scores[chosen] > -.infinity else { return 0 }
        let root = Chord.vocabulary[chosen].root
        var rival = -Double.infinity
        for i in scores.indices where Chord.vocabulary[i].root != root {
            rival = max(rival, scores[i])
        }
        guard rival > -.infinity else { return 1 }
        // Un dixième de point d'écart est déjà net ; au-delà c'est sans appel.
        return min(max((scores[chosen] - rival) / 0.10, 0), 1)
    }
}
