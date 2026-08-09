import AppKit
import MetalKit
import SwiftUI

/// Hauteur de la réglette du haut, où se dessine et s'attrape la boucle.
let rulerHeight = 20.0

// MARK: - Vue Metal et gestes

/// La vue qui reçoit tout : molette, pincement, clic, clavier. Les coordonnées
/// sont converties une bonne fois en « points depuis le coin haut-gauche », comme
/// dans `Viewport`, pour ne pas avoir à se souvenir ailleurs que les vues AppKit
/// ont l'origine en bas.
final class TimelineMetalView: MTKView {
    var model: AppModel?
    private var tracking: NSTrackingArea?
    /// Instant où a commencé un tracé de boucle, s'il y en a un en cours.
    private var loopAnchor: Double?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    // MARK: Navigation

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        // Le trackpad envoie des deltas précis ; la souris à molette envoie des
        // crans, qu'on amplifie pour que le geste ait le même effet.
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX * (precise ? 1 : 8)
        let dy = event.scrollingDeltaY * (precise ? 1 : 8)
        let flags = event.modifierFlags

        if flags.contains(.shift) {
            model.viewport.zoomFrequency(factor: exp(dy * 0.006), anchorY: p.y,
                                         height: Double(bounds.height))
        } else if flags.contains(.option) || flags.contains(.command) {
            model.viewport.zoomTime(factor: exp(dy * 0.006), anchorX: p.x)
        } else {
            model.viewport.startColumn -= dx * model.viewport.columnsPerPoint
            model.viewport.bottomBin += dy * model.viewport.binsPerPoint
        }
        model.cancelTurn()
        model.clampViewport()
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        let factor = 1 + event.magnification
        if event.modifierFlags.contains(.shift) {
            model.viewport.zoomFrequency(factor: factor, anchorY: p.y,
                                         height: Double(bounds.height))
        } else {
            model.viewport.zoomTime(factor: factor, anchorX: p.x)
        }
        model.cancelTurn()
        model.clampViewport()
    }

    // MARK: Souris

    /// Un glisser dans la réglette du haut — ou avec ⇧ n'importe où — trace la
    /// boucle ; partout ailleurs, il déplace la tête de lecture.
    private func drawsLoop(_ event: NSEvent, at p: CGPoint) -> Bool {
        p.y <= rulerHeight || event.modifierFlags.contains(.shift)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        model.cancelTurn()
        if drawsLoop(event, at: p) {
            loopAnchor = model.time(atPoint: Double(p.x))
            if event.clickCount >= 2 { model.loop = nil; loopAnchor = nil }
        } else {
            model.seek(to: model.time(atPoint: Double(p.x)))
            model.beginProbe(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        model.hover = p
        if let anchor = loopAnchor {
            model.setLoop(from: anchor, to: model.time(atPoint: Double(p.x)))
        } else {
            model.seek(to: model.time(atPoint: Double(p.x)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        loopAnchor = nil
        model?.endProbe()
    }

    override func mouseMoved(with event: NSEvent) {
        model?.hover = location(event)
    }

    override func mouseExited(with event: NSEvent) {
        model?.hover = nil
    }

    // MARK: Clavier

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers {
        case " ": model.togglePlayback()
        case "[": model.setLoopStart(at: model.playhead)
        case "]": model.setLoopEnd(at: model.playhead)
        case "l", "L": model.loopEnabled.toggle()
        case "b", "B": model.snapLoopToBars()
        case "t", "T": model.setDownbeatAtPlayhead()
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            model.seek(to: model.playhead - (shift ? 5 : 1))
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            model.seek(to: model.playhead + (shift ? 5 : 1))
        case "\u{1b}": model.loop = nil
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Pont SwiftUI

struct SpectrogramSurface: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> TimelineMetalView {
        let device = MTLCreateSystemDefaultDevice()
        let view = TimelineMetalView(frame: .zero, device: device)
        view.model = model
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        if let device, let renderer = SpectrogramRenderer(device: device) {
            context.coordinator.renderer = renderer
            model.renderer = renderer
            renderer.layout = model.spectrogram.layout
            if model.spectrogram.columnCount > 0 { renderer.upload(model.spectrogram) }
        }
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TimelineMetalView, context: Context) {
        view.model = model
        context.coordinator.model = model
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var model: AppModel
        var renderer: SpectrogramRenderer?

        init(model: AppModel) { self.model = model }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer else { return }
            model.tick(viewSize: view.bounds.size)
            renderer.viewport = model.viewport
            renderer.display = model.display
            renderer.draw(in: view)
        }
    }
}

// MARK: - Repères dessinés par-dessus

/// Grille métrique, octaves, boucle, tête de lecture, aimantation. Tout est en
/// SwiftUI : ça se redessine tout seul quand la fenêtre visible bouge, et ça évite
/// de mêler du texte au shader.
struct TimelineOverlay: View {
    let model: AppModel

    var body: some View {
        Canvas { context, size in
            guard model.spectrogram.columnCount > 0 else { return }
            drawTempoGrid(&context, size)
            drawOctaves(&context, size)
            drawLoop(&context, size)
            drawRuler(&context, size)
            drawPlayhead(&context, size)
            drawSnap(&context, size)
        }
        .allowsHitTesting(false)
    }

    private func vertical(_ context: inout GraphicsContext, x: Double, from y0: Double,
                          to y1: Double, color: Color, width: Double = 0.5) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: y0))
        line.addLine(to: CGPoint(x: x, y: y1))
        context.stroke(line, with: .color(color), lineWidth: width)
    }

    // MARK: Grille métrique

    /// Mesures, temps, ou subdivisions : la densité suit le zoom, de sorte qu'on
    /// ne voie jamais une bouillie de traits ni une grille absente.
    private func drawTempoGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        guard model.display.showGrid, let tempo = model.tempo, tempo.bpm > 0 else { return }
        let pointsPerBeat = tempo.beatSeconds
            / model.spectrogram.secondsPerColumn / model.viewport.columnsPerPoint
        guard pointsPerBeat > 0.5 else { return }

        let beatsPerBar = Double(max(tempo.beatsPerBar, 1))
        // Pas le plus fin qui reste lisible : subdivisions, temps, ou mesures.
        let subdivision: Double
        if pointsPerBeat >= 120 { subdivision = 0.25 }
        else if pointsPerBeat >= 60 { subdivision = 0.5 }
        else if pointsPerBeat >= 9 { subdivision = 1 }
        else if pointsPerBeat * beatsPerBar >= 7 { subdivision = beatsPerBar }
        else { return }

        let first = (tempo.beat(at: model.time(atPoint: 0)) / subdivision).rounded(.down) * subdivision
        let last = tempo.beat(at: model.time(atPoint: Double(size.width)))
        var beat = first
        while beat <= last {
            defer { beat += subdivision }
            let time = tempo.time(ofBeat: beat)
            guard time >= 0 else { continue }
            let x = model.point(ofTime: time)
            let isBar = abs(beat.truncatingRemainder(dividingBy: beatsPerBar)) < 1e-6
            let isBeat = abs(beat.rounded() - beat) < 1e-6
            let color: Color = isBar ? .white.opacity(0.4)
                : isBeat ? .white.opacity(0.18) : .white.opacity(0.08)
            vertical(&context, x: x, from: rulerHeight, to: Double(size.height),
                     color: color, width: isBar ? 1 : 0.5)
        }

        // Numéros de mesure, tant qu'ils ne se marchent pas dessus.
        let pointsPerBar = pointsPerBeat * beatsPerBar
        guard pointsPerBar >= 44 else { return }
        var bar = (tempo.beat(at: model.time(atPoint: 0)) / beatsPerBar).rounded(.down)
        while tempo.time(ofBeat: bar * beatsPerBar) <= model.time(atPoint: Double(size.width)) {
            defer { bar += 1 }
            let time = tempo.time(ofBeat: bar * beatsPerBar)
            guard time >= 0 else { continue }
            context.draw(Text("\(Int(bar) + 1)")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55)),
                         at: CGPoint(x: model.point(ofTime: time) + 11, y: rulerHeight + 9))
        }
    }

    // MARK: Octaves

    private func drawOctaves(_ context: inout GraphicsContext, _ size: CGSize) {
        guard model.display.showGrid else { return }
        let layout = model.spectrogram.layout
        for marker in Pitch.octaveMarkers(from: layout.minFrequency, to: layout.maxFrequency,
                                          referenceA: model.display.referenceA) {
            let y = model.point(ofFrequency: marker.frequency)
            guard y > rulerHeight + 6, y < Double(size.height) else { continue }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.white.opacity(0.16)), lineWidth: 0.5)
            context.draw(Text(marker.label).font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5)),
                         at: CGPoint(x: 16, y: y - 7))
        }
    }

    // MARK: Boucle

    private func drawLoop(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let loop = model.loop else { return }
        let x0 = model.point(ofTime: loop.lowerBound)
        let x1 = model.point(ofTime: loop.upperBound)
        let active = model.loopEnabled

        // Ce qui est hors de la boucle s'assombrit : on voit d'un coup d'œil ce
        // qui va être joué, sans avoir à lire deux traits.
        let outside = Color.black.opacity(active ? 0.42 : 0.18)
        context.fill(Path(CGRect(x: 0, y: rulerHeight, width: max(x0, 0),
                                 height: Double(size.height) - rulerHeight)), with: .color(outside))
        context.fill(Path(CGRect(x: min(x1, Double(size.width)), y: rulerHeight,
                                 width: max(Double(size.width) - x1, 0),
                                 height: Double(size.height) - rulerHeight)), with: .color(outside))

        let edge = Color.yellow.opacity(active ? 0.9 : 0.4)
        for x in [x0, x1] {
            vertical(&context, x: x, from: 0, to: Double(size.height), color: edge, width: 1)
        }
        context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 0), height: rulerHeight)),
                     with: .color(.yellow.opacity(active ? 0.3 : 0.12)))

        // Longueur du passage, en secondes et — si la grille est là — en mesures.
        var label = AppModel.format(loop.upperBound - loop.lowerBound)
        if let tempo = model.tempo, tempo.barSeconds > 0 {
            let bars = (loop.upperBound - loop.lowerBound) / tempo.barSeconds
            label += String(format: "  ·  %.2g mesures", bars)
        }
        guard x1 - x0 > 90 else { return }
        context.draw(Text(label).font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.black.opacity(0.8)),
                     at: CGPoint(x: (x0 + x1) / 2, y: rulerHeight / 2))
    }

    // MARK: Réglette et tête de lecture

    private func drawRuler(_ context: inout GraphicsContext, _ size: CGSize) {
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerHeight)),
                     with: .color(.black.opacity(0.45)))

        let seconds = model.spectrogram.secondsPerColumn * model.viewport.columnsPerPoint
        let candidates: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = candidates.first { $0 >= seconds * 90 } ?? 600
        var t = (model.time(atPoint: 0) / step).rounded(.down) * step
        let end = model.time(atPoint: Double(size.width))
        while t <= end {
            defer { t += step }
            guard t >= 0 else { continue }
            let x = model.point(ofTime: t)
            vertical(&context, x: x, from: 0, to: rulerHeight, color: .white.opacity(0.3))
            context.draw(Text(AppModel.format(t))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: x + 26, y: rulerHeight / 2))
        }
    }

    private func drawPlayhead(_ context: inout GraphicsContext, _ size: CGSize) {
        let x = model.point(ofTime: model.playhead)
        guard x >= 0, x <= Double(size.width) else { return }
        vertical(&context, x: x, from: 0, to: Double(size.height),
                 color: .white.opacity(0.85), width: 1)
    }

    // MARK: Aimantation

    /// Le curseur ne dit pas ce qu'il y a « sous le pixel » mais quelle raie est la
    /// plus proche — comme un graphique en courbe qui accroche le point de donnée
    /// voisin. Les régions rendues noires par les réglages n'attirent rien.
    private func drawSnap(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let hover = model.hover else { return }
        let text: String
        let anchor: CGPoint

        if let snap = model.snap {
            let x = model.point(ofTime: snap.time)
            let y = model.point(ofFrequency: snap.frequency)
            anchor = CGPoint(x: x, y: y)

            var link = Path()
            link.move(to: hover)
            link.addLine(to: anchor)
            context.stroke(link, with: .color(.white.opacity(0.35)), lineWidth: 0.5)

            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.white.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            let ring = CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9)
            context.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 1.5)

            text = String(format: "%@   %.1f Hz   %@",
                          Pitch.noteName(for: snap.frequency, referenceA: model.display.referenceA),
                          snap.frequency, AppModel.format(snap.time))
        } else {
            // Rien d'assez clair alentour : on retombe sur la lecture brute.
            let frequency = model.frequency(atPoint: Double(hover.y))
            anchor = hover
            var line = Path()
            line.move(to: CGPoint(x: 0, y: hover.y))
            line.addLine(to: CGPoint(x: size.width, y: hover.y))
            context.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            text = String(format: "%.1f Hz   %@", frequency,
                          AppModel.format(model.time(atPoint: Double(hover.x))))
        }

        let resolved = context.resolve(Text(text).font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(.white))
        let measured = resolved.measure(in: size)
        let box = CGRect(x: min(max(anchor.x + 12, 4), size.width - measured.width - 14),
                         y: max(anchor.y - measured.height - 14, rulerHeight + 4),
                         width: measured.width + 10, height: measured.height + 6)
        context.fill(Path(roundedRect: box, cornerRadius: 5),
                     with: .color(.black.opacity(0.6)))
        context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
    }
}
