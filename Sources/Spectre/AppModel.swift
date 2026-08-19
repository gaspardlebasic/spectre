import AppKit
import Foundation
import Observation
import SpectreCore
import SpectreMac
import UniformTypeIdentifiers

/// État de l'application : le fichier, sa matrice, la fenêtre visible, la lecture.
@Observable final class AppModel {
    private(set) var source: AudioSource?
    private(set) var spectrogram = Spectrogram.empty

    var analysis = AnalysisSettings()
    var display = DisplaySettings()
    var viewport = Viewport()

    /// `var` et non `let` : SwiftUI n'accepte de fabriquer une liaison vers
    /// `player.speed` que si le chemin est modifiable de bout en bout.
    var player = Player()

    /// Position de la tête de lecture, en secondes.
    var playhead: Double = 0
    /// Position du curseur dans la vue (en points, depuis le coin haut-gauche).
    var hover: CGPoint? {
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
    var pointerOverControls = false {
        didSet {
            guard pointerOverControls else { return }
            hover = nil
        }
    }
    /// Raie sur laquelle le curseur s'est aimanté.
    var snap: SnapTarget?

    /// Passage joué en boucle.
    var loop: ClosedRange<Double>? { didSet { pushLoop() } }
    var loopEnabled = true { didSet { pushLoop() } }

    /// Grille métrique estimée au chargement, ajustable ensuite.
    ///
    /// C'est elle qui découpe le relevé des accords — un accord par temps — donc en
    /// changer le refait. Un tempo faux ou un « un » mal placé donnerait des accords
    /// à cheval sur deux harmonies, ce qui ne ressemble à rien : corriger la grille
    /// corrige les accords du même geste.
    var tempo: TempoGrid? {
        didSet {
            guard tempo != oldValue else { return }
            releveAccords(separated: isSeparated, fingerprint: source?.fingerprint)
        }
    }

    /// Ce que la batterie joue : une ligne par voie, sous le spectrogramme.
    ///
    /// Dès que les quatre pistes existent, le relevé se fait sur la **piste de
    /// batterie seule** — et la batterie sort de l'image du même geste. C'est le
    /// bon régime : sur un mixage entier, tout ce qui claque dans le médium
    /// alimente la ligne de caisse claire et l'attaque d'une note de basse s'y lit
    /// comme un coup. Voir `relevePercussion(keeping:separated:fingerprint:mix:)`.
    private(set) var percussion = PercussionTrack.empty
    /// Vrai tant que le relevé du morceau courant n'est pas fini.
    private(set) var percussionPending = false
    /// Montrer la ligne de batterie. Volontairement **hors** des réglages conservés :
    /// c'est une vue en cours d'essai, et lui faire une place dans le format des
    /// sessions rendrait illisibles celles déjà écrites.
    var showDrumLane = true
    @ObservationIgnored private var percussionToken = 0

    /// Les accords devinés, un par temps. Vide tant que la séparation n'a pas eu
    /// lieu : il y faut la basse et l'accompagnement **séparément**.
    private(set) var chords = ChordTrack.empty
    private(set) var chordsPending = false
    /// Écrire les noms d'accords sous la grille.
    var showChords = true
    @ObservationIgnored private var chordToken = 0

    /// Avancement de l'analyse (0…1), `nil` quand rien n'est en cours.
    var progress: Double?
    var status: String?

    /// Sinusoïde d'écoute, tenue tant que le bouton reste enfoncé.
    @ObservationIgnored private let tone = ToneGenerator()
    @ObservationIgnored private var probing = false

    /// Taille de la vue en points, tenue à jour par le rendu.
    @ObservationIgnored var viewSize = CGSize(width: 1200, height: 700)
    @ObservationIgnored weak var renderer: SpectrogramRenderer?
    /// Évite de recadrer une deuxième fois si la vue change de taille après coup.
    @ObservationIgnored private var needsFit = false
    /// Dernière session écrite sur le disque, et depuis quand elle est périmée.
    @ObservationIgnored private var savedSession: FileSession?
    @ObservationIgnored private var staleSince: CFTimeInterval?

    init() {
        // Quitter l'application ne doit pas coûter les réglages en cours : la
        // position de lecture, elle, n'est écrite qu'à ce moment-là.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.flushSession()
        }
    }

