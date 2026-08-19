import Foundation

/// Relevé de la batterie : *quand*, *quoi*, *combien fort* — les trois seules
/// questions qu'on se pose devant une piste de percussions.
///
/// Le spectrogramme n'y répond pas. Son axe vertical porte la hauteur, et une
/// batterie n'en a pas : une grosse caisse est une tache basse et large, une caisse
/// claire une barre qui traverse toute l'image, un charleston un brouillard en haut.
/// L'axe qui porte toute l'information sur une mélodie n'en porte presque aucune
/// ici, et la palette « notes » attribue des teintes qui ne veulent rien dire.
///
/// Pire : le banc multi-résolution est **fait pour l'inverse** de ce qu'il faudrait.
/// Il allonge la fenêtre à mesure qu'on descend, pour séparer deux demi-tons dans
/// les graves ; à 60 Hz elle dure une seconde et demie. Une grosse caisse y est
/// étalée sur plus d'une mesure. C'est pourquoi cette analyse-ci ne relit pas la
/// matrice mais **repart du signal**, avec une fenêtre courte et constante : 21 ms,
/// une ligne tous les 47 Hz. On y perd toute finesse en hauteur — dont on n'a que
/// faire — et on y gagne la seule chose qui compte, l'instant de l'attaque.
public enum DrumVoice: Int, CaseIterable, Codable, Sendable {
    case kick, snare, cymbal

    public var label: String {
        switch self {
        case .kick: "Grosse caisse"
        case .snare: "Caisse claire"
        case .cymbal: "Cymbales"
        }
    }

    /// De quoi tenir sur la marge d'une ligne haute de quinze points.
    public var short: String {
        switch self {
        case .kick: "GC"
        case .snare: "CC"
        case .cymbal: "CY"
        }
    }

    /// Bande où cette voie porte l'essentiel de son attaque.
    ///
    /// Les bandes ne se touchent pas : entre elles vivent la basse (150–200 Hz)
    /// et le corps des instruments harmoniques (1,2–5 kHz), qui n'ont rien à faire
    /// dans un détecteur de percussions. Ce qui déborde quand même — le claquement
    /// d'une caisse claire monte jusqu'à 10 kHz — est la limite connue de la
    /// méthode, et se voit à l'écran plutôt que de se cacher.
    public var band: ClosedRange<Double> {
        switch self {
        case .kick: 30...150
        case .snare: 200...1200
        case .cymbal: 5000...14000
        }
    }

    /// Couleur de la voie, en sRGB.
    ///
    /// Trois teintes **choisies**, et non calculées. La version précédente les
    /// répartissait sur le cercle chromatique à clarté et chroma égales en Oklch,
    /// comme la palette des notes, pour qu'aucune ligne ne paraisse jouer plus fort
    /// qu'une autre à force égale. Ces trois-ci ne suivent pas cette règle — le jaune
    /// est nettement plus clair que le violet — mais elles se distinguent mieux les
    /// unes des autres sur un fond noir, et sur trois lignes nommées en marge la
    /// confusion n'a pas lieu d'être. Le compromis est assumé dans ce sens-là.
    public var color: (r: Double, g: Double, b: Double) {
        let hex: UInt32 = switch self {
        case .kick: 0x9200ED        // violet
        case .snare: 0x00E0BA       // turquoise
        case .cymbal: 0xFFCF00      // jaune
        }
        return (Double((hex >> 16) & 0xFF) / 255,
                Double((hex >> 8) & 0xFF) / 255,
                Double(hex & 0xFF) / 255)
    }

    /// Fenêtre avec laquelle on **reconnaît** cette voie — jamais avec laquelle on
    /// la date.
    ///
    /// Séparer 60 Hz de 200 Hz demande une fenêtre longue : à 21 ms, une ligne fait
    /// 47 Hz et le corps d'une caisse claire tombe dans la bande de la grosse
    /// caisse, si bien que tout ce qui sonne allume tout. C'est très exactement le
    /// compromis du banc multi-résolution — mais il ne coûte rien ici, parce que
    /// l'instant, lui, vient d'ailleurs : de la courbe d'attaque, à 5 ms près, la
    /// même pour toutes les voies. On peut donc prendre 85 ms pour regarder les
    /// graves sans rien perdre de la ponctualité.
    var windowSize: Int {
        switch self {
        case .kick: 4096      // 85 ms à 48 kHz, une ligne tous les 12 Hz
        case .snare: 2048     // 43 ms, une ligne tous les 23 Hz
        case .cymbal: 1024    // 21 ms : là-haut, une ligne de 47 Hz est déjà fine
        }
    }

