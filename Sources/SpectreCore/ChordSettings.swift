import Foundation
import SpectreTextes

/// Les réglages du relevé d'accords.
///
/// Ce sont de bons choix moyens, et un bon choix moyen est toujours mauvais quelque
/// part : une ballade au piano, un morceau de funk où la basse joue plus de notes
/// que l'accompagnement et un enregistrement saturé ne demandent pas les mêmes
/// équilibres. Les sortir du code, c'est admettre qu'aucune valeur ne vaut pour
/// toute la musique.
///
/// Ils se lisent tous dans la même langue, celle du relevé par raies : une raie est
/// **visible** au-dessus d'une certaine clarté, elle est **tenue** si elle occupe
/// assez de l'intervalle, elle est **expliquée** si une raie plus grave la porte
/// dans ses harmoniques — et l'accord retenu est celui qui rend compte du mieux
/// possible de ce qui reste.
public struct ChordSettings: Equatable, Hashable, Codable, Sendable {

    /// Sur quelle durée un accord se décide.
    public enum Scope: Int, CaseIterable, Codable, Sendable {
        /// Un accord par temps, lissé par le passage de Viterbi. Il sait dire qu'on
        /// change d'accord au milieu d'une mesure, au prix d'une décision prise sur
        /// très peu de son — et d'un lissage qui efface parfois un accord de passage.
        case beat = 0
        /// Un accord par mesure. Chaque décision porte alors sur quatre fois plus
        /// de matière, et n'est lissée par rien : ce qu'on lit est ce que la mesure
        /// contient.
        case span = 1

        public var label: String {
            switch self {
            case .beat: T(.porteeParTemps)
            case .span: T(.porteeParMesure)
            }
        }
    }

    /// Ce que le détecteur s'autorise à nommer.
    ///
    /// Le vocabulaire le plus riche n'est pas le plus juste. Restreindre est souvent
    /// le réglage qui améliore le plus un relevé : sur un morceau qui n'a que des
    /// triades, retirer les septièmes retire d'un coup toutes les erreurs possibles.
    public enum Vocabulary: Int, CaseIterable, Codable, Sendable {
        case triads = 0, sevenths = 1, all = 2, extended = 3

        public var label: String {
            switch self {
            case .triads: T(.vocabulaireTriades)
            case .sevenths: T(.vocabulaireSeptiemes)
            case .all: T(.vocabulaireTout)
            case .extended: T(.vocabulaireEnrichis)
            }
        }

        public var qualities: [ChordQuality] {
            switch self {
            case .triads: [.major, .minor, .suspended4]
            case .sevenths: [.major, .minor, .suspended4, .dominant7, .minor7, .major7]
            case .all: [.major, .minor, .suspended4, .dominant7, .minor7, .major7,
                        .halfDiminished, .diminished, .augmented, .major6, .minor6]
            case .extended: ChordQuality.allCases
            }
        }
    }

    /// Le temps par défaut : c'est la portée qui sait montrer un changement d'accord
    /// au milieu d'une mesure, et c'est ce qu'on demande le plus souvent à un relevé.
    ///
    /// Elle a son prix, et il est mesuré : sur le fichier témoin, découper au temps
    /// laisse deux fois plus de raies inexpliquées et un tiers de noms sûrs en moins
    /// que découper à la mesure — un temps porte rarement assez de notes tenues pour
    /// se décider seul, et le lissage de Viterbi rattrape le reste. La mesure reste
    /// offerte pour les morceaux qui tiennent leur harmonie.
    ///
    /// Ce choix ne coûte plus la lecture d'un passage : **une sélection est une
    /// portée dans les deux modes** — voir `ChordDetector.detect`.
    public var scope: Scope = .beat
    /// Les enrichissements compris, par défaut. Sur le fichier témoin, les écrire
    /// fait tomber les raies tenues sans explication de 7,2 % à 4,3 %, et le nombre
    /// de mesures qui en portent une de 27 % à 16 % : ce n'étaient pas des erreurs du
    /// relevé, c'étaient des notes que le vocabulaire ne savait pas nommer.
    public var vocabulary: Vocabulary = .extended

    /// Clarté à partir de laquelle une raie compte comme visible, de 0 à 1.
    ///
    /// La même échelle que l'image : 0 est le noir réglé, 1 le blanc. C'est le
    /// pivot de tout le relevé — la frontière entre ce qui est joué et ce qui ne
    /// l'est pas passe par là, et elle se règle aussi bien avec ce curseur qu'avec
    /// celui du contraste. La valeur par défaut est celle de l'aimantation du
    /// curseur, pour que ce qui attire la souris et ce qui nourrit le relevé soient
    /// la même chose.
    public var clarity: Double = 0.12

    /// Part de l'intervalle pendant laquelle une raie doit être visible pour compter
    /// comme tenue.
    ///
    /// À 1, il faudrait une note absolument continue — ce qu'aucun instrument pincé
    /// ne fait. À 0,5, la moitié suffit et les notes de passage entrent dans
    /// l'accord. C'est le réglage qui décide de ce qu'est une « note de l'accord »
    /// plutôt qu'une broderie.
    public var hold: Double = 0.7

