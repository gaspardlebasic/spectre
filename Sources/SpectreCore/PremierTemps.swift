import Foundation

/// La grille métrique, reprise sur la batterie.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI UN SECOND PASSAGE, ET POURQUOI SUR LA BATTERIE
///
/// `TempoEstimator` lit le flux spectral du mixage : tout ce qui monte compte, une
/// attaque de piano comme un coup de caisse claire. Cela suffit à trouver la
/// **période** — c'est une question de régularité, et la régularité survit au
/// mélange. Cela ne suffit pas à trouver le **premier temps**, pour deux raisons
/// qui se cumulent :
///
/// - la caisse claire est ce qui monte le plus haut et le plus large dans le
///   spectre, si bien que la recherche du temps fort tombe volontiers sur le
///   contretemps — sur le morceau témoin, elle plaçait le « un » à 1,5 s, soit sur
///   le quatrième temps, alors que le morceau commence pile sur un temps ;
/// - « le temps qui porte le plus d'énergie » n'est pas une définition du temps
///   fort. Le temps fort, c'est celui où la grosse caisse tombe, où la caisse
///   claire ne tombe pas, où la cymbale s'ouvre, et où l'harmonie change.
///
/// Ces quatre indices demandent qu'on sache **quel** instrument a joué, ce que le
/// mixage ne dit pas et ce que la piste de batterie dit très bien. D'où ce second
/// passage, qui arrive quand la séparation est finie et reprend la grille avec ce
/// qu'elle a appris : les coups relevés voie par voie, et le changement d'harmonie
/// lu dans l'image — laquelle, une fois séparée, n'a plus de percussions pour la
/// brouiller.
///
/// Ce qui n'est pas fait ici, et délibérément : **corriger la période du simple au
/// double.** Presque toute batterie pose un charleston sur les croches ; une
/// recherche libre y trouverait la demi-période aussi bien que la bonne, et
/// remplacerait une erreur rare par une erreur systématique. L'octave du tempo
/// reste donc l'affaire de `TempoEstimator`, qui la tranche par un a priori centré
/// sur 120 BPM.
/// ─────────────────────────────────────────────────────────────────────────────
public enum PremierTemps {

    // MARK: Ce qui se règle

    /// Écart de période exploré autour de la grille reçue, de part et d'autre.
    ///
    /// Un pour cent et demi, et pas davantage : c'est ce qu'il faut pour rattraper
    /// l'arrondi à l'entier de `TempoEstimator` — une demi-BPM vaut 0,8 % à 60 BPM —
    /// et pas assez pour aller chercher un autre tempo. Élargir la fenêtre ne
    /// donnerait pas une meilleure réponse, elle donnerait une autre question.
    private static let marge = 0.015

    /// Ce que chaque voie pèse dans la recherche de la pulsation.
    ///
    /// Le charleston compte moins, et ce n'est pas une question de force : il joue
    /// les croches, donc une fois sur deux à contretemps. Ces coups-là ne se
    /// contredisent pas — dans la somme vectorielle, un contretemps annule
    /// exactement le temps qui le précède — mais ils diluent la mesure sans rien
    /// lui apprendre.
    private static func poids(_ voix: DrumVoice) -> Double {
        switch voix {
        case .kick: 1
        case .snare: 1
        case .cymbal: 0.35
        }
    }

    /// En dessous, il n'y a pas de batterie à lire — un morceau qui n'en a pas, une
    /// piste que la séparation a rendue vide.
    private static let minimumDeCoups = 16

    /// Part de l'énergie des coups qui doit se retrouver alignée sur la pulsation
    /// pour qu'on croie ce qu'on vient de mesurer.
    ///
    /// C'est `|Z| / Σw` : un batteur qui joue rigoureusement en place donne 1, un
    /// nuage de coups sans pulsation donne 0. En dessous du seuil, la grille reçue
    /// est laissée telle quelle — mieux vaut une grille imparfaite qu'une grille
    /// posée au hasard sur ce qui n'en est pas une.
    private static let accrocheMinimale = 0.22

    /// Poids du changement d'harmonie et de la cymbale ouverte dans le choix du
    /// temps fort, une fois la pulsation trouvée.
    ///
    /// Ils départagent ce que la batterie seule ne peut pas départager. Grosse
    /// caisse aux temps 1 et 3, caisse claire aux 2 et 4 : c'est le motif de la
    /// moitié de la musique enregistrée, et il donne **exactement** la même note au
    /// premier et au troisième temps. Ce qui les sépare est ailleurs — l'accord
    /// change sur le « un » et pas sur le « trois », et c'est sur le « un » qu'une
    /// cymbale s'ouvre.
    private static let poidsDeLHarmonie = 1.3
    private static let poidsDeLaCymbale = 0.6