    /// Deux coups de la même voie ne se suivent pas de plus près que ça. Un
    /// roulement de caisse claire enfreint cette règle, et c'est assumé : mieux vaut
    /// un roulement montré comme une suite de coups réguliers que chaque rebond
    /// compté deux fois sur tout le reste du morceau.
    var refractory: Double {
        switch self {
        case .kick: 0.06
        case .snare: 0.06
        case .cymbal: 0.04
        }
    }
}

/// Un coup : son instant, sa voie, et sa force rapportée aux autres coups de la
/// même voie dans le morceau (1 = le plus franc).
///
/// La force est **relative** parce qu'elle sert à dessiner : ce qu'on lit sur une
/// ligne de batterie, ce sont les accents, pas des décibels.
public struct DrumHit: Equatable, Sendable {
    public var time: Double
    public var voice: DrumVoice
    public var strength: Double

    public init(time: Double, voice: DrumVoice, strength: Double) {
        self.time = time
        self.voice = voice
        self.strength = strength
    }
}

/// Les coups relevés, et les courbes d'attaque dont ils sont tirés.
///
/// Les courbes sont gardées parce qu'un détecteur se trompe : dessinées en fond,
/// elles montrent ce que le seuil a laissé de côté. Une ligne de coups qui ne
/// s'accorde pas avec la bosse qu'on voit derrière se voit immédiatement, là où une
/// ligne de coups seule aurait l'air d'une vérité.
public struct PercussionTrack: Sendable {
    /// Triés par instant croissant, toutes voies mêlées.
    public let hits: [DrumHit]
    /// Une courbe par voie, dans l'ordre de `DrumVoice`, ramenée entre 0 et 1.
    public let curves: [[Float]]
    public let secondsPerFrame: Double

    public init(hits: [DrumHit], curves: [[Float]], secondsPerFrame: Double) {
        self.hits = hits
        self.curves = curves
        self.secondsPerFrame = secondsPerFrame
    }

    public static let empty = PercussionTrack(hits: [], curves: [], secondsPerFrame: 0.005)
    public var isEmpty: Bool { hits.isEmpty && curves.isEmpty }

    public func hits(of voice: DrumVoice) -> [DrumHit] {
        hits.filter { $0.voice == voice }
    }

    /// Les coups d'un intervalle. Le balayage suffit : un morceau en compte
    /// quelques milliers, et une image se dessine soixante fois par seconde sur des
    /// machines qui en font mille fois plus.
    public func hits(from t0: Double, to t1: Double) -> [DrumHit] {
        hits.filter { $0.time >= t0 && $0.time <= t1 }
    }

    /// Hauteur de la courbe d'une voie sur un intervalle de temps.
    ///
    /// C'est le **maximum**, jamais la moyenne — la même règle que le shader du
    /// spectrogramme au dézoom, et pour la même raison : une attaque est brève par
    /// nature et disparaîtrait dès qu'un pixel couvre plus qu'elle.
    public func level(_ voice: DrumVoice, from t0: Double, to t1: Double) -> Float {
        let curve = curves.indices.contains(voice.rawValue) ? curves[voice.rawValue] : []
        guard !curve.isEmpty, secondsPerFrame > 0 else { return 0 }
        let f0 = max(0, Int(t0 / secondsPerFrame))
        let f1 = min(curve.count - 1, Int(t1 / secondsPerFrame))
        guard f0 <= f1 else { return 0 }
        var peak: Float = 0
        for f in f0...f1 { peak = max(peak, curve[f]) }
        return peak
    }
}

// MARK: - Détection

