import Foundation

// L'espagnol. Il nomme ses notes `Do Re Mi` comme le français, mais prend les
// symboles anglo-saxons — `Lam`, `Domaj7` — parce que c'est ce qu'on lit sur les
// grilles hispanophones. Voir `SystemeDeNotes.symboles`.

extension Catalogue {
    public static let espagnol: [Cle: String] = [

        // MARK: Les pistes
        .pisteMixage: "Mezcla",
        .pisteBatterie: "Batería",
        .pisteBasse: "Bajo",
        .pisteVoix: "Voz",
        .pisteReste: "Resto",
        .pisteMixageAide: "El tema tal como está.",
        .pisteBatterieAide: """
            Batería y percusión.
            Una vez separadas las pistas deja de verse en el espectrograma: alimenta las tres líneas de abajo, que dicen de ella lo que un espectro no sabe decir.
            Desmarcada, ya no se oye y esas líneas quedan vacías.
            """,
        .pisteBasseAide: "El bajo solo — la pista mejor aislada, y la más difícil de sacar de oído en una mezcla densa.",
        .pisteVoixAide: "El canto solo.",
        .pisteResteAide: "Todo lo demás: teclados, guitarras, vientos, cuerdas.",
        .pisteSilence: "silencio",
        .pisteSans: "sin %1$@",
        .pisteNi: " ni ",
        .pistePlus: " + ",
        .pisteDecocherAide: "\nDesmarcar quita esta pista; lo que queda suena junto.",

        // MARK: Les voies de la batterie
        .voieGrosseCaisse: "Bombo",
        .voieCaisseClaire: "Caja",
        .voieCymbales: "Platillos",
        .voieGrosseCaisseCourt: "BO",
        .voieCaisseClaireCourt: "CA",
        .voieCymbalesCourt: "PL",

        // MARK: Les palettes
        .paletteGris: "Escala de grises",
        .paletteNotes: "Notas (círculo de quintas)",

        // MARK: Le relevé d'accords
        .porteeParTemps: "Un acorde por pulso",
        .porteeParMesure: "Un acorde por compás",
        .vocabulaireTriades: "Sólo tríadas",
        .vocabulaireSeptiemes: "Tríadas y séptimas",
        .vocabulaireTout: "Incluyendo sextas y disminuidos",
        .vocabulaireEnrichis: "Con las tensiones — 9, 11, 13",

        // MARK: Les couleurs d'accord
        .couleurMajeur: "mayor",
        .couleurMineur: "menor",
        .couleurSuspendu4: "cuarta suspendida",
        .couleurSeptieme: "séptima",
        .couleurMineurSeptieme: "menor séptima",
        .couleurSeptiemeMajeure: "séptima mayor",
        .couleurDemiDiminue: "semidisminuido",
        .couleurDiminue: "disminuido",
        .couleurAugmente: "aumentado",
        .couleurSixte: "sexta",
        .couleurMineurSixte: "menor sexta",
        .couleurNeuviemeAjoutee: "novena añadida",
        .couleurMineurNeuviemeAjoutee: "menor con novena añadida",
        .couleurNeuvieme: "novena",
        .couleurMineurNeuvieme: "menor novena",
        .couleurSeptiemeMajeureNeuvieme: "novena mayor",
        .couleurOnzieme: "oncena",
        .couleurMineurOnzieme: "menor oncena",
        .couleurTreizieme: "trecena",

        // MARK: Ce qui peut échouer
        .erreurModeleAbsent: "El modelo de separación no está instalado.",
        .erreurModeleIllisible: "Modelo ilegible: %1$@",
        .erreurAucunMorceau: "Ningún tema abierto.",
        .erreurEcritureImpossible: "No se puede escribir «%1$@».",
        .erreurInterrompue: "Separación interrumpida.",
        .erreurSeparationEchouee: "La separación ha fallado: %1$@",
        .erreurEnvironnementOnnx: "entorno ONNX no disponible — %1$@",
        .erreurCoreMLIndisponible: "CoreML no disponible",
        .erreurFormatIllisible: "formato ilegible",
        .erreurFormatEntree: "formato de entrada inservible",
        .erreurTampons: "búferes no disponibles",
        .erreurAucunEchantillon: "no se ha leído ninguna muestra",
        .erreurReseauRienRendu: "la red no ha devuelto nada",
        .erreurOnnxAbsent: "ONNX Runtime no está instalado — ejecutar .\\onnx.ps1.",
        .erreurQuatrePistes: "la red no ha devuelto las cuatro pistas",
        .erreurLectureImpossible: "Reproducción imposible: %1$@",
        .erreurMoteurAudio: "Motor de audio no disponible: %1$@",
        .erreurFichierIllisible: "No se ha podido leer «%1$@».",
        .dialogueOuvrir: "Abrir",
        .dialogueChoisirUnMorceau: "Elegir un archivo de audio para transcribir",

        // MARK: Les étapes de la séparation
        .etapeLectureDuMorceau: "Leyendo el tema…",
        .etapeOuvertureDuReseau: "Abriendo la red…",
        .etapeCompilationDuReseau: "Compilando la red para esta máquina — una sola vez…",

        // MARK: Ce que l'application dit d'elle-même
        .statutLectureDuFichier: "Leyendo el archivo…",
        .statutAnalyseFaite: "%1$@ — %2$@, analizado en %3$@ s (×%4$@ tiempo real)%5$@",
        .statutReglagesRetrouves: " · ajustes recuperados",
        .statutModeleAbsentApplication: "Falta el modelo en la aplicación: ejecutar ./modele.sh y luego ./build.sh.",
        .statutPreparation: "Preparando el tema…",
        .statutPistesNonEnregistrees: "Pistas no guardadas: %1$@",
        .statutLectureDesPistes: "Leyendo las pistas ya separadas…",
        .statutSeparationPourcent: "Separando las pistas: %1$@ %",
        .statutSeparationRestant: "Separando las pistas: %1$@ % — quedan %2$@",
        .statutSeparationEnCours: "Separando las pistas…",
        .statutPistesIllisibles: "Pistas ilegibles; se ha quedado la mezcla.",
        .statutAnalyseDe: "Analizando «%1$@»…",
        .statutReleveBatterie: "Leyendo la batería…",
        .statutGrilleReprise: "Rejilla recuperada de la batería",
        .statutBatterieRetiree: "Batería quitada",
        .statutAucunCoup: "Ningún golpe detectado",
        .statutReleveAccords: "Leyendo los acordes…",
        .statutAccordsGrilleDabord: "Acordes: buscar antes la rejilla",
        .statutAccordsRienDeTenu: "Acordes: nada sostenido en pantalla — aclarar la imagen",
        .statutPistesEffacees: "Pistas borradas.",
        .dureeSecondes: "%1$@ s",
        .dureeMinutes: "%1$@ min",
        .dureeMinutesSecondes: "%1$@ min %2$@ s",

        // MARK: Le panneau : ses groupes
        .groupeTempo: "Detección del tempo",
        .groupeTempoAide: "Estimado al abrir a partir de los ataques. Manda sobre las líneas de compás, el imán del cursor y la detección de acordes.",
        .groupeLecture: "Reproducción",
        .groupeLectureAide: "Lo que suena, y cómo. Al pulsar en la imagen se mueve el cabezal y suena la línea señalada.",
        .groupeImage: "Imagen",
        .groupeImageAide: "Lo que muestra el espectrograma: hasta dónde bajar en el fondo, y sobre cuántas octavas extenderlo.",
        .groupeAffichage: "Visualización",
        .groupeAffichageAide: "Lo que se pone alrededor de la imagen: la línea de batería, los nombres de acordes, la escritura de las teclas negras.",
        .groupeBoucle: "Bucle",
        .groupeBoucleAide: "Trazar un bucle: arrastrar en la regla de arriba, o ⇧ + arrastrar en la imagen. Arrastrar la zona amarilla la desplaza, sus bordes la estiran; los límites se pegan a la rejilla, y ⌘ durante el gesto los libera.",
        .groupePistes: "Pistas",
        .groupePistesAide: "Las cuatro pistas separadas, las que hace sonar la columna de la derecha. Elegir una pista no sólo cambia lo que se oye, sino lo que se ve: el espectrograma de una pista aislada tiene muchos menos parciales cruzándose, de modo que el imán cae por fin en la línea correcta.",

        // MARK: Le panneau lui-même
        .panneauReglages: "Ajustes",
        .panneauOuvrirAide: "Reproducción, bucle, tempo, visualización — ⌘⌥R",
        .panneauOuvrirAideWin: "Reproducción, bucle, tempo, visualización — R.",
        .panneauReplierAide: "Plegar el panel — ⌘⌥R",

        // MARK: Le tempo
        .tempoEstimationFloue: "La estimación no es clara en este tema: hay que comprobar la rejilla.",
        .tempoChampAide: "Pulsar sobre la cifra para escribirla: la estimación suele fallar por un factor de dos, que se corrige con un dígito.",
        .tempoBPM: "BPM",
        .tempoPasAide: "Ajustar 0,1 BPM — lo justo para recuperar una rejilla que se desvía a lo largo.",
        .tempoSignatureAide: "Pulsos por compás. Cambia la separación de las líneas y la marca del primer tiempo.",
        .tempoUnIci: "1 aquí",
        .tempoUnIciAide: "Poner el primer tiempo del compás en el cabezal (1)",
        .tempoRelancerAide: "Volver a estimar, con el compás elegido.",
        .tempoIndetermine: "tempo indeterminado",
        .tempoChercherAide: "Buscar una rejilla en este tema. Sin ella, ni líneas de compás ni detección de acordes.",
        .tempoIndetermineWin: "Tempo indeterminado",
        .tempoChercher: "Buscar",
        .tempoMoinsAide: "Quitar 0,1 BPM — lo justo para recuperar una rejilla que se desvía a lo largo.",
        .tempoPlusAide: "Añadir 0,1 BPM — lo justo para recuperar una rejilla que se desvía a lo largo.",
        .tempoSignatureAideWin: "Pulsos por compás: la separación de las líneas y la marca del primer tiempo. Al pulsar se recorre de 2/4 a 7/4.",
        .tempoUnIciAideWin: "Poner el primer tiempo del compás en el cabezal (1).",
        .tempoRefaire: "Rehacer",
        .tempoRelancerAideWin: "Volver a estimar, con el compás elegido.",

        // MARK: La lecture
        .lectureLire: "Reproducir",
        .lecturePause: "Pausa",
        .lectureLireAide: """
            Reproducir o pausar (espacio).
            Al pulsar en la imagen se mueve el cabezal, y suena la línea señalada.
            """,
        .lectureLireAideWin: "Reproducir o pausar (espacio). Las flechas ← y → avanzan un segundo, cinco con ⇧.",
        .lectureNeutre: "Neutro",
        .lectureNeutreAide: "Devolver la velocidad al 100 % y la transposición a +0. La ralentización y la transposición vuelven a su sitio juntas: se empujaron juntas para descifrar un pasaje, y uno quiere volver a oír el tema tal como es, no a medias.",
        .lectureVitesse: "Velocidad",
        .lectureVitesseAide: """
            Ralentiza o acelera sin tocar la altura.
            Un tope devuelve exactamente al 100 %, donde el tratamiento sale del camino del sonido.
            Doble clic en el texto para volver ahí.
            """,
        .lectureVitesseAideWin: "Ralentiza o acelera sin tocar la altura. Al 100 % el tratamiento sale del camino del sonido.",
        .lectureTransposition: "Transposición",
        .lectureTranspositionAide: """
            Transpone sin tocar la velocidad, en semitonos.
            Los valores intermedios recolocan una grabación desafinada.
            Doble clic en el texto para volver a +0.
            """,
        .lectureTranspositionAideWin: "Transpone sin tocar la velocidad, en semitonos. Los valores intermedios recolocan una grabación desafinada.",
        .lectureVolume: "Volumen",
        .lectureVolumeAide: "El nivel de salida de la aplicación. El Mac lo deja al mezclador del sistema; aquí es el único sitio donde ajustarlo sin salir de la ventana.",
        .lectureRevenirAuDebut: "Volver al principio",
        .uniteDemiTons: "st",
        .uniteDemiTonsLong: "semitonos",
        .uniteOctaves: "oct",
        .uniteMesures: "compases",

        // MARK: L'image
        .imageContraste: "Contraste",
        .imageContrasteAide: """
            Nivel representado en negro. Subirlo limpia el fondo,
            y quita de paso ese ruido del imán del cursor.
            """,
        .imageContrasteAideWin: "El nivel representado en negro: la frontera entre lo que se toca y lo que no. Subirlo limpia el fondo, y quita de paso ese ruido del imán del cursor; bajarlo deja entrar líneas pálidas en la detección de acordes.",
        .imageAutoGlobal: "Auto global",
        .imageAutoGlobalAide: "Volver al contraste medido sobre el tema entero al abrirlo — la marca de la que se partió. K",
        .imageAutoLocal: "Auto local",
        .imageAutoLocalAide: "Ajustar negro, claro y pendiente según lo que hay en pantalla. ⇧K",
        .imageZoomVertical: "Zoom vertical",
        .imageZoomVerticalAide: """
            Extiende el eje de frecuencias; el valor da el número de octavas visibles.
            En el trackpad: ⇧ + pellizco, o ⇧ + rueda — anclado bajo el cursor.
            La reproducción se filtra a la banda visible.
            """,
        .imageZoomVerticalAideWin: "Extiende el eje de frecuencias; el valor da el número de octavas visibles. Con el ratón: ⇧ y la rueda, anclado bajo el cursor. La reproducción se filtra a la banda visible.",

        // MARK: L'affichage
        .affichageBatterie: "Batería",
        .affichageBatterieAide: """
            Detección de la batería, bajo la imagen: un trazo por golpe, una línea por voz.
            El espectrograma dice la altura, que una percusión no tiene; estas tres líneas dicen cuándo, qué y cuán fuerte.
            Valen sobre todo en la pista de batería aislada.
            """,
        .affichageAccords: "Acordes",
        .affichageAccordsAide: """
            Nombres de acordes, al pie de la rejilla: uno por pulso, por compás o por frase según el zoom.
            Deducidos del bajo y el acompañamiento separados — hacen falta pues las cuatro pistas calculadas, y una rejilla métrica.
            Al pasar por encima suenan y se rodean sus notas en el espectro; la palidez de un nombre dice la incertidumbre de la lectura.
            """,
        .affichageTouchesNoires: "Nombres de las teclas negras",
        .affichageTouchesNoiresAide: "La escritura de las teclas negras: Mi♭ o Re♯.",
        .affichageBemols: "Bemoles",
        .affichageDieses: "Sostenidos",

        // MARK: La boucle
        .boucleJouer: "Reproducir en bucle",
        .boucleJouerAide: """
            Reproducir el pasaje en bucle, sin hueco al volver (L).
            [ y ] ponen el principio y el final en el cabezal.
            """,
        .boucleJouerAideWin: "Reproducir el pasaje en bucle, sin hueco al volver (L).",
        .boucleAuxMesures: "A compases",
        .boucleAuxMesuresAide: "Extender el bucle a los compases que lo enmarcan (B)",
        .boucleMesures: "Compases",
        .boucleEffacer: "Borrar",
        .boucleEffacerAide: "Borrar el bucle (esc)",
        .boucleAucunPassage: "Ningún pasaje trazado",
        .boucleDuAu: "De %1$@ a %2$@",
        .boucleDebutIci: "Principio aquí",
        .boucleFinIci: "Final aquí",
        .boucleCalerSurMesures: "Ajustar a los compases",
        .boucleBoucler: "En bucle",
        .boucleEffacerLaBoucle: "Borrar el bucle",

        // MARK: Les pistes, dans le panneau
        .pistesEffacerLesPistes: "Borrar las pistas",
        .pistesEffacerAide: "Volver a la mezcla. Las pistas se recalculan en medio minuto si se vuelve a ellas.",
        .pistesSeparationEnCours: "separando",
        .pistesGardees: "Conservadas",
        .pistesToutGarder: "Conservar todo",
        .pistesToutGarderAide: "Volver a oír la mezcla entera, las cuatro pistas marcadas.",
        .pistesRefaire: "Rehacer",
        .pistesRefaireAide: "Olvidar las pistas calculadas. Se rehacen la próxima vez que se escuche una pista sola — el recurso cuando la separación ha salido mal en un tema.",
        .pistesCache: "Caché de pistas",
        .pistesPlafond: "Tope",
        .pistesPlafondAide: "Un tema de siete minutos cuesta unos 300 MB. Pasado el tope, los temas abiertos hace más tiempo se van enteros — nunca el que se está oyendo — y se recalculan.",
        .pistesViderLeCache: "Vaciar la caché",
        .pistesViderLeCacheAide: "Tirar todas las pistas guardadas. Cada tema tendrá que separarse de nuevo, unos treinta segundos por tema.",
        .pistesOuvrirLeDossier: "Abrir la carpeta",
        .pistesOuvrirLeDossierAide: "Mostrar en el explorador de archivos la carpeta donde se guardan las pistas separadas.",
        .pistesPoidsAbsents: "Los pesos de Demucs no están instalados — ver `modele.sh`. Sin ellos, el tema se lee tal como está.",
        .pistesPoidsAbsentsWin: "Los pesos de Demucs no están instalados — ver `modele.sh`. Sin ellos, el tema se lee tal como está.",
        .pistesOnnxAbsent: "ONNX Runtime no está instalado: ejecutar .\\onnx.ps1, y luego reiniciar la aplicación.",

        // MARK: Les menus du Mac
        .menuOuvrir: "Abrir…",
        .menuOuvrirRecemment: "Abrir reciente",
        .menuViderLeMenu: "Vaciar el menú",
        .menuLecture: "Reproducción",
        .menuBoucle: "Bucle",
        .menuAffichage: "Visualización",
        .menuTempo: "Tempo",
        .menuPanneauDeReglages: "Panel de ajustes",
        .menuContrasteOuverture: "Contraste de apertura",
        .menuContrasteAutomatique: "Contraste automático según la pantalla",
        .menuPoserLePremierTemps: "Poner aquí el primer tiempo",
        .menuRecalculerLaGrille: "Recalcular la rejilla",

        // MARK: L'accueil
        .accueilDeposer: "Soltar un archivo de audio",
        .accueilRaccourci: "o ⌘O",
        .accueilAnalyse: "Analizando…",

        // MARK: La page de lancement
        .lancementReprendre: "Retomar un tema",
        .lancementAucunMorceau: "Todavía no se ha abierto ningún tema.",
        .lancementOuvrirUnFichier: "Abrir un archivo…",
        .lancementRetirer: "Quitar de la lista y tirar sus pistas separadas",
        .lancementSepare: "pistas separadas",

        // MARK: Le diaporama du premier lancement
        .bienvenueTitreBoucle: "Repetir un pasaje a cámara lenta",
        .bienvenueCorpsBoucle: "Mayús + arrastrar sobre el espectrograma elige un pasaje y lo pone en bucle. Los deslizadores Velocidad y Transposición, en el panel de ajustes, lo ralentizan sin desafinarlo y lo transportan sin ralentizarlo.",
        .bienvenueTempoBoucle: "El tempo se detecta solo al abrir el tema. Cuando cae al lado, el panel lo corrige: la cifra se escribe a mano, y «1 aquí» pone el primer tiempo del compás donde está el cabezal.",
        .bienvenueTitrePistes: "Cuatro pistas, separadas en su propia máquina",
        .bienvenueCorpsPistes: "Voz, bajo, batería y el resto se aíslan en cuanto se abre un tema, y se guardan para las veces siguientes. El cálculo dura unos minutos; la barra de abajo dice por dónde va, y el tema se escucha mientras tanto.",
        .bienvenueRapports: "Cuando algo se rompe, Spectre envía el informe por su cuenta. Ni los nombres de sus archivos, ni sus carpetas, ni lo que escucha forman parte de él.",
        .bienvenueSuivant: "Siguiente",
        .bienvenueCommencer: "Empezar",
        .bienvenuePasser: "Omitir",

        // MARK: La mise à jour
        .majTitre: "Spectre %1$@ ya está disponible",
        .majCorps: "Usted tiene la versión %1$@.",
        .majTelecharger: "Descargar",
        .majIgnorer: "Omitir esta versión",

        // MARK: La fenêtre des réglages
        .reglagesPistesSeparees: "Pistas separadas",
        .reglagesTailleMaximale: "Tamaño máximo de la caché",
        .reglagesOccupe: "Ocupado",
        .reglagesViderPoints: "Vaciar…",
        .reglagesOuvrirLeDossier: "Abrir la carpeta",
        .reglagesViderBouton: "Vaciar",
        .reglagesAnnuler: "Cancelar",
        .reglagesCacheExplication: "Un tema de siete minutos cuesta unos 250 MB. Pasado el tope, los temas abiertos hace más tiempo se van enteros — nunca el que se está oyendo — y se recalculan en medio minuto.",
        .reglagesViderTitre: "¿Vaciar la caché de pistas separadas?",
        .reglagesViderMessage: "Cada tema tendrá que separarse de nuevo, unos treinta segundos por tema.",
        .reglagesCouleurDesNotes: "Color de las notas",
        .reglagesPremiereTeinte: "Primer tono",
        .reglagesCouleursExplication: "Los doce tonos se reparten según el círculo de quintas: dos notas cercanas armónicamente son cercanas en color, un tritono las pone en oposición. Cambiar el primero sólo gira la serie — esas relaciones no se mueven.",
        .reglagesLangue: "Idioma",
        .reglagesLangueInterface: "Idioma de la interfaz",
        .reglagesLangueSysteme: "Sistema",
        .reglagesNomDesNotes: "Nombre de las notas",
        .reglagesNotesSelonLaLangue: "Sigue al idioma",
        .reglagesLangueExplication: "El nombre de las notas sigue al idioma, y se ajusta aparte: uno puede querer la interfaz en español y los acordes en C D E. En alemán y en polaco, B es el si bemol y H el si natural.",
        .reglagesAuto: "Auto",
        .reglagesLangueImposee: "La variable de entorno SPECTRE_LANGUE impone el idioma: este ajuste no tiene efecto mientras esté puesta.",

        // MARK: Windows
        .winMenuOuvrir: "Abrir un archivo…\tCtrl+O",
        .winMenuOuvrirRecemment: "Abrir reciente",
        .winMenuViderLaListe: "Vaciar la lista",
        .winMenuMasquerReglages: "Ocultar los ajustes\tR",
        .winMenuReglages: "Ajustes…\tR",
        .winMenuQuitter: "Salir\tAlt+F4",
        .winBarreAide: "R ajustes · espacio reproducir · ⇧arrastrar bucle · Ctrl rueda zoom · clic derecho menú",
        .winBarreBoucle: "bucle",
        .winBarreBoucleHorsService: "bucle (desactivado)",
        .winFriseOuvrir: "Abrir un archivo: Ctrl + O",

        // MARK: El aviso del primer arranque

        // MARK: La ligne de commande
        .cliFichierIntrouvable: "Archivo no encontrado: %1$@",
        .cliLectureImpossible: "Lectura imposible: %1$@",
        .cliMatriceVide: "Matriz vacía",
        .cliAucuneGrille: "No se ha encontrado rejilla métrica",
        .cliMixage: "mezcla",
        .cliPistesSansBatterie: "pistas sin batería",
        .cliBasseEtAccompagnement: "bajo y acompañamiento",
        .cliCarteDeBasse: " · mapa de bajo",
        .cliEnTete: "%1$@ — %2$@ s, %3$@%4$@, %5$@ BPM, %6$@/4",
        .cliVocabulaire: "%1$@ — %2$@ acordes",
        .cliReglages: "contraste %1$@…%2$@ dB, pendiente %3$@ dB/octava; claridad %4$@, sostén %5$@ %",
        .cliTemps: "mapa %1$@ s, lectura %2$@ s, análisis incluido %3$@ s",
        .cliAucunIntervalle: "(ningún intervalo en la ventana pedida)",
        .cliIntervalles: "%1$@ intervalos, %2$@ nombrados (%3$@ %), %4$@ cambios",
        .cliRaiesTenues: "%1$@ líneas sostenidas por intervalo, %2$@ % sin explicar, %3$@ % de los intervalos llevan una",
        .cliNomsSurs: "%1$@ % de los nombres son seguros (margen ≥ 0,5 línea)",
        .cliInexpliquees: "sin explicar: ",
        .cliFondamentale: "fund.",
        .cliModeleAbsent: "Falta el modelo: ejecutar ./modele.sh y luego ./build.sh",
        .cliSuffixePistes: " — pistas",
        .cliCrete: "pico",
        .cliSeparationFaite: "Hecho en %1$@ s para %2$@ s de música (×%3$@ tiempo real).",
        .cliEchec: "Fallo: %1$@",
    ]
}
