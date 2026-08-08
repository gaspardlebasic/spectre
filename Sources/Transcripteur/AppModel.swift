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
    var hover: CGPoint?

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
            let elapsed = Date().timeIntervalSince(started)

            DispatchQueue.main.async {
                guard let self else { return }
                self.adopt(source: loaded, spectrogram: spectrogram, elapsed: elapsed)
            }
        }
    }

    private func adopt(source: AudioSource, spectrogram: Spectrogram, elapsed: TimeInterval) {
        self.source = source
        self.spectrogram = spectrogram
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
            if t >= duration - 0.005 { player.pause() }
        }
        if resized { clampViewport() }
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

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let cents = Int((seconds - Double(total)) * 100)
        return String(format: "%d:%02d,%02d", total / 60, total % 60, cents)
    }
}
