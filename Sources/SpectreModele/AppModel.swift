import Foundation
import Observation
import SpectreCore
import SpectreTextes

/// Marge, en fraction de la largeur, que la tête de lecture ne doit pas franchir.
private let margeDuTournePage = 0.1
/// Durée du tourne-page.
private let dureeDuTournePage = 0.32

/// État de l'application : le fichier, sa matrice, la fenêtre visible, la lecture.
///
/// **Ce fichier ne connaît aucun système.** Tout ce qu'il demande à la plateforme
/// passe par les protocoles de `Plateforme.swift` ; ce qui reste ici est le
/// comportement de Spectre, le même sur toutes les machines. C'est la leçon du
/// premier portage, qui en avait écrit un second, plus fruste, et le regardait
/// diverger.
///
/// **Pourquoi générique sur le lecteur, et sur lui seul.** L'interface de macOS
/// fabrique des liaisons SwiftUI vers `model.player.speed` et
/// `model.player.transpose`. Une liaison exige un chemin modifiable de bout en
/// bout, et le suivi d'`Observation` exige un type *concret* : masquer le lecteur
/// derrière un protocole existentiel romprait ce suivi, et l'affichage cesserait
/// de se mettre à jour sans qu'une seule ligne de calcul soit fausse. C'est
/// précisément le piège que l'ancien `WINDOWS.md` avait signalé. Un paramètre
/// générique le contourne sans rien coûter : chaque plateforme pose son type, et
/// `Spectre` s'en cache derrière un `typealias`. Les autres services, que
/// l'interface n'observe jamais, restent des existentiels — plus simples.
@Observable public final class AppModel<Lecteur: LecteurAudio> {

    // MARK: Ce que la plateforme fournit

    @ObservationIgnored private let décodeur: Décodeur
    @ObservationIgnored private let pistes: ServiceDeSeparation
    @ObservationIgnored private let dialogue: DialogueFichier
    @ObservationIgnored private let récentsDuSystème: DocumentsRecents
    @ObservationIgnored private let extérieur: Exterieur
    /// Lisibles de l'extérieur, et en lecture seule : le dessin y prend l'origine
    /// des teintes, qui décide de la couleur des noms de notes. Les *écrire* est le
    /// métier du panneau, qui tient sa propre référence — voir `ReglagesModifiables`.
    @ObservationIgnored public let préférences: PreferencesGlobales

    public private(set) var source: AudioSource?
    public private(set) var spectrogram = Spectrogram.empty

    public var analysis: AnalysisSettings

    /// Les réglages d'affichage — et, depuis le relevé par raies, une **entrée du
    /// relevé d'accords**.
    ///
    /// Le noir de l'image est la frontière entre ce qui est joué et ce qui ne l'est
    /// pas : l'éclaircir fait entrer des raies pâles dans le relevé, le monter les
    /// en sort. C'est voulu et c'est le cœur de la promesse — ce qu'on voit est ce
    /// qui est lu — mais cela veut dire que tirer un curseur de contraste refait les
    /// accords, d'où la coalescence par tour de boucle.
    public var display = DisplaySettings() {
        didSet {
            // Le diapason décide de où tombent les demi-tons : la carte elle-même
            // est à refaire.
            if display.referenceA != oldValue.referenceA {
                releveCarteDesNotes()
            } else if display.floorDb != oldValue.floorDb
                        || display.ceilingDb != oldValue.ceilingDb
                        || display.gamma != oldValue.gamma
                        || display.tiltDbPerOctave != oldValue.tiltDbPerOctave {
                scheduleChords()
            }
        }
    }
    /// Le contraste mesuré à l'ouverture du fichier, sur le morceau entier.
    ///
    /// Relevé **même quand une session enregistrée impose autre chose** : sans
    /// cela, le retour au contraste d'ouverture n'aurait marché que sur un fichier
    /// jamais ouvert auparavant, c'est-à-dire jamais dans l'usage réel. Il est
    /// mesuré et non retenu d'une séance à l'autre : la même matrice donne la même
    /// mesure, si bien que rouvrir un morceau retrouve exactement le même repère
    /// sans qu'on ait rien à enregistrer.
    @ObservationIgnored private var openingContrast: DisplaySettings?
    public var viewport = Viewport()

    /// `var` et non `let` : SwiftUI n'accepte de fabriquer une liaison vers
    /// `player.speed` que si le chemin est modifiable de bout en bout.
    public var player: Lecteur

    /// Position de la tête de lecture, en secondes.
    public var playhead: Double = 0
    /// Position du curseur dans la vue (en points, depuis le coin haut-gauche).
    public var hover: CGPoint? {
        didSet {
            if hover == nil { snap = nil }
            updateChordTone()
        }
    }
    /// Vrai quand le curseur est sur les commandes flottantes.
    ///
    /// Elles sont posées **sur** l'image : sans cela, viser un bouton ferait
    /// afficher par-dessous la note et la fréquence du point qu'il cache, avec son
    /// trait et son cercle. On ne désigne pas une raie quand on vise un bouton.
    public var pointerOverControls = false {
        didSet {
            guard pointerOverControls else { return }
            hover = nil
        }
    }
    /// Raie sur laquelle le curseur s'est aimanté.
    public var snap: SnapTarget?

    /// Passage joué en boucle — et, en portée « mesure », le passage relevé.
    ///
    /// Les deux ne font qu'un exprès. Sélectionner un passage pour le travailler et
    /// demander ce qui s'y joue sont le même geste : on n'allait pas faire tracer
    /// deux rectangles pour la même intention. Le relevé suit donc la borne qu'on
    /// tire, sans latence — le chromagramme est déjà là, voir `chromaCache`.
    public var loop: ClosedRange<Double>? {
        didSet {
            pushLoop()
            // Quelle que soit la portée réglée : la boucle est devenue la portée du
            // relevé dès qu'elle existe, et l'effacer rend le morceau à la sienne.
            guard loop != oldValue else { return }
            reloadChords()
        }
    }
    public var loopEnabled = true { didSet { pushLoop() } }

    /// Grille métrique estimée au chargement, ajustable ensuite.
    ///
    /// C'est elle qui découpe le relevé des accords — un accord par temps — donc en
    /// changer le refait. Un tempo faux ou un « un » mal placé donnerait des accords
    /// à cheval sur deux harmonies, ce qui ne ressemble à rien : corriger la grille
    /// corrige les accords du même geste.
    public var tempo: TempoGrid? {
        didSet {
            guard tempo != oldValue else { return }
            reloadChords()
        }
    }

    /// Ce que la batterie joue : une ligne par voie, sous le spectrogramme.
    ///
    /// Dès que les quatre pistes existent, le relevé se fait sur la **piste de
    /// batterie seule** — et la batterie sort de l'image du même geste. C'est le
    /// bon régime : sur un mixage entier, tout ce qui claque dans le médium
    /// alimente la ligne de caisse claire et l'attaque d'une note de basse s'y lit
    /// comme un coup. Voir `relevePercussion(keeping:separated:fingerprint:mix:)`.
    public private(set) var percussion = PercussionTrack.empty
    /// Vrai tant que le relevé du morceau courant n'est pas fini.
    public private(set) var percussionPending = false
    /// Montrer la ligne de batterie. Volontairement **hors** des réglages conservés :
    /// c'est une vue en cours d'essai, et lui faire une place dans le format des
    /// sessions rendrait illisibles celles déjà écrites.
    public var showDrumLane = true
    @ObservationIgnored private var percussionToken = 0

    /// Les accords devinés — un par temps, ou un par mesure, ou un seul pour le
    /// passage sélectionné, selon la portée réglée. Vide tant que la séparation n'a
    /// pas eu lieu : il y faut la basse et l'accompagnement **séparément**.
    /// Le relevé, **à la hauteur qu'on entend** : c'est lui qu'on affiche et qu'on
    /// fait sonner. Voir `geometrieEntendue`.
    public private(set) var chords = ChordTrack.empty
    /// Le même relevé, à la hauteur où il a été fait. Transposer ne relance rien :
    /// c'est la même analyse, renommée.
    @ObservationIgnored private var relevéDesAccords = ChordTrack.empty
    public private(set) var chordsPending = false
    /// Écrire les noms d'accords sous la grille.
    public var showChords = true

    /// Avancement de l'analyse (0…1), `nil` quand rien n'est en cours.
    public var progress: Double?
    public var status: String?

    /// La page de lancement, le diaporama du premier lancement et la mise à jour.
    ///
    /// Un objet à part, et non trois propriétés de plus ici : ce qu'il porte ne vaut
    /// que tant qu'aucun morceau n'est ouvert, ne touche ni au son ni à l'image, et
    /// s'éprouve donc sans monter une carte son — voir `Lancement.swift`.
    ///
    /// `@ObservationIgnored` sur la référence, qui ne change jamais : c'est l'objet
    /// lui-même qui est observé, et les vues qui lisent `modele.lancement.morceaux`
    /// se remettent à jour comme si la liste était ici.
    @ObservationIgnored public let lancement: Lancement

    /// Sinusoïde d'écoute, tenue tant que le bouton reste enfoncé.
    @ObservationIgnored private let sinusoide: Sinusoide
    @ObservationIgnored private var probing = false

    /// Taille de la vue en points, tenue à jour par le rendu.
    @ObservationIgnored public var viewSize = CGSize(width: 1200, height: 700)
    @ObservationIgnored public weak var renderer: (any RenduSpectrogramme)?
    /// Évite de recadrer une deuxième fois si la vue change de taille après coup.
    @ObservationIgnored private var needsFit = false
    /// Dernière session écrite sur le disque, et depuis quand elle est périmée.
    @ObservationIgnored private var savedSession: FileSession?
    @ObservationIgnored private var staleSince: Double?
    /// Dernier examen de la session, pour ne pas le refaire à chaque image.
    @ObservationIgnored private var lastAutosaveCheck: Double = 0

    /// Tout ce que le modèle ne sait pas faire seul lui est remis ici, et une fois
    /// pour toutes. Il n'ira rien chercher ailleurs : c'est ce qui rend la liste
    /// des dépendances lisible d'un coup d'œil, et le modèle éprouvable avec des
    /// pièces de harnais à la place des vraies.
    public init(lecteur: Lecteur,
                décodeur: Décodeur,
                sinusoide: Sinusoide,
                pistes: ServiceDeSeparation,
                dialogue: DialogueFichier,
                récentsDuSystème: DocumentsRecents,
                extérieur: Exterieur,
                préférences: PreferencesGlobales) {
        self.player = lecteur
        self.décodeur = décodeur
        self.sinusoide = sinusoide
        self.pistes = pistes
        self.dialogue = dialogue
        self.récentsDuSystème = récentsDuSystème
        self.extérieur = extérieur
        self.préférences = préférences
        self.lancement = Lancement(pistes: pistes, exterieur: extérieur)
        self.analysis = AnalysisSettings(reassignment: préférences.reassignment)
    }

