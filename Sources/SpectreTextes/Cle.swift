import Foundation

/// Une clé par texte affiché.
///
/// L'énumération est plate et `CaseIterable` exprès : c'est ce qui permet à
/// `LangueCheck` de dire « il manque cette clé en polonais » plutôt que de laisser
/// le trou se découvrir dans une fenêtre, six mois plus tard, sur la seule machine
/// qui parle cette langue-là.
///
/// Les noms sont français, comme le reste du dépôt. Le suffixe `Aide` marque une
/// infobulle, `Win` un texte propre à Windows — les raccourcis n'y sont pas les
/// mêmes, et c'est la seule raison de doubler une clé.
public enum Cle: String, CaseIterable, Sendable {

    // MARK: - Les pistes

    case pisteMixage, pisteBatterie, pisteBasse, pisteVoix, pisteReste
    case pisteMixageAide, pisteBatterieAide, pisteBasseAide, pisteVoixAide
    case pisteResteAide
    case pisteSilence, pisteSans, pisteNi, pistePlus
    case pisteDecocherAide

    // MARK: - Les voies de la batterie

    case voieGrosseCaisse, voieCaisseClaire, voieCymbales
    case voieGrosseCaisseCourt, voieCaisseClaireCourt, voieCymbalesCourt

    // MARK: - Les palettes

    case paletteGris, paletteNotes

    // MARK: - Le relevé d'accords

    case porteeParTemps, porteeParMesure
    case vocabulaireTriades, vocabulaireSeptiemes, vocabulaireTout
    case vocabulaireEnrichis

    // MARK: - Les couleurs d'accord, en toutes lettres

    case couleurMajeur, couleurMineur, couleurSuspendu4, couleurSeptieme
    case couleurMineurSeptieme, couleurSeptiemeMajeure, couleurDemiDiminue
    case couleurDiminue, couleurAugmente, couleurSixte, couleurMineurSixte
    case couleurNeuviemeAjoutee, couleurMineurNeuviemeAjoutee, couleurNeuvieme
    case couleurMineurNeuvieme, couleurSeptiemeMajeureNeuvieme, couleurOnzieme
    case couleurMineurOnzieme, couleurTreizieme

    // MARK: - Ce qui peut échouer

    case erreurModeleAbsent, erreurModeleIllisible, erreurAucunMorceau
    case erreurEcritureImpossible, erreurInterrompue, erreurSeparationEchouee
    case erreurEnvironnementOnnx, erreurCoreMLIndisponible, erreurFormatIllisible
    case erreurFormatEntree, erreurTampons, erreurAucunEchantillon
    case erreurReseauRienRendu, erreurOnnxAbsent, erreurQuatrePistes
    case erreurLectureImpossible, erreurMoteurAudio, erreurFichierIllisible
    case dialogueOuvrir, dialogueChoisirUnMorceau

    // MARK: - Les étapes de la séparation

    case etapeLectureDuMorceau, etapeOuvertureDuReseau, etapeCompilationDuReseau

    // MARK: - Ce que l'application dit d'elle-même

    case statutLectureDuFichier, statutAnalyseFaite, statutReglagesRetrouves
    case statutModeleAbsentApplication, statutPreparation
    case statutPistesNonEnregistrees, statutLectureDesPistes
    case statutSeparationPourcent, statutSeparationRestant, statutSeparationEnCours
    case statutPistesIllisibles, statutAnalyseDe
    case statutReleveBatterie, statutBatterieRetiree, statutAucunCoup
    case statutReleveAccords, statutAccordsGrilleDabord, statutAccordsRienDeTenu
    case statutPistesEffacees
    case dureeSecondes, dureeMinutes, dureeMinutesSecondes

    // MARK: - Le panneau : ses groupes

    case groupeTempo, groupeTempoAide
    case groupeLecture, groupeLectureAide
    case groupeImage, groupeImageAide
    case groupeAffichage, groupeAffichageAide
    case groupeBoucle, groupeBoucleAide
    case groupePistes, groupePistesAide

    // MARK: - Le panneau lui-même

    case panneauReglages, panneauOuvrirAide, panneauOuvrirAideWin
    case panneauReplierAide

    // MARK: - Le tempo

