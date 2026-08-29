import Foundation
import SpectreCore
import SpectreModele
#if canImport(WinSDK)
import WinSDK
#endif

// La page de lancement, le diaporama et la mise à jour — éprouvés sans fenêtre.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CES TROIS-LÀ ENSEMBLE
//
// Ce sont les trois seules choses de l'application que **la plupart des gens ne
// verront qu'une fois**, et une chose qu'on ne voit qu'une fois est une chose que
// l'auteur ne revoit jamais : son propre témoin est écrit depuis des mois. Un
// diaporama qui reviendrait à chaque lancement, une corbeille qui n'emporterait pas
// les pistes, une mise à jour proposée vers une version plus ancienne que celle qui
// tourne — aucun de ces trois défauts ne se verrait ici.
//
// Il tourne sans réseau : `MiseAJour.demande` est remplacée par une fonction qui
// rend un JSON écrit à la main. C'est la même couture que `Rapports.poste`, et pour
// la même raison — le harnais éprouve la lecture de la réponse et la comparaison des
// numéros, qui sont ce qui peut être faux, et non `URLSession`, qui ne l'est pas.
//
// Il pose lui-même `SPECTRE_RANGEMENT` sur un dossier neuf : c'est ce qui lui donne
// un premier lancement à chaque exécution, et ce qui l'empêche d'effacer les pistes
// séparées de qui le lance.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

let gestionnaire = FileManager.default

/// `setenv` est du POSIX et n'existe pas sous Windows : c'est
/// `SetEnvironmentVariableW` qui écrit dans le bloc que `ProcessInfo` relit.
func poserDansLEnvironnement(_ nom: String, _ valeur: String) {
    #if canImport(WinSDK)
    _ = nom.withCString(encodedAs: UTF16.self) { n in
        valeur.withCString(encodedAs: UTF16.self) { v in
            SetEnvironmentVariableW(n, v)
        }
    }
    #else
    setenv(nom, valeur, 1)
    #endif
}

let rangement = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("spectre-lancement-\(ProcessInfo.processInfo.processIdentifier)")
try? gestionnaire.createDirectory(at: rangement, withIntermediateDirectories: true)
poserDansLEnvironnement("SPECTRE_RANGEMENT", rangement.path)
// Et l'on **repose** les deux leviers que `check.sh` et `essai.sh` posent pour
// eux-mêmes. C'est la règle déjà écrite pour `SPECTRE_LANGUE` : une chose qui se lit
// dans l'environnement ne s'éprouve pas depuis un script qui l'a posée. Sans ces
// deux lignes, ce harnais passait tout seul et échouait sous `essai.sh`, en disant
// que le diaporama ne se montre pas au premier lancement — ce qui était vrai, et ne
// disait rien de l'application.
poserDansLEnvironnement("SPECTRE_BIENVENUE", "oui")
poserDansLEnvironnement("SPECTRE_MAJ", "https://exemple.invalide/releases")
defer { try? gestionnaire.removeItem(at: rangement) }

// MARK: - Les pièces de rechange

/// Un rangement de pistes qui ne calcule rien et retient ce qu'on lui a demandé
/// d'oublier. C'est tout ce dont `Lancement` a besoin : il ne sépare jamais.
final class RangementDEssai: ServiceDeSeparation {
    var separes: Set<String> = []
    var oublies: [String] = []

    var modeleDisponible: Bool { true }
    var poidsPresents: Bool { true }
    func tailleDuCache() -> Int { 0 }
    func viderLeCache() { separes.removeAll() }
    func estSepare(_ empreinte: String) -> Bool { separes.contains(empreinte) }
    func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? { nil }
    func chargerLesPistes(empreinte: String, fin: @escaping (BanqueDePistes?) -> Void) {
        fin(nil)
    }
    func oublierLesPistes(empreinte: String) {
        oublies.append(empreinte)
        separes.remove(empreinte)
    }
    func marquerUtilise(_ empreinte: String) {}
    func separer(fichier: URL, empreinte: String,
                 avancement: @escaping (SeparationProgress) -> Void,
                 fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                 rangement: @escaping (Error?) -> Void) -> TravailAnnulable {
        fatalError("le harnais ne sépare jamais")
    }
}

/// Le navigateur et l'explorateur de fichiers, remplacés par un carnet.
final class ExterieurDEssai: Exterieur {
    var pages: [URL] = []
    var dossiers: [URL] = []
    func ouvrirLaPage(_ url: URL) { pages.append(url) }
    func montrerLeDossier(_ url: URL) { dossiers.append(url) }
}

