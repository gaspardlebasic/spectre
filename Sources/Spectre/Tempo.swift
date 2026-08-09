import Foundation

/// Grille métrique : un tempo, un point de départ, une signature.
struct TempoGrid: Equatable, Codable {
    var bpm: Double
    /// Instant du premier temps fort, en secondes.
    var origin: Double
    var beatsPerBar: Int = 4
    /// Netteté du pic d'autocorrélation retenu, rapportée au reste (1 = rien de
    /// saillant). En dessous de 2 environ, il vaut mieux se méfier de la grille.
    var confidence: Double = 0

    var beatSeconds: Double { 60 / max(bpm, 1) }
    var barSeconds: Double { beatSeconds * Double(beatsPerBar) }

    /// Numéro de temps (fractionnaire) à un instant donné. 0 = le premier temps fort.
    func beat(at time: Double) -> Double { (time - origin) / beatSeconds }
    func time(ofBeat b: Double) -> Double { origin + b * beatSeconds }

    /// Pas de grille le plus fin qui reste lisible à une densité donnée, en temps.
    /// `nil` quand même les mesures se marcheraient dessus.
    ///
    /// Une seule définition sert au tracé *et* à l'aimantation de la boucle : ce
    /// sur quoi les bornes se posent est exactement ce qu'on voit à l'écran.
    func unit(pointsPerBeat: Double) -> Double? {
        let bar = Double(max(beatsPerBar, 1))
        if pointsPerBeat >= 120 { return 0.25 }
        if pointsPerBeat >= 60 { return 0.5 }
        if pointsPerBeat >= 9 { return 1 }
        if pointsPerBeat * bar >= 7 { return bar }
        return nil
    }

    /// Instant le plus proche sur une grille de pas donné.
    func snap(_ time: Double, unit: Double) -> Double {
        guard unit > 0 else { return time }
        return self.time(ofBeat: (beat(at: time) / unit).rounded() * unit)
    }
}

/// Estimation du tempo à partir du spectrogramme déjà calculé.
///
/// Rien de nouveau n'est lu du fichier : la matrice contient tout ce qu'il faut.
/// Le flux spectral — somme des montées de niveau d'une colonne à la suivante —
/// donne une courbe qui pique à chaque attaque ; son autocorrélation donne la
/// période, et une recherche de phase donne l'endroit où poser le premier temps.
enum TempoEstimator {
    static let minBPM = 50.0
    static let maxBPM = 200.0

    /// Les niveaux sont plafonnés par le bas : sans ça, le silence numérique
    /// (−200 dB) produirait des montées de 150 dB au moindre souffle.
    private static let floorDb: Float = -90

    /// Courbe d'attaque : pour chaque colonne, ce qui a *monté* depuis la
    /// précédente. Seules les montées comptent — une note qui s'éteint n'est pas
    /// un évènement rythmique.
    static func onsetEnvelope(_ s: Spectrogram) -> [Float] {
        guard s.columnCount > 1, s.binCount > 0 else { return [] }
        var flux = [Float](repeating: 0, count: s.columnCount)
        s.values.withUnsafeBufferPointer { v in
            for c in 1..<s.columnCount {
                let cur = c * s.binCount, prev = cur - s.binCount
                var sum: Float = 0
                for i in 0..<s.binCount {
                    let d = max(v[cur + i], floorDb) - max(v[prev + i], floorDb)
                    if d > 0 { sum += d }
                }
                flux[c] = sum
            }
        }

        // On retranche la tendance locale : ce qui compte est de dépasser ses
        // voisines immédiates, pas d'être fort dans l'absolu (un passage joué
        // fort ne doit pas écraser un passage joué doux).
        let half = max(1, Int(0.35 / s.secondsPerColumn))
        var prefix = [Float](repeating: 0, count: flux.count + 1)
        for c in 0..<flux.count { prefix[c + 1] = prefix[c] + flux[c] }

        var envelope = [Float](repeating: 0, count: flux.count)
        for c in 0..<flux.count {
            let lo = max(0, c - half), hi = min(flux.count - 1, c + half)
            let mean = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
            envelope[c] = max(0, flux[c] - mean)
        }
        return envelope
    }

