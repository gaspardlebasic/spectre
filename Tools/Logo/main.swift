import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Fabrique l'icône de l'application à partir de Resources/icone.svg.
//
// Le SVG est rendu par le système — `NSImage` le charge en `_NSSVGImageRep`, donc en
// vectoriel : chaque taille est rastérisée à sa résolution propre plutôt que d'être
// la réduction floue d'une grande image.
//
// Seule addition au dessin : la plaque arrondie de macOS. Le SVG est un carré plein,
// or une icône du Dock est un rectangle à coins très arrondis, en retrait de sa
// case. Sans cette découpe, l'application dépasserait de la grille où toutes les
// autres se rangent.

let source = URL(fileURLWithPath: "Resources/icone.svg")
guard let artwork = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("Icône illisible : \(source.path)\n".utf8))
    exit(1)
}

func render(size: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("contexte impossible") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Marge et arrondi de la grille d'icônes macOS.
    let side = CGFloat(size)
    let inset = side * 0.0915
    let plate = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    ctx.addPath(CGPath(roundedRect: plate,
                       cornerWidth: plate.width * 0.2237,
                       cornerHeight: plate.width * 0.2237,
                       transform: nil))
    ctx.clip()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    artwork.draw(in: plate, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { fatalError("encodage impossible") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("écriture impossible : \(url.path)") }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1] : "build/logo")
let iconset = outputDirectory.appendingPathComponent("Spectre.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                       ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    render(size: pixels, to: iconset.appendingPathComponent("\(name).png"))
}
render(size: 1024, to: outputDirectory.appendingPathComponent("icone-1024.png"))
print("→ \(outputDirectory.path)")
