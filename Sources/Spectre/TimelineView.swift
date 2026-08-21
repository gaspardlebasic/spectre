import AppKit
import MetalKit
import SpectreCore
import SpectreModele
import SpectreMac
import SwiftUI

/// Hauteur de la réglette du haut, où se dessine et s'attrape la boucle.
let rulerHeight = 20.0

// MARK: - Les gestes, partagés

/// Navigation et tracé de boucle, écrits une fois pour les deux vues qui les portent.
///
/// L'image et la ligne de batterie montrent **le même axe des temps** ; il n'y a
/// aucune raison qu'un pincement marche sur l'une et pas sur l'autre — c'est la même
/// musique, regardée un pouce plus bas. Seul l'axe vertical diffère : l'image porte
/// les fréquences, la ligne de batterie porte trois voies. Là où il n'y a pas de
/// fréquences, le zoom vertical s'ancre au milieu de l'image plutôt que sous un
/// curseur qui ne désigne rien.
enum TimelineGestures {
    /// - Parameter anchorY: l'ordonnée sous le curseur, ou `nil` quand la vue n'a pas
    ///   d'axe des fréquences.
    static func scroll(_ event: NSEvent, x: Double, anchorY: Double?, model: AppModel) {
        // Le trackpad envoie des deltas précis ; la souris à molette envoie des
        // crans, qu'on amplifie pour que le geste ait le même effet.
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX * (precise ? 1 : 8)
        let dy = event.scrollingDeltaY * (precise ? 1 : 8)
        let flags = event.modifierFlags
        let height = max(Double(model.viewSize.height), 1)

        if flags.contains(.shift) {
            model.viewport.zoomFrequency(factor: exp(dy * 0.006),
                                         anchorY: anchorY ?? height / 2, height: height)
        } else if flags.contains(.option) || flags.contains(.command) {
            model.viewport.zoomTime(factor: exp(dy * 0.006), anchorX: x)
        } else {
            model.viewport.startColumn -= dx * model.viewport.columnsPerPoint
            model.viewport.bottomBin += dy * model.viewport.binsPerPoint
        }
        model.cancelTurn()
        model.clampViewport()
    }

    static func magnify(_ event: NSEvent, x: Double, anchorY: Double?, model: AppModel) {
        let factor = 1 + event.magnification
        let height = max(Double(model.viewSize.height), 1)
        if event.modifierFlags.contains(.shift) {
            model.viewport.zoomFrequency(factor: factor,
                                         anchorY: anchorY ?? height / 2, height: height)
        } else {
            model.viewport.zoomTime(factor: factor, anchorX: x)
        }
        model.cancelTurn()
        model.clampViewport()
    }
}

// MARK: - Vue Metal et gestes

/// La vue qui reçoit tout : molette, pincement, clic, clavier. Les coordonnées
/// sont converties une bonne fois en « points depuis le coin haut-gauche », comme
/// dans `Viewport`, pour ne pas avoir à se souvenir ailleurs que les vues AppKit
/// ont l'origine en bas.
final class TimelineMetalView: MTKView {
    var model: AppModel?
    private var tracking: NSTrackingArea?
    private var clock: CADisplayLink?
    /// Ce que le glisser en cours est en train de faire à la boucle.
    private enum LoopDrag {
        case creating(anchor: Double)
        case moving(grab: Double)          // écart entre le clic et le début
        case resizing(LoopEdge)
    }
    private var loopDrag: LoopDrag?
    /// Tolérance, en points, pour attraper une borne plutôt que le corps.
    private let edgeGrab = 7.0

    override var acceptsFirstResponder: Bool { true }