    /// Énergie captée par un train d'impulsions régulier.
    ///
    /// La période est fractionnaire et une attaque dure quelques colonnes : lire
    /// une seule colonne raterait le sommet une fois sur deux, et l'écart entre
    /// deux phases voisines se noierait dans cette erreur d'échantillonnage. On
    /// prend donc le maximum d'un petit voisinage.
    private static func pulseScore(_ envelope: [Float], from start: Double,
                                   every period: Double, tolerance: Int = 2) -> Double {
        guard period > 0 else { return 0 }
        var total = 0.0
        var position = start
        while position < Double(envelope.count) {
            let centre = Int(position.rounded())
            let lo = max(0, centre - tolerance), hi = min(envelope.count - 1, centre + tolerance)
            if lo <= hi {
                var peak: Float = 0
                for k in lo...hi { peak = max(peak, envelope[k]) }
                total += Double(peak)
            }
            position += period
        }
        return total
    }

    static func estimate(_ s: Spectrogram, beatsPerBar: Int = 4) -> TempoGrid? {
        let envelope = onsetEnvelope(s)
        guard envelope.count > 32 else { return nil }
        let hop = s.secondsPerColumn
        let minLag = max(2, Int((60 / maxBPM / hop).rounded()))
        let maxLag = min(envelope.count / 2, Int((60 / minBPM / hop).rounded()))
        guard maxLag > minLag else { return nil }

        // Autocorrélation, pondérée par un a priori centré sur 120 BPM : sans lui
        // l'estimation choisit volontiers la moitié ou le double du bon tempo,
        // qui corrèlent presque aussi bien.
        var best = minLag
        var bestScore = -Double.infinity
        var scores = [Double](repeating: 0, count: maxLag + 1)
        var correlations = [Double](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var sum = 0.0
            for c in 0..<(envelope.count - lag) {
                sum += Double(envelope[c]) * Double(envelope[c + lag])
            }
            let r = sum / Double(envelope.count - lag)
            correlations[lag] = r
            let bpm = 60 / (Double(lag) * hop)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            scores[lag] = r * prior
            if scores[lag] > bestScore { bestScore = scores[lag]; best = lag }
        }

        // Affinage sous-colonne par une parabole sur les trois points du sommet.
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let a = correlations[best - 1], b = correlations[best], c = correlations[best + 1]
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 {
                lag += min(max(0.5 * (a - c) / denominator, -0.5), 0.5)
            }
        }
        guard lag * hop > 0 else { return nil }

        // Le tempo est **arrondi à l'entier**. L'affinage sous-colonne ci-dessus
        // donne des valeurs comme 123,4 BPM : une précision que la mesure n'a pas
        // vraiment, et qui se lit comme une certitude. La quasi-totalité des
        // morceaux est jouée sur un tempo rond ; on propose donc l'entier, et le
        // pas de 0,1 BPM de la barre reste là pour rattraper les cas où il faut.
        let bpm = max((60 / (lag * hop)).rounded(), 1)
        // La phase est ensuite cherchée avec la période **arrondie** — celle qu'on
        // va réellement dessiner. L'optimiser pour une autre laisserait la grille
        // décalée dès la première mesure.
        lag = 60 / (bpm * hop)

        // Phase : on essaie chaque décalage possible et on garde celui où les
        // temps tombent sur le plus d'énergie d'attaque.
        var bestPhase = 0.0
        var bestPhaseScore = -Double.infinity
        let steps = max(1, Int(lag.rounded()))
        for step in 0..<steps {
            let score = pulseScore(envelope, from: Double(step), every: lag)
            if score > bestPhaseScore { bestPhaseScore = score; bestPhase = Double(step) }
        }

        // Temps fort : parmi les `beatsPerBar` façons de placer le « un », celle
        // dont les temps forts portent le plus d'énergie.
        var bestDownbeat = 0
        var bestDownbeatScore = -Double.infinity
        for j in 0..<max(beatsPerBar, 1) {
            let score = pulseScore(envelope, from: bestPhase + Double(j) * lag,
                                   every: lag * Double(beatsPerBar))
            if score > bestDownbeatScore { bestDownbeatScore = score; bestDownbeat = j }
        }

        let mean = correlations[minLag...maxLag].reduce(0, +) / Double(maxLag - minLag + 1)
        let confidence = mean > 0 ? correlations[best] / mean : 0

        return TempoGrid(bpm: bpm,
                         origin: (bestPhase + Double(bestDownbeat) * lag) * hop,
                         beatsPerBar: beatsPerBar,
                         confidence: confidence)
    }
}
