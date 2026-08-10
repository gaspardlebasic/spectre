import Foundation

/// La logique de lecture, sans carte son : où en est la tête, quels échantillons
/// sortent, et comment la boucle repart.
///
/// Sur macOS, `AVAudioPlayerNode` rend ces trois services — on lui empile des
/// segments, on l'interroge sur son horloge, il enchaîne sans trou. Rien de tel
/// ailleurs : quand on tient soi-même le rappel de rendu, il faut décider quels
/// échantillons remplir et compter le temps soi-même.
///
/// D'où cette chaîne, qui est **la même sur les deux plateformes** et n'a besoin
/// d'aucune d'elles : elle tire ses échantillons d'un tampon déjà décodé et les
/// rend filtrés. Ne reste à la plateforme que d'ouvrir un périphérique et
/// d'appeler `render` — quelques dizaines de lignes, là où toute la difficulté
/// était.
///
/// La position est **calculée depuis les échantillons rendus**, jamais depuis une
/// horloge murale : c'est ce qui la garde exacte quand le périphérique prend du
/// retard, et ce qui la rend vérifiable hors ligne.
public struct PlaybackChain {
    /// Le morceau, en mono ou entrelacé selon ce que l'appelant fournit.
    private var samples: [Float]
    private let channels: Int
    public let sampleRate: Double

    private var band: BandFilter
    /// Position de lecture, en images, sur le fichier d'origine.
    private var position: Double = 0

    public private(set) var loop: ClosedRange<Double>?
    public var volume: Float = 1

    public init(samples: [Float], channels: Int = 1, sampleRate: Double) {
        self.samples = samples
        self.channels = max(channels, 1)
        self.sampleRate = max(sampleRate, 1)
        self.band = BandFilter(sampleRate: max(sampleRate, 1))
    }

    public var frameCount: Int { samples.count / channels }
    public var duration: Double { Double(frameCount) / sampleRate }

    /// Instant courant, en secondes.
    public var currentTime: Double {
        get { position / sampleRate }
        set { position = min(max(newValue, 0), duration) * sampleRate }
    }

    public mutating func setBand(_ range: ClosedRange<Double>?) {
        band.setBand(range)
    }

    /// Pose ou retire la boucle. Les règles sont celles de la version macOS : une
    /// boucle plus courte que 50 ms n'en est pas une, et lire hors de la boucle
    /// n'aurait aucun sens — on y rentre.
    public mutating func setLoop(_ range: ClosedRange<Double>?) {
        let nettoyée = range.flatMap { r -> ClosedRange<Double>? in
            let lo = min(max(r.lowerBound, 0), duration)
            let hi = min(max(r.upperBound, 0), duration)
            return hi - lo > LoopEditing.minimumLength ? lo...hi : nil
        }
        loop = nettoyée
        if let nettoyée, !nettoyée.contains(currentTime) {
            currentTime = nettoyée.lowerBound
        }
    }

    /// Remplit `output` (entrelacé, `outputChannels` canaux) et avance la tête.
    ///
    /// - Returns: le nombre d'images réellement produites. Moins que demandé
    ///   signifie qu'on a atteint la fin du morceau — hors boucle, où l'on ne
    ///   l'atteint jamais.
    ///
    /// La boucle est prise **au fil du remplissage**, pas au tour suivant : un
    /// bloc peut chevaucher la fin de la boucle, et il repart alors à son début
    /// dans le même bloc. C'est ce qui rend la reprise sans trou, là où un
    /// repositionnement déclenché à l'arrivée sur la fin laisserait un silence de
    /// la durée d'un tampon.
    @discardableResult
    public mutating func render(into output: UnsafeMutableBufferPointer<Float>,
                                frames: Int, outputChannels: Int = 2) -> Int {
        let total = frameCount
        guard total > 0 else {
            for i in 0..<min(output.count, frames * outputChannels) { output[i] = 0 }
            return 0
        }

        // Bornes de lecture : la boucle si elle est posée, sinon tout le fichier.
        let première = loop.map { Int($0.lowerBound * sampleRate) } ?? 0
        let dernière = loop.map { Int($0.upperBound * sampleRate) } ?? total
        let fin = min(max(dernière, première + 1), total)

        var produites = 0
        while produites < frames {
            var index = Int(position)
            if index >= fin {
                guard loop != nil else { break }
                index = première
                position = Double(première)
            }
            if index < première { index = première; position = Double(première) }

            // Une seule voie mono suffit : l'analyse et l'écoute portent sur le
            // même signal, et la stéréo ne se rejoue pas à l'envers d'un filtre.
            var v: Float = 0
            for c in 0..<channels { v += samples[index * channels + c] }
            v /= Float(channels)
            v = band.process(v) * volume

            let base = produites * outputChannels
            for c in 0..<outputChannels where base + c < output.count {
                output[base + c] = v
            }
            position += 1
            produites += 1
        }

        // Le reste du tampon est mis à zéro : un périphérique à qui l'on rend
        // moins que demandé rejoue sinon le bloc précédent, ce qui s'entend.
        for i in (produites * outputChannels)..<min(output.count, frames * outputChannels) {
            output[i] = 0
        }
        return produites
    }

    /// Remet les filtres à zéro. À appeler sur un saut : les mémoires d'un biquad
    /// portent le signal d'avant, et les relire ailleurs produit un claquement.
    public mutating func seek(to time: Double) {
        currentTime = time
        band.reset()
    }
}
