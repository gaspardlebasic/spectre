import AppKit
import SpectreCore
import SpectreModele
import SwiftUI

// MARK: - Les gestes de la ligne

/// Reçoit molette, pincement et clic au-dessus de la ligne de batterie.
///
/// SwiftUI ne sait pas rendre le pincement du trackpad ni les deltas précis de la
/// molette : c'est une vue AppKit qui les porte, exactement comme pour l'image. Sans
/// elle, passer la souris un pouce plus bas suffisait à faire cesser le zoom, ce qui
/// n'a aucune raison d'être — les deux vues partagent le même axe des temps, et le
/// geste est le même.
final class DrumLaneInputView: NSView {
    var model: AppModel?
    /// L'ancre du glisser en cours, quand il trace une boucle.
    private var loopAnchor: Double?

    private func x(_ event: NSEvent) -> Double {
        Double(convert(event.locationInWindow, from: nil).x)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        // `anchorY: nil` : il n'y a pas de fréquences ici, et le zoom vertical
        // s'ancre alors au milieu de l'image.
        TimelineGestures.scroll(event, x: x(event), anchorY: nil, model: model)
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        TimelineGestures.magnify(event, x: x(event), anchorY: nil, model: model)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        model.cancelTurn()
        let time = model.time(atPoint: x(event))
        if event.modifierFlags.contains(.shift) {
            loopAnchor = time
        } else {
            loopAnchor = nil
            model.seek(to: time)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let time = model.time(atPoint: x(event))
        // ⌘ enfoncé pendant le geste libère les bornes de la grille, comme dans
        // l'image.
        let snapping = !event.modifierFlags.contains(.command)
        if let anchor = loopAnchor {
            model.setLoop(from: anchor, to: time, snapping: snapping)
        } else {
            model.seek(to: time)
        }
    }

    override func mouseUp(with event: NSEvent) { loopAnchor = nil }
}

struct DrumLaneInput: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> DrumLaneInputView {
        let view = DrumLaneInputView()
        view.model = model
        return view
    }

    func updateNSView(_ view: DrumLaneInputView, context: Context) { view.model = model }
}

/// Hauteur de la ligne de batterie, réglettes comprises.
let drumLaneHeight = 62.0

/// La batterie, sous le spectrogramme : une ligne par voie, un trait par coup.
///
/// **Pourquoi une piste à part et non une couleur de plus dans l'image.** Un
/// spectrogramme répond à « quelle hauteur, quand » ; une batterie n'a pas de
/// hauteur, et les trois questions qu'on se pose devant elle — quand, quoi, combien
/// fort — n'ont aucun rapport avec l'axe vertical. Empilées sur trois lignes, elles
/// se lisent comme une tablature de batterie, c'est-à-dire comme ce qu'on écrirait
/// de toute façon sur le papier.
///
/// Elle partage l'axe des temps du spectrogramme, à la colonne près : même largeur,
/// même `point(ofTime:)`. Zoomer, défiler, poser une boucle continuent donc de valoir
/// pour elle, et un coup se lit à l'aplomb de ce qui l'a produit dans l'image.
///
/// Ce qui est dessiné en fond de chaque ligne est le **niveau de la bande**, à
/// l'échelle des coups. C'est délibéré : un détecteur se trompe, et une ligne de
/// traits seule aurait l'air d'une vérité. Un coup manqué se voit alors comme une
/// bosse sans trait, et un coup inventé comme un trait sans bosse.
struct DrumLaneView: View {
    let model: AppModel

