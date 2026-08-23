import Foundation
import SpectreCore
import SpectreTextes
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
        langue(panneau)
    }

    // MARK: - La langue

    /// La langue et l'écriture des notes, en queue de panneau.
    ///
    /// En queue parce que c'est le réglage qu'on touche une fois et plus jamais —
    /// l'ordre de ce panneau va du quotidien au définitif. Le Mac les met dans sa
    /// fenêtre ⌘, pour la même raison ; Windows n'ayant pas cet endroit, ils
    /// finissent ici.
    ///
    /// Les langues sont désignées par leur code à deux lettres et non par leur nom.
    /// Six segments dans trois cents points laissent cinquante points chacun :
    /// « Français » n'y tient pas, « FR » oui — et c'est déjà ainsi que la page
    /// d'accueil les présente. Le nom entier se lit sur la ligne du dessus.
    private func langue(_ p: Panneau) {
        p.titre(T(.reglagesLangue), aide: T(.reglagesLangueExplication))

        let langues = Langue.allCases
        p.note(T(.reglagesLangueInterface), valeur: Textes.langue.nomNatif)
        let codes = [T(.reglagesAuto)] + langues.map { $0.rawValue.uppercased() }
        let choisie = preferences.langue.flatMap(langues.firstIndex(of:)).map { $0 + 1 } ?? 0
        if let rang = p.segments(nil, codes, choisie,
                                 aide: T(.reglagesLangueInterface)) {
            preferences.langue = rang == 0 ? nil : langues[rang - 1]
        }

        let systemes = SystemeDeNotes.allCases
        let notes = [T(.reglagesAuto)] + systemes.map(\.label)
        let notée = preferences.systemeDeNotes.flatMap(systemes.firstIndex(of:))
            .map { $0 + 1 } ?? 0
        if let rang = p.segments(T(.reglagesNomDesNotes), notes, notée,
                                 aide: T(.reglagesLangueExplication)) {
            preferences.systemeDeNotes = rang == 0 ? nil : systemes[rang - 1]
        }

        // Les douze noms en clair : c'est le seul endroit où l'on voit, sans ouvrir
        // un morceau, que l'allemand appelle B le si bémol et H le si naturel.
        p.explication(Pitch.names(flats: modele.display.useFlats)
                        .joined(separator: "  "))
        if Textes.langueImposee { p.explication(T(.reglagesLangueImposee)) }
    }

    // MARK: - Le tempo

    /// Le tempo, tout entier sur une ligne : le chiffre, les deux flèches, la
    /// signature, le premier temps, et de quoi relancer l'estimation.
    ///
    /// Sur une ligne parce que c'est **une** question — sur quelle grille ce morceau
    /// est-il écrit — et qu'on y répond d'un coup : on lit le chiffre, on pose le 1
    /// au bon endroit, c'est fini.
    private func tempo(_ p: Panneau) {
        p.titre(T(.groupeTempo), aide: T(.groupeTempoAide))

        guard let grille = modele.tempo, grille.bpm > 0 else {
            if p.rangee([
                .mot(T(.tempoIndetermineWin)),
                .bouton(T(.tempoChercher), aide: T(.tempoChercherAide),
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
            franc ? .rien : .alerte("≈", aide: T(.tempoEstimationFloue)),
            .valeur(String(format: "%.1f", grille.bpm)),
            .mot(T(.tempoBPM)),
            .bouton("−", aide: T(.tempoMoinsAide)),
            .bouton("+", aide: T(.tempoPlusAide)),
            .bouton("\(modele.beatsPerBar)/4", aide: T(.tempoSignatureAideWin)),
            .bouton(T(.tempoUnIci), aide: T(.tempoUnIciAideWin)),
            .bouton(T(.tempoRefaire), aide: T(.tempoRelancerAideWin))
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
        p.titre(T(.groupeLecture), aide: T(.groupeLectureAide))

        switch p.rangee([
            .bouton(modele.player.isPlaying ? T(.lecturePause) : T(.lectureLire),
                    aide: T(.lectureLireAideWin),
                    actif: modele.duration > 0),
            .valeur(AppModel.format(modele.playhead)),
            .bouton(T(.lectureNeutre),
                    aide: T(.lectureNeutreAide),
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
        if let vitesse = p.curseur(T(.lectureVitesse), modele.player.speed, 0.25...1.5,
                                   texte: String(format: "%.0f %%",
                                                 modele.player.speed * 100),
                                   aide: T(.lectureVitesseAideWin),
                                   actif: modele.duration > 0) {
            modele.player.speed = vitesse
        }
        if let ton = p.curseur(T(.lectureTransposition), modele.player.transpose, -12...12,
                               texte: String(format: "%+.1f ", modele.player.transpose)
                                   + T(.uniteDemiTons),
                               aide: T(.lectureTranspositionAideWin),
                               actif: modele.duration > 0) {
            modele.player.transpose = ton
        }
        if let volume = p.curseur(T(.lectureVolume), modele.player.volume, 0...1,
                                  texte: String(format: "%.0f %%",
                                                modele.player.volume * 100),
                                  aide: T(.lectureVolumeAide)) {
            modele.player.volume = volume
        }
    }

    // MARK: - Image

    /// Ce que le spectrogramme montre : jusqu'où descendre dans le fond, et sur
    /// combien d'octaves l'étaler.
    private func image(_ p: Panneau) {
        p.titre(T(.groupeImage), aide: T(.groupeImageAide))

        let vide = modele.spectrogram.columnCount == 0
        if let noir = p.curseur(T(.imageContraste), modele.display.floorDb, -120...(-40),
                                texte: String(format: "%.0f dB", modele.display.floorDb),
                                aide: T(.imageContrasteAideWin),
                                actif: !vide) {
            modele.display.floorDb = noir
        }
        // « Global » et « local » disent la seule chose qui les sépare : sur quoi le
        // réglage est mesuré. L'un relit le morceau entier tel qu'il a été mesuré à
        // l'ouverture, l'autre ce que la fenêtre montre en ce moment.
        switch p.boutons([T(.imageAutoGlobal), T(.imageAutoLocal)],
                         aides: [T(.imageAutoGlobalAide), T(.imageAutoLocalAide)],
                         inactifs: vide ? [0, 1] : []) {
        case 0: modele.restoreOpeningContrast()
        case 1: modele.applyAutoContrast()
        default: break
        }

        if let zoom = p.curseur(T(.imageZoomVertical), log2(modele.verticalZoom), 0...6,
                                texte: String(format: "%.1f ", modele.visibleOctaves)
                                    + T(.uniteOctaves),
                                aide: T(.imageZoomVerticalAideWin),
                                actif: !vide) {
            modele.verticalZoom = pow(2, zoom)
        }
    }

    // MARK: - Affichage

    /// Ce qui se pose autour de l'image : la ligne de batterie, les noms d'accords,
    /// l'écriture des touches noires.
    private func affichage(_ p: Panneau) {
        p.titre(T(.groupeAffichage), aide: T(.groupeAffichageAide))

        if let batterie = p.bascule(T(.affichageBatterie), modele.showDrumLane,
                                    aide: T(.affichageBatterieAide)) {
            modele.showDrumLane = batterie
        }
        if let remarque = modele.drumLaneNotice { p.explication(remarque) }
        if let grille = p.bascule(T(.affichageAccords), modele.showChords,
                                  aide: T(.affichageAccordsAide)) {
            modele.showChords = grille
        }
        if let bemols = p.segments(T(.affichageTouchesNoires),
                                   [T(.affichageBemols), T(.affichageDieses)],
                                   modele.display.useFlats ? 0 : 1,
                                   aide: T(.affichageTouchesNoiresAide)) {
            modele.display.useFlats = bemols == 0
        }
    }

    // MARK: - Boucle

    private func boucle(_ p: Panneau) {
        p.titre(T(.groupeBoucle), aide: T(.groupeBoucleAide))
        if let boucler = p.bascule(T(.boucleJouer), modele.loopEnabled,
                                   aide: T(.boucleJouerAideWin),
                                   actif: modele.loop != nil) {
            modele.loopEnabled = boucler
        }
        if let plage = modele.loop {
            p.note(T(.boucleDuAu, AppModel.format(plage.lowerBound),
                     AppModel.format(plage.upperBound)),
                   valeur: AppModel.format(plage.upperBound - plage.lowerBound))
        } else {
            p.note(T(.boucleAucunPassage))
        }
        var inactifs = Set<Int>()
        if modele.loop == nil || modele.tempo == nil { inactifs.insert(0) }
        if modele.loop == nil { inactifs.insert(1) }
        switch p.boutons([T(.boucleAuxMesures), T(.boucleEffacer)],
                         aides: [T(.boucleAuxMesuresAide), T(.boucleEffacerAide)],
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
        p.titre(T(.groupePistes), aide: T(.groupePistesAide))

        guard modele.hasModel else {
            p.explication(Reseau.fichier == nil ? T(.pistesPoidsAbsentsWin)
                                               : T(.pistesOnnxAbsent))
            return
        }

        if let avancement = modele.separating {
            p.note(modele.status ?? T(.statutSeparationEnCours),
                   valeur: String(format: "%.0f %%", avancement * 100))
        } else if let erreur = modele.separationError {
            p.explication(erreur)
        }

        p.note(T(.pistesGardees), valeur: Stem.label(for: modele.selection))

        var inactifs = Set<Int>()
        if modele.isWholeMix { inactifs.insert(0) }
        if !modele.isSeparated || modele.separating != nil { inactifs.insert(1) }
        // Oublier les pistes les fait recalculer à la prochaine écoute d'une piste
        // seule : c'est le recours quand la séparation a mal tourné.
        switch p.boutons([T(.pistesToutGarder), T(.pistesRefaire)],
                         aides: [T(.pistesToutGarderAide), T(.pistesRefaireAide)],
                         inactifs: inactifs) {
        case 0: modele.restoreWholeMix()
        case 1: modele.forgetStems()
        default: break
        }

        p.air()
        p.note(T(.pistesCache), valeur: Self.enOctets(occupe()))
        let paliers = PreferencesWindows.paliersDeCache
        if let choisi = p.segments(T(.pistesPlafond), paliers.map(Self.enOctets),
                                   paliers.firstIndex(of: preferences.cacheLimit) ?? 1,
                                   aide: T(.pistesPlafondAide)) {
            preferences.cacheLimit = paliers[choisi]
            relevéLe = -1
        }
        if p.boutons([T(.pistesViderLeCache)],
                     aides: [T(.pistesViderLeCacheAide)],
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
