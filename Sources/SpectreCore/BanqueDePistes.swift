import Foundation
import SpectreDSP

/// Les quatre pistes d'un morceau, décodées, en mémoire, pour toute la séance.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI LA MÉMOIRE PLUTÔT QUE LE DISQUE
///
/// Les pistes ont longtemps vécu en fichiers, et toute combinaison qu'on écoutait
/// en fabriquait un de plus : sommer, écrire un FLAC, le relire, le décoder. Sur un
/// morceau de huit minutes, cela coûtait vingt secondes après la séparation — pendant
/// lesquelles la barre restait figée à 80 % — et jusqu'à sept secondes à chaque fois
/// qu'on cochait une piste. Le calcul lui-même, la somme, en occupe un demi-quart :
/// tout le reste était de l'encodage et du décodage d'un signal qu'on venait de
/// produire.
///
/// Le FLAC reste, pour le **rangement** : deux fois et demie moins de place, et il
/// faut bien retrouver le morceau demain. Mais il ne sert plus qu'une fois, à
/// l'ouverture, et il s'écrit derrière la fenêtre plutôt que devant.
///
/// LE STOCKAGE EST D'UN SEUL TENANT, ET IL EST À NOUS
///
/// Un `[[Float]]` par piste aurait suffi au modèle, mais pas au fil audio : Swift ne
/// promet pas qu'un tableau garde la même adresse, et le rappel de rendu n'a le droit
/// ni d'allouer ni de retenir un objet. D'où une allocation unique, dont l'adresse ne
/// bouge plus de la vie de la banque, et dans laquelle le rendu lit directement.
///
/// La disposition est `[piste][canal][image]` : les images d'un même canal se suivent,
/// ce qui est l'ordre dans lequel tout le monde les parcourt.
/// ─────────────────────────────────────────────────────────────────────────────
public final class BanqueDePistes {
    /// Le morceau dont ces pistes viennent. Comparé avant de s'en servir : une
    /// banque qui traîne d'un morceau précédent ne doit jamais se faire prendre pour
    /// celle du morceau ouvert.
    public let empreinte: String
    public let sampleRate: Double
    public let frameCount: Int
    public let channels: Int
    /// L'ordre des pistes dans le stockage. C'est lui qu'indexent les masques.
    public let ordre: [Stem]

    /// Le bloc unique. Public parce que le fil audio y lit sans passer par personne ;
    /// personne d'autre n'a de raison d'y toucher.
    public let echantillons: UnsafeMutablePointer<Float>

    public var duration: Double {
        sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }

    /// Combien d'octets cette banque occupe. Sert aux comptes rendus — un morceau de
    /// huit minutes en pèse 660 millions.
    public var poids: Int {
        ordre.count * channels * frameCount * MemoryLayout<Float>.size
    }

    /// Construit la banque **en vidant le dictionnaire au fur et à mesure**.
    ///
    /// Sans cela, le temps de la copie, les pistes existeraient deux fois : 1,3 Go sur
    /// un morceau de huit minutes, au moment précis où le réseau vient de rendre la
    /// main et où la mémoire est déjà au plus haut. Chaque piste recopiée est retirée
    /// du dictionnaire, donc libérée : le sommet ne dépasse plus d'une piste.
    public init?(empreinte: String, sampleRate: Double, pistes: inout [Stem: [[Float]]]) {
        let présentes = Stem.separated.filter { pistes[$0] != nil }
        guard !présentes.isEmpty,
              let première = pistes[présentes[0]], !première.isEmpty else { return nil }
        let canaux = première.count
        let images = première.first?.count ?? 0
        guard canaux > 0, images > 0 else { return nil }

        self.empreinte = empreinte
        self.sampleRate = sampleRate
        self.frameCount = images
        self.channels = canaux
        self.ordre = présentes
        self.echantillons = .allocate(capacity: présentes.count * canaux * images)
        // Une piste plus courte que la première laisserait des flottants indéterminés
        // en fin de bloc, qu'on entendrait. On part d'un bloc à zéro.
        self.echantillons.initialize(repeating: 0, count: présentes.count * canaux * images)

        for (rang, piste) in présentes.enumerated() {
            guard let canauxDeLaPiste = pistes.removeValue(forKey: piste) else { continue }
            for c in 0..<min(canaux, canauxDeLaPiste.count) {
                let combien = min(images, canauxDeLaPiste[c].count)
                canauxDeLaPiste[c].withUnsafeBufferPointer { source in
                    (echantillons + (rang * canaux + c) * images)
                        .update(from: source.baseAddress!, count: combien)
                }
            }
        }
    }

