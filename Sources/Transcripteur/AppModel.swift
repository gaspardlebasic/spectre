import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// État de l'application : le fichier, sa matrice, la fenêtre visible, la lecture.
@Observable final class AppModel {
    private(set) var source: AudioSource?
    private(set) var spectrogram = Spectrogram.empty

    var analysis = AnalysisSettings()
    var display = DisplaySettings()
    var viewport = Viewport()

    /// `var` et non `let` : SwiftUI n'accepte de fabriquer une liaison vers
    /// `player.speed` que si le chemin est modifiable de bout en bout.
    var player = Player()

    /// Position de la tête de lecture, en secondes.
    var playhead: Double = 0
    /// La vue suit-elle la lecture ?
    var follow = true
    /// Position du curseur dans la vue (en points, depuis le coin haut-gauche).
    var hover: CGPoint? {
        didSet { if hover == nil { snap = nil } }
    }
    /// Raie sur laquelle le curseur s'est aimanté.
    var snap: SnapTarget?

    /// Passage joué en boucle.
    var loop: ClosedRange<Double>? { didSet { pushLoop() } }
    var loopEnabled = true { didSet { pushLoop() } }

    /// Grille métrique estimée au chargement, ajustable ensuite.
    var tempo: TempoGrid?

    /// Avancement de l'analyse (0…1), `nil` quand rien n'est en cours.
    var progress: Double?
    var status: String?

    /// Taille de la vue en points, tenue à jour par le rendu.
    @ObservationIgnored var viewSize = CGSize(width: 1200, height: 700)
    @ObservationIgnored weak var renderer: SpectrogramRenderer?
    /// Évite de recadrer une deuxième fois si la vue change de taille après coup.
    @ObservationIgnored private var needsFit = false

    var title: String { source?.name ?? "Transcripteur" }
    var duration: Double { source?.duration ?? 0 }

    // MARK: Ouverture

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Ouvrir"
        panel.message = "Choisir un fichier audio à transcrire"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard progress == nil else { return }
        status = "Lecture du fichier…"
        progress = 0
        player.stop()
        playhead = 0

        let settings = analysis
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            let loaded: AudioSource
            do {
                loaded = try AudioSource.load(url)
            } catch {
                DispatchQueue.main.async {
                    self?.progress = nil
                    self?.status = error.localizedDescription
                }
                return
            }
            DispatchQueue.main.async { self?.status = "Analyse…" }

            let spectrogram = OfflineAnalysis.run(samples: loaded.mono,
                                                  sampleRate: loaded.sampleRate,
                                                  settings: settings) { p in
                DispatchQueue.main.async { self?.progress = p }
            }
            // Le tempo se lit dans la matrice : rien à relire du fichier.
            let grid = TempoEstimator.estimate(spectrogram)
            let elapsed = Date().timeIntervalSince(started)

