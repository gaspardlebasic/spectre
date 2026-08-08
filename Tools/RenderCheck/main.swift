import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

// Vérification du rendu : on fabrique une matrice de synthèse, on la fait passer
// par la vraie chaîne (téléversement → shader → image), et on relit les pixels.
// Aucune fenêtre : tout se fait hors écran, donc en intégration continue aussi.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(label) — \(detail)")
    if !ok { failures += 1 }
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "rendu.png"

guard let device = MTLCreateSystemDefaultDevice(),
      let renderer = SpectrogramRenderer(device: device),
      let queue = device.makeCommandQueue() else {
    print("  ✗ Metal indisponible")
    exit(1)
}

let bins = 180
let columns = 3000

func makeLayout() -> BinLayout {
    var l = BinLayout()
    l.binCount = bins
    l.minFrequency = 27.5
    l.maxFrequency = 27.5 * pow(2, Double(bins) / 36)
    l.binsPerOctave = 36
    l.sampleRate = 48000
    return l
}

/// Rend une image et renvoie les pixels en niveaux de gris (0…1), rangée par rangée
/// depuis le **haut**.
func render(_ spectrogram: Spectrogram, viewport: Viewport,
            width: Int, height: Int) -> [Float] {
    renderer.layout = spectrogram.layout
    renderer.upload(spectrogram)
    renderer.viewport = viewport
    renderer.display.colorMap = .gray
    renderer.display.gamma = 1
    renderer.display.tiltDbPerOctave = 0
    renderer.display.floorDb = -100
    renderer.display.ceilingDb = 0

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    guard let target = device.makeTexture(descriptor: desc),
          let commands = queue.makeCommandBuffer() else { return [] }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    renderer.encode(into: commands, descriptor: pass,
                    pixelSize: CGSize(width: width, height: height), scale: 1)
    if let blit = commands.makeBlitCommandEncoder() {
        blit.synchronize(resource: target)
        blit.endEncoding()
    }
    commands.commit()
    commands.waitUntilCompleted()

    var raw = [UInt8](repeating: 0, count: width * height * 4)
    raw.withUnsafeMutableBytes { buffer in
        target.getBytes(buffer.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    return (0..<(width * height)).map { Float(raw[$0 * 4 + 2]) / 255 }   // canal rouge
}

func writePNG(_ pixels: [Float], width: Int, height: Int, to path: String) {
    var bytes = pixels.map { UInt8(min(max($0, 0), 1) * 255) }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let space = CGColorSpace(name: CGColorSpace.linearGray),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 8, bytesPerRow: width, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    bytes.removeAll()
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Scène 1 : une rampe fréquence/temps

// Une raie qui monte régulièrement : elle dit d'un coup si le temps va bien vers
// la droite, les graves vers le bas, et si la fenêtre visible est respectée.
var ramp = [Float](repeating: -200, count: columns * bins)
func rampBin(_ c: Int) -> Int { 10 + c * 150 / columns }
for c in 0..<columns {
    ramp[c * bins + rampBin(c)] = 0
}
let rampScene = Spectrogram(layout: makeLayout(), columnCount: columns,
                            secondsPerColumn: 0.01, values: ramp)

let width = 600, height = 300
var viewport = Viewport.fitting(columns: columns, bins: bins,
                                size: (Double(width), Double(height)))
let full = render(rampScene, viewport: viewport, width: width, height: height)
writePNG(full, width: width, height: height, to: outputPath)

print("=== Cadrage complet ===")
func brightestRow(_ pixels: [Float], column x: Int, width: Int, height: Int) -> (row: Int, value: Float) {
    var best = 0, value = Float(0)
    for y in 0..<height where pixels[y * width + x] > value {
        value = pixels[y * width + x]
        best = y
    }
    return (best, value)
}

var worstError = 0.0
for x in stride(from: 20, to: width - 20, by: 60) {
    let found = brightestRow(full, column: x, width: width, height: height)
    let column = Int(viewport.column(atPoint: Double(x) + 0.5))
    let expected = viewport.point(ofBin: Double(rampBin(column)) + 0.5, height: Double(height))
    worstError = max(worstError, abs(Double(found.row) + 0.5 - expected))
}
check("la raie tombe où la fenêtre le prévoit", worstError < 2.5,
      String(format: "écart max %.1f px", worstError))

let bottomLeft = brightestRow(full, column: 5, width: width, height: height)
let topRight = brightestRow(full, column: width - 5, width: width, height: height)
check("les graves sont en bas, le temps va vers la droite",
      bottomLeft.row > height * 2 / 3 && topRight.row < height / 3,
      "début à la rangée \(bottomLeft.row), fin à la rangée \(topRight.row)")

// MARK: - Scène 2 : un transitoire d'une seule colonne

// Dézoomé, un pixel couvre cinq colonnes : une attaque isolée doit survivre,
// parce que le shader prend le maximum et non la moyenne.
print("\n=== Transitoire au dézoom ===")
var click = [Float](repeating: -200, count: columns * bins)
let clickColumn = 1500
for i in 0..<bins { click[clickColumn * bins + i] = 0 }
let clickScene = Spectrogram(layout: makeLayout(), columnCount: columns,
                             secondsPerColumn: 0.01, values: click)
let zoomedOut = render(clickScene, viewport: viewport, width: width, height: height)
let expectedX = Int(viewport.point(ofColumn: Double(clickColumn)))
var clickPeak = Float(0)
for x in max(0, expectedX - 2)...min(width - 1, expectedX + 2) {
    clickPeak = max(clickPeak, zoomedOut[(height / 2) * width + x])
}
check("une colonne isolée reste visible à \(String(format: "%.0f", viewport.columnsPerPoint)) colonnes par pixel",
      clickPeak > 0.9, String(format: "%.2f de clarté à x≈%d", clickPeak, expectedX))

// MARK: - Scène 3 : zoom et défilement

// On zoome d'un facteur 20 autour d'un point : la colonne visée doit rester
// exactement sous le curseur, sinon le zoom au trackpad « glisse ».
print("\n=== Zoom ancré ===")
let anchorX = 137.0
let before = viewport.column(atPoint: anchorX)
viewport.zoomTime(factor: 20, anchorX: anchorX)
let after = viewport.column(atPoint: anchorX)
check("la colonne sous le curseur ne bouge pas", abs(before - after) < 1e-9,
      String(format: "%.6f contre %.6f", before, after))

let zoomed = render(rampScene, viewport: viewport, width: width, height: height)
var zoomError = 0.0
for x in stride(from: 20, to: width - 20, by: 60) {
    let found = brightestRow(zoomed, column: x, width: width, height: height)
    let column = Int(viewport.column(atPoint: Double(x) + 0.5))
    let expected = viewport.point(ofBin: Double(rampBin(column)) + 0.5, height: Double(height))
    zoomError = max(zoomError, abs(Double(found.row) + 0.5 - expected))
}
check("la raie suit toujours après zoom", zoomError < 2.5,
      String(format: "écart max %.1f px", zoomError))

print("\n→ \(outputPath)")
if failures == 0 {
    print("Tout est bon.")
} else {
    print("\(failures) vérification(s) en échec.")
    exit(1)
}
