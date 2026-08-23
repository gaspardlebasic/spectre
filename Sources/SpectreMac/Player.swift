import AVFoundation
import Foundation
import Observation
import SpectreCore
import SpectreTextes
import SpectreDSP

/// Lecture, avec ralenti et transposition indépendants.
///
/// **Deux sources, un seul graphe.** Un morceau qui n'est pas séparé — ou dont on
/// garde les quatre pistes — se lit en flux depuis son fichier, comme toujours :
/// c'est le signal d'origine, il ne coûte rien en mémoire, et rien ne vaut mieux que
/// lui. Dès qu'une piste est décochée, ce qui sort est la **somme des pistes cochées,
/// calculée au moment où le son sort**, à partir de la banque en mémoire.
///
/// Les deux entrent dans le même mélangeur, et ce qui suit — bande passante, ralenti,
/// transposition — ne sait pas laquelle joue. Les deux restent branchées en
/// permanence : cocher une piste ne démonte plus le graphe de rendu, ce qui
/// s'entendait comme un accroc à chaque bascule.
///
/// `AVAudioUnitTimePitch` est l'unité fournie par le système : correcte jusqu'à
/// la moitié de la vitesse, métallique en dessous. Elle est ici pour que la chaîne
/// soit complète ; le jour où la qualité devient le sujet, c'est le seul nœud à
/// remplacer — rien d'autre dans l'application ne dépend de la vitesse de lecture,
/// puisque l'analyse porte sur le fichier d'origine.
@Observable public final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// Là où les deux sources se rejoignent. Sans lui, passer du fichier à la banque
    /// demanderait de rebrancher la chaîne — donc de l'arrêter et de la refaire, ce
    /// qui est très exactement ce qu'on entendait en cochant une piste.
    private let melangeur = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    /// Deux passe-haut et deux passe-bas en cascade : 24 dB par octave de chaque
    /// côté. Un seul biquad (12 dB/octave) laisserait passer la basse voisine
    /// qu'on cherche précisément à écarter.
    private let band = AVAudioUnitEQ(numberOfBands: 4)
    /// Bande actuellement appliquée, pour ne pas retoucher les filtres à chaque
    /// image quand rien n'a bougé.
    @ObservationIgnored private var appliedBand: ClosedRange<Double>?

    // MARK: Ce qui joue

    private enum Source { case aucune, fichier, banque }
    @ObservationIgnored private var source: Source = .aucune

    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var fileSampleRate: Double = 44100
    /// Instant d'où part la lecture programmée : l'horloge du nœud repart de zéro
    /// à chaque `stop()`, on lui rajoute donc l'origine du segment.
    @ObservationIgnored private var segmentStart: Double = 0
    @ObservationIgnored private var pausedAt: Double = 0

    /// La banque en cours, tenue ici pour qu'elle vive aussi longtemps que le fil
    /// audio y lit. Le rappel de rendu, lui, ne voit que des pointeurs.
    @ObservationIgnored private var banque: BanqueDePistes?
    @ObservationIgnored private var noeudBanque: AVAudioSourceNode?
    @ObservationIgnored private let etat = SourceDeBanque()

    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    public var message: String?

    private var storedSpeed: Double = 1
    private var storedTranspose: Double = 0

    /// Vitesse de lecture (1 = normale), hauteur inchangée. La valeur est crantée
    /// à l'écriture : ce que l'affichage montre est ce qui est réellement appliqué.
    public var speed: Double {
        get { storedSpeed }
        set {
            let snapped = Detent.speed(newValue)
            guard snapped != storedSpeed else { return }
            storedSpeed = snapped
            applyTimePitch()
        }
    }

    /// Transposition, en demi-tons (fractionnaire : sert aussi à recaler un
    /// enregistrement désaccordé).
    public var transpose: Double {
        get { storedTranspose }
        set {
            let snapped = Detent.transpose(newValue)
            guard snapped != storedTranspose else { return }
            storedTranspose = snapped
            applyTimePitch()
        }
    }

    /// Ni ralenti ni transposé : le fichier tel quel.
    public var isNeutral: Bool { storedSpeed == 1 && storedTranspose == 0 }

    /// Applique vitesse et hauteur, et **retire l'unité du chemin du signal**
    /// quand il n'y a rien à faire.
    ///
    /// À ×1 et +0, un vocodeur de phase laissé en service continue de découper et
    /// recoller le signal pour un résultat censé être identique — travail inutile,
    /// et surtout irrégulier : c'est le pire cas pour une échéance temps réel.
    /// Court-circuitée, l'unité laisse passer les échantillons du fichier tels
    /// quels, ce que `check.sh` vérifie au bit près.
    private func applyTimePitch() {
        let rate = min(max(storedSpeed, 1.0 / 32), 4)
        let cents = min(max(storedTranspose, -24), 24) * 100
        timePitch.rate = Float(rate)
        timePitch.pitch = Float(cents)
        timePitch.auAudioUnit.shouldBypassEffect = isNeutral
    }

    public var volume: Double = 1 {
        didSet { applyVolume() }
    }

    private func applyVolume() {
        melangeur.outputVolume = Float(min(max(volume, 0), 1))
    }

    public init() {
        engine.attach(node)
        engine.attach(melangeur)
        engine.attach(timePitch)
        engine.attach(band)
        // La suite du graphe est branchée une fois pour toutes, au format des pistes.
        // Le mélangeur convertit ce que le fichier apporte — 48 kHz, mono, peu
        // importe — et le reste de la chaîne n'a plus jamais à être défait.
        let format = Self.formatDesPistes
        engine.connect(melangeur, to: band, format: format)
        engine.connect(band, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.connect(node, to: melangeur, format: nil)
        for (i, parameters) in band.bands.enumerated() {
            parameters.filterType = i < 2 ? .highPass : .lowPass
            parameters.bypass = true
        }
        // Sans cet appel, l'état neutre — le plus courant, et celui du démarrage —
        // laisserait l'unité en service jusqu'à ce qu'on touche un curseur.
        applyTimePitch()
        applyVolume()
    }

    deinit {
        engine.stop()
        etat.liberer()
    }

    /// Le format dans lequel Demucs rend ses pistes, et donc celui de la banque.
    private static let formatDesPistes = AVAudioFormat(
        standardFormatWithSampleRate: StemStore.stemSampleRate, channels: 2)!

    /// Restreint la lecture à une bande de fréquences, ou la laisse entière.
    ///
    /// Les fréquences sont celles du **fichier**, pas celles qui sortent : le
    /// filtrage est placé avant la transposition, si bien que ce qu'on entend
    /// correspond à ce qu'on voit même quand on joue un ton plus haut.
    public func setBand(_ range: ClosedRange<Double>?) {
        // Un mouvement de trackpad produit une consigne par image ; on ne retouche
        // les filtres que lorsque l'écart devient audible (un dixième de demi-ton).
        if let range, let applied = appliedBand,
           abs(log2(range.lowerBound / applied.lowerBound)) < 0.005,
           abs(log2(range.upperBound / applied.upperBound)) < 0.005 { return }
        if range == nil && appliedBand == nil { return }
        appliedBand = range

        guard let range else {
            for parameters in band.bands { parameters.bypass = true }
            return
        }
        let nyquist = frequenceCourante / 2
        let low = min(max(range.lowerBound, 20), nyquist * 0.95)
        let high = min(max(range.upperBound, low * 1.05), nyquist * 0.95)
        for (i, parameters) in band.bands.enumerated() {
            let isHighPass = i < 2
            parameters.frequency = Float(isHighPass ? low : high)
            // Une borne collée au bord de l'analyse ne filtre rien : on la retire
            // plutôt que de laisser un filtre travailler pour rien.
            parameters.bypass = isHighPass ? low <= 25 : high >= nyquist * 0.9
        }
    }

    private var frequenceCourante: Double {
        source == .banque ? (banque?.sampleRate ?? 44100) : fileSampleRate
    }

    // MARK: Ouvrir

    public func load(url: URL) {
        // Les nœuds s'arrêtent, **le moteur reste en marche** : c'est lui qui coûte à
        // arrêter et à refaire, et le remonter s'entendait comme un accroc chaque fois
        // qu'on recochait toutes les pistes. Les deux sources entrent dans le même
        // mélangeur ; seule l'entrée du fichier est rebranchée ici.
        //
        // La position repart de zéro, comme avant : c'est l'appelant qui sait où elle
        // doit retomber — au début pour un morceau qu'on ouvre, là où elle était pour
        // une piste qu'on recoche — et il la repose juste après.
        etat.jouer(false)
        node.stop()
        isPlaying = false
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            fileSampleRate = f.processingFormat.sampleRate
            duration = Double(f.length) / fileSampleRate
            source = .fichier
            etat.jouer(false)
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: melangeur, format: f.processingFormat)
            engine.prepare()
            pausedAt = 0
            segmentStart = 0
        } catch {
            file = nil
            duration = 0
            source = .aucune
            message = T(.erreurLectureImpossible, error.localizedDescription)
        }
    }

    /// Joue la somme des pistes cochées, depuis la mémoire.
    ///
    /// Rappelée avec **la même banque**, elle ne fait que remplacer un masque de bits
    /// que le fil audio relit à chaque bloc : pas de rechargement, pas de coupure, pas
    /// une image perdue. C'est ce qui rend la bascule d'une piste immédiate là où elle
    /// coûtait jusqu'à sept secondes.
    public func charger(_ nouvelle: BanqueDePistes, gardant pistes: Set<Stem>) {
        if banque === nouvelle, source == .banque {
            etat.masque(nouvelle.masque(pistes))
            return
        }
        // La tête de lecture survit au changement de source : revenir du mixage à une
        // sélection de pistes ne doit pas ramener au début du morceau.
        let reprise = source == .aucune ? 0 : currentTime
        let jouait = isPlaying
        node.stop()

        banque = nouvelle
        source = .banque
        duration = nouvelle.duration
        // La géométrie d'abord : c'est elle que le rappel de rendu capture, et il est
        // fabriqué juste après.
        etat.installer(banque: nouvelle, masque: nouvelle.masque(pistes))
        installerLeNoeud(pour: nouvelle)
        etat.position(images: Int64(min(max(reprise, 0), duration) * nouvelle.sampleRate))
        pausedAt = min(max(reprise, 0), duration)
        appliquerLaBoucle()
        if jouait, demarrerLeMoteur() {
            etat.jouer(true)
            isPlaying = true
        } else {
            etat.jouer(false)
            isPlaying = false
        }
    }

    /// Le nœud qui rend la banque, **refait à chaque banque**.
    ///
    /// Le rappel de rendu capture le pointeur des échantillons et la longueur du bloc :
    /// les remplacer sous un nœud vivant ferait lire hors du tampon le temps d'une
    /// écriture. Un nœud neuf par morceau coûte quelques millisecondes, une fois.
    private func installerLeNoeud(pour nouvelle: BanqueDePistes) {
        let format = AVAudioFormat(standardFormatWithSampleRate: nouvelle.sampleRate,
                                   channels: AVAudioChannelCount(nouvelle.channels))
            ?? Self.formatDesPistes
        if let ancien = noeudBanque {
            engine.disconnectNodeOutput(ancien)
            engine.detach(ancien)
        }
        let neuf = etat.noeudDeRendu(format: format)
        engine.attach(neuf)
        engine.connect(neuf, to: melangeur, format: format)
        noeudBanque = neuf
        engine.prepare()
    }

    // MARK: La boucle

    /// Boucle en cours, en secondes. La lecture y reste tant qu'elle est posée.
    public private(set) var loop: ClosedRange<Double>?
    /// Longueur du premier segment joué, du point de départ à la fin de la boucle.
    @ObservationIgnored private var firstSegment: Double = 0
    /// Tours déjà programmés et pas encore consommés.
    @ObservationIgnored private var scheduledLaps = 0
    /// Nombre de tours maintenus d'avance dans la file du nœud.
    private static let lapsAhead = 3

    /// Pose ou retire la boucle. Si on est en train de lire, la file est refaite
    /// immédiatement — sans quoi le changement n'aurait d'effet qu'au tour suivant.
    public func setLoop(_ range: ClosedRange<Double>?) {
        let cleaned = range.flatMap { r -> ClosedRange<Double>? in
            let lo = min(max(r.lowerBound, 0), duration)
            let hi = min(max(r.upperBound, 0), duration)
            return hi - lo > 0.05 ? lo...hi : nil
        }
        guard cleaned != loop else { return }
        loop = cleaned
        if source == .banque {
            appliquerLaBoucle()
        } else if isPlaying {
            play(from: currentTime)
        }
    }

    private func appliquerLaBoucle() {
        guard let banque else { return }
        etat.boucle(loop.map {
            (Int64($0.lowerBound * banque.sampleRate), Int64($0.upperBound * banque.sampleRate))
        })
    }

    // MARK: Où en est la lecture

    /// Position de lecture, en secondes depuis le début du morceau.
    ///
    /// Deux comptes, selon ce qui joue. Le nœud de fichier tient son horloge lui-même,
    /// et il suffit de la replier sur la boucle. La banque, elle, est rendue par nous :
    /// le fil audio marque, à chaque bloc, **l'instant où ce bloc sera entendu**, et
    /// l'affichage interpole depuis cette marque. C'est ce qui garde la tête de lecture
    /// sur ce qui sort du haut-parleur plutôt que sur ce qu'on vient de remettre au
    /// système — une avance d'une vingtaine de millisecondes, qui se voit sur une image
    /// où l'on cherche une attaque au dixième de temps.
    public var currentTime: Double {
        guard isPlaying else { return pausedAt }
        if source == .banque {
            guard let banque else { return pausedAt }
            let images = etat.positionEntendue(vitesse: max(storedSpeed, 0.001),
                                               retard: engine.outputNode.presentationLatency)
            return min(max(Double(images) / banque.sampleRate, 0), duration)
        }
        guard let render = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: render),
              played.sampleRate > 0
        else { return pausedAt }
        let elapsed = Double(played.sampleTime) / played.sampleRate

        if let loop, loop.upperBound > loop.lowerBound {
            if elapsed < firstSegment { return segmentStart + elapsed }
            let length = loop.upperBound - loop.lowerBound
            let into = (elapsed - firstSegment).truncatingRemainder(dividingBy: length)
            return loop.lowerBound + into
        }
        return min(max(segmentStart + elapsed, 0), duration)
    }

    // MARK: Jouer

    private func demarrerLeMoteur() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            message = T(.erreurMoteurAudio, error.localizedDescription)
            return false
        }
    }

    public func play(from time: Double? = nil) {
        var start = min(max(time ?? pausedAt, 0), max(duration - 0.01, 0))
        // Lancer la lecture hors de la boucle n'aurait aucun sens : on rentre.
        if let loop, !loop.contains(start) { start = loop.lowerBound }

        switch source {
        case .aucune:
            return
        case .banque:
            guard let banque else { return }
            guard demarrerLeMoteur() else { return }
            etat.position(images: Int64(start * banque.sampleRate))
            appliquerLaBoucle()
            etat.jouer(true)
            pausedAt = start
            isPlaying = true
        case .fichier:
            guard let file else { return }
            let frame = AVAudioFramePosition(start * fileSampleRate)
            guard frame < file.length else { return }
            node.stop()                       // remet l'horloge du nœud à zéro
            guard demarrerLeMoteur() else { return }
            segmentStart = start
            scheduledLaps = 0
            if let loop {
                let end = AVAudioFramePosition(loop.upperBound * fileSampleRate)
                firstSegment = loop.upperBound - start
                node.scheduleSegment(file, startingFrame: frame,
                                     frameCount: AVAudioFrameCount(max(end - frame, 1)), at: nil)
                for _ in 0..<Self.lapsAhead { scheduleLap() }
            } else {
                firstSegment = .infinity
                node.scheduleSegment(file, startingFrame: frame,
                                     frameCount: AVAudioFrameCount(file.length - frame), at: nil)
            }
            node.play()
            isPlaying = true
        }
    }

    /// Programme un tour de boucle de plus. Les segments s'enchaînent dans la file
    /// du nœud : la reprise est sans trou, contrairement à un repositionnement
    /// déclenché à l'arrivée sur la fin.
    private func scheduleLap() {
        guard let file, let loop else { return }
        let from = AVAudioFramePosition(loop.lowerBound * fileSampleRate)
        let to = AVAudioFramePosition(loop.upperBound * fileSampleRate)
        guard to > from else { return }
        scheduledLaps += 1
        node.scheduleSegment(file, startingFrame: from,
                             frameCount: AVAudioFrameCount(to - from), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying, self.loop != nil,
                      self.source == .fichier else { return }
                self.scheduledLaps -= 1
                while self.scheduledLaps < Self.lapsAhead { self.scheduleLap() }
            }
        }
    }

    public func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        etat.jouer(false)
        node.stop()
        isPlaying = false
    }

    public func stop() {
        pausedAt = isPlaying ? currentTime : pausedAt
        etat.jouer(false)
        node.stop()
        engine.stop()
        isPlaying = false
    }

    public func toggle(at time: Double) {
        if isPlaying { pause() } else { play(from: time) }
    }

    /// Déplace la tête de lecture, en poursuivant si on était en train de lire.
    public func seek(to time: Double) {
        let wasPlaying = isPlaying
        pausedAt = min(max(time, 0), duration)
        if wasPlaying {
            play(from: pausedAt)
        } else if source == .banque, let banque {
            etat.position(images: Int64(pausedAt * banque.sampleRate))
        } else {
            node.stop()
            isPlaying = false
        }
    }
}

