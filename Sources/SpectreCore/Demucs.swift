import Foundation

// Demucs v4, tout ce qui n'est ni le moteur d'inférence ni le disque.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CECI EST DANS LE NOYAU
//
// Séparer un morceau, ce n'est pas seulement appeler un réseau. C'est le découper
// en tranches de taille fixe, recentrer et réduire le signal comme `separate.py`
// le fait, mettre chaque tranche en forme — la forme d'onde **et** son spectre —
// recoller les tranches en fondu enchaîné par une fenêtre triangulaire, et rendre
// le tout à son échelle d'origine.
//
// Rien de tout cela ne dépend d'un système. Ce qui en dépend tient en deux
// phrases : *ouvrir un fichier stéréo à 44,1 kHz* et *exécuter un graphe ONNX*.
// C'est exactement la frontière que `MoteurDemucs` trace.
//
// La première version de ce portage aurait pu récrire la boucle du côté Windows —
// deux cents lignes, faciles à recopier, et une convention à côté suffit pour que
// les deux plateformes séparent la même musique différemment sans que personne ne
// s'en aperçoive avant des mois. C'est la même erreur que le premier portage avait
// faite avec le modèle d'application, à une échelle plus petite.
// ─────────────────────────────────────────────────────────────────────────────

/// Ce que la séparation demande à un moteur d'inférence, et rien de plus.
///
/// Une tranche entre — la forme d'onde et son spectre —, huit voies sortent :
/// quatre sources, deux canaux, en deux morceaux que `Demucs` recolle. Que le
/// calcul passe par CoreML, par DirectML ou par les seuls cœurs ne le regarde pas.
public protocol MoteurDemucs {
    /// - Parameters:
    ///   - mix: `channels × segment` flottants, canal après canal.
    ///   - spec: `channels × bins × frames × 2`, rangé comme PyTorch.
    /// - Returns: `zout` (le spectre masqué) et `xt` (la branche temporelle).
    func appliquer(mix: [Float], spec: [Float]) throws -> (zout: [Float], xt: [Float])
}

public enum Demucs {
    /// Longueur de la tranche, en échantillons : `segment × samplerate` du modèle.
    ///
    /// Le réseau travaille sur une **tranche de taille fixe** — 7,8 s de stéréo à
    /// 44,1 kHz — parce que c'est ainsi qu'il a été entraîné et exporté.
    public static let segment = 343_980
    public static let sampleRate = 44_100.0
    public static let channels = 2
    /// Recouvrement entre tranches voisines, comme dans Demucs.
    public static let overlap = 0.25

    // MARK: - La fenêtre et l'échelle

    /// La fenêtre triangulaire du fondu enchaîné.
    ///
    /// Sans elle, la couture entre deux tranches s'entendrait toutes les 5,8 s.
    public static func transitionWindow() -> [Float] {
        let half = segment / 2
        var window = [Float](repeating: 0, count: segment)
        for i in 0..<half { window[i] = Float(i + 1) }
        for i in half..<segment { window[i] = Float(segment - i) }
        let peak = Float(half)
        for i in 0..<segment { window[i] /= peak }
        return window
    }

    /// Moyenne et écart-type du signal moyenné sur les canaux.
    ///
    /// Sur la moyenne des canaux, comme dans `separate.py` — pas canal par canal, ce
    /// qui déplacerait l'image stéréo.
    ///
    /// Calculés à la main plutôt qu'avec `vDSP_normalize`, dont la variante sans
    /// tampon de sortie n'est pas ce qu'on croit — et en double précision, parce
    /// qu'une somme de dix millions de carrés en simple précision perd ses derniers
    /// chiffres bien avant la fin.
    public static func moments(of mix: [[Float]]) -> (Double, Double) {
        let length = mix.first?.count ?? 0
        guard length > 0, !mix.isEmpty else { return (0, 1) }
        var total = 0.0, totalSquares = 0.0
        for i in 0..<length {
            var averaged = 0.0
            for channel in mix { averaged += Double(channel[i]) }
            averaged /= Double(mix.count)
            total += averaged
            totalSquares += averaged * averaged
        }
        let mean = total / Double(length)
        let variance = max(totalSquares / Double(length) - mean * mean, 0)
        let deviation = variance.squareRoot()
        // Un signal parfaitement plat donnerait un écart-type nul : on ne divise
        // pas par lui.
        return (mean, deviation > 1e-8 ? deviation : 1)
    }

    // MARK: - La séparation

