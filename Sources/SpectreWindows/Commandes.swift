import Foundation
import SpectreCore
import SpectreModele
import SpectreWin

// Ce que le panneau montre — le pendant de `Sources/Spectre/Controls.swift`.
//
// ─────────────────────────────────────────────────────────────────────────────
// UN SEUL PANNEAU, ET C'EST UN CHOIX
//
// Sur le Mac, les commandes flottent sur l'image et les réglages de l'application
// entière vivent dans la fenêtre ⌘, : le cache des pistes, l'ancrage des couleurs.
// Le partage y a une raison — macOS *a* une fenêtre de préférences, à une place
// que tout le monde connaît, et n'en pas user serait s'en écarter pour rien.
//
// Windows n'a pas cet endroit : chaque application invente le sien. Un seul
// panneau, donc, qui défile. Ce qui vient d'abord est ce qu'on touche à chaque
// morceau ; ce qui vient à la fin est ce qu'on règle une fois pour toutes.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUI N'EST PLUS RÉGLABLE, NI ICI NI SUR LE MAC
//
// Le panneau a porté douze curseurs de relevé d'accords, un interrupteur de
// réattribution spectrale et la bande des douze teintes. Ils sont partis ensemble,
// des deux côtés, et pour la même raison : ce sont des poids de fonction de coût
// et un réglage d'analyse qu'on n'accorde pas en une séance, mais en écoutant ce
// qu'ils changent sur plusieurs morceaux. Les valeurs d'origine sont celles qui
// ont gagné cet accord ; les exposer ne servait qu'à les défaire.
//
// Elles vivent maintenant dans `ChordSettings()` et dans `PreferencesWindows`, en
// constantes — voir la note qui y est écrite.
// ─────────────────────────────────────────────────────────────────────────────

/// Une classe et non une structure : le panneau est décrit à chaque image, et deux
/// ou trois choses ne peuvent pas se relever aussi souvent — la taille du cache des
/// pistes demande de parcourir un dossier de plusieurs gigaoctets.
final class Commandes {
    let modele: AppModel
    let preferences: PreferencesWindows

    /// Ce que le dossier des pistes occupe, relevé de loin en loin.
    ///
    /// Le parcourir à chaque image reviendrait à lister quelques milliers de fichiers
    /// cent vingt fois par seconde, pour un chiffre qui bouge une fois par morceau.
    private var tailleDuCache = 0
    private var relevéLe = -1.0

    init(modele: AppModel, preferences: PreferencesWindows) {
        self.modele = modele
        self.preferences = preferences
    }

    /// Décrit le panneau, commande par commande. Appelée à chaque image : ce qui est
    /// lu vient du modèle, ce qui est écrit y retourne aussitôt.
    ///
    /// L'ordre est celui du panneau macOS, et il n'est pas quelconque : le tempo
    /// vient en premier parce que **tout le reste en dépend** — sans grille, pas de
    /// barres de mesure, pas d'accords, pas de boucle calée. C'est le premier
    /// réglage qu'on vérifie en ouvrant un morceau.
    func dessiner(dans panneau: Panneau) {
        tempo(panneau)
        lecture(panneau)
        image(panneau)
        affichage(panneau)
        boucle(panneau)
        pistes(panneau)
    }

    // MARK: - Le tempo

