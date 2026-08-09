import Accelerate
import Metal
import MetalKit
import simd

// Doit rester binairement identique à la structure `Uniforms` du shader.
struct ViewUniforms {
    /// Colonne au bord gauche, ligne au bord bas.
    var origin = SIMD2<Float>(0, 0)
    /// Colonnes et lignes couvertes par un pixel.
    var perPixel = SIMD2<Float>(1, 1)
    /// Taille de la vue, en pixels.
    var viewSize = SIMD2<Float>(1, 1)
    var columns: UInt32 = 0
    var bins: UInt32 = 0
    var tileRows: UInt32 = 1
    /// Nombre de colonnes échantillonnées par pixel quand on est dézoomé.
    var steps: UInt32 = 1
    var colorMap: UInt32 = 0
    var minDb: Float = -95
    var maxDb: Float = -25
    var gamma: Float = 1
    var tiltPerOctave: Float = 0
    var log2FminOver1k: Float = 0
    var binsPerOctave: Float = 36
    /// Numéro de demi-ton (échelle MIDI) de la ligne 0.
    var semitoneAtBin0: Float = 0
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 origin;
    float2 perPixel;
    float2 viewSize;
    uint  columns;
    uint  bins;
    uint  tileRows;
    uint  steps;
    uint  colorMap;
    float minDb;
    float maxDb;
    float gamma;
    float tiltPerOctave;
    float log2FminOver1k;
    float binsPerOctave;
    float semitoneAtBin0;
};

struct VSOut {
    float4 position [[position]];
};

vertex VSOut vertexMain(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VSOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    return out;
}

static float3 palette(float t, uint which) {
    if (which == 0u) { return float3(t); }

    float3 c0, c1, c2, c3, c4, c5, c6;
    if (which == 1u) {          // inferno
        c0 = float3(0.00021894, 0.00165100, -0.01948090);
        c1 = float3(0.10651342, 0.56395644, 3.93271239);
        c2 = float3(11.6024931, -3.97285397, -15.9423941);
        c3 = float3(-41.7039961, 17.4363989, 44.3541452);
        c4 = float3(77.1629357, -33.4023589, -81.8073093);
        c5 = float3(-71.3194282, 32.6260643, 73.2095199);
        c6 = float3(25.1311262, -12.2426690, -23.0703250);
    } else if (which == 2u) {   // magma
        c0 = float3(-0.00213649, -0.00074966, -0.00538613);
        c1 = float3(0.25166054, 0.67752324, 2.49402660);
        c2 = float3(8.35371728, -3.57771951, 0.31446790);
        c3 = float3(-27.6687331, 14.2647308, -13.6492132);
        c4 = float3(52.1761398, -27.9436061, 12.9441694);
        c5 = float3(-50.7685254, 29.0465828, 4.23415299);
        c6 = float3(18.6557051, -11.4897735, -5.60196151);
    } else if (which == 3u) {   // viridis
        c0 = float3(0.27772733, 0.00540734, 0.33409981);
        c1 = float3(0.10509304, 1.40461353, 1.38459016);
        c2 = float3(-0.33086183, 0.21484756, 0.09509516);
        c3 = float3(-4.63423050, -5.79910097, -19.3324410);
        c4 = float3(6.22826994, 14.1799334, 56.6905526);
        c5 = float3(4.77638500, -13.7451454, -65.3530326);
        c6 = float3(-5.43545586, 4.64585261, 26.3124352);
    } else {                    // turbo
        c0 = float3(0.11408901, 0.06288341, 0.22483372);
        c1 = float3(6.71641950, 3.18228675, 7.57158159);
        c2 = float3(-66.0940236, -4.92798270, -10.0943937);
        c3 = float3(228.766079, 25.0498670, -91.5410533);
        c4 = float3(-334.835157, -69.3174971, 288.585885);
        c5 = float3(218.763722, 67.5215057, -305.204577);
        c6 = float3(-52.8890348, -21.5452736, 110.517465);
    }
    float3 v = c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6)))));
    return clamp(v, 0.0, 1.0);
}

// Lecture d'une colonne, interpolée entre deux lignes voisines.
static float readColumn(texture2d_array<float, access::read> tiles,
                        int column, int b0, int b1, float fr, uint tileRows) {
    uint slice = uint(column) / tileRows;
    uint row = uint(column) % tileRows;
    float a = tiles.read(uint2(uint(b0), row), slice).r;
    float b = tiles.read(uint2(uint(b1), row), slice).r;
    return mix(a, b, fr);
}

