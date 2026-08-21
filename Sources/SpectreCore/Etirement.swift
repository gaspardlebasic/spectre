import Foundation

/// Ralentir sans descendre, transposer sans allonger.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI C'EST ÉCRIT ICI PLUTÔT QUE PRIS AILLEURS
///
/// macOS a `AVAudioUnitTimePitch`, et il existe des bibliothèques faites pour
/// cela. Aucune ne traverse : celle d'Apple n'existe que chez Apple, et les autres
/// s'embarquent — un en-tête de plusieurs mégaoctets à verser dans le dépôt, à
/// construire et à distribuer, pour un rouage dont on peut écrire la version qu'on
/// veut en deux cents lignes.
///
/// C'est la même décision que la FFT écrite à la main plutôt que PFFFT, et que les
/// demi-flottants écrits à la main plutôt que `Float16` : **une frontière qu'on ne
/// peut pas mesurer des deux côtés n'est qu'une promesse.** Celle-ci se mesure,
/// dans `Tools/EtirementCheck`, et elle vaut pour les trois plateformes.
///
/// La méthode est celle qu'on appelle SOLA — on découpe le signal en grains, on
/// les recolle à une cadence différente, et on cherche à chaque fois le décalage
/// qui raccorde le mieux au grain précédent. C'est ce que fait un vocodeur de
/// phase en plus fruste, et c'est correct jusque vers le quart de la vitesse, ce
/// qui couvre largement ce qu'on demande à un outil de transcription.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Vitesse et hauteur sont **indépendantes**, et c'est tout l'intérêt : on ralentit
/// un passage sans qu'il descende d'une octave, et on transpose un morceau sans
/// qu'il s'allonge.
///
///   - la position de lecture avance de `vitesse` image par image rendue, ce qui
///     donne le tempo ;
///   - à l'intérieur d'un grain, on lit avec un pas de `2^(demiTons/12)`, ce qui
///     donne la hauteur.
///
/// Les deux réglages ne se gênent donc pas, et le neutre est exact au bit près.
public struct Etireur {

    /// Longueur d'un grain, en images de sortie.
    ///
    /// 2 048 images font 46 ms à 44,1 kHz. Plus court, les basses n'ont pas la
    /// place de faire une période et deviennent granuleuses ; plus long, les
    /// attaques se dédoublent parce qu'un même coup se retrouve dans deux grains
    /// recollés à des instants différents.
    public static let longueurDuGrain = 2048
    /// Recouvrement de moitié : c'est ce qui fait que deux fenêtres de Hann
    /// voisines s'additionnent à un, et donc que le niveau ne bat pas.
    private static var saut: Int { longueurDuGrain / 2 }
    /// De combien on a le droit de déplacer un grain pour mieux le raccorder.
    ///
    /// 256 images font 5,8 ms, soit une période de 172 Hz : assez pour rattraper la
    /// phase de tout ce qui est au-dessus des plus basses fondamentales, et assez
    /// peu pour qu'un déplacement ne s'entende pas comme un tremblement du tempo.
    private static let recherche = 256

    public let sampleRate: Double

    /// Vitesse de lecture. 1 = normale, 0,5 = deux fois plus lent.
    public var vitesse: Double = 1
    /// Transposition, en demi-tons. Fractionnaire : sert aussi à recaler un
    /// enregistrement désaccordé.
    public var demiTons: Double = 0

    /// Ni ralenti ni transposé : les échantillons passent tels quels.
    ///
    /// Le court-circuit n'est pas une optimisation, c'est une garantie. Un
    /// recollage laissé en service à ×1 et +0 continue de découper et de raccorder
    /// pour un résultat *censé* être identique — travail inutile, irrégulier, et
    /// qui ne rend jamais exactement l'original. Court-circuité, le neutre est le
    /// fichier.
    public var estNeutre: Bool { vitesse == 1 && demiTons == 0 }

    /// Le pas de lecture à l'intérieur d'un grain.
    private var pas: Double { pow(2, demiTons / 12) }

    // Le tampon d'entrée, et l'indice absolu de sa première image.
    private var entree: [Float] = []
    private var lecture: Double = 0          // position dans `entree`, en images
    private var finDeSource = false

