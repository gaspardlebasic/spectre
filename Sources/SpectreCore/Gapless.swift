import Foundation

/// Les échantillons que le décodeur rend et que personne n'a jamais joués.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// LE PROBLÈME
///
/// Les formats à trame — AAC, MP3 — ne peuvent pas commencer n'importe où : le
/// codeur préfixe le signal de quelques centaines à quelques milliers
/// d'échantillons d'amorçage, et le complète à la fin jusqu'à la trame pleine.
/// Ces échantillons font partie du fichier mais pas du morceau. Le nombre exact
/// est écrit dans le conteneur — la table d'édition d'un MP4, la balise LAME
/// d'un MP3 — et c'est au lecteur de le retrancher.
///
/// `AVAudioFile` le fait tout seul. **Media Foundation ne le fait pas.** Sur un
/// AAC de six secondes, Windows rend 267 264 échantillons là où macOS en rend
/// 264 600 : le morceau démarre 48 ms plus tard, et tout ce qu'on a placé
/// dessus — boucle, repères, grille de tempo — glisse d'autant. Un fichier de
/// session écrit sur un système ne retomberait plus juste sur l'autre.
///
/// D'où ce lecteur : il ne décode rien, il lit seulement ce que le conteneur
/// déclare. Et parce qu'il est en Swift portable, il se met au point sur un Mac
/// en confrontant ses réponses à celles d'`AVAudioFile`, sans la machine cible.
/// ─────────────────────────────────────────────────────────────────────────────
public enum GaplessTrim {

    public struct Info: Equatable {
        /// Échantillons à jeter au début.
        public let priming: Int
        /// Échantillons à jeter à la fin.
        public let padding: Int
        /// Longueur utile, quand le conteneur la donne — sinon `nil`.
        public let frames: Int?

        public init(priming: Int, padding: Int, frames: Int?) {
            self.priming = priming
            self.padding = padding
            self.frames = frames
        }

        /// Applique la coupe à un signal décodé.
        ///
        /// ─────────────────────────────────────────────────────────────────────
        /// LE DÉCODEUR A PEUT-ÊTRE DÉJÀ COUPÉ
        ///
        /// Chaque décodeur en fait une part différente, et aucun ne dit laquelle.
        /// Media Foundation ôte le retard du banc de filtres d'un MP3 — 528
        /// échantillons — et rien d'autre. AVFoundation ôte tout. Retrancher
        /// aveuglément ce que le conteneur déclare décalerait donc le signal
        /// d'autant, dans l'autre sens.
        ///
        /// La longueur utile, elle, ne dépend d'aucun décodeur. On s'en sert
        /// comme d'un point fixe : l'excédent réellement observé, comparé à
        /// l'excédent déclaré, dit combien le décodeur a déjà pris. Et il l'a
        /// forcément pris **au début** — le retard d'un décodeur est un
        /// phénomène de début. Le reste se répartit comme le conteneur le dit.
        ///
        /// Cette réconciliation se vérifie : elle tombe juste sur un AAC d'Apple
        /// (rien de pré-coupé), sur un MP3 de LAME (528 pré-coupés) et sur un
        /// MP3 de ffmpeg (dont la balise ne déclare pas de retard). Voir
        /// `Tools/GaplessCheck`.
        /// ─────────────────────────────────────────────────────────────────────
        public func apply(to samples: [Float]) -> [Float] {
            var debut = min(max(priming, 0), samples.count)
            var fin = samples.count - min(max(padding, 0), samples.count - debut)

            if let frames, frames > 0, frames <= samples.count {
                let excedentObserve = samples.count - frames
                let excedentDeclare = max(priming, 0) + max(padding, 0)
                let dejaFait = max(excedentDeclare - excedentObserve, 0)
                debut = min(max(max(priming, 0) - dejaFait, 0), excedentObserve)
                fin = debut + frames
            }

            guard fin > debut else { return samples }
            guard debut > 0 || fin < samples.count else { return samples }
            return Array(samples[debut..<fin])
        }
    }