    // MARK: - Le tour complet

    /// La grille d'un morceau dont on a le signal, batterie comprise : on l'estime,
    /// puis on la reprend.
    ///
    /// C'est la porte des lignes de commande, qui ont le signal et pas le relevé.
    /// L'application, elle, a déjà relevé la batterie pour sa ligne du bas et appelle
    /// `affiner` directement — refaire une détection de percussions coûterait une
    /// seconde pour redonner ce qui est déjà en mémoire.
    public static func grille(_ image: Spectrogram, signal: [Float], frequence: Double,
                              tempsParMesure: Int = 4) -> TempoGrid? {
        guard let estimée = TempoEstimator.estimate(image, beatsPerBar: tempsParMesure)
        else { return nil }
        let batterie = PercussionDetector.detect(samples: signal, sampleRate: frequence)
        return affiner(estimée, batterie: batterie, image: image) ?? estimée
    }

    // MARK: - La reprise

    /// Reprend une grille avec ce que la batterie sait d'elle.
    ///
    /// Rend `nil` — et non la grille reçue — quand la batterie n'a rien à dire :
    /// l'appelant sait alors qu'il n'a rien appris, et peut le dire.
    public static func affiner(_ grille: TempoGrid, batterie: PercussionTrack,
                               image: Spectrogram) -> TempoGrid? {
        let coups = batterie.hits
        guard coups.count >= minimumDeCoups, grille.bpm > 0 else { return nil }
        let mesure = max(grille.beatsPerBar, 1)

        var forceTotale = 0.0
        for coup in coups { forceTotale += poids(coup.voice) * max(coup.strength, 0) }
        guard forceTotale > 0 else { return nil }

        let période = affinerLaPériode(coups, autour: 60 / grille.bpm,
                                       durée: durée(de: image, coups: coups))
        // Le tempo qu'on va **dessiner** est celui qu'on affiche, et la phase se
        // cherche avec lui : l'optimiser pour une autre période laisserait la grille
        // décalée dès la deuxième mesure. C'est la règle que `TempoEstimator` s'était
        // déjà donnée en arrondissant à l'entier.
        let bpm = tempoLisible(60 / période)
        let pas = 60 / bpm

        let (module, phase) = accroche(coups, période: pas)
        guard module / forceTotale >= accrocheMinimale else { return nil }

        let temps = numérotation(coups, phase: phase, période: pas)
        let position = tempsFort(temps, mesure: mesure, image: image,
                                 phase: phase, période: pas)

        // Le premier temps fort du morceau, et non le premier qui tombe après la
        // phase : `origin` se lit comme un instant du fichier, et un « un » posé
        // avant son début n'en est pas un.
        var origine = phase + Double(position) * pas
        let mesureEntière = pas * Double(mesure)
        origine -= (origine / mesureEntière).rounded(.down) * mesureEntière
        // Un morceau qui commence pile sur un temps tombe, au hasard du calcul, sur
        // une origine de zéro ou sur une origine d'une mesure moins un millième. Les
        // deux disent la même chose et aucune mesure ne les départage — le relevé
        // des coups est précis à cinq millisecondes —, mais elles ne se valent pas à
        // l'usage : la seconde ouvre une mesure *avant* le début du fichier, mesure
        // que rien ne pourra jamais relever ni dessiner. On tranche donc pour zéro.
        if mesureEntière - origine < pas / 20 { origine = 0 }

        return TempoGrid(bpm: bpm, origin: origine, beatsPerBar: mesure,
                         confidence: sûreté(module / forceTotale))
    }

    // MARK: - La pulsation

    private static func durée(de image: Spectrogram, coups: [DrumHit]) -> Double {
        let vue = image.duration
        return vue > 0 ? vue : (coups.last?.time ?? 0) + 1
    }