    /// Le tempo, tout entier sur une ligne : le chiffre, les deux flèches, la
    /// signature, le premier temps, et de quoi relancer l'estimation.
    ///
    /// Sur une ligne parce que c'est **une** question — sur quelle grille ce morceau
    /// est-il écrit — et qu'on y répond d'un coup : on lit le chiffre, on pose le 1
    /// au bon endroit, c'est fini.
    private func tempo(_ p: Panneau) {
        p.titre("Détection du tempo",
                aide: "Estimée à l'ouverture d'après les attaques. Elle commande les "
                    + "barres de mesure, l'aimantation du curseur et le relevé des "
                    + "accords.")

        guard let grille = modele.tempo, grille.bpm > 0 else {
            if p.rangee([
                .mot("Tempo indéterminé"),
                .bouton("Chercher",
                        aide: "Chercher une grille dans ce morceau. Sans elle, ni "
                            + "barres de mesure ni relevé d'accords.",
                        actif: modele.spectrogram.columnCount > 0)
            ]) == 1 {
                modele.recomputeTempo()
            }
            return
        }

        // Une estimation peu franche est annoncée comme telle : mieux vaut un « à
        // peu près » visible qu'une grille faussement assurée.
        let franc = grille.confidence <= 0 || grille.confidence >= 2.2
        switch p.rangee([
            franc ? .rien
                  : .alerte("≈", aide: "L'estimation n'est pas franche sur ce "
                                     + "morceau : la grille est à vérifier."),
            .valeur(String(format: "%.1f", grille.bpm)),
            .mot("BPM"),
            .bouton("−", aide: "Retirer 0,1 BPM — de quoi rattraper une grille qui "
                             + "dérive sur la longueur."),
            .bouton("+", aide: "Ajouter 0,1 BPM — de quoi rattraper une grille qui "
                             + "dérive sur la longueur."),
            .bouton("\(modele.beatsPerBar)/4",
                    aide: "Temps par mesure : l'espacement des barres, et le repère "
                        + "du premier temps. Cliquer fait défiler 2/4 à 7/4."),
            .bouton("1 ici", aide: "Poser le premier temps de la mesure à la tête de "
                                 + "lecture (1)."),
            .bouton("Refaire", aide: "Relancer l'estimation, avec la signature "
                                   + "choisie.")
        ]) {
        case 3: modele.nudgeTempo(by: -0.1)
        case 4: modele.nudgeTempo(by: 0.1)
        case 5:
            // Elle défile plutôt qu'elle ne s'ouvre : un menu déroulant demande une
            // fenêtre que le mode immédiat n'a pas, et six signatures se parcourent
            // plus vite qu'on ne vise dans une liste.
            let temps = [2, 3, 4, 5, 6, 7]
            let rang = temps.firstIndex(of: modele.beatsPerBar) ?? 2
            modele.beatsPerBar = temps[(rang + 1) % temps.count]
        case 6: modele.setDownbeatAtPlayhead()
        case 7: modele.recomputeTempo()
        default: break
        }
    }

    // MARK: - Lecture

    private func lecture(_ p: Panneau) {
        p.titre("Lecture",
                aide: "Ce qui se joue, et comment. Cliquer dans l'image déplace la "
                    + "tête de lecture et fait sonner la raie désignée.")

        switch p.rangee([
            .bouton(modele.player.isPlaying ? "Pause" : "Lire",
                    aide: "Lire ou mettre en pause (espace). Les flèches ← et → "
                        + "avancent d'une seconde, de cinq avec ⇧.",
                    actif: modele.duration > 0),
            .valeur(AppModel.format(modele.playhead)),
            .bouton("Neutre",
                    aide: "Ramener la vitesse à 100 % et la transposition à +0. Le "
                        + "ralenti et la transposition se remettent d'aplomb "
                        + "ensemble : on les a poussés ensemble pour déchiffrer un "
                        + "passage, et l'on veut réentendre le morceau tel qu'il "
                        + "est, pas à moitié.",
                    actif: !modele.player.isNeutral)
        ]) {
        case 0: modele.togglePlayback()
        case 2:
            modele.player.speed = 1
            modele.player.transpose = 0
        default: break
        }

        // En pourcentage et non en « × », et « Transposition » et non « Ton » : les
        // mêmes mots que le panneau macOS, parce que ce sont les mêmes réglages.
        if let vitesse = p.curseur("Vitesse", modele.player.speed, 0.25...1.5,
                                   texte: String(format: "%.0f %%",
                                                 modele.player.speed * 100),
                                   aide: "Ralentit ou accélère sans toucher à la "
                                       + "hauteur. À 100 % le traitement est retiré "
                                       + "du chemin du son.",
                                   actif: modele.duration > 0) {
            modele.player.speed = vitesse
        }
        if let ton = p.curseur("Transposition", modele.player.transpose, -12...12,
                               texte: String(format: "%+.1f dt", modele.player.transpose),
                               aide: "Transpose sans toucher à la vitesse, en "
                                   + "demi-tons. Les valeurs intermédiaires recalent "
                                   + "un enregistrement désaccordé.",
                               actif: modele.duration > 0) {
            modele.player.transpose = ton
        }
        if let volume = p.curseur("Volume", modele.player.volume, 0...1,
                                  texte: String(format: "%.0f %%",
                                                modele.player.volume * 100),
                                  aide: "Le niveau de sortie de l'application. Le "
                                      + "Mac s'en remet au mélangeur du système ; "
                                      + "ici, c'est le seul endroit où le régler "
                                      + "sans quitter la fenêtre.") {
            modele.player.volume = volume
        }
    }

    // MARK: - Image

