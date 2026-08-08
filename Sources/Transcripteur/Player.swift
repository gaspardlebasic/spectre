import AVFoundation
import Foundation
import Observation

/// Lecture du fichier, avec ralenti et transposition indépendants.
///
/// `AVAudioUnitTimePitch` est l'unité fournie par le système : correcte jusqu'à
/// la moitié de la vitesse, métallique en dessous. Elle est ici pour que la chaîne
/// soit complète ; le jour où la qualité devient le sujet, c'est le seul nœud à
/// remplacer — rien d'autre dans l'application ne dépend de la vitesse de lecture,
/// puisque l'analyse porte sur le fichier d'origine.
@Observable final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var fileSampleRate: Double = 44100
    /// Instant d'où part la lecture programmée : l'horloge du nœud repart de zéro
    /// à chaque `stop()`, on lui rajoute donc l'origine du segment.
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var pausedAt: Double = 0

    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    var message: String?

    /// Vitesse de lecture (1 = normale), hauteur inchangée.
    var speed: Double = 1 {
        didSet { timePitch.rate = Float(min(max(speed, 1.0 / 32), 4)) }
    }

    /// Transposition, en demi-tons (fractionnaire : sert aussi à recaler un
    /// enregistrement désaccordé).
    var transpose: Double = 0 {
        didSet { timePitch.pitch = Float(min(max(transpose, -24), 24) * 100) }
    }

    var volume: Double = 1 {
        didSet { node.volume = Float(min(max(volume, 0), 1)) }
    }

    init() {
        engine.attach(node)
        engine.attach(timePitch)
    }

    func load(url: URL) {
        stop()
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            fileSampleRate = f.processingFormat.sampleRate
            duration = Double(f.length) / fileSampleRate
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: f.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: f.processingFormat)
            engine.prepare()
            pausedAt = 0
            segmentStart = 0
        } catch {
            file = nil
            duration = 0
            message = "Lecture impossible : \(error.localizedDescription)"
        }
    }

    /// Boucle en cours, en secondes. La lecture y reste tant qu'elle est posée.
    private(set) var loop: ClosedRange<Double>?
    /// Longueur du premier segment joué, du point de départ à la fin de la boucle.
    @ObservationIgnored private var firstSegment: Double = 0
    /// Tours déjà programmés et pas encore consommés.
    @ObservationIgnored private var scheduledLaps = 0
    /// Nombre de tours maintenus d'avance dans la file du nœud.
    private static let lapsAhead = 3

    /// Position de lecture, en secondes depuis le début du fichier.
    ///
    /// L'horloge du nœud compte les images qu'il a fournies depuis son démarrage.
    /// En boucle, il en fournit bien plus que la durée du passage : on replie donc
    /// le temps écoulé sur la longueur de la boucle, ce qui donne une position
    /// juste sans jamais interroger la file de lecture.
    var currentTime: Double {
        guard isPlaying,
              let render = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: render),
              played.sampleRate > 0
        else { return pausedAt }
        let elapsed = Double(played.sampleTime) / played.sampleRate

        if let loop, loop.upperBound > loop.lowerBound {
            if elapsed < firstSegment { return segmentStart + elapsed }
            let length = loop.upperBound - loop.lowerBound
            let into = (elapsed - firstSegment).truncatingRemainder(dividingBy: length)
            return loop.lowerBound + into
        }
        return min(max(segmentStart + elapsed, 0), duration)
    }

    /// Pose ou retire la boucle. Si on est en train de lire, la file est refaite
    /// immédiatement — sans quoi le changement n'aurait d'effet qu'au tour suivant.
    func setLoop(_ range: ClosedRange<Double>?) {
        let cleaned = range.flatMap { r -> ClosedRange<Double>? in
            let lo = min(max(r.lowerBound, 0), duration)
            let hi = min(max(r.upperBound, 0), duration)
            return hi - lo > 0.05 ? lo...hi : nil
        }
        guard cleaned != loop else { return }
        loop = cleaned
        if isPlaying { play(from: currentTime) }
    }

    func play(from time: Double? = nil) {
        guard let file else { return }
        var start = min(max(time ?? pausedAt, 0), max(duration - 0.01, 0))
        // Lancer la lecture hors de la boucle n'aurait aucun sens : on rentre.
        if let loop, !loop.contains(start) { start = loop.lowerBound }
        let frame = AVAudioFramePosition(start * fileSampleRate)
        guard frame < file.length else { return }

        node.stop()                       // remet l'horloge du nœud à zéro
        if !engine.isRunning {
            do { try engine.start() } catch {
                message = "Moteur audio indisponible : \(error.localizedDescription)"
                return
            }
        }
        segmentStart = start
        scheduledLaps = 0

        if let loop {
            let end = AVAudioFramePosition(loop.upperBound * fileSampleRate)
            firstSegment = loop.upperBound - start
            node.scheduleSegment(file, startingFrame: frame,
                                 frameCount: AVAudioFrameCount(max(end - frame, 1)), at: nil)
            for _ in 0..<Self.lapsAhead { scheduleLap() }
        } else {
            firstSegment = .infinity
            node.scheduleSegment(file, startingFrame: frame,
                                 frameCount: AVAudioFrameCount(file.length - frame), at: nil)
        }
        node.play()
        isPlaying = true
    }

    /// Programme un tour de boucle de plus. Les segments s'enchaînent dans la file
    /// du nœud : la reprise est sans trou, contrairement à un repositionnement
    /// déclenché à l'arrivée sur la fin.
    private func scheduleLap() {
        guard let file, let loop else { return }
        let from = AVAudioFramePosition(loop.lowerBound * fileSampleRate)
        let to = AVAudioFramePosition(loop.upperBound * fileSampleRate)
        guard to > from else { return }
        scheduledLaps += 1
        node.scheduleSegment(file, startingFrame: from,
                             frameCount: AVAudioFrameCount(to - from), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying, self.loop != nil else { return }
                self.scheduledLaps -= 1
                while self.scheduledLaps < Self.lapsAhead { self.scheduleLap() }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        node.stop()
        isPlaying = false
    }

    func stop() {
        pausedAt = isPlaying ? currentTime : pausedAt
        node.stop()
        engine.stop()
        isPlaying = false
    }

    func toggle(at time: Double) {
        if isPlaying { pause() } else { play(from: time) }
    }

    /// Déplace la tête de lecture, en poursuivant si on était en train de lire.
    func seek(to time: Double) {
        let wasPlaying = isPlaying
        pausedAt = min(max(time, 0), duration)
        if wasPlaying {
            play(from: pausedAt)
        } else {
            node.stop()
            isPlaying = false
        }
    }
}
