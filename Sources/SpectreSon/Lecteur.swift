import CPont
import Foundation
import Observation
import SpectreCore
import SpectreTextes
import SpectreModele
import SpectreSocle

/// La lecture sous Windows : WASAPI en dessous, et rien d'autre.
///
/// Le pendant macOS est `Player`, qui empile des nœuds dans un `AVAudioEngine`.
/// Ici il n'y a pas de moteur : un périphérique réclame des échantillons, et trois
/// pièces déjà écrites les fournissent, toutes trois portables et toutes trois
/// mesurées ailleurs que dans ce fichier.
///
/// - `PlaybackChain` tient la position, la boucle et le filtre de bande — 16
///   contrôles dans `ChainCheck` ;
/// - `Etireur` tient le ralenti et la transposition — 20 contrôles dans
///   `EtirementCheck` ;
/// - `Sources/CPont/wasapi.c` ouvre le périphérique et réclame.
///
/// Ce fichier ne fait que les brancher, et **le seul travail qui lui reste est
/// celui du temps** : ce que la tête de lecture doit montrer n'est pas la position
/// d'où l'on tire des échantillons, mais celle de ce qui sort du haut-parleur.
/// Voir `currentTime`.
@Observable public final class LecteurSurLePont: LecteurAudio {

    // MARK: L'état partagé avec le fil audio

    /// Tout ce que les deux fils touchent est sous ce verrou, et rien d'autre ne
    /// l'est. Le rendu d'un bloc coûte quelques centaines de microsecondes ; le fil
    /// principal ne le garde jamais plus longtemps qu'un réglage de curseur.
    @ObservationIgnored private let verrou = NSLock()
    @ObservationIgnored private var chaine: PlaybackChain?
    @ObservationIgnored private var etireur = Etireur(sampleRate: 44100)
    @ObservationIgnored private var sortie: OpaquePointer?
    @ObservationIgnored private var frequence: Double = 44100

    /// Position lue **sous le verrou** par le fil audio, et recopiée ici pour que
    /// l'affichage n'ait pas à le prendre soixante fois par seconde.
    @ObservationIgnored private var positionBrute: Double = 0

    // MARK: Ce que le modèle voit

    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    public var message: String?

    @ObservationIgnored private var url: URL?
    /// La banque en cours et la sélection qu'on en tire, pour ne pas resommer ce qui
    /// est déjà sous le doigt.
    @ObservationIgnored private var banque: BanqueDePistes?
    @ObservationIgnored private var gardees: Set<Stem> = []
    /// Change à chaque demande : une somme qui revient après qu'on a cliqué ailleurs
    /// n'a plus rien à installer.
    @ObservationIgnored private var jeton = 0
    /// Ce qu'on nous a demandé pendant que le fichier se décodait encore.
    @ObservationIgnored private var enAttenteDeLecture: Double?
    @ObservationIgnored private var chargementEnCours: URL?

    private var vitesseRangee: Double = 1
    private var transpositionRangee: Double = 0

    /// Vitesse de lecture (1 = normale), hauteur inchangée. La valeur est crantée à
    /// l'écriture : ce que l'affichage montre est ce qui est réellement appliqué.
    public var speed: Double {
        get { vitesseRangee }
        set {
            let crante = Detent.speed(newValue)
            guard crante != vitesseRangee else { return }
            vitesseRangee = crante
            appliquerLEtirement()
        }
    }

    /// Transposition, en demi-tons (fractionnaire : sert aussi à recaler un
    /// enregistrement désaccordé).
    public var transpose: Double {
        get { transpositionRangee }
        set {
            let crante = Detent.transpose(newValue)
            guard crante != transpositionRangee else { return }
            transpositionRangee = crante
            appliquerLEtirement()
        }
    }

    public var isNeutral: Bool { vitesseRangee == 1 && transpositionRangee == 0 }

    public var volume: Double = 1 {
        didSet {
            verrou.lock()
            chaine?.volume = Float(min(max(volume, 0), 1))
            verrou.unlock()
        }
    }

