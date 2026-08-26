import Foundation

// L'allemand. Deux choses à savoir avant d'y toucher.
//
// **Les notes.** `B` désigne le si bémol et `H` le si naturel — c'est dans
// `SystemeDeNotes.germanique`, pas ici, mais c'est ce qui surprend en premier.
//
// **La longueur.** L'allemand fait couramment un tiers de plus que le français, et
// les textes courts d'ici sont écrits pour la place qu'ils ont : « Schlagzeug » tient
// tout juste dans les soixante-deux points de la colonne des pistes, et les
// abréviations de la ligne de batterie n'ont droit qu'à deux lettres.

extension Catalogue {
    public static let allemand: [Cle: String] = [

        // MARK: Les pistes
        .pisteMixage: "Mix",
        .pisteBatterie: "Drums",
        .pisteBasse: "Bass",
        .pisteVoix: "Gesang",
        .pisteReste: "Rest",
        .pisteMixageAide: "Das Stück, wie es ist.",
        .pisteBatterieAide: """
            Schlagzeug und Perkussion.
            Sind die Spuren einmal getrennt, erscheint es nicht mehr im Spektrogramm: es speist die drei Linien darunter, die von ihm sagen, was ein Spektrum nicht sagen kann.
            Abgewählt hört man es nicht mehr, und diese Linien bleiben leer.
            """,
        .pisteBasseAide: "Der Bass allein — die am besten getrennte Spur, und die in einem dichten Mix am schwersten herauszuhörende.",
        .pisteVoixAide: "Nur der Gesang.",
        .pisteResteAide: "Alles Übrige: Tasten, Gitarren, Bläser, Streicher.",
        .pisteSilence: "Stille",
        .pisteSans: "ohne %1$@",
        .pisteNi: " und ",
        .pistePlus: " + ",
        .pisteDecocherAide: "\nAbwählen nimmt diese Spur heraus; was bleibt, erklingt zusammen.",

        // MARK: Les voies de la batterie
        .voieGrosseCaisse: "Bassdrum",
        .voieCaisseClaire: "Snare",
        .voieCymbales: "Becken",
        .voieGrosseCaisseCourt: "BD",
        .voieCaisseClaireCourt: "SN",
        .voieCymbalesCourt: "BE",

        // MARK: Les palettes
        .paletteGris: "Graustufen",
        .paletteNotes: "Töne (Quintenzirkel)",

        // MARK: Le relevé d'accords
        .porteeParTemps: "Ein Akkord pro Zählzeit",
        .porteeParMesure: "Ein Akkord pro Takt",
        .vocabulaireTriades: "Nur Dreiklänge",
        .vocabulaireSeptiemes: "Dreiklänge und Septakkorde",
        .vocabulaireTout: "Mit Sexten und verminderten",
        .vocabulaireEnrichis: "Mit Optionstönen — 9, 11, 13",

        // MARK: Les couleurs d'accord
        .couleurMajeur: "Dur",
        .couleurMineur: "Moll",
        .couleurSuspendu4: "Quartvorhalt",
        .couleurSeptieme: "Septakkord",
        .couleurMineurSeptieme: "Moll-Septakkord",
        .couleurSeptiemeMajeure: "große Septime",
        .couleurDemiDiminue: "halbvermindert",
        .couleurDiminue: "vermindert",
        .couleurAugmente: "übermäßig",
        .couleurSixte: "Sexte",
        .couleurMineurSixte: "Moll-Sexte",
        .couleurNeuviemeAjoutee: "mit hinzugefügter None",
        .couleurMineurNeuviemeAjoutee: "Moll mit hinzugefügter None",
        .couleurNeuvieme: "None",
        .couleurMineurNeuvieme: "Moll-None",
        .couleurSeptiemeMajeureNeuvieme: "große None",
        .couleurOnzieme: "Undezime",
        .couleurMineurOnzieme: "Moll-Undezime",
        .couleurTreizieme: "Tredezime",

        // MARK: Ce qui peut échouer
        .erreurModeleAbsent: "Das Trennmodell ist nicht installiert.",
        .erreurModeleIllisible: "Modell nicht lesbar: %1$@",
        .erreurAucunMorceau: "Kein Stück geöffnet.",
        .erreurEcritureImpossible: "„%1$@“ kann nicht geschrieben werden.",
        .erreurInterrompue: "Trennung abgebrochen.",
        .erreurSeparationEchouee: "Die Trennung ist fehlgeschlagen: %1$@",
        .erreurEnvironnementOnnx: "ONNX-Umgebung nicht verfügbar — %1$@",
        .erreurCoreMLIndisponible: "CoreML nicht verfügbar",
        .erreurFormatIllisible: "Format nicht lesbar",
        .erreurFormatEntree: "Eingabeformat unbrauchbar",
        .erreurTampons: "Puffer nicht verfügbar",
        .erreurAucunEchantillon: "kein Sample gelesen",
        .erreurReseauRienRendu: "das Netz hat nichts geliefert",
        .erreurOnnxAbsent: "ONNX Runtime ist nicht installiert — .\\onnx.ps1 ausführen.",
        .erreurQuatrePistes: "das Netz hat nicht alle vier Spuren geliefert",
        .erreurLectureImpossible: "Wiedergabe nicht möglich: %1$@",
        .erreurMoteurAudio: "Audio-Engine nicht verfügbar: %1$@",
        .erreurFichierIllisible: "„%1$@“ konnte nicht gelesen werden.",
        .dialogueOuvrir: "Öffnen",
        .dialogueChoisirUnMorceau: "Eine Audiodatei zum Heraushören wählen",

        // MARK: Les étapes de la séparation
        .etapeLectureDuMorceau: "Stück wird gelesen…",
        .etapeOuvertureDuReseau: "Netz wird geladen…",
        .etapeCompilationDuReseau: "Netz wird für diese Maschine übersetzt — nur einmal…",

        // MARK: Ce que l'application dit d'elle-même
        .statutLectureDuFichier: "Datei wird gelesen…",
        .statutAnalyseFaite: "%1$@ — %2$@, in %3$@ s analysiert (×%4$@ Echtzeit)%5$@",
        .statutReglagesRetrouves: " · Einstellungen wiedergefunden",
        .statutModeleAbsentApplication: "Modell fehlt in der App: ./modele.sh und dann ./build.sh ausführen.",
        .statutPreparation: "Stück wird vorbereitet…",
        .statutPistesNonEnregistrees: "Spuren nicht gespeichert: %1$@",
        .statutLectureDesPistes: "Bereits getrennte Spuren werden gelesen…",
        .statutSeparationPourcent: "Spuren werden getrennt: %1$@ %",
        .statutSeparationRestant: "Spuren werden getrennt: %1$@ % — noch %2$@",
        .statutSeparationEnCours: "Spuren werden getrennt…",
        .statutPistesIllisibles: "Spuren nicht lesbar; der Mix ist geblieben.",
        .statutAnalyseDe: "„%1$@“ wird analysiert…",
        .statutReleveBatterie: "Schlagzeug wird gelesen…",
        .statutBatterieRetiree: "Schlagzeug entfernt",
        .statutAucunCoup: "Kein Schlag gefunden",
        .statutReleveAccords: "Akkorde werden gelesen…",
        .statutAccordsGrilleDabord: "Akkorde: zuerst das Raster suchen",
        .statutAccordsRienDeTenu: "Akkorde: nichts Gehaltenes auf dem Bild — Bild aufhellen",
        .statutPistesEffacees: "Spuren gelöscht.",
        .dureeSecondes: "%1$@ s",
        .dureeMinutes: "%1$@ min",
        .dureeMinutesSecondes: "%1$@ min %2$@ s",

        // MARK: Le panneau : ses groupes
        .groupeTempo: "Tempoerkennung",
        .groupeTempoAide: "Beim Öffnen aus den Anschlägen geschätzt. Sie bestimmt die Taktstriche, das Einrasten und die Akkorderkennung.",
        .groupeLecture: "Wiedergabe",
        .groupeLectureAide: "Was erklingt, und wie. Ein Klick ins Bild versetzt den Abspielkopf und lässt die bezeichnete Linie klingen.",
        .groupeImage: "Bild",
        .groupeImageAide: "Was das Spektrogramm zeigt: wie weit hinunter in den Grund, und über wie viele Oktaven gespreizt.",
        .groupeAffichage: "Anzeige",
        .groupeAffichageAide: "Was sich um das Bild legt: die Schlagzeuglinie, die Akkordnamen, die Schreibweise der schwarzen Tasten.",
        .groupeBoucle: "Schleife",
        .groupeBoucleAide: "Eine Schleife ziehen: im Lineal oben ziehen, oder ⇧ + Ziehen im Bild. Das gelbe Feld zu ziehen verschiebt sie, seine Ränder dehnen sie; die Grenzen rasten am Raster ein, und ⌘ während der Geste löst sie.",
        .groupePistes: "Spuren",
        .groupePistesAide: "Die vier getrennten Spuren, die die rechte Spalte hörbar macht. Eine Spur zu wählen ändert nicht nur, was man hört, sondern was man sieht: das Spektrogramm einer einzelnen Spur hat weit weniger sich kreuzende Teiltöne, sodass das Einrasten endlich die richtige Linie trifft.",

        // MARK: Le panneau lui-même
        .panneauReglages: "Einstellungen",
        .panneauOuvrirAide: "Wiedergabe, Schleife, Tempo, Anzeige — ⌘⌥R",
        .panneauOuvrirAideWin: "Wiedergabe, Schleife, Tempo, Anzeige — R.",
        .panneauReplierAide: "Feld einklappen — ⌘⌥R",

        // MARK: Le tempo
        .tempoEstimationFloue: "Die Schätzung ist bei diesem Stück nicht eindeutig: das Raster ist zu prüfen.",
        .tempoChampAide: "Auf die Zahl klicken, um sie einzugeben: die Schätzung irrt sich meist um den Faktor zwei, was eine Ziffer behebt.",
        .tempoBPM: "BPM",
        .tempoPasAide: "Um 0,1 BPM verstellen — genug, um ein über die Länge driftendes Raster einzuholen.",
        .tempoSignatureAide: "Zählzeiten pro Takt. Ändert den Abstand der Taktstriche und die Marke der Eins.",
        .tempoUnIci: "1 hier",
        .tempoUnIciAide: "Die Eins des Takts auf den Abspielkopf setzen (1)",
        .tempoRelancerAide: "Die Schätzung erneut laufen lassen, mit der gewählten Taktart.",
        .tempoIndetermine: "Tempo unbestimmt",
        .tempoChercherAide: "In diesem Stück ein Raster suchen. Ohne es weder Taktstriche noch Akkorderkennung.",
        .tempoIndetermineWin: "Tempo unbestimmt",
        .tempoChercher: "Suchen",
        .tempoMoinsAide: "0,1 BPM abziehen — genug, um ein über die Länge driftendes Raster einzuholen.",
        .tempoPlusAide: "0,1 BPM hinzufügen — genug, um ein über die Länge driftendes Raster einzuholen.",
        .tempoSignatureAideWin: "Zählzeiten pro Takt: der Abstand der Taktstriche und die Marke der Eins. Klicken schaltet von 2/4 bis 7/4 durch.",
        .tempoUnIciAideWin: "Die Eins des Takts auf den Abspielkopf setzen (1).",
        .tempoRefaire: "Neu",
        .tempoRelancerAideWin: "Die Schätzung erneut laufen lassen, mit der gewählten Taktart.",

        // MARK: La lecture
        .lectureLire: "Play",
        .lecturePause: "Pause",
        .lectureLireAide: """
            Abspielen oder anhalten (Leertaste).
            Ein Klick ins Bild versetzt den Abspielkopf und lässt die bezeichnete Linie klingen.
            """,
        .lectureLireAideWin: "Abspielen oder anhalten (Leertaste). Die Pfeile ← und → gehen eine Sekunde weiter, fünf mit ⇧.",
        .lectureNeutre: "Neutral",
        .lectureNeutreAide: "Tempo auf 100 % und Transposition auf +0 zurückstellen. Verlangsamung und Transposition kommen gemeinsam zurecht: gemeinsam wurden sie verschoben, um eine Stelle zu entziffern, und man will das Stück wieder hören, wie es ist, nicht halb.",
        .lectureVitesse: "Tempo",
        .lectureVitesseAide: """
            Verlangsamt oder beschleunigt, ohne die Tonhöhe anzutasten.
            Eine Raste führt genau auf 100 % zurück, wo die Bearbeitung aus dem Klangweg genommen wird.
            Doppelklick auf den Text führt dorthin zurück.
            """,
        .lectureVitesseAideWin: "Verlangsamt oder beschleunigt, ohne die Tonhöhe anzutasten. Bei 100 % wird die Bearbeitung aus dem Klangweg genommen.",
        .lectureTransposition: "Transposition",
        .lectureTranspositionAide: """
            Transponiert in Halbtönen, ohne das Tempo anzutasten.
            Zwischenwerte rücken eine verstimmte Aufnahme zurecht.
            Doppelklick auf den Text führt auf +0 zurück.
            """,
        .lectureTranspositionAideWin: "Transponiert in Halbtönen, ohne das Tempo anzutasten. Zwischenwerte rücken eine verstimmte Aufnahme zurecht.",
        .lectureVolume: "Lautstärke",
        .lectureVolumeAide: "Der Ausgangspegel der App. Der Mac überlässt ihn dem Mischer des Systems; hier ist er der einzige Ort, ihn ohne Verlassen des Fensters zu stellen.",
        .lectureRevenirAuDebut: "Zurück zum Anfang",
        .uniteDemiTons: "HT",
        .uniteDemiTonsLong: "Halbtöne",
        .uniteOctaves: "Okt",
        .uniteMesures: "Takte",

        // MARK: L'image
        .imageContraste: "Kontrast",
        .imageContrasteAide: """
            Der schwarz dargestellte Pegel. Ihn zu heben räumt den Grund auf
            und nimmt zugleich dieses Rauschen aus dem Magneten des Zeigers.
            """,
        .imageContrasteAideWin: "Der schwarz dargestellte Pegel: die Grenze zwischen dem, was gespielt wird, und dem, was nicht. Ihn zu heben räumt den Grund auf und nimmt zugleich dieses Rauschen aus dem Magneten des Zeigers; ihn zu senken lässt blasse Linien in die Akkorderkennung.",
        .imageAutoGlobal: "Auto global",
        .imageAutoGlobalAide: "Zurück zum Kontrast, der beim Öffnen über das ganze Stück gemessen wurde — die Marke, von der man ausging. K",
        .imageAutoLocal: "Auto lokal",
        .imageAutoLocalAide: "Schwarz, Weiß und Neigung nach dem einstellen, was auf dem Bild ist. ⇧K",
        .imageZoomVertical: "Vertikaler Zoom",
        .imageZoomVerticalAide: """
            Spreizt die Frequenzachse; der Wert gibt die Zahl der sichtbaren Oktaven.
            Am Trackpad: ⇧ + Kneifen, oder ⇧ + Rad — unter dem Zeiger verankert.
            Die Wiedergabe wird auf das sichtbare Band gefiltert.
            """,
        .imageZoomVerticalAideWin: "Spreizt die Frequenzachse; der Wert gibt die Zahl der sichtbaren Oktaven. Mit der Maus: ⇧ und das Rad, unter dem Zeiger verankert. Die Wiedergabe wird auf das sichtbare Band gefiltert.",

        // MARK: L'affichage
        .affichageBatterie: "Drums",
        .affichageBatterieAide: """
            Schlagzeugerkennung, unter dem Bild: ein Strich pro Schlag, eine Linie pro Stimme.
            Das Spektrogramm nennt die Tonhöhe, die eine Perkussion nicht hat; diese drei Linien nennen wann, was und wie stark.
            Sie taugen vor allem auf der einzelnen Schlagzeugspur.
            """,
        .affichageAccords: "Akkorde",
        .affichageAccordsAide: """
            Akkordnamen, am Fuß des Rasters: einer pro Zählzeit, pro Takt oder pro Phrase, je nach Zoom.
            Aus dem getrennten Bass und der Begleitung erschlossen — es müssen also alle vier Spuren berechnet sein und ein metrisches Raster bestehen.
            Sie zu überfahren lässt sie klingen und umkreist ihre Töne im Spektrum; die Blässe eines Namens nennt die Unsicherheit der Lesung.
            """,
        .affichageTouchesNoires: "Namen der schwarzen Tasten",
        .affichageTouchesNoiresAide: "Die Schreibweise der schwarzen Tasten: Es oder Dis.",
        .affichageBemols: "b-Vorzeichen",
        .affichageDieses: "Kreuze",

        // MARK: La boucle
        .boucleJouer: "In Schleife spielen",
        .boucleJouerAide: """
            Die Stelle in Schleife spielen, ohne Loch beim Zurückspringen (L).
            [ und ] setzen Anfang und Ende auf den Abspielkopf.
            """,
        .boucleJouerAideWin: "Die Stelle in Schleife spielen, ohne Loch beim Zurückspringen (L).",
        .boucleAuxMesures: "Auf Takte",
        .boucleAuxMesuresAide: "Die Schleife auf die umgebenden Takte ausdehnen (B)",
        .boucleMesures: "Takte",
        .boucleEffacer: "Löschen",
        .boucleEffacerAide: "Die Schleife löschen (Esc)",
        .boucleAucunPassage: "Keine Stelle gezogen",
        .boucleDuAu: "Von %1$@ bis %2$@",
        .boucleDebutIci: "Anfang hier",
        .boucleFinIci: "Ende hier",
        .boucleCalerSurMesures: "An Takten ausrichten",
        .boucleBoucler: "Schleife",
        .boucleEffacerLaBoucle: "Die Schleife löschen",

        // MARK: Les pistes, dans le panneau
        .pistesEffacerLesPistes: "Spuren löschen",
        .pistesEffacerAide: "Zurück zum Mix. Die Spuren berechnen sich in einer halben Minute neu, wenn man zu ihnen zurückkehrt.",
        .pistesSeparationEnCours: "wird getrennt",
        .pistesGardees: "Behalten",
        .pistesToutGarder: "Alle behalten",
        .pistesToutGarderAide: "Den ganzen Mix wieder hören, alle vier Spuren angewählt.",
        .pistesRefaire: "Neu",
        .pistesRefaireAide: "Die berechneten Spuren vergessen. Sie entstehen beim nächsten Hören einer einzelnen Spur neu — der Ausweg, wenn die Trennung bei einem Stück misslungen ist.",
        .pistesCache: "Spuren-Cache",
        .pistesPlafond: "Grenze",
        .pistesPlafondAide: "Ein siebenminütiges Stück kostet etwa 300 MB. Über der Grenze gehen die am längsten nicht geöffneten Stücke ganz — nie das gerade gehörte — und werden neu berechnet.",
        .pistesViderLeCache: "Cache leeren",
        .pistesViderLeCacheAide: "Alle abgelegten Spuren wegwerfen. Jedes Stück muss erneut getrennt werden, etwa eine halbe Minute je Stück.",
        .pistesPoidsAbsents: "Die Demucs-Gewichte sind nicht installiert — siehe `modele.sh`. Ohne sie wird das Stück gelesen, wie es ist.",
        .pistesPoidsAbsentsWin: "Die Demucs-Gewichte sind nicht installiert — siehe `modele.sh`. Ohne sie wird das Stück gelesen, wie es ist.",
        .pistesOnnxAbsent: "ONNX Runtime ist nicht installiert: .\\onnx.ps1 ausführen und die App neu starten.",

        // MARK: Les menus du Mac
        .menuOuvrir: "Öffnen…",
        .menuOuvrirRecemment: "Benutzte Dokumente",
        .menuViderLeMenu: "Menü löschen",
        .menuLecture: "Wiedergabe",
        .menuBoucle: "Schleife",
        .menuAffichage: "Darstellung",
        .menuTempo: "Tempo",
        .menuPanneauDeReglages: "Einstellungsfeld",
        .menuContrasteOuverture: "Kontrast beim Öffnen",
        .menuContrasteAutomatique: "Automatischer Kontrast auf das Sichtbare",
        .menuPoserLePremierTemps: "Die Eins hierher setzen",
        .menuRecalculerLaGrille: "Raster neu berechnen",

        // MARK: L'accueil
        .accueilDeposer: "Eine Audiodatei ablegen",
        .accueilRaccourci: "oder ⌘O",
        .accueilAnalyse: "Analyse…",

        // MARK: La fenêtre des réglages
        .reglagesPistesSeparees: "Getrennte Spuren",
        .reglagesTailleMaximale: "Maximale Cache-Größe",
        .reglagesOccupe: "Belegt",
        .reglagesViderPoints: "Leeren…",
        .reglagesViderBouton: "Leeren",
        .reglagesAnnuler: "Abbrechen",
        .reglagesCacheExplication: "Ein siebenminütiges Stück kostet etwa 250 MB. Über der Grenze gehen die am längsten nicht geöffneten Stücke ganz — nie das gerade gehörte — und berechnen sich in einer halben Minute neu.",
        .reglagesViderTitre: "Den Cache der getrennten Spuren leeren?",
        .reglagesViderMessage: "Jedes Stück muss erneut getrennt werden, etwa eine halbe Minute je Stück.",
        .reglagesCouleurDesNotes: "Farbe der Töne",
        .reglagesPremiereTeinte: "Erster Farbton",
        .reglagesCouleursExplication: "Die zwölf Farbtöne folgen dem Quintenzirkel: zwei harmonisch nahe Töne sind farblich nah, ein Tritonus stellt sie einander gegenüber. Den ersten zu ändern dreht nur die Reihe — diese Verhältnisse bewegen sich nicht.",
        .reglagesLangue: "Sprache",
        .reglagesLangueInterface: "Sprache der Oberfläche",
        .reglagesLangueSysteme: "System",
        .reglagesNomDesNotes: "Tonnamen",
        .reglagesNotesSelonLaLangue: "Folgt der Sprache",
        .reglagesLangueExplication: "Die Tonnamen folgen der Sprache und werden getrennt eingestellt: man kann die Oberfläche auf Deutsch und die Akkorde in C D E wollen. Auf Deutsch und Polnisch ist B das Bes und H das reine H.",
        .reglagesAuto: "Auto",
        .reglagesLangueImposee: "Die Umgebungsvariable SPECTRE_LANGUE erzwingt die Sprache: diese Einstellung bleibt wirkungslos, solange sie gesetzt ist.",

        // MARK: Windows
        .winMenuOuvrir: "Eine Datei öffnen…\tStrg+O",
        .winMenuOuvrirRecemment: "Benutzte Dokumente",
        .winMenuViderLaListe: "Liste löschen",
        .winMenuMasquerReglages: "Einstellungen ausblenden\tR",
        .winMenuReglages: "Einstellungen…\tR",
        .winMenuQuitter: "Beenden\tAlt+F4",
        .winBarreAide: "R Einstellungen · Leertaste Play · ⇧ziehen Schleife · Strg Rad Zoom · Rechtsklick Menü",
        .winBarreBoucle: "Schleife",
        .winBarreBoucleHorsService: "Schleife (aus)",
        .winFriseOuvrir: "Eine Datei öffnen: Strg + O",

        // MARK: Der Hinweis beim ersten Start
        .avisRapportsTitre: "Spectre meldet seine Pannen selbst",
        .avisRapportsCorps: "Wenn etwas kaputtgeht, schickt Spectre den Bericht von selbst, ohne zu fragen. Nur so lässt es sich beheben: niemand macht sich die Mühe, eine Panne zu schildern, und eine Panne, von der man nichts erfährt, bleibt.",
        .avisRapportsSecret: "Niemals dabei: Ihre Dateinamen, Ihre Ordner oder was Sie hören. Sonst wird nichts erfasst — weder was Sie mit der Anwendung tun noch wie lange Sie sie geöffnet haben.",
        .avisRapportsCompris: "Verstanden",

        // MARK: La ligne de commande
        .cliFichierIntrouvable: "Datei nicht gefunden: %1$@",
        .cliLectureImpossible: "Nicht lesbar: %1$@",
        .cliMatriceVide: "Leere Matrix",
        .cliAucuneGrille: "Kein metrisches Raster gefunden",
        .cliMixage: "Mix",
        .cliPistesSansBatterie: "Spuren ohne Schlagzeug",
        .cliBasseEtAccompagnement: "Bass und Begleitung",
        .cliCarteDeBasse: " · Basskarte",
        .cliEnTete: "%1$@ — %2$@ s, %3$@%4$@, %5$@ BPM, %6$@/4",
        .cliVocabulaire: "%1$@ — %2$@ Akkorde",
        .cliReglages: "Kontrast %1$@…%2$@ dB, Neigung %3$@ dB/Oktave; Klarheit %4$@, Haltedauer %5$@ %",
        .cliTemps: "Karte %1$@ s, Lesung %2$@ s, Analyse inbegriffen %3$@ s",
        .cliAucunIntervalle: "(kein Abschnitt im verlangten Fenster)",
        .cliIntervalles: "%1$@ Abschnitte, %2$@ benannt (%3$@ %), %4$@ Wechsel",
        .cliRaiesTenues: "%1$@ gehaltene Linien je Abschnitt, %2$@ % unerklärt, %3$@ % der Abschnitte tragen eine",
        .cliNomsSurs: "%1$@ % der Namen sind sicher (Abstand ≥ 0,5 Linie)",
        .cliInexpliquees: "unerklärt: ",
        .cliFondamentale: "Grundt.",
        .cliModeleAbsent: "Modell fehlt: ./modele.sh und dann ./build.sh ausführen",
        .cliSuffixePistes: " — Spuren",
        .cliCrete: "Spitze",
        .cliSeparationFaite: "Fertig in %1$@ s für %2$@ s Musik (×%3$@ Echtzeit).",
        .cliEchec: "Fehlgeschlagen: %1$@",
    ]
}