    /// Hauteur d'une ligne, et espace entre deux.
    private let rowHeight = 17.0
    private let rowGap = 1.0
    private let topPadding = 4.0
    /// Largeur du couloir des intitulés, à gauche.
    private let gutter = 26.0

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.black.opacity(0.92)))
            var edge = Path()
            edge.move(to: CGPoint(x: 0, y: 0.25))
            edge.addLine(to: CGPoint(x: size.width, y: 0.25))
            context.stroke(edge, with: .color(.white.opacity(0.16)), lineWidth: 0.5)

            guard model.spectrogram.columnCount > 0 else { return }
            drawGrid(&context, size)
            // Pendant la séparation, la ligne reste vide. Elle *pourrait* montrer le
            // relevé du mixage, mais ce relevé-là est approximatif et sera remplacé
            // dans la minute par celui de la piste de batterie isolée : l'afficher
            // reviendrait à faire lire deux fois deux rythmes différents.
            if !model.calculEnCours {
                for voice in DrumVoice.allCases { draw(voice, &context, size) }
            }
            drawLoop(&context, size)
            drawLabels(&context, size)
            if let notice = model.drumLaneNotice { draw(notice, &context, size) }
        }
        // La tête de lecture est un calque à part, ici comme sur l'image : elle
        // avance à chaque instant, et le relevé de batterie ne bouge pas avec elle.
        .overlay(PlayheadLine(model: model))
        // Molette, pincement, clic et ⇧ + glisser : tout ce que l'image accepte, la
        // ligne l'accepte aussi. Une bande de rythme sur laquelle on ne peut ni se
        // poser ni zoomer ne sert à rien.
        .overlay(DrumLaneInput(model: model))
        .frame(height: drumLaneHeight)
    }

    private func rect(of voice: DrumVoice, in size: CGSize) -> CGRect {
        let y = topPadding + Double(voice.rawValue) * (rowHeight + rowGap)
        return CGRect(x: 0, y: y, width: size.width, height: rowHeight)
    }

    private func color(_ voice: DrumVoice, opacity: Double) -> Color {
        let rgb = voice.color
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }

    // MARK: La grille métrique

    /// Les mêmes traits que dans l'image, au même endroit : c'est ce qui permet de
    /// lire une syncope. Sans eux, la ligne ne dirait que « il s'est passé quelque
    /// chose », jamais « sur le contretemps ».
    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        guard model.display.showGrid, let tempo = model.tempo, tempo.bpm > 0,
              let subdivision = model.gridUnit else { return }
        let first = (tempo.beat(at: model.time(atPoint: 0)) / subdivision)
            .rounded(.down) * subdivision
        let last = tempo.beat(at: model.time(atPoint: Double(size.width)))
        var beat = first
        while beat <= last {
            defer { beat += subdivision }
            let time = tempo.time(ofBeat: beat)
            guard time >= 0 else { continue }
            let isPhrase = tempo.opensPhrase(beat)
            let isBar = tempo.opensBar(beat)
            let isBeat = abs(beat.rounded() - beat) < 1e-6
            var line = Path()
            line.move(to: CGPoint(x: model.point(ofTime: time), y: 0))
            line.addLine(to: CGPoint(x: model.point(ofTime: time), y: size.height))
            // Les mêmes quatre degrés que l'image, un cran plus discrets : ici les
            // traits passent derrière des coups qui, eux, doivent se compter.
            context.stroke(line,
                           with: .color(.white.opacity(isPhrase ? 0.32
                                                       : isBar ? 0.20
                                                       : isBeat ? 0.10 : 0.045)),
                           lineWidth: isBar ? 0.75 : 0.5)
        }
    }

    // MARK: Une voie

    private func draw(_ voice: DrumVoice, _ context: inout GraphicsContext, _ size: CGSize) {
        let row = rect(of: voice, in: size)

        var base = Path()
        base.move(to: CGPoint(x: 0, y: row.maxY))
        base.addLine(to: CGPoint(x: size.width, y: row.maxY))
        context.stroke(base, with: .color(.white.opacity(0.10)), lineWidth: 0.5)

        drawCurve(voice, row: row, &context, size)
        drawHits(voice, row: row, &context, size)
    }

    /// Le niveau de la bande, un pixel après l'autre.
    ///
    /// La hauteur d'un pixel est le **maximum** de ce que la courbe fait sur sa
    /// largeur, jamais la moyenne — la même règle que le shader du spectrogramme, et
    /// pour la même raison : une attaque est brève et s'effacerait dès qu'on
    /// regarde le morceau en entier.
    private func drawCurve(_ voice: DrumVoice, row: CGRect,
                           _ context: inout GraphicsContext, _ size: CGSize) {
        guard !model.percussion.isEmpty else { return }
        var area = Path()
        area.move(to: CGPoint(x: 0, y: row.maxY))
        var x = 0.0
        while x <= Double(size.width) {
            defer { x += 1 }
            let t0 = model.time(atPoint: x)
            let t1 = model.time(atPoint: x + 1)
            let value = Double(model.percussion.level(voice, from: t0, to: t1))
            area.addLine(to: CGPoint(x: x, y: row.maxY - value * (row.height - 1)))
        }
        area.addLine(to: CGPoint(x: Double(size.width), y: row.maxY))
        area.closeSubpath()
        context.fill(area, with: .color(color(voice, opacity: 0.22)))
    }

    /// Les coups. La force se lit à la fois sur la hauteur et sur l'opacité : l'une
    /// seule ne se voit pas assez sur dix-sept points de haut.
    ///
    /// **Un trait droit, fin, sans arrondi**, et le même pour les trois voies. Un coup
    /// est un instant : un rectangle aux angles coupés le désigne plus franchement
    /// qu'une pastille dont les bords fuient, surtout quand deux coups se suivent à la
    /// double croche. Les cymbales avaient gardé un trait deux fois plus large, au
    /// prétexte qu'elles tombent moins souvent sur les temps ; c'était une raison de
    /// dessin, pas de lecture — trois lignes qui répondent à la même question doivent
    /// se lire de la même façon, sans quoi l'œil croit que la différence veut dire
    /// quelque chose.
    private func drawHits(_ voice: DrumVoice, row: CGRect,
                          _ context: inout GraphicsContext, _ size: CGSize) {
        let from = model.time(atPoint: -4)
        let to = model.time(atPoint: Double(size.width) + 4)
        let width = 1.5
        for hit in model.percussion.hits(from: from, to: to) where hit.voice == voice {
            let x = model.point(ofTime: hit.time)
            let height = (0.42 + 0.58 * hit.strength) * (row.height - 2)
            let mark = CGRect(x: x - width / 2, y: row.maxY - height,
                              width: width, height: height)
            context.fill(Path(mark),
                         with: .color(color(voice, opacity: 0.5 + 0.5 * hit.strength)))
        }
    }

    // MARK: Repères

    /// Les intitulés vivent sur un fond opaque : posés à même les traits, ils
    /// deviennent illisibles dès qu'un charleston joue les doubles croches.
    private func drawLabels(_ context: inout GraphicsContext, _ size: CGSize) {
        for voice in DrumVoice.allCases {
            let row = rect(of: voice, in: size)
            context.fill(Path(CGRect(x: 0, y: row.minY, width: gutter, height: row.height)),
                         with: .color(.black.opacity(0.72)))
            context.draw(Text(voice.short)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(color(voice, opacity: 0.9)),
                         at: CGPoint(x: gutter / 2, y: row.midY))
        }
    }

    /// Ce qui est hors de la boucle s'assombrit, comme dans l'image au-dessus.
    private func drawLoop(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let loop = model.loop else { return }
        let x0 = model.point(ofTime: loop.lowerBound)
        let x1 = model.point(ofTime: loop.upperBound)
        let outside = Color.black.opacity(model.loopEnabled ? 0.42 : 0.18)
        context.fill(Path(CGRect(x: 0, y: 0, width: max(x0, 0), height: size.height)),
                     with: .color(outside))
        context.fill(Path(CGRect(x: min(x1, Double(size.width)), y: 0,
                                 width: max(Double(size.width) - x1, 0), height: size.height)),
                     with: .color(outside))
    }

    /// Le relevé se fait pendant qu'on travaille, et la batterie peut avoir été
    /// retirée : la ligne dit laquelle des deux, plutôt que de rester vide sans
    /// raison apparente.
    private func draw(_ notice: String, _ context: inout GraphicsContext, _ size: CGSize) {
        let text = Text(notice)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        context.draw(context.resolve(text),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}