    /// L'énergie des coups repliée sur une période, et la phase où elle pointe.
    ///
    /// C'est une somme vectorielle : chaque coup est placé sur un cercle dont un tour
    /// vaut une période, avec sa force pour longueur. Des coups tous en place
    /// s'additionnent ; des coups sans pulsation se répartissent sur le cercle et
    /// s'annulent. Le module dit à quel point la batterie tient la mesure, l'argument
    /// dit **où** elle la pose — et l'un ne va pas sans l'autre, ce qui est
    /// exactement ce qu'il faut pour se méfier d'une phase trouvée sur rien.
    ///
    /// L'avantage sur un train d'impulsions promené le long de la courbe d'attaque —
    /// ce que fait `TempoEstimator` — est qu'aucune phase n'est privilégiée : il n'y
    /// a pas de pas d'échantillonnage, la réponse est continue et vaut au
    /// millième de temps.
    private static func accroche(_ coups: [DrumHit], période: Double)
        -> (module: Double, phase: Double) {
        guard période > 0 else { return (0, 0) }
        var re = 0.0, im = 0.0
        for coup in coups {
            let p = poids(coup.voice) * max(coup.strength, 0)
            let angle = 2 * .pi * coup.time / période
            re += p * cos(angle)
            im += p * sin(angle)
        }
        let module = (re * re + im * im).squareRoot()
        var phase = atan2(im, re) / (2 * .pi) * période
        if phase < 0 { phase += période }
        return (module, phase)
    }

    /// La période qui replie le mieux les coups sur eux-mêmes, tout près de celle
    /// qu'on nous donne.
    ///
    /// Le pas de la recherche n'est pas choisi : il vient de la longueur du morceau.
    /// Une erreur de période `δ` décale le dernier temps de `durée × δ / période` ;
    /// pour que deux périodes voisines ne puissent pas se manquer, il faut que ce
    /// décalage reste sous le quart d'un temps. D'où un pas de `période² / (4 × durée)`,
    /// c'est-à-dire d'autant plus fin que le morceau est long — ce qui est bien le
    /// sens de la chose : plus il dure, plus il faut être précis pour tenir jusqu'au
    /// bout.
    private static func affinerLaPériode(_ coups: [DrumHit], autour: Double,
                                         durée: Double) -> Double {
        guard autour > 0, durée > autour else { return autour }
        let étendue = 2 * marge * autour
        let fin = autour * autour / (4 * durée)
        let pas = min(max(Int((étendue / max(fin, 1e-9)).rounded()), 32), 1200)

        var meilleure = autour
        var meilleurModule = -1.0
        for i in 0...pas {
            let période = autour * (1 - marge) + étendue * Double(i) / Double(pas)
            let module = accroche(coups, période: période).module
            if module > meilleurModule {
                meilleurModule = module
                meilleure = période
            }
        }
        return meilleure
    }

    /// Le tempo tel qu'on l'écrit.
    ///
    /// `TempoEstimator` arrondit à l'entier, et il a raison de le faire : la
    /// quasi-totalité des morceaux est jouée sur un tempo rond, et trois décimales
    /// se lisent comme une certitude qu'on n'a pas. Mais tout n'est pas rond — un
    /// morceau joué à la main, un disque repiqué d'un vinyle qui ne tournait pas
    /// juste —, et forcer l'entier fait alors dériver la grille d'un temps entier
    /// avant la fin.
    ///
    /// D'où la règle : l'entier quand on en est à moins d'un vingtième, le dixième
    /// de BPM sinon — le pas de la réglette du panneau, donc une valeur que
    /// l'utilisatrice peut reprendre à la main.
    private static func tempoLisible(_ bpm: Double) -> Double {
        let borné = min(max(bpm, 20), 400)
        let entier = borné.rounded()
        if abs(borné - entier) < 0.06 { return entier }
        return (borné * 10).rounded() / 10
    }

    // MARK: - Le temps fort

    /// Un coup, rapporté au temps sur lequel il tombe.
    private struct CoupPlacé {
        let voix: DrumVoice
        let force: Double
        /// Numéro du temps depuis la phase, et non depuis le début du fichier.
        let temps: Int
    }

    /// Rattache chaque coup au temps le plus proche, et jette ceux qui n'en sont
    /// pas assez près.
    ///
    /// Le quart de temps est la porte : au-delà, on est sur une croche, une double,
    /// un roulement — quelque chose qui a sa place dans la musique et aucune dans un
    /// profil de mesure. Les laisser entrer reviendrait à compter la moitié des
    /// coups sur le temps d'à côté.
    private static func numérotation(_ coups: [DrumHit], phase: Double,
                                     période: Double) -> [CoupPlacé] {
        guard période > 0 else { return [] }
        var placés: [CoupPlacé] = []
        placés.reserveCapacity(coups.count)
        for coup in coups {
            let exact = (coup.time - phase) / période
            let temps = exact.rounded()
            guard abs(exact - temps) <= 0.25, temps >= 0 else { continue }
            placés.append(CoupPlacé(voix: coup.voice, force: max(coup.strength, 0),
                                    temps: Int(temps)))
        }
        return placés
    }

