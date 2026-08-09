import AppKit
import Foundation
import Observation
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
        didSet { if hover == nil { snap = nil } }
    }
    /// Raie sur laquelle le curseur s'est aimanté.
    var snap: SnapTarget?

    /// Passage joué en boucle.
    var loop: ClosedRange<Double>? { didSet { pushLoop() } }
    var loopEnabled = true { didSet { pushLoop() } }

    /// Grille métrique estimée au chargement, ajustable ensuite.
    var tempo: TempoGrid?

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

    var title: String { source?.name ?? "Transcripteur" }
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

    func open(_ url: URL) {
        guard progress == nil else { return }
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
        stem = .mix
        stemCache.removeAll()
        job?.cancel()
        job = nil
        separating = nil
        separationError = nil
        askingForModel = false
        snap = nil
        progress = nil
        player.load(url: source.url)
        renderer?.layout = spectrogram.layout
        renderer?.upload(spectrogram)

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

    /// Piste choisie dans le sélecteur. C'est un **souhait** : tant que la
    /// séparation n'est pas faite, l'affichage reste sur le mixage et la vignette
    /// choisie porte l'avancement. On ne fait pas attendre devant un écran vide ce
    /// qui prend des minutes.
    private(set) var stem: Stem = .mix
    /// Avancement de la séparation, puis de l'analyse de la piste (0…1).
    private(set) var separating: Double?
    /// Avancement de l'installation du modèle.
    private(set) var installing: Double?
    /// Vrai quand l'utilisateur a demandé une piste sans que le modèle soit là.
    var askingForModel = false
    private(set) var separationError: String?

    @ObservationIgnored private var mixSpectrogram = Spectrogram.empty
    /// Les spectrogrammes des pistes déjà regardées, gardés en mémoire : y revenir
    /// doit être instantané, alors que les recalculer coûterait chaque fois
    /// plusieurs secondes.
    @ObservationIgnored private var stemCache: [Stem: Spectrogram] = [:]
    @ObservationIgnored private var job: SeparationJob?
    @ObservationIgnored private let installer = ModelInstaller()

    var isSeparated: Bool {
        guard let fingerprint = source?.fingerprint else { return false }
        return StemStore.isSeparated(fingerprint)
    }

    var hasModel: Bool { StemStore.hasModel }

    /// Réponse au sélecteur.
    func select(_ wanted: Stem) {
        guard wanted != stem, source != nil else { return }
        separationError = nil

        if wanted == .mix {
            stem = .mix
            show(.mix)
            return
        }
        guard let fingerprint = source?.fingerprint else { return }
        if StemStore.isSeparated(fingerprint) {
            stem = wanted
            show(wanted)
            return
        }
        // Rien de séparé et pas de modèle : on ne bouge pas le sélecteur, on
        // explique. Déplacer la sélection vers une piste qu'on ne peut pas montrer
        // serait mentir sur l'état des choses.
        guard StemStore.hasModel else {
            askingForModel = true
            return
        }
        stem = wanted
        separate()
    }

    private func separate() {
        guard let source, let fingerprint = source.fingerprint, separating == nil else { return }
        job?.cancel()
        let work = SeparationJob()
        job = work
        separating = 0
        status = "Séparation des pistes…"
        work.run(fileAt: source.url, fingerprint: fingerprint,
                 progress: { [weak self] p in self?.separating = p * 0.8 },
                 completion: { [weak self] result in
                     guard let self, self.job === work else { return }
                     self.job = nil
                     switch result {
                     case .success:
                         self.show(self.stem)
                     case .failure(let error):
                         self.separating = nil
                         self.stem = .mix
                         self.separationError = error.localizedDescription
                         self.status = error.localizedDescription
                     }
                 })
    }

    /// Charge et analyse une piste, puis la met à l'écran et dans le lecteur.
    ///
    /// L'analyse est refaite sur la piste plutôt que reprise du mixage : c'est tout
    /// l'intérêt de l'opération, un spectrogramme où ne restent que les partielles
    /// d'un seul instrument.
    private func show(_ wanted: Stem) {
        guard let source else { return }
        // Un calcul encore en cours garde sa barre : revenir au mixage pendant la
        // séparation est le geste normal — on continue à travailler — et ce n'est
        // pas une raison pour perdre de vue ce qui tourne.
        let stillWorking = job != nil
        if wanted == .mix {
            if !stillWorking { separating = nil }
            adopt(spectrogram: mixSpectrogram, playing: source.url)
            return
        }
        if let ready = stemCache[wanted] {
            if !stillWorking { separating = nil }
            adopt(spectrogram: ready, playing: StemStore.url(wanted, for: source.fingerprint ?? ""))
            return
        }
        guard let fingerprint = source.fingerprint,
              let file = StemStore.url(wanted, for: fingerprint) else { return }

        separating = separating ?? 0.8
        status = "Analyse de « \(wanted.label) »…"
        let settings = analysis
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let loaded = try? AudioSource.load(file) else {
                DispatchQueue.main.async {
                    self?.separating = nil
                    self?.stem = .mix
                    self?.separationError = "Piste « \(wanted.label) » illisible."
                }
                return
            }
            let matrix = OfflineAnalysis.run(samples: loaded.mono,
                                             sampleRate: loaded.sampleRate,
                                             settings: settings) { p in
                DispatchQueue.main.async { self?.separating = 0.8 + p * 0.2 }
            }
            DispatchQueue.main.async {
                guard let self, self.stem == wanted else { return }
                self.stemCache[wanted] = matrix
                self.separating = nil
                self.status = "Piste « \(wanted.label) »"
                self.adopt(spectrogram: matrix, playing: file)
            }
        }
    }

    /// Bascule l'image et le son sans rien perdre de ce qui est en cours : la
    /// fenêtre visible, la boucle et la position de lecture survivent au changement
    /// de piste, sans quoi comparer deux pistes serait insupportable.
    private func adopt(spectrogram matrix: Spectrogram, playing file: URL?) {
        spectrogram = matrix
        renderer?.layout = matrix.layout
        renderer?.upload(matrix)
        snap = nil
        guard let file else { return }
        let wasPlaying = player.isPlaying
        let at = playhead
        player.load(url: file)
        player.setLoop(loopEnabled ? loop : nil)
        if wasPlaying { player.play(from: at) } else { player.seek(to: at) }
    }

    // MARK: Installation du modèle

    func installModel() {
        guard let remote = StemStore.modelSource else { return }
        installing = 0
        installer.start(from: remote,
                        progress: { [weak self] p in self?.installing = p },
                        completion: { [weak self] result in
                            self?.installing = nil
                            switch result {
                            case .success:
                                self?.askingForModel = false
                                self?.status = "Modèle installé."
                            case .failure(let error):
                                self?.separationError = error.localizedDescription
                            }
                        })
    }

    /// Désigner le fichier à la main — le chemin tant qu'aucune adresse de
    /// téléchargement n'est publiée, et de toute façon celui qui sert à essayer un
    /// modèle avant de le publier.
    func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "onnx")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.prompt = "Installer"
        panel.message = "Choisir le modèle Demucs converti (.onnx)"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try ModelInstaller.install(from: file)
            askingForModel = false
            status = "Modèle installé."
        } catch {
            separationError = error.localizedDescription
        }
    }

    func dismissModelPrompt() { askingForModel = false }

    /// Efface les pistes de ce morceau — de quoi refaire la séparation si le
    /// résultat déçoit, sans aller fouiller dans Application Support.
    func forgetStems() {
        guard let fingerprint = source?.fingerprint else { return }
        job?.cancel()
        job = nil
        separating = nil
        stemCache.removeAll()
        StemStore.removeStems(for: fingerprint)
        stem = .mix
        show(.mix)
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

    func scaleTempo(by factor: Double) {
        guard var grid = tempo else { return }
        grid.bpm = min(max(grid.bpm * factor, 20), 400)
        grid.confidence = 0        // ce n'est plus l'estimation, c'est un choix
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