// MARK: - Ce que le fil audio voit

/// L'état que le rappel de rendu lit, et que la fenêtre écrit.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// POURQUOI DES POINTEURS ET PAS DES PROPRIÉTÉS
///
/// Un rappel de rendu n'a le droit ni d'allouer, ni de prendre un verrou, ni de
/// retenir un objet : il tourne sous une échéance de quelques millisecondes que le
/// système ne repousse pas. Lire `self.masque` sur une classe Swift ne garantit rien
/// de tout cela.
///
/// D'où ces scalaires alloués un par un. Chacun tient dans un mot aligné, et un mot
/// aligné se lit et s'écrit d'un coup sur les machines où cette application tourne :
/// le rendu voit donc toujours **une** valeur, l'ancienne ou la nouvelle, jamais un
/// mélange des deux. Le seul état à plusieurs mots est la boucle, et son écriture est
/// ordonnée pour que cela reste vrai — voir `boucle(_:)`.
///
/// La géométrie de la banque, elle, n'est pas partagée : elle est **capturée dans le
/// rappel**, qui est refait quand la banque change. Un pointeur de données et une
/// longueur qui se désaccorderaient le temps d'un bloc feraient lire hors du tampon.
///
/// Publique parce que `PlaybackCheck` monte le même graphe en rendu hors ligne et
/// vérifie les échantillons qui en sortent. Un mélangeur récrit pour la vérification
/// ne vérifierait que lui-même.
/// ─────────────────────────────────────────────────────────────────────────────
public final class SourceDeBanque {
    private let masqueP = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private let enLectureP = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private let positionP = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let boucleDebutP = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let boucleFinP = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    /// L'instant où le bloc qu'on vient de rendre sera entendu, et la position qu'il
    /// porte. Les deux ne sont lus ensemble que par l'affichage, qui tolère de tomber
    /// entre deux blocs — cinq millisecondes.
    private let marqueTempsP = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let marquePositionP = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    public init() {
        masqueP.pointee = 0
        enLectureP.pointee = 0
        positionP.pointee = 0
        boucleDebutP.pointee = 0
        boucleFinP.pointee = 0
        marqueTempsP.pointee = 0
        marquePositionP.pointee = 0
    }

