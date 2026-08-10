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
    }

    public static func read(at url: URL) throws -> Contents {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Contents {
        let octets = [UInt8](data)
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

        var mono = [Float](repeating: 0, count: images)
        let gain = Float(1) / Float(canaux)

        octets.withUnsafeBufferPointer { source in
            let base = source.baseAddress! + début
            for image in 0..<images {
                var somme: Float = 0
                for canal in 0..<canaux {
                    let p = base + (image * canaux + canal) * octetsParÉchantillon
                    somme += échantillon(p, bits: bits, flottant: format == 3)
                }
                mono[image] = somme * gain
            }
        }

        return Contents(sampleRate: échantillonnage, channels: canaux, mono: mono)
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
