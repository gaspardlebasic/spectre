import Foundation

/// Lecture d'un fichier WAV, en Swift, sans rien demander au système.
///
/// Le décodage est ce qui verrouille tout le reste : sans lui, l'analyse n'a rien
/// à se mettre sous la dent sur une plateforme neuve. Commencer par le WAV n'est
/// pas un renoncement mais un ordre de marche — c'est le seul format qu'on
/// décode sans dépendre de personne, et il suffit à prouver la chaîne entière de
/// bout en bout. Les formats compressés viendront de Media Foundation sous
/// Windows, qui les connaît tous et ne s'installe pas.
///
/// Le canal unique est obtenu par **moyenne** des canaux, exactement comme la
/// version macOS : c'est ce que l'analyse attend, et un écart ici décalerait tous
/// les niveaux.
public enum WAVFile {

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(URL)
        case notRIFF
        case unsupported(String)
        case empty

        public var description: String {
            switch self {
            case .unreadable(let url): return "Impossible de lire « \(url.lastPathComponent) »."
            case .notRIFF: return "Ce n'est pas un fichier WAV."
            case .unsupported(let quoi): return "WAV non pris en charge : \(quoi)."
            case .empty: return "Le fichier ne contient aucun son."
            }
        }
    }

    public struct Contents {
        public let sampleRate: Double
        public let channels: Int
        /// Les canaux mêlés en un seul, par moyenne.
        public let mono: [Float]
        public var frameCount: Int { mono.count }
        public var duration: Double { sampleRate > 0 ? Double(mono.count) / sampleRate : 0 }

        // L'initialiseur par membres qu'écrit le compilateur reste interne : il faut
        // donc le poser à la main pour qu'il traverse la frontière du module. Le
        // décodeur de Windows en a besoin — ce qui sort de Media Foundation est le
        // même contenu, obtenu autrement.
        public init(sampleRate: Double, channels: Int, mono: [Float]) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.mono = mono
        }
    }

    public static func read(at url: URL) throws -> Contents {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
        return try decode(data)
    }

    /// Le même fichier, **canal par canal** plutôt que mêlé.
    ///
    /// L'analyse ne veut que le mono, et c'est pourquoi `read` s'arrête là. Les
    /// pistes séparées, elles, sont stéréo et doivent le rester : il serait dommage
    /// d'écouter en mono une basse qu'on vient d'isoler.
    public static func readChannels(at url: URL)
        throws -> (channels: [[Float]], sampleRate: Double) {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
        let octets = [UInt8](data)
        let e = try entete(octets)
        var canaux = [[Float]](repeating: [Float](repeating: 0, count: e.images),
                               count: e.canaux)
        octets.withUnsafeBufferPointer { source in
            let base = source.baseAddress! + e.debut
            for c in 0..<e.canaux {
                canaux[c].withUnsafeMutableBufferPointer { sortie in
                    for image in 0..<e.images {
                        let p = base + (image * e.canaux + c) * e.octetsParEchantillon
                        sortie[image] = échantillon(p, bits: e.bits, flottant: e.flottant)
                    }
                }
            }
        }
        return (canaux, e.echantillonnage)
    }

    /// La fréquence et le nombre de canaux, **sans lire tout le fichier**.
    ///
    /// Une piste séparée pèse cent cinquante mégaoctets ; savoir à quelle fréquence
    /// elle a été écrite ne vaut pas de les relire. Seize kilo-octets suffisent : les
    /// en-têtes RIFF viennent en tête de fichier, et ceux qu'on écrit soi-même
    /// d'autant plus sûrement.
    public static func forme(at url: URL) -> (sampleRate: Double, channels: Int)? {
        guard let poignee = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? poignee.close() }
        guard let debut = try? poignee.read(upToCount: 16 * 1024),
              let e = try? entete([UInt8](debut)) else { return nil }
        return (e.echantillonnage, e.canaux)
    }

    public static func decode(_ data: Data) throws -> Contents {
        let octets = [UInt8](data)
        let e = try entete(octets)

        var mono = [Float](repeating: 0, count: e.images)
        let gain = Float(1) / Float(e.canaux)

        octets.withUnsafeBufferPointer { source in
            let base = source.baseAddress! + e.debut
            for image in 0..<e.images {
                var somme: Float = 0
                for canal in 0..<e.canaux {
                    let p = base + (image * e.canaux + canal) * e.octetsParEchantillon
                    somme += échantillon(p, bits: e.bits, flottant: e.flottant)
                }
                mono[image] = somme * gain
            }
        }

        return Contents(sampleRate: e.echantillonnage, channels: e.canaux, mono: mono)
    }

    /// Ce que l'en-tête a dit, et où le son commence.
    ///
    /// Séparé de la lecture parce qu'il y a désormais deux lectures — mêlée et canal
    /// par canal — et qu'un format RIFF analysé deux fois est un format analysé de
    /// deux façons.
    private struct Entete {
        var canaux: Int
        var bits: Int
        var flottant: Bool
        var echantillonnage: Double
        var debut: Int
        var images: Int
        var octetsParEchantillon: Int { bits / 8 }
    }

    private static func entete(_ octets: [UInt8]) throws -> Entete {
        guard octets.count >= 12 else { throw Failure.notRIFF }

        func u16(_ i: Int) -> Int { Int(octets[i]) | Int(octets[i + 1]) << 8 }
        func u32(_ i: Int) -> Int {
            Int(octets[i]) | Int(octets[i + 1]) << 8
                | Int(octets[i + 2]) << 16 | Int(octets[i + 3]) << 24
        }
        func marque(_ i: Int) -> String {
            String(bytes: octets[i..<min(i + 4, octets.count)], encoding: .ascii) ?? ""
        }

        guard marque(0) == "RIFF", marque(8) == "WAVE" else { throw Failure.notRIFF }

        // Parcours des morceaux. On ne suppose pas que `fmt ` précède `data`, ni
        // qu'ils se suivent : un WAV réel porte souvent des morceaux de métadonnées
        // entre les deux, et un lecteur qui les ignore doit les enjamber
        // correctement — un morceau de taille impaire est suivi d'un octet de
        // bourrage qui ne compte pas dans sa taille.
        var format = -1, bits = 0, canaux = 0, échantillonnage = 0.0
        var début = -1, longueur = 0
        var i = 12
        while i + 8 <= octets.count {
            let nom = marque(i)
            let taille = u32(i + 4)
            let corps = i + 8
            guard taille >= 0, corps <= octets.count else { break }

            if nom == "fmt " && taille >= 16 {
                format = u16(corps)
                canaux = u16(corps + 2)
                échantillonnage = Double(u32(corps + 4))
                bits = u16(corps + 14)
                // WAVE_FORMAT_EXTENSIBLE : le vrai format est dans le sous-type,
                // dont seuls les deux premiers octets nous intéressent.
                if format == 0xFFFE, taille >= 40 {
                    format = u16(corps + 24)
                }
            } else if nom == "data" {
                début = corps
                longueur = min(taille, octets.count - corps)
            }

            i = corps + taille + (taille % 2)      // bourrage des tailles impaires
        }

        guard format >= 0, canaux > 0, échantillonnage > 0 else { throw Failure.notRIFF }
        guard début >= 0, longueur > 0 else { throw Failure.empty }
        guard format == 1 || format == 3 else {
            throw Failure.unsupported("format \(format), seuls PCM et flottant sont lus")
        }
        guard [8, 16, 24, 32].contains(bits) else {
            throw Failure.unsupported("\(bits) bits par échantillon")
        }
        if format == 3 && bits != 32 {
            throw Failure.unsupported("flottant sur \(bits) bits")
        }

        let octetsParÉchantillon = bits / 8
        let images = longueur / (octetsParÉchantillon * canaux)
        guard images > 0 else { throw Failure.empty }

        return Entete(canaux: canaux, bits: bits, flottant: format == 3,
                      echantillonnage: échantillonnage, debut: début, images: images)
    }

    /// Un échantillon ramené dans −1…1.
    ///
    /// Les entiers signés sont divisés par leur pleine échelle, et le 8 bits est
    /// **non signé** avec 128 pour zéro — une singularité du format qu'on paie
    /// d'une ligne, et qui autrement donne un signal saturé et décalé.
    private static func échantillon(_ p: UnsafePointer<UInt8>, bits: Int,
                                    flottant: Bool) -> Float {
        switch bits {
        case 8:
            return (Float(p[0]) - 128) / 128
        case 16:
            let v = Int16(bitPattern: UInt16(p[0]) | UInt16(p[1]) << 8)
            return Float(v) / 32768
        case 24:
            var v = Int32(p[0]) | Int32(p[1]) << 8 | Int32(p[2]) << 16
            if v & 0x800000 != 0 { v -= 0x1000000 }        // extension du signe
            return Float(v) / 8_388_608
        case 32 where flottant:
            let bits = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            return Float(bitPattern: bits)
        case 32:
            let v = Int32(bitPattern: UInt32(p[0]) | UInt32(p[1]) << 8
                          | UInt32(p[2]) << 16 | UInt32(p[3]) << 24)
            return Float(v) / 2_147_483_648
        default:
            return 0
        }
    }
}
