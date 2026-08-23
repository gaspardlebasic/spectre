import Foundation

// Le catalogue, et d'où vient la langue.
//
// ─────────────────────────────────────────────────────────────────────────────
// PAS DE `.strings`, PAS DE `NSLocalizedString`, PAS DE `Bundle.module`
//
// Tout cela marche sur le Mac et se casse ailleurs : la recherche de ressources
// d'un paquet SwiftPM n'est pas le chemin qu'on veut emprunter pour afficher un
// bouton sous Windows, et un texte qui manque y échoue en silence. Le catalogue est
// donc du Swift ordinaire — une clé par texte, cinq tables, un repli sur le
// français — compilé dans l'exécutable, vérifié par `LangueCheck`, et identique sur
// les trois systèmes.
//
// LES TEXTES À TROUS SONT POSITIONNELS
//
// `%1$@`, `%2$@`, et la substitution est faite ici, à la main. Pas de
// `String(format:)` : l'ordre des mots n'est pas le même d'une langue à l'autre —
// l'allemand renvoie couramment le verbe à la fin — et `%@` avec une `String` n'a
// pas le même sort selon la Foundation qui compile. Ce qu'on remplace est du texte
// dans du texte, et rien d'autre.
// ─────────────────────────────────────────────────────────────────────────────

public enum Textes {

    /// La langue à l'écran. Posée une fois au démarrage par la plateforme, avant que
    /// quoi que ce soit s'affiche, et rechangée quand on la choisit dans les réglages.
    public static var langue: Langue = .fr

    /// Le système de noms de notes choisi à la main. `nil` — le défaut — le fait
    /// suivre la langue.
    ///
    /// Deux réglages et non un seul, parce que ce ne sont pas la même question : un
    /// guitariste français qui a appris sur des grilles américaines veut son
    /// interface en français et ses accords en `Am`.
    public static var choixDeNotes: SystemeDeNotes?

    /// Le système effectivement employé pour nommer les notes et les accords.
    public static var systemeDeNotes: SystemeDeNotes {
        choixDeNotes ?? SystemeDeNotes.pour(langue)
    }

    // MARK: - D'où vient la langue

    /// La langue qu'impose `SPECTRE_LANGUE`, s'il y en a une.
    ///
    /// C'est le levier des harnais, qui doivent comparer un relevé d'accords à une
    /// grille écrite d'avance sans dépendre de la langue de la machine qui les fait
    /// tourner. Elle passe avant tout le reste.
    ///
    /// Tenue **à part** de `resoudre`, et pas par élégance : une règle qui se lit
    /// dans l'environnement ne s'éprouve pas, puisque le harnais qui l'éprouverait
    /// tourne lui-même avec la variable posée. Séparées, les deux se vérifient
    /// chacune de son côté.
    public static var imposee: Langue? {
        ProcessInfo.processInfo.environment["SPECTRE_LANGUE"]
            .flatMap(Langue.reconnue)
    }

    /// Dans l'ordre : le choix enregistré, le système, l'anglais.
    ///
    /// - Parameter etiquettesDuSysteme: ce que le système dit préférer, de la plus
    ///   souhaitée à la moins — `AppleLanguages` sur le Mac, `GetUserPreferredUILanguages`
    ///   sous Windows. On les parcourt dans l'ordre : un Mac réglé en breton puis en
    ///   allemand doit obtenir l'allemand, pas l'anglais.
    public static func resoudre(choix: Langue?,
                                etiquettesDuSysteme: [String]) -> Langue {
        if let choix { return choix }
        for etiquette in etiquettesDuSysteme {
            if let langue = Langue.reconnue(etiquette) { return langue }
        }
        return .en
    }

    /// Pose la langue et le système de notes d'un coup, au démarrage.
    public static func demarrer(choix: Langue?, notes: SystemeDeNotes?,
                                etiquettesDuSysteme: [String]) {
        langue = imposee ?? resoudre(choix: choix,
                                     etiquettesDuSysteme: etiquettesDuSysteme)
        choixDeNotes = notes
    }

    /// Vrai quand `SPECTRE_LANGUE` impose la langue : le réglage est alors sans
    /// effet, et le panneau a de quoi le dire plutôt que de paraître cassé.
    public static var langueImposee: Bool { imposee != nil }

    // MARK: - Le catalogue

    public static func catalogue(_ langue: Langue) -> [Cle: String] {
        switch langue {
        case .fr: Catalogue.francais
        case .en: Catalogue.anglais
        case .es: Catalogue.espagnol
        case .de: Catalogue.allemand
        case .pl: Catalogue.polonais
        }
    }

    /// Le texte d'une clé, dans la langue courante.
    ///
    /// Le repli est le français et non l'anglais : c'est la langue de référence, la
    /// seule dont `LangueCheck` garantit qu'elle est complète. Une clé introuvable
    /// même là s'affiche entre chevrons plutôt que vide — un bouton sans intitulé ne
    /// se remarque pas, un bouton qui dit `⟨quelqueChose⟩` se corrige le jour même.
    public static func texte(_ cle: Cle) -> String {
        if let trouve = catalogue(langue)[cle] { return trouve }
        if let francais = Catalogue.francais[cle] { return francais }
        return "⟨\(cle)⟩"
    }
}

/// Le texte d'une clé. Court exprès : il apparaît des centaines de fois, souvent
/// deux ou trois fois dans une même ligne.
public func T(_ cle: Cle) -> String { Textes.texte(cle) }

/// Le texte d'une clé, ses trous remplis dans l'ordre : `%1$@`, `%2$@`…
///
/// Les valeurs arrivent déjà écrites — « 42 % », « 2 min 30 s ». Mettre en forme un
/// nombre est l'affaire de qui le connaît, pas du catalogue.
public func T(_ cle: Cle, _ valeurs: String...) -> String {
    Textes.remplir(Textes.texte(cle), valeurs)
}

extension Textes {
    /// Remplit les trous d'un texte : `%1$@` prend la première valeur, et ainsi de
    /// suite. Publique parce que `LangueCheck` l'éprouve — une vérification des
    /// repères ne vaut que ce que vaut la substitution qu'elle contrôle.
    public static func remplir(_ modele: String, _ valeurs: [String]) -> String {
        var texte = modele
        for (rang, valeur) in valeurs.enumerated() {
            texte = texte.replacingOccurrences(of: "%\(rang + 1)$@", with: valeur)
        }
        return texte
    }
}
