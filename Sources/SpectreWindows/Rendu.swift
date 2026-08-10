import CSDL3
import Foundation
import SpectreCore

// Le rendu OpenGL du spectrogramme.
//
// Windows n'expose de lui-même que l'OpenGL 1.1 de 1997 : tout ce qui a été
// ajouté depuis — nuanceurs, tableaux de textures, objets de sommets — doit être
// réclamé pointeur par pointeur au pilote. C'est la corvée d'entrée de toute
// application OpenGL sous Windows, et la raison d'être de bibliothèques comme
// glad. On s'en passe ici : la liste tient en une vingtaine d'entrées, et une
// dépendance de plus se paierait à chaque construction.

private typealias GLenum = UInt32
private typealias GLuint = UInt32
private typealias GLint = Int32
private typealias GLsizei = Int32
private typealias GLbitfield = UInt32
private typealias GLchar = CChar

private let GL_FLOAT: GLenum = 0x1406
private let GL_RED: GLenum = 0x1903
private let GL_RGBA: GLenum = 0x1908
private let GL_R32F: GLenum = 0x822E
private let GL_RGBA8: GLenum = 0x8058
private let GL_UNSIGNED_BYTE: GLenum = 0x1401
private let GL_TEXTURE_2D: GLenum = 0x0DE1
private let GL_TEXTURE_2D_ARRAY: GLenum = 0x8C1A
private let GL_TEXTURE_MIN_FILTER: GLenum = 0x2801
private let GL_TEXTURE_MAG_FILTER: GLenum = 0x2800
private let GL_TEXTURE_WRAP_S: GLenum = 0x2802
private let GL_TEXTURE_WRAP_T: GLenum = 0x2803
private let GL_NEAREST: GLint = 0x2600
private let GL_CLAMP_TO_EDGE: GLint = 0x812F
private let GL_TEXTURE0: GLenum = 0x84C0
private let GL_TEXTURE1: GLenum = 0x84C1
private let GL_VERTEX_SHADER: GLenum = 0x8B31
private let GL_FRAGMENT_SHADER: GLenum = 0x8B30
private let GL_COMPILE_STATUS: GLenum = 0x8B81
private let GL_LINK_STATUS: GLenum = 0x8B82
private let GL_COLOR_BUFFER_BIT: GLbitfield = 0x4000
private let GL_TRIANGLES: GLenum = 0x0004
private let GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5