    /// Ce que le spectrogramme montre : jusqu'où descendre dans le fond, et sur
    /// combien d'octaves l'étaler.
    private func image(_ p: Panneau) {
        p.titre("Image",
                aide: "Ce que le spectrogramme montre : jusqu'où descendre dans le "
                    + "fond, et sur combien d'octaves l'étaler.")

        let vide = modele.spectrogram.columnCount == 0
        if let noir = p.curseur("Contraste", modele.display.floorDb, -120...(-40),
                                texte: String(format: "%.0f dB", modele.display.floorDb),
                                aide: "Le niveau rendu noir : la frontière entre ce "
                                    + "qui est joué et ce qui ne l'est pas. Le "
                                    + "monter nettoie le fond, et retire du même "
                                    + "coup ce bruit de l'aimant du curseur ; "
                                    + "l'éclaircir fait entrer des raies pâles dans "
                                    + "le relevé d'accords.",
                                actif: !vide) {
            modele.display.floorDb = noir
        }
        // « Global » et « local » disent la seule chose qui les sépare : sur quoi le
        // réglage est mesuré. L'un relit le morceau entier tel qu'il a été mesuré à
        // l'ouverture, l'autre ce que la fenêtre montre en ce moment.
        switch p.boutons(["Auto global", "Auto local"],
                         aides: ["Revenir au contraste mesuré sur le morceau entier "
                                 + "à son ouverture — le repère d'où l'on est parti.",
                                 "Régler noir, clair et pente d'après ce qui est à "
                                 + "l'écran en ce moment."],
                         inactifs: vide ? [0, 1] : []) {
        case 0: modele.restoreOpeningContrast()
        case 1: modele.applyAutoContrast()
        default: break
        }

        if let zoom = p.curseur("Zoom vertical", log2(modele.verticalZoom), 0...6,
                                texte: String(format: "%.1f oct", modele.visibleOctaves),
                                aide: "Étale l'axe des fréquences ; la valeur donne "
                                    + "le nombre d'octaves visibles. À la souris : "
                                    + "⇧ et la molette, ancré sous le curseur. La "
                                    + "lecture est filtrée sur la bande visible.",
                                actif: !vide) {
            modele.verticalZoom = pow(2, zoom)
        }
    }

    // MARK: - Affichage

    /// Ce qui se pose autour de l'image : la ligne de batterie, les noms d'accords,
    /// l'écriture des touches noires.
    private func affichage(_ p: Panneau) {
        p.titre("Affichage",
                aide: "Ce qui se pose autour de l'image : la ligne de batterie, les "
                    + "noms d'accords, l'écriture des touches noires.")

        if let batterie = p.bascule("Batterie", modele.showDrumLane,
                                    aide: "Relevé de la batterie, sous l'image : un "
                                        + "trait par coup, une ligne par voie. Le "
                                        + "spectrogramme dit la hauteur, qu'une "
                                        + "percussion n'a pas ; ces trois lignes "
                                        + "disent quand, quoi et combien fort. Elles "
                                        + "valent surtout sur la piste de batterie "
                                        + "isolée.") {
            modele.showDrumLane = batterie
        }
        if let remarque = modele.drumLaneNotice { p.explication(remarque) }
        if let grille = p.bascule("Accords", modele.showChords,
                                  aide: "Noms d'accords, au pied de la grille : un "
                                      + "par temps, par mesure ou par phrase selon "
                                      + "le zoom. Devinés sur la basse et "
                                      + "l'accompagnement séparés — il faut donc que "
                                      + "les quatre pistes soient calculées, et "
                                      + "qu'une grille métrique existe. La pâleur "
                                      + "d'un nom dit l'incertitude du relevé.") {
            modele.showChords = grille
        }
        if let bemols = p.segments("Noms des touches noires", ["Bémols", "Dièses"],
                                   modele.display.useFlats ? 0 : 1,
                                   aide: "L'écriture des touches noires : Mi♭ ou "
                                       + "Ré♯.") {
            modele.display.useFlats = bemols == 0
        }
    }

    // MARK: - Boucle

    private func boucle(_ p: Panneau) {
        p.titre("Boucle",
                aide: "Tracer une boucle : glisser dans la réglette du haut, ou ⇧ et "
                    + "glisser n'importe où sur l'image. [ et ] posent le début et "
                    + "la fin à la tête de lecture. Elle sert à la fois de boucle de "
                    + "lecture et, en portée « un accord par mesure », de portée du "
                    + "relevé.")
        if let boucler = p.bascule("Jouer en boucle", modele.loopEnabled,
                                   aide: "Jouer le passage en boucle, sans trou à la "
                                       + "reprise (L).",
                                   actif: modele.loop != nil) {
            modele.loopEnabled = boucler
        }
        if let plage = modele.loop {
            p.note("Du \(AppModel.format(plage.lowerBound)) au "
                   + "\(AppModel.format(plage.upperBound))",
                   valeur: AppModel.format(plage.upperBound - plage.lowerBound))
        } else {
            p.note("Aucun passage tracé")
        }
        var inactifs = Set<Int>()
        if modele.loop == nil || modele.tempo == nil { inactifs.insert(0) }
        if modele.loop == nil { inactifs.insert(1) }
        switch p.boutons(["Aux mesures", "Effacer"],
                         aides: ["Étendre la boucle aux mesures qui l'encadrent (B).",
                                 "Effacer la boucle (échap)."],
                         inactifs: inactifs) {
        case 0: modele.snapLoopToBars()
        case 1: modele.loop = nil
        default: break
        }
    }