    public private(set) var loop: ClosedRange<Double>?

    public init() {}

    deinit {
        if let sortie { spectre_sortie_fermer(sortie) }
    }

    private func appliquerLEtirement() {
        verrou.lock()
        // Les bornes sont celles de la version macOS, pour que les deux crans
        // butent au même endroit.
        etireur.vitesse = min(max(vitesseRangee, 1.0 / 32), 4)
        etireur.demiTons = min(max(transpositionRangee, -24), 24)
        verrou.unlock()
    }

    // MARK: Le temps

    /// Position de ce qui **s'entend**, et non de ce qu'on a déjà lu.
    ///
    /// Trois retards s'additionnent entre la lecture d'un échantillon et le moment
    /// où il sort, et il faut les retirer tous les trois :
    ///
    /// - ce que l'étireur a tiré de la chaîne sans l'avoir encore recollé ;
    /// - ce qui est recollé mais pas encore remis au périphérique — compté dans le
    ///   même terme ;
    /// - ce que le périphérique tient dans son tampon.
    ///
    /// Sans ce retrait, la tête prend une cinquantaine de millisecondes d'avance sur
    /// le son. Personne ne le remarque en écoutant ; tout le monde le remarque en
    /// calant une boucle sur un temps, où la tête est visiblement passée avant que
    /// le coup ne se fasse entendre.
    public var currentTime: Double {
        verrou.lock()
        let position = positionBrute
        let enReserve = Double(etireur.enAttente)
        verrou.unlock()
        guard frequence > 0 else { return 0 }

        // Le périphérique compte en images de sortie ; à vitesse réduite, une image
        // de sortie vaut moins d'une image de fichier.
        let enVol = Double(sortie.map { spectre_sortie_en_vol($0) } ?? 0)
        let retard = (enReserve + enVol * max(vitesseRangee, 0.001)) / frequence
        return min(max(position - retard, 0), max(duration, 0))
    }

    // MARK: Ouvrir

