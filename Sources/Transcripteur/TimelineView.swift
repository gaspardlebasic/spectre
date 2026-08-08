import AppKit
import MetalKit
import SwiftUI

// MARK: - Vue Metal et gestes

/// La vue qui reçoit tout : molette, pincement, clic. Les coordonnées sont
/// converties une bonne fois en « points depuis le coin haut-gauche », comme dans
/// `Viewport`, pour ne pas avoir à se souvenir ailleurs que les vues AppKit ont
/// l'origine en bas.
final class TimelineMetalView: MTKView {
    var model: AppModel?
    private var tracking: NSTrackingArea?

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

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        // Le trackpad envoie des deltas précis ; la souris à molette envoie des
        // crans, qu'on amplifie pour que le geste ait le même effet.
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX * (precise ? 1 : 8)
        let dy = event.scrollingDeltaY * (precise ? 1 : 8)

        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            model.viewport.zoomTime(factor: exp(dy * 0.006), anchorX: p.x)
        } else {
            model.viewport.startColumn -= dx * model.viewport.columnsPerPoint
            model.viewport.bottomBin += dy * model.viewport.binsPerPoint
            if abs(dx) > 0 { model.follow = false }
        }
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
        model.clampViewport()
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        model.follow = false
        model.seek(to: model.time(atPoint: location(event).x))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        model.seek(to: model.time(atPoint: location(event).x))
    }

    override func mouseMoved(with event: NSEvent) {
        model?.hover = location(event)
    }

    override func mouseExited(with event: NSEvent) {
        model?.hover = nil
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        switch event.charactersIgnoringModifiers {
        case " ":
            model.togglePlayback()
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            model.seek(to: model.playhead - (event.modifierFlags.contains(.shift) ? 5 : 1))
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            model.seek(to: model.playhead + (event.modifierFlags.contains(.shift) ? 5 : 1))
        default:
            super.keyDown(with: event)
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

/// Grille des octaves, échelle de temps, tête de lecture et curseur. Tout est en
/// SwiftUI : ça se redessine tout seul quand la fenêtre visible bouge, et ça évite
/// de mêler du texte au shader.
struct TimelineOverlay: View {
    let model: AppModel

    var body: some View {
        Canvas { context, size in
            guard model.spectrogram.columnCount > 0 else { return }
            drawOctaves(&context, size)
            drawTimeRuler(&context, size)
            drawPlayhead(&context, size)
            drawHover(&context, size)
        }
        .allowsHitTesting(false)
    }

    private func drawOctaves(_ context: inout GraphicsContext, _ size: CGSize) {
        let layout = model.spectrogram.layout
        guard model.display.showGrid else { return }
        for marker in Pitch.octaveMarkers(from: layout.minFrequency, to: layout.maxFrequency,
                                          referenceA: model.display.referenceA) {
            let bin = layout.bin(of: marker.frequency)
            let y = model.viewport.point(ofBin: bin, height: Double(size.height))
            guard y > 12, y < Double(size.height) else { continue }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.white.opacity(0.16)), lineWidth: 0.5)
            context.draw(Text(marker.label).font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5)),
                         at: CGPoint(x: 16, y: y - 7))
        }
    }

    private func drawTimeRuler(_ context: inout GraphicsContext, _ size: CGSize) {
        let seconds = model.spectrogram.secondsPerColumn * model.viewport.columnsPerPoint
        // Pas de grille « rond » le plus proche de 90 points.
        let raw = seconds * 90
        let candidates: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = candidates.first { $0 >= raw } ?? 600
        var t = (model.time(atPoint: 0) / step).rounded(.down) * step
        let end = model.time(atPoint: Double(size.width))
        while t <= end {
            defer { t += step }
            guard t >= 0 else { continue }
            let x = model.viewport.point(ofColumn: model.spectrogram.column(atTime: t))
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: 14))
            context.stroke(line, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
            context.draw(Text(AppModel.format(t)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55)),
                         at: CGPoint(x: x + 26, y: 8))
        }
    }

    private func drawPlayhead(_ context: inout GraphicsContext, _ size: CGSize) {
        let x = model.viewport.point(ofColumn: model.spectrogram.column(atTime: model.playhead))
        guard x >= 0, x <= Double(size.width) else { return }
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 1)
    }

    private func drawHover(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let p = model.hover else { return }
        let frequency = model.frequency(atPoint: Double(p.y))
        let name = Pitch.noteName(for: frequency, referenceA: model.display.referenceA)
        let text = String(format: "%@   %.1f Hz   %@", name, frequency,
                          AppModel.format(model.time(atPoint: Double(p.x))))
        var line = Path()
        line.move(to: CGPoint(x: 0, y: p.y))
        line.addLine(to: CGPoint(x: size.width, y: p.y))
        context.stroke(line, with: .color(.white.opacity(0.25)), lineWidth: 0.5)

        let resolved = context.resolve(Text(text).font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(.white))
        let measured = resolved.measure(in: size)
        let box = CGRect(x: min(p.x + 12, size.width - measured.width - 14),
                         y: max(p.y - measured.height - 12, 4),
                         width: measured.width + 10, height: measured.height + 6)
        context.fill(Path(roundedRect: box, cornerRadius: 5),
                     with: .color(.black.opacity(0.55)))
        context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
    }
}
