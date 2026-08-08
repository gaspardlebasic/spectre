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

    /// Position de lecture, en secondes depuis le début du fichier.
    var currentTime: Double {
        guard isPlaying,
              let render = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: render),
              played.sampleRate > 0
        else { return pausedAt }
        let elapsed = Double(played.sampleTime) / played.sampleRate
        return min(max(segmentStart + elapsed, 0), duration)
    }

    func play(from time: Double? = nil) {
        guard let file else { return }
        let start = min(max(time ?? pausedAt, 0), max(duration - 0.01, 0))
        let frame = AVAudioFramePosition(start * fileSampleRate)
        let remaining = AVAudioFrameCount(max(file.length - frame, 0))
        guard remaining > 0 else { return }

        node.stop()                       // remet l'horloge du nœud à zéro
        if !engine.isRunning {
            do { try engine.start() } catch {
                message = "Moteur audio indisponible : \(error.localizedDescription)"
                return
            }
        }
        segmentStart = start
        node.scheduleSegment(file, startingFrame: frame, frameCount: remaining, at: nil)
        node.play()
        isPlaying = true
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