    public func liberer() {
        masqueP.deallocate(); enLectureP.deallocate(); positionP.deallocate()
        boucleDebutP.deallocate(); boucleFinP.deallocate()
        marqueTempsP.deallocate(); marquePositionP.deallocate()
    }

    public func installer(banque: BanqueDePistes, masque: UInt32) {
        enLectureP.pointee = 0
        geometrie(de: banque)
        masqueP.pointee = masque
        positionP.pointee = 0
        boucleDebutP.pointee = 0
        boucleFinP.pointee = 0
        marqueTempsP.pointee = 0
        marquePositionP.pointee = 0
    }

    public func masque(_ bits: UInt32) { masqueP.pointee = bits }
    public func jouer(_ oui: Bool) { enLectureP.pointee = oui ? 1 : 0 }

    public func position(images: Int64) {
        positionP.pointee = images
        marqueTempsP.pointee = 0
        marquePositionP.pointee = images
    }

    /// Pose la boucle **en la désarmant d'abord**. Le rendu ne voit alors jamais un
    /// début neuf avec une fin ancienne, ce qui l'enverrait lire à l'envers.
    public func boucle(_ bornes: (Int64, Int64)?) {
        boucleFinP.pointee = 0
        guard let bornes, bornes.1 > bornes.0 else { return }
        boucleDebutP.pointee = bornes.0
        boucleFinP.pointee = bornes.1
    }

