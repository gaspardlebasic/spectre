import Foundation

/// Comment on écrit les douze hauteurs, et les accords qu'on bâtit dessus.
///
/// Quatre systèmes pour cinq langues : l'allemand et le polonais partagent
/// exactement les mêmes douze noms, et le français et l'espagnol ne diffèrent que
/// par l'accent de « Ré ».
///
/// **Le piège allemand et polonais** : `B` y désigne le si bémol et `H` le si
/// naturel. Ce n'est pas une coquille — c'est la convention de ces deux pays, et
/// c'est la seule chose de tout ce fichier qu'on ne peut pas deviner depuis le
/// français.
public enum SystemeDeNotes: Int, CaseIterable, Codable, Sendable {
    case latinFr = 0, latinEs = 1, anglo = 2, germanique = 3

    /// Comment le sélecteur le nomme : par ses premières notes, qui le disent mieux
    /// qu'un adjectif. « C D E H » se reconnaît d'un coup d'œil pour qui l'emploie,
    /// là où « germanique » demande de savoir ce que ça recouvre.
    public var label: String {
        switch self {
        case .latinFr: "Do Ré Mi"
        case .latinEs: "Do Re Mi"
        case .anglo: "C D E"
        case .germanique: "C D E H"
        }
    }

    /// Les douze noms, touches noires nommées par le haut.
    public var dieses: [String] {
        switch self {
        case .latinFr:
            ["Do", "Do♯", "Ré", "Ré♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]
        case .latinEs:
            ["Do", "Do♯", "Re", "Re♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]
        case .anglo:
            ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        // Les altérations s'écrivent en toutes lettres et non par un signe : « Fis »
        // et non « F♯ ». C'est ainsi que ces deux langues nomment les notes, et
        // mélanger les deux écritures donnerait quelque chose que personne n'emploie.
        case .germanique:
            ["C", "Cis", "D", "Dis", "E", "F", "Fis", "G", "Gis", "A", "Ais", "H"]
        }
    }

    /// Les douze noms, touches noires nommées par le bas — l'écriture par défaut.
    public var bemols: [String] {
        switch self {
        case .latinFr:
            ["Do", "Ré♭", "Ré", "Mi♭", "Mi", "Fa", "Sol♭", "Sol", "La♭", "La", "Si♭", "Si"]
        case .latinEs:
            ["Do", "Re♭", "Re", "Mi♭", "Mi", "Fa", "Sol♭", "Sol", "La♭", "La", "Si♭", "Si"]
        case .anglo:
            ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        // « B » est ici le si bémol, et « H » le si naturel. Voir la note en tête.
        case .germanique:
            ["C", "Des", "D", "Es", "E", "F", "Ges", "G", "As", "A", "B", "H"]
        }
    }

    public func noms(bemols useFlats: Bool) -> [String] { useFlats ? bemols : dieses }

    /// Le jeu de symboles d'accords qui va avec.
    ///
    /// L'espagnol écrit `Do Re Mi` mais prend les symboles anglo-saxons : `Am` et
    /// non `La-`. Les deux se voient en Espagne, mais un seul se lit sans hésiter —
    /// c'est ce qu'on trouve sur les sites de tablatures hispanophones.
    public var symboles: JeuDeSymboles {
        self == .latinFr ? .jazz : .populaire
    }

    /// Le système qu'une langue emploie, faute de choix explicite.
    public static func pour(_ langue: Langue) -> SystemeDeNotes {
        switch langue {
        case .fr: .latinFr
        case .es: .latinEs
        case .en: .anglo
        case .de, .pl: .germanique
        }
    }
}

/// Les deux manières d'écrire la couleur d'un accord.
///
/// Le jazz écrit `La-`, `DoΔ`, `Siø` ; le reste du monde écrit `Am`, `Cmaj7`,
/// `Bm7♭5`. Coller un `-` sur un `A` donnerait quelque chose que personne ne lit
/// hors de France, et c'est la seule raison de tenir deux jeux.
public enum JeuDeSymboles: Int, CaseIterable, Codable, Sendable {
    case jazz = 0, populaire = 1
}

/// Les dix-neuf couleurs d'accord, dans l'ordre de `ChordQuality`.
///
/// Cette table vit ici et non dans `SpectreCore` parce qu'elle est une affaire
/// d'écriture, pas d'harmonie : les intervalles, eux, ne changent pas d'un pays à
/// l'autre. `ChordQuality.symbol` la lit par son rang.
public enum SymbolesDaccord {
    public static func symbole(rang: Int, jeu: JeuDeSymboles) -> String {
        let table = jeu == .jazz ? jazz : populaire
        guard rang >= 0, rang < table.count else { return "" }
        return table[rang]
    }

    /// major, minor, suspended4, dominant7, minor7, major7, halfDiminished,
    /// diminished, augmented, major6, minor6, add9, minorAdd9, ninth, minorNinth,
    /// major9, eleventh, minorEleventh, thirteenth.
    static let jazz = ["", "-", "sus4", "7", "-7", "Δ", "ø", "°", "+", "6", "-6",
                       "add9", "-add9", "9", "-9", "Δ9", "11", "-11", "13"]
    static let populaire = ["", "m", "sus4", "7", "m7", "maj7", "m7♭5", "dim", "aug",
                            "6", "m6", "add9", "madd9", "9", "m9", "maj9", "11",
                            "m11", "13"]
}