    /// Lit ce que le conteneur déclare, sans décoder.
    ///
    /// Rend `nil` quand le format ne dit rien — un WAV, un FLAC, un MP3 sans
    /// balise LAME —, auquel cas il n'y a rien à couper.
    public static func read(at url: URL) -> Info? {
        // Le fichier est projeté en mémoire plutôt que lu : sur un MP4, la table
        // d'édition est souvent tout à la fin, et un morceau d'une heure pèse
        // cent mégaoctets qu'on n'a aucune raison de recopier pour lire douze
        // octets.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let octets = [UInt8](data.prefix(24))
        if octets.count >= 12, octets[4] == 0x66, octets[5] == 0x74,
           octets[6] == 0x79, octets[7] == 0x70 {          // « ftyp » : un MP4
            return lireMP4(data)
        }
        return lireMP3(data)
    }

    // ══════════════════════════════════════════════════════════════════ MP4/M4A

    /// Un MP4 est un arbre de boîtes : taille sur quatre octets, type sur quatre,
    /// contenu. C'est tout, et cela suffit à trouver ce qu'on cherche.
    private static func lireMP4(_ data: Data) -> Info? {
        guard let moov = boite("moov", dans: data, plage: data.startIndex..<data.endIndex) else {
            return nil
        }
        // Les outils d'Apple — dont l'encodeur AAC du système — n'écrivent pas de
        // table d'édition mais une étiquette `iTunSMPB`, qui donne les trois
        // nombres directement et sans conversion d'échelle. Quand elle est là,
        // c'est la meilleure source ; le reste du monde utilise `elst`.
        if let info = lireITunSMPB(data, moov) { return info }

        // L'échelle de temps du film, qui mesure la table d'édition.
        var echelleFilm = 0
        if let mvhd = boite("mvhd", dans: data, plage: moov) {
            let base = mvhd.lowerBound
            let version = data[base]
            let decalage = version == 1 ? 20 : 12
            if base + decalage + 4 <= mvhd.upperBound {
                echelleFilm = Int(entier32(data, base + decalage))
            }
        }

        // Le premier `trak` qui porte une table d'édition et une échelle de temps
        // est la piste audio : sur un fichier de musique, il n'y en a qu'une.
        var curseur = moov.lowerBound
        while let trak = boite("trak", dans: data, plage: curseur..<moov.upperBound) {
            curseur = trak.upperBound
            guard let mdia = boite("mdia", dans: data, plage: trak),
                  let mdhd = boite("mdhd", dans: data, plage: mdia) else { continue }
            let base = mdhd.lowerBound
            let version = data[base]
            let decalage = version == 1 ? 20 : 12
            guard base + decalage + 4 <= mdhd.upperBound else { continue }
            // L'échelle de temps d'une piste audio est sa fréquence
            // d'échantillonnage : la table d'édition se lit donc directement en
            // échantillons.
            let echellePiste = Int(entier32(data, base + decalage))
            guard echellePiste > 0 else { continue }

            guard let edts = boite("edts", dans: data, plage: trak),
                  let elst = boite("elst", dans: data, plage: edts) else { continue }
            guard let edition = premiereEdition(data, elst) else { continue }

            // `media_time` est l'endroit du signal décodé où le morceau commence
            // vraiment : c'est l'amorçage, en échantillons.
            let amorce = max(edition.debut, 0)
            var utiles: Int?
            if echelleFilm > 0, edition.duree > 0 {
                utiles = Int((edition.duree * Int64(echellePiste)) / Int64(echelleFilm))
            }
            return Info(priming: amorce, padding: 0, frames: utiles)
        }
        return nil
    }