    /// Ce qui sort du haut-parleur en cet instant, en images du morceau.
    ///
    /// La marque dit : « le bloc qui commence à cette image-là sera entendu à cet
    /// instant-là ». Il est encore à venir, donc l'écart est négatif et on recule
    /// d'autant — c'est la compensation du tampon de sortie, sans avoir à le mesurer.
    /// Le retard du périphérique, lui, s'ajoute, et la vitesse convertit du temps
    /// d'écoute au temps du morceau.
    public func positionEntendue(vitesse: Double, retard: Double) -> Int64 {
        let marque = marqueTempsP.pointee
        let position = marquePositionP.pointee
        guard marque != 0 else { return positionP.pointee }
        let maintenant = mach_absolute_time()
        let écart = Double(Int64(bitPattern: maintenant) - Int64(bitPattern: marque))
            * SourceDeBanque.secondesParTic
        return position + Int64((écart - retard) * vitesse * StemStore.stemSampleRate)
    }

    private static let secondesParTic: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Fabrique le rappel de rendu pour une banque donnée.
    ///
    /// Tout ce qui décrit la banque est capturé ici, une fois : le bloc n'ira jamais
    /// le redemander à personne.
    public func noeudDeRendu(format: AVAudioFormat) -> AVAudioSourceNode {
        let masqueP = self.masqueP, enLectureP = self.enLectureP, positionP = self.positionP
        let boucleDebutP = self.boucleDebutP, boucleFinP = self.boucleFinP
        let marqueTempsP = self.marqueTempsP, marquePositionP = self.marquePositionP
        let source = self.echantillons
        let images = self.images
        let canaux = self.canaux
        let pistes = self.pistes

        return AVAudioSourceNode(format: format) { silence, horodatage, demandées, tampons in
            _ = boucleDebutP
            let sortie = UnsafeMutableAudioBufferListPointer(tampons)
            let voulues = Int(demandées)
            let masque = masqueP.pointee

            guard enLectureP.pointee == 1, let source, masque != 0, images > 0 else {
                silence.pointee = true
                for tampon in sortie {
                    memset(tampon.mData, 0, Int(tampon.mDataByteSize))
                }
                return noErr
            }

            var position = positionP.pointee
            marquePositionP.pointee = position
            marqueTempsP.pointee = horodatage.pointee.mHostTime

            let début = boucleDebutP.pointee
            let fin = boucleFinP.pointee
            let boucle = fin > début

            var écrit = 0
            while écrit < voulues {
                if boucle, position >= fin || position < début { position = début }
                let limite = boucle ? fin : Int64(images)
                let combien = min(voulues - écrit, Int(limite - position))
                guard combien > 0 else { break }
                for (c, tampon) in sortie.enumerated() where c < canaux {
                    let dst = tampon.mData!.assumingMemoryBound(to: Float.self) + écrit
                    memset(dst, 0, combien * MemoryLayout<Float>.size)
                    for rang in 0..<pistes where masque & (1 << UInt32(rang)) != 0 {
                        let base = source + (rang * canaux + c) * images + Int(position)
                        Vector.addScaled(base, times: 1, into: dst, count: combien)
                    }
                }
                position += Int64(combien)
                écrit += combien
            }
            // La fin du morceau : le reste du bloc est du silence, et la position
            // reste au bout plutôt que de repartir.
            if écrit < voulues {
                for (c, tampon) in sortie.enumerated() where c < canaux {
                    let dst = tampon.mData!.assumingMemoryBound(to: Float.self) + écrit
                    memset(dst, 0, (voulues - écrit) * MemoryLayout<Float>.size)
                }
            }
            positionP.pointee = position
            return noErr
        }
    }

    // La géométrie de la banque installée, recopiée ici pour que `noeudDeRendu` la
    // capture sans toucher à l'objet.
    private var echantillons: UnsafePointer<Float>?
    private var images = 0
    private var canaux = 0
    private var pistes = 0

    private func geometrie(de banque: BanqueDePistes) {
        echantillons = UnsafePointer(banque.echantillons)
        images = banque.frameCount
        canaux = banque.channels
        pistes = banque.ordre.count
    }
}