/// Relève les coups de batterie à partir du signal, indépendamment de la matrice.
///
/// En deux temps, et c'est le point délicat.
///
/// **Quand** : une seule courbe de flux spectral, sur tout le spectre utile, dont
/// on cueille les sommets. Un coup, quel qu'il soit, est une montée d'énergie.
///
/// **Quoi** : surtout pas la répartition de cette montée entre les bandes. Une
/// attaque est brève, donc large : le principe d'incertitude étale la moindre
/// percussion sur tout le spectre le temps d'une fenêtre, si bien qu'au moment
/// précis de l'attaque *toutes* les bandes montent — la première version de ce
/// fichier comptait chaque caisse claire comme une grosse caisse. On regarde donc
/// ce qui **reste** 10 à 60 ms après : là, la bavure est passée et il ne subsiste
/// que le son de l'instrument. Une caisse claire n'a presque rien à 60 Hz une fois
/// son attaque finie ; une grosse caisse, presque tout.
///
/// Reste à décider ce que « fort » veut dire. Pas en décibels absolus — la même
/// batterie enregistrée dix décibels plus bas donnerait un relevé vide. Chaque
/// bande est rapportée à **ses propres statistiques sur le morceau** : son fond
/// (20ᵉ centile) et son plein (97ᵉ). Un coup est une bande portée aux deux tiers de
/// son plein. C'est le même raisonnement que le contraste automatique, qui déduit
/// son noir et son clair de la matrice plutôt que de les fixer d'avance.
public enum PercussionDetector {
    /// 1024 points, soit 21 ms à 48 kHz : assez long pour qu'une grosse caisse à
    /// 60 Hz existe dans le spectre (trois périodes), assez court pour qu'un
    /// charleston ne bave pas sur la double croche voisine.
    public static let fftSize = 1024
    /// Un quart de fenêtre : 5 ms, la précision d'instant qu'on vise.
    public static let hopDivisor = 4

    /// Les niveaux sont plafonnés par le bas, comme pour le tempo : sans quoi le
    /// silence numérique produirait des montées de 150 dB au moindre souffle.
    private static let floorDb: Float = -90
    /// Largeur (de part et d'autre) de la moyenne locale retranchée du flux.
    private static let trendSeconds = 0.25
    /// Montée moyenne, en dB par ligne, en dessous de laquelle aucun sommet du flux
    /// n'est un coup. Un plancher absolu, pour qu'une piste vide ne rende pas du
    /// bruit régulier.
    private static let minimumRise: Float = 0.8
    /// Un sommet du flux doit peser au moins cette part du 90ᵉ centile des sommets.
    private static let relativeThreshold: Float = 0.22
    /// Deux coups, quels qu'ils soient, ne se distinguent pas de plus près que ça.
    private static let onsetRefractory = 0.045
    /// Durée d'observation de la queue d'un coup : la bavure est passée, l'instrument
    /// résonne encore.
    ///
    /// Elle commence une **demi-fenêtre** après l'attaque, et cette demi-fenêtre
    /// dépend de la voie. C'est indispensable et ce n'est pas évident : une trame de
    /// 85 ms centrée 15 ms après le coup contient encore le coup, donc encore sa
    /// bavure — attendre « 15 ms » ne veut rien dire tant qu'on n'a pas dit avec
    /// quelle fenêtre on regarde. Repoussée d'une demi-fenêtre, la première trame
    /// lue ne contient plus un seul échantillon d'avant l'attaque.
    private static let tailSeconds = 0.060
    /// Une bande sonne quand elle est à moins de tant de décibels de son plein.
    ///
    /// Mesuré depuis le **haut**, jamais depuis le fond : le fond d'une bande, c'est
    /// le silence entre deux coups, et le silence numérique est à −90 dB comme il
    /// pourrait être à −140. Compter depuis lui rendait la mesure dépendante de rien
    /// — une caisse claire dont la bavure atteint 60 % de l'écart au silence
    /// allumait la grosse caisse. Depuis le haut, la question devient « cette bande
    /// est-elle portée comme elle l'est quand son instrument joue ? », qui ne dépend
    /// ni du niveau d'enregistrement ni du plancher.
    private static let presenceRange: Float = 12
    /// Montée minimale d'une bande entre l'avant et l'après d'un coup, en dB.
    private static let minimumLift: Float = 5
    /// Étendue, en dB, de ce qui se dessine en fond des lignes : au-delà, noir.
    private static let displayRange: Float = 30
    /// Étendue, en dB, sur laquelle se lisent les accents : un coup joué 18 dB sous
    /// les plus francs du morceau est dessiné au minimum de visibilité.
    private static let accentRange: Float = 18