/// Les fonctions OpenGL, réclamées au pilote une fois pour toutes.
private struct GL {
    let clearColor: @convention(c) (Float, Float, Float, Float) -> Void
    let clear: @convention(c) (GLbitfield) -> Void
    let viewport: @convention(c) (GLint, GLint, GLsizei, GLsizei) -> Void
    let pixelStorei: @convention(c) (GLenum, GLint) -> Void
    let genTextures: @convention(c) (GLsizei, UnsafeMutablePointer<GLuint>) -> Void
    let bindTexture: @convention(c) (GLenum, GLuint) -> Void
    let texParameteri: @convention(c) (GLenum, GLenum, GLint) -> Void
    let texImage2D: @convention(c) (GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                                    GLenum, GLenum, UnsafeRawPointer?) -> Void
    let texImage3D: @convention(c) (GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei,
                                    GLint, GLenum, GLenum, UnsafeRawPointer?) -> Void
    let texSubImage3D: @convention(c) (GLenum, GLint, GLint, GLint, GLint,
                                       GLsizei, GLsizei, GLsizei, GLenum, GLenum,
                                       UnsafeRawPointer?) -> Void
    let activeTexture: @convention(c) (GLenum) -> Void
    let createShader: @convention(c) (GLenum) -> GLuint
    let shaderSource: @convention(c) (GLuint, GLsizei,
                                      UnsafePointer<UnsafePointer<GLchar>?>?,
                                      UnsafePointer<GLint>?) -> Void
    let compileShader: @convention(c) (GLuint) -> Void
    let getShaderiv: @convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>) -> Void
    let getShaderInfoLog: @convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?,
                                          UnsafeMutablePointer<GLchar>) -> Void
    let createProgram: @convention(c) () -> GLuint
    let attachShader: @convention(c) (GLuint, GLuint) -> Void
    let linkProgram: @convention(c) (GLuint) -> Void
    let getProgramiv: @convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>) -> Void
    let getProgramInfoLog: @convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?,
                                           UnsafeMutablePointer<GLchar>) -> Void
    let useProgram: @convention(c) (GLuint) -> Void
    let deleteShader: @convention(c) (GLuint) -> Void
    let getUniformLocation: @convention(c) (GLuint, UnsafePointer<GLchar>) -> GLint
    let uniform1i: @convention(c) (GLint, GLint) -> Void
    let uniform1f: @convention(c) (GLint, Float) -> Void
    let uniform2f: @convention(c) (GLint, Float, Float) -> Void
    let genVertexArrays: @convention(c) (GLsizei, UnsafeMutablePointer<GLuint>) -> Void
    let bindVertexArray: @convention(c) (GLuint) -> Void
    let drawArrays: @convention(c) (GLenum, GLint, GLsizei) -> Void

    /// Chaque pointeur est réclamé nommément. Un `nil` ici veut dire que le pilote
    /// ne connaît pas la fonction — donc que le contexte n'est pas celui qu'on
    /// croit — et il vaut mieux le dire tout de suite que planter au premier appel.
    init?() {
        func adresse(_ nom: String) -> UnsafeMutableRawPointer? {
            unsafeBitCast(SDL_GL_GetProcAddress(nom), to: UnsafeMutableRawPointer?.self)
        }
        func lie<T>(_ nom: String, _ type: T.Type) -> T? {
            guard let p = adresse(nom) else {
                FileHandle.standardError.write(Data("OpenGL : \(nom) introuvable\n".utf8))
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }
        guard let a = lie("glClearColor", (@convention(c) (Float, Float, Float, Float) -> Void).self),
              let b = lie("glClear", (@convention(c) (GLbitfield) -> Void).self),
              let c = lie("glViewport", (@convention(c) (GLint, GLint, GLsizei, GLsizei) -> Void).self),
              let d = lie("glPixelStorei", (@convention(c) (GLenum, GLint) -> Void).self),
              let e = lie("glGenTextures", (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>) -> Void).self),
              let f = lie("glBindTexture", (@convention(c) (GLenum, GLuint) -> Void).self),
              let g = lie("glTexParameteri", (@convention(c) (GLenum, GLenum, GLint) -> Void).self),
              let h = lie("glTexImage2D", (@convention(c) (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, UnsafeRawPointer?) -> Void).self),
              let i = lie("glTexImage3D", (@convention(c) (GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei, GLint, GLenum, GLenum, UnsafeRawPointer?) -> Void).self),
              let j = lie("glTexSubImage3D", (@convention(c) (GLenum, GLint, GLint, GLint, GLint, GLsizei, GLsizei, GLsizei, GLenum, GLenum, UnsafeRawPointer?) -> Void).self),
              let k = lie("glActiveTexture", (@convention(c) (GLenum) -> Void).self),
              let l = lie("glCreateShader", (@convention(c) (GLenum) -> GLuint).self),
              let m = lie("glShaderSource", (@convention(c) (GLuint, GLsizei, UnsafePointer<UnsafePointer<GLchar>?>?, UnsafePointer<GLint>?) -> Void).self),
              let n = lie("glCompileShader", (@convention(c) (GLuint) -> Void).self),
              let o = lie("glGetShaderiv", (@convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>) -> Void).self),
              let p = lie("glGetShaderInfoLog", (@convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<GLchar>) -> Void).self),
              let q = lie("glCreateProgram", (@convention(c) () -> GLuint).self),
              let r = lie("glAttachShader", (@convention(c) (GLuint, GLuint) -> Void).self),
              let s = lie("glLinkProgram", (@convention(c) (GLuint) -> Void).self),
              let t = lie("glGetProgramiv", (@convention(c) (GLuint, GLenum, UnsafeMutablePointer<GLint>) -> Void).self),
              let u = lie("glGetProgramInfoLog", (@convention(c) (GLuint, GLsizei, UnsafeMutablePointer<GLsizei>?, UnsafeMutablePointer<GLchar>) -> Void).self),
              let v = lie("glUseProgram", (@convention(c) (GLuint) -> Void).self),
              let w = lie("glDeleteShader", (@convention(c) (GLuint) -> Void).self),
              let x = lie("glGetUniformLocation", (@convention(c) (GLuint, UnsafePointer<GLchar>) -> GLint).self),
              let y = lie("glUniform1i", (@convention(c) (GLint, GLint) -> Void).self),
              let z = lie("glUniform1f", (@convention(c) (GLint, Float) -> Void).self),
              let aa = lie("glUniform2f", (@convention(c) (GLint, Float, Float) -> Void).self),
              let ab = lie("glGenVertexArrays", (@convention(c) (GLsizei, UnsafeMutablePointer<GLuint>) -> Void).self),
              let ac = lie("glBindVertexArray", (@convention(c) (GLuint) -> Void).self),
              let ad = lie("glDrawArrays", (@convention(c) (GLenum, GLint, GLsizei) -> Void).self)
        else { return nil }
        clearColor = a; clear = b; viewport = c; pixelStorei = d
        genTextures = e; bindTexture = f; texParameteri = g
        texImage2D = h; texImage3D = i; texSubImage3D = j; activeTexture = k
        createShader = l; shaderSource = m; compileShader = n
        getShaderiv = o; getShaderInfoLog = p
        createProgram = q; attachShader = r; linkProgram = s
        getProgramiv = t; getProgramInfoLog = u; useProgram = v; deleteShader = w
        getUniformLocation = x; uniform1i = y; uniform1f = z; uniform2f = aa
        genVertexArrays = ab; bindVertexArray = ac; drawArrays = ad
    }
}