    // L'accumulateur de sortie : ce qui est recollé mais pas encore rendu.
    private var accumulateur: [Float] = []
    private var pretes = 0                   // images prêtes en tête d'accumulateur
    private var ecriture = 0                 // où le prochain grain sera ajouté
    private var premierGrain = true

    private let fenetre: [Float]

    public init(sampleRate: Double) {
        self.sampleRate = max(sampleRate, 1)
        let n = Etireur.longueurDuGrain
        // Hann, en périodique et non en symétrique : c'est la forme qui redonne
        // exactement un quand on l'additionne à elle-même décalée de moitié.
        fenetre = (0..<n).map { i in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)))
        }
    }

    /// Images déjà tirées de la source mais pas encore entendues.
    ///
    /// La position que l'application affiche est celle de ce qui **sort**, pas de ce
    /// qu'on a lu d'avance : sans ce retrait, la tête de lecture prendrait un demi
    /// grain d'avance sur le son — 23 ms, ce qui se voit quand on cale une boucle.
    public var enAttente: Int {
        guard !estNeutre else { return 0 }
        let restantEnEntree = Double(entree.count) - lecture
        // Ce qui reste en entrée sera entendu à la vitesse `vitesse` ; ce qui est
        // déjà recollé, lui, est en images de sortie et s'entend tel quel.
        return max(Int(restantEnEntree) - pretes, 0)
    }

    /// Vide tout. À appeler sur un saut : les grains en réserve portent le passage
    /// d'avant, et les entendre après un saut fait un raccord.
    public mutating func reinitialiser() {
        entree.removeAll(keepingCapacity: true)
        accumulateur.removeAll(keepingCapacity: true)
        lecture = 0
        pretes = 0
        ecriture = 0
        premierGrain = true
        finDeSource = false
    }

    /// Remplit `sortie` avec `images` images, en tirant de la source ce qu'il faut.
    ///
    /// `alimenter` reçoit un tampon à remplir et rend le nombre d'images qu'il a
    /// réellement produites ; moins que demandé signifie la fin de la source.
    ///
    /// - Returns: le nombre d'images rendues. Moins que demandé signifie que la
    ///   source est épuisée et que tout ce qui restait a été rendu.
    @discardableResult
    public mutating func rendre(into sortie: UnsafeMutableBufferPointer<Float>,
                                images: Int,
                                alimenter: (UnsafeMutableBufferPointer<Float>, Int) -> Int)
        -> Int {
        guard images > 0 else { return 0 }

        // Le neutre ne passe pas par ici : il n'y a rien à recoller, et le faire
        // quand même rendrait un signal qui n'est plus le fichier.
        if estNeutre {
            if !entree.isEmpty || !accumulateur.isEmpty { reinitialiser() }
            return alimenter(sortie, images)
        }

        var rendues = 0
        while rendues < images {
            if pretes == 0 {
                guard fabriquerUnGrain(alimenter) else { break }
            }
            let n = min(pretes, images - rendues)
            for i in 0..<n { sortie[rendues + i] = accumulateur[i] }
            accumulateur.removeFirst(n)
            ecriture -= n
            pretes -= n
            rendues += n
        }
        for i in rendues..<images { sortie[i] = 0 }
        return rendues
    }

    // MARK: Un grain

    /// Recolle un grain de plus, et rend `false` quand la source est épuisée.
    private mutating func fabriquerUnGrain(
        _ alimenter: (UnsafeMutableBufferPointer<Float>, Int) -> Int) -> Bool {

        let L = Etireur.longueurDuGrain
        let H = Etireur.saut
        let pas = self.pas

        // Ce que le grain va lire : `L` échantillons au pas `pas`, plus la marge de
        // recherche des deux côtés.
        let besoin = Int(ceil(lecture + Double(L) * pas)) + Etireur.recherche + 2
        if !remplir(jusqua: besoin, alimenter) { return false }

        // Le décalage qui raccorde le mieux au grain précédent.
        //
        // Sans lui, deux grains voisins se recollent avec des phases quelconques et
        // le son bat — c'est le défaut qui distingue un recollage naïf d'un SOLA.
        var decalage = 0
        if !premierGrain {
            decalage = meilleurDecalage(pas: pas)
        }
        premierGrain = false
        let depart = lecture + Double(decalage)

        // La place où écrire, dans l'accumulateur.
        if accumulateur.count < ecriture + L {
            accumulateur.append(contentsOf:
                repeatElement(0, count: ecriture + L - accumulateur.count))
        }

        for i in 0..<L {
            let p = depart + Double(i) * pas
            accumulateur[ecriture + i] += interpole(p) * fenetre[i]
        }

        ecriture += H
        // La position de lecture avance au rythme de la **vitesse**, et non de celui
        // du grain : c'est là, et là seulement, que se décide le tempo.
        lecture += Double(H) * vitesse
        pretes = min(ecriture, accumulateur.count)

        // Ce qui est devant la position de lecture ne resservira plus, moins la
        // marge de recherche du grain suivant.
        let aJeter = Int(lecture) - Etireur.recherche - 1
        if aJeter > L {
            entree.removeFirst(aJeter)
            lecture -= Double(aJeter)
        }
        return true
    }

    /// Cherche, autour de la position de lecture, l'endroit dont le début ressemble
    /// le plus à la fin de ce qui est déjà recollé.
    private func meilleurDecalage(pas: Double) -> Int {
        let H = Etireur.saut
        // On compare sur un quart de grain : assez pour juger, et quatre fois moins
        // cher qu'une comparaison sur le recouvrement entier.
        let n = min(H, 512)
        guard ecriture + n <= accumulateur.count else { return 0 }

        var meilleur = 0
        var meilleureNote = -Double.infinity
        var d = -Etireur.recherche
        while d <= Etireur.recherche {
            let depart = lecture + Double(d)
            if depart < 0 || depart + Double(n) * pas + 1 >= Double(entree.count) {
                d += 4
                continue
            }
            // Corrélation, normalisée par l'énergie du candidat : sans la
            // normalisation, le décalage le plus fort gagne toujours, et le
            // raccord suit le volume au lieu de suivre la phase.
            var produit = 0.0
            var energie = 1e-9
            for i in 0..<n {
                let a = Double(accumulateur[ecriture + i])
                let b = Double(interpole(depart + Double(i) * pas))
                produit += a * b
                energie += b * b
            }
            let note = produit / energie.squareRoot()
            if note > meilleureNote { meilleureNote = note; meilleur = d }
            // Un pas de quatre : la recherche coûte quatre fois moins, et un
            // décalage à quatre images près suffit — au-delà de 5 kHz, ce que
            // l'oreille juge dans un raccord n'est plus la phase.
            d += 4
        }
        return meilleur
    }

    /// L'échantillon à une position fractionnaire, par interpolation linéaire.
    ///
    /// Linéaire et non sinc : le pas ne dépasse jamais deux — deux octaves de
    /// transposition — et à ce régime le repliement qu'elle laisse passer est très
    /// en dessous de ce que le recollage lui-même produit.
    private func interpole(_ p: Double) -> Float {
        if p <= 0 { return entree.first ?? 0 }
        let i = Int(p)
        guard i + 1 < entree.count else { return entree.last ?? 0 }
        let f = Float(p - Double(i))
        return entree[i] + (entree[i + 1] - entree[i]) * f
    }

    /// Tire de la source jusqu'à avoir `besoin` images en tampon.
    private mutating func remplir(jusqua besoin: Int,
                                  _ alimenter: (UnsafeMutableBufferPointer<Float>, Int) -> Int)
        -> Bool {
        while entree.count < besoin {
            if finDeSource {
                // La source est finie : on complète de silence pour que le dernier
                // grain sorte entier plutôt que tronqué net.
                if entree.count >= Int(lecture) + Etireur.longueurDuGrain {
                    break
                }
                entree.append(contentsOf: repeatElement(0, count: besoin - entree.count))
                break
            }
            let manque = besoin - entree.count
            let debut = entree.count
            entree.append(contentsOf: repeatElement(0, count: manque))
            let obtenues = entree.withUnsafeMutableBufferPointer { tampon -> Int in
                let vue = UnsafeMutableBufferPointer(rebasing: tampon[debut...])
                return alimenter(vue, manque)
            }
            if obtenues < manque {
                entree.removeLast(manque - obtenues)
                finDeSource = true
            }
        }
        // Épuisé pour de bon : plus rien à lire, et plus rien à recoller.
        return Double(entree.count) > lecture
    }
}
