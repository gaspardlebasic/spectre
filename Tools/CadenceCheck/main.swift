import Foundation
import SpectreDessin
import SpectreModele

// La cadence de la boucle, éprouvée sans fenêtre.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE HARNAIS EXISTE
//
// Il éprouve la règle qui a fait tomber la consommation au repos — voir
// `SpectreDessin/Cadence.swift`. La question qu'il pose est : « à quelle allure la
// boucle tournerait-elle dans cet état-là ? », et elle se pose sans carte
// graphique, sans serveur d'affichage et sans bureau.
//
// C'est ce qui compte. Une fenêtre ne s'ouvre pas partout : `prlctl exec` tombe
// dans la session 0 de Windows, qui n'a pas de bureau, et la machine Linux
// n'ouvre pas de session tant que personne ne s'y connecte. Le défaut lui-même
// n'était visible que dans un gestionnaire des tâches, par-dessus l'épaule de
// quelqu'un ; la règle qui le corrige, elle, se vérifie partout et à chaque
// compilation. Un défaut qui ne se mesure que devant l'écran revient.
//
// Ce qu'il ne prouve pas : les secondes de processeur. Celles-là demandent une
// vraie fenêtre, et c'est `SpectreWindows --repos` et `SpectreLinux --repos` qui
// les donnent.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0

func verifier(_ quoi: String, _ obtenu: Allure, _ attendu: Allure) {
    if obtenu == attendu {
        print("  ✓ \(quoi) → \(obtenu)")
    } else {
        print("  ✗ \(quoi) → \(obtenu), attendu \(attendu)")
        echecs += 1
    }
}

func verifier(_ quoi: String, _ obtenu: Double, _ attendu: Double, tolerance: Double) {
    if abs(obtenu - attendu) <= tolerance {
        print("  ✓ \(quoi) → \(String(format: "%.2f", obtenu))")
    } else {
        print("  ✗ \(quoi) → \(String(format: "%.2f", obtenu)), "
              + "attendu \(String(format: "%.2f", attendu))")
        echecs += 1
    }
}

print("Cadence — l'allure de la boucle")

// MARK: - La fenêtre cachée l'emporte sur tout

// C'est le défaut d'origine, et c'est donc le premier contrôle : une fenêtre que
// personne ne voit n'est pas une fenêtre qu'on dessine, quoi qu'il se passe
// derrière. La lecture comprise — le son ne passe pas par la boucle de dessin.
do {
    var cadence = Cadence()
    let t = 1000.0
    cadence.uneEntree()
    verifier("cachée, rien ne bouge",
             cadence.allure(quelqueChoseBouge: false, fenetreCachee: true, maintenant: t),
             .arretee)
    verifier("cachée, un morceau joue",
             cadence.allure(quelqueChoseBouge: true, fenetreCachee: true, maintenant: t),
             .arretee)
    verifier("cachée, la main vient de bouger",
             cadence.allure(quelqueChoseBouge: false, fenetreCachee: true, maintenant: t),
             .arretee)
}

// MARK: - Devant, ce qui bouge décide

do {
    var cadence = Cadence()
    // Aucune entrée n'a jamais eu lieu : une fenêtre qu'on vient d'ouvrir et qu'on
    // n'a pas touchée n'a aucune raison de brûler soixante images par seconde.
    verifier("neuve, rien ne bouge",
             cadence.allure(quelqueChoseBouge: false, fenetreCachee: false, maintenant: 0),
             .repos)
    verifier("neuve, quelque chose bouge",
             cadence.allure(quelqueChoseBouge: true, fenetreCachee: false, maintenant: 0),
             .pleine)

    // Le sursis d'un geste : pleine cadence pendant une seconde, repos ensuite.
    // La borne est éprouvée des deux côtés, parce qu'une borne qu'on n'éprouve que
    // d'un côté est une borne qu'on peut avoir écrite à l'envers.
    cadence.uneEntree()
    let geste = Horloge.maintenant()
    verifier("le geste vient d'avoir lieu",
             cadence.allure(quelqueChoseBouge: false, fenetreCachee: false,
                            maintenant: geste),
             .pleine)
    verifier("juste avant la fin du sursis",
             cadence.allure(quelqueChoseBouge: false, fenetreCachee: false,
                            maintenant: geste + Cadence.sursisDUnGeste - 0.01),
             .pleine)
    verifier("juste après la fin du sursis",
             cadence.allure(quelqueChoseBouge: false, fenetreCachee: false,
                            maintenant: geste + Cadence.sursisDUnGeste + 0.01),
             .repos)
}

// MARK: - Ce que la règle promet en images par seconde

