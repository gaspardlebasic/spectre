/// Le numéro de version de Spectre, et le seul.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI IL EST ÉCRIT ICI, ET NULLE PART AILLEURS
///
/// Il l'était à trois endroits qui n'avaient aucun moyen de s'accorder : le
/// `CFBundleShortVersionString` du `Info.plist` pour le Mac, la ressource de version
/// que `logo.ps1` fabrique pour Windows, et rien du tout pour Linux. Le journal l'a
/// dit dès sa première ligne — « Spectre 0.2 » sur un Mac, « Spectre inconnue » sous
/// Windows — alors que la livraison qui tournait s'appelait 0.4.
///
/// Ce n'est pas un détail de présentation. Un rapport de plantage qui se trompe de
/// version fait chercher la panne dans le mauvais code, et c'est précisément ce que
/// `docs/RAPPORTS.md` s'apprête à envoyer. Un numéro faux y coûterait plus cher que
/// pas de numéro du tout.
///
/// **Tout le reste le lit d'ici.** `build.sh` le pose dans le `Info.plist` du paquet
/// macOS ; `paquet.ps1` et `paquet.sh` refusent de fabriquer un paquet dont
/// l'étiquette le contredit. Le seul geste à faire en livrant est donc de le changer
/// **ici**, dans le même commit que l'étiquette.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Spectre {
    /// Deux nombres, pas quatre : c'est ce qu'on écrit sur une étiquette — `v0.4` —
    /// et ce qu'on lit dans des notes de version. Windows, qui exige quatre nombres
    /// dans son bloc de ressources, complète avec des zéros ; c'est son affaire, et
    /// `paquet.ps1` la traite déjà.
    public static let version = "0.4"
}