/// Rend un spectrogramme déjà calculé.
///
/// La matrice est envoyée **une fois** au chargement, en tuiles, et plus rien ne
/// remonte au GPU ensuite : zoomer, défiler, changer de palette ou de contraste
/// ne fait que relire ce qui est déjà là. C'est le même parti pris que la version
/// Metal, et c'est ce qui rend la navigation instantanée.
final class SpectrogramRenderer {
    /// Hauteur d'une tuile, en colonnes. Une texture ne peut pas être arbitrairement
    /// grande ; on empile donc des tranches, et le nuanceur retrouve la sienne par
    /// une division.
    static let tileRows = 2048

    private let gl: GL
    private let program: GLuint
    private var tiles: GLuint = 0
    private var noteColors: GLuint = 0
    private var vao: GLuint = 0
    private var uniformes: [String: GLint] = [:]

    private let spectrogram: Spectrogram

    init?(spectrogram: Spectrogram, shaderPath: URL) {
        guard let gl = GL() else { return nil }
        self.gl = gl
        self.spectrogram = spectrogram

        guard let source = try? String(contentsOf: shaderPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Nuanceur introuvable : \(shaderPath.path)\n".utf8))
            return nil
        }
        // Le fichier porte les deux étages, chacun ouvert par sa ligne `#version`.
        // On le coupe là plutôt que sur un commentaire, qui se réécrit.
        let morceaux = source.components(separatedBy: "#version 330 core")
        guard morceaux.count >= 3 else {
            FileHandle.standardError.write(Data("Le nuanceur ne porte pas ses deux étages.\n".utf8))
            return nil
        }
        let sommets = "#version 330 core" + morceaux[1]
        let fragments = "#version 330 core" + morceaux[2]

        guard let vs = Self.compile(gl, sommets, GL_VERTEX_SHADER, "sommets"),
              let fs = Self.compile(gl, fragments, GL_FRAGMENT_SHADER, "fragments")
        else { return nil }

        program = gl.createProgram()
        gl.attachShader(program, vs)
        gl.attachShader(program, fs)
        gl.linkProgram(program)
        var etat: GLint = 0
        gl.getProgramiv(program, GL_LINK_STATUS, &etat)
        if etat == 0 {
            var journal = [GLchar](repeating: 0, count: 4096)
            gl.getProgramInfoLog(program, 4096, nil, &journal)
            FileHandle.standardError.write(Data("Édition de liens du nuanceur :\n\(String(cString: journal))\n".utf8))
            return nil
        }
        gl.deleteShader(vs)
        gl.deleteShader(fs)

        gl.genVertexArrays(1, &vao)
        televerse()
    }

    private static func compile(_ gl: GL, _ source: String, _ type: GLenum,
                                _ nom: String) -> GLuint? {
        let objet = gl.createShader(type)
        var etat: GLint = 0
        source.withCString { p in
            var pointeur: UnsafePointer<GLchar>? = p
            gl.shaderSource(objet, 1, &pointeur, nil)
        }
        gl.compileShader(objet)
        gl.getShaderiv(objet, GL_COMPILE_STATUS, &etat)
        guard etat != 0 else {
            var journal = [GLchar](repeating: 0, count: 4096)
            gl.getShaderInfoLog(objet, 4096, nil, &journal)
            FileHandle.standardError.write(
                Data("Compilation du nuanceur (\(nom)) :\n\(String(cString: journal))\n".utf8))
            return nil
        }
        return objet
    }

