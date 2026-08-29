import Foundation

// Le français est la langue de référence : chaque texte est écrit ici d'abord, et
// c'est ici qu'on retombe quand une clé manque ailleurs. Une entrée qui disparaît
// de cette table fait échouer `LangueCheck` pour les cinq langues d'un coup — c'est
// voulu, elle est la seule dont la complétude est garantie.

extension Catalogue {
    public static let francais: [Cle: String] = [

        // MARK: Les pistes
        .pisteMixage: "Mixage",
        .pisteBatterie: "Batterie",
        .pisteBasse: "Basse",
        .pisteVoix: "Voix",
        .pisteReste: "Reste",
        .pisteMixageAide: "Le morceau tel qu'il est.",
        .pisteBatterieAide: """
            Batterie et percussions.
            Une fois les pistes séparées, elle ne se voit plus dans le spectrogramme : elle nourrit les trois lignes du bas, qui disent d'elle ce qu'un spectre ne sait pas dire.
            Décochée, on ne l'entend plus et ces lignes restent vides.
            """,
        .pisteBasseAide: "La basse seule — la piste la mieux isolée, et la plus difficile à relever à l'oreille dans un mixage dense.",
        .pisteVoixAide: "Le chant seul.",
        .pisteResteAide: "Tout le reste : claviers, guitares, cuivres, cordes.",
        .pisteSilence: "silence",
        .pisteSans: "sans %1$@",
        .pisteNi: " ni ",
        .pistePlus: " + ",
        .pisteDecocherAide: "\nDécocher retire cette piste ; ce qui reste est joué ensemble.",

        // MARK: Les voies de la batterie
        .voieGrosseCaisse: "Grosse caisse",
        .voieCaisseClaire: "Caisse claire",
        .voieCymbales: "Cymbales",
        .voieGrosseCaisseCourt: "GC",
        .voieCaisseClaireCourt: "CC",
        .voieCymbalesCourt: "CY",

        // MARK: Les palettes
        .paletteGris: "Niveaux de gris",
        .paletteNotes: "Notes (cycle des quintes)",

        // MARK: Le relevé d'accords
        .porteeParTemps: "Un accord par temps",
        .porteeParMesure: "Un accord par mesure",
        .vocabulaireTriades: "Triades seules",
        .vocabulaireSeptiemes: "Triades et septièmes",
        .vocabulaireTout: "Sixtes et diminués compris",
        .vocabulaireEnrichis: "Avec les enrichissements — 9, 11, 13",

        // MARK: Les couleurs d'accord
        .couleurMajeur: "majeur",
        .couleurMineur: "mineur",
        .couleurSuspendu4: "suspendu 4",
        .couleurSeptieme: "septième",
        .couleurMineurSeptieme: "mineur septième",
        .couleurSeptiemeMajeure: "septième majeure",
        .couleurDemiDiminue: "demi-diminué",
        .couleurDiminue: "diminué",
        .couleurAugmente: "augmenté",
        .couleurSixte: "sixte",
        .couleurMineurSixte: "mineur sixte",
        .couleurNeuviemeAjoutee: "neuvième ajoutée",
        .couleurMineurNeuviemeAjoutee: "mineur neuvième ajoutée",
        .couleurNeuvieme: "neuvième",
        .couleurMineurNeuvieme: "mineur neuvième",
        .couleurSeptiemeMajeureNeuvieme: "septième majeure neuvième",
        .couleurOnzieme: "onzième",
        .couleurMineurOnzieme: "mineur onzième",
        .couleurTreizieme: "treizième",

        // MARK: Ce qui peut échouer
        .erreurModeleAbsent: "Le modèle de séparation n'est pas installé.",
        .erreurModeleIllisible: "Modèle illisible : %1$@",
        .erreurAucunMorceau: "Aucun morceau ouvert.",
        .erreurEcritureImpossible: "Impossible d'écrire « %1$@ ».",
        .erreurInterrompue: "Séparation interrompue.",
        .erreurSeparationEchouee: "La séparation a échoué : %1$@",
        .erreurEnvironnementOnnx: "environnement ONNX indisponible — %1$@",
        .erreurCoreMLIndisponible: "CoreML indisponible",
        .erreurFormatIllisible: "format illisible",
        .erreurFormatEntree: "format d'entrée inutilisable",
        .erreurTampons: "tampons indisponibles",
        .erreurAucunEchantillon: "aucun échantillon lu",
        .erreurReseauRienRendu: "le réseau n'a rien rendu",
        .erreurOnnxAbsent: "ONNX Runtime n'est pas installé — lancer .\\onnx.ps1.",
        .erreurQuatrePistes: "le réseau n'a pas rendu les quatre pistes",
        .erreurLectureImpossible: "Lecture impossible : %1$@",
        .erreurMoteurAudio: "Moteur audio indisponible : %1$@",
        .erreurFichierIllisible: "« %1$@ » n'a pas pu être lu.",
        .dialogueOuvrir: "Ouvrir",
        .dialogueChoisirUnMorceau: "Choisir un fichier audio à transcrire",

        // MARK: Les étapes de la séparation
        .etapeLectureDuMorceau: "Lecture du morceau…",
        .etapeOuvertureDuReseau: "Ouverture du réseau…",
        .etapeCompilationDuReseau: "Compilation du réseau pour cette machine — une seule fois…",

        // MARK: Ce que l'application dit d'elle-même
        .statutLectureDuFichier: "Lecture du fichier…",
        .statutAnalyseFaite: "%1$@ — %2$@, analysé en %3$@ s (×%4$@ temps réel)%5$@",
        .statutReglagesRetrouves: " · réglages retrouvés",
        .statutModeleAbsentApplication: "Modèle absent de l'application : lancer ./modele.sh puis ./build.sh.",
        .statutPreparation: "Préparation du morceau…",
        .statutPistesNonEnregistrees: "Pistes non enregistrées : %1$@",
        .statutLectureDesPistes: "Lecture des pistes déjà séparées…",
        .statutSeparationPourcent: "Séparation des pistes : %1$@ %",
        .statutSeparationRestant: "Séparation des pistes : %1$@ % — encore %2$@",
        .statutSeparationEnCours: "Séparation des pistes…",
        .statutPistesIllisibles: "Pistes illisibles ; le mixage est resté.",
        .statutAnalyseDe: "Analyse de « %1$@ »…",
        .statutReleveBatterie: "Relevé de la batterie…",
        .statutGrilleReprise: "Grille reprise sur la batterie",
        .statutBatterieRetiree: "Batterie retirée",
        .statutAucunCoup: "Aucun coup relevé",
        .statutReleveAccords: "Relevé des accords…",
        .statutAccordsGrilleDabord: "Accords : chercher la grille d'abord",
        .statutAccordsRienDeTenu: "Accords : rien de tenu à l'écran — éclaircir l'image",
        .statutPistesEffacees: "Pistes effacées.",
        .dureeSecondes: "%1$@ s",
        .dureeMinutes: "%1$@ min",
        .dureeMinutesSecondes: "%1$@ min %2$@ s",

        // MARK: Le panneau : ses groupes
        .groupeTempo: "Détection du tempo",
        .groupeTempoAide: "Estimée à l'ouverture d'après les attaques. Elle commande les barres de mesure, l'aimantation et le relevé des accords.",
        .groupeLecture: "Lecture",
        .groupeLectureAide: "Ce qui se joue, et comment. Cliquer dans l'image déplace la tête de lecture et fait sonner la raie désignée.",
        .groupeImage: "Image",
        .groupeImageAide: "Ce que le spectrogramme montre : jusqu'où descendre dans le fond, et sur combien d'octaves l'étaler.",
        .groupeAffichage: "Affichage",
        .groupeAffichageAide: "Ce qui se pose autour de l'image : la ligne de batterie, les noms d'accords, l'écriture des touches noires.",
        .groupeBoucle: "Boucle",
        .groupeBoucleAide: "Tracer une boucle : glisser dans la réglette du haut, ou ⇧ + glisser dans l'image. Glisser la zone jaune la déplace, ses bords l'étendent ; les bornes se posent sur la grille, et ⌘ pendant le geste les libère.",
        .groupePistes: "Pistes",
        .groupePistesAide: "Les quatre pistes séparées, celles que la colonne de droite fait entendre. Choisir une piste ne change pas seulement ce qu'on entend, mais ce qu'on voit : le spectrogramme d'une piste isolée a bien moins de partielles qui se croisent, si bien que l'aimantation tombe enfin sur la bonne raie.",

        // MARK: Le panneau lui-même
        .panneauReglages: "Réglages",
        .panneauOuvrirAide: "Lecture, boucle, tempo, affichage — ⌘⌥R",
        .panneauOuvrirAideWin: "Lecture, boucle, tempo, affichage — R.",
        .panneauReplierAide: "Replier le panneau — ⌘⌥R",

        // MARK: Le tempo
        .tempoEstimationFloue: "L'estimation n'est pas franche sur ce morceau : la grille est à vérifier.",
        .tempoChampAide: "Cliquer sur le chiffre pour le saisir : l'estimation se trompe surtout d'un facteur deux, qu'on corrige d'un chiffre.",
        .tempoBPM: "BPM",
        .tempoPasAide: "Ajuster de 0,1 BPM — de quoi rattraper une grille qui dérive sur la longueur.",
        .tempoSignatureAide: "Temps par mesure. Change l'espacement des barres, et le repère du premier temps.",
        .tempoUnIci: "1 ici",
        .tempoUnIciAide: "Poser le premier temps de la mesure à la tête de lecture (1)",
        .tempoRelancerAide: "Relancer l'estimation, avec la signature choisie.",
        .tempoIndetermine: "tempo indéterminé",
        .tempoChercherAide: "Chercher une grille dans ce morceau. Sans elle, ni barres de mesure ni relevé d'accords.",
        .tempoIndetermineWin: "Tempo indéterminé",
        .tempoChercher: "Chercher",
        .tempoMoinsAide: "Retirer 0,1 BPM — de quoi rattraper une grille qui dérive sur la longueur.",
        .tempoPlusAide: "Ajouter 0,1 BPM — de quoi rattraper une grille qui dérive sur la longueur.",
        .tempoSignatureAideWin: "Temps par mesure : l'espacement des barres, et le repère du premier temps. Cliquer fait défiler 2/4 à 7/4.",
        .tempoUnIciAideWin: "Poser le premier temps de la mesure à la tête de lecture (1).",
        .tempoRefaire: "Refaire",
        .tempoRelancerAideWin: "Relancer l'estimation, avec la signature choisie.",

        // MARK: La lecture
        .lectureLire: "Lire",
        .lecturePause: "Pause",
        .lectureLireAide: """
            Lire ou mettre en pause (espace).
            Cliquer dans l'image déplace la tête de lecture, et fait sonner la raie désignée.
            """,
        .lectureLireAideWin: "Lire ou mettre en pause (espace). Les flèches ← et → avancent d'une seconde, de cinq avec ⇧.",
        .lectureNeutre: "Neutre",
        .lectureNeutreAide: "Ramener la vitesse à 100 % et la transposition à +0. Le ralenti et la transposition se remettent d'aplomb ensemble : on les a poussés ensemble pour déchiffrer un passage, et l'on veut réentendre le morceau tel qu'il est, pas à moitié.",
        .lectureVitesse: "Vitesse",
        .lectureVitesseAide: """
            Ralentit ou accélère sans toucher à la hauteur.
            Un cran ramène exactement à 100 %, où le traitement est retiré du chemin du son.
            Double-clic sur le texte pour y revenir.
            """,
        .lectureVitesseAideWin: "Ralentit ou accélère sans toucher à la hauteur. À 100 % le traitement est retiré du chemin du son.",
        .lectureTransposition: "Transposition",
        .lectureTranspositionAide: """
            Transpose sans toucher à la vitesse, en demi-tons.
            Les valeurs intermédiaires recalent un enregistrement désaccordé.
            Double-clic sur le texte pour revenir à +0.
            """,
        .lectureTranspositionAideWin: "Transpose sans toucher à la vitesse, en demi-tons. Les valeurs intermédiaires recalent un enregistrement désaccordé.",
        .lectureVolume: "Volume",
        .lectureVolumeAide: "Le niveau de sortie de l'application. Le Mac s'en remet au mélangeur du système ; ici, c'est le seul endroit où le régler sans quitter la fenêtre.",
        .lectureRevenirAuDebut: "Revenir au début",
        .uniteDemiTons: "dt",
        .uniteDemiTonsLong: "demi-tons",
        .uniteOctaves: "oct",
        .uniteMesures: "mesures",

        // MARK: L'image
        .imageContraste: "Contraste",
        .imageContrasteAide: """
            Niveau rendu noir. Le monter nettoie le fond,
            et retire du même coup ce bruit de l'aimant du curseur.
            """,
        .imageContrasteAideWin: "Le niveau rendu noir : la frontière entre ce qui est joué et ce qui ne l'est pas. Le monter nettoie le fond, et retire du même coup ce bruit de l'aimant du curseur ; l'éclaircir fait entrer des raies pâles dans le relevé d'accords.",
        .imageAutoGlobal: "Auto global",
        .imageAutoGlobalAide: "Revenir au contraste mesuré sur le morceau entier à son ouverture — le repère d'où l'on est parti. K",
        .imageAutoLocal: "Auto local",
        .imageAutoLocalAide: "Régler noir, clair et pente d'après ce qui est à l'écran. ⇧K",
        .imageZoomVertical: "Zoom vertical",
        .imageZoomVerticalAide: """
            Étale l'axe des fréquences ; la valeur donne le nombre d'octaves visibles.
            Au trackpad : ⇧ + pincement, ou ⇧ + molette — ancré sous le curseur.
            La lecture est filtrée sur la bande visible.
            """,
        .imageZoomVerticalAideWin: "Étale l'axe des fréquences ; la valeur donne le nombre d'octaves visibles. À la souris : ⇧ et la molette, ancré sous le curseur. La lecture est filtrée sur la bande visible.",

        // MARK: L'affichage
        .affichageBatterie: "Batterie",
        .affichageBatterieAide: """
            Relevé de la batterie, sous l'image : un trait par coup, une ligne par voie.
            Le spectrogramme dit la hauteur, qu'une percussion n'a pas ; ces trois lignes disent quand, quoi et combien fort.
            Elles valent surtout sur la piste de batterie isolée.
            """,
        .affichageAccords: "Accords",
        .affichageAccordsAide: """
            Noms d'accords, au pied de la grille : un par temps, par mesure ou par phrase selon le zoom.
            Devinés sur la basse et l'accompagnement séparés — il faut donc que les quatre pistes soient calculées, et qu'une grille métrique existe.
            Les survoler les fait entendre et entoure leurs notes dans le spectre ; la pâleur d'un nom dit l'incertitude du relevé.
            """,
        .affichageTouchesNoires: "Noms des touches noires",
        .affichageTouchesNoiresAide: "L'écriture des touches noires : Mi♭ ou Ré♯.",
        .affichageBemols: "Bémols",
        .affichageDieses: "Dièses",

        // MARK: La boucle
        .boucleJouer: "Jouer en boucle",
        .boucleJouerAide: """
            Jouer le passage en boucle, sans trou à la reprise (L).
            [ et ] posent le début et la fin à la tête de lecture.
            """,
        .boucleJouerAideWin: "Jouer le passage en boucle, sans trou à la reprise (L).",
        .boucleAuxMesures: "Aux mesures",
        .boucleAuxMesuresAide: "Étendre la boucle aux mesures qui l'encadrent (B)",
        .boucleMesures: "Mesures",
        .boucleEffacer: "Effacer",
        .boucleEffacerAide: "Effacer la boucle (échap)",
        .boucleAucunPassage: "Aucun passage tracé",
        .boucleDuAu: "Du %1$@ au %2$@",
        .boucleDebutIci: "Début ici",
        .boucleFinIci: "Fin ici",
        .boucleCalerSurMesures: "Caler sur les mesures",
        .boucleBoucler: "Boucler",
        .boucleEffacerLaBoucle: "Effacer la boucle",

        // MARK: Les pistes, dans le panneau
        .pistesEffacerLesPistes: "Effacer les pistes",
        .pistesEffacerAide: "Repartir du mixage. Les pistes se recalculent en une demi-minute si vous y revenez.",
        .pistesSeparationEnCours: "séparation en cours",
        .pistesGardees: "Gardées",
        .pistesToutGarder: "Tout garder",
        .pistesToutGarderAide: "Réentendre le mixage entier, les quatre pistes cochées.",
        .pistesRefaire: "Refaire",
        .pistesRefaireAide: "Oublier les pistes calculées. Elles se refont à la prochaine écoute d'une piste seule — le recours quand la séparation a mal tourné sur un morceau.",
        .pistesCache: "Cache des pistes",
        .pistesPlafond: "Plafond",
        .pistesPlafondAide: "Un morceau de sept minutes coûte environ 300 Mo. Au-delà du plafond, les morceaux les moins récemment ouverts s'en vont entiers — jamais celui qu'on écoute — et se recalculent.",
        .pistesViderLeCache: "Vider le cache",
        .pistesViderLeCacheAide: "Jeter toutes les pistes rangées. Chaque morceau devra être séparé de nouveau, soit environ une demi-minute par morceau.",
        .pistesPoidsAbsents: "Les poids de Demucs ne sont pas installés — voir `modele.sh`. Sans eux, le morceau se lit tel qu'il est.",
        .pistesPoidsAbsentsWin: "Les poids de Demucs ne sont pas installés — voir `modele.sh`. Sans eux, le morceau se lit tel qu'il est.",
        .pistesOnnxAbsent: "ONNX Runtime n'est pas installé : lancer .\\onnx.ps1, puis relancer l'application.",

        // MARK: Les menus du Mac
        .menuOuvrir: "Ouvrir…",
        .menuOuvrirRecemment: "Ouvrir récemment",
        .menuViderLeMenu: "Vider le menu",
        .menuLecture: "Lecture",
        .menuBoucle: "Boucle",
        .menuAffichage: "Affichage",
        .menuTempo: "Tempo",
        .menuPanneauDeReglages: "Panneau de réglages",
        .menuContrasteOuverture: "Contraste de l'ouverture",
        .menuContrasteAutomatique: "Contraste automatique sur ce qui est à l'écran",
        .menuPoserLePremierTemps: "Poser le premier temps ici",
        .menuRecalculerLaGrille: "Recalculer la grille",

        // MARK: L'accueil
        .accueilDeposer: "Déposer un fichier audio",
        .accueilRaccourci: "ou ⌘O",
        .accueilAnalyse: "Analyse…",

        // MARK: La fenêtre des réglages
        .reglagesPistesSeparees: "Pistes séparées",
        .reglagesTailleMaximale: "Taille maximale du cache",
        .reglagesOccupe: "Occupé",
        .reglagesViderPoints: "Vider…",
        .reglagesViderBouton: "Vider",
        .reglagesAnnuler: "Annuler",
        .reglagesCacheExplication: "Un morceau de sept minutes coûte environ 250 Mo. Au-delà du plafond, les morceaux les moins récemment ouverts s'en vont entiers — jamais celui qu'on écoute — et se recalculent en une demi-minute.",
        .reglagesViderTitre: "Vider le cache des pistes séparées ?",
        .reglagesViderMessage: "Chaque morceau devra être séparé de nouveau, soit environ une demi-minute par morceau.",
        .reglagesCouleurDesNotes: "Couleur des notes",
        .reglagesPremiereTeinte: "Première teinte",
        .reglagesCouleursExplication: "Les douze teintes sont réparties selon le cycle des quintes : deux notes proches harmoniquement sont proches en couleur, un triton les met en opposition. Changer la première ne fait que tourner la série — ces rapports-là ne bougent pas.",
        .reglagesLangue: "Langue",
        .reglagesLangueInterface: "Langue de l'interface",
        .reglagesLangueSysteme: "Système",
        .reglagesNomDesNotes: "Nom des notes",
        .reglagesNotesSelonLaLangue: "Suit la langue",
        .reglagesLangueExplication: "Le nom des notes suit la langue, et se règle à part : on peut vouloir l'interface en français et les accords en Am. En allemand et en polonais, B est le si bémol et H le si naturel.",
        .reglagesAuto: "Auto",
        .reglagesLangueImposee: "La variable d'environnement SPECTRE_LANGUE impose la langue : ce réglage est sans effet tant qu'elle est posée.",

        // MARK: Windows
        .winMenuOuvrir: "Ouvrir un fichier…\tCtrl+O",
        .winMenuOuvrirRecemment: "Ouvrir récemment",
        .winMenuViderLaListe: "Vider la liste",
        .winMenuMasquerReglages: "Masquer les réglages\tR",
        .winMenuReglages: "Réglages…\tR",
        .winMenuQuitter: "Quitter\tAlt+F4",
        .winBarreAide: "R réglages · espace lire · ⇧glisser boucler · Ctrl molette zoomer · clic droit menu",
        .winBarreBoucle: "boucle",
        .winBarreBoucleHorsService: "boucle (hors service)",
        .winFriseOuvrir: "Ouvrir un fichier : Ctrl + O",

        // MARK: L'avis du premier lancement
        .avisRapportsTitre: "Spectre signale ses pannes toute seule",
        .avisRapportsCorps: "Quand quelque chose casse, Spectre en envoie le rapport sans rien vous demander. C'est ce qui permet de le corriger : personne ne prend la peine de raconter une panne, et une panne qu'on n'apprend pas reste là.",
        .avisRapportsSecret: "N'en font jamais partie : le nom de vos fichiers, vos dossiers, ni ce que vous écoutez. Rien d'autre n'est mesuré — ni ce que vous faites de l'application, ni combien de temps vous l'ouvrez.",
        .avisRapportsCompris: "J'ai compris",

        // MARK: La ligne de commande
        .cliFichierIntrouvable: "Fichier introuvable : %1$@",
        .cliLectureImpossible: "Lecture impossible : %1$@",
        .cliMatriceVide: "Matrice vide",
        .cliAucuneGrille: "Aucune grille métrique trouvée",
        .cliMixage: "mixage",
        .cliPistesSansBatterie: "pistes sans batterie",
        .cliBasseEtAccompagnement: "basse et accompagnement",
        .cliCarteDeBasse: " · carte de basse",
        .cliEnTete: "%1$@ — %2$@ s, %3$@%4$@, %5$@ BPM, %6$@/4",
        .cliVocabulaire: "%1$@ — %2$@ accords",
        .cliReglages: "contraste %1$@…%2$@ dB, pente %3$@ dB/octave ; clarté %4$@, tenue %5$@ %",
        .cliTemps: "carte %1$@ s, relevé %2$@ s, analyse comprise %3$@ s",
        .cliAucunIntervalle: "(aucun intervalle dans la fenêtre demandée)",
        .cliIntervalles: "%1$@ intervalles, %2$@ nommés (%3$@ %), %4$@ changements",
        .cliRaiesTenues: "%1$@ raies tenues par intervalle, %2$@ % inexpliquées, %3$@ % des intervalles en portent une",
        .cliNomsSurs: "%1$@ % des noms sont sûrs (marge ≥ 0,5 raie)",
        .cliInexpliquees: "inexpliquées : ",
        .cliFondamentale: "fond.",
        .cliModeleAbsent: "Modèle absent : lancer ./modele.sh puis ./build.sh",
        .cliSuffixePistes: " — pistes",
        .cliCrete: "crête",
        .cliSeparationFaite: "Fait en %1$@ s pour %2$@ s de musique (×%3$@ temps réel).",
        .cliEchec: "Échec : %1$@",
    ]
}

/// Les cinq tables. Une énumération vide qui ne sert qu'à les porter : elles sont
/// assez longues pour mériter un fichier chacune, et assez liées pour vouloir un
/// seul nom.
public enum Catalogue {}