    public static func detect(samples: [Float], sampleRate: Double) -> PercussionTrack {
        let hop = fftSize / hopDivisor
        guard sampleRate > 0, samples.count > 4 * fftSize else { return .empty }
        // Toutes les courbes partagent cette grille, quelle que soit la fenêtre qui
        // les a produites : les trames sont **centrées** sur `f · hop`, si bien
        // qu'une fenêtre de 85 ms et une de 21 ms décrivent bien le même instant.
        let frameCount = samples.count / hop
        let secondsPerFrame = Double(hop) / sampleRate

        // Quand : les sommets du flux, sur tout le spectre utile.
        let flux = attackFlux(samples, sampleRate: sampleRate,
                              hop: hop, frameCount: frameCount)
        let onsets = peaks(in: detrended(flux, secondsPerFrame: secondsPerFrame),
                           secondsPerFrame: secondsPerFrame, refractory: onsetRefractory)

        // Quoi : pour chacun, les bandes qui sonnent encore une fois l'attaque
        // passée, rapportées à ce que cette bande fait de plus fort dans le morceau.
        var hits: [DrumHit] = []
        var curves = [[Float]]()
        for voice in DrumVoice.allCases {
            let level = bandLevel(samples, sampleRate: sampleRate, hop: hop,
                                  frameCount: frameCount, voice: voice)
            // La garde dépend de la voie : une trame de 85 ms centrée 15 ms après le
            // coup contient encore le coup, donc encore sa bavure.
            let clearance = Double(voice.windowSize) / sampleRate / 2
            let firstTail = Int((clearance / secondsPerFrame).rounded())
            let lastTail = Int(((clearance + tailSeconds) / secondsPerFrame).rounded())
            let after = firstTail...max(firstTail, lastTail)
            let before = (-lastTail)...(-firstTail)

            // Ce que chaque coup laisse dans cette bande, et ce qui y était juste
            // avant. Les deux se mesurent une fois pour toutes : `loud` est le plein
            // de la bande **tel qu'un coup le produit**, et non le plein de la bande
            // toutes trames confondues — sur un mixage, une nappe de clavier tenue
            // fixerait ce dernier sans qu'aucune caisse claire n'y soit pour rien.
            let tails = onsets.map { onset -> (before: Float, after: Float) in
                let f = Int((onset.time / secondsPerFrame).rounded())
                func peak(_ window: ClosedRange<Int>) -> Float {
                    var top = floorDb
                    for k in window where f + k >= 0 && f + k < level.count {
                        top = max(top, level[f + k])
                    }
                    return top
                }
                return (peak(before), peak(after))
            }
            let loud = percentile(tails.map(\.after), 0.90)
            // Ce qui se dessine en fond se compte depuis le haut, comme la présence
            // et la force : le fond de l'image est ce qui est à trente décibels du
            // plein de la bande. Compté depuis le silence, un coup encore en train de
            // s'éteindre trois cents millisecondes plus tard tenait la moitié de la
            // hauteur, et la ligne n'était plus qu'une bouillie grise.
            curves.append(level.map { min(max(1 - (loud - $0) / displayRange, 0), 1) })

            var previousHit = -Double.infinity
            for (onset, tail) in zip(onsets, tails) {
                let peak = tail.after
                guard peak >= loud - presenceRange else { continue }
                // Et il faut que la bande ait **monté** : sur une piste isolée, la
                // question ne se pose pas — entre deux coups il n'y a rien. Sur un
                // mixage, le médium est occupé en permanence par les claviers et les
                // guitares, et sans cette condition la ligne de caisse claire suivrait
                // l'accompagnement au lieu de la batterie.
                guard peak >= tail.before + minimumLift else { continue }
                // Un roulement enfreint la garde de sa voie, et c'est assumé :
                // mieux vaut le montrer comme une suite de coups réguliers que
                // compter chaque rebond deux fois sur tout le reste du morceau.
                guard onset.time - previousHit >= voice.refractory else { continue }
                previousHit = onset.time
                // La force se compte **depuis le haut** : un coup se juge contre les
                // coups les plus francs du morceau, sur la quinzaine de décibels où
                // vivent les accents. La rapporter au fond, comme la présence,
                // saturerait tout à 1 dès que le fond est du silence.
                let strength = 1 - Double((loud - peak) / accentRange)
                hits.append(DrumHit(time: onset.time, voice: voice,
                                    strength: min(max(strength, 0.08), 1)))
            }
        }
        hits.sort { $0.time < $1.time }
        return PercussionTrack(hits: hits, curves: curves, secondsPerFrame: secondsPerFrame)
    }