    /// Écrit la session en cours sans attendre l'échéance.
    ///
    /// À appeler quand l'application s'en va : quitter ne doit pas coûter les
    /// réglages, et la position de lecture n'est écrite qu'à ce moment-là. C'est la
    /// plateforme qui sait *quand* — `NSApplication.willTerminate` sur macOS,
    /// `WM_CLOSE` sous Windows — et le modèle qui sait *quoi*.
    public func applicationVaSeFermer() {
        flushSession()
    }

    public var title: String { source?.name ?? "Spectre" }
    public var fileURL: URL? { source?.url }
    public var duration: Double { source?.duration ?? 0 }

    // MARK: Ouverture

    public func openPanel() {
        if let url = dialogue.choisirUnMorceau() { open(url) }
    }

    // MARK: Les morceaux récents

    /// Ce que porte « Fichier ▸ Ouvrir récemment », et la page de lancement.
    ///
    /// Une seule liste pour les deux : elle vit dans `lancement`, qui la relit du
    /// disque et sait ce que chaque morceau a déjà de pistes calculées. Le menu n'a
    /// besoin que des adresses, et les prend ici — deux listes tenues en parallèle
    /// finiraient par se contredire au premier oubli.
    public var recentFiles: [URL] { lancement.morceaux.map(\.url) }

    public func clearRecentFiles() {
        lancement.toutOublier()
        récentsDuSystème.effacer()
    }

    /// Ce que la plateforme appelle une fois, quand la fenêtre est là.
    ///
    /// Remplace l'ouverture automatique du dernier morceau. Voir l'en-tête de
    /// `Lancement.swift` : rouvrir tout seul lançait une minute de GPU sur un
    /// morceau dont on ne voulait pas huit fois sur dix, et la page de lancement
    /// rend le choix sans rien coûter — la première ligne de la liste *est* le
    /// dernier morceau.
    ///
    /// Il ne reste donc à faire ici qu'une chose : poser au dépôt la question de la
    /// version. Le diaporama et la liste, eux, n'attendent rien et sont déjà prêts
    /// quand la fenêtre s'ouvre.
    public func demarrer() {
        lancement.chercherUneMiseAJour()
    }

    /// Montre le dossier des pistes séparées dans l'explorateur de fichiers.
    ///
    /// Le panneau de réglages dit ce qu'il occupe et sait le vider ; il manquait de
    /// pouvoir aller voir — pour reprendre une piste isolée dans un autre logiciel,
    /// ou pour comprendre où sont passés les gigaoctets.
    public func montrerLeDossierDesPistes() { lancement.montrerLeDossierDesPistes() }

    /// Refait l'image du morceau ouvert. Changer un réglage d'analyse n'est pas
    /// changer un réglage d'affichage : la matrice n'est pas à retoucher, elle est
    /// à recalculer, et avec elle la carte des notes, les accords et le tempo.
    ///
    /// On repasse par l'ouverture plutôt que d'écrire un chemin plus court : elle
    /// enregistre la session avant, la relit après, et rend donc le cadrage, le
    /// contraste et la tête de lecture tels qu'ils étaient.
    public func reanalyse() {
        guard let url = fileURL else { return }
        open(url)
    }