// Les périodes ne sont pas des détails de mise en œuvre : ce sont elles qui font
// tomber la consommation, et elles se lisent en images par seconde. Les fixer ici
// fait qu'une main qui les changerait sans y penser trouve un harnais rouge plutôt
// qu'une facture de processeur trois mois plus tard.
print("\n  Les périodes")
verifier("au repos, images par seconde", 1 / Cadence.periodeDeRepos, 10, tolerance: 0)
verifier("cachée, réveils par seconde", 1 / Cadence.periodeCachee, 4, tolerance: 0)
verifier("sursis d'un geste, en secondes", Cadence.sursisDUnGeste, 1, tolerance: 0)
// Six fois moins d'images qu'un écran à soixante hertz : c'est la promesse, et
// c'est le nombre qu'on retrouve dans `--repos`.
verifier("images économisées sur soixante, au repos",
         60 - 1 / Cadence.periodeDeRepos, 50, tolerance: 0)

// MARK: - Le rapport de repos

// Le rapport se lit à l'œil, mais deux nombres s'y calculent, et un pourcentage
// faux est pire qu'un pourcentage absent : c'est très exactement en divisant un
// cœur plein par huit fils qu'on lit « 15 % » et qu'on passe à côté.
print("\n  Le rapport")
do {
    let passe = Repos.Passe(nom: "essai", secondes: 5, images: 50, processeur: 0.25)
    verifier("images par seconde", passe.cadence, 10, tolerance: 0.001)
    verifier("part d'un cœur, en pour cent", passe.partDUnCoeur, 5, tolerance: 0.001)
    let cœurPlein = Repos.Passe(nom: "essai", secondes: 5, images: 3000, processeur: 5)
    verifier("un cœur plein vaut cent pour cent", cœurPlein.partDUnCoeur, 100,
             tolerance: 0.001)
    let texte = Repos.rapport([passe, cœurPlein], fils: 8)
    if texte.contains("8 fils"), texte.contains("gestionnaire des tâches") {
        print("  ✓ le rapport dit combien de fils, et ce qu'un cœur y vaut")
    } else {
        print("  ✗ le rapport ne rapporte pas le pourcentage au nombre de fils")
        print(texte)
        echecs += 1
    }

    // Le cas qui a failli faire conclure de travers : zéro image dessinée, et cinq
    // cœurs occupés — par la séparation des pistes, qu'ouvrir un morceau déclenche.
    // Les deux nombres étaient justes ; lus ensemble sans cet avertissement, ils
    // accusaient la boucle d'un travail qui n'était pas le sien.
    let pendantUnCalcul = Repos.Passe(nom: "essai", secondes: 5, images: 0,
                                      processeur: 25, travaillait: true)
    let avecAvis = Repos.rapport([pendantUnCalcul], fils: 8)
    if avecAvis.contains("calculait encore") {
        print("  ✓ une passe mesurée pendant un calcul le dit")
    } else {
        print("  ✗ une passe mesurée pendant un calcul passe pour du repos")
        echecs += 1
    }
    if Repos.rapport([passe], fils: 8).contains("calculait encore") {
        print("  ✗ l'avertissement paraît sur une passe qui ne calculait rien")
        echecs += 1
    } else {
        print("  ✓ et une passe au repos ne porte pas l'avertissement")
    }
}

// MARK: - Le temps de processeur

// Il ne s'agit pas de mesurer quoi que ce soit ici, mais de vérifier que l'horloge
// répond : sur une plateforme où elle rendrait zéro, tout relevé de repos dirait
// « rien consommé » et passerait pour une bonne nouvelle.
print("\n  L'horloge de processeur")
do {
    let depart = Horloge.tempsProcesseur()
    // Une demi-seconde de calcul, comptée à l'horloge murale et non en tours de
    // boucle : sous Windows, le temps de processeur d'un processus n'avance que par
    // pas de quinze millisecondes, et un calcul trop court peut se lire zéro sur
    // une horloge parfaitement juste. Une demi-seconde met trente pas entre les
    // deux relevés, ce qui ne laisse plus de doute.
    let fin = Horloge.maintenant() + 0.5
    var somme = 0.0
    var i = 1.0
    while Horloge.maintenant() < fin {
        for _ in 0..<100_000 { somme += i.squareRoot(); i += 1 }
    }
    let brûlé = Horloge.tempsProcesseur() - depart
    // La moitié de ce qui s'est écoulé : le harnais n'a qu'un fil, et l'on veut
    // savoir que l'horloge compte, pas mesurer la machine.
    if brûlé > 0.25, somme > 0 {
        print("  ✓ elle compte le temps brûlé (\(String(format: "%.3f", brûlé)) s)")
    } else {
        print("  ✗ elle rend \(brûlé) s pour une demi-seconde de calcul")
        echecs += 1
    }
}

print("")
if echecs == 0 {
    print("Cadence : tout est passé.")
    exit(0)
}
print("Cadence : \(echecs) contrôle(s) en échec.")
exit(1)
