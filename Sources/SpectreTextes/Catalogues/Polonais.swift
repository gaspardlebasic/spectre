import Foundation

// Le polonais. Il partage ses douze noms de notes avec l'allemand — `Cis`, `Es`,
// `B` pour le si bémol et `H` pour le si naturel — voir `SystemeDeNotes.germanique`.
//
// Les nombres y prennent trois formes selon la quantité (1, 2–4, 5 et plus). Les
// textes d'ici l'évitent : les durées s'écrivent en unités abrégées (« 12 s »,
// « 3 min »), et les comptes de la ligne de commande sont suivis d'un nom au génitif
// pluriel, qui est la forme juste dès cinq et acceptable partout ailleurs dans un
// relevé chiffré.

extension Catalogue {
    public static let polonais: [Cle: String] = [

        // MARK: Les pistes
        .pisteMixage: "Miks",
        .pisteBatterie: "Perkusja",
        .pisteBasse: "Bas",
        .pisteVoix: "Wokal",
        .pisteReste: "Reszta",
        .pisteMixageAide: "Utwór taki, jaki jest.",
        .pisteBatterieAide: """
            Perkusja i instrumenty perkusyjne.
            Po rozdzieleniu ścieżek nie widać jej już w spektrogramie: zasila trzy linie u dołu, które mówią o niej to, czego widmo powiedzieć nie umie.
            Odznaczona — nie słychać jej, a te linie zostają puste.
            """,
        .pisteBasseAide: "Sam bas — ścieżka najlepiej wyodrębniona i najtrudniejsza do wyłapania ze słuchu w gęstym miksie.",
        .pisteVoixAide: "Sam śpiew.",
        .pisteResteAide: "Cała reszta: klawisze, gitary, dęte, smyczki.",
        .pisteSilence: "cisza",
        .pisteSans: "bez %1$@",
        .pisteNi: " i ",
        .pistePlus: " + ",
        .pisteDecocherAide: "\nOdznaczenie usuwa tę ścieżkę; to, co zostaje, gra razem.",

        // MARK: Les voies de la batterie
        .voieGrosseCaisse: "Stopa",
        .voieCaisseClaire: "Werbel",
        .voieCymbales: "Talerze",
        .voieGrosseCaisseCourt: "ST",
        .voieCaisseClaireCourt: "WE",
        .voieCymbalesCourt: "TA",

        // MARK: Les palettes
        .paletteGris: "Odcienie szarości",
        .paletteNotes: "Dźwięki (koło kwintowe)",

        // MARK: Le relevé d'accords
        .porteeParTemps: "Jeden akord na miarę",
        .porteeParMesure: "Jeden akord na takt",
        .vocabulaireTriades: "Tylko trójdźwięki",
        .vocabulaireSeptiemes: "Trójdźwięki i septymowe",
        .vocabulaireTout: "Z sekstowymi i zmniejszonymi",
        .vocabulaireEnrichis: "Z rozszerzeniami — 9, 11, 13",

        // MARK: Les couleurs d'accord
        .couleurMajeur: "durowy",
        .couleurMineur: "molowy",
        .couleurSuspendu4: "z zawieszoną kwartą",
        .couleurSeptieme: "septymowy",
        .couleurMineurSeptieme: "molowy septymowy",
        .couleurSeptiemeMajeure: "wielki septymowy",
        .couleurDemiDiminue: "półzmniejszony",
        .couleurDiminue: "zmniejszony",
        .couleurAugmente: "zwiększony",
        .couleurSixte: "sekstowy",
        .couleurMineurSixte: "molowy sekstowy",
        .couleurNeuviemeAjoutee: "z dodaną noną",
        .couleurMineurNeuviemeAjoutee: "molowy z dodaną noną",
        .couleurNeuvieme: "nonowy",
        .couleurMineurNeuvieme: "molowy nonowy",
        .couleurSeptiemeMajeureNeuvieme: "wielki nonowy",
        .couleurOnzieme: "undecymowy",
        .couleurMineurOnzieme: "molowy undecymowy",
        .couleurTreizieme: "tercdecymowy",

        // MARK: Ce qui peut échouer
        .erreurModeleAbsent: "Model rozdzielania nie jest zainstalowany.",
        .erreurModeleIllisible: "Model nie do odczytania: %1$@",
        .erreurAucunMorceau: "Żaden utwór nie jest otwarty.",
        .erreurEcritureImpossible: "Nie można zapisać „%1$@”.",
        .erreurInterrompue: "Rozdzielanie przerwane.",
        .erreurSeparationEchouee: "Rozdzielanie nie powiodło się: %1$@",
        .erreurEnvironnementOnnx: "środowisko ONNX niedostępne — %1$@",
        .erreurCoreMLIndisponible: "CoreML niedostępny",
        .erreurFormatIllisible: "format nie do odczytania",
        .erreurFormatEntree: "format wejściowy nie do użycia",
        .erreurTampons: "bufory niedostępne",
        .erreurAucunEchantillon: "nie odczytano żadnej próbki",
        .erreurReseauRienRendu: "sieć nic nie zwróciła",
        .erreurOnnxAbsent: "ONNX Runtime nie jest zainstalowany — uruchom .\\onnx.ps1.",
        .erreurQuatrePistes: "sieć nie zwróciła czterech ścieżek",
        .erreurLectureImpossible: "Odtwarzanie niemożliwe: %1$@",
        .erreurMoteurAudio: "Silnik dźwięku niedostępny: %1$@",
        .erreurFichierIllisible: "Nie udało się odczytać „%1$@”.",
        .dialogueOuvrir: "Otwórz",
        .dialogueChoisirUnMorceau: "Wybierz plik dźwiękowy do przepisania",

        // MARK: Les étapes de la séparation
        .etapeLectureDuMorceau: "Odczyt utworu…",
        .etapeOuvertureDuReseau: "Otwieranie sieci…",
        .etapeCompilationDuReseau: "Kompilacja sieci dla tej maszyny — tylko raz…",

        // MARK: Ce que l'application dit d'elle-même
        .statutLectureDuFichier: "Odczyt pliku…",
        .statutAnalyseFaite: "%1$@ — %2$@, przeanalizowano w %3$@ s (×%4$@ czasu rzeczywistego)%5$@",
        .statutReglagesRetrouves: " · ustawienia odzyskane",
        .statutModeleAbsentApplication: "Brak modelu w aplikacji: uruchom ./modele.sh, a potem ./build.sh.",
        .statutPreparation: "Przygotowanie utworu…",
        .statutPistesNonEnregistrees: "Ścieżki niezapisane: %1$@",
        .statutLectureDesPistes: "Odczyt już rozdzielonych ścieżek…",
        .statutSeparationPourcent: "Rozdzielanie ścieżek: %1$@ %",
        .statutSeparationRestant: "Rozdzielanie ścieżek: %1$@ % — jeszcze %2$@",
        .statutSeparationEnCours: "Rozdzielanie ścieżek…",
        .statutPistesIllisibles: "Ścieżki nie do odczytania; został miks.",
        .statutAnalyseDe: "Analiza „%1$@”…",
        .statutReleveBatterie: "Odczyt perkusji…",
        .statutGrilleReprise: "Siatka odtworzona z perkusji",
        .statutBatterieRetiree: "Perkusja usunięta",
        .statutAucunCoup: "Nie wykryto żadnego uderzenia",
        .statutReleveAccords: "Odczyt akordów…",
        .statutAccordsGrilleDabord: "Akordy: najpierw znajdź siatkę",
        .statutAccordsRienDeTenu: "Akordy: nic nie jest trzymane na ekranie — rozjaśnij obraz",
        .statutPistesEffacees: "Ścieżki usunięte.",
        .dureeSecondes: "%1$@ s",
        .dureeMinutes: "%1$@ min",
        .dureeMinutesSecondes: "%1$@ min %2$@ s",

        // MARK: Le panneau : ses groupes
        .groupeTempo: "Wykrywanie tempa",
        .groupeTempoAide: "Oszacowane przy otwarciu na podstawie ataków. Rządzi kreskami taktowymi, przyciąganiem kursora i odczytem akordów.",
        .groupeLecture: "Odtwarzanie",
        .groupeLectureAide: "Co gra i jak. Kliknięcie w obraz przesuwa głowicę i sprawia, że wskazana linia brzmi.",
        .groupeImage: "Obraz",
        .groupeImageAide: "Co pokazuje spektrogram: jak głęboko schodzić w tło i na ilu oktawach je rozciągnąć.",
        .groupeAffichage: "Wyświetlanie",
        .groupeAffichageAide: "Co układa się wokół obrazu: linia perkusji, nazwy akordów, zapis czarnych klawiszy.",
        .groupeBoucle: "Pętla",
        .groupeBoucleAide: "Rysowanie pętli: przeciągnij po linijce u góry albo ⇧ + przeciągnij po obrazie. Przeciągnięcie żółtego pola przesuwa je, jego brzegi rozciągają; granice przyklejają się do siatki, a ⌘ w trakcie gestu je uwalnia.",
        .groupePistes: "Ścieżki",
        .groupePistesAide: "Cztery rozdzielone ścieżki, te, które udostępnia kolumna po prawej. Wybór ścieżki zmienia nie tylko to, co słychać, ale i to, co widać: spektrogram pojedynczej ścieżki ma o wiele mniej krzyżujących się składowych, więc przyciąganie trafia wreszcie we właściwą linię.",

        // MARK: Le panneau lui-même
        .panneauReglages: "Ustawienia",
        .panneauOuvrirAide: "Odtwarzanie, pętla, tempo, wyświetlanie — ⌘⌥R",
        .panneauOuvrirAideWin: "Odtwarzanie, pętla, tempo, wyświetlanie — R.",
        .panneauReplierAide: "Zwiń panel — ⌘⌥R",

        // MARK: Le tempo
        .tempoEstimationFloue: "Oszacowanie nie jest jednoznaczne w tym utworze: siatkę trzeba sprawdzić.",
        .tempoChampAide: "Kliknij liczbę, aby ją wpisać: oszacowanie myli się najczęściej o czynnik dwa, co poprawia jedna cyfra.",
        .tempoBPM: "BPM",
        .tempoPasAide: "Zmiana o 0,1 BPM — tyle, by nadrobić siatkę dryfującą na długości.",
        .tempoSignatureAide: "Miar na takt. Zmienia odstęp kresek taktowych i znacznik pierwszej miary.",
        .tempoUnIci: "1 tutaj",
        .tempoUnIciAide: "Ustaw pierwszą miarę taktu na głowicy (1)",
        .tempoRelancerAide: "Powtórz oszacowanie, z wybranym metrum.",
        .tempoIndetermine: "tempo nieokreślone",
        .tempoChercherAide: "Poszukaj siatki w tym utworze. Bez niej ani kresek taktowych, ani odczytu akordów.",
        .tempoIndetermineWin: "Tempo nieokreślone",
        .tempoChercher: "Szukaj",
        .tempoMoinsAide: "Odejmij 0,1 BPM — tyle, by nadrobić siatkę dryfującą na długości.",
        .tempoPlusAide: "Dodaj 0,1 BPM — tyle, by nadrobić siatkę dryfującą na długości.",
        .tempoSignatureAideWin: "Miar na takt: odstęp kresek taktowych i znacznik pierwszej miary. Kliknięcie przechodzi od 2/4 do 7/4.",
        .tempoUnIciAideWin: "Ustaw pierwszą miarę taktu na głowicy (1).",
        .tempoRefaire: "Ponów",
        .tempoRelancerAideWin: "Powtórz oszacowanie, z wybranym metrum.",

        // MARK: La lecture
        .lectureLire: "Odtwórz",
        .lecturePause: "Pauza",
        .lectureLireAide: """
            Odtwarzaj lub zatrzymaj (spacja).
            Kliknięcie w obraz przesuwa głowicę i sprawia, że wskazana linia brzmi.
            """,
        .lectureLireAideWin: "Odtwarzaj lub zatrzymaj (spacja). Strzałki ← i → przesuwają o sekundę, o pięć z ⇧.",
        .lectureNeutre: "Neutralnie",
        .lectureNeutreAide: "Przywróć prędkość do 100 % i transpozycję do +0. Spowolnienie i transpozycja wracają do siebie razem: razem je przesunięto, żeby rozszyfrować fragment, a chce się usłyszeć utwór taki, jaki jest, nie w połowie.",
        .lectureVitesse: "Prędkość",
        .lectureVitesseAide: """
            Zwalnia lub przyspiesza, nie ruszając wysokości.
            Zatrzask wraca dokładnie do 100 %, gdzie obróbka znika z drogi dźwięku.
            Dwuklik na tekście, by tam wrócić.
            """,
        .lectureVitesseAideWin: "Zwalnia lub przyspiesza, nie ruszając wysokości. Przy 100 % obróbka znika z drogi dźwięku.",
        .lectureTransposition: "Transpozycja",
        .lectureTranspositionAide: """
            Transponuje w półtonach, nie ruszając prędkości.
            Wartości pośrednie ustawiają rozstrojone nagranie.
            Dwuklik na tekście, by wrócić do +0.
            """,
        .lectureTranspositionAideWin: "Transponuje w półtonach, nie ruszając prędkości. Wartości pośrednie ustawiają rozstrojone nagranie.",
        .lectureVolume: "Głośność",
        .lectureVolumeAide: "Poziom wyjściowy aplikacji. Mac zostawia go mikserowi systemu; tutaj to jedyne miejsce, gdzie da się go ustawić bez opuszczania okna.",
        .lectureRevenirAuDebut: "Wróć na początek",
        .uniteDemiTons: "pt",
        .uniteDemiTonsLong: "półtonów",
        .uniteOctaves: "okt",
        .uniteMesures: "taktów",

        // MARK: L'image
        .imageContraste: "Kontrast",
        .imageContrasteAide: """
            Poziom oddany na czarno. Podniesienie go czyści tło
            i przy okazji zabiera ten szum magnesowi kursora.
            """,
        .imageContrasteAideWin: "Poziom oddany na czarno: granica między tym, co grane, a tym, co nie. Podniesienie go czyści tło i przy okazji zabiera ten szum magnesowi kursora; obniżenie wpuszcza blade linie do odczytu akordów.",
        .imageAutoGlobal: "Auto globalnie",
        .imageAutoGlobalAide: "Wróć do kontrastu zmierzonego na całym utworze przy jego otwarciu — punktu, z którego się wyszło. K",
        .imageAutoLocal: "Auto lokalnie",
        .imageAutoLocalAide: "Ustaw czerń, jasność i nachylenie według tego, co na ekranie. ⇧K",
        .imageZoomVertical: "Powiększenie pionowe",
        .imageZoomVerticalAide: """
            Rozciąga oś częstotliwości; wartość podaje liczbę widocznych oktaw.
            Na gładziku: ⇧ + uszczypnięcie albo ⇧ + kółko — zakotwiczone pod kursorem.
            Odtwarzanie jest filtrowane do widocznego pasma.
            """,
        .imageZoomVerticalAideWin: "Rozciąga oś częstotliwości; wartość podaje liczbę widocznych oktaw. Myszą: ⇧ i kółko, zakotwiczone pod kursorem. Odtwarzanie jest filtrowane do widocznego pasma.",

        // MARK: L'affichage
        .affichageBatterie: "Perkusja",
        .affichageBatterieAide: """
            Odczyt perkusji, pod obrazem: jedna kreska na uderzenie, jedna linia na głos.
            Spektrogram mówi o wysokości, której perkusja nie ma; te trzy linie mówią kiedy, co i jak mocno.
            Najwięcej dają na wyodrębnionej ścieżce perkusji.
            """,
        .affichageAccords: "Akordy",
        .affichageAccordsAide: """
            Nazwy akordów, u stóp siatki: jedna na miarę, na takt albo na frazę, zależnie od powiększenia.
            Odgadnięte z rozdzielonego basu i akompaniamentu — potrzeba więc obliczonych czterech ścieżek i istniejącej siatki metrycznej.
            Najechanie na nie sprawia, że brzmią, i zakreśla ich dźwięki w widmie; bladość nazwy mówi o niepewności odczytu.
            """,
        .affichageTouchesNoires: "Nazwy czarnych klawiszy",
        .affichageTouchesNoiresAide: "Zapis czarnych klawiszy: Es albo Dis.",
        .affichageBemols: "Bemole",
        .affichageDieses: "Krzyżyki",

        // MARK: La boucle
        .boucleJouer: "Graj w pętli",
        .boucleJouerAide: """
            Graj fragment w pętli, bez dziury przy powrocie (L).
            [ i ] ustawiają początek i koniec na głowicy.
            """,
        .boucleJouerAideWin: "Graj fragment w pętli, bez dziury przy powrocie (L).",
        .boucleAuxMesures: "Do taktów",
        .boucleAuxMesuresAide: "Rozszerz pętlę na takty, które ją obejmują (B)",
        .boucleMesures: "Takty",
        .boucleEffacer: "Usuń",
        .boucleEffacerAide: "Usuń pętlę (esc)",
        .boucleAucunPassage: "Nie wyznaczono fragmentu",
        .boucleDuAu: "Od %1$@ do %2$@",
        .boucleDebutIci: "Początek tutaj",
        .boucleFinIci: "Koniec tutaj",
        .boucleCalerSurMesures: "Dopasuj do taktów",
        .boucleBoucler: "Pętla",
        .boucleEffacerLaBoucle: "Usuń pętlę",

        // MARK: Les pistes, dans le panneau
        .pistesEffacerLesPistes: "Usuń ścieżki",
        .pistesEffacerAide: "Wróć do miksu. Ścieżki przeliczą się w pół minuty, jeśli się do nich wróci.",
        .pistesSeparationEnCours: "rozdzielanie",
        .pistesGardees: "Zachowane",
        .pistesToutGarder: "Zachowaj wszystko",
        .pistesToutGarderAide: "Usłysz znów cały miks, wszystkie cztery ścieżki zaznaczone.",
        .pistesRefaire: "Ponów",
        .pistesRefaireAide: "Zapomnij obliczone ścieżki. Powstaną na nowo przy następnym odsłuchu pojedynczej ścieżki — ratunek, gdy rozdzielanie nie wyszło na jakimś utworze.",
        .pistesCache: "Pamięć ścieżek",
        .pistesPlafond: "Limit",
        .pistesPlafondAide: "Siedmiominutowy utwór kosztuje około 300 MB. Powyżej limitu najdawniej otwierane utwory odchodzą w całości — nigdy ten, którego się słucha — i są przeliczane na nowo.",
        .pistesViderLeCache: "Wyczyść pamięć",
        .pistesViderLeCacheAide: "Wyrzuć wszystkie zachowane ścieżki. Każdy utwór trzeba będzie rozdzielić od nowa, około pół minuty na utwór.",
        .pistesOuvrirLeDossier: "Otwórz folder",
        .pistesOuvrirLeDossierAide: "Pokaż w menedżerze plików folder, w którym leżą rozdzielone ścieżki.",
        .pistesPoidsAbsents: "Wagi Demucsa nie są zainstalowane — zobacz `modele.sh`. Bez nich utwór czyta się taki, jaki jest.",
        .pistesPoidsAbsentsWin: "Wagi Demucsa nie są zainstalowane — zobacz `modele.sh`. Bez nich utwór czyta się taki, jaki jest.",
        .pistesOnnxAbsent: "ONNX Runtime nie jest zainstalowany: uruchom .\\onnx.ps1, a potem uruchom aplikację ponownie.",

        // MARK: Les menus du Mac
        .menuOuvrir: "Otwórz…",
        .menuOuvrirRecemment: "Otwórz ostatnie",
        .menuViderLeMenu: "Wyczyść menu",
        .menuLecture: "Odtwarzanie",
        .menuBoucle: "Pętla",
        .menuAffichage: "Widok",
        .menuTempo: "Tempo",
        .menuPanneauDeReglages: "Panel ustawień",
        .menuContrasteOuverture: "Kontrast z otwarcia",
        .menuContrasteAutomatique: "Kontrast automatyczny według ekranu",
        .menuPoserLePremierTemps: "Ustaw tutaj pierwszą miarę",
        .menuRecalculerLaGrille: "Przelicz siatkę",

        // MARK: L'accueil
        .accueilDeposer: "Upuść plik dźwiękowy",
        .accueilRaccourci: "albo ⌘O",
        .accueilAnalyse: "Analiza…",

        // MARK: La page de lancement
        .lancementReprendre: "Wróć do utworu",
        .lancementAucunMorceau: "Nie otwarto jeszcze żadnego utworu.",
        .lancementOuvrirUnFichier: "Otwórz plik…",
        .lancementRetirer: "Usuń z listy i wyrzuć jego rozdzielone ścieżki",
        .lancementSepare: "ścieżki rozdzielone",

        // MARK: Le diaporama du premier lancement
        .bienvenueTitreBoucle: "Zapętlić fragment i zwolnić go",
        .bienvenueCorpsBoucle: "Shift + przeciągnięcie po spektrogramie wybiera fragment i zapętla go. Suwaki Prędkość i Transpozycja w panelu ustawień zwalniają go, nie rozstrajając, i transponują, nie zwalniając.",
        .bienvenueTempoBoucle: "Tempo jest wykrywane samo przy otwarciu. Kiedy trafia obok, panel je poprawia: liczbę można wpisać ręcznie, a „1 tutaj” stawia pierwszą miarę taktu tam, gdzie stoi głowica.",
        .bienvenueTitrePistes: "Cztery ścieżki, rozdzielone na Twoim komputerze",
        .bienvenueCorpsPistes: "Wokal, bas, perkusja i reszta są rozdzielane od razu przy otwarciu utworu, a potem zachowywane na kolejne razy. Obliczenie trwa kilka minut; dolny pasek mówi, gdzie jest, a utworu można w tym czasie słuchać.",
        .bienvenueRapports: "Kiedy coś się zepsuje, Spectre sam wysyła raport. Nazwy Twoich plików, Twoje foldery ani to, czego słuchasz, nigdy się w nim nie znajdują.",
        .bienvenueSuivant: "Dalej",
        .bienvenueCommencer: "Zaczynamy",
        .bienvenuePasser: "Pomiń",

        // MARK: La mise à jour
        .majTitre: "Spectre %1$@ jest dostępny",
        .majCorps: "Masz wersję %1$@.",
        .majTelecharger: "Pobierz",
        .majIgnorer: "Pomiń tę wersję",

        // MARK: La fenêtre des réglages
        .reglagesPistesSeparees: "Rozdzielone ścieżki",
        .reglagesTailleMaximale: "Maksymalny rozmiar pamięci",
        .reglagesOccupe: "Zajęte",
        .reglagesViderPoints: "Wyczyść…",
        .reglagesOuvrirLeDossier: "Otwórz folder",
        .reglagesViderBouton: "Wyczyść",
        .reglagesAnnuler: "Anuluj",
        .reglagesCacheExplication: "Siedmiominutowy utwór kosztuje około 250 MB. Powyżej limitu najdawniej otwierane utwory odchodzą w całości — nigdy ten, którego się słucha — i przeliczają się na nowo w pół minuty.",
        .reglagesViderTitre: "Wyczyścić pamięć rozdzielonych ścieżek?",
        .reglagesViderMessage: "Każdy utwór trzeba będzie rozdzielić od nowa, około pół minuty na utwór.",
        .reglagesCouleurDesNotes: "Kolor dźwięków",
        .reglagesPremiereTeinte: "Pierwszy odcień",
        .reglagesCouleursExplication: "Dwanaście odcieni rozłożono według koła kwintowego: dwa dźwięki bliskie harmonicznie są bliskie w kolorze, tryton stawia je naprzeciw siebie. Zmiana pierwszego tylko obraca szereg — te zależności się nie ruszają.",
        .reglagesLangue: "Język",
        .reglagesLangueInterface: "Język interfejsu",
        .reglagesLangueSysteme: "System",
        .reglagesNomDesNotes: "Nazwy dźwięków",
        .reglagesNotesSelonLaLangue: "Zgodnie z językiem",
        .reglagesLangueExplication: "Nazwy dźwięków idą za językiem i ustawia się je osobno: można chcieć interfejsu po polsku, a akordów w C D E. Po polsku i po niemiecku B to bes, a H to czyste h.",
        .reglagesAuto: "Auto",
        .reglagesLangueImposee: "Zmienna środowiskowa SPECTRE_LANGUE narzuca język: to ustawienie nie działa, dopóki jest ustawiona.",

        // MARK: Windows
        .winMenuOuvrir: "Otwórz plik…\tCtrl+O",
        .winMenuOuvrirRecemment: "Otwórz ostatnie",
        .winMenuViderLaListe: "Wyczyść listę",
        .winMenuMasquerReglages: "Ukryj ustawienia\tR",
        .winMenuReglages: "Ustawienia…\tR",
        .winMenuQuitter: "Zakończ\tAlt+F4",
        .winBarreAide: "R ustawienia · spacja odtwarzaj · ⇧przeciągnij pętla · Ctrl kółko powiększenie · prawy klik menu",
        .winBarreBoucle: "pętla",
        .winBarreBoucleHorsService: "pętla (wyłączona)",
        .winFriseOuvrir: "Otwórz plik: Ctrl + O",

        // MARK: Komunikat przy pierwszym uruchomieniu

        // MARK: La ligne de commande
        .cliFichierIntrouvable: "Nie znaleziono pliku: %1$@",
        .cliLectureImpossible: "Odczyt niemożliwy: %1$@",
        .cliMatriceVide: "Pusta macierz",
        .cliAucuneGrille: "Nie znaleziono siatki metrycznej",
        .cliMixage: "miks",
        .cliPistesSansBatterie: "ścieżki bez perkusji",
        .cliBasseEtAccompagnement: "bas i akompaniament",
        .cliCarteDeBasse: " · mapa basu",
        .cliEnTete: "%1$@ — %2$@ s, %3$@%4$@, %5$@ BPM, %6$@/4",
        .cliVocabulaire: "%1$@ — %2$@ akordów",
        .cliReglages: "kontrast %1$@…%2$@ dB, nachylenie %3$@ dB/oktawę; klarowność %4$@, trzymanie %5$@ %",
        .cliTemps: "mapa %1$@ s, odczyt %2$@ s, z analizą %3$@ s",
        .cliAucunIntervalle: "(brak odcinka w żądanym oknie)",
        .cliIntervalles: "%1$@ odcinków, %2$@ nazwanych (%3$@ %), %4$@ zmian",
        .cliRaiesTenues: "%1$@ trzymanych linii na odcinek, %2$@ % niewyjaśnionych, %3$@ % odcinków nosi jedną",
        .cliNomsSurs: "%1$@ % nazw jest pewnych (margines ≥ 0,5 linii)",
        .cliInexpliquees: "niewyjaśnione: ",
        .cliFondamentale: "podst.",
        .cliModeleAbsent: "Brak modelu: uruchom ./modele.sh, a potem ./build.sh",
        .cliSuffixePistes: " — ścieżki",
        .cliCrete: "szczyt",
        .cliSeparationFaite: "Gotowe w %1$@ s dla %2$@ s muzyki (×%3$@ czasu rzeczywistego).",
        .cliEchec: "Niepowodzenie: %1$@",
    ]
}