    /// Courbe d'attaque : pour chaque trame, la montée moyenne par ligne depuis la
    /// trame précédente, sur tout le spectre où vit une percussion.
    ///
    /// Moyenne **par ligne** et non somme, pour que le plancher absolu veuille dire
    /// la même chose quelle que soit la cadence d'échantillonnage.
    private static func attackFlux(_ samples: [Float], sampleRate: Double,
                                   hop: Int, frameCount: Int) -> [Float] {
        let n = fftSize
        guard let fft = RealFFT(n: n) else { return [] }
        let half = n / 2
        let lowest = max(1, bin(of: 30, n: n, sampleRate: sampleRate))
        let highest = min(half, bin(of: 16000, n: n, sampleRate: sampleRate))
        guard lowest < highest else { return [] }

        var flux = [Float](repeating: 0, count: frameCount)
        var spectrum = [Float](repeating: 0, count: half + 1)
        var current = [Float](repeating: floorDb, count: half + 1)
        var previous = [Float](repeating: floorDb, count: half + 1)
        var window = [Float](repeating: 0, count: n)

        for f in 0..<frameCount {
            gather(samples, centre: f * hop, into: &window)
            fft.power(of: window, into: &spectrum)
            for i in lowest...highest {
                current[i] = max(10 * log10(max(spectrum[i], 1e-12)), floorDb)
            }
            if f > 0 {
                var sum: Float = 0
                for i in lowest...highest {
                    let rise = current[i] - previous[i]
                    if rise > 0 { sum += rise }
                }
                flux[f] = sum / Float(highest - lowest + 1)
            }
            swap(&current, &previous)
        }
        return flux
    }

    /// Niveau d'une bande, trame par trame, avec la fenêtre propre à cette voie.
    private static func bandLevel(_ samples: [Float], sampleRate: Double, hop: Int,
                                  frameCount: Int, voice: DrumVoice) -> [Float] {
        let n = voice.windowSize
        guard let fft = RealFFT(n: n) else { return [] }
        let half = n / 2
        let lo = min(max(bin(of: voice.band.lowerBound, n: n, sampleRate: sampleRate), 1), half)
        let hi = min(max(bin(of: voice.band.upperBound, n: n, sampleRate: sampleRate), lo), half)

        var out = [Float](repeating: floorDb, count: frameCount)
        var spectrum = [Float](repeating: 0, count: half + 1)
        var window = [Float](repeating: 0, count: n)
        for f in 0..<frameCount {
            gather(samples, centre: f * hop, into: &window)
            fft.power(of: window, into: &spectrum)
            var power: Float = 0
            for i in lo...hi { power += spectrum[i] }
            out[f] = max(10 * log10(max(power, 1e-12)), floorDb)
        }
        return out
    }

    /// Recopie une fenêtre **centrée** sur un échantillon, complétée de silence aux
    /// deux bouts du fichier. C'est ce centrage qui permet de comparer des fenêtres
    /// de longueurs différentes sans les recaler une à une.
    private static func gather(_ samples: [Float], centre: Int, into window: inout [Float]) {
        let n = window.count
        let start = centre - n / 2
        for i in 0..<n {
            let j = start + i
            window[i] = (j >= 0 && j < samples.count) ? samples[j] : 0
        }
    }

    private static func bin(of frequency: Double, n: Int, sampleRate: Double) -> Int {
        Int((frequency * Double(n) / sampleRate).rounded())
    }