    deinit { echantillons.deallocate() }

    // MARK: Où trouver une piste

    public func rang(_ piste: Stem) -> Int? { ordre.firstIndex(of: piste) }

    /// Le début d'un canal d'une piste, dans le bloc.
    public func debut(_ piste: Stem, canal: Int) -> UnsafePointer<Float>? {
        guard let rang = rang(piste), canal >= 0, canal < channels else { return nil }
        return UnsafePointer(echantillons + (rang * channels + canal) * frameCount)
    }

    /// Les pistes voulues, ramenées à un masque de bits sur `ordre`.
    ///
    /// C'est sous cette forme que la sélection traverse la frontière du fil audio :
    /// un seul mot de 32 bits, aligné, qu'on remplace d'un coup. Le rendu lit donc
    /// toujours une sélection cohérente — jamais la moitié de l'ancienne et la moitié
    /// de la nouvelle — sans qu'un verrou ait à entrer dans le rappel.
    public func masque(_ pistes: Set<Stem>) -> UInt32 {
        var bits: UInt32 = 0
        for (rang, piste) in ordre.enumerated() where pistes.contains(piste) {
            bits |= 1 << UInt32(rang)
        }
        return bits
    }

    // MARK: Ce qu'on en tire

    /// Une piste seule, recopiée canal par canal. Sert à l'écrire sur le disque.
    public func canauxDe(_ piste: Stem) -> [[Float]]? {
        guard rang(piste) != nil else { return nil }
        return (0..<channels).map { c in
            [Float](UnsafeBufferPointer(start: debut(piste, canal: c)!, count: frameCount))
        }
    }

    /// La somme des pistes demandées, canal par canal.
    public func melangeStereo(_ pistes: Set<Stem>) -> [[Float]] {
        let voulues = ordre.filter(pistes.contains)
        guard !voulues.isEmpty else { return [] }
        return (0..<channels).map { c in
            var somme = [Float](repeating: 0, count: frameCount)
            somme.withUnsafeMutableBufferPointer { sortie in
                for piste in voulues {
                    Vector.addScaled(debut(piste, canal: c)!, times: 1,
                                     into: sortie.baseAddress!, count: frameCount)
                }
            }
            return somme
        }
    }

    /// La somme des pistes demandées, canaux moyennés.
    ///
    /// **Moyennés et non additionnés** : c'est ce que fait le décodeur pour le mixage,
    /// et l'analyse compare les deux images. Sommer ici rendrait toute piste isolée
    /// six décibels plus haute que le mixage dont elle sort, et le contraste
    /// d'ouverture sauterait à chaque bascule.
    public func melangeMono(_ pistes: Set<Stem>) -> [Float] {
        let voulues = ordre.filter(pistes.contains)
        guard !voulues.isEmpty else { return [] }
        let gain = 1 / Float(channels)
        var somme = [Float](repeating: 0, count: frameCount)
        somme.withUnsafeMutableBufferPointer { sortie in
            for piste in voulues {
                for c in 0..<channels {
                    Vector.addScaled(debut(piste, canal: c)!, times: gain,
                                     into: sortie.baseAddress!, count: frameCount)
                }
            }
        }
        return somme
    }

    /// Les quatre pistes sont-elles là ? Une banque incomplète — un fichier illisible
    /// sur les quatre — ne doit pas faire croire le morceau séparé.
    public var complete: Bool { ordre.count == Stem.separated.count }
}