            DispatchQueue.main.async {
                guard let self else { return }
                self.adopt(source: loaded, spectrogram: spectrogram,
                           tempo: grid, elapsed: elapsed)
            }
        }
    }

    private func adopt(source: AudioSource, spectrogram: Spectrogram,
                       tempo: TempoGrid?, elapsed: TimeInterval) {
        self.source = source
        self.spectrogram = spectrogram
        self.tempo = tempo
        loop = nil
        snap = nil
        progress = nil
        player.load(url: source.url)
        renderer?.layout = spectrogram.layout
        renderer?.upload(spectrogram)
        needsFit = true
        fitIfNeeded()
        let speed = source.duration / max(elapsed, 0.001)
        status = String(format: "%@ — %@, analysé en %.1f s (×%.0f temps réel)",
                        source.name, Self.format(source.duration), elapsed, speed)
    }

    private func fitIfNeeded() {
        guard needsFit, spectrogram.columnCount > 0, viewSize.width > 1 else { return }
        needsFit = false
        viewport = .fitting(columns: spectrogram.columnCount,
                            bins: spectrogram.binCount,
                            size: (Double(viewSize.width), Double(viewSize.height)))
    }

    // MARK: Boucle d'affichage

    /// Appelée à chaque image : synchronise la tête de lecture et fait défiler.
    func tick(viewSize: CGSize) {
        let resized = abs(viewSize.width - self.viewSize.width) > 0.5
            || abs(viewSize.height - self.viewSize.height) > 0.5
        self.viewSize = viewSize
        if needsFit { fitIfNeeded() }

        if player.isPlaying {
            let t = player.currentTime
            if abs(t - playhead) > 1e-4 { playhead = t }
            if follow { scrollToPlayhead() }
            if player.loop == nil, t >= duration - 0.005 { player.pause() }
        }
        if resized { clampViewport() }
        updateSnap()
    }

    private func updateSnap() {
        guard let hover, spectrogram.columnCount > 0 else {
            if snap != nil { snap = nil }
            return
        }
        let found = Snapping.nearest(to: hover, in: spectrogram, viewport: viewport,
                                     display: display, viewSize: viewSize)
        if found != snap { snap = found }
    }

    private func scrollToPlayhead() {
        let width = Double(viewSize.width)
        let x = viewport.point(ofColumn: spectrogram.column(atTime: playhead))
        // Tant que la tête reste dans les deux tiers du milieu, on ne bouge pas :
        // une image qui glisse en permanence est illisible.
        if x > width * 0.75 || x < width * 0.1 {
            viewport.startColumn = spectrogram.column(atTime: playhead) - width * 0.25 * viewport.columnsPerPoint
            clampViewport()
        }
    }

    func clampViewport() {
        guard spectrogram.columnCount > 0 else { return }
        viewport.clamp(columns: spectrogram.columnCount,
                       bins: spectrogram.binCount,
                       size: (Double(viewSize.width), Double(viewSize.height)))
    }

    // MARK: Actions

    func seek(to time: Double) {
        playhead = min(max(time, 0), duration)
        player.seek(to: playhead)
    }

    // MARK: Boucle

    private func pushLoop() {
        player.setLoop(loopEnabled ? loop : nil)
    }

    /// Définit la boucle à partir de deux instants, dans n'importe quel ordre.
    func setLoop(from a: Double, to b: Double) {
        let lo = min(max(min(a, b), 0), duration)
        let hi = min(max(max(a, b), 0), duration)
        loop = hi - lo > 0.05 ? lo...hi : nil
    }

    /// Pose une borne au passage de la tête de lecture, en gardant l'autre.
    func setLoopStart(at time: Double) {
        setLoop(from: time, to: loop.map { max($0.upperBound, time + 0.2) } ?? min(time + 4, duration))
    }

    func setLoopEnd(at time: Double) {
        setLoop(from: loop.map { min($0.lowerBound, time - 0.2) } ?? max(time - 4, 0), to: time)
    }

    /// Cale la boucle sur les mesures qui l'encadrent — c'est presque toujours ce
    /// qu'on veut quand on travaille un passage.
    func snapLoopToBars() {
        guard let loop, let tempo, tempo.barSeconds > 0 else { return }
        let first = (tempo.beat(at: loop.lowerBound) / Double(tempo.beatsPerBar)).rounded(.down)
        let last = (tempo.beat(at: loop.upperBound) / Double(tempo.beatsPerBar)).rounded(.up)
        setLoop(from: tempo.time(ofBeat: first * Double(tempo.beatsPerBar)),
                to: tempo.time(ofBeat: last * Double(tempo.beatsPerBar)))
    }

    // MARK: Tempo

    func scaleTempo(by factor: Double) {
        guard var grid = tempo else { return }
        grid.bpm = min(max(grid.bpm * factor, 20), 400)
        grid.confidence = 0        // ce n'est plus l'estimation, c'est un choix
        tempo = grid
    }

    func nudgeTempo(by delta: Double) {
        guard var grid = tempo else { return }
        grid.bpm = min(max(grid.bpm + delta, 20), 400)
        tempo = grid
    }

    /// Pose le premier temps à l'endroit de la tête de lecture.
    func setDownbeatAtPlayhead() {
        guard var grid = tempo else {
            tempo = TempoGrid(bpm: 120, origin: playhead)
            return
        }
        grid.origin = playhead
        tempo = grid
    }

    var beatsPerBar: Int {
        get { tempo?.beatsPerBar ?? 4 }
        set {
            guard var grid = tempo else { return }
            grid.beatsPerBar = max(1, newValue)
            tempo = grid
        }
    }

    // MARK: Lecture

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            playhead = player.currentTime
        } else {
            player.play(from: playhead)
        }
    }

    /// Fréquence correspondant à une ordonnée de la vue (comptée depuis le haut).
    func frequency(atPoint y: Double) -> Double {
        let bin = viewport.bin(atPoint: y, height: Double(viewSize.height))
        return spectrogram.layout.frequency(atBin: bin)
    }

    func time(atPoint x: Double) -> Double {
        (viewport.column(atPoint: x) + 0.5) * spectrogram.secondsPerColumn
    }

    /// Abscisse d'un instant dans la vue, en points.
    func point(ofTime t: Double) -> Double {
        viewport.point(ofColumn: spectrogram.column(atTime: t))
    }

    /// Ordonnée d'une fréquence dans la vue, en points depuis le haut.
    func point(ofFrequency f: Double) -> Double {
        viewport.point(ofBin: spectrogram.layout.bin(of: f), height: Double(viewSize.height))
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let cents = Int((seconds - Double(total)) * 100)
        return String(format: "%d:%02d,%02d", total / 60, total % 60, cents)
    }
}