    /// La matrice et la table des couleurs, envoyées une fois pour toutes.
    private func televerse() {
        let bins = spectrogram.binCount
        let colonnes = spectrogram.columnCount
        let tranches = max(1, (colonnes + Self.tileRows - 1) / Self.tileRows)

        // Les colonnes font `bins` flottants : sans cela, OpenGL supposerait un
        // alignement sur quatre octets par ligne et décalerait tout dès qu'un
        // nombre de lignes impair se présente.
        gl.pixelStorei(GL_UNPACK_ALIGNMENT, 1)

        gl.genTextures(1, &tiles)
        gl.bindTexture(GL_TEXTURE_2D_ARRAY, tiles)
        gl.texParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        gl.texParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        gl.texParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        gl.texParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        gl.texImage3D(GL_TEXTURE_2D_ARRAY, 0, GLint(GL_R32F),
                      GLsizei(bins), GLsizei(Self.tileRows), GLsizei(tranches),
                      0, GL_RED, GL_FLOAT, nil)

        spectrogram.values.withUnsafeBufferPointer { source in
            for tranche in 0..<tranches {
                let premiere = tranche * Self.tileRows
                let hauteur = min(Self.tileRows, colonnes - premiere)
                guard hauteur > 0 else { break }
                gl.texSubImage3D(GL_TEXTURE_2D_ARRAY, 0, 0, 0, GLint(tranche),
                                 GLsizei(bins), GLsizei(hauteur), 1,
                                 GL_RED, GL_FLOAT,
                                 source.baseAddress! + premiere * bins)
            }
        }

        var table = NotePalette.makeTable(saturation: 1.4)
        gl.genTextures(1, &noteColors)
        gl.bindTexture(GL_TEXTURE_2D, noteColors)
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        table.withUnsafeMutableBufferPointer { p in
            gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8),
                          GLsizei(NotePalette.steps), GLsizei(NotePalette.pitchClassCount),
                          0, GL_RGBA, GL_UNSIGNED_BYTE, p.baseAddress)
        }
    }

    private func lieu(_ nom: String) -> GLint {
        if let connu = uniformes[nom] { return connu }
        let l = nom.withCString { gl.getUniformLocation(program, $0) }
        uniformes[nom] = l
        return l
    }

    func draw(viewport: Viewport, display: DisplaySettings, size: (width: Int, height: Int)) {
        gl.viewport(0, 0, GLsizei(size.width), GLsizei(size.height))
        gl.clearColor(0, 0, 0, 1)
        gl.clear(GL_COLOR_BUFFER_BIT)
        gl.useProgram(program)

        gl.activeTexture(GL_TEXTURE0)
        gl.bindTexture(GL_TEXTURE_2D_ARRAY, tiles)
        gl.uniform1i(lieu("tiles"), 0)
        gl.activeTexture(GL_TEXTURE1)
        gl.bindTexture(GL_TEXTURE_2D, noteColors)
        gl.uniform1i(lieu("noteColors"), 1)

        let layout = spectrogram.layout
        gl.uniform2f(lieu("origin"), Float(viewport.startColumn), Float(viewport.bottomBin))
        gl.uniform2f(lieu("perPixel"), Float(viewport.columnsPerPoint),
                     Float(viewport.binsPerPoint))
        gl.uniform2f(lieu("viewSize"), Float(size.width), Float(size.height))
        gl.uniform1i(lieu("columns"), GLint(spectrogram.columnCount))
        gl.uniform1i(lieu("bins"), GLint(spectrogram.binCount))
        gl.uniform1i(lieu("tileRows"), GLint(Self.tileRows))
        // Au dézoom, un pixel couvre plusieurs colonnes : on en échantillonne
        // assez pour ne pas manquer les attaques, mais pas plus.
        gl.uniform1i(lieu("steps"), GLint(min(max(Int(viewport.columnsPerPoint.rounded()), 1), 64)))
        gl.uniform1i(lieu("colorMap"), GLint(display.colorMap.rawValue))
        gl.uniform1f(lieu("minDb"), Float(display.floorDb))
        gl.uniform1f(lieu("maxDb"), Float(display.ceilingDb))
        gl.uniform1f(lieu("gammaValue"), Float(display.gamma))
        gl.uniform1f(lieu("tiltPerOctave"), Float(display.tiltDbPerOctave))
        gl.uniform1f(lieu("log2FminOver1k"), Float(log2(layout.minFrequency / 1000)))
        gl.uniform1f(lieu("binsPerOctave"), Float(layout.binsPerOctave))
        gl.uniform1f(lieu("semitoneAtBin0"),
                     Float(Pitch.midi(from: layout.minFrequency, referenceA: display.referenceA)))

        gl.bindVertexArray(vao)
        gl.drawArrays(GL_TRIANGLES, 0, 3)
    }
}
