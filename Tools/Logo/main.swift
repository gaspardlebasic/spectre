import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Logo de Transcripteur : une pile de profils spectraux vue en perspective.
//
// La forme vient tout droit de ce que l'application montre — des raies, empilées,
// chacune occultant celles qui sont derrière. Trois d'entre elles sont colorées :
// ce sont les partiels que l'œil suit dans le spectrogramme.
//
// L'image est *calculée*, pas dessinée à la main, pour deux raisons : chaque taille
// d'icône est rendue à sa propre résolution (les traits fins ne se bouchent pas au
// petit format), et le résultat est reproductible — même graine, même image.

// MARK: - Nombres pseudo-aléatoires reproductibles

struct Seeded {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

// MARK: - Profil d'une raie

/// Une ligne du logo : quelques bosses gaussiennes sur une ondulation de fond.
struct Ridge {
    struct Peak { var centre, width, height: Double }
    var peaks: [Peak]
    var phase: Double
}

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Hauteur du profil en `u ∈ [-1, 1]`, ramenée à zéro sur les bords.
func profile(_ ridge: Ridge, at u: Double) -> Double {
    var v = 0.0
    for p in ridge.peaks {
        let d = (u - p.centre) / p.width
        v += p.height * exp(-d * d)
    }
    // Ondulation de fond : sans elle, l'espace entre les bosses est une ligne
    // droite, et la pile perd ce qui la fait ressembler à une mesure.
    v += 0.055 * sin(u * 9 + ridge.phase) * exp(-u * u * 0.8)
    v += 0.030 * sin(u * 23 - ridge.phase * 1.7) * exp(-u * u * 1.3)
    return max(v, 0) * (1 - smoothstep(0.70, 1.0, abs(u)))
}

/// Les dix profils, tirés une fois pour toutes : toutes les tailles d'icône
/// montrent exactement la même image.
func makeRidges() -> [Ridge] {
    var rng = Seeded(0x5DE_C0DE_1979)
    return (0..<10).map { row in
        var peaks: [Ridge.Peak] = []
        // La bosse dominante ne tombe pas où le hasard la met : elle **serpente**
        // d'une ligne à l'autre. Tirée au sort, elle se serait agglutinée avec ses
        // voisines et la pile n'aurait plus été qu'une montagne ; en la faisant
        // dériver, on lit chaque ligne séparément — et le glissando qui en résulte
        // dit assez bien ce que l'application sert à suivre.
        let drift = 0.30 * sin(Double(row) * 0.72 + 0.5)
        peaks.append(.init(centre: drift + rng.range(-0.05, 0.05),
                           width: rng.range(0.10, 0.15),
                           height: rng.range(0.88, 1.0)))
        // Deux ou trois harmoniques, franchement plus basses : une ligne où toutes
        // les bosses se valent n'est plus une raie, c'est une broussaille. Elles se
        // tiennent à distance de la dominante, sinon elles la doublent.
        for _ in 0..<Int(rng.range(2, 4)) {
            var centre = rng.range(-0.70, 0.70)
            if abs(centre - drift) < 0.22 { centre += centre > drift ? 0.22 : -0.22 }
            peaks.append(.init(centre: centre,
                               width: rng.range(0.06, 0.12),
                               height: rng.range(0.14, 0.40)))
        }
        return Ridge(peaks: peaks, phase: rng.range(0, 2 * .pi))
    }
}

// MARK: - Couleurs

struct RGB {
    var r, g, b: Double
    func cg(_ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

let background = RGB(r: 0.043, g: 0.055, b: 0.078)
let plainLine = RGB(r: 0.898, g: 0.929, b: 0.976)

/// Les trois raies froides et vives, réparties dans la profondeur pour que la
/// couleur traverse la perspective au lieu de se poser sur un seul plan.
let coloured: [Int: RGB] = [
    1: RGB(r: 0.133, g: 0.827, b: 0.933),   // cyan
    4: RGB(r: 0.231, g: 0.510, b: 0.965),   // azur
    7: RGB(r: 0.545, g: 0.361, b: 0.965),   // violet
]

// MARK: - Tracé

/// Dessine le logo dans un carré de côté `size`.
///
/// - Parameter plate: dessine la plaque arrondie de l'icône macOS. Faux pour une
///   image destinée à être posée sur un autre fond.
func drawLogo(in ctx: CGContext, size: Double, plate: Bool) {
    let ridges = makeRidges()

    ctx.saveGState()
    if plate {
        // Marge et arrondi de la grille d'icônes macOS.
        let inset = size * 0.0915
        let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let path = CGPath(roundedRect: rect,
                          cornerWidth: rect.width * 0.2237,
                          cornerHeight: rect.width * 0.2237,
                          transform: nil)
        ctx.addPath(path)
        ctx.clip()
    }
    ctx.setFillColor(background.cg())
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // Projection : point de fuite au-dessus du cadre, si bien que les lignes se
    // resserrent vers le haut sans jamais s'agglutiner sur un horizon visible.
    // `z` va de 1 (ligne de devant) à 1,535 (ligne du fond) ; tout le reste —
    // écartement, largeur, amplitude, épaisseur du trait — en découle.
    let horizon = -0.46
    let reach = 1.30
    let depth = { (row: Int) in 1 + Double(row) * (0.646 / 9) }
    let baseline = { (row: Int) in horizon + reach / depth(row) }   // fraction depuis le haut
    let samples = 512

    // De la plus lointaine à la plus proche : chaque ligne efface derrière elle
    // ce qui la précède, et c'est cette occultation qui fait tout le relief.
    for row in stride(from: 9, through: 0, by: -1) {
        let z = depth(row)
        let yBase = baseline(row)
        // La demi-largeur reste en deçà de la plaque : au ras du bas, l'arrondi de
        // l'icône rogne le cadre, et une ligne trop large s'y ferait couper.
        let halfWidth = 0.350 / z
        // L'amplitude suit l'**écartement local**, pas la profondeur : c'est le
        // rapport des deux qui décide de la densité, et il doit rester le même du
        // devant au fond, sinon les lignes du fond se noient les unes dans les
        // autres pendant que celles de devant flottent.
        let spacing = baseline(min(row, 8)) - baseline(min(row, 8) + 1)
        let amplitude = 2.0 * spacing

        let path = CGMutablePath()
        for s in 0...samples {
            let u = -1 + 2 * Double(s) / Double(samples)
            let x = (0.5 + u * halfWidth) * size
            let y = (1 - (yBase - amplitude * profile(ridges[row], at: u))) * size
            if s == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }

        // Le remplissage descend jusqu'au bas du cadre : c'est lui qui masque les
        // lignes situées derrière.
        let mask = CGMutablePath()
        mask.addPath(path)
        mask.addLine(to: CGPoint(x: (0.5 + halfWidth) * size, y: 0))
        mask.addLine(to: CGPoint(x: (0.5 - halfWidth) * size, y: 0))
        mask.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(background.cg())
        ctx.addPath(mask)
        ctx.fillPath()
        ctx.restoreGState()

        // Les lignes lointaines pâlissent : c'est le second indice de profondeur,
        // celui qui agit même là où rien ne se chevauche.
        let depth = Double(row) / 9
        let tint = coloured[row]
        let colour = tint ?? plainLine
        let alpha = (tint != nil ? 1.0 : 0.97) - 0.30 * depth

        ctx.saveGState()
        if tint != nil {
            // Halo : une raie colorée doit rayonner, pas seulement être colorée.
            ctx.setShadow(offset: .zero, blur: size * 0.022, color: colour.cg(0.9))
        }
        ctx.setStrokeColor(colour.cg(alpha))
        // Trait fuyant lui aussi, mais jamais plus fin qu'un pixel : au format 16
        // points, une ligne à 0,3 pixel disparaîtrait.
        ctx.setLineWidth(max(size * 0.0132 / z, max(size * 0.0062, 0.85)))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// MARK: - Écriture

func render(size: Int, plate: Bool, to url: URL) {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("contexte impossible") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawLogo(in: ctx, size: Double(size), plate: plate)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("encodage impossible") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("écriture impossible : \(url.path)") }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1] : "build/logo")
let iconset = outputDirectory.appendingPathComponent("Transcripteur.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Chaque taille est rendue à sa résolution propre : les traits et le halo suivent,
// au lieu d'être une réduction floue du grand format.
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                       ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    render(size: pixels, plate: true, to: iconset.appendingPathComponent("\(name).png"))
}

// Deux images à part : l'icône en grand, et le motif seul pour un document ou une
// page — sans la plaque, qui n'a de sens que dans le Dock.
render(size: 1024, plate: true, to: outputDirectory.appendingPathComponent("icone-1024.png"))
render(size: 1024, plate: false, to: outputDirectory.appendingPathComponent("motif-1024.png"))
print("→ \(outputDirectory.path)")