    public func open(_ url: URL) {
        guard progress == nil else { return }
        RecentFiles.note(url)
        récentsDuSystème.noter(url)
        lancement.rafraichir()
        status = T(.statutLectureDuFichier)
        progress = 0
        player.stop()
        playhead = 0

        let settings = analysis
        // Les services sont pris ici plutôt qu'à travers `self` dans le bloc : ils
        // ne changent jamais, et les prendre au passage évite de retenir le modèle
        // pour un calcul qui n'a plus d'objet dès qu'on change de morceau.
        let décodeur = self.décodeur
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            let loaded: AudioSource
            do {
                loaded = try décodeur.charger(url)
            } catch {
                // Dit **et** remonté. C'est l'étape 2 de `docs/RAPPORTS.md` : une
                // panne que l'application détecte déjà, qu'elle écrivait dans la
                // barre du bas avant de l'oublier. `Journal.erreur` est le seul
                // chemin — ce qui s'écrit dans le journal est ce qui part, et il n'y
                // a donc pas deux listes de pannes à tenir accordées.
                Journal.erreur("ouverture du morceau : \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.progress = nil
                    self?.status = error.localizedDescription
                }
                return
            }
            DispatchQueue.main.async { self?.status = "Analyse…" }

            let spectrogram = OfflineAnalysis.run(samples: loaded.mono,
                                                  sampleRate: loaded.sampleRate,
                                                  settings: settings) { p in
                DispatchQueue.main.async { self?.progress = p }
            }
            // Le tempo se lit dans la matrice : rien à relire du fichier.
            let grid = TempoEstimator.estimate(spectrogram)
            let elapsed = Date().timeIntervalSince(started)

            DispatchQueue.main.async {
                guard let self else { return }
                self.adopt(source: loaded, spectrogram: spectrogram,
                           tempo: grid, elapsed: elapsed)
            }
        }
    }

    private func adopt(source: AudioSource, spectrogram: Spectrogram,
                       tempo: TempoGrid?, elapsed: TimeInterval) {
        flushSession()                     // le morceau précédent garde ses réglages
        self.source = source
        self.spectrogram = spectrogram
        // Le nouveau morceau repart du mixage : les pistes du précédent n'ont rien
        // à faire à l'écran, et un calcul encore en cours sur lui n'a plus d'objet.
        mixSpectrogram = spectrogram
        selection = Self.everything
        stemCache.removeAll()
        bassNoteMap = .empty
        bassMapKey = nil
        // Les pistes du morceau précédent quittent la mémoire ici — six cent soixante
        // mégaoctets sur un morceau de huit minutes, qu'il n'y a aucune raison de
        // garder pour un fichier qu'on vient de fermer.
        banque = nil
        enAttenteDeBanque = nil
        chargementDesPistes = false
        job?.cancel()
        job = nil
        separating = nil
        separationError = nil
        snap = nil
        progress = nil
        player.load(url: source.url)
        renderer?.layout = spectrogram.layout
        renderer?.upload(spectrogram)
        percussionCache.removeAll()
        poserLesAccords(.empty)
        chordsPending = false
        // La carte des notes de la nouvelle image. Elle part en tâche de fond ; le
        // relevé des accords la suivra dès qu'elle sera là.
        releveCarteDesNotes()

        // Le contraste de l'ouverture, mesuré tout de suite et sur le morceau
        // entier — avant même de savoir si une session va le remplacer. C'est une
        // passe d'histogramme sur une matrice déjà en mémoire, sans commune mesure
        // avec l'analyse qui vient de l'y mettre, et c'est ce qui donne à K un
        // repère y compris sur un morceau qu'on rouvre.
        openingContrast = AutoContrast.settings(basedOn: display, in: spectrogram)

        let saved = source.fingerprint.flatMap { SessionStore.load($0) }
        if let saved {
            // Ce que l'utilisatrice a réglé l'emporte sur ce que l'analyse propose.
            display = saved.display
            self.tempo = saved.tempo ?? tempo
            grilleAutomatique = saved.tempo == nil
            loop = saved.loop
            player.speed = saved.speed
            player.transpose = saved.transpose
            viewport = saved.viewport
            needsFit = false
            clampViewport()
            seek(to: saved.playhead)
        } else {
            // Rien de connu : la grille vient de l'analyse, le cadrage montre tout,
            // et les réglages d'affichage restent ceux du morceau précédent.
            self.tempo = tempo
            grilleAutomatique = true
            loop = nil
            playhead = 0
            needsFit = true
            fitIfNeeded()
            // Rien de connu non plus sur l'allure de l'enregistrement : on la
            // mesure plutôt que d'imposer un compromis.
            restoreOpeningContrast()
        }
        savedSession = currentSession()
        staleSince = nil

        let ratio = source.duration / max(elapsed, 0.001)
        status = T(.statutAnalyseFaite, source.name, Self.format(source.duration),
                   String(format: "%.1f", elapsed), String(format: "%.0f", ratio),
                   saved != nil ? T(.statutReglagesRetrouves) : "")

        // Les pistes de ce morceau existent peut-être déjà, d'une séance
        // précédente : la batterie sort alors de l'image et va nourrir sa ligne,
        // sans rien avoir à demander. Sinon on s'en tient au mixage qu'on vient
        // d'analyser — repasser par `show` ne ferait que téléverser une deuxième
        // fois la même matrice.
        if source.fingerprint.map(pistes.estSepare) == true {
            // Rouvrir un morceau le remet en tête : le ménage du cache s'appuie sur
            // cette date, et jeter celui sur lequel on travaille serait le comble.
            source.fingerprint.map(pistes.marquerUtilise)
            show(selection)
        } else {
            relevePercussion(Self.everything, from: source.mono,
                             sampleRate: source.sampleRate)
            // **La séparation part d'elle-même.** Elle est devenue la condition de
            // presque tout ce que l'application sait faire — la ligne de batterie sur
            // la piste isolée, les noms d'accords sur basse et accompagnement — si
            // bien qu'attendre qu'on décoche une piste revenait à cacher le gros de
            // l'outil derrière un geste que rien n'annonce. Elle tourne en fond
            // pendant qu'on travaille, et n'a lieu qu'une fois par morceau.
            separate()
        }
    }

    // MARK: Réglages conservés

    private func currentSession() -> FileSession {
        FileSession(display: display, tempo: tempo, loop: loop, playhead: playhead,
                    speed: player.speed, transpose: player.transpose, viewport: viewport)
    }

    /// Écrit la session si elle a cessé de bouger depuis une seconde.
    ///
    /// La tête de lecture est exclue de la comparaison : elle change à chaque
    /// image pendant la lecture, et sauvegarder chaque seconde pour cela seul
    /// serait absurde. Elle est écrite avec le reste, et à la fermeture.
    private func autosave() {
        guard let fingerprint = source?.fingerprint else { return }
        // Quatre fois par seconde suffisent à décider s'il faut écrire dans une
        // seconde. Fabriquer et comparer la session à chaque image, cent vingt fois
        // par seconde, coûtait plus cher que l'écriture elle-même.
        let time = Horloge.maintenant()
        guard time - lastAutosaveCheck > 0.25 else { return }
        lastAutosaveCheck = time
        let current = currentSession()
        guard current.withoutPlayhead != savedSession?.withoutPlayhead else {
            staleSince = nil
            return
        }
        let now = Horloge.maintenant()
        guard let since = staleSince else { staleSince = now; return }
        guard now - since > 1 else { return }
        SessionStore.save(current, for: fingerprint)
        savedSession = current
        staleSince = nil
    }

    /// Écrit sans attendre — changement de morceau, ou fermeture de l'application.
    public func flushSession() {
        guard let fingerprint = source?.fingerprint else { return }
        let current = currentSession()
        guard current != savedSession else { return }
        SessionStore.save(current, for: fingerprint)
        savedSession = current
        staleSince = nil
    }

    private func fitIfNeeded() {
        guard needsFit, spectrogram.columnCount > 0, viewSize.width > 1 else { return }
        needsFit = false
        viewport = .fitting(columns: spectrogram.columnCount,
                            bins: spectrogram.binCount,
                            size: (Double(viewSize.width), Double(viewSize.height)))
    }

    // MARK: Boucle d'affichage

    /// Appelée à chaque image : synchronise la tête de lecture et fait défiler.
    public func tick(viewSize: CGSize) {
        let resized = abs(viewSize.width - self.viewSize.width) > 0.5
            || abs(viewSize.height - self.viewSize.height) > 0.5
        self.viewSize = viewSize
        if needsFit { fitIfNeeded() }
        // La palette des notes suit la transposition ; le reste de l'affichage la
        // suit par `geometrieEntendue`, qui se lit à la demande.
        renderer?.demiTons = player.transpose
        accorderALaTonalite()

        if player.isPlaying {
            let t = player.currentTime
            if abs(t - playhead) > 1e-4 { playhead = t }
            scrollToPlayhead()
            if player.loop == nil, t >= duration - 0.005 { player.pause() }
        }
        advanceTurn()
        if resized { clampViewport() }
        updateSnap()
        updateBandFilter()
        autosave()
    }

    /// N'entendre que ce qu'on regarde.
    ///
    /// La bande passante suit la portion visible de l'axe des fréquences : zoomer
    /// sur les graves isole la basse, et le filtre se règle image par image, donc
    /// pendant qu'on déplace la vue au trackpad sans interrompre la lecture.
    /// Quand tout le spectre est à l'écran, les filtres sont retirés — inutile de
    /// faire travailler quatre biquads pour ne rien couper.
    private func updateBandFilter() {
        guard spectrogram.columnCount > 0 else { return }
        player.setBand(viewport.visibleBand(in: spectrogram.layout,
                                            height: Double(viewSize.height)))
    }

    // MARK: Contraste

    /// Colonnes et lignes actuellement à l'écran.
    private var visibleColumns: Range<Int> {
        let first = Int(viewport.startColumn.rounded(.down))
        let last = Int(viewport.endColumn(width: Double(viewSize.width)).rounded(.up))
        let all = 0..<spectrogram.columnCount
        return (max(first, 0)..<max(last, 1)).clamped(to: all)
    }

    private var visibleBins: Range<Int> {
        let bottom = Int(viewport.bottomBin.rounded(.down))
        let top = Int(viewport.topBin(height: Double(viewSize.height)).rounded(.up))
        let all = 0..<spectrogram.binCount
        return (max(bottom, 0)..<max(top, 1)).clamped(to: all)
    }

    // MARK: Zoom vertical

    /// Nombre d'octaves visibles — la façon musicale de dire « zoom vertical ».
    public var visibleOctaves: Double {
        guard spectrogram.binCount > 0 else { return 0 }
        return Double(viewSize.height) * viewport.binsPerPoint
            / max(spectrogram.layout.binsPerOctave, 1)
    }

    /// Zoom vertical, 1 = tout le spectre tient dans la vue.
    ///
    /// Le curseur zoome autour du **milieu de la vue** : c'est le seul point fixe
    /// qui ait un sens quand le geste ne désigne aucun endroit de l'image, alors
    /// que le pincement, lui, s'ancre sous le doigt.
    public var verticalZoom: Double {
        get {
            guard spectrogram.binCount > 0, viewport.binsPerPoint > 0,
                  viewSize.height > 1 else { return 1 }
            return Double(spectrogram.binCount) / Double(viewSize.height) / viewport.binsPerPoint
        }
        set {
            let current = verticalZoom
            guard spectrogram.binCount > 0, current > 0 else { return }
            let target = min(max(newValue, 1), 64)
            guard abs(target - current) > 1e-6 else { return }
            viewport.zoomFrequency(factor: target / current,
                                   anchorY: Double(viewSize.height) / 2,
                                   height: Double(viewSize.height))
            clampViewport()
        }
    }

    /// Règle noir, clair et pente sur ce qu'on a sous les yeux.
    ///
    /// Sur ce qu'on regarde, et seulement là : le réglage sur le morceau entier
    /// n'est plus un bouton, c'est le repère d'ouverture — voir
    /// `restoreOpeningContrast()`. Deux commandes qui rendaient le même service au
    /// cadrage d'ensemble en font une de trop.
    public func applyAutoContrast() {
        guard spectrogram.columnCount > 0 else { return }
        let found = AutoContrast.settings(basedOn: display, in: spectrogram,
                                          columns: visibleColumns, bins: visibleBins)
        guard let found else { return }
        display = found
    }

    /// Revient au contraste mesuré à l'ouverture du fichier.
    ///
    /// C'est le point de retour, et il en fallait un. Les trois réglages de
    /// contraste se retouchent en permanence — on éclaircit pour aller chercher une
    /// harmonique, on assombrit pour ne garder que les attaques — et l'on finit par
    /// ne plus savoir d'où l'on est parti. Le seul repère qui vaille est celui que
    /// l'application avait mesuré sur le morceau entier en l'ouvrant : ni un
    /// compromis d'usine, ni le résultat d'un cadrage, l'allure de cet
    /// enregistrement-là.
    ///
    /// Ne touche ni au gamma, ni à la palette, ni au diapason : ce sont des goûts,
    /// pas des mesures, et les remettre d'office serait défaire un réglage qu'on
    /// n'a pas demandé à défaire.
    public func restoreOpeningContrast() {
        guard let opening = openingContrast else { return }
        display.floorDb = opening.floorDb
        display.ceilingDb = opening.ceilingDb
        display.tiltDbPerOctave = opening.tiltDbPerOctave
    }

    // MARK: Grille

    /// Pas de la grille actuellement dessinée, en temps. `nil` quand le zoom ne
    /// permet plus d'en montrer une.
    ///
    /// Une seule définition sert au tracé *et* à l'aimantation : ce sur quoi la
    /// boucle se cale est exactement ce qu'on voit, comme dans un séquenceur.
    public var gridUnit: Double? {
        guard let tempo, tempo.bpm > 0, spectrogram.columnCount > 0 else { return nil }
        return tempo.unit(pointsPerBeat: tempo.beatSeconds
                            / spectrogram.secondsPerColumn / viewport.columnsPerPoint)
    }

    /// Pas d'aimantation. Trop dézoomé pour montrer une grille, on se cale quand
    /// même sur les mesures : ⌘ reste de toute façon la porte de sortie.
    private var snapUnit: Double? {
        guard let tempo else { return nil }
        return gridUnit ?? Double(max(tempo.beatsPerBar, 1))
    }

    public func snapToGrid(_ time: Double) -> Double {
        guard let tempo, let unit = snapUnit else { return time }
        return tempo.snap(time, unit: unit)
    }

    private func updateSnap() {
        var found: SnapTarget?
        if let hover, spectrogram.columnCount > 0 {
            found = Snapping.nearest(to: hover, in: spectrogram, viewport: viewport,
                                     display: display, viewSize: viewSize)
            // L'aimantation cherche dans la matrice, donc dans les fréquences de
            // l'analyse ; ce qui en sort est lu, écrit et entendu, donc à la hauteur
            // qu'on entend. La ligne se pose au même pixel de toute façon :
            // `point(ofFrequency:)` transpose dans l'autre sens.
            if facteurDeTransposition != 1 { found?.frequency *= facteurDeTransposition }
        }
        if found != snap { snap = found }
        // La sinusoïde suit l'aimantation : elle se tait donc d'elle-même dès que
        // le curseur passe sur une région que les réglages rendent noire.
        if probing { sinusoide.play(found?.frequency) }
    }

    // MARK: Écoute d'une raie

    /// Fait sonner la raie désignée, et la suit tant que le bouton reste enfoncé.
    public func beginProbe(at point: CGPoint) {
        hover = point
        probing = true
        updateSnap()
    }

    public func endProbe() {
        guard probing else { return }
        probing = false
        sinusoide.stop()
    }


    /// Fait tourner la page quand la tête de lecture sort du cadre.
    ///
    /// L'image ne glisse pas en continu — illisible — mais saute d'une page quand
    /// la tête arrive à 10 % du bord, et se repose alors à 10 % de l'autre côté :
    /// on garde un peu de passé derrière soi et presque toute la largeur devant.
    private func scrollToPlayhead() {
        let width = Double(viewSize.width)
        guard width > 1 else { return }
        let column = spectrogram.column(atTime: playhead)
        // Pendant l'animation, c'est la destination qui décide : sans quoi chaque
        // image relancerait un tourne-page tant que la tête est encore hors cadre.
        let start = turn?.to ?? viewport.startColumn
        let x = (column - start) / viewport.columnsPerPoint
        guard x > width * (1 - margeDuTournePage) || x < width * margeDuTournePage else { return }
        turnPage(to: column - width * margeDuTournePage * viewport.columnsPerPoint)
    }

    /// Tourne-page en cours : d'où, vers où, depuis quand.
    @ObservationIgnored private var turn: (from: Double, to: Double, start: Double)?

    private func turnPage(to startColumn: Double) {
        // La destination est recadrée d'avance : en fin de fichier elle se confond
        // avec la position courante, et il ne se passe alors rien du tout plutôt
        // qu'une animation relancée à chaque image contre la butée.
        let target = clamped(startColumn)
        guard abs(target - viewport.startColumn) > 0.5 else { return }
        turn = (from: viewport.startColumn, to: target, start: Horloge.maintenant())
    }

    private func clamped(_ startColumn: Double) -> Double {
        var candidate = viewport
        candidate.startColumn = startColumn
        candidate.clamp(columns: spectrogram.columnCount, bins: spectrogram.binCount,
                        size: (Double(viewSize.width), Double(viewSize.height)))
        return candidate.startColumn
    }

    /// Interrompt le tourne-page. Appelé dès que la main reprend la barre : rien
    /// n'est plus désagréable qu'une vue qui continue de glisser sous les doigts.
    public func cancelTurn() { turn = nil }

    /// Vrai quand l'image suivante ne montrera pas la même chose que celle-ci.
    ///
    /// C'est ce que la boucle de fenêtre demande au modèle pour savoir si elle doit
    /// tourner à la cadence de l'écran ou se mettre au repos — voir
    /// `SpectreDessin/Cadence.swift`, qui dit pourquoi la question se pose.
    ///
    /// La liste est **volontairement large**. Se tromper vers le haut coûte
    /// quelques images de trop, ce que personne ne remarque ; se tromper vers le
    /// bas fige l'écran, ce que tout le monde remarque. Chaque terme est donc
    /// une source d'animation, et non un état qui *pourrait* bouger :
    ///
    /// - la lecture déplace la tête, et fait tourner la page ;
    /// - le tourne-page s'anime tout seul pendant une demi-seconde ;
    /// - l'analyse, la séparation, le relevé de batterie et celui d'accords
    ///   écrivent tous dans la barre d'état, et l'avancement y monte.
    ///
    /// Ce qui n'y est **pas**, et qui n'a pas à y être : le survol, les gestes, la
    /// molette. Ceux-là passent par la fenêtre, qui le dit à la cadence, et non par
    /// le modèle. Un modèle ne sait pas qu'une souris existe.
    public var quelqueChoseBouge: Bool {
        player.isPlaying
            || turn != nil
            || progress != nil
            || calculEnCours
            || percussionPending
            || chordsPending
    }

    private func advanceTurn() {
        guard let turn else { return }
        let elapsed = Horloge.maintenant() - turn.start
        let t = min(max(elapsed / dureeDuTournePage, 0), 1)
        let eased = t * t * (3 - 2 * t)          // départ et arrivée en douceur
        viewport.startColumn = turn.from + (turn.to - turn.from) * eased
        if t >= 1 { self.turn = nil }
        clampViewport()
    }

    public func clampViewport() {
        guard spectrogram.columnCount > 0 else { return }
        viewport.clamp(columns: spectrogram.columnCount,
                       bins: spectrogram.binCount,
                       size: (Double(viewSize.width), Double(viewSize.height)))
    }

    // MARK: - Pistes séparées

    /// Pistes **gardées**. Toutes cochées au départ, ce qui est le morceau tel
    /// qu'il est ; on retire ce dont on ne veut pas — la voix pour travailler
    /// l'accompagnement, la batterie pour entendre l'harmonie.
    ///
    /// C'est un **souhait** : tant que la séparation n'est pas faite, l'affichage
    /// reste sur le mixage et la barre porte l'avancement. On ne fait pas attendre
    /// devant un écran vide ce qui prend des minutes.
    public private(set) var selection: Set<Stem> = Reglages.everything


    /// Tout garder, c'est ne rien retirer. Renvoie vers `Reglages` : un type
    /// générique n'accepte pas de propriété statique stockée.
    public static var everything: Set<Stem> { Reglages.everything }
    /// Vrai quand rien n'est retiré : le morceau d'origine suffit alors, et il est
    /// plus fidèle que la somme de ses parts — la séparation ne conserve pas
    /// exactement le signal.
    public var isWholeMix: Bool { selection == Self.everything }
    /// Avancement de la séparation, puis de l'analyse de la piste (0…1).
    public private(set) var separating: Double?
    public private(set) var separationError: String?

    @ObservationIgnored private var mixSpectrogram = Spectrogram.empty
    /// Les spectrogrammes des pistes déjà regardées, gardés en mémoire : y revenir
    /// doit être instantané, alors que les recalculer coûterait chaque fois
    /// plusieurs secondes.
    @ObservationIgnored private var stemCache: [Set<Stem>: Spectrogram] = [:]
    /// Les relevés de batterie déjà faits, rangés comme les spectrogrammes.
    @ObservationIgnored private var percussionCache: [Set<Stem>: PercussionTrack] = [:]
    /// La carte des notes de la matrice affichée : le sommet de chaque demi-ton,
    /// colonne par colonne.
    ///
    /// C'est toute la dépense du relevé, et elle ne dépend que de la matrice et du
    /// diapason. Ce qui vient ensuite — compter combien de temps chaque demi-ton
    /// tient dans une mesure, comparer à cent trente-deux accords — se fait en
    /// quelques millisecondes sur un morceau entier. C'est ce qui permet au relevé de
    /// suivre le curseur de contraste et la borne d'une sélection qu'on tire.
    @ObservationIgnored private var noteMap = NoteMap.empty
    @ObservationIgnored private var noteMapToken = 0
    /// Ce qui a servi à relever la carte : le diapason et la netteté demandée.
    /// Changer l'un des deux la périme ; changer n'importe quel autre réglage, non.
    @ObservationIgnored private var noteMapKey: Int?
    /// Vrai quand un relevé est déjà demandé pour ce tour de boucle : tirer un
    /// curseur émet des dizaines de changements par seconde, et un seul relevé par
    /// image suffit.
    @ObservationIgnored private var chordsScheduled = false
    /// Un relevé est en route ; un autre est demandé derrière.
    @ObservationIgnored private var chordsRunning = false
    @ObservationIgnored private var chordsAgain = false
    @ObservationIgnored private var job: TravailAnnulable?
    /// Un préchargement des pistes voisines est en route.
    @ObservationIgnored private var precaching = false

    /// Les quatre pistes du morceau, décodées, en mémoire. Tout ce qui s'écoute et
    /// tout ce qui s'analyse en sort — il n'y a plus de fichier de combinaison.
    @ObservationIgnored private var banque: BanqueDePistes?
    /// Ce qu'on montrera dès que la banque sera montée. Rouvrir un morceau déjà
    /// séparé demande une seconde de lecture, pendant laquelle la demande attend
    /// plutôt que de se perdre.
    @ObservationIgnored private var enAttenteDeBanque: Set<Stem>?
    public private(set) var chargementDesPistes = false

    /// Ce que le moteur de séparation dit être en train de faire, et depuis quand.
    @ObservationIgnored private var etapeDeSeparation = ""
    @ObservationIgnored private var etapeDepuis = 0.0
    /// L'instant de la première tranche finie, et la fraction qu'elle portait : de
    /// quoi dire combien de temps il reste.
    @ObservationIgnored private var tranchesDepuis: Double?
    /// Battement d'une seconde pendant la séparation. Sans lui, un message qui
    /// compte les secondes ne serait redessiné qu'au changement d'étape.
    private var horlogeDeSeparation = 0

    /// La carte des notes de la **piste de basse seule**, quand elle existe.
    ///
    /// Elle ne sert qu'à une chose : retirer du relevé les harmoniques de la basse,
    /// qui sont souvent plus fortes que sa fondamentale et entraient dans l'accord
    /// comme des notes que personne n'a jouées. Voir
    /// `ChordVoicing.withoutBassHarmonics`.
    ///
    /// C'est la seule entorse au principe « le relevé lit l'image affichée », et elle
    /// est étroite : cette carte-ci ne peut rien **ajouter** au relevé, seulement en
    /// retirer ce que la basse suffit à expliquer. Ce qu'on voit reste ce qui décide ;
    /// on sait seulement, en plus, d'où une partie vient.
    @ObservationIgnored private var bassNoteMap = NoteMap.empty
    @ObservationIgnored private var bassMapKey: Int?

    /// Un calcul de pistes est en route : séparation, ou simple montée en mémoire de
    /// pistes déjà rangées. La ligne de batterie reste vide dans les deux cas — elle
    /// *pourrait* montrer le relevé du mixage, mais il est approximatif et serait
    /// remplacé dans la minute par celui de la piste isolée.
    public var calculEnCours: Bool { separating != nil || chargementDesPistes }

    public var isSeparated: Bool {
        guard let fingerprint = source?.fingerprint else { return false }
        // La banque d'abord : à la fin d'une séparation, les pistes sont en mémoire et
        // parfaitement utilisables alors qu'elles finissent seulement de s'écrire.
        if banque?.empreinte == fingerprint { return true }
        return pistes.estSepare(fingerprint)
    }

    public var hasModel: Bool { pistes.modeleDisponible }
    /// Les poids seuls — pour que le panneau dise lequel des deux manque.
    public var poidsPresents: Bool { pistes.poidsPresents }
    /// Ce que les pistes séparées occupent, et de quoi tout jeter. Le panneau les
    /// montre ; c'est le rangement qui sait.
    public func tailleDuCache() -> Int { pistes.tailleDuCache() }
    public func viderLeCache() { pistes.viderLeCache() }

    /// Garde ou retire une piste.
    ///
    /// Ce qui reste coché est **sommé** : retirer la voix laisse basse, batterie et
    /// reste, c'est-à-dire l'accompagnement. Décocher la dernière n'aurait rien à
    /// montrer ni à jouer, et n'est donc pas permis.
    public func toggle(_ stem: Stem) {
        guard stem != .mix else { return }
        var next = selection
        if next.contains(stem) { next.remove(stem) } else { next.insert(stem) }
        guard !next.isEmpty else { return }
        apply(next)
    }

    /// Remet toutes les pistes, donc le morceau tel qu'il est.
    public func restoreWholeMix() { apply(Self.everything) }

    private func apply(_ wanted: Set<Stem>) {
        guard wanted != selection, !wanted.isEmpty, source != nil else { return }
        separationError = nil

        // Rien de retiré : le fichier d'origine fait l'affaire, sans calcul.
        if wanted == Self.everything {
            selection = wanted
            show(wanted)
            return
        }
        guard let fingerprint = source?.fingerprint else { return }
        if banque?.empreinte == fingerprint || pistes.estSepare(fingerprint) {
            selection = wanted
            show(wanted)
            return
        }
        // Le modèle est embarqué dans l'application : son absence n'est pas un
        // problème d'utilisation mais de construction, et se dit comme tel. On ne
        // touche pas à la sélection — la déplacer vers des pistes qu'on ne peut pas
        // montrer serait mentir sur l'état des choses.
        guard pistes.modeleDisponible else {
            // Un défaut d'empaquetage, et il ne se voit que chez les autres : ici le
            // modèle est toujours là. C'est exactement le genre de panne pour
            // laquelle les rapports existent.
            Journal.erreur("les poids de la séparation manquent à l'application")
            separationError = T(.statutModeleAbsentApplication)
            status = separationError
            return
        }
        selection = wanted
        separate()
    }

    private func separate() {
        guard let source, let fingerprint = source.fingerprint, separating == nil else { return }
        // Sans modèle il n'y a rien à lancer, et ce n'est pas une raison pour se
        // plaindre à l'ouverture de chaque fichier : le manque est déjà dit quand on
        // demande une piste explicitement.
        guard pistes.modeleDisponible else { return }
        job?.cancel()
        separating = 0
        etape(T(.statutPreparation))
        tranchesDepuis = nil
        battre()
        // Le travail se compare à `job` avant chaque effet : un calcul annulé peut
        // encore avoir un rappel en vol, et il n'a plus rien à dire du morceau
        // ouvert entre-temps. La comparaison porte sur l'identité, d'où la
        // variable posée avant l'appel.
        var work: TravailAnnulable?
        work = pistes.separer(
            fichier: source.url, empreinte: fingerprint,
            avancement: { [weak self] p in
                guard let self, self.job === work else { return }
                if p.stage != self.etapeDeSeparation { self.etape(p.stage) }
                self.separating = p.fraction
                if p.fraction > 0, self.tranchesDepuis == nil {
                    self.tranchesDepuis = Horloge.maintenant()
                }
                self.status = self.messageDeSeparation ?? p.stage
            },
            fin: { [weak self] result in
                guard let self, self.job === work else { return }
                self.job = nil
                switch result {
                case .success(let montée):
                    // Les pistes sont là, en mémoire. Rien n'attend le disque : ce qui
                    // suit — le son, l'image, la ligne de batterie — se sert de la
                    // banque, et le FLAC s'écrit derrière.
                    self.banque = montée
                    self.separating = nil
                    self.enAttenteDeBanque = nil
                    self.show(self.selection)
                case .failure(let error):
                    Journal.erreur("séparation : \(error.localizedDescription)")
                    self.separating = nil
                    self.selection = Self.everything
                    self.separationError = error.localizedDescription
                    self.status = error.localizedDescription
                }
            },
            rangement: { [weak self] error in
                guard let self else { return }
                // Le rangement ne concerne plus ce qui est à l'écran ; il ne se dit que
                // pour ce qu'il change vraiment — un échec, qui obligera à recalculer
                // la prochaine fois.
                if let error {
                    Journal.erreur("rangement des pistes : \(error.localizedDescription)")
                    self.status = T(.statutPistesNonEnregistrees, error.localizedDescription)
                }
            })
        job = work
    }

    /// Change d'étape, et remet le compteur de secondes à zéro.
    private func etape(_ quoi: String) {
        etapeDeSeparation = quoi
        etapeDepuis = Horloge.maintenant()
    }

    /// Fait battre le message une fois par seconde tant qu'un calcul est en cours.
    ///
    /// C'est ce battement qui répond au reproche d'origine : l'ouverture du réseau est
    /// un seul appel opaque, dont il n'y a rien à mesurer, et une ligne immobile
    /// pendant quinze secondes passe pour une panne. Elle compte donc les secondes,
    /// ce qui ne prétend rien savoir de plus mais montre que le travail avance.
    private func battre() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.separating != nil || self.chargementDesPistes else { return }
            self.horlogeDeSeparation += 1
            self.status = self.messageDeSeparation ?? self.status
            self.battre()
        }
    }

    /// Ce qui se passe en ce moment, dit en toutes lettres.
    ///
    /// Les étapes ne se ressemblent pas : l'une dure une seconde, une autre quinze,
    /// une autre une minute la première fois — et une seule des trois se mesure. On
    /// dit donc **laquelle**, depuis **combien de temps**, et, quand c'est mesurable,
    /// combien il reste.
    private var messageDeSeparation: String? {
        _ = horlogeDeSeparation                 // le message compte les secondes
        if chargementDesPistes {
            return T(.statutLectureDesPistes)
        }
        guard let separating else { return nil }
        if separating > 0 {
            let pourcent = Int((separating * 100).rounded())
            guard let depuis = tranchesDepuis else {
                return T(.statutSeparationPourcent, "\(pourcent)")
            }
            let écoulé = Horloge.maintenant() - depuis
            guard separating > 0.05, écoulé > 2 else {
                return T(.statutSeparationPourcent, "\(pourcent)")
            }
            let restant = écoulé * (1 - separating) / separating
            return T(.statutSeparationRestant, "\(pourcent)", Self.duree(restant))
        }
        let écoulé = Horloge.maintenant() - etapeDepuis
        let quoi = etapeDeSeparation.isEmpty ? T(.statutSeparationEnCours) : etapeDeSeparation
        // Sous deux secondes, le compteur clignoterait pour rien.
        return écoulé < 2 ? quoi : "\(quoi) \(Self.duree(écoulé))"
    }

    /// Une durée en toutes lettres, sans décimale : personne ne lit « 43,7 s ».
    private static func duree(_ secondes: Double) -> String {
        let s = Int(secondes.rounded())
        if s < 60 { return T(.dureeSecondes, "\(max(s, 1))") }
        let m = s / 60, r = s % 60
        return r == 0 ? T(.dureeMinutes, "\(m)") : T(.dureeMinutesSecondes, "\(m)", "\(r)")
    }

    /// Monte en mémoire les pistes déjà rangées, puis montre ce qu'on attendait.
    private func chargerLaBanque(_ fingerprint: String) {
        guard !chargementDesPistes else { return }
        chargementDesPistes = true
        battre()
        pistes.chargerLesPistes(empreinte: fingerprint) { [weak self] montée in
            guard let self else { return }
            self.chargementDesPistes = false
            guard self.source?.fingerprint == fingerprint else { return }
            guard let montée else {
                // Les fichiers sont là mais ne se lisent pas : plutôt que de rester
                // sur une promesse, on revient au mixage et on le dit.
                Journal.erreur("les pistes séparées sont sur le disque mais illisibles")
                self.enAttenteDeBanque = nil
                self.selection = Self.everything
                self.separationError = T(.statutPistesIllisibles)
                self.status = self.separationError
                self.show(Self.everything)
                return
            }
            self.banque = montée
            let voulu = self.enAttenteDeBanque ?? self.selection
            self.enAttenteDeBanque = nil
            self.show(voulu)
        }
    }

    /// Charge et analyse la sélection, puis la met à l'écran et dans le lecteur.
    ///
    /// L'analyse est refaite sur le signal choisi plutôt que reprise du mixage :
    /// c'est tout l'intérêt de l'opération, un spectrogramme où ne restent que les
    /// partielles de ce qu'on écoute.
    /// Ce qui reste à **voir** dans le spectrogramme.
    ///
    /// Dès que les quatre pistes existent, la batterie sort de l'image : elle n'y
    /// apportait que des colonnes verticales qui traversent tout, sans hauteur à
    /// lire, et elle masquait les attaques des instruments qu'on cherche justement à
    /// relever. Elle a maintenant ses trois lignes en bas, qui disent d'elle ce
    /// qu'un spectrogramme ne sait pas dire.
    ///
    /// Elle reparaît dans un seul cas : quand elle est la seule piste gardée. Il n'y
    /// aurait alors rien d'autre à montrer, et une image noire ne rend service à
    /// personne.
    private func seen(_ wanted: Set<Stem>, separated: Bool) -> Set<Stem> {
        guard separated else { return wanted }
        let rest = wanted.subtracting([.drums])
        return rest.isEmpty ? wanted : rest
    }

    private func show(_ wanted: Set<Stem>) {
        guard let source else { return }
        // Un calcul encore en cours garde sa barre : revenir au mixage pendant la
        // séparation est le geste normal — on continue à travailler — et ce n'est
        // pas une raison pour perdre de vue ce qui tourne.
        let stillWorking = job != nil
        let fingerprint = source.fingerprint
        let separated = isSeparated
        let visible = seen(wanted, separated: separated)

        // Rien de retiré et rien de séparé : le fichier d'origine, tel quel.
        if visible == Self.everything, !separated {
            relevePercussion(Self.everything, from: source.mono, sampleRate: source.sampleRate)
            if !stillWorking { separating = nil }
            adopt(spectrogram: mixSpectrogram, ecoutant: .fichier(source.url))
            return
        }
        guard let fingerprint else { return }

        // Séparé, mais les pistes ne sont pas encore montées : on retient la demande
        // et on va les chercher. Une seconde, une fois par morceau.
        guard let banque, banque.empreinte == fingerprint else {
            enAttenteDeBanque = wanted
            chargerLaBanque(fingerprint)
            return
        }

        // La ligne de batterie et l'image ne viennent plus du même signal : l'une de
        // la piste de batterie seule, l'autre de tout le reste. Elles se demandent
        // donc séparément.
        relevePercussion(keeping: wanted, banque: banque)
        // Les accords, eux, se relèvent sur l'image : ils suivront tout seuls,
        // quand la nouvelle matrice sera adoptée.

        // Ce qui se joue reste ce qui est coché — décocher la batterie la fait
        // taire, et vide sa ligne du même geste. Tout coché, c'est le fichier
        // d'origine qui sort : la somme des quatre pistes lui ressemble beaucoup, mais
        // le morceau tel qu'il est ne se remplace pas par une approximation.
        let écoute: Ecoute = wanted == Self.everything
            ? .fichier(source.url)
            : .pistes(wanted)

        if let ready = stemCache[visible] {
            if !stillWorking { separating = nil }
            adopt(spectrogram: ready, ecoutant: écoute)
            return
        }

        // Le son d'abord, l'image ensuite : la somme est déjà en mémoire, il n'y a
        // aucune raison de faire attendre l'oreille le quart de seconde que coûte
        // l'analyse.
        adopt(spectrogram: spectrogram, ecoutant: écoute, gardantLImage: true)

        let name = Stem.label(for: wanted)
        status = T(.statutAnalyseDe, Stem.label(for: visible))
        let settings = analysis
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // La somme des pistes à voir est fabriquée ici, puis gardée : y revenir
            // ne doit pas coûter une seconde addition sur dix millions
            // d'échantillons.
            let mono = banque.melangeMono(visible)
            let matrix = OfflineAnalysis.run(samples: mono,
                                             sampleRate: banque.sampleRate,
                                             settings: settings)
            DispatchQueue.main.async {
                guard let self, self.selection == wanted,
                      self.banque === banque else { return }
                self.stemCache[visible] = matrix
                self.status = name
                self.adopt(spectrogram: matrix, ecoutant: .rien)
            }
        }
    }

    /// Ce qui doit sortir des haut-parleurs.
    private enum Ecoute {
        /// Le morceau tel qu'il est, lu depuis son fichier.
        case fichier(URL)
        /// La somme des pistes cochées, prise dans la banque.
        case pistes(Set<Stem>)
        /// Ne rien toucher : le son est déjà le bon, seule l'image change.
        case rien
    }

    /// Bascule l'image et le son sans rien perdre de ce qui est en cours : la
    /// fenêtre visible, la boucle et la position de lecture survivent au changement
    /// de piste, sans quoi comparer deux pistes serait insupportable.
    private func adopt(spectrogram matrix: Spectrogram, ecoutant écoute: Ecoute,
                       gardantLImage: Bool = false) {
        // L'image qu'on vient de montrer est le nouveau point de départ : ce qui est à
        // un clic d'ici se prépare en fond. En `defer` parce que la bascule du son
        // sort par plusieurs chemins, et qu'aucun ne doit sauter le préchargement.
        defer { if !gardantLImage { precacheStems() } }
        if !gardantLImage {
            spectrogram = matrix
            // L'image a changé : la carte des notes aussi, et les accords avec elle.
            releveCarteDesNotes()
            renderer?.layout = matrix.layout
            renderer?.upload(matrix)
            snap = nil
        }
        switch écoute {
        case .rien:
            return
        case .pistes(let gardées):
            // Cocher une piste ne change plus de fichier : elle change un masque que
            // le fil audio relit à chaque bloc. Rien à rouvrir, rien à reprogrammer,
            // et pas une image perdue.
            guard let banque else { return }
            player.charger(banque, gardant: gardées)
            player.setLoop(loopEnabled ? loop : nil)
        case .fichier(let url):
            let wasPlaying = player.isPlaying
            let at = playhead
            player.load(url: url)
            player.setLoop(loopEnabled ? loop : nil)
            if wasPlaying { player.play(from: at) } else { player.seek(to: at) }
        }
    }

    /// Ce que la ligne de batterie a à dire quand elle n'a rien à montrer. Une ligne
    /// vide sans un mot laisserait croire que le morceau n'a pas de batterie.
    ///
    /// C'est aussi elle qui porte l'avancement de la séparation. Cette place-là
    /// n'est pas un pis-aller : la séparation part toute seule à l'ouverture, et
    /// c'est précisément cette ligne qu'elle va remplir. Un relevé tiré du mixage
    /// s'afficherait entre-temps pour être remplacé une minute plus tard par un
    /// autre — mieux vaut une ligne vide qui dit ce qu'elle attend.
    ///
    /// **Elle dit l'étape, et pas seulement un pourcentage.** Une séparation, ce n'est
    /// pas une barre qui monte : c'est un décodage d'une seconde, une ouverture de
    /// réseau de quinze secondes dont rien ne se mesure — une minute la première fois,
    /// le temps de le compiler pour la machine —, puis quatre-vingts tranches qui,
    /// elles, se comptent. Un seul « 0 % » pour les seize premières secondes passait
    /// pour une panne. Voir `messageDeSeparation`.
    public var drumLaneNotice: String? {
        if let message = messageDeSeparation { return message }
        if percussionPending { return T(.statutReleveBatterie) }
        guard percussion.hits.isEmpty else { return nil }
        if isSeparated, !selection.contains(.drums) { return T(.statutBatterieRetiree) }
        return spectrogram.columnCount > 0 ? T(.statutAucunCoup) : nil
    }

    /// Prépare en fond les images qu'un seul clic peut demander.
    ///
    /// Le **son**, lui, n'a plus rien à précharger : il se somme à l'instant où il
    /// sort. Ne reste que l'image, un quart de seconde d'analyse, qu'on prend d'avance
    /// pendant qu'on regarde la précédente plutôt qu'au moment du clic.
    ///
    /// Seulement ce qui est **à un geste d'ici** : les quatre bascules depuis la
    /// sélection courante, soit trois images en pratique — retirer la batterie ne
    /// change pas ce qu'on voit, elle est déjà hors de l'image. Précalculer les
    /// quinze combinaisons remplirait la mémoire de matrices que personne ne
    /// demandera : chacune pèse une soixantaine de mégaoctets sur un morceau de huit
    /// minutes.
    ///
    /// En `utility` : c'est du travail d'avance, il ne doit rien prendre à ce qu'on
    /// est en train de faire.
    private func precacheStems() {
        guard !precaching, separating == nil, job == nil,
              let fingerprint = source?.fingerprint,
              let banque, banque.empreinte == fingerprint else { return }

        // La basse seule, d'abord : elle ne s'affiche presque jamais, mais le relevé
        // d'accords la lit à chaque intervalle pour en retirer les harmoniques.
        var todo: [Set<Stem>] = []
        if stemCache[[.bass]] == nil { todo.append([.bass]) }
        for stem in Stem.separated {
            var next = selection
            if next.contains(stem) { next.remove(stem) } else { next.insert(stem) }
            guard !next.isEmpty else { continue }
            let visible = seen(next, separated: true)
            guard stemCache[visible] == nil, !todo.contains(visible) else { continue }
            todo.append(visible)
        }
        guard !todo.isEmpty else { return }

        precaching = true
        let settings = analysis
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for visible in todo {
                // Pas de garde en cours de route : interroger le fil principal
                // depuis ici pour savoir si le morceau a changé demanderait un
                // `sync`, donc un interblocage à écrire un jour. Trois analyses de
                // trop sur un fichier qu'on vient de fermer coûtent une seconde en
                // `utility` ; la garde du dépôt, elle, est sûre.
                let matrix = OfflineAnalysis.run(samples: banque.melangeMono(visible),
                                                 sampleRate: banque.sampleRate,
                                                 settings: settings)
                DispatchQueue.main.async {
                    guard let self, self.source?.fingerprint == fingerprint else { return }
                    self.stemCache[visible] = matrix
                    // La basse vient d'arriver : le relevé peut enfin distinguer ses
                    // harmoniques de ce que jouent les autres.
                    if visible == [.bass] { self.releveCarteDeLaBasse() }
                }
            }
            DispatchQueue.main.async { self?.precaching = false }
        }
    }

    /// Ce qui nourrit la ligne de batterie, selon l'état des pistes.
    ///
    /// Trois cas, et un seul geste pour l'utilisateur — la bascule « batterie » :
    ///
    /// - **pistes séparées, batterie gardée** : la piste de batterie seule. C'est le
    ///   bon régime, celui où le relevé ne se trompe presque plus : plus de basse
    ///   pour allumer la grosse caisse, plus de guitare pour allumer la caisse
    ///   claire.
    /// - **pistes séparées, batterie décochée** : rien. On ne l'entend pas, on ne la
    ///   voit pas — la ligne reste vide plutôt que de continuer à montrer un relevé
    ///   qui ne correspond plus à ce qui sort des haut-parleurs.
    /// - **pas encore séparé** : le mixage, faute de mieux. Le relevé y est
    ///   approximatif, et c'est dit dans le README plutôt que caché.
    private func relevePercussion(keeping wanted: Set<Stem>, banque: BanqueDePistes) {
        guard wanted.contains(.drums) else {
            percussionToken += 1
            percussion = .empty
            percussionPending = false
            return
        }
        percussionToken += 1
        let token = percussionToken
        if let ready = percussionCache[[.drums]] {
            percussion = ready
            percussionPending = false
            reprendreLaGrille(ready)
            return
        }
        percussion = .empty
        percussionPending = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // La somme mono se fait ici : elle coûte une trentaine de millisecondes sur
            // un morceau long, et le fil principal n'a pas à les payer.
            let track = PercussionDetector.detect(samples: banque.melangeMono([.drums]),
                                                  sampleRate: banque.sampleRate)
            DispatchQueue.main.async {
                guard let self else { return }
                self.percussionCache[[.drums]] = track
                guard self.percussionToken == token else { return }
                self.percussion = track
                self.percussionPending = false
                // La piste de batterie est le seul endroit d'où le premier temps se
                // lit vraiment : c'est maintenant, et pas avant, qu'on peut reprendre
                // la grille.
                self.reprendreLaGrille(track)
            }
        }
    }

    // MARK: Les accords

    /// Hauteur de la bande où s'écrivent les noms d'accords, en bas de l'image.
    /// Partagée par le dessin et par la désignation à la souris — sans quoi la zone
    /// sensible et la zone dessinée finiraient par se décoller.
    public static var chordBandHeight: Double { Reglages.chordBandHeight }

    /// L'accord que la souris désigne, ou `nil`.
    ///
    /// Le survol porte sur **toute la durée** de l'accord, pas sur les quelques points
    /// de son nom : viser huit caractères ne serait pas un geste, ce serait un
    /// exercice. Le nom marque le début, la zone sensible couvre ce qu'il nomme.
    public var hoveredChord: ChordSegment? {
        guard showChords, !chords.isEmpty, let hover, let unit = gridUnit else { return nil }
        guard hover.y >= viewSize.height - Self.chordBandHeight,
              hover.y <= viewSize.height else { return nil }
        let pointed = time(atPoint: Double(hover.x))
        return chords.labels(from: time(atPoint: 0),
                             to: time(atPoint: Double(viewSize.width)),
                             grouping: max(1, Int(unit.rounded())))
            .first { pointed >= $0.start && pointed < $0.end && $0.chord != nil }
    }

    /// Les raies sur lesquelles l'accord survolé a été décidé.
    ///
    /// Pas de calcul, pas de cache : le relevé les a rangées avec le segment. C'est
    /// le point du nouveau relevé — ce qu'on entoure *est* ce qui a décidé du nom, et
    /// non une seconde lecture du spectre qui pourrait dire autre chose.
    public var hoveredChordNotes: [SoundingNote] { hoveredChord?.notes ?? [] }

    // MARK: Écoute d'un accord

    /// L'accord qui sonne en ce moment, pour ne pas le relancer à chaque pixel.
    @ObservationIgnored private var soundingChord: (start: Double, chord: Chord)?

    /// Survoler un nom d'accord le fait entendre.
    ///
    /// Ce qu'on entend est **exactement ce qu'on voit entouré** : les notes que le
    /// relevé a trouvées dans le spectre à cet endroit, dans l'octave où elles y
    /// sont. Jouer plutôt un accord de manuel — fondamentale, tierce, quinte au
    /// milieu du clavier — donnerait un son plus propre et répondrait à côté : la
    /// question posée en survolant est « est-ce bien cela que j'entends là ? », et
    /// il faut pour y répondre le même renversement et le même registre.
    ///
    /// Faute de notes visibles — un passage réglé trop sombre, un accord deviné sur
    /// une basse seule — on retombe sur l'accord de manuel, à partir de Do3. Rester
    /// muet ne dirait pas si l'on n'a rien trouvé ou si rien ne marche.
    private func updateChordTone() {
        guard !probing else { return }
        let segment = hoveredChord
        let current = segment.flatMap { s in s.chord.map { (start: s.start, chord: $0) } }
        guard current?.start != soundingChord?.start
                || current?.chord != soundingChord?.chord else { return }
        soundingChord = current
        guard let current else { return sinusoide.stop() }
        // En triangles, et non en sinusoïdes : un accord de sinusoïdes pures n'a pas
        // de timbre, se confond avec la musique qu'il commente et ne ressemble à
        // aucun instrument qui aurait pu le jouer. La raie désignée, elle, reste une
        // sinusoïde — voir `ToneWaveform`.
        sinusoide.play(chord: chordFrequencies(current.chord), waveform: .triangle)
    }

    /// Ce qu'on fait entendre : **toutes les raies retenues**, à leur octave.
    ///
    /// Toutes, y compris celles que l'accord ne contient pas — celles qui sont
    /// entourées en pointillés. Ne jouer que les notes du nom rendrait l'écoute plus
    /// jolie et la réponse fausse : la question posée en survolant est « est-ce bien
    /// cela qui est là ? », et il faut pour y répondre entendre ce qui est là.
    ///
    /// Les voix sont limitées ; quand il y a trop de raies, ce sont les plus fortes
    /// qui sonnent. Faute de raies — un passage réglé trop sombre — on retombe sur
    /// l'accord de manuel à partir de Do3 : rester muet ne dirait pas si l'on n'a
    /// rien trouvé ou si rien ne marche.
    private func chordFrequencies(_ chord: Chord) -> [Double] {
        let notes = hoveredChordNotes
        let midi: [Int] = notes.isEmpty
            ? chord.quality.intervals.map { 48 + chord.root + $0 }
            : notes.sorted { $0.level > $1.level }
                   .prefix(sinusoide.voixMaximales).map(\.midi).sorted()
        // Les raies retenues sont déjà transposées — elles viennent du relevé
        // affiché. Reste la fraction de demi-ton que l'arrondi a laissée de côté :
        // sans elle, un morceau recalé de trente cents s'entendrait battre contre
        // l'accord qu'on lui joue par-dessus.
        let reste = pow(2, (player.transpose - Double(demiTonsEntiers)) / 12)
        return midi.map { Pitch.frequency(ofMidi: Double($0),
                                          referenceA: display.referenceA) * reste }
    }

    /// Pourquoi la ligne d'accords est vide, quand elle l'est.
    public var chordNotice: String? {
        guard showChords, spectrogram.columnCount > 0 else { return nil }
        if chordsPending { return T(.statutReleveAccords) }
        guard chords.isEmpty else { return nil }
        if tempo == nil || (tempo?.bpm ?? 0) <= 0 { return T(.statutAccordsGrilleDabord) }
        return T(.statutAccordsRienDeTenu)
    }

    /// Relève la carte des notes de la matrice affichée, puis les accords.
    ///
    /// La carte est la seule partie chère — un balayage de la matrice entière — et
    /// elle ne dépend que de l'image et du diapason. Elle se refait donc à chaque
    /// changement de piste affichée, en tâche de fond, et le relevé qui la suit se
    /// refait, lui, à la moindre retouche de contraste : il est assez rapide pour ça.
    ///
    /// Le jeton écarte la carte d'une image qu'on a laissée derrière soi — changer de
    /// piste pendant qu'elle se calcule est le geste normal.
    private func releveCarteDesNotes() {
        noteMapToken += 1
        let token = noteMapToken
        noteMap = .empty
        chordsAgain = false
        guard spectrogram.columnCount > 0 else {
            poserLesAccords(.empty)
            chordsPending = false
            return
        }
        poserLesAccords(.empty)
        chordsPending = true
        let matrix = spectrogram
        let referenceA = display.referenceA
        let prominence = préférences.chords.prominence
        noteMapKey = Self.mapKey(referenceA: referenceA, prominence: prominence)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let map = NoteMap.build(matrix, referenceA: referenceA, prominence: prominence)
            DispatchQueue.main.async {
                guard let self, self.noteMapToken == token else { return }
                self.noteMap = map
                self.chordsPending = false
                self.releveAccords()
                // Le diapason ou la netteté ont pu changer : la carte de la basse
                // vieillit avec celle de l'image, et se refait sur la même clé.
                self.releveCarteDeLaBasse()
            }
        }
    }

    /// Devine les accords à partir des raies tenues de l'image.
    ///
    /// **Ce qui est affiché, et rien d'autre.** C'est le renversement du relevé
    /// précédent, qui lisait toujours la basse et l'accompagnement séparés quoi qu'on
    /// ait coché. L'ancien parti se défendait — « ce n'est pas une vue de ce qu'on
    /// écoute mais une lecture de ce qui est joué » — mais il rendait impossible la
    /// seule chose qui compte ici : qu'on puisse regarder l'image et comprendre le
    /// nom. Masquer la voix retire maintenant ses tenues du relevé, ce qui est
    /// souvent ce qu'on veut ; la remettre les y remet.
    private func releveAccords() {
        guard !noteMap.isEmpty, let tempo, tempo.bpm > 0 else {
            poserLesAccords(.empty)
            chordsPending = false
            return
        }
        // Un seul relevé à la fois, et un seul en attente derrière. Tirer un curseur
        // de contraste demande un relevé par image ; les empiler tous sur la file
        // ferait chauffer la machine pour jeter aussitôt tous les résultats sauf le
        // dernier.
        guard !chordsRunning else {
            chordsAgain = true
            return
        }
        chordsRunning = true
        let settings = préférences.chords
        // La boucle est la portée du relevé dès qu'elle existe, quelle que soit la
        // portée réglée : entourer un passage, c'est demander son accord.
        let selection = loop
        let map = noteMap
        let bass = voitLaBasse && !bassNoteMap.isEmpty ? bassNoteMap : nil
        let vue = display
        let token = noteMapToken
        if chords.isEmpty { chordsPending = true }
        // En tâche de fond, et pas par excès de prudence : à la mesure, le relevé
        // d'un morceau entier prend trente millisecondes, mais au temps il faut
        // recoudre sept cent cinquante décisions entre deux cent vingt-huit accords,
        // et le quart de seconde que cela demande se verrait comme un à-coup sous le
        // curseur qu'on est en train de tirer.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let track = ChordDetector.detect(map: map, display: vue, tempo: tempo,
                                             settings: settings, selection: selection,
                                             bass: bass)
            DispatchQueue.main.async {
                guard let self else { return }
                self.chordsRunning = false
                // La carte a changé sous nos pieds : ce relevé-ci ne décrit plus
                // l'image affichée.
                guard self.noteMapToken == token else { return }
                self.poserLesAccords(track)
                self.chordsPending = false
                if self.chordsAgain {
                    self.chordsAgain = false
                    self.releveAccords()
                }
            }
        }
    }

    private static func mapKey(referenceA: Double, prominence: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(referenceA)
        hasher.combine(prominence)
        return hasher.finalize()
    }

    /// Reprendre le relevé sur le morceau ouvert — après un tour de réglage, une
    /// sélection nouvelle, un contraste retouché.
    ///
    /// La carte des notes ne se refait que si ce qui la fabrique a bougé : le
    /// diapason, ou la netteté exigée d'une raie. Tout le reste se relit dessus.
    public func reloadChords() {
        let settings = préférences.chords
        if noteMapKey != Self.mapKey(referenceA: display.referenceA,
                                     prominence: settings.prominence) {
            releveCarteDesNotes()
        } else {
            releveAccords()
        }
    }

    /// La carte de la piste de basse seule, d'où le relevé tire de quoi écarter ses
    /// harmoniques.
    ///
    /// Trois conditions, et elles se lisent dans cet ordre : les pistes sont
    /// séparées, la basse est **à l'image** — la retirer doit retirer aussi son droit
    /// de veto — et sa matrice est déjà en mémoire. Sinon, le relevé s'en tient à
    /// l'explication par le grave, qui vaut pour tout le monde.
    private func releveCarteDeLaBasse() {
        guard voitLaBasse else {
            guard !bassNoteMap.isEmpty else { return }
            bassNoteMap = .empty
            bassMapKey = nil
            releveAccords()
            return
        }
        let referenceA = display.referenceA
        let prominence = préférences.chords.prominence
        let key = Self.mapKey(referenceA: referenceA, prominence: prominence)
        guard bassMapKey != key, let matrix = stemCache[[.bass]] else { return }
        bassMapKey = key
        let fingerprint = source?.fingerprint
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let map = NoteMap.build(matrix, referenceA: referenceA, prominence: prominence)
            DispatchQueue.main.async {
                guard let self, self.source?.fingerprint == fingerprint else { return }
                self.bassNoteMap = map
                self.releveAccords()
            }
        }
    }

    /// La basse est-elle dans ce qu'on regarde ?
    private var voitLaBasse: Bool {
        guard let fingerprint = source?.fingerprint,
              pistes.estSepare(fingerprint) else { return false }
        return seen(selection, separated: true).contains(.bass)
    }

    /// Le même, mais au plus une fois par tour de boucle.
    ///
    /// Tirer le curseur de contraste émet des dizaines de changements par seconde ;
    /// relever les accords à chacun serait refaire trente fois le même travail pour
    /// une seule image affichée.
    private func scheduleChords() {
        guard !chordsScheduled else { return }
        chordsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chordsScheduled = false
            self.releveAccords()
        }
    }

    /// Relève la batterie du signal courant, en tâche de fond.
    ///
    /// À part de l'analyse plutôt qu'à sa suite : le relevé coûte à peu près autant
    /// que le spectrogramme lui-même, et il n'y a aucune raison de retarder d'autant
    /// l'affichage de l'image. La ligne apparaît un instant après le reste.
    ///
    /// Le jeton écarte le résultat d'un relevé qu'on a laissé derrière soi — changer
    /// de piste ou de morceau pendant qu'il tourne est le geste normal. Le résultat
    /// est tout de même rangé au passage : il aura servi si l'on y revient.
    private func relevePercussion(_ wanted: Set<Stem>, from samples: [Float],
                                  sampleRate: Double) {
        percussionToken += 1
        let token = percussionToken
        if let ready = percussionCache[wanted] {
            percussion = ready
            percussionPending = false
            return
        }
        percussion = .empty
        percussionPending = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let track = PercussionDetector.detect(samples: samples, sampleRate: sampleRate)
            DispatchQueue.main.async {
                guard let self else { return }
                self.percussionCache[wanted] = track
                guard self.percussionToken == token else { return }
                self.percussion = track
                self.percussionPending = false
            }
        }
    }

    /// Efface les pistes de ce morceau — de quoi refaire la séparation si le
    /// résultat déçoit, sans aller fouiller dans Application Support.
    public func forgetStems() {
        guard let fingerprint = source?.fingerprint else { return }
        job?.cancel()
        job = nil
        separating = nil
        stemCache.removeAll()
        bassNoteMap = .empty
        bassMapKey = nil
        percussionCache.removeAll()
        // La banque aussi : sans cela, « effacer les pistes » les laisserait à l'écran
        // et dans les haut-parleurs, et le morceau passerait encore pour séparé.
        banque = nil
        enAttenteDeBanque = nil
        pistes.oublierLesPistes(empreinte: fingerprint)
        selection = Self.everything
        show(Self.everything)
        status = T(.statutPistesEffacees)
    }

    // MARK: Actions

    public func seek(to time: Double) {
        playhead = min(max(time, 0), duration)
        player.seek(to: playhead)
    }

    // MARK: Boucle

    private func pushLoop() {
        player.setLoop(loopEnabled ? loop : nil)
    }

    /// Définit la boucle à partir de deux instants, dans n'importe quel ordre.
    /// Par défaut les bornes se posent sur la grille ; ⌘ pendant le geste les
    /// laisse libres, comme dans les séquenceurs.
    public func setLoop(from a: Double, to b: Double, snapping: Bool = false) {
        loop = LoopEditing.made(from: a, to: b, duration: duration,
                                snap: snapper(snapping))
    }

    /// Aimante ou laisse libre, selon le geste en cours.
    private func snapper(_ snapping: Bool) -> (Double) -> Double {
        snapping ? { [self] in snapToGrid($0) } : { $0 }
    }

    public func dragLoop(edge: LoopEdge, to time: Double, snapping: Bool) {
        guard let loop else { return }
        self.loop = LoopEditing.resized(loop, edge: edge, to: time, duration: duration,
                                        snap: snapper(snapping))
    }

    public func moveLoop(startingAt time: Double, snapping: Bool) {
        guard let loop else { return }
        self.loop = LoopEditing.moved(loop, startingAt: time, duration: duration,
                                      snap: snapper(snapping))
    }

    /// Pose une borne au passage de la tête de lecture, en gardant l'autre.
    public func setLoopStart(at time: Double) {
        setLoop(from: time, to: loop.map { max($0.upperBound, time + 0.2) } ?? min(time + 4, duration))
    }

    public func setLoopEnd(at time: Double) {
        setLoop(from: loop.map { min($0.lowerBound, time - 0.2) } ?? max(time - 4, 0), to: time)
    }

    /// Cale la boucle sur les mesures qui l'encadrent — c'est presque toujours ce
    /// qu'on veut quand on travaille un passage.
    public func snapLoopToBars() {
        guard let loop, let tempo, tempo.barSeconds > 0 else { return }
        let first = (tempo.beat(at: loop.lowerBound) / Double(tempo.beatsPerBar)).rounded(.down)
        let last = (tempo.beat(at: loop.upperBound) / Double(tempo.beatsPerBar)).rounded(.up)
        setLoop(from: tempo.time(ofBeat: first * Double(tempo.beatsPerBar)),
                to: tempo.time(ofBeat: last * Double(tempo.beatsPerBar)))
    }

    // MARK: Tempo

    /// Relance l'estimation, avec la signature choisie par l'utilisateur — ce qui
    /// en fait autre chose qu'un simple retour en arrière : à 3/4, la recherche du
    /// premier temps ne cherche pas au même endroit qu'à 4/4.
    public func recomputeTempo() {
        guard spectrogram.columnCount > 0 else { return }
        let matrix = spectrogram
        let signature = beatsPerBar
        // Redemander la grille, c'est redonner la main au calcul : ce qui suivra —
        // la reprise sur la batterie — a de nouveau le droit de la corriger.
        grilleAutomatique = true
        let batterie = percussion
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var grid = TempoEstimator.estimate(matrix, beatsPerBar: signature)
            if let estimée = grid,
               let reprise = PremierTemps.affiner(estimée, batterie: batterie, image: matrix) {
                grid = reprise
            }
            DispatchQueue.main.async { self?.tempo = grid }
        }
    }

    /// Reprend la grille sur la piste de batterie, maintenant qu'elle existe.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// POURQUOI DEUX ESTIMATIONS, ET PAS UNE
    ///
    /// La première se fait à l'ouverture, sur le mixage : il faut bien une grille
    /// tout de suite, la séparation dure une minute, et on ne va pas laisser
    /// l'image sans mesures pendant ce temps-là. Elle trouve la période, ce dont
    /// le mixage est capable.
    ///
    /// La seconde se fait ici, quand la piste de batterie est là. Elle trouve le
    /// **premier temps**, ce dont le mixage n'est pas capable : il faut pour cela
    /// savoir que ce coup-ci est une grosse caisse et celui-là une caisse claire.
    /// Voir `PremierTemps`, qui dit le détail.
    ///
    /// Elle ne touche à rien si la grille a été réglée à la main, et ne touche à
    /// rien non plus si la batterie n'a rien de net à dire — dans les deux cas,
    /// c'est la grille reçue qui reste.
    /// ─────────────────────────────────────────────────────────────────────────
    private func reprendreLaGrille(_ batterie: PercussionTrack) {
        guard grilleAutomatique, let grille = tempo, grille.bpm > 0,
              spectrogram.columnCount > 0, !batterie.hits.isEmpty else { return }
        let image = spectrogram
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let reprise = PremierTemps.affiner(grille, batterie: batterie,
                                                     image: image) else { return }
            DispatchQueue.main.async {
                // La grille a pu changer sous nos pieds — un autre morceau, un
                // réglage à la main : ce calcul-ci ne décrit plus rien.
                guard let self, self.grilleAutomatique, self.tempo == grille else { return }
                self.tempo = reprise
                self.status = T(.statutGrilleReprise)
            }
        }
    }

    /// Tempo saisi à la main. Ce n'est plus une estimation mais un choix, d'où la
    /// confiance remise à zéro : le « ≈ » qui prévient d'une grille incertaine n'a
    /// plus lieu d'être quand c'est l'utilisatrice qui l'a dictée.
    public func setTempo(_ value: Double) {
        guard value.isFinite else { return }
        grilleAutomatique = false
        guard var grid = tempo else {
            tempo = TempoGrid(bpm: min(max(value, 20), 400), origin: playhead)
            return
        }
        grid.bpm = min(max(value, 20), 400)
        grid.confidence = 0
        tempo = grid
    }

    public func nudgeTempo(by delta: Double) {
        guard var grid = tempo else { return }
        grilleAutomatique = false
        grid.bpm = min(max(grid.bpm + delta, 20), 400)
        tempo = grid
    }

    /// Pose le premier temps à l'endroit de la tête de lecture.
    public func setDownbeatAtPlayhead() {
        grilleAutomatique = false
        guard var grid = tempo else {
            tempo = TempoGrid(bpm: 120, origin: playhead)
            return
        }
        grid.origin = playhead
        tempo = grid
    }

    public var beatsPerBar: Int {
        get { tempo?.beatsPerBar ?? 4 }
        set {
            guard var grid = tempo else { return }
            grilleAutomatique = false
            grid.beatsPerBar = max(1, newValue)
            tempo = grid
        }
    }

    // MARK: Lecture

    public func togglePlayback() {
        if player.isPlaying {
            player.pause()
            playhead = player.currentTime
        } else {
            player.play(from: playhead)
        }
    }

    // MARK: La tonalité

    /// La géométrie de l'axe des fréquences **telle qu'on l'entend**.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// TRANSPOSER NE DÉPLACE RIEN, CELA RENOMME
    ///
    /// La matrice est faite sur le signal d'origine et ne bouge pas : une raie
    /// analysée à 440 Hz reste à sa ligne. Mais deux demi-tons plus haut, c'est
    /// 494 Hz qui sort du haut-parleur, et c'est donc 494 Hz que l'axe doit nommer.
    /// Sans cela, la note lue sous le curseur, la couleur de la raie, la sinusoïde
    /// qu'on entend en la désignant et le nom de l'accord désignent quatre hauteurs
    /// pour un seul son.
    ///
    /// Tout passe par ici, et c'est ce qui garde l'ensemble d'aplomb : les repères
    /// d'octave, la conversion point ↔ fréquence, l'aimantation sur une raie. Le
    /// filtre de bande, lui, ne passe pas par ici et c'est délibéré — il coupe le
    /// signal **avant** l'étireur, donc dans les fréquences de l'analyse.
    /// ─────────────────────────────────────────────────────────────────────────
    public var geometrieEntendue: BinLayout {
        var géométrie = spectrogram.layout
        let facteur = facteurDeTransposition
        guard facteur != 1 else { return géométrie }
        géométrie.minFrequency *= facteur
        géométrie.maxFrequency *= facteur
        return géométrie
    }

    /// Ce par quoi une fréquence de l'analyse est multipliée pour donner celle qu'on
    /// entend.
    private var facteurDeTransposition: Double { pow(2, player.transpose / 12) }

    /// Vrai tant que la grille métrique est celle du calcul, et que personne n'y a
    /// touché.
    ///
    /// Ce qui a été réglé à la main ne se fait pas reprendre par une machine : poser
    /// soi-même le premier temps sur un passage rubato, puis voir la séparation le
    /// déplacer une minute plus tard, serait la pire des surprises. Une session
    /// retrouvée compte pour un réglage à la main — on ne sait pas ce qui, dedans,
    /// a été touché, et le supposer intact reviendrait à défaire du travail.
    @ObservationIgnored private var grilleAutomatique = true

    /// Ce que l'affichage montre en ce moment, pour ne le refaire que quand la
    /// réglette a bougé.
    @ObservationIgnored private var tonaliteAffichee = 0.0

    /// Range un relevé et l'accorde à la tonalité du moment. **La seule porte** :
    /// poser `chords` directement laisserait un relevé à la hauteur de l'analyse au
    /// milieu d'un affichage transposé, et le nom écrit sous l'image contredirait la
    /// couleur des raies qu'il commente.
    private func poserLesAccords(_ relevé: ChordTrack) {
        relevéDesAccords = relevé
        chords = relevé.transposé(de: demiTonsEntiers)
    }

    /// Remet l'affichage à la hauteur qu'on entend. Appelée à chaque image, elle ne
    /// travaille que quand la réglette a bougé.
    private func accorderALaTonalite() {
        guard player.transpose != tonaliteAffichee else { return }
        tonaliteAffichee = player.transpose
        chords = relevéDesAccords.transposé(de: demiTonsEntiers)
    }

    /// Le décalage **entier**, celui qui renomme notes et accords. Une transposition
    /// d'un demi-ton et demi ne correspond à aucun nom ; l'arrondi est la seule
    /// réponse possible, et c'est aussi celle que la réglette encourage — ses crans
    /// tombent sur les demi-tons.
    private var demiTonsEntiers: Int { Int(player.transpose.rounded()) }

    /// Fréquence correspondant à une ordonnée de la vue (comptée depuis le haut).
    public func frequency(atPoint y: Double) -> Double {
        let bin = viewport.bin(atPoint: y, height: Double(viewSize.height))
        return geometrieEntendue.frequency(atBin: bin)
    }

    public func time(atPoint x: Double) -> Double {
        (viewport.column(atPoint: x) + 0.5) * spectrogram.secondsPerColumn
    }

    /// Abscisse d'un instant dans la vue, en points.
    public func point(ofTime t: Double) -> Double {
        viewport.point(ofColumn: spectrogram.column(atTime: t))
    }

    /// Ordonnée d'une fréquence dans la vue, en points depuis le haut.
    ///
    /// La fréquence attendue est celle qu'on **entend**, comme celle que rend
    /// `frequency(atPoint:)` : les deux sont réciproques, transposition comprise, et
    /// tout ce qui se pose sur l'image le reste quand la réglette bouge.
    public func point(ofFrequency f: Double) -> Double {
        viewport.point(ofBin: geometrieEntendue.bin(of: f), height: Double(viewSize.height))
    }

    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let cents = Int((seconds - Double(total)) * 100)
        return String(format: "%d:%02d,%02d", total / 60, total % 60, cents)
    }
}