    public func load(url nouvelle: URL) {
        stop()
        banque = nil
        gardees = []
        jeton += 1
        url = nouvelle
        duration = 0
        message = nil
        chargementEnCours = nouvelle

        // Le décodage est **entier et en mémoire** : sur un morceau long il prend
        // quelques secondes, et le faire ici bloquerait la fenêtre à chaque
        // ouverture. `AVAudioFile` n'a pas ce problème parce qu'il lit en flux ;
        // nous n'avons pas de lecteur en flux, alors on décode à côté.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let contenu = try? DecodeurSurLePont.lire(nouvelle)
            // La référence faible est reprise dans une constante avant le second
            // bloc. Dans le premier, `self` est une *variable* capturée, et un bloc
            // imbriqué qui la relit est ce que le mode Swift 6 refusera.
            let lecteur = self
            DispatchQueue.main.async {
                guard let lecteur, lecteur.chargementEnCours == nouvelle else { return }
                lecteur.chargementEnCours = nil
                guard let contenu, !contenu.mono.isEmpty else {
                    lecteur.message = T(.erreurFichierIllisible,
                                        nouvelle.lastPathComponent)
                    return
                }
                lecteur.installer(contenu)
            }
        }
    }

    /// Joue la somme des pistes cochées, prise dans la banque.
    ///
    /// Les combinaisons ne sont plus des fichiers : elles se somment ici, en mémoire,
    /// et il n'y a plus rien à écrire, à relire ni à décoder. La somme se fait à côté —
    /// deux dixièmes de seconde sur un morceau long — pour que la fenêtre ne se fige
    /// pas sur un clic.
    public func charger(_ nouvelle: BanqueDePistes, gardant pistes: Set<Stem>) {
        guard banque !== nouvelle || gardees != pistes else { return }
        banque = nouvelle
        gardees = pistes
        url = nil
        chargementEnCours = nil
        message = nil
        jeton += 1
        let attendu = jeton
        let reprise = currentTime
        let jouait = isPlaying
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mono = nouvelle.melangeMono(pistes)
            let lecteur = self
            DispatchQueue.main.async {
                guard let lecteur, lecteur.jeton == attendu else { return }
                lecteur.installer(mono: mono, frequence: nouvelle.sampleRate,
                                  reprenant: reprise, enJouant: jouait)
            }
        }
    }

    private func installer(_ contenu: WAVFile.Contents) {
        installer(mono: contenu.mono, frequence: contenu.sampleRate,
                  reprenant: nil, enJouant: false)
    }

    private func installer(mono: [Float], frequence frequenceDuSignal: Double,
                           reprenant reprise: Double?, enJouant jouait: Bool) {
        verrou.lock()
        var neuve = PlaybackChain(samples: mono, channels: 1,
                                  sampleRate: frequenceDuSignal)
        neuve.volume = Float(min(max(volume, 0), 1))
        neuve.setLoop(loop)
        // Cocher une piste ne change pas de morceau : la tête de lecture reste où elle
        // était, sans quoi comparer deux pistes serait insupportable.
        if let reprise { neuve.currentTime = reprise }
        chaine = neuve
        etireur = Etireur(sampleRate: frequenceDuSignal)
        etireur.vitesse = min(max(vitesseRangee, 1.0 / 32), 4)
        etireur.demiTons = min(max(transpositionRangee, -24), 24)
        positionBrute = reprise ?? 0
        verrou.unlock()

        duration = neuve.duration

        // Le périphérique est rouvert dès que la fréquence change, et pas à chaque
        // fichier : rouvrir coûte quelques dizaines de millisecondes, qui
        // s'entendraient comme un retard à la première note.
        if sortie == nil || frequence != frequenceDuSignal {
            ouvrirLaSortie(frequence: frequenceDuSignal)
        }

        if jouait {
            play(from: reprise)
        } else if let depart = enAttenteDeLecture {
            enAttenteDeLecture = nil
            play(from: depart)
        }
    }

    private func ouvrirLaSortie(frequence voulue: Double) {
        if let ancienne = sortie {
            spectre_sortie_fermer(ancienne)
            sortie = nil
        }
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        let contexte = Unmanaged.passUnretained(self).toOpaque()
        let ouverte = erreur.withUnsafeMutableBufferPointer { tampon in
            spectre_sortie_ouvrir(voulue, rappelDeRendu, contexte, tampon.baseAddress)
        }
        guard let ouverte else {
            let texte = String(cString: erreur)
            Journal.erreur(texte)
            message = "Pas de son : \(texte)"
            frequence = voulue
            return
        }
        sortie = ouverte
        frequence = spectre_sortie_frequence(ouverte)
        if frequence != voulue {
            // Windows n'a pas voulu de la fréquence du fichier : tout ce qui est
            // compté en images du fichier serait alors faux. On le dit plutôt que de
            // laisser une lecture qui dérive.
            Journal.note("le périphérique tourne à \(Int(frequence)) Hz "
                         + "au lieu de \(Int(voulue)) Hz")
        }
    }

    // MARK: Jouer

    public func play(from time: Double?) {
        guard let sortie else {
            // Le fichier se décode encore : on retient la demande plutôt que de la
            // perdre, sans quoi appuyer sur la barre d'espace juste après une
            // ouverture ne ferait rien.
            enAttenteDeLecture = time ?? currentTime
            return
        }
        if let time { seek(to: time) }
        spectre_sortie_jouer(sortie)
        isPlaying = true
    }

    public func pause() {
        guard let sortie else { enAttenteDeLecture = nil; return }
        spectre_sortie_pause(sortie)
        isPlaying = false
    }

    public func stop() {
        enAttenteDeLecture = nil
        if let sortie { spectre_sortie_pause(sortie) }
        isPlaying = false
        seek(to: 0)
    }

    public func toggle(at time: Double) {
        if isPlaying { pause() } else { play(from: time) }
    }

    public func seek(to time: Double) {
        verrou.lock()
        let avant = chaine?.currentTime
        chaine?.seek(to: max(time, 0))
        // L'étireur garde en réserve le passage d'avant : le laisser sortir après un
        // saut ferait entendre un morceau de l'endroit qu'on vient de quitter.
        etireur.reinitialiser()
        positionBrute = chaine?.currentTime ?? 0
        let saut = avant.map { abs(positionBrute - $0) } ?? 0
        verrou.unlock()
        viderSiLaTeteASaute(de: saut)
    }

    public func setLoop(_ range: ClosedRange<Double>?) {
        loop = range
        verrou.lock()
        let avant = chaine?.currentTime
        chaine?.setLoop(range)
        positionBrute = chaine?.currentTime ?? positionBrute
        let saut = avant.map { abs(positionBrute - $0) } ?? 0
        verrou.unlock()
        viderSiLaTeteASaute(de: saut)
    }

    /// Jette ce que le périphérique tient encore quand la tête a sauté plus loin
    /// que ce qu'il tient.
    ///
    /// L'étireur, lui, est toujours vidé : sa réserve fait quelques dizaines de
    /// millisecondes et ne coûte rien à refaire. Le périphérique, non — le vider
    /// l'oblige à repartir d'un tampon plein, et le faire à chaque petit déplacement
    /// transformerait un glisser sur la réglette en hachoir.
    ///
    /// Le seuil est donc **ce que le périphérique tient**, et non un nombre choisi :
    /// en deçà, ce qui est en vol recouvre encore le passage où l'on arrive, et le
    /// laisser sortir ne s'entend pas. Au-delà, c'est un autre endroit du morceau, et
    /// on l'entendrait.
    private func viderSiLaTeteASaute(de saut: Double) {
        guard let sortie, frequence > 0 else { return }
        let enVol = Double(spectre_sortie_en_vol(sortie)) / frequence
        guard saut > enVol else { return }
        spectre_sortie_vider(sortie)
    }

    public func setBand(_ range: ClosedRange<Double>?) {
        verrou.lock()
        chaine?.setBand(range)
        verrou.unlock()
    }

    // MARK: Ce que le fil audio appelle

    /// Remplit un bloc. **Sur le fil audio**, sous le verrou.
    fileprivate func remplir(_ destination: UnsafeMutablePointer<Float>,
                             images: Int, canaux: Int) -> Int {
        verrou.lock()
        defer { verrou.unlock() }
        guard chaine != nil else { return 0 }

        // Le mono d'abord, en tête du tampon de sortie ; l'entrelacement ensuite, à
        // rebours, pour n'avoir besoin d'aucun tampon de travail. Le fil audio
        // n'alloue rien, et c'est ce qui fait qu'il ne craque pas.
        let mono = UnsafeMutableBufferPointer(start: destination, count: images)
        let rendues = etireur.rendre(into: mono, images: images) { entree, demandees in
            // La chaîne rend en mono parce qu'on le lui demande : un seul canal
            // suffit, l'analyse et l'écoute portent sur le même signal.
            self.chaine!.render(into: entree, frames: demandees, outputChannels: 1)
        }

        if canaux > 1 {
            var i = images - 1
            while i >= 0 {
                let v = destination[i]
                for c in 0..<canaux { destination[i * canaux + c] = v }
                i -= 1
            }
        }
        positionBrute = chaine?.currentTime ?? positionBrute

        // La fin du morceau arrête la lecture, mais depuis le fil principal : c'est
        // lui qui tient `isPlaying`, et le toucher d'ici le ferait lire pendant
        // qu'il change.
        if rendues < images, isPlaying {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }
        return rendues
    }
}

/// Le rappel que WASAPI appelle. Une fonction C : elle ne capture rien et retrouve
/// son objet par le contexte qu'on lui a confié à l'ouverture.
private let rappelDeRendu: SpectreRemplir = { destination, images, canaux, contexte in
    guard let destination, let contexte else { return 0 }
    let lecteur = Unmanaged<LecteurSurLePont>.fromOpaque(contexte).takeUnretainedValue()
    return Int32(lecteur.remplir(destination, images: Int(images), canaux: Int(canaux)))
}