    /// `iTunSMPB` est une chaîne de champs hexadécimaux séparés par des espaces :
    /// réservé, amorçage, remplissage, longueur utile sur seize chiffres.
    private static func lireITunSMPB(_ data: Data, _ moov: Range<Data.Index>) -> Info? {
        guard let nom = position(de: ["iTunSMPB"], dans: data, plage: moov),
              let bloc = position(de: ["data"], dans: data,
                                  plage: nom..<min(nom + 64, moov.upperBound))
        else { return nil }

        // Après le type viennent quatre octets de version et drapeaux, puis
        // quatre réservés ; la chaîne suit.
        let debut = bloc + 12
        let fin = min(debut + 160, moov.upperBound)
        guard debut < fin else { return nil }
        let texte = String(decoding: data[debut..<fin], as: UTF8.self)
        let champs = texte.split(whereSeparator: { $0 == " " || $0 == "\0" })
        guard champs.count >= 4,
              let amorce = Int(champs[1], radix: 16),
              let remplissage = Int(champs[2], radix: 16),
              let utiles = Int(champs[3], radix: 16),
              utiles > 0
        else { return nil }
        return Info(priming: amorce, padding: remplissage, frames: utiles)
    }

    private static func premiereEdition(_ data: Data,
                                        _ elst: Range<Data.Index>) -> (debut: Int, duree: Int64)? {
        let base = elst.lowerBound
        guard base + 8 <= elst.upperBound else { return nil }
        let version = data[base]
        let nombre = Int(entier32(data, base + 4))
        var p = base + 8
        for _ in 0..<nombre {
            if version == 1 {
                guard p + 20 <= elst.upperBound else { return nil }
                let duree = Int64(bitPattern: entier64(data, p))
                let debut = Int64(bitPattern: entier64(data, p + 8))
                p += 20
                // Une édition à `-1` est un blanc voulu, pas un amorçage.
                if debut >= 0 { return (Int(debut), duree) }
            } else {
                guard p + 12 <= elst.upperBound else { return nil }
                let duree = Int64(entier32(data, p))
                let debut = Int64(Int32(bitPattern: entier32(data, p + 4)))
                p += 12
                if debut >= 0 { return (Int(debut), duree) }
            }
        }
        return nil
    }

    /// Cherche une boîte d'un type donné, d'abord au premier niveau de `plage`,
    /// puis dans les boîtes de conteneur connues. La descente est guidée plutôt
    /// qu'aveugle : chercher « mdhd » n'importe où trouverait n'importe quoi.
    private static func boite(_ type: String, dans data: Data,
                              plage: Range<Data.Index>) -> Range<Data.Index>? {
        let cible = [UInt8](type.utf8)
        var p = plage.lowerBound
        while p + 8 <= plage.upperBound {
            var taille = Int(entier32(data, p))
            var entete = 8
            if taille == 1 {
                guard p + 16 <= plage.upperBound else { return nil }
                taille = Int(entier64(data, p + 8))
                entete = 16
            } else if taille == 0 {
                taille = plage.upperBound - p
            }
            guard taille >= entete, p + taille <= plage.upperBound else { return nil }
            if data[p + 4] == cible[0], data[p + 5] == cible[1],
               data[p + 6] == cible[2], data[p + 7] == cible[3] {
                return (p + entete)..<(p + taille)
            }
            p += taille
        }
        return nil
    }

