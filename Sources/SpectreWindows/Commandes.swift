import Foundation
import SpectreCore
import SpectreModele
import SpectreWin

// Ce que le panneau montre — le pendant de `Sources/Spectre/Controls.swift` et de
// `Sources/Spectre/Preferences.swift`, réunis.
//
// ─────────────────────────────────────────────────────────────────────────────
// RÉUNIS, ET C'EST UN CHOIX
//
// Sur le Mac, les commandes flottent sur l'image et les préférences vivent dans la
// fenêtre ⌘,. Le partage y a une raison : macOS *a* une fenêtre de préférences, à
// une place que tout le monde connaît, et n'en pas user serait s'en écarter pour
// rien.
//
// Windows n'a pas cet endroit — chaque application invente le sien. Et la frontière
// entre les deux moitiés n'est pas celle qu'on croit à l'usage : le contraste est un
// réglage « d'affichage » et la clarté minimale d'une raie un réglage « d'accords »,
// alors qu'on les tourne l'un après l'autre en regardant la même image bouger. Les
// séparer ici obligerait à ouvrir deux choses pour un seul geste.
//
// Un seul panneau, donc, qui défile. Ce qui vient d'abord est ce qu'on touche à
// chaque morceau ; ce qui vient à la fin est ce qu'on règle une fois pour toutes.
// ─────────────────────────────────────────────────────────────────────────────

struct Commandes {
    let modele: AppModel
    let preferences: PreferencesWindows

    /// Décrit le panneau, commande par commande. Appelée à chaque image : ce qui est
    /// lu vient du modèle, ce qui est écrit y retourne aussitôt.
    func dessiner(dans panneau: Panneau) {
        lecture(panneau)
        boucle(panneau)
        tempo(panneau)
        image(panneau)
        couleurs(panneau)
        analyse(panneau)
        accords(panneau)
    }

    // MARK: - Lecture

    private func lecture(_ p: Panneau) {
        p.titre("Lecture")

        if let vitesse = p.curseur("Vitesse", modele.player.speed, 0.25...1.5,
                                   texte: String(format: "×%.2f", modele.player.speed),
                                   actif: modele.duration > 0) {
            modele.player.speed = vitesse
        }
        if let ton = p.curseur("Ton", modele.player.transpose, -12...12,
                               texte: String(format: "%+.1f", modele.player.transpose),
                               actif: modele.duration > 0) {
            modele.player.transpose = ton
        }
        if let volume = p.curseur("Volume", modele.player.volume, 0...1,
                                  texte: String(format: "%.0f %%",
                                                modele.player.volume * 100)) {
            modele.player.volume = volume
        }

        switch p.boutons(modele.player.isPlaying ? ["Pause", "Neutre"] : ["Lire", "Neutre"],
                         inactifs: modele.duration == 0 ? [0]
                                  : modele.player.isNeutral ? [1] : []) {
        case 0: modele.togglePlayback()
        case 1:
            // Le ralenti et la transposition se remettent d'aplomb ensemble : on les
            // a poussés ensemble pour déchiffrer un passage, et l'on veut réentendre
            // le morceau tel qu'il est, pas à moitié.
            modele.player.speed = 1
            modele.player.transpose = 0
        default: break
        }
    }

    // MARK: - Boucle

    private func boucle(_ p: Panneau) {
        p.titre("Boucle")
        if let boucler = p.bascule("Jouer en boucle", modele.loopEnabled,
                                   actif: modele.loop != nil) {
            modele.loopEnabled = boucler
        }
        if let plage = modele.loop {
            p.note("Du \(AppModel.format(plage.lowerBound)) au "
                   + "\(AppModel.format(plage.upperBound))",
                   valeur: AppModel.format(plage.upperBound - plage.lowerBound))
        } else {
            p.explication("Glisser dans la réglette du haut — ou ⇧ et glisser "
                          + "n'importe où sur l'image — trace un passage. Il sert à la "
                          + "fois de boucle de lecture et, en portée « un accord par "
                          + "mesure », de portée du relevé.")
        }
        var inactifs = Set<Int>()
        if modele.loop == nil || modele.tempo == nil { inactifs.insert(0) }
        if modele.loop == nil { inactifs.insert(1) }
        switch p.boutons(["Aux mesures", "Effacer"], inactifs: inactifs) {
        case 0: modele.snapLoopToBars()
        case 1: modele.loop = nil
        default: break
        }
    }