    /// Le rendu est cadencé à la main plutôt que laissé à `MTKView`.
    ///
    /// La boucle interne de `MTKView` ne programme son dessin que dans le mode
    /// **par défaut** de la boucle d'exécution. Or macOS bascule en
    /// `NSEventTrackingRunLoopMode` pendant un geste au trackpad : le
    /// spectrogramme se figeait donc tant que les doigts bougeaient, alors que les
    /// repères SwiftUI, repeints par une autre voie, suivaient. Une horloge
    /// d'affichage inscrite dans les modes communs dessine dans les deux.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock?.invalidate()
        guard window != nil else { clock = nil; return }
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        clock = link
    }

    /// Ce dont l'image dépend. Tant que rien de tout cela ne bouge, le dessin
    /// serait pixel pour pixel le même : le calque garde ce qu'il montre déjà, et
    /// le GPU se tait. C'est tout le sujet de la lecture au repos — la tête de
    /// lecture avance, mais elle est peinte ailleurs, dans son propre calque.
    private struct RenderKey: Equatable {
        var viewport: Viewport
        var display: DisplaySettings
        var hueOrigin: Int
        var generation: Int
        var size: CGSize
    }
    private var drawn: RenderKey?
    private var wasVisible = true

    @objc private func step() {
        guard let model else { return }
        model.tick(viewSize: bounds.size)

        // Fenêtre masquée ou entièrement recouverte : le son continue, l'image
        // n'a personne pour la regarder. Le retour au premier plan repart d'un
        // dessin complet, le système ayant pu jeter le contenu du calque.
        let visible = window?.occlusionState.contains(.visible) ?? false
        defer { wasVisible = visible }
        guard visible else { return }
        if !wasVisible { drawn = nil }

        let key = RenderKey(viewport: model.viewport, display: model.display,
                            hueOrigin: Preferences.shared.hueOrigin,
                            generation: model.renderer?.generation ?? 0,
                            size: drawableSize)
        guard key != drawn else { return }
        drawn = key
        draw()
    }

    deinit { clock?.invalidate() }

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
        TimelineGestures.scroll(event, x: Double(p.x), anchorY: Double(p.y), model: model)
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        TimelineGestures.magnify(event, x: Double(p.x), anchorY: Double(p.y), model: model)
    }

    // MARK: Souris

    /// Un glisser dans la réglette du haut — ou avec ⇧ n'importe où — trace la
    /// boucle ; partout ailleurs, il déplace la tête de lecture et fait sonner la
    /// raie désignée.
    private func drawsLoop(_ event: NSEvent, at p: CGPoint) -> Bool {
        p.y <= rulerHeight || event.modifierFlags.contains(.shift)
    }

    /// Ce qu'un clic à cet endroit ferait à la boucle existante : rien, la
    /// déplacer, ou tirer l'une de ses bornes.
    private func grab(at p: CGPoint) -> LoopDrag? {
        guard let model, let loop = model.loop, p.y <= rulerHeight else { return nil }
        let x0 = model.point(ofTime: loop.lowerBound)
        let x1 = model.point(ofTime: loop.upperBound)
        if abs(Double(p.x) - x0) <= edgeGrab { return .resizing(.start) }
        if abs(Double(p.x) - x1) <= edgeGrab { return .resizing(.end) }
        if Double(p.x) > x0, Double(p.x) < x1 {
            return .moving(grab: model.time(atPoint: Double(p.x)) - loop.lowerBound)
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        model.cancelTurn()
        if event.clickCount >= 2, p.y <= rulerHeight {
            model.loop = nil
            loopDrag = nil
            return
        }
        if drawsLoop(event, at: p) {
            // Une boucle déjà posée s'attrape : par le corps pour la déplacer, par
            // un bord pour l'étendre. Ailleurs, le glisser en trace une nouvelle.
            loopDrag = grab(at: p) ?? .creating(anchor: model.time(atPoint: Double(p.x)))
        } else {
            model.seek(to: model.time(atPoint: Double(p.x)))
            model.beginProbe(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let p = location(event)
        model.hover = p
        // ⌘ enfoncé pendant le geste libère les bornes de la grille.
        let snapping = !event.modifierFlags.contains(.command)
        let time = model.time(atPoint: Double(p.x))
        switch loopDrag {
        case .creating(let anchor):
            model.setLoop(from: anchor, to: time, snapping: snapping)
        case .moving(let grab):
            model.moveLoop(startingAt: time - grab, snapping: snapping)
        case .resizing(let edge):
            model.dragLoop(edge: edge, to: time, snapping: snapping)
        case nil:
            model.seek(to: time)
        }
    }

    override func mouseUp(with event: NSEvent) {
        loopDrag = nil
        model?.endProbe()
        cursor(at: location(event))
    }

    override func mouseMoved(with event: NSEvent) {
        // Les commandes flottantes sont posées sur l'image, et la zone de suivi
        // continue de recevoir les mouvements qui les survolent. Sans ce garde-fou,
        // viser un bouton ferait afficher par-dessous la note et la fréquence du
        // point qu'il cache.
        guard model?.pointerOverControls != true else { return }
        let p = location(event)
        model?.hover = p
        cursor(at: p)
    }

    /// Le curseur annonce ce qui va se passer : sans cela, rien ne laisse deviner
    /// qu'une boucle posée se rattrape.
    private func cursor(at p: CGPoint) {
        switch grab(at: p) {
        case .resizing: NSCursor.resizeLeftRight.set()
        case .moving: NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        model?.hover = nil
        NSCursor.arrow.set()
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
        case "1": model.setDownbeatAtPlayhead()
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
        view.isPaused = true
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
            renderer.viewport = model.viewport
            renderer.display = model.display
            renderer.hueOrigin = Preferences.shared.hueOrigin
            renderer.draw(in: view)
        }
    }
}

// MARK: - Tête de lecture

/// La tête de lecture, seule, dans son propre calque.
///
/// Elle avance à chaque image pendant la lecture, et **tout ce qui partage son
/// dessin se refait avec elle**. Tant qu'elle était un trait du canevas des
/// repères, jouer un morceau sans toucher à rien refaisait cent vingt fois par
/// seconde la grille, les accords et leurs textes — pour déplacer un trait d'un
/// pixel. Ici, c'est un rectangle qu'on décale : le compositeur s'en charge.
struct PlayheadLine: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let x = model.point(ofTime: model.playhead)
            if x >= 0, x <= Double(geometry.size.width) {
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 1, height: geometry.size.height)
                    .offset(x: x)
            }
        }
        .allowsHitTesting(false)
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
            drawChords(&context, size)
            drawChordNotes(&context, size)
            drawLoop(&context, size)
            drawRuler(&context, size)
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
        // Le pas est celui du modèle : ce qu'on dessine est exactement ce sur quoi
        // la boucle s'aimante.
        guard let subdivision = model.gridUnit else { return }

        let first = (tempo.beat(at: model.time(atPoint: 0)) / subdivision).rounded(.down) * subdivision
        let last = tempo.beat(at: model.time(atPoint: Double(size.width)))
        var beat = first
        while beat <= last {
            defer { beat += subdivision }
            let time = tempo.time(ofBeat: beat)
            guard time >= 0 else { continue }
            let x = model.point(ofTime: time)
            // Quatre degrés de clarté pour quatre degrés de découpage. La phrase est
            // le seul trait qu'on lise encore quand on regarde le morceau entier ;
            // zoomé, elle donne le « un » de chaque groupe de quatre mesures, qu'on
            // cherchait jusqu'ici en comptant.
            let isPhrase = tempo.opensPhrase(beat)
            let isBar = tempo.opensBar(beat)
            let isBeat = abs(beat.rounded() - beat) < 1e-6
            let color: Color = isPhrase ? .white.opacity(0.38)
                : isBar ? .white.opacity(0.24)
                : isBeat ? .white.opacity(0.11) : .white.opacity(0.05)
            vertical(&context, x: x, from: rulerHeight, to: Double(size.height),
                     color: color, width: isBar ? 0.75 : 0.5)
        }

        // Numéros de mesure : toutes tant qu'elles ont la place, sinon une par
        // phrase. Une grille sans un seul numéro ne dit plus où l'on est, et c'est
        // précisément dézoomé qu'on se le demande. Le second seuil est plus bas que
        // le premier parce qu'un numéro sur quatre mesures a quatre fois la place.
        let pointsPerBar = pointsPerBeat * beatsPerBar
        let phrase = Double(TempoGrid.barsPerPhrase)
        let step: Double = pointsPerBar >= 44 ? 1
            : pointsPerBar * phrase >= 32 ? phrase : 0
        guard step > 0 else { return }
        var bar = (tempo.beat(at: model.time(atPoint: 0)) / (beatsPerBar * step))
            .rounded(.down) * step
        while tempo.time(ofBeat: bar * beatsPerBar) <= model.time(atPoint: Double(size.width)) {
            defer { bar += step }
            let time = tempo.time(ofBeat: bar * beatsPerBar)
            guard time >= 0 else { continue }
            context.draw(Text("\(Int(bar) + 1)")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38)),
                         at: CGPoint(x: model.point(ofTime: time) + 11, y: rulerHeight + 9))
        }
    }

    // MARK: Accords

    /// Hauteur de la bande où s'écrivent les accords, en bas de l'image.
    private var chordBandHeight: Double { AppModel.chordBandHeight }

    /// Les raies sur lesquelles l'accord survolé a été décidé, entourées et nommées.
    ///
    /// **Toutes celles qui ont compté, à toutes leurs octaves** — c'est le contrat du
    /// relevé par raies : le cadre ne montre pas une idée de l'accord, il montre les
    /// traits mêmes que le relevé a lus dans cette image. Ce qui n'est pas entouré n'a
    /// que trois raisons de ne pas l'être : la raie n'a pas duré tout l'intervalle,
    /// une raie plus grave l'explique dans ses harmoniques, ou elle est trop pâle pour
    /// le seuil réglé.
    ///
    /// Une raie tenue que l'accord ne contient pas est entourée **en pointillés** :
    /// elle a compté dans la décision — contre le nom retenu, même — et l'effacer
    /// laisserait à l'écran un trait franc dont rien n'expliquerait le silence.
    private func drawChordNotes(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let segment = model.hoveredChord, let chord = segment.chord else { return }
        let notes = model.hoveredChordNotes
        guard !notes.isEmpty else { return }

        let x0 = max(model.point(ofTime: segment.start), 0)
        let x1 = min(model.point(ofTime: segment.end), Double(size.width))
        guard x1 > x0 else { return }

        // La durée de l'accord s'éclaire à peine : c'est le cadre de lecture, pas
        // l'information.
        context.fill(Path(CGRect(x: x0, y: rulerHeight, width: x1 - x0,
                                 height: Double(size.height) - rulerHeight - chordBandHeight)),
                     with: .color(.white.opacity(0.05)))

        for note in notes {
            let frequency = Pitch.frequency(ofMidi: Double(note.midi),
                                            referenceA: model.display.referenceA)
            let y = model.point(ofFrequency: frequency)
            // La hauteur du cadre est celle d'un demi-ton à ce zoom-là : il entoure
            // exactement ce qu'il désigne, et grandit quand on grossit l'image.
            let half = abs(model.point(ofFrequency: Pitch.frequency(
                ofMidi: Double(note.midi) - 0.5, referenceA: model.display.referenceA)) - y)
            let thickness = min(max(half * 2, 3), 40)
            guard y + thickness > rulerHeight,
                  y - thickness < Double(size.height) - chordBandHeight else { continue }

            let colour = noteColour(note.pitchClass)
            let box = CGRect(x: x0, y: y - thickness / 2, width: x1 - x0, height: thickness)
            let opacity: Double
            var style = StrokeStyle(lineWidth: 1)
            switch note.role {
            case .root: opacity = 0.95; style.lineWidth = 1.5
            case .chord: opacity = 0.7
            case .extra:
                opacity = 0.6
                // Pointillés : tenue, mais étrangère au nom. On la montre pour qu'on
                // voie ce que le relevé a dû laisser de côté.
                style.dash = [3, 3]
            }
            context.stroke(Path(roundedRect: box, cornerRadius: 2),
                           with: .color(colour.opacity(opacity)), style: style)

            // Le nom se pose à gauche du cadre quand la place existe, dedans sinon.
            let text = Text(note.name(flats: model.display.useFlats)
                            + (note.role == .extra ? " ?" : ""))
                .font(.system(size: 10, weight: note.isRoot ? .bold : .medium,
                              design: .rounded))
                .foregroundStyle(colour.opacity(note.role == .extra ? 0.75 : 1))
            let resolved = context.resolve(text)
            let width = resolved.measure(in: size).width
            let left = x0 - width - 5
            let plaque = CGRect(x: left - 3, y: y - 8, width: width + 6, height: 16)
            if left > 2 {
                context.fill(Path(roundedRect: plaque, cornerRadius: 3),
                             with: .color(.black.opacity(0.75)))
                context.draw(resolved, at: CGPoint(x: left, y: y), anchor: .leading)
            } else {
                context.fill(Path(roundedRect: CGRect(x: x0 + 2, y: y - 8,
                                                      width: width + 6, height: 16),
                                  cornerRadius: 3),
                             with: .color(.black.opacity(0.75)))
                context.draw(resolved, at: CGPoint(x: x0 + 5, y: y), anchor: .leading)
            }
        }

        // Et le nom de l'accord lui-même, en grand, pour qu'on sache ce qu'on regarde.
        context.draw(Text(chord.label(flats: model.display.useFlats))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9)),
                     at: CGPoint(x: x0 + 4, y: rulerHeight + 12), anchor: .topLeading)
    }

    /// La teinte suit la rotation choisie dans les préférences : un cadre doit avoir
    /// la couleur de la raie qu'il entoure, pas une autre.
    private func noteColour(_ pitchClass: Int) -> Color {
        let rgb = NotePalette.color(pitchClass: ((pitchClass % 12) + 12) % 12,
                                    intensity: 0.9,
                                    saturation: model.display.noteSaturation,
                                    origin: Preferences.shared.hueOrigin)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }


    /// Les noms d'accords, au pied des traits de la grille.
    ///
    /// **En bas, et pas en haut.** La réglette du haut porte déjà la boucle et les
    /// numéros de mesure, et surtout : ce qu'on cherche en levant les yeux d'un
    /// instrument, c'est l'accord *sous* le passage qu'on regarde. Il est là où le
    /// doigt se pose.
    ///
    /// La densité suit la grille, sans jamais la contredire. Le relevé, lui, est
    /// toujours fait au temps : zoomer ne recalcule rien, cela dévoile seulement ce
    /// qui n'avait pas la place de s'écrire — et un accord tenu quatre mesures reste
    /// écrit une seule fois, à son début.
    private func drawChords(_ context: inout GraphicsContext, _ size: CGSize) {
        // Une bande vide sans explication passe pour une panne. Elle dit donc ce
        // qui manque — la séparation, ou la grille — plutôt que de rester muette.
        if let notice = model.chordNotice {
            let top = Double(size.height) - chordBandHeight
            context.fill(Path(CGRect(x: 0, y: top, width: size.width,
                                     height: chordBandHeight)),
                         with: .color(.black.opacity(0.55)))
            context.draw(Text(notice).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45)),
                         at: CGPoint(x: size.width / 2, y: top + chordBandHeight / 2))
            return
        }
        guard model.showChords, !model.chords.isEmpty,
              let tempo = model.tempo, tempo.bpm > 0, let unit = model.gridUnit else { return }
        // Sous le temps, on ne descend pas : personne ne change d'accord à la double
        // croche, et quatre noms par temps seraient illisibles.
        let grouping = max(1, Int(unit.rounded()))
        let labels = model.chords.labels(from: model.time(atPoint: 0),
                                         to: model.time(atPoint: Double(size.width)),
                                         grouping: grouping)
        guard !labels.isEmpty else { return }

        // Un fond, sinon les noms se perdent dans les graves de l'image — qui sont
        // justement la partie la plus dense, et celle qui les touche.
        let top = Double(size.height) - chordBandHeight
        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: chordBandHeight)),
                     with: .color(.black.opacity(0.55)))

        var occupied = -Double.infinity
        for segment in labels {
            guard let chord = segment.chord else { continue }
            let x = model.point(ofTime: segment.start)
            guard x < Double(size.width) else { break }
            // La marge de confiance se lit sur la pâleur : un accord deviné de
            // justesse ne doit pas s'afficher du même ton qu'un accord évident.
            let opacity = 0.45 + 0.5 * segment.confidence
            let text = Text(chord.label(flats: model.display.useFlats))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(opacity))
            let resolved = context.resolve(text)
            let width = resolved.measure(in: size).width
            guard x + width > 0 else { continue }
            // Deux noms ne se chevauchent jamais : celui qui n'a pas la place est
            // sauté, et son trait de grille reste seul. Mieux vaut un nom manquant
            // qu'une bouillie de lettres.
            guard x >= occupied + 6 else { continue }
            occupied = x + width
            context.draw(resolved, at: CGPoint(x: x + 3, y: Double(size.height) - 4),
                         anchor: .bottomLeading)
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
                          Pitch.noteName(for: snap.frequency, referenceA: model.display.referenceA,
                                         flats: model.display.useFlats, withOctave: false),
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
