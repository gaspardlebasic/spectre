import Foundation

// Écrire un WAV, sans rien demander au système.
//
// Le lecteur existait depuis l'étape 1 du portage ; l'écrivain manque jusqu'à
// l'étape 9, où Windows doit ranger les pistes séparées. Sur le Mac, AVFoundation
// écrit du FLAC en trois lignes ; ailleurs, il n'y a pas de bibliothèque de
// compression sans perte qu'on puisse supposer présente — et en ajouter une pour
// ranger un cache serait payer cher une place que l'on peut acheter autrement.
//
// D'où le vingt-quatre bits : deux fois et demie moins de place que le flottant,
// un plancher de bruit à −132 dB, et une réserve de niveau qui règle le seul écueil
// du format entier — ce qui dépasse ±1,0. C'est exactement le raisonnement du FLAC
// côté Mac, et la même réserve.

public extension WAVFile {

    /// De combien les pistes entières sont écrites en dessous, et remontées à la
    /// lecture.
    ///
    /// Une piste séparée dépasse ±1,0 — 1,19 mesuré sur la batterie du morceau
    /// témoin — et tout ce qui dépasse serait écrêté. On écrit donc six décibels plus
    /// bas et l'on remonte à la lecture. Il reste vingt-deux bits utiles, soit un
    /// plancher à −132 dB : trente-sept décibels sous le plus bas que l'affichage
    /// sache montrer.
    ///
    /// Deux et non quatre : la réserve doit couvrir les crêtes réelles, pas rassurer.
    /// Ce qui dépasserait quand même n'est pas écrêté en silence — voir `ecrire`.
    static var reserve: Float { 2 }

    /// Écrit des canaux en WAV, et rend le chemin **réellement** écrit.
    ///
    /// En vingt-quatre bits avec la réserve, sauf si le signal n'y tient pas : cette
    /// piste-là s'écrit alors en flottant, exact, sous la même racine et l'extension
    /// `.wavf`. Mieux vaut un fichier gros qu'un fichier faux, et c'est le genre de
    /// faute qui ne se verrait qu'au moment de relire un spectrogramme.
    @discardableResult
    static func ecrire(_ canaux: [[Float]], echantillonnage: Double,
                       vers url: URL) throws -> URL {
        guard let premier = canaux.first, !premier.isEmpty else {
            throw SeparationFailure.cannotWrite(url)
        }
        let crete = canaux.reduce(Float(0)) { max($0, $1.map(abs).max() ?? 0) }
        let entier = crete < reserve
        let cible = entier ? url : url.deletingPathExtension().appendingPathExtension("wavf")

        let images = premier.count
        let nombreDeCanaux = canaux.count
        let bits = entier ? 24 : 32
        let octetsParEchantillon = bits / 8
        let taillePCM = images * nombreDeCanaux * octetsParEchantillon

        var fichier = Data(capacity: 44 + taillePCM)
        func texte(_ s: String) { fichier.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { fichier.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { fichier.append(contentsOf: $0) } }

        texte("RIFF"); u32(36 + taillePCM); texte("WAVE")
        texte("fmt "); u32(16)
        u16(entier ? 1 : 3)                       // PCM entier, ou flottant IEEE
        u16(nombreDeCanaux)
        u32(Int(echantillonnage.rounded()))
        u32(Int(echantillonnage.rounded()) * nombreDeCanaux * octetsParEchantillon)
        u16(nombreDeCanaux * octetsParEchantillon)
        u16(bits)
        texte("data"); u32(taillePCM)

        // Entrelacé, image par image : c'est ce que le format veut, et c'est aussi ce
        // qui permet d'écrire d'un seul bloc plutôt que canal par canal.
        var corps = [UInt8](repeating: 0, count: taillePCM)
        let echelle = entier ? 1 / reserve : 1
        corps.withUnsafeMutableBufferPointer { sortie in
            var k = 0
            for image in 0..<images {
                for c in 0..<nombreDeCanaux {
                    let v = canaux[c][image] * echelle
                    if entier {
                        // ±8 388 607 et non ±8 388 608 : la valeur la plus négative
                        // du complément à deux n'a pas de symétrique, et l'écrire
                        // ferait déborder l'arrondi vers le positif.
                        let e = Int32(max(-8_388_607, min(8_388_607,
                                                          (v * 8_388_607).rounded())))
                        let u = UInt32(bitPattern: e)
                        sortie[k] = UInt8(u & 0xFF)
                        sortie[k + 1] = UInt8((u >> 8) & 0xFF)
                        sortie[k + 2] = UInt8((u >> 16) & 0xFF)
                        k += 3
                    } else {
                        let u = v.bitPattern
                        sortie[k] = UInt8(u & 0xFF)
                        sortie[k + 1] = UInt8((u >> 8) & 0xFF)
                        sortie[k + 2] = UInt8((u >> 16) & 0xFF)
                        sortie[k + 3] = UInt8((u >> 24) & 0xFF)
                        k += 4
                    }
                }
            }
        }
        fichier.append(contentsOf: corps)

        try? FileManager.default.createDirectory(
            at: cible.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fichier.write(to: cible, options: .atomic)
        } catch {
            throw SeparationFailure.cannotWrite(cible)
        }
        return cible
    }

    /// Le gain à appliquer en relisant **un fichier écrit par `ecrire`**, et lui
    /// seul.
    ///
    /// La réserve pour les fichiers entiers, rien pour les flottants, qui portent le
    /// signal tel quel. La condition est la même des deux côtés, et c'est le point :
    /// écrire avec une réserve que la relecture ne rattrape pas rendrait un signal
    /// six décibels trop bas, silencieusement.
    ///
    /// Le contrat s'arrête là. Un WAV venu d'ailleurs n'a pas été écrit par nous et
    /// n'a aucune raison d'être remonté : c'est à l'appelant de ne poser la question
    /// que sur ses propres fichiers — voir `RangementSurLePont`, qui vérifie
    /// l'emplacement avant de la poser. Le pendant macOS s'est fait prendre
    /// exactement là : `write` décidait sur l'extension, `gain` sur l'extension *et*
    /// l'emplacement, et les deux ne disaient donc pas la même chose.
    static func gain(pour url: URL) -> Float {
        url.pathExtension.lowercased() == "wavf" ? 1 : reserve
    }
}