    // MARK: - Tempo

    private func tempo(_ p: Panneau) {
        p.titre("Tempo et mesures")
        if let grille = modele.tempo, grille.bpm > 0 {
            p.note("Relevé", valeur: String(format: "%.1f BPM", grille.bpm))
            if grille.confidence > 0, grille.confidence < 2.2 {
                p.explication("Le relevé hésite sur ce morceau : la grille est "
                              + "probablement à recaler à la main.")
            }
            switch p.boutons(["− 0,1", "+ 0,1", "1 ici", "Refaire"]) {
            case 0: modele.nudgeTempo(by: -0.1)
            case 1: modele.nudgeTempo(by: 0.1)
            case 2: modele.setDownbeatAtPlayhead()
            case 3: modele.recomputeTempo()
            default: break
            }
            let temps = [3, 4, 5, 6, 7]
            if let choisi = p.segments("Temps par mesure",
                                       temps.map(String.init),
                                       temps.firstIndex(of: modele.beatsPerBar) ?? 1) {
                modele.beatsPerBar = temps[choisi]
            }
        } else {
            p.note("Aucune grille relevée")
            if p.boutons(["Relever le tempo"],
                         inactifs: modele.spectrogram.columnCount == 0 ? [0] : []) == 0 {
                modele.recomputeTempo()
            }
        }
    }

    // MARK: - Image

    private func image(_ p: Panneau) {
        p.titre("Image")

        let vide = modele.spectrogram.columnCount == 0
        if let noir = p.curseur("Contraste", modele.display.floorDb, -120...(-40),
                                texte: String(format: "%.0f dB", modele.display.floorDb),
                                actif: !vide) {
            modele.display.floorDb = noir
        }
        p.explication("Le niveau rendu noir. C'est la frontière entre ce qui est joué "
                      + "et ce qui ne l'est pas — l'éclaircir fait entrer des raies "
                      + "pâles dans le relevé d'accords, et les noms changent sous vos "
                      + "yeux pendant que vous tirez.")
        switch p.boutons(["Auto", "Ouverture"], inactifs: vide ? [0, 1] : []) {
        case 0: modele.applyAutoContrast()
        case 1: modele.restoreOpeningContrast()
        default: break
        }

        if let zoom = p.curseur("Zoom vertical", log2(modele.verticalZoom), 0...6,
                                texte: String(format: "%.1f oct", modele.visibleOctaves),
                                actif: !vide) {
            modele.verticalZoom = pow(2, zoom)
        }

        p.air()
        p.note("Palette")
        if let choisie = p.choix(ColorMap.allCases.map(\.label),
                                 modele.display.colorMap.rawValue),
           let palette = ColorMap(rawValue: choisie) {
            modele.display.colorMap = palette
        }

        p.air()
        if let batterie = p.bascule("Ligne de batterie", modele.showDrumLane) {
            modele.showDrumLane = batterie
        }
        if let grille = p.bascule("Grille d'accords", modele.showChords) {
            modele.showChords = grille
        }
        if let bemols = p.segments("Noms des touches noires", ["Bémols", "Dièses"],
                                   modele.display.useFlats ? 0 : 1) {
            modele.display.useFlats = bemols == 0
        }
    }

    // MARK: - Couleur des notes

    private func couleurs(_ p: Panneau) {
        p.titre("Couleur des notes")
        let noms = Pitch.names(flats: modele.display.useFlats)
        if let classe = p.teintes(noms, origine: preferences.hueOrigin,
                                  saturation: modele.display.noteSaturation) {
            preferences.hueOrigin = classe
        }
        p.explication("Les douze teintes sont réparties selon le cycle des quintes : "
                      + "deux notes proches harmoniquement sont proches en couleur, un "
                      + "triton les met en opposition. Choisir la première ne fait que "
                      + "tourner la série — ces rapports-là ne bougent pas.")
    }

    // MARK: - Analyse