    // MARK: - Les pistes

    /// Ce qui reste des pistes dans le panneau : leur état, et le dossier où elles
    /// sont rangées.
    ///
    /// Les quatre bascules n'y sont plus : elles vivent dans la colonne flottante, à
    /// l'écran en permanence — voir `Flottant.swift`. Les répéter ici reviendrait à
    /// montrer deux fois le même interrupteur à deux points de l'écran, l'un d'eux
    /// étant caché neuf fois sur dix.
    private func pistes(_ p: Panneau) {
        p.titre("Pistes",
                aide: "Les quatre pistes séparées, celles que la colonne de droite "
                    + "fait entendre. Choisir une piste ne change pas seulement ce "
                    + "qu'on entend, mais ce qu'on voit : le spectrogramme d'une "
                    + "piste isolée a bien moins de partielles qui se croisent, si "
                    + "bien que l'aimantation tombe enfin sur la bonne raie.")

        guard modele.hasModel else {
            p.explication(Reseau.fichier == nil
                          ? "Les poids de Demucs ne sont pas installés — voir "
                            + "`modele.sh`. Sans eux, le morceau se lit tel qu'il est."
                          : "ONNX Runtime n'est pas installé : lancer .\\onnx.ps1, "
                            + "puis relancer l'application.")
            return
        }

        if let avancement = modele.separating {
            p.note(modele.status ?? "Séparation des pistes…",
                   valeur: String(format: "%.0f %%", avancement * 100))
        } else if let erreur = modele.separationError {
            p.explication(erreur)
        }

        p.note("Gardées", valeur: Stem.label(for: modele.selection))

        var inactifs = Set<Int>()
        if modele.isWholeMix { inactifs.insert(0) }
        if !modele.isSeparated || modele.separating != nil { inactifs.insert(1) }
        switch p.boutons(["Tout garder", "Refaire"],
                         aides: ["Réentendre le mixage entier, les quatre pistes "
                                 + "cochées.",
                                 // Oublier les pistes les fait recalculer à la
                                 // prochaine écoute d'une piste seule : c'est le
                                 // recours quand la séparation a mal tourné.
                                 "Oublier les pistes calculées. Elles se refont à la "
                                 + "prochaine écoute d'une piste seule — le recours "
                                 + "quand la séparation a mal tourné sur un morceau."],
                         inactifs: inactifs) {
        case 0: modele.restoreWholeMix()
        case 1: modele.forgetStems()
        default: break
        }

        p.air()
        p.note("Cache des pistes", valeur: Self.enOctets(occupe()))
        let paliers = PreferencesWindows.paliersDeCache
        if let choisi = p.segments("Plafond", paliers.map(Self.enOctets),
                                   paliers.firstIndex(of: preferences.cacheLimit) ?? 1,
                                   aide: "Un morceau de sept minutes coûte environ "
                                       + "300 Mo. Au-delà du plafond, les morceaux "
                                       + "les moins récemment ouverts s'en vont "
                                       + "entiers — jamais celui qu'on écoute — et "
                                       + "se recalculent.") {
            preferences.cacheLimit = paliers[choisi]
            relevéLe = -1
        }
        if p.boutons(["Vider le cache"],
                     aides: ["Jeter toutes les pistes rangées. Chaque morceau devra "
                             + "être séparé de nouveau, soit environ une demi-minute "
                             + "par morceau."],
                     inactifs: occupe() == 0 ? [0] : []) == 0 {
            RangementDesPistes.vider()
            relevéLe = -1
        }
    }

    /// La taille du cache, relevée au plus une fois toutes les deux secondes.
    private func occupe() -> Int {
        let maintenant = Horloge.maintenant()
        if relevéLe < 0 || maintenant - relevéLe > 2 {
            tailleDuCache = RangementDesPistes.taille()
            relevéLe = maintenant
        }
        return tailleDuCache
    }

    /// Des octets en gigaoctets ou en mégaoctets, comme le système les compte.
    private static func enOctets(_ octets: Int) -> String {
        octets >= 1_000_000_000
            ? String(format: "%.1f Go", Double(octets) / 1_000_000_000)
            : String(format: "%.0f Mo", Double(octets) / 1_000_000)
    }
}