    /// Lequel des `mesure` temps est le « un ».
    ///
    /// Quatre indices, tous ramenés à une part de leur total pour qu'aucun ne dépende
    /// du nombre de coups ni du niveau d'enregistrement :
    ///
    /// - **la grosse caisse** y tombe, et c'est l'indice le plus sûr ;
    /// - **la caisse claire** n'y tombe pas : c'est le contretemps qui la porte, et
    ///   la compter en négatif est ce qui a manqué à l'ancienne recherche, laquelle
    ///   la comptait en positif comme tout le reste ;
    /// - **la cymbale ouverte** — une crash, pas un charleston — marque le début
    ///   d'une phrase ;
    /// - **l'harmonie change**, ce que la batterie ne peut pas dire et ce que
    ///   l'image dit très bien.
    private static func tempsFort(_ coups: [CoupPlacé], mesure: Int, image: Spectrogram,
                                  phase: Double, période: Double) -> Int {
        guard mesure > 1 else { return 0 }
        let grosse = profil(coups, voix: .kick, mesure: mesure)
        let claire = profil(coups, voix: .snare, mesure: mesure)
        let cymbale = profilDesCymbalesOuvertes(coups, mesure: mesure)
        let harmonie = profilDHarmonie(image, mesure: mesure, phase: phase, période: période)

        let plat = 1 / Double(mesure)
        var meilleur = 0
        var meilleurScore = -Double.infinity
        for j in 0..<mesure {
            let score = grosse[j] - claire[j]
                + poidsDeLaCymbale * (cymbale[j] - plat)
                + poidsDeLHarmonie * (harmonie[j] - plat)
            if score > meilleurScore { meilleurScore = score; meilleur = j }
        }
        return meilleur
    }

    /// Comment la force d'une voie se répartit sur les temps de la mesure, en parts
    /// dont la somme fait 1. Une voie muette rend un profil plat, qui ne départage
    /// rien — ce qui est la bonne réponse quand il n'y a rien à dire.
    private static func profil(_ coups: [CoupPlacé], voix: DrumVoice,
                               mesure: Int) -> [Double] {
        var parts = [Double](repeating: 0, count: mesure)
        var total = 0.0
        for coup in coups where coup.voix == voix {
            parts[coup.temps % mesure] += coup.force
            total += coup.force
        }
        guard total > 0 else { return [Double](repeating: 1 / Double(mesure), count: mesure) }
        return parts.map { $0 / total }
    }

    /// Les cymbales franchement plus fortes que les autres — celles qu'on ouvre.
    ///
    /// Le charleston tient les croches d'un bout à l'autre et n'apprend rien sur la
    /// mesure ; la crash, elle, ne se pose que sur les débuts. On ne garde donc que
    /// le haut de la distribution, et **on renonce à l'indice si ce haut est peuplé** :
    /// une piste dont un quart des cymbales sont « fortes » n'a pas de crash, elle a
    /// un charleston joué fort.
    private static func profilDesCymbalesOuvertes(_ coups: [CoupPlacé],
                                                  mesure: Int) -> [Double] {
        let plat = [Double](repeating: 1 / Double(mesure), count: mesure)
        let cymbales = coups.filter { $0.voix == .cymbal }
        guard cymbales.count >= mesure * 2 else { return plat }
        let ouvertes = cymbales.filter { $0.force >= 0.8 }
        guard !ouvertes.isEmpty,
              Double(ouvertes.count) <= 0.25 * Double(cymbales.count) else { return plat }

        var parts = [Double](repeating: 0, count: mesure)
        var total = 0.0
        for coup in ouvertes {
            parts[coup.temps % mesure] += coup.force
            total += coup.force
        }
        guard total > 0 else { return plat }
        return parts.map { $0 / total }
    }

    // MARK: - L'harmonie

