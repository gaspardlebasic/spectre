import Foundation
import SpectreTextes

// Le catalogue des cinq langues, éprouvé avant qu'une fenêtre s'ouvre.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE HARNAIS EXISTE
//
// Une traduction oubliée ne casse rien. Elle ne lève aucune erreur, n'empêche pas
// de compiler, et se découvre dans une fenêtre — six mois plus tard, par hasard,
// sur la seule machine qui parle cette langue-là. C'est la définition d'un défaut
// qu'un harnais doit attraper : silencieux, tardif, et invisible à qui écrit le
// code.
//
// Il vérifie quatre choses, et rien de ce qu'il vérifie ne se voit à la lecture :
// qu'aucune clé ne manque, que les trous d'un texte sont les mêmes dans toutes les
// langues, que les douze notes sont bien douze partout, et que la langue se résout
// dans l'ordre annoncé.
//
// Le troisième point mérite un mot. Les tables de notes sont de la musique, pas de
// la traduction : `H` et `B` en allemand ne sont pas une affaire de goût, et une
// table à onze entrées ferait sortir l'application par un débordement d'indice à
// la première note jouée.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

// MARK: - Toutes les clés, dans toutes les langues

titre("Le catalogue est complet")

let toutesLesCles = Cle.allCases
print("  \(toutesLesCles.count) clés, \(Langue.allCases.count) langues — "
      + "\(toutesLesCles.count * Langue.allCases.count) textes attendus")

for langue in Langue.allCases {
    let table = Textes.catalogue(langue)
    let manquantes = toutesLesCles.filter { table[$0] == nil }
    let vides = toutesLesCles.filter { table[$0]?.isEmpty == true }
    verifie(manquantes.isEmpty, "\(langue.rawValue) : aucune clé manquante",
            manquantes.isEmpty ? "" : "\(manquantes.count) absentes, dont "
                + manquantes.prefix(4).map(\.rawValue).joined(separator: ", "))
    verifie(vides.isEmpty, "\(langue.rawValue) : aucun texte vide",
            vides.isEmpty ? "" : vides.prefix(4).map(\.rawValue).joined(separator: ", "))
}

// Une clé en trop est un texte que plus personne n'affiche : elle ne casse rien,
// mais elle se traduit encore à chaque langue ajoutée.
for langue in Langue.allCases {
    let connues = Set(toutesLesCles)
    let surnumeraires = Textes.catalogue(langue).keys.filter { !connues.contains($0) }
    verifie(surnumeraires.isEmpty, "\(langue.rawValue) : aucune clé orpheline",
            surnumeraires.map(\.rawValue).joined(separator: ", "))
}

// MARK: - Les trous

titre("Les textes à trous se correspondent")

/// Les repères `%1$@`, `%2$@`… d'un texte. Ce sont eux, et non l'ordre des mots,
/// qui doivent se retrouver d'une langue à l'autre : une traduction a le droit de
/// commencer par le second, pas d'en oublier un.
func trous(_ texte: String) -> Set<Int> {
    var trouves = Set<Int>()
    for rang in 1...9 where texte.contains("%\(rang)$@") { trouves.insert(rang) }
    return trouves
}

let reference = Textes.catalogue(.fr)
var trousFautifs = 0
for langue in Langue.allCases where langue != .fr {
    let table = Textes.catalogue(langue)
    for cle in toutesLesCles {
        guard let attendu = reference[cle], let traduit = table[cle] else { continue }
        if trous(attendu) != trous(traduit) {
            print("  ✗ \(langue.rawValue) / \(cle.rawValue) : "
                  + "attendus \(trous(attendu).sorted()), trouvés \(trous(traduit).sorted())")
            trousFautifs += 1
        }
    }
}
verifie(trousFautifs == 0, "les repères de substitution se correspondent partout",
        trousFautifs == 0 ? "" : "\(trousFautifs) textes fautifs")

// Un trou se remplit bien : la vérification vaut ce que vaut la substitution.
verifie(Textes.remplir("le %1$@ et le %2$@", ["premier", "second"])
        == "le premier et le second", "les trous se remplissent dans l'ordre")
verifie(Textes.remplir("%2$@ avant %1$@", ["un", "deux"]) == "deux avant un",
        "et dans le désordre, si la langue le demande")

// MARK: - Les douze notes

titre("Les noms de notes")

for systeme in SystemeDeNotes.allCases {
    let d = systeme.dieses, b = systeme.bemols
    verifie(d.count == 12 && b.count == 12, "\(systeme.label) : douze noms de part et d'autre",
            "dièses \(d.count), bémols \(b.count)")
    verifie(Set(d).count == 12, "\(systeme.label) : aucun nom en double, en dièses")
    verifie(Set(b).count == 12, "\(systeme.label) : aucun nom en double, en bémols")
    // Les notes naturelles sont les mêmes des deux côtés : seules les touches
    // noires changent d'écriture.
    let naturelles = [0, 2, 4, 5, 7, 9, 11]
    verifie(naturelles.allSatisfy { d[$0] == b[$0] },
            "\(systeme.label) : les touches blanches s'écrivent pareil")
}