    /// Centile d'une suite de niveaux. Trier coûte un instant, une fois par bande
    /// et par morceau : ce n'est pas là que se joue le temps de calcul.
    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
        return sorted[index]
    }

    /// Retranche la tendance locale : ce qui compte est de dépasser ses voisines
    /// immédiates, pas d'être fort dans l'absolu — un passage joué fort ne doit pas
    /// écraser un passage joué doux.
    private static func detrended(_ flux: [Float], secondsPerFrame: Double) -> [Float] {
        guard !flux.isEmpty, secondsPerFrame > 0 else { return flux }
        let half = max(1, Int(trendSeconds / secondsPerFrame))
        var prefix = [Float](repeating: 0, count: flux.count + 1)
        for f in 0..<flux.count { prefix[f + 1] = prefix[f] + flux[f] }
        var out = [Float](repeating: 0, count: flux.count)
        for f in 0..<flux.count {
            let lo = max(0, f - half), hi = min(flux.count - 1, f + half)
            let mean = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
            out[f] = max(0, flux[f] - mean)
        }
        return out
    }

    /// Sommets d'une courbe d'attaque.
    ///
    /// Les candidats sont pris **du plus fort au plus faible**, chacun écartant ses
    /// voisins immédiats : un coup franc l'emporte donc toujours sur la bavure qui
    /// le suit, quel que soit l'ordre du temps.
    private static func peaks(in curve: [Float], secondsPerFrame: Double,
                              refractory: Double) -> [(time: Double, value: Float)] {
        guard curve.count > 2 else { return [] }
        var candidates: [(frame: Int, value: Float)] = []
        for f in 1..<(curve.count - 1)
        where curve[f] > curve[f - 1] && curve[f] >= curve[f + 1] && curve[f] > 0 {
            candidates.append((f, curve[f]))
        }
        guard !candidates.isEmpty else { return [] }

        // Référence : le 90ᵉ centile des sommets, et non le maximum — un seul coup
        // exceptionnel (une cymbale crash) mettrait la barre hors d'atteinte.
        let reference = max(percentile(candidates.map(\.value), 0.9), minimumRise)
        let threshold = max(reference * relativeThreshold, minimumRise)

        let guardFrames = max(1, Int(refractory / secondsPerFrame))
        var taken = [Bool](repeating: false, count: curve.count)
        var kept: [(time: Double, value: Float)] = []
        for candidate in candidates.sorted(by: { $0.value > $1.value }) where candidate.value >= threshold {
            let lo = max(0, candidate.frame - guardFrames)
            let hi = min(curve.count - 1, candidate.frame + guardFrames)
            if (lo...hi).contains(where: { taken[$0] }) { continue }
            taken[candidate.frame] = true
            kept.append((time: time(ofFrame: candidate.frame, in: curve,
                                    secondsPerFrame: secondsPerFrame),
                         value: candidate.value))
        }
        kept.sort { $0.time < $1.time }
        return kept
    }

    /// Instant d'un sommet, affiné par une parabole sur ses deux voisines — la même
    /// façon de faire que pour le tempo et pour l'aimantation du curseur.
    ///
    /// Les trames étant centrées, une trame décrit son propre instant — mais le flux
    /// ne culmine pas quand l'attaque est au milieu de la fenêtre : il culmine quand
    /// elle traverse le flanc le plus raide de la fenêtre de Hann, qui pour un carré
    /// de Hann tombe à un sixième de fenêtre du centre. L'attaque est donc en avance
    /// d'autant sur la trame qui la signale. C'est la seule constante empirique du
    /// fichier, et `PercussionCheck` mesure ce qu'il en reste sur un motif dont les
    /// instants sont connus.
    private static func time(ofFrame f: Int, in curve: [Float],
                             secondsPerFrame: Double) -> Double {
        var position = Double(f)
        if f > 0, f < curve.count - 1 {
            let a = curve[f - 1], b = curve[f], c = curve[f + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 {
                position += Double(min(max(0.5 * (a - c) / denominator, -0.5), 0.5))
            }
        }
        // Une fenêtre dure exactement `hopDivisor` sauts.
        let windowSeconds = Double(hopDivisor) * secondsPerFrame
        // La trame centrée voit déjà l'attaque dans sa moitié droite : elle la
        // signale donc un sixième de fenêtre trop tôt, et non trop tard.
        return max(0, position * secondsPerFrame + windowSeconds / 6)
    }
}