    /// De combien un sommet doit dominer les creux qui l'entourent, en dB.
    ///
    /// C'est le réglage qui décide de ce qu'est une **raie**. Sans lui, la traînée
    /// d'une note forte — les ondulations que toute fenêtre d'analyse laisse autour
    /// d'un pic — devient une note un demi-ton à côté : sur le fichier témoin, la
    /// neuvième bémol était la deuxième « note inexpliquée » la plus fréquente, ce
    /// qu'aucune musique ne justifie. Le monter ne garde que les traits francs.
    public var prominence: Double = 5

    /// Décroissance supposée des harmoniques, en dB par doublement du rang.
    ///
    /// Une raie deux octaves au-dessus d'une note grave n'a pas à être aussi forte
    /// pour être crue : on attend d'une quatrième harmonique qu'elle soit bien plus
    /// faible que d'une deuxième. Sans cette pente, une basse un peu forte expliquait
    /// tout ce qui était joué au-dessus d'elle et l'accord se réduisait à sa basse.
    public var harmonicDrop: Double = 9

    /// De combien une raie doit dépasser ce que l'harmonique expliquerait, en dB,
    /// pour être gardée quand même.
    ///
    /// Une harmonique est plus faible que sa fondamentale ; une raie franchement plus
    /// forte contient donc autre chose — quelqu'un joue là aussi. C'est ce qui permet
    /// à un accord doublé à l'octave de montrer ses deux octaves.
    public var mustExceedParent: Double = 6

    /// Ce que coûte une raie tenue que l'accord retenu ne contient pas.
    ///
    /// C'est le réglage de l'adéquation, celui qui dit à quel point un nom doit
    /// rendre compte de ce qu'on voit. Un point : une note franche laissée sans
    /// explication annule exactement une note juste.
    public var unexplainedCost: Double = 1

    /// Ce que coûte une note de l'accord qu'on ne voit pas.
    ///
    /// Un demi-point seulement : une quinte omise, masquée par une harmonique ou
    /// noyée dans le mixage est chose commune, alors qu'une tierce inventée ne l'est
    /// pas. C'est ce qui permet de nommer une septième dont la quinte manque.
    public var missingCost: Double = 0.5

    /// Ce que rapporte à un accord d'avoir la note la plus grave pour fondamentale,
    /// et ce que coûte une basse qui lui est étrangère.
    ///
    /// La basse n'est plus une piste séparée mais la **raie tenue la plus grave** de
    /// l'image. C'est elle qui sépare `Do6` de `La-7`, mêmes notes, et un
    /// renversement de son accord de base.
    public var bassAgreement: Double = 0.35
    public var bassContradiction: Double = 0.2

    /// Prix des couleurs rares. **Zéro par défaut** : le relevé par raies n'en a plus
    /// besoin — une note qu'on ne voit pas coûte déjà quelque chose — et à l'essai
    /// sur de la vraie musique, le laisser à zéro donne le meilleur relevé.
    public var rarityWeight: Double = 0

    /// Prix d'un changement d'accord d'un temps au suivant. Sans effet hors de la
    /// portée « un accord par temps » : rien ne lisse des mesures décidées séparément.
    public var changeCost: Double = 0.55

    public init() {}

    /// Les accords que ce vocabulaire autorise.
    public var chords: [Chord] {
        let qualities = vocabulary.qualities
        return (0..<12).flatMap { root in qualities.map { Chord(root: root, quality: $0) } }
    }

    /// Ce qui change la **carte des notes** — la seule partie chère du relevé. Tout
    /// le reste ne fait que la relire, et se refait en quelques millisecondes.
    public var mapKey: Int { prominence.hashValue }

    /// Décodage tolérant aux champs manquants, pour la même raison que
    /// `DisplaySettings` : un réglage ajouté ne doit pas effacer ceux déjà écrits, et
    /// un réglage disparu ne doit pas empêcher de relire le reste.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChordSettings()
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? d.scope
        vocabulary = try c.decodeIfPresent(Vocabulary.self, forKey: .vocabulary) ?? d.vocabulary
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? d.clarity
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? d.hold
        prominence = try c.decodeIfPresent(Double.self, forKey: .prominence) ?? d.prominence
        harmonicDrop = try c.decodeIfPresent(Double.self, forKey: .harmonicDrop)
            ?? d.harmonicDrop
        mustExceedParent = try c.decodeIfPresent(Double.self, forKey: .mustExceedParent)
            ?? d.mustExceedParent
        unexplainedCost = try c.decodeIfPresent(Double.self, forKey: .unexplainedCost)
            ?? d.unexplainedCost
        missingCost = try c.decodeIfPresent(Double.self, forKey: .missingCost) ?? d.missingCost
        bassAgreement = try c.decodeIfPresent(Double.self, forKey: .bassAgreement)
            ?? d.bassAgreement
        bassContradiction = try c.decodeIfPresent(Double.self, forKey: .bassContradiction)
            ?? d.bassContradiction
        rarityWeight = try c.decodeIfPresent(Double.self, forKey: .rarityWeight)
            ?? d.rarityWeight
        changeCost = try c.decodeIfPresent(Double.self, forKey: .changeCost) ?? d.changeCost
    }
}