    case tempoEstimationFloue, tempoChampAide, tempoBPM, tempoPasAide
    case tempoSignatureAide, tempoUnIci, tempoUnIciAide, tempoRelancerAide
    case tempoIndetermine, tempoChercherAide
    case tempoIndetermineWin, tempoChercher, tempoMoinsAide, tempoPlusAide
    case tempoSignatureAideWin, tempoUnIciAideWin, tempoRefaire, tempoRelancerAideWin

    // MARK: - La lecture

    case lectureLire, lecturePause, lectureLireAide, lectureLireAideWin
    case lectureNeutre, lectureNeutreAide
    case lectureVitesse, lectureVitesseAide, lectureVitesseAideWin
    case lectureTransposition, lectureTranspositionAide, lectureTranspositionAideWin
    case lectureVolume, lectureVolumeAide
    case lectureRevenirAuDebut
    case uniteDemiTons, uniteDemiTonsLong, uniteOctaves, uniteMesures

    // MARK: - L'image

    case imageContraste, imageContrasteAide, imageContrasteAideWin
    case imageAutoGlobal, imageAutoGlobalAide
    case imageAutoLocal, imageAutoLocalAide
    case imageZoomVertical, imageZoomVerticalAide, imageZoomVerticalAideWin

    // MARK: - L'affichage

    case affichageBatterie, affichageBatterieAide
    case affichageAccords, affichageAccordsAide
    case affichageTouchesNoires, affichageTouchesNoiresAide
    case affichageBemols, affichageDieses

    // MARK: - La boucle

    case boucleJouer, boucleJouerAide, boucleJouerAideWin
    case boucleAuxMesures, boucleAuxMesuresAide, boucleMesures
    case boucleEffacer, boucleEffacerAide
    case boucleAucunPassage, boucleDuAu
    case boucleDebutIci, boucleFinIci, boucleCalerSurMesures, boucleBoucler
    case boucleEffacerLaBoucle

    // MARK: - Les pistes, dans le panneau

    case pistesEffacerLesPistes, pistesEffacerAide, pistesSeparationEnCours
    case pistesGardees, pistesToutGarder, pistesToutGarderAide
    case pistesRefaire, pistesRefaireAide
    case pistesCache, pistesPlafond, pistesPlafondAide
    case pistesViderLeCache, pistesViderLeCacheAide
    case pistesPoidsAbsents, pistesPoidsAbsentsWin, pistesOnnxAbsent

    // MARK: - Les menus du Mac

    case menuOuvrir, menuOuvrirRecemment, menuViderLeMenu
    case menuLecture, menuBoucle, menuAffichage, menuTempo
    case menuPanneauDeReglages
    case menuContrasteOuverture, menuContrasteAutomatique
    case menuPoserLePremierTemps, menuRecalculerLaGrille

    // MARK: - L'accueil

    case accueilDeposer, accueilRaccourci, accueilAnalyse

    // MARK: - La fenêtre des réglages

    case reglagesPistesSeparees, reglagesTailleMaximale, reglagesOccupe
    case reglagesViderPoints, reglagesViderBouton, reglagesAnnuler
    case reglagesCacheExplication, reglagesViderTitre, reglagesViderMessage
    case reglagesCouleurDesNotes, reglagesPremiereTeinte, reglagesCouleursExplication
    case reglagesLangue, reglagesLangueInterface, reglagesLangueSysteme
    case reglagesNomDesNotes, reglagesNotesSelonLaLangue
    case reglagesLangueExplication, reglagesLangueImposee, reglagesAuto

    // MARK: - Windows

    case winMenuOuvrir, winMenuOuvrirRecemment, winMenuViderLaListe
    case winMenuMasquerReglages, winMenuReglages, winMenuQuitter
    case winBarreAide, winBarreBoucle, winBarreBoucleHorsService
    case winFriseOuvrir

    // MARK: - La ligne de commande

    case cliFichierIntrouvable, cliLectureImpossible, cliMatriceVide
    case cliAucuneGrille, cliMixage, cliPistesSansBatterie
    case cliBasseEtAccompagnement, cliCarteDeBasse, cliEnTete, cliVocabulaire
    case cliReglages, cliTemps, cliAucunIntervalle, cliIntervalles
    case cliRaiesTenues, cliNomsSurs, cliInexpliquees, cliFondamentale
    case cliModeleAbsent, cliSuffixePistes, cliCrete, cliSeparationFaite
    case cliEchec
}