    private static func entier32(_ data: Data, _ i: Data.Index) -> UInt32 {
        (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func entier64(_ data: Data, _ i: Data.Index) -> UInt64 {
        (UInt64(entier32(data, i)) << 32) | UInt64(entier32(data, i + 4))
    }

    // ══════════════════════════════════════════════════════════════════════ MP3

    /// Le retard que tout décodeur MP3 ajoute, par construction du format.
    ///
    /// Il ne dépend pas du codeur : c'est la latence du banc de filtres et de la
    /// transformée. La balise LAME ne compte que le retard *du codeur* ; les deux
    /// s'additionnent.
    private static let retardDecodeurMP3 = 529

    private static func lireMP3(_ data: Data) -> Info? {
        var debut = data.startIndex
        // Une étiquette ID3v2 précède souvent le son ; sa taille est écrite sur
        // sept bits par octet, l'octet de poids fort restant à zéro pour ne
        // jamais imiter une synchronisation.
        if data.count > 10, data[debut] == 0x49, data[debut + 1] == 0x44,
           data[debut + 2] == 0x33 {
            let taille = (Int(data[debut + 6]) << 21) | (Int(data[debut + 7]) << 14)
                       | (Int(data[debut + 8]) << 7) | Int(data[debut + 9])
            debut += 10 + taille
        }
        guard debut + 4 <= data.endIndex, data[debut] == 0xFF,
              (data[debut + 1] & 0xE0) == 0xE0 else { return nil }

        // La place de l'en-tête de flux dépend de la version et du nombre de
        // canaux, parce qu'il vient après les données latérales dont la taille
        // varie. La chercher à l'aveugle tomberait sur du son.
        let version = (data[debut + 1] >> 3) & 0x03    // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let mode = (data[debut + 3] >> 6) & 0x03       // 3 = mono
        let mpeg1 = version == 3
        let lateral = mpeg1 ? (mode == 3 ? 17 : 32) : (mode == 3 ? 9 : 17)
        let parTrame = mpeg1 ? 1152 : 576

        let xing = debut + 4 + lateral
        guard xing + 8 <= data.endIndex else { return nil }
        let etiquette = String(decoding: data[xing..<(xing + 4)], as: UTF8.self)
        guard etiquette == "Xing" || etiquette == "Info" else { return nil }

        // Les drapeaux disent quels champs facultatifs suivent ; la balise du
        // codeur vient après eux, à une place qui se calcule exactement.
        let drapeaux = entier32(data, xing + 4)
        var p = xing + 8
        var trames = 0
        if drapeaux & 0x1 != 0 {
            guard p + 4 <= data.endIndex else { return nil }
            trames = Int(entier32(data, p)); p += 4
        }
        if drapeaux & 0x2 != 0 { p += 4 }              // taille en octets
        if drapeaux & 0x4 != 0 { p += 100 }            // table de positions
        if drapeaux & 0x8 != 0 { p += 4 }              // indicateur de qualité
        guard trames > 0 else { return nil }

        // La balise du codeur : neuf octets de nom, puis, au décalage 0x15,
        // douze bits d'amorçage et douze de remplissage.
        var amorceCodeur = 0, remplissageCodeur = 0
        if p + 0x18 <= data.endIndex {
            let a = Int(data[p + 0x15]), b = Int(data[p + 0x16]), c = Int(data[p + 0x17])
            amorceCodeur = (a << 4) | (b >> 4)
            remplissageCodeur = ((b & 0x0F) << 8) | c
        }

        // Ce que la trame d'en-tête et le codeur ajoutent au signal :
        //
        //   — la trame qui porte `Xing` est du silence, et elle est décodée ;
        //   — le codeur a préfixé `amorceCodeur` échantillons ;
        //   — tout décodeur en ajoute 529 par construction du format ;
        //   — le remplissage de fin est amputé de ces mêmes 529.
        //
        // `trames` ne compte pas la trame d'en-tête, d'où la longueur utile.
        let utiles = trames * parTrame - amorceCodeur - remplissageCodeur
        guard utiles > 0 else { return nil }
        return Info(priming: parTrame + amorceCodeur + retardDecodeurMP3,
                    padding: max(remplissageCodeur - retardDecodeurMP3, 0),
                    frames: utiles)
    }

    private static func position(de motifs: [String], dans data: Data,
                                 plage: Range<Data.Index>) -> Data.Index? {
        for motif in motifs {
            let octets = [UInt8](motif.utf8)
            var p = plage.lowerBound
            while p + octets.count <= plage.upperBound {
                var trouve = true
                for k in 0..<octets.count where data[p + k] != octets[k] {
                    trouve = false
                    break
                }
                if trouve { return p }
                p += 1
            }
        }
        return nil
    }
}