fragment float4 fragmentMain(VSOut in [[stage_in]],
                             texture2d_array<float, access::read> tiles [[texture(0)]],
                             texture2d<float, access::read> noteColors [[texture(1)]],
                             constant Uniforms &u [[buffer(0)]]) {
    // Position du pixel dans la matrice. `position` est au centre du pixel.
    float colCenter = u.origin.x + in.position.x * u.perPixel.x;
    float binPos = u.origin.y + (u.viewSize.y - in.position.y) * u.perPixel.y;

    float bf = binPos - 0.5;
    int i0 = int(floor(bf));
    float fr = bf - float(i0);
    int lastBin = int(u.bins) - 1;
    int b0 = clamp(i0, 0, lastBin);
    int b1 = clamp(i0 + 1, 0, lastBin);
    int lastColumn = int(u.columns) - 1;

    float db = -400.0;
    if (u.steps <= 1u) {
        // Zoomé : interpolation entre les deux colonnes voisines, sinon l'image
        // devient un damier dès qu'une colonne dépasse le pixel.
        float cf = colCenter - 0.5;
        int c0 = int(floor(cf));
        float ft = cf - float(c0);
        if (c0 >= -1 && c0 <= lastColumn) {
            float a = readColumn(tiles, clamp(c0, 0, lastColumn), b0, b1, fr, u.tileRows);
            float b = readColumn(tiles, clamp(c0 + 1, 0, lastColumn), b0, b1, fr, u.tileRows);
            db = mix(a, b, ft);
        }
    } else {
        // Dézoomé : un pixel couvre plusieurs colonnes. On en prend le **maximum**,
        // pas la moyenne — sinon les attaques, brèves par nature, s'effacent.
        float start = colCenter - 0.5 * u.perPixel.x;
        float step = u.perPixel.x / float(u.steps);
        for (uint k = 0u; k < u.steps; ++k) {
            int c = int(floor(start + (float(k) + 0.5) * step));
            if (c < 0 || c > lastColumn) { continue; }
            db = max(db, readColumn(tiles, c, b0, b1, fr, u.tileRows));
        }
    }

    // Pente d'affichage, référencée à 1 kHz.
    float octave = u.log2FminOver1k + binPos / max(u.binsPerOctave, 1e-3);
    db += u.tiltPerOctave * octave;

    float t = clamp((db - u.minDb) / max(u.maxDb - u.minDb, 1e-3), 0.0, 1.0);
    t = pow(t, u.gamma);

    if (u.colorMap == 5u) {
        float semitone = u.semitoneAtBin0 + binPos * 12.0 / max(u.binsPerOctave, 1e-3);
        int pitchClass = int(floor(semitone + 0.5));
        pitchClass = ((pitchClass % 12) + 12) % 12;
        int last = int(noteColors.get_width()) - 1;
        float ft = t * float(last);
        int t0 = clamp(int(floor(ft)), 0, last);
        int t1 = min(t0 + 1, last);
        float3 ca = noteColors.read(uint2(uint(t0), uint(pitchClass))).rgb;
        float3 cb = noteColors.read(uint2(uint(t1), uint(pitchClass))).rgb;
        return float4(mix(ca, cb, ft - float(t0)), 1.0);
    }

    return float4(palette(t, u.colorMap), 1.0);
}
"""

/// Rendu d'une fenêtre du spectrogramme.
///
/// La matrice ne défile plus : elle est envoyée une fois pour toutes sur le GPU et
/// c'est la *fenêtre* qui bouge. Comme une texture 2D plafonne à 16 384 lignes et
/// qu'une heure de musique en fait 360 000, la matrice est découpée en tuiles
/// empilées dans un `texture2d_array` — le shader retrouve la tuile par une
/// division, il n'y a donc toujours qu'un seul appel de dessin.
final class SpectrogramRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var tiles: MTLTexture?
    private var noteColorTable: MTLTexture?
    private var tableSaturation = Double.nan

    /// Hauteur d'une tuile, en colonnes.
    private let tileRows = 4096
    private(set) var columns = 0
    private(set) var bins = 0

    /// Ce que le rendu doit afficher : renseigné à chaque image par la vue.
    var viewport = Viewport()
    var display = DisplaySettings()

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        super.init()

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertexMain")
            desc.fragmentFunction = library.makeFunction(name: "fragmentMain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Spectre : compilation du shader impossible — \(error)")
            return nil
        }
        buildNoteColorTable(saturation: display.noteSaturation)
    }

    // MARK: Téléversement

    /// Envoie la matrice sur le GPU. Les dB sont convertis en demi-flottants :
    /// à ces niveaux le pas vaut 0,06 dB, très en dessous du visible, et la
    /// mémoire occupée est divisée par deux.
    func upload(_ spectrogram: Spectrogram) {
        let bins = spectrogram.binCount
        let columns = spectrogram.columnCount
        guard bins > 0, columns > 0 else {
            tiles = nil
            self.columns = 0
            self.bins = 0
            return
        }

        let sliceCount = (columns + tileRows - 1) / tileRows
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r16Float
        desc.width = bins
        desc.height = tileRows
        desc.arrayLength = sliceCount
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else {
            NSLog("Spectre : texture de \(sliceCount) tuiles impossible à allouer.")
            return
        }

        var half = [UInt16](repeating: 0, count: columns * bins)
        spectrogram.values.withUnsafeBufferPointer { src in
            half.withUnsafeMutableBufferPointer { dst in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                          height: 1, width: vImagePixelCount(columns * bins),
                                          rowBytes: columns * bins * MemoryLayout<Float>.size)
                var output = vImage_Buffer(data: dst.baseAddress!,
                                           height: 1, width: vImagePixelCount(columns * bins),
                                           rowBytes: columns * bins * MemoryLayout<UInt16>.size)
                vImageConvert_PlanarFtoPlanar16F(&input, &output, 0)
            }
        }

        let bytesPerRow = bins * MemoryLayout<UInt16>.size
        half.withUnsafeBufferPointer { buf in
            for slice in 0..<sliceCount {
                let first = slice * tileRows
                let rows = min(tileRows, columns - first)
                texture.replace(region: MTLRegionMake2D(0, 0, bins, rows),
                                mipmapLevel: 0,
                                slice: slice,
                                withBytes: buf.baseAddress! + first * bins,
                                bytesPerRow: bytesPerRow,
                                bytesPerImage: bytesPerRow * rows)
            }
        }

        tiles = texture
        self.columns = columns
        self.bins = bins
    }

    private func buildNoteColorTable(saturation: Double) {
        if noteColorTable == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: NotePalette.steps,
                height: NotePalette.pitchClassCount,
                mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .managed
            noteColorTable = device.makeTexture(descriptor: desc)
        }
        guard let tex = noteColorTable else { return }
        tableSaturation = saturation
        let table = NotePalette.makeTable(saturation: saturation)
        table.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, NotePalette.steps, NotePalette.pitchClassCount),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: NotePalette.steps * 4)
        }
    }

    // MARK: Rendu

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer()
        else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        encode(into: commands, descriptor: descriptor,
               pixelSize: view.drawableSize, scale: scale)
        commands.present(drawable)
        commands.commit()
    }

    /// Isolé de `MTKView` pour pouvoir aussi produire des images hors écran.
    func encode(into commands: MTLCommandBuffer,
                descriptor: MTLRenderPassDescriptor,
                pixelSize: CGSize,
                scale: CGFloat) {
        // L'encodeur est créé même quand il n'y a rien à dessiner : c'est lui qui
        // exécute l'effacement de la vue. Sans ça on présenterait un tampon jamais
        // écrit — que Metal affiche en magenta.
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        guard let pipeline, let tiles else {
            encoder.endEncoding()
            return
        }

        if display.colorMap == .notes, tableSaturation != display.noteSaturation {
            buildNoteColorTable(saturation: display.noteSaturation)
        }

        let columnsPerPixel = viewport.columnsPerPoint / Double(scale)
        var u = ViewUniforms()
        u.origin = SIMD2<Float>(Float(viewport.startColumn), Float(viewport.bottomBin))
        u.perPixel = SIMD2<Float>(Float(columnsPerPixel),
                                  Float(viewport.binsPerPoint / Double(scale)))
        u.viewSize = SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))
        u.columns = UInt32(columns)
        u.bins = UInt32(bins)
        u.tileRows = UInt32(tileRows)
        // Assez d'échantillons pour ne pas rater d'attaque, pas assez pour coûter
        // cher : au-delà d'une trentaine, l'œil ne fait plus la différence.
        u.steps = UInt32(min(max(Int(columnsPerPixel.rounded(.up)), 1), 32))
        let map = (display.colorMap == .notes && noteColorTable == nil) ? .gray : display.colorMap
        u.colorMap = UInt32(map.rawValue)
        u.minDb = Float(display.floorDb)
        u.maxDb = Float(display.ceilingDb)
        u.gamma = Float(display.gamma)
        u.tiltPerOctave = Float(display.tiltDbPerOctave)
        u.log2FminOver1k = Float(log2(layout.minFrequency / 1000))
        u.binsPerOctave = Float(layout.binsPerOctave)
        u.semitoneAtBin0 = Float(Pitch.midi(from: layout.minFrequency, referenceA: display.referenceA))

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(tiles, index: 0)
        encoder.setFragmentTexture(noteColorTable, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<ViewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Géométrie de l'axe des fréquences, nécessaire aux couleurs de notes.
    var layout = BinLayout()
}