// Ce que personne ne devine depuis le français, et qui est la raison d'être de la
// table germanique.
let germanique = SystemeDeNotes.germanique
verifie(germanique.bemols[10] == "B", "en allemand et en polonais, B est le si bémol",
        germanique.bemols[10])
verifie(germanique.bemols[11] == "H", "et H le si naturel", germanique.bemols[11])
verifie(germanique.dieses[6] == "Fis", "les dièses s'écrivent en toutes lettres",
        germanique.dieses[6])
verifie(SystemeDeNotes.anglo.bemols[11] == "B", "là où l'anglais écrit B pour le si naturel")

titre("Les symboles d'accords")

for jeu in JeuDeSymboles.allCases {
    let table = (0..<19).map { SymbolesDaccord.symbole(rang: $0, jeu: jeu) }
    verifie(Set(table).count == 19, "dix-neuf symboles distincts",
            "\(jeu) : \(Set(table).count)")
    verifie(table[0].isEmpty, "un accord majeur ne porte pas de symbole")
}
verifie(SymbolesDaccord.symbole(rang: 1, jeu: .jazz) == "-",
        "le jazz écrit le mineur d'un tiret")
verifie(SymbolesDaccord.symbole(rang: 1, jeu: .populaire) == "m",
        "le reste du monde l'écrit m")
verifie(SymbolesDaccord.symbole(rang: 5, jeu: .populaire) == "maj7",
        "et la septième majeure maj7")

titre("Chaque langue a son système de notes")

for langue in Langue.allCases {
    let systeme = SystemeDeNotes.pour(langue)
    print("  · \(langue.rawValue) → \(systeme.label), symboles "
          + (systeme.symboles == .jazz ? "jazz" : "populaires"))
}
verifie(SystemeDeNotes.pour(.fr) == .latinFr, "le français garde Do Ré Mi et le jazz")
verifie(SystemeDeNotes.pour(.es) == .latinEs, "l'espagnol écrit Do Re Mi")
verifie(SystemeDeNotes.pour(.es).symboles == .populaire,
        "mais prend les symboles anglo-saxons — Am, et non La-")
verifie(SystemeDeNotes.pour(.de) == SystemeDeNotes.pour(.pl),
        "l'allemand et le polonais partagent leurs douze noms")

// MARK: - D'où vient la langue

titre("La langue se résout dans l'ordre annoncé")

verifie(Langue.reconnue("fr-CA") == .fr, "une variante régionale tombe sur sa langue")
verifie(Langue.reconnue("de_DE") == .de, "quel que soit le séparateur")
verifie(Langue.reconnue("br") == nil, "une langue inconnue n'est pas reconnue")

verifie(Textes.resoudre(choix: .pl, etiquettesDuSysteme: ["fr-FR"]) == .pl,
        "le choix enregistré passe avant le système")
verifie(Textes.resoudre(choix: nil, etiquettesDuSysteme: ["fr-FR"]) == .fr,
        "sans choix, le système décide")
verifie(Textes.resoudre(choix: nil, etiquettesDuSysteme: ["br", "de-DE"]) == .de,
        "et l'on descend la liste du système plutôt que de s'arrêter au premier inconnu")
verifie(Textes.resoudre(choix: nil, etiquettesDuSysteme: ["br", "eu"]) == .en,
        "l'anglais reste le dernier recours")

// `SPECTRE_LANGUE` passe avant tout cela, et se lit à part — c'est ce qui permet à
// ce harnais de tourner sous la variable que `check.sh` lui pose, sans que les
// quatre lignes ci-dessus deviennent fausses.
if let imposee = Textes.imposee {
    print("  · SPECTRE_LANGUE impose \(imposee.rawValue) — c'est ce que ce harnais "
          + "voit, et l'ordre ci-dessus reste vrai sans elle")
    verifie(Textes.langueImposee, "et l'application sait le dire")
} else {
    verifie(!Textes.langueImposee, "aucune langue imposée par l'environnement")
}

// MARK: - Le repli

titre("Le repli sur le français")

let avant = Textes.langue
Textes.langue = .pl
verifie(!T(.panneauReglages).isEmpty && !T(.panneauReglages).hasPrefix("⟨"),
        "une clé traduite rend sa traduction", T(.panneauReglages))
Textes.langue = avant

print("")
if echecs == 0 {
    print("Tout est en ordre — \(toutesLesCles.count) clés dans cinq langues.")
} else {
    print("\(echecs) échec(s).")
}
exit(echecs == 0 ? 0 : 1)