    /// Où l'harmonie change, rapporté aux temps de la mesure.
    ///
    /// L'accord change sur le « un » bien plus souvent que sur les autres temps :
    /// c'est ce qui départage le premier temps du troisième, que la batterie seule
    /// ne sait pas départager quand la grosse caisse tombe sur les deux.
    ///
    /// Le changement se mesure entre les **chromas** de deux temps voisins, et non
    /// entre leurs spectres : replier le spectre sur douze classes de hauteur retire
    /// l'octave, qui n'a rien à voir avec le changement d'accord, et retire du même
    /// geste le renversement — une basse qui monte à la tierce sans que l'harmonie
    /// bouge ne compte alors plus pour un changement.
    ///
    /// L'image lue est celle qui est affichée : après séparation, c'est-à-dire
    /// presque toujours quand on arrive ici, la batterie n'y est plus. C'est le
    /// meilleur des cas — un chroma calculé sur des percussions ne veut rien dire.
    private static func profilDHarmonie(_ image: Spectrogram, mesure: Int,
                                        phase: Double, période: Double) -> [Double] {
        let plat = [Double](repeating: 1 / Double(mesure), count: mesure)
        guard image.columnCount > 4, image.binCount > 0, période > 0,
              image.secondsPerColumn > 0 else { return plat }

        let classes = classesDeHauteur(image.layout)
        let premier = max(Int(((0 - phase) / période).rounded(.up)), 0)
        let dernier = Int(((image.duration - phase) / période).rounded(.down))
        guard dernier - premier >= mesure * 2 else { return plat }

        // Un chroma par temps, calculé une seule fois : le changement d'un temps au
        // suivant se lit ensuite dans la liste, sans relire la matrice deux fois par
        // frontière.
        var chromas: [[Double]] = []
        chromas.reserveCapacity(dernier - premier + 1)
        for temps in premier...dernier {
            let début = phase + Double(temps) * période
            chromas.append(chroma(image, de: début, à: début + période, classes: classes))
        }

        var parts = [Double](repeating: 0, count: mesure)
        var total = 0.0
        for i in 1..<chromas.count {
            let écart = distance(chromas[i - 1], chromas[i])
            parts[(premier + i) % mesure] += écart
            total += écart
        }
        guard total > 0 else { return plat }
        return parts.map { $0 / total }
    }

    /// À quelle classe de hauteur appartient chaque ligne de la matrice.
    private static func classesDeHauteur(_ géométrie: BinLayout) -> [Int] {
        let bas = Pitch.midi(from: géométrie.minFrequency)
        let parLigne = 12 / max(géométrie.binsPerOctave, 1)
        return (0..<géométrie.binCount).map { ligne in
            let demiTon = bas + Double(ligne) * parLigne
            return ((Int(demiTon.rounded()) % 12) + 12) % 12
        }
    }

    /// Les douze classes de hauteur d'un intervalle de temps, en puissance.
    private static func chroma(_ image: Spectrogram, de t0: Double, à t1: Double,
                               classes: [Int]) -> [Double] {
        var douze = [Double](repeating: 0, count: 12)
        let c0 = max(Int(image.column(atTime: t0).rounded()), 0)
        let c1 = min(Int(image.column(atTime: t1).rounded()), image.columnCount - 1)
        guard c0 <= c1 else { return douze }
        let lignes = image.binCount
        image.values.withUnsafeBufferPointer { valeurs in
            for c in c0...c1 {
                let base = c * lignes
                for i in 0..<lignes {
                    // Les décibels reviennent en puissance : additionner des
                    // décibels n'a pas de sens, et c'est la puissance qui dit
                    // combien une raie pèse dans l'accord.
                    let db = Double(valeurs[base + i])
                    guard db > -90 else { continue }
                    douze[classes[i]] += pow(10, db / 10)
                }
            }
        }
        return douze
    }

    /// Un écart entre deux chromas, de 0 (la même harmonie) à 1 (rien de commun).
    ///
    /// C'est le cosinus, donc une comparaison de **formes** : un passage joué fort
    /// et le même joué doux ne comptent pas pour un changement, ce qui est bien ce
    /// qu'on veut d'une mesure du changement d'accord.
    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var produit = 0.0, carréA = 0.0, carréB = 0.0
        for i in 0..<12 {
            produit += a[i] * b[i]
            carréA += a[i] * a[i]
            carréB += b[i] * b[i]
        }
        let norme = (carréA * carréB).squareRoot()
        guard norme > 0 else { return 0 }
        return min(max(1 - produit / norme, 0), 1)
    }

    // MARK: - La sûreté

    /// Ramène la part d'énergie accrochée à l'échelle de `TempoGrid.confidence`,
    /// où 1 veut dire « rien de saillant » et où le panneau se méfie sous 2.
    ///
    /// Une batterie parfaitement en place accroche tout et rend une confiance très
    /// haute ; une batterie qui traîne accroche la moitié et rend 2, soit le seuil
    /// à partir duquel on cesse d'écrire « ≈ » devant le tempo. Le plafond évite
    /// qu'un morceau programmé à la machine n'affiche une certitude infinie.
    private static func sûreté(_ accrochée: Double) -> Double {
        min(1 / max(1 - accrochée, 0.05), 20)
    }
}