    private func analyse(_ p: Panneau) {
        p.titre("Analyse")
        if let reattribution = p.bascule("Réattribution spectrale",
                                         preferences.reassignment) {
            preferences.reassignment = reattribution
            modele.analysis.reassignment = reattribution
            // Changer la façon d'analyser, ce n'est pas changer la façon d'afficher :
            // il n'y a rien à retoucher dans la matrice, elle est à refaire. Le
            // morceau ouvert repart donc pour une analyse — un aller-retour par la
            // session, si bien que le cadrage, le contraste et la tête de lecture
            // sont retrouvés.
            modele.reanalyse()
        }
        p.explication("Chaque case de la transformée dépose son énergie à la fréquence "
                      + "que sa propre phase désigne, au lieu du centre de la case qui "
                      + "l'a captée. Les partiels passent de trois lignes à une, et les "
                      + "attaques cessent de baver.")
        p.explication("En échange, ce qui n'est pas fait de raies — souffle, cymbales, "
                      + "réverbération — devient granuleux, et l'analyse coûte deux fois "
                      + "plus. La décocher refait l'image du morceau ouvert.")
    }

    // MARK: - Le relevé des accords

    /// Les huit nombres dont dépend ce qu'une raie doit être pour compter.
    ///
    /// Écrits ici dans le même ordre et avec les mêmes bornes que dans le panneau
    /// macOS. Les deux se lisent l'un contre l'autre — c'est la discipline qui vaut
    /// déjà pour `Frise.swift` et `TimelineOverlay`, et pour la même raison : le jour
    /// où l'un des deux changera, on verra lequel.
    private func accords(_ p: Panneau) {
        p.titre("Relevé des accords")
        var reglages = preferences.chords
        var change = false

        p.note("Portée")
        if let portee = p.choix(ChordSettings.Scope.allCases.map(\.label),
                               reglages.scope.rawValue),
           let valeur = ChordSettings.Scope(rawValue: portee) {
            reglages.scope = valeur
            change = true
        }
        p.explication(reglages.scope == .beat
                      ? "Un accord est décidé sur chaque temps, puis la suite est "
                        + "lissée : changer d'accord coûte, rester ne coûte rien. Il "
                        + "sait montrer un changement au milieu d'une mesure, au prix "
                        + "de décisions prises sur très peu de matière."
                      : "Un accord par mesure, décidé sur la mesure entière et sur rien "
                        + "d'autre. Et dès qu'une boucle est tracée, elle devient la "
                        + "seule portée du relevé : un accord, pour ce passage-là.")

        p.air()
        p.note("Vocabulaire")
        if let vocabulaire = p.choix(ChordSettings.Vocabulary.allCases.map(\.label),
                                     reglages.vocabulary.rawValue),
           let valeur = ChordSettings.Vocabulary(rawValue: vocabulaire) {
            reglages.vocabulary = valeur
            change = true
        }
        p.explication("Ce qu'on s'autorise à nommer. Ce que le vocabulaire ne sait pas "
                      + "écrire ne disparaît pas de l'image pour autant : il se retrouve "
                      + "entouré en pointillés. Restreindre est souvent ce qui améliore "
                      + "le plus un relevé — sur un morceau qui ne joue que des triades, "
                      + "interdire le reste supprime d'un coup toutes les erreurs "
                      + "possibles.")

        p.air()
        if let valeur = p.curseur("Clarté minimale d'une raie", reglages.clarity,
                                  0...0.4, texte: String(format: "%.2f", reglages.clarity)) {
            reglages.clarity = valeur
            change = true
        }
        p.explication("À partir de quelle clarté un trait de l'image compte comme une "
                      + "note. C'est la même échelle que l'écran : 0 est le noir réglé, "
                      + "1 le blanc. Le curseur de contraste fait donc le même travail.")

        if let valeur = p.curseur("Tenue minimale", reglages.hold, 0.3...1,
                                  texte: String(format: "%.0f %%", reglages.hold * 100)) {
            reglages.hold = valeur
            change = true
        }
        p.explication("Quelle part de la mesure — ou du passage sélectionné — une raie "
                      + "doit occuper pour être une note de l'accord. C'est ce qui sépare "
                      + "une harmonie d'une broderie. Monté trop haut, plus rien ne tient "
                      + "et la ligne se vide.")

        if let valeur = p.curseur("Netteté d'une raie", reglages.prominence, 0...12,
                                  texte: String(format: "%.1f dB", reglages.prominence)) {
            reglages.prominence = valeur
            change = true
        }
        p.explication("De combien un trait doit se détacher du fond avant le demi-ton "
                      + "voisin. Sans cette exigence, on relève une tenue un demi-ton à "
                      + "côté de chaque note franche. C'est le seul réglage qui fasse "
                      + "relire l'image ; les autres sont instantanés.")

        if let valeur = p.curseur("Décroissance des harmoniques", reglages.harmonicDrop,
                                  0...20,
                                  texte: String(format: "%.1f dB", reglages.harmonicDrop)) {
            reglages.harmonicDrop = valeur
            change = true
        }
        if let valeur = p.curseur("Marge pour la croire jouée", reglages.mustExceedParent,
                                  0...20,
                                  texte: String(format: "%.1f dB",
                                                reglages.mustExceedParent)) {
            reglages.mustExceedParent = valeur
            change = true
        }
        p.explication("Une note isolée peuple le spectre bien au-delà d'elle-même. Une "
                      + "raie qu'une raie plus grave explique ainsi n'est pas entourée. "
                      + "Baissez-les et l'accord se réduit à sa basse ; montez-les et "
                      + "chaque harmonique devient une note.")

        if let valeur = p.curseur("Prix d'une raie inexpliquée", reglages.unexplainedCost,
                                  0...2,
                                  texte: String(format: "%.2f", reglages.unexplainedCost)) {
            reglages.unexplainedCost = valeur
            change = true
        }
        if let valeur = p.curseur("Prix d'une note absente", reglages.missingCost, 0...2,
                                  texte: String(format: "%.2f", reglages.missingCost)) {
            reglages.missingCost = valeur
            change = true
        }
        p.explication("Les deux plateaux de la balance. Le premier force le relevé à "
                      + "rendre compte de tout ce qu'on voit ; le second est plus bas, "
                      + "parce qu'une quinte masquée est chose commune alors qu'une "
                      + "tierce inventée ne l'est pas.")

        if let valeur = p.curseur("La basse impose sa fondamentale", reglages.bassAgreement,
                                  0...1,
                                  texte: String(format: "%.2f", reglages.bassAgreement)) {
            reglages.bassAgreement = valeur
            change = true
        }
        if let valeur = p.curseur("Basse étrangère à l'accord", reglages.bassContradiction,
                                  0...1,
                                  texte: String(format: "%.2f",
                                                reglages.bassContradiction)) {
            reglages.bassContradiction = valeur
            change = true
        }
        p.explication("La basse est ici la raie tenue la plus grave de l'image. C'est "
                      + "elle qui sépare Do6 de La-7, qui sont pourtant les mêmes notes.")

        if let valeur = p.curseur("Prix des couleurs rares", reglages.rarityWeight, 0...3,
                                  texte: String(format: "%.2f", reglages.rarityWeight)) {
            reglages.rarityWeight = valeur
            change = true
        }
        if let valeur = p.curseur("Coût d'un changement d'accord", reglages.changeCost,
                                  0...1.5,
                                  texte: String(format: "%.2f", reglages.changeCost),
                                  actif: reglages.scope == .beat) {
            reglages.changeCost = valeur
            change = true
        }
        p.explication(reglages.scope == .span
                      ? "Sans effet ici : des mesures décidées séparément ne sont lissées "
                        + "par rien. Le réglage revient avec la portée « un accord par "
                        + "temps »."
                      : "L'inertie du relevé. Monté, l'accord tient — au risque d'avaler "
                        + "les changements brefs. À zéro, deux accords voisins se mettent "
                        + "à clignoter d'un temps sur l'autre.")

        if p.boutons(["Rétablir les valeurs d'origine"],
                     inactifs: reglages == ChordSettings() ? [0] : []) == 0 {
            reglages = ChordSettings()
            change = true
        }

        // Un seul aller-retour par image, et seulement s'il y a eu un changement : le
        // relevé se refait sur le morceau ouvert à chaque écriture, et l'écrire à
        // chaque commande le referait sept fois pour un curseur tiré une fois.
        guard change, reglages != preferences.chords else { return }
        preferences.chords = reglages
        modele.reloadChords()
    }
}