    /// Sépare un morceau déjà chargé, tranche par tranche.
    ///
    /// - Parameters:
    ///   - mix: stéréo à 44,1 kHz, canal par canal. C'est au moteur de plateforme de
    ///     le lire ainsi ; le réseau n'accepte rien d'autre.
    ///   - avancement: appelé depuis le fil de calcul, à chaque tranche finie.
    ///   - annule: consulté entre deux tranches. Fermer un morceau ne doit pas
    ///     attendre la fin d'un calcul devenu inutile.
    public static func separer(_ mix: [[Float]], par moteur: MoteurDemucs,
                               avancement: (SeparationProgress) -> Void,
                               annule: () -> Bool) throws -> SeparatedStems {
        guard let fourier = DemucsFourier() else {
            throw SeparationFailure.engine("transformée de Fourier indisponible")
        }
        var mix = mix
        let length = mix.first?.count ?? 0
        guard length > 0, mix.count == channels else {
            throw SeparationFailure.engine("morceau vide")
        }

        // Demucs travaille sur un signal recentré et réduit, et rend le résultat à
        // la même échelle.
        let (mean, deviation) = moments(of: mix)
        let shift = Float(-mean), scale = Float(1 / deviation)
        for c in 0..<mix.count {
            for i in 0..<length { mix[c][i] = (mix[c][i] + shift) * scale }
        }
        guard mix[0].allSatisfy(\.isFinite) else {
            throw SeparationFailure.engine("signal d'entrée non exploitable")
        }

        let step = Int(Double(segment) * (1 - overlap))
        let starts = Array(stride(from: 0, to: length, by: step))
        let window = transitionWindow()

        // Un accumulateur par piste : le réseau les rend toutes ensemble.
        var sums = Stem.separated.map { _ in
            [[Float]](repeating: [Float](repeating: 0, count: length), count: channels)
        }
        var weights = [Float](repeating: 0, count: length)
        var done = 0.0

        for start in starts {
            if annule() { throw SeparationFailure.cancelled }
            let count = min(segment, length - start)
            let voices = try tranche(mix, from: start, count: count,
                                     fourier: fourier, moteur: moteur)

            // Fondu enchaîné : chaque tranche est pesée par une fenêtre
            // triangulaire, et l'on divise à la fin par la somme des poids.
            for source in Stem.separated.indices {
                for c in 0..<channels {
                    let voice = voices[source * channels + c]
                    sums[source][c].withUnsafeMutableBufferPointer { out in
                        for i in 0..<count { out[start + i] += window[i] * voice[i] }
                    }
                }
            }
            for i in 0..<count { weights[start + i] += window[i] }

            done += 1
            avancement(SeparationProgress(fraction: done / Double(starts.count),
                                          stage: "Séparation des pistes…"))
        }

        var result: [Stem: [[Float]]] = [:]
        for (source, stem) in Stem.separated.enumerated() {
            // Normalisation par les poids et retour à l'échelle d'origine, en un
            // seul passage.
            for c in 0..<channels {
                for i in 0..<length {
                    let w = weights[i]
                    sums[source][c][i] = w > 0
                        ? sums[source][c][i] / w * Float(deviation) + Float(mean) : 0
                }
            }
            // Une piste non finie ne doit jamais atteindre le disque : elle
            // s'écrirait sans bruit, se relirait sans erreur, et ne se verrait
            // qu'au moment où le spectrogramme resterait noir.
            guard sums[source].allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                throw SeparationFailure.engine("piste « \(stem.label) » non finie")
            }
            result[stem] = sums[source]
        }
        // **44,1 kHz, quoi qu'on ait ouvert.** Le réseau a appris là et le chargement
        // y ramène tout ; les pistes rendues n'ont donc pas la fréquence du fichier
        // d'origine, et le dire est le seul moyen qu'elles s'écrivent juste.
        return SeparatedStems(sampleRate: sampleRate, channels: result)
    }

    // MARK: Une tranche

    /// Met une tranche en forme, l'envoie au moteur, et rend ses huit voies —
    /// quatre sources, deux canaux.
    ///
    /// Le graphe ne fait plus les transformées : on lui donne le spectre en même
    /// temps que la forme d'onde — dont sa branche temporelle a besoin — et il rend
    /// le spectre masqué plus cette branche. La transformée inverse et le recollement
    /// des deux branches se font ici.
    private static func tranche(_ mix: [[Float]], from start: Int, count: Int,
                                fourier: DemucsFourier,
                                moteur: MoteurDemucs) throws -> [[Float]] {
        // La tranche est complétée par du silence quand on arrive au bout : le
        // réseau n'accepte qu'une taille, celle sur laquelle il a été figé.
        var flat = [Float](repeating: 0, count: channels * segment)
        for c in 0..<channels {
            mix[c].withUnsafeBufferPointer { source in
                flat.withUnsafeMutableBufferPointer { destination in
                    (destination.baseAddress! + c * segment)
                        .update(from: source.baseAddress! + start, count: count)
                }
            }
        }

        // Le spectre, rangé comme PyTorch : (canal, raie, trame, réel/imaginaire).
        let bins = DemucsFourier.bins
        let frames = DemucsFourier.frames(for: segment)
        let plane = bins * frames
        var spec = [Float](repeating: 0, count: channels * plane * 2)
        for c in 0..<channels {
            let (real, imaginary) = fourier.spectrogram(
                of: Array(flat[c * segment..<(c + 1) * segment]))
            let base = c * plane * 2
            for k in 0..<plane {
                spec[base + k * 2] = real[k]
                spec[base + k * 2 + 1] = imaginary[k]
            }
        }

        let (z, t) = try moteur.appliquer(mix: flat, spec: spec)

        let voices = Stem.separated.count * channels
        guard z.count >= voices * plane * 2, t.count >= voices * segment else {
            throw SeparationFailure.engine("sortie de taille inattendue")
        }

        var real = [Float](repeating: 0, count: plane)
        var imaginary = [Float](repeating: 0, count: plane)
        return (0..<voices).map { v in
            let base = v * plane * 2
            for k in 0..<plane {
                real[k] = z[base + k * 2]
                imaginary[k] = z[base + k * 2 + 1]
            }
            // Les deux branches se rejoignent ici, comme le faisait la dernière
            // ligne du réseau.
            let spectral = fourier.signal(real: real, imaginary: imaginary,
                                          length: segment)
            var voice = [Float](repeating: 0, count: count)
            let offset = v * segment
            for i in 0..<count { voice[i] = spectral[i] + t[offset + i] }
            return voice
        }
    }
}
