import Foundation

// L'anglais. C'est aussi la langue du dernier recours — celle qu'obtient une
// machine réglée dans une sixième langue — d'où le soin particulier : elle sera lue
// par des gens dont ce n'est pas la langue maternelle.

extension Catalogue {
    public static let anglais: [Cle: String] = [

        // MARK: Les pistes
        .pisteMixage: "Mix",
        .pisteBatterie: "Drums",
        .pisteBasse: "Bass",
        .pisteVoix: "Vocals",
        .pisteReste: "Other",
        .pisteMixageAide: "The track as it is.",
        .pisteBatterieAide: """
            Drums and percussion.
            Once the stems are separated it no longer shows in the spectrogram: it feeds the three lanes below, which say about it what a spectrum cannot.
            Unchecked, you stop hearing it and those lanes stay empty.
            """,
        .pisteBasseAide: "The bass alone — the best isolated stem, and the hardest to pick out by ear in a dense mix.",
        .pisteVoixAide: "The singing alone.",
        .pisteResteAide: "Everything else: keys, guitars, brass, strings.",
        .pisteSilence: "silence",
        .pisteSans: "without %1$@",
        .pisteNi: " or ",
        .pistePlus: " + ",
        .pisteDecocherAide: "\nUnchecking removes this stem; what remains is played together.",

        // MARK: Les voies de la batterie
        .voieGrosseCaisse: "Kick drum",
        .voieCaisseClaire: "Snare drum",
        .voieCymbales: "Cymbals",
        .voieGrosseCaisseCourt: "KD",
        .voieCaisseClaireCourt: "SD",
        .voieCymbalesCourt: "CY",

        // MARK: Les palettes
        .paletteGris: "Greyscale",
        .paletteNotes: "Notes (circle of fifths)",

        // MARK: Le relevé d'accords
        .porteeParTemps: "One chord per beat",
        .porteeParMesure: "One chord per bar",
        .vocabulaireTriades: "Triads only",
        .vocabulaireSeptiemes: "Triads and sevenths",
        .vocabulaireTout: "Including sixths and diminished",
        .vocabulaireEnrichis: "With extensions — 9, 11, 13",

        // MARK: Les couleurs d'accord
        .couleurMajeur: "major",
        .couleurMineur: "minor",
        .couleurSuspendu4: "suspended 4th",
        .couleurSeptieme: "seventh",
        .couleurMineurSeptieme: "minor seventh",
        .couleurSeptiemeMajeure: "major seventh",
        .couleurDemiDiminue: "half-diminished",
        .couleurDiminue: "diminished",
        .couleurAugmente: "augmented",
        .couleurSixte: "sixth",
        .couleurMineurSixte: "minor sixth",
        .couleurNeuviemeAjoutee: "added ninth",
        .couleurMineurNeuviemeAjoutee: "minor added ninth",
        .couleurNeuvieme: "ninth",
        .couleurMineurNeuvieme: "minor ninth",
        .couleurSeptiemeMajeureNeuvieme: "major ninth",
        .couleurOnzieme: "eleventh",
        .couleurMineurOnzieme: "minor eleventh",
        .couleurTreizieme: "thirteenth",

        // MARK: Ce qui peut échouer
        .erreurModeleAbsent: "The separation model is not installed.",
        .erreurModeleIllisible: "Model unreadable: %1$@",
        .erreurAucunMorceau: "No track open.",
        .erreurEcritureImpossible: "Cannot write “%1$@”.",
        .erreurInterrompue: "Separation interrupted.",
        .erreurSeparationEchouee: "Separation failed: %1$@",
        .erreurEnvironnementOnnx: "ONNX environment unavailable — %1$@",
        .erreurCoreMLIndisponible: "CoreML unavailable",
        .erreurFormatIllisible: "unreadable format",
        .erreurFormatEntree: "unusable input format",
        .erreurTampons: "buffers unavailable",
        .erreurAucunEchantillon: "no samples read",
        .erreurReseauRienRendu: "the network returned nothing",
        .erreurOnnxAbsent: "ONNX Runtime is not installed — run .\\onnx.ps1.",
        .erreurQuatrePistes: "the network did not return all four stems",
        .erreurLectureImpossible: "Playback failed: %1$@",
        .erreurMoteurAudio: "Audio engine unavailable: %1$@",
        .erreurFichierIllisible: "“%1$@” could not be read.",
        .dialogueOuvrir: "Open",
        .dialogueChoisirUnMorceau: "Choose an audio file to transcribe",

        // MARK: Les étapes de la séparation
        .etapeLectureDuMorceau: "Reading the track…",
        .etapeOuvertureDuReseau: "Loading the network…",
        .etapeCompilationDuReseau: "Compiling the network for this machine — once only…",

        // MARK: Ce que l'application dit d'elle-même
        .statutLectureDuFichier: "Reading the file…",
        .statutAnalyseFaite: "%1$@ — %2$@, analysed in %3$@ s (×%4$@ real time)%5$@",
        .statutReglagesRetrouves: " · settings restored",
        .statutModeleAbsentApplication: "Model missing from the app: run ./modele.sh then ./build.sh.",
        .statutPreparation: "Preparing the track…",
        .statutPistesNonEnregistrees: "Stems not saved: %1$@",
        .statutLectureDesPistes: "Reading the already separated stems…",
        .statutSeparationPourcent: "Separating stems: %1$@ %",
        .statutSeparationRestant: "Separating stems: %1$@ % — %2$@ left",
        .statutSeparationEnCours: "Separating stems…",
        .statutPistesIllisibles: "Stems unreadable; the mix stayed.",
        .statutAnalyseDe: "Analysing “%1$@”…",
        .statutReleveBatterie: "Reading the drums…",
        .statutGrilleReprise: "Grid recovered from the drums",
        .statutBatterieRetiree: "Drums removed",
        .statutAucunCoup: "No hits found",
        .statutReleveAccords: "Reading the chords…",
        .statutAccordsGrilleDabord: "Chords: find the beat grid first",
        .statutAccordsRienDeTenu: "Chords: nothing held on screen — brighten the image",
        .statutPistesEffacees: "Stems cleared.",
        .dureeSecondes: "%1$@ s",
        .dureeMinutes: "%1$@ min",
        .dureeMinutesSecondes: "%1$@ min %2$@ s",

        // MARK: Le panneau : ses groupes
        .groupeTempo: "Tempo detection",
        .groupeTempoAide: "Estimated on opening from the onsets. It drives the bar lines, the snapping and the chord detection.",
        .groupeLecture: "Playback",
        .groupeLectureAide: "What plays, and how. Clicking in the image moves the playhead and sounds the line under the pointer.",
        .groupeImage: "Image",
        .groupeImageAide: "What the spectrogram shows: how far down into the noise floor, and over how many octaves.",
        .groupeAffichage: "Display",
        .groupeAffichageAide: "What sits around the image: the drum lane, the chord names, the spelling of the black keys.",
        .groupeBoucle: "Loop",
        .groupeBoucleAide: "Drawing a loop: drag in the ruler at the top, or ⇧ + drag in the image. Dragging the yellow area moves it, its edges stretch it; the bounds snap to the grid, and ⌘ during the gesture frees them.",
        .groupePistes: "Stems",
        .groupePistesAide: "The four separated stems, the ones the column on the right lets you hear. Choosing a stem changes not only what you hear but what you see: an isolated stem has far fewer partials crossing each other, so the snapping finally lands on the right line.",

        // MARK: Le panneau lui-même
        .panneauReglages: "Settings",
        .panneauOuvrirAide: "Playback, loop, tempo, display — ⌘⌥R",
        .panneauOuvrirAideWin: "Playback, loop, tempo, display — R.",
        .panneauReplierAide: "Fold the panel away — ⌘⌥R",

        // MARK: Le tempo
        .tempoEstimationFloue: "The estimate is not clear-cut on this track: the grid needs checking.",
        .tempoChampAide: "Click the number to type it: the estimate is usually off by a factor of two, which one digit fixes.",
        .tempoBPM: "BPM",
        .tempoPasAide: "Adjust by 0.1 BPM — enough to catch a grid that drifts over the length.",
        .tempoSignatureAide: "Beats per bar. Changes the spacing of the bar lines, and the downbeat marker.",
        .tempoUnIci: "1 here",
        .tempoUnIciAide: "Put the first beat of the bar at the playhead (1)",
        .tempoRelancerAide: "Run the estimate again, with the chosen time signature.",
        .tempoIndetermine: "tempo unknown",
        .tempoChercherAide: "Look for a grid in this track. Without one, no bar lines and no chord detection.",
        .tempoIndetermineWin: "Tempo unknown",
        .tempoChercher: "Find",
        .tempoMoinsAide: "Take away 0.1 BPM — enough to catch a grid that drifts over the length.",
        .tempoPlusAide: "Add 0.1 BPM — enough to catch a grid that drifts over the length.",
        .tempoSignatureAideWin: "Beats per bar: the spacing of the bar lines, and the downbeat marker. Clicking cycles from 2/4 to 7/4.",
        .tempoUnIciAideWin: "Put the first beat of the bar at the playhead (1).",
        .tempoRefaire: "Redo",
        .tempoRelancerAideWin: "Run the estimate again, with the chosen time signature.",

        // MARK: La lecture
        .lectureLire: "Play",
        .lecturePause: "Pause",
        .lectureLireAide: """
            Play or pause (space).
            Clicking in the image moves the playhead, and sounds the line under the pointer.
            """,
        .lectureLireAideWin: "Play or pause (space). The ← and → arrows move by one second, five with ⇧.",
        .lectureNeutre: "Neutral",
        .lectureNeutreAide: "Bring the speed back to 100 % and the transposition to +0. Slowdown and transposition are reset together: they were pushed together to work out a passage, and one wants to hear the track as it is, not half of it.",
        .lectureVitesse: "Speed",
        .lectureVitesseAide: """
            Slows down or speeds up without touching the pitch.
            A detent returns exactly to 100 %, where the processing is taken out of the signal path.
            Double-click the text to go back there.
            """,
        .lectureVitesseAideWin: "Slows down or speeds up without touching the pitch. At 100 % the processing is taken out of the signal path.",
        .lectureTransposition: "Transpose",
        .lectureTranspositionAide: """
            Transposes without touching the speed, in semitones.
            Fractional values bring a detuned recording back into tune.
            Double-click the text to return to +0.
            """,
        .lectureTranspositionAideWin: "Transposes without touching the speed, in semitones. Fractional values bring a detuned recording back into tune.",
        .lectureVolume: "Volume",
        .lectureVolumeAide: "The app's output level. The Mac leaves this to the system mixer; here, it is the only place to set it without leaving the window.",
        .lectureRevenirAuDebut: "Back to the start",
        .uniteDemiTons: "st",
        .uniteDemiTonsLong: "semitones",
        .uniteOctaves: "oct",
        .uniteMesures: "bars",

        // MARK: L'image
        .imageContraste: "Contrast",
        .imageContrasteAide: """
            The level rendered black. Raising it cleans up the floor,
            and takes that noise out of the pointer's magnet at the same time.
            """,
        .imageContrasteAideWin: "The level rendered black: the boundary between what is played and what is not. Raising it cleans up the floor, and takes that noise out of the pointer's magnet at the same time; lowering it lets faint lines into the chord detection.",
        .imageAutoGlobal: "Auto global",
        .imageAutoGlobalAide: "Return to the contrast measured over the whole track when it was opened — the mark one started from. K",
        .imageAutoLocal: "Auto local",
        .imageAutoLocalAide: "Set black, white and tilt from what is on screen. ⇧K",
        .imageZoomVertical: "Vertical zoom",
        .imageZoomVerticalAide: """
            Stretches the frequency axis; the value gives the number of visible octaves.
            On the trackpad: ⇧ + pinch, or ⇧ + wheel — anchored under the pointer.
            Playback is filtered to the visible band.
            """,
        .imageZoomVerticalAideWin: "Stretches the frequency axis; the value gives the number of visible octaves. With the mouse: ⇧ and the wheel, anchored under the pointer. Playback is filtered to the visible band.",

        // MARK: L'affichage
        .affichageBatterie: "Drums",
        .affichageBatterieAide: """
            Drum detection, below the image: one stroke per hit, one lane per voice.
            The spectrogram tells pitch, which percussion has none of; these three lanes tell when, what and how hard.
            They are worth most on the isolated drum stem.
            """,
        .affichageAccords: "Chords",
        .affichageAccordsAide: """
            Chord names, at the foot of the grid: one per beat, per bar or per phrase depending on the zoom.
            Worked out from the separated bass and accompaniment — so all four stems must be computed, and a beat grid must exist.
            Hovering them sounds them and circles their notes in the spectrum; a pale name means the reading is uncertain.
            """,
        .affichageTouchesNoires: "Black key names",
        .affichageTouchesNoiresAide: "How the black keys are spelled: E♭ or D♯.",
        .affichageBemols: "Flats",
        .affichageDieses: "Sharps",

        // MARK: La boucle
        .boucleJouer: "Loop playback",
        .boucleJouerAide: """
            Play the passage on a loop, with no gap at the turnaround (L).
            [ and ] put the start and the end at the playhead.
            """,
        .boucleJouerAideWin: "Play the passage on a loop, with no gap at the turnaround (L).",
        .boucleAuxMesures: "To bars",
        .boucleAuxMesuresAide: "Extend the loop to the bars around it (B)",
        .boucleMesures: "Bars",
        .boucleEffacer: "Clear",
        .boucleEffacerAide: "Clear the loop (esc)",
        .boucleAucunPassage: "No passage drawn",
        .boucleDuAu: "From %1$@ to %2$@",
        .boucleDebutIci: "Start here",
        .boucleFinIci: "End here",
        .boucleCalerSurMesures: "Snap to bars",
        .boucleBoucler: "Loop",
        .boucleEffacerLaBoucle: "Clear the loop",

        // MARK: Les pistes, dans le panneau
        .pistesEffacerLesPistes: "Clear the stems",
        .pistesEffacerAide: "Go back to the mix. The stems recompute in half a minute if you come back to them.",
        .pistesSeparationEnCours: "separating",
        .pistesGardees: "Kept",
        .pistesToutGarder: "Keep all",
        .pistesToutGarderAide: "Hear the whole mix again, all four stems checked.",
        .pistesRefaire: "Redo",
        .pistesRefaireAide: "Forget the computed stems. They come back the next time a single stem is played — the fallback when separation went wrong on a track.",
        .pistesCache: "Stem cache",
        .pistesPlafond: "Limit",
        .pistesPlafondAide: "A seven-minute track costs about 300 MB. Past the limit, the least recently opened tracks go whole — never the one being played — and get recomputed.",
        .pistesViderLeCache: "Empty the cache",
        .pistesViderLeCacheAide: "Throw away every stored stem. Each track will have to be separated again, about half a minute per track.",
        .pistesPoidsAbsents: "The Demucs weights are not installed — see `modele.sh`. Without them, the track plays as it is.",
        .pistesPoidsAbsentsWin: "The Demucs weights are not installed — see `modele.sh`. Without them, the track plays as it is.",
        .pistesOnnxAbsent: "ONNX Runtime is not installed: run .\\onnx.ps1, then restart the app.",

        // MARK: Les menus du Mac
        .menuOuvrir: "Open…",
        .menuOuvrirRecemment: "Open Recent",
        .menuViderLeMenu: "Clear Menu",
        .menuLecture: "Playback",
        .menuBoucle: "Loop",
        .menuAffichage: "View",
        .menuTempo: "Tempo",
        .menuPanneauDeReglages: "Settings Panel",
        .menuContrasteOuverture: "Opening Contrast",
        .menuContrasteAutomatique: "Auto Contrast on What Is on Screen",
        .menuPoserLePremierTemps: "Put the Downbeat Here",
        .menuRecalculerLaGrille: "Recompute the Grid",

        // MARK: L'accueil
        .accueilDeposer: "Drop an audio file",
        .accueilRaccourci: "or ⌘O",
        .accueilAnalyse: "Analysing…",

        // MARK: La fenêtre des réglages
        .reglagesPistesSeparees: "Separated stems",
        .reglagesTailleMaximale: "Maximum cache size",
        .reglagesOccupe: "Used",
        .reglagesViderPoints: "Empty…",
        .reglagesViderBouton: "Empty",
        .reglagesAnnuler: "Cancel",
        .reglagesCacheExplication: "A seven-minute track costs about 250 MB. Past the limit, the least recently opened tracks go whole — never the one being played — and recompute in half a minute.",
        .reglagesViderTitre: "Empty the separated stem cache?",
        .reglagesViderMessage: "Each track will have to be separated again, about half a minute per track.",
        .reglagesCouleurDesNotes: "Note colours",
        .reglagesPremiereTeinte: "First hue",
        .reglagesCouleursExplication: "The twelve hues follow the circle of fifths: two notes close harmonically are close in colour, a tritone puts them opposite. Changing the first one only rotates the series — those relations do not move.",
        .reglagesLangue: "Language",
        .reglagesLangueInterface: "Interface language",
        .reglagesLangueSysteme: "System",
        .reglagesNomDesNotes: "Note names",
        .reglagesNotesSelonLaLangue: "Follows the language",
        .reglagesLangueExplication: "Note names follow the language, and are set separately: one may want the interface in English and the chords in Do Re Mi. In German and Polish, B is the B flat and H the B natural.",
        .reglagesAuto: "Auto",
        .reglagesLangueImposee: "The SPECTRE_LANGUE environment variable is forcing the language: this setting has no effect while it is set.",

        // MARK: Windows
        .winMenuOuvrir: "Open a file…\tCtrl+O",
        .winMenuOuvrirRecemment: "Open Recent",
        .winMenuViderLaListe: "Clear the list",
        .winMenuMasquerReglages: "Hide the settings\tR",
        .winMenuReglages: "Settings…\tR",
        .winMenuQuitter: "Quit\tAlt+F4",
        .winBarreAide: "R settings · space play · ⇧drag loop · Ctrl wheel zoom · right click menu",
        .winBarreBoucle: "loop",
        .winBarreBoucleHorsService: "loop (off)",
        .winFriseOuvrir: "Open a file: Ctrl + O",

        // MARK: The notice shown once, at first launch
        .avisRapportsTitre: "Spectre reports its own failures",
        .avisRapportsCorps: "When something breaks, Spectre sends the report on its own, without asking. That is what gets it fixed: nobody takes the trouble to describe a failure, and a failure nobody hears about stays.",
        .avisRapportsSecret: "Never part of it: your file names, your folders, or what you listen to. Nothing else is measured — not what you do with the app, not how long you keep it open.",
        .avisRapportsCompris: "Got it",

        // MARK: La ligne de commande
        .cliFichierIntrouvable: "File not found: %1$@",
        .cliLectureImpossible: "Cannot read: %1$@",
        .cliMatriceVide: "Empty matrix",
        .cliAucuneGrille: "No beat grid found",
        .cliMixage: "mix",
        .cliPistesSansBatterie: "stems without drums",
        .cliBasseEtAccompagnement: "bass and accompaniment",
        .cliCarteDeBasse: " · bass map",
        .cliEnTete: "%1$@ — %2$@ s, %3$@%4$@, %5$@ BPM, %6$@/4",
        .cliVocabulaire: "%1$@ — %2$@ chords",
        .cliReglages: "contrast %1$@…%2$@ dB, tilt %3$@ dB/octave; clarity %4$@, hold %5$@ %",
        .cliTemps: "map %1$@ s, reading %2$@ s, analysis included %3$@ s",
        .cliAucunIntervalle: "(no interval in the requested window)",
        .cliIntervalles: "%1$@ intervals, %2$@ named (%3$@ %), %4$@ changes",
        .cliRaiesTenues: "%1$@ held lines per interval, %2$@ % unexplained, %3$@ % of intervals carry one",
        .cliNomsSurs: "%1$@ % of the names are certain (margin ≥ 0.5 line)",
        .cliInexpliquees: "unexplained: ",
        .cliFondamentale: "root",
        .cliModeleAbsent: "Model missing: run ./modele.sh then ./build.sh",
        .cliSuffixePistes: " — stems",
        .cliCrete: "peak",
        .cliSeparationFaite: "Done in %1$@ s for %2$@ s of music (×%3$@ real time).",
        .cliEchec: "Failed: %1$@",
    ]
}