    var title: String { source?.name ?? "Spectre" }
    var fileURL: URL? { source?.url }
    var duration: Double { source?.duration ?? 0 }

    // MARK: Ouverture

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = "Ouvrir"
        panel.message = "Choisir un fichier audio à transcrire"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: Les morceaux récents

    /// Ce que porte « Fichier ▸ Ouvrir récemment ».
    ///
    /// La liste vient de `RecentFiles`, qui est la nôtre — celle d'AppKit ne survit
    /// pas au redémarrage ici. On la tient tout de même à jour en parallèle, pour le
    /// menu du Dock et les « Éléments récents » du menu Pomme, qui ne connaissent
    /// qu'elle.
    private(set) var recentFiles: [URL] = RecentFiles.all()

    func clearRecentFiles() {
        RecentFiles.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentFiles = []
    }

    /// Rouvre le dernier morceau consulté, au démarrage — **sauf si le lancement en
    /// désignait déjà un**.
    ///
    /// Le délai n'est pas de la superstition. Un double-clic dans le Finder délivre
    /// son fichier par un évènement qui arrive *après* l'apparition de la fenêtre :
    /// ouvrir le morceau précédent tout de suite reviendrait à en analyser un pour
    /// rien, puis à le remplacer sous les yeux de l'utilisatrice — et, depuis que la
    /// séparation est automatique, à lancer une minute de GPU sur le mauvais morceau.
    /// On laisse donc passer le temps de cet évènement, et l'on ne fait rien si
    /// quelque chose est arrivé entre-temps.
    func reopenLastFile() {
        guard source == nil, progress == nil, let last = recentFiles.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.source == nil, self.progress == nil else { return }
            self.open(last)
        }
    }

    func open(_ url: URL) {
        guard progress == nil else { return }
        RecentFiles.note(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentFiles = RecentFiles.all()
        status = "Lecture du fichier…"
        progress = 0
        player.stop()
        playhead = 0

        let settings = analysis
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            let loaded: AudioSource
            do {
                loaded = try AudioSource.load(url)
            } catch {
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
        // Le relevé des accords est rangé sous la grille métrique, qui n'appartient
        // pas au morceau : deux morceaux à 120 BPM partagent la clé. Sans ce vidage,
        // le second afficherait les accords du premier — une erreur silencieuse et
        // parfaitement crédible à l'écran.
        chordCache.removeAll()
        chords = .empty
        chordsPending = false

        let saved = source.fingerprint.flatMap { SessionStore.load($0) }
        if let saved {
            // Ce que l'utilisatrice a réglé l'emporte sur ce que l'analyse propose.
            display = saved.display
            self.tempo = saved.tempo ?? tempo
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
            loop = nil
            playhead = 0
            needsFit = true
            fitIfNeeded()
            // Rien de connu non plus sur l'allure de l'enregistrement : on la
            // mesure plutôt que d'imposer un compromis.
            applyAutoContrast(wholePiece: true)
        }
        savedSession = currentSession()
        staleSince = nil

        let ratio = source.duration / max(elapsed, 0.001)
        status = String(format: "%@ — %@, analysé en %.1f s (×%.0f temps réel)%@",
                        source.name, Self.format(source.duration), elapsed, ratio,
                        saved != nil ? " · réglages retrouvés" : "")

        // Les pistes de ce morceau existent peut-être déjà, d'une séance
        // précédente : la batterie sort alors de l'image et va nourrir sa ligne,
        // sans rien avoir à demander. Sinon on s'en tient au mixage qu'on vient
        // d'analyser — repasser par `show` ne ferait que téléverser une deuxième
        // fois la même matrice.
        if source.fingerprint.map(StemStore.isSeparated) == true {
            // Rouvrir un morceau le remet en tête : le ménage du cache s'appuie sur
            // cette date, et jeter celui sur lequel on travaille serait le comble.
            source.fingerprint.map(StemStore.markUsed)
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
        let current = currentSession()
        guard current.withoutPlayhead != savedSession?.withoutPlayhead else {
            staleSince = nil
            return
        }
        let now = CACurrentMediaTime()
        guard let since = staleSince else { staleSince = now; return }
        guard now - since > 1 else { return }
        SessionStore.save(current, for: fingerprint)
        savedSession = current
        staleSince = nil
    }

    /// Écrit sans attendre — changement de morceau, ou fermeture de l'application.
    func flushSession() {
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
    func tick(viewSize: CGSize) {
        let resized = abs(viewSize.width - self.viewSize.width) > 0.5
            || abs(viewSize.height - self.viewSize.height) > 0.5
        self.viewSize = viewSize
        if needsFit { fitIfNeeded() }

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
    var visibleOctaves: Double {
        guard spectrogram.binCount > 0 else { return 0 }
        return Double(viewSize.height) * viewport.binsPerPoint
            / max(spectrogram.layout.binsPerOctave, 1)
    }

    /// Zoom vertical, 1 = tout le spectre tient dans la vue.
    ///
    /// Le curseur zoome autour du **milieu de la vue** : c'est le seul point fixe
    /// qui ait un sens quand le geste ne désigne aucun endroit de l'image, alors
    /// que le pincement, lui, s'ancre sous le doigt.
    var verticalZoom: Double {
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
    /// Une seule règle plutôt que deux boutons : au cadrage d'ensemble, « ce qu'on
    /// a sous les yeux » est le morceau entier, et le réglage vaut pour lui.
    func applyAutoContrast(wholePiece: Bool = false) {
        guard spectrogram.columnCount > 0 else { return }
        let found = AutoContrast.settings(basedOn: display, in: spectrogram,
                                          columns: wholePiece ? nil : visibleColumns,
                                          bins: wholePiece ? nil : visibleBins)
        guard let found else { return }
        display = found
    }

    // MARK: Grille

    /// Pas de la grille actuellement dessinée, en temps. `nil` quand le zoom ne
    /// permet plus d'en montrer une.
    ///
    /// Une seule définition sert au tracé *et* à l'aimantation : ce sur quoi la
    /// boucle se cale est exactement ce qu'on voit, comme dans un séquenceur.
    var gridUnit: Double? {
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

    func snapToGrid(_ time: Double) -> Double {
        guard let tempo, let unit = snapUnit else { return time }
        return tempo.snap(time, unit: unit)
    }

    private func updateSnap() {
        var found: SnapTarget?
        if let hover, spectrogram.columnCount > 0 {
            found = Snapping.nearest(to: hover, in: spectrogram, viewport: viewport,
                                     display: display, viewSize: viewSize)
        }
        if found != snap { snap = found }
        // La sinusoïde suit l'aimantation : elle se tait donc d'elle-même dès que
        // le curseur passe sur une région que les réglages rendent noire.
        if probing { tone.play(found?.frequency) }
    }

    // MARK: Écoute d'une raie

    /// Fait sonner la raie désignée, et la suit tant que le bouton reste enfoncé.
    func beginProbe(at point: CGPoint) {
        hover = point
        probing = true
        updateSnap()
    }

    func endProbe() {
        guard probing else { return }
        probing = false
        tone.stop()
    }

    /// Marge, en fraction de la largeur, que la tête de lecture ne doit pas franchir.
    private static let margin = 0.1
    /// Durée du tourne-page.
    private static let turnDuration = 0.32

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
        guard x > width * (1 - Self.margin) || x < width * Self.margin else { return }
        turnPage(to: column - width * Self.margin * viewport.columnsPerPoint)
    }

    /// Tourne-page en cours : d'où, vers où, depuis quand.
    @ObservationIgnored private var turn: (from: Double, to: Double, start: CFTimeInterval)?

    private func turnPage(to startColumn: Double) {
        // La destination est recadrée d'avance : en fin de fichier elle se confond
        // avec la position courante, et il ne se passe alors rien du tout plutôt
        // qu'une animation relancée à chaque image contre la butée.
        let target = clamped(startColumn)
        guard abs(target - viewport.startColumn) > 0.5 else { return }
        turn = (from: viewport.startColumn, to: target, start: CACurrentMediaTime())
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
    func cancelTurn() { turn = nil }

    private func advanceTurn() {
        guard let turn else { return }
        let elapsed = CACurrentMediaTime() - turn.start
        let t = min(max(elapsed / Self.turnDuration, 0), 1)
        let eased = t * t * (3 - 2 * t)          // départ et arrivée en douceur
        viewport.startColumn = turn.from + (turn.to - turn.from) * eased
        if t >= 1 { self.turn = nil }
        clampViewport()
    }

    func clampViewport() {
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
    private(set) var selection: Set<Stem> = AppModel.everything

    /// Tout garder, c'est ne rien retirer.
    static let everything = Set(Stem.separated)
    /// Vrai quand rien n'est retiré : le morceau d'origine suffit alors, et il est
    /// plus fidèle que la somme de ses parts — la séparation ne conserve pas
    /// exactement le signal.
    var isWholeMix: Bool { selection == Self.everything }
    /// Avancement de la séparation, puis de l'analyse de la piste (0…1).
    private(set) var separating: Double?
    private(set) var separationError: String?

    @ObservationIgnored private var mixSpectrogram = Spectrogram.empty
    /// Les spectrogrammes des pistes déjà regardées, gardés en mémoire : y revenir
    /// doit être instantané, alors que les recalculer coûterait chaque fois
    /// plusieurs secondes.
    @ObservationIgnored private var stemCache: [Set<Stem>: Spectrogram] = [:]
    /// Les relevés de batterie déjà faits, rangés comme les spectrogrammes.
    @ObservationIgnored private var percussionCache: [Set<Stem>: PercussionTrack] = [:]
    /// Les relevés d'accords déjà faits, rangés par grille métrique — c'est elle qui
    /// découpe, donc en changer change le relevé, et y revenir doit être immédiat.
    @ObservationIgnored private var chordCache: [TempoGrid: ChordTrack] = [:]
    @ObservationIgnored private var job: SeparationJob?

    var isSeparated: Bool {
        guard let fingerprint = source?.fingerprint else { return false }
        return StemStore.isSeparated(fingerprint)
    }

    var hasModel: Bool { StemStore.hasModel }

    /// Garde ou retire une piste.
    ///
    /// Ce qui reste coché est **sommé** : retirer la voix laisse basse, batterie et
    /// reste, c'est-à-dire l'accompagnement. Décocher la dernière n'aurait rien à
    /// montrer ni à jouer, et n'est donc pas permis.
    func toggle(_ stem: Stem) {
        guard stem != .mix else { return }
        var next = selection
        if next.contains(stem) { next.remove(stem) } else { next.insert(stem) }
        guard !next.isEmpty else { return }
        apply(next)
    }

    /// Remet toutes les pistes, donc le morceau tel qu'il est.
    func restoreWholeMix() { apply(Self.everything) }

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
        if StemStore.isSeparated(fingerprint) {
            selection = wanted
            show(wanted)
            return
        }
        // Le modèle est embarqué dans l'application : son absence n'est pas un
        // problème d'utilisation mais de construction, et se dit comme tel. On ne
        // touche pas à la sélection — la déplacer vers des pistes qu'on ne peut pas
        // montrer serait mentir sur l'état des choses.
        guard StemStore.hasModel else {
            separationError = "Modèle absent de l'application : lancer ./modele.sh puis ./build.sh."
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
        guard StemStore.hasModel else { return }
        job?.cancel()
        let work = SeparationJob()
        job = work
        separating = 0
        status = "Séparation des pistes…"
        work.run(fileAt: source.url, fingerprint: fingerprint,
                 separator: DemucsSeparator(),
                 // L'étape est reprise telle quelle : les dix premières secondes se
                 // passent avant la première tranche, et la barre y reste à zéro sans
                 // rien avoir à dire d'autre.
                 progress: { [weak self] p in
                     guard let self, self.job === work else { return }
                     self.separating = p.fraction * 0.8
                     self.status = p.stage
                 },
                 completion: { [weak self] result in
                     guard let self, self.job === work else { return }
                     self.job = nil
                     switch result {
                     case .success:
                         self.show(self.selection)
                     case .failure(let error):
                         self.separating = nil
                         self.selection = AppModel.everything
                         self.separationError = error.localizedDescription
                         self.status = error.localizedDescription
                     }
                 })
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
        let separated = fingerprint.map(StemStore.isSeparated) ?? false
        let visible = seen(wanted, separated: separated)

        // La ligne de batterie et l'image ne viennent plus du même signal : l'une de
        // la piste de batterie seule, l'autre de tout le reste. Elles se demandent
        // donc séparément.
        relevePercussion(keeping: wanted, separated: separated, fingerprint: fingerprint,
                         mix: source)
        releveAccords(separated: separated, fingerprint: fingerprint)

        // Ce qui se joue reste ce qui est coché — décocher la batterie la fait
        // taire, et vide sa ligne du même geste.
        let heard: URL? = wanted == Self.everything
            ? source.url
            : fingerprint.flatMap { try? StemStore.combined(wanted, for: $0) }

        // Rien de retiré et rien de séparé : le fichier d'origine, tel quel.
        if visible == Self.everything, !separated {
            if !stillWorking { separating = nil }
            adopt(spectrogram: mixSpectrogram, playing: heard)
            return
        }
        guard let fingerprint else { return }
        if let ready = stemCache[visible] {
            if !stillWorking { separating = nil }
            adopt(spectrogram: ready, playing: heard)
            return
        }

        separating = separating ?? 0.8
        let name = Stem.label(for: wanted)
        status = "Analyse de « \(Stem.label(for: visible)) »…"
        let settings = analysis
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // La somme des pistes à voir est fabriquée ici, puis gardée : y revenir
            // ne doit pas coûter une seconde addition sur dix millions
            // d'échantillons.
            guard let file = try? StemStore.combined(visible, for: fingerprint),
                  let loaded = try? AudioSource.load(file) else {
                DispatchQueue.main.async {
                    self?.separating = nil
                    self?.selection = AppModel.everything
                    self?.separationError = "« \(name) » illisible."
                    self?.show(AppModel.everything)
                }
                return
            }
            let matrix = OfflineAnalysis.run(samples: loaded.mono,
                                             sampleRate: loaded.sampleRate,
                                             settings: settings) { p in
                DispatchQueue.main.async { self?.separating = 0.8 + p * 0.2 }
            }
            DispatchQueue.main.async {
                guard let self, self.selection == wanted else { return }
                self.stemCache[visible] = matrix
                self.separating = nil
                self.status = name
                self.adopt(spectrogram: matrix, playing: heard)
            }
        }
    }

    /// Bascule l'image et le son sans rien perdre de ce qui est en cours : la
    /// fenêtre visible, la boucle et la position de lecture survivent au changement
    /// de piste, sans quoi comparer deux pistes serait insupportable.
    private func adopt(spectrogram matrix: Spectrogram, playing file: URL?) {
        spectrogram = matrix
        forgetVoicing()
        renderer?.layout = matrix.layout
        renderer?.upload(matrix)
        snap = nil
        guard let file else { return }
        // Cocher une piste change de fichier sans changer de morceau : le format est
        // le même, donc le moteur audio n'a pas à être arrêté. C'est lui qu'on
        // entendait, pas la lecture du nouveau fichier.
        if player.replace(with: file) { return }
        let wasPlaying = player.isPlaying
        let at = playhead
        player.load(url: file)
        player.setLoop(loopEnabled ? loop : nil)
        if wasPlaying { player.play(from: at) } else { player.seek(to: at) }
    }

    /// Ce que la ligne de batterie a à dire quand elle n'a rien à montrer. Une ligne
    /// vide sans un mot laisserait croire que le morceau n'a pas de batterie.
    ///
    /// C'est aussi elle qui porte l'avancement de la séparation. Cette place-là
    /// n'est pas un pis-aller : la séparation part toute seule à l'ouverture, et
    /// c'est précisément cette ligne qu'elle va remplir. Un relevé tiré du mixage
    /// s'afficherait entre-temps pour être remplacé une minute plus tard par un
    /// autre — mieux vaut une ligne vide qui dit ce qu'elle attend.
    var drumLaneNotice: String? {
        if let progress = separating {
            return String(format: "Séparation des pistes : %d %%",
                          Int((progress * 100).rounded()))
        }
        if percussionPending { return "Relevé de la batterie…" }
        guard percussion.hits.isEmpty else { return nil }
        if isSeparated, !selection.contains(.drums) { return "Batterie retirée" }
        return spectrogram.columnCount > 0 ? "Aucun coup relevé" : nil
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
    private func relevePercussion(keeping wanted: Set<Stem>, separated: Bool,
                                  fingerprint: String?, mix: AudioSource) {
        guard separated else {
            relevePercussion(Self.everything, from: mix.mono, sampleRate: mix.sampleRate)
            return
        }
        guard wanted.contains(.drums), let fingerprint,
              let file = StemStore.url(.drums, for: fingerprint) else {
            percussionToken += 1
            percussion = .empty
            percussionPending = false
            return
        }
        relevePercussion([.drums], loading: file)
    }

    /// Relève la batterie d'un fichier qu'il faut d'abord lire — la piste isolée.
    private func relevePercussion(_ key: Set<Stem>, loading file: URL) {
        percussionToken += 1
        let token = percussionToken
        if let ready = percussionCache[key] {
            percussion = ready
            percussionPending = false
            return
        }
        percussion = .empty
        percussionPending = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let loaded = try? AudioSource.load(file) else {
                DispatchQueue.main.async { self?.percussionPending = false }
                return
            }
            let track = PercussionDetector.detect(samples: loaded.mono,
                                                  sampleRate: loaded.sampleRate)
            DispatchQueue.main.async {
                guard let self else { return }
                self.percussionCache[key] = track
                guard self.percussionToken == token else { return }
                self.percussion = track
                self.percussionPending = false
            }
        }
    }

    // MARK: Les accords

    /// Hauteur de la bande où s'écrivent les noms d'accords, en bas de l'image.
    /// Partagée par le dessin et par la désignation à la souris — sans quoi la zone
    /// sensible et la zone dessinée finiraient par se décoller.
    static let chordBandHeight = 18.0

    /// L'accord que la souris désigne, ou `nil`.
    ///
    /// Le survol porte sur **toute la durée** de l'accord, pas sur les quelques points
    /// de son nom : viser huit caractères ne serait pas un geste, ce serait un
    /// exercice. Le nom marque le début, la zone sensible couvre ce qu'il nomme.
    var hoveredChord: ChordSegment? {
        guard showChords, !chords.isEmpty, let hover, let unit = gridUnit else { return nil }
        guard hover.y >= viewSize.height - Self.chordBandHeight,
              hover.y <= viewSize.height else { return nil }
        let pointed = time(atPoint: Double(hover.x))
        return chords.labels(from: time(atPoint: 0),
                             to: time(atPoint: Double(viewSize.width)),
                             grouping: max(1, Int(unit.rounded())))
            .first { pointed >= $0.start && pointed < $0.end && $0.chord != nil }
    }

    /// Les notes de l'accord survolé, telles qu'elles sonnent vraiment.
    ///
    /// Gardées d'un dessin à l'autre. Le spectre moyen d'un temps, c'est une
    /// exponentiation par ligne et par colonne — vingt mille pour un temps — et
    /// l'image se redessine soixante fois par seconde tant que la souris ne bouge
    /// pas. Le calcul ne dépend que de l'accord désigné : il n'a aucune raison
    /// d'être refait tant qu'on reste dessus.
    @ObservationIgnored private var voicingCache: (key: ClosedRange<Double>,
                                                   notes: [SoundingNote])?

    var hoveredChordNotes: [SoundingNote] {
        guard let segment = hoveredChord, let chord = segment.chord,
              spectrogram.columnCount > 0, segment.end > segment.start else { return [] }
        let key = segment.start...segment.end
        if let cached = voicingCache, cached.key == key { return cached.notes }
        let spectrum = spectrogram.averageSpectrum(from: segment.start, to: segment.end)
        // Le noir de l'image sert de plancher : ce qu'on entoure est ce qu'on voit.
        // C'est aussi le réglage de contraste qui commande, donc l'éclaircir dévoile
        // des notes plus faibles — ce qui est le comportement qu'on attend.
        let notes = ChordVoicing.sounding(chord, in: spectrum, layout: spectrogram.layout,
                                          referenceA: display.referenceA,
                                          visibleFloor: Float(display.floorDb))
        voicingCache = (key, notes)
        return notes
    }

    /// À jeter dès que l'image change : les mêmes bornes de temps ne désignent plus
    /// le même contenu quand on passe d'une piste à l'autre.
    func forgetVoicing() { voicingCache = nil }

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
        guard let current else { return tone.stop() }
        tone.play(chord: chordFrequencies(current.chord))
    }

    private func chordFrequencies(_ chord: Chord) -> [Double] {
        let notes = hoveredChordNotes
        let midi: [Int] = notes.isEmpty
            ? chord.quality.intervals.map { 48 + chord.root + $0 }
            : notes.map(\.midi)
        return midi.map { Pitch.frequency(ofMidi: Double($0),
                                          referenceA: display.referenceA) }
    }

    /// Pourquoi la ligne d'accords est vide, quand elle l'est.
    var chordNotice: String? {
        guard showChords, spectrogram.columnCount > 0 else { return nil }
        if chordsPending { return "Relevé des accords…" }
        guard chords.isEmpty else { return nil }
        if !isSeparated { return "Accords : séparer les pistes d'abord" }
        if tempo == nil || (tempo?.bpm ?? 0) <= 0 { return "Accords : chercher la grille d'abord" }
        return nil
    }

    /// Devine les accords à partir des deux pistes qui les portent.
    ///
    /// **Toujours la basse et le « reste », quoi qu'on ait coché.** Ce n'est pas une
    /// vue de ce qu'on écoute mais une lecture de ce qui est joué : retirer la basse
    /// pour travailler ne doit pas effacer les accords qu'on est en train de relever.
    /// C'est l'inverse du choix fait pour la ligne de batterie, et pour la même
    /// raison — là-bas, décocher la batterie *veut dire* qu'on ne veut plus la voir.
    ///
    /// Le relevé se refait quand la grille métrique change : c'est elle qui découpe.
    private func releveAccords(separated: Bool, fingerprint: String?) {
        chordToken += 1
        let token = chordToken
        guard separated, let fingerprint, let tempo, tempo.bpm > 0,
              let bassFile = StemStore.url(.bass, for: fingerprint),
              let otherFile = StemStore.url(.other, for: fingerprint) else {
            chords = .empty
            chordsPending = false
            return
        }
        if let ready = chordCache[tempo] {
            chords = ready
            chordsPending = false
            return
        }
        chords = .empty
        chordsPending = true
        let referenceA = display.referenceA
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let bass = try? AudioSource.load(bassFile),
                  let other = try? AudioSource.load(otherFile) else {
                DispatchQueue.main.async { self?.chordsPending = false }
                return
            }
            let track = ChordDetector.detect(bass: bass.mono, harmony: other.mono,
                                             sampleRate: other.sampleRate,
                                             tempo: tempo, referenceA: referenceA)
            DispatchQueue.main.async {
                guard let self else { return }
                self.chordCache[tempo] = track
                guard self.chordToken == token else { return }
                self.chords = track
                self.chordsPending = false
            }
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
    func forgetStems() {
        guard let fingerprint = source?.fingerprint else { return }
        job?.cancel()
        job = nil
        separating = nil
        stemCache.removeAll()
        percussionCache.removeAll()
        StemStore.removeStems(for: fingerprint)
        selection = Self.everything
        show(Self.everything)
        status = "Pistes effacées."
    }

    // MARK: Actions

    func seek(to time: Double) {
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
    func setLoop(from a: Double, to b: Double, snapping: Bool = false) {
        loop = LoopEditing.made(from: a, to: b, duration: duration,
                                snap: snapper(snapping))
    }

    /// Aimante ou laisse libre, selon le geste en cours.
    private func snapper(_ snapping: Bool) -> (Double) -> Double {
        snapping ? { [self] in snapToGrid($0) } : { $0 }
    }

    func dragLoop(edge: LoopEdge, to time: Double, snapping: Bool) {
        guard let loop else { return }
        self.loop = LoopEditing.resized(loop, edge: edge, to: time, duration: duration,
                                        snap: snapper(snapping))
    }

    func moveLoop(startingAt time: Double, snapping: Bool) {
        guard let loop else { return }
        self.loop = LoopEditing.moved(loop, startingAt: time, duration: duration,
                                      snap: snapper(snapping))
    }

    /// Pose une borne au passage de la tête de lecture, en gardant l'autre.
    func setLoopStart(at time: Double) {
        setLoop(from: time, to: loop.map { max($0.upperBound, time + 0.2) } ?? min(time + 4, duration))
    }

    func setLoopEnd(at time: Double) {
        setLoop(from: loop.map { min($0.lowerBound, time - 0.2) } ?? max(time - 4, 0), to: time)
    }

    /// Cale la boucle sur les mesures qui l'encadrent — c'est presque toujours ce
    /// qu'on veut quand on travaille un passage.
    func snapLoopToBars() {
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
    func recomputeTempo() {
        guard spectrogram.columnCount > 0 else { return }
        let matrix = spectrogram
        let signature = beatsPerBar
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let grid = TempoEstimator.estimate(matrix, beatsPerBar: signature)
            DispatchQueue.main.async { self?.tempo = grid }
        }
    }

    /// Tempo saisi à la main. Ce n'est plus une estimation mais un choix, d'où la
    /// confiance remise à zéro : le « ≈ » qui prévient d'une grille incertaine n'a
    /// plus lieu d'être quand c'est l'utilisatrice qui l'a dictée.
    func setTempo(_ value: Double) {
        guard value.isFinite else { return }
        guard var grid = tempo else {
            tempo = TempoGrid(bpm: min(max(value, 20), 400), origin: playhead)
            return
        }
        grid.bpm = min(max(value, 20), 400)
        grid.confidence = 0
        tempo = grid
    }

    func nudgeTempo(by delta: Double) {
        guard var grid = tempo else { return }
        grid.bpm = min(max(grid.bpm + delta, 20), 400)
        tempo = grid
    }

    /// Pose le premier temps à l'endroit de la tête de lecture.
    func setDownbeatAtPlayhead() {
        guard var grid = tempo else {
            tempo = TempoGrid(bpm: 120, origin: playhead)
            return
        }
        grid.origin = playhead
        tempo = grid
    }

    var beatsPerBar: Int {
        get { tempo?.beatsPerBar ?? 4 }
        set {
            guard var grid = tempo else { return }
            grid.beatsPerBar = max(1, newValue)
            tempo = grid
        }
    }

    // MARK: Lecture

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            playhead = player.currentTime
        } else {
            player.play(from: playhead)
        }
    }

    /// Fréquence correspondant à une ordonnée de la vue (comptée depuis le haut).
    func frequency(atPoint y: Double) -> Double {
        let bin = viewport.bin(atPoint: y, height: Double(viewSize.height))
        return spectrogram.layout.frequency(atBin: bin)
    }

    func time(atPoint x: Double) -> Double {
        (viewport.column(atPoint: x) + 0.5) * spectrogram.secondsPerColumn
    }

    /// Abscisse d'un instant dans la vue, en points.
    func point(ofTime t: Double) -> Double {
        viewport.point(ofColumn: spectrogram.column(atTime: t))
    }

    /// Ordonnée d'une fréquence dans la vue, en points depuis le haut.
    func point(ofFrequency f: Double) -> Double {
        viewport.point(ofBin: spectrogram.layout.bin(of: f), height: Double(viewSize.height))
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let cents = Int((seconds - Double(total)) * 100)
        return String(format: "%d:%02d,%02d", total / 60, total % 60, cents)
    }
}