/// Fabrique un fichier qui a l'air d'un morceau : `SessionStore.fingerprint` lit sa
/// taille, son début et sa fin, et se moque du reste.
@discardableResult
func morceauFactice(_ nom: String) throws -> URL {
    let url = rangement.appendingPathComponent(nom)
    try Data(repeating: UInt8(nom.count % 251), count: 4096).write(to: url)
    return url
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Comparer deux numéros de version")

do {
    // Ce qui doit proposer.
    let plusRecentes = [("0.6", "0.5"), ("v0.6", "0.5"), ("1.0", "0.9"),
                        ("0.10", "0.9"), ("0.5.1", "0.5"), ("2", "1.9.9")]
    for (candidate, courante) in plusRecentes {
        verifie(MiseAJour.plusRecente(candidate, que: courante),
                "« \(candidate) » est plus récente que « \(courante) »")
    }

    // Ce qui ne doit rien proposer. La ligne qui compte est « 0.9 contre 0.10 » :
    // un tri alphabétique dit exactement le contraire, et le jour où le dépôt
    // passera de 0.9 à 0.10 est le jour où l'on ne veut pas relire ce fichier.
    let pas = [("0.5", "0.5"), ("v0.5", "0.5"), ("0.4", "0.5"), ("0.9", "0.10"),
               ("0.5", "0.5.1"), ("", "0.5"), ("étiquette", "0.5"), ("0.5", "")]
    for (candidate, courante) in pas {
        verifie(!MiseAJour.plusRecente(candidate, que: courante),
                "« \(candidate) » ne remplace pas « \(courante) »")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Lire ce que le dépôt répond")

/// Attend la réponse de `MiseAJour.chercher`, qui arrive sur un fil à part.
///
/// Sans la politesse de trois secondes que l'application s'impose : elle existe pour
/// que la fenêtre s'ouvre avant qu'un fil tire sur la carte réseau, et le harnais n'a
/// pas de fenêtre — trente secondes d'attente pour rien à chaque `check.sh`.
func demander(_ reponse: Data?, courante: String = "0.5") -> MiseAJour.Livraison? {
    MiseAJour.demande = { _ in reponse }
    let attente = DispatchSemaphore(value: 0)
    final class Boite: @unchecked Sendable { var valeur: MiseAJour.Livraison? }
    let boite = Boite()
    MiseAJour.chercher(courante: courante, politesse: 0) { trouvee in
        boite.valeur = trouvee
        attente.signal()
    }
    _ = attente.wait(timeout: .now() + 30)
    return boite.valeur
}

/// La même attente, mais sans reposer la fonction de remplacement : sert au levier
/// `SPECTRE_MAJ=non`, qui doit couper avant elle.
func demanderSansPolitesse() -> MiseAJour.Livraison? {
    let attente = DispatchSemaphore(value: 0)
    final class Boite: @unchecked Sendable { var valeur: MiseAJour.Livraison? }
    let boite = Boite()
    MiseAJour.chercher(courante: "0.5", politesse: 0) { trouvee in
        boite.valeur = trouvee
        attente.signal()
    }
    _ = attente.wait(timeout: .now() + 30)
    return boite.valeur
}

do {
    let vraie = Data("""
        {"tag_name":"v0.9","html_url":"https://github.com/exemple/spectre/releases/tag/v0.9"}
        """.utf8)
    let trouvee = demander(vraie)
    verifie(trouvee?.version == "0.9", "le numéro est lu, sans son « v »",
            trouvee?.version ?? "rien")
    verifie(trouvee?.page.absoluteString.hasSuffix("v0.9") == true,
            "et la page qui va avec")

    verifie(demander(vraie, courante: "0.9") == nil,
            "la version qui tourne déjà ne se propose pas")
    verifie(demander(vraie, courante: "1.0") == nil,
            "ni une version plus ancienne que celle qui tourne")

    // Ce qu'on ne contrôle pas : la réponse. Aucune de ces trois formes ne doit
    // proposer quoi que ce soit, et surtout aucune ne doit arrêter l'application.
    verifie(demander(nil) == nil, "pas de réseau, pas de proposition")
    verifie(demander(Data("ceci n'est pas du JSON".utf8)) == nil,
            "une réponse illisible non plus")
    verifie(demander(Data("{\"message\":\"Not Found\"}".utf8)) == nil,
            "ni une réponse sans étiquette")

    // Et le champ qui manque le plus souvent : l'adresse de la page. On retombe
    // alors sur la page des versions, plutôt que de perdre la proposition.
    let sansPage = demander(Data("{\"tag_name\":\"v0.9\"}".utf8))
    verifie(sansPage?.version == "0.9",
            "une release sans adresse se propose quand même")
    verifie(sansPage?.page.absoluteString.contains("releases") == true,
            "et renvoie vers la page des versions")

    // Et le levier qui retire la question entièrement, pour qui ne veut pas qu'on
    // la pose. Il doit court-circuiter avant même la fonction de remplacement,
    // sans quoi `SPECTRE_MAJ=non` ne retirerait rien du tout.
    poserDansLEnvironnement("SPECTRE_MAJ", "non")
    MiseAJour.demande = { _ in vraie }
    verifie(demanderSansPolitesse() == nil, "« SPECTRE_MAJ=non » ne demande rien")
    poserDansLEnvironnement("SPECTRE_MAJ", "https://exemple.invalide/releases")

    MiseAJour.demande = nil
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Le diaporama ne se montre qu'une fois")

do {
    Bienvenue.oublierPourLeHarnais()
    verifie(Bienvenue.aMontrer, "au premier lancement, il est à montrer")

    let pistes = RangementDEssai()
    let premier = Lancement(pistes: pistes, exterieur: ExterieurDEssai())
    verifie(premier.diaporama, "et le lancement le porte")
    verifie(premier.diapositive == 0, "il commence à la première diapositive")
    verifie(!premier.derniereDiapositive, "qui n'est pas la dernière")
    premier.suivant()
    verifie(premier.diapositive == 1 && premier.derniereDiapositive,
            "« Suivant » mène à la seconde, qui est la dernière")
    premier.suivant()
    verifie(!premier.diaporama, "et « Commencer » le referme")

    Bienvenue.oublierPourLeHarnais()
    verifie(!Bienvenue.aMontrer, "le témoin est écrit tout de suite, pas à la fermeture")
    let second = Lancement(pistes: pistes, exterieur: ExterieurDEssai())
    verifie(!second.diaporama, "au lancement suivant, il ne revient pas")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("La mise à jour vient après le diaporama")

do {
    try? gestionnaire.removeItem(at: rangement.appendingPathComponent("bienvenue-vue"))
    Bienvenue.oublierPourLeHarnais()
    let exterieur = ExterieurDEssai()
    let lancement = Lancement(pistes: RangementDEssai(), exterieur: exterieur)
    let page = URL(string: "https://github.com/exemple/spectre/releases/tag/v0.9")!

    lancement.proposer(.init(version: "0.9", page: page))
    verifie(lancement.diaporama, "le diaporama est encore là")
    verifie(!lancement.miseAJourAMontrer,
            "et la mise à jour attend derrière lui plutôt que de s'y superposer")

    lancement.fermerLeDiaporama()
    verifie(lancement.miseAJourAMontrer, "le diaporama refermé, elle se montre")

    lancement.telecharger()
    verifie(exterieur.pages == [page], "« Télécharger » ouvre la page des versions")
    verifie(!lancement.miseAJourAMontrer, "et la modale s'en va")

    let autre = Lancement(pistes: RangementDEssai(), exterieur: exterieur)
    autre.proposer(.init(version: "0.9", page: page))
    verifie(autre.miseAJourAMontrer, "sur un lancement neuf, elle se montre")
    autre.fermerLaMiseAJour()
    verifie(!autre.miseAJourAMontrer, "Échap la referme sans rien ouvrir")
    verifie(exterieur.pages == [page], "et sans rien ouvrir dans le navigateur")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("« Ignorer cette version » tient d'un lancement à l'autre")

// Le défaut qu'on cherche ici est celui qu'a remplacé ce bouton : « Plus tard » ne
// valait que pour la séance en cours, donc la question revenait à chaque ouverture
// et la seule façon d'en sortir était de mettre à jour. Ce qui se vérifie, c'est
// donc le lancement **suivant** — et qu'une version de plus repose bien la question.
do {
    try? gestionnaire.removeItem(at: rangement.appendingPathComponent("maj-ecartee"))
    MiseAJourEcartee.oublierPourLeHarnais()
    let exterieur = ExterieurDEssai()
    let page = URL(string: "https://github.com/exemple/spectre/releases/tag/v0.9")!

    let ignoree = Lancement(pistes: RangementDEssai(), exterieur: exterieur)
    ignoree.fermerLeDiaporama()
    ignoree.proposer(.init(version: "0.9", page: page))
    verifie(ignoree.miseAJourAMontrer, "elle se montre une première fois")
    ignoree.ignorerCetteVersion()
    verifie(!ignoree.miseAJourAMontrer, "le bouton la referme")
    verifie(exterieur.pages.isEmpty, "sans rien ouvrir dans le navigateur")

    MiseAJourEcartee.oublierPourLeHarnais()
    verifie(MiseAJourEcartee.version == "0.9",
            "le numéro est écrit sur le disque tout de suite, pas à la fermeture")

    let apres = Lancement(pistes: RangementDEssai(), exterieur: exterieur)
    apres.fermerLeDiaporama()
    apres.proposer(.init(version: "0.9", page: page))
    verifie(!apres.miseAJourAMontrer, "au lancement suivant, elle ne revient pas")

    let suivante = Lancement(pistes: RangementDEssai(), exterieur: exterieur)
    suivante.fermerLeDiaporama()
    suivante.proposer(.init(version: "0.10",
                            page: URL(string: "https://exemple/v0.10")!))
    verifie(suivante.miseAJourAMontrer,
            "mais la livraison d'après repose la question : on écarte une version, pas les mises à jour")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("La liste des morceaux, et sa corbeille")

do {
    RecentFiles.clear()
    let pistes = RangementDEssai()
    let un = try morceauFactice("un.wav")
    let deux = try morceauFactice("deux.wav")
    guard let empreinteDeUn = SessionStore.fingerprint(of: un) else {
        throw NSError(domain: "empreinte", code: 0)
    }
    pistes.separes.insert(empreinteDeUn)
    RecentFiles.note(un)
    RecentFiles.note(deux)

    let exterieur = ExterieurDEssai()
    let lancement = Lancement(pistes: pistes, exterieur: exterieur)
    verifie(lancement.morceaux.map(\.nom) == ["deux", "un"],
            "le dernier ouvert est en tête, et le nom perd son extension")
    verifie(lancement.morceaux.last?.separe == true,
            "la ligne dit que ce morceau a déjà ses pistes")
    verifie(lancement.morceaux.first?.separe == false,
            "et que l'autre ne les a pas")

    // Le geste qui compte : retirer une ligne **jette aussi les pistes**. Sans
    // cela, cette page serait un endroit où l'on croit faire de la place sans en
    // faire — trois cents mégaoctets par morceau resteraient sur le disque.
    lancement.oublier(un)
    verifie(pistes.oublies == [empreinteDeUn], "la corbeille jette les pistes séparées")
    verifie(lancement.morceaux.map(\.nom) == ["deux"], "et la ligne s'en va")
    verifie(gestionnaire.fileExists(atPath: un.path),
            "le fichier audio, lui, n'est pas touché")

    let relu = Lancement(pistes: pistes, exterieur: exterieur)
    verifie(relu.morceaux.map(\.nom) == ["deux"], "et il ne revient pas au lancement suivant")

    // « Vider le menu » est un geste de rangement, pas de ménage : on ne veut plus
    // voir la liste, on ne demande pas à recalculer des heures de GPU.
    pistes.oublies.removeAll()
    pistes.separes.insert("peu importe")
    relu.toutOublier()
    verifie(relu.morceaux.isEmpty, "tout oublier vide la liste")
    verifie(pistes.oublies.isEmpty, "sans jeter la moindre piste")
}

// ─────────────────────────────────────────────────────────────────────────────

titre("Le dossier des pistes")

do {
    let exterieur = ExterieurDEssai()
    let lancement = Lancement(pistes: RangementDEssai(), exterieur: exterieur)
    lancement.montrerLeDossierDesPistes()
    verifie(exterieur.dossiers.count == 1, "le panneau sait le faire montrer")
    verifie(exterieur.dossiers.first?.lastPathComponent == "pistes",
            "et c'est bien celui des pistes", exterieur.dossiers.first?.path ?? "aucun")
    // Le même dossier que celui où le rangement écrit : s'ils divergeaient, le
    // bouton ouvrirait un dossier vide sans rien dire.
    verifie(exterieur.dossiers.first?.standardizedFileURL
                == Storage.pistes?.standardizedFileURL,
            "le même que celui où les pistes sont rangées")
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
