import Foundation
import SpectreCore
import SpectreDessin
import SpectreModele
import SpectreTextes

// Vérification des gestes.
//
//     GestesCheck
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE HARNAIS N'EXISTAIT PAS AVANT, ET POURQUOI IL EXISTE MAINTENANT
//
// Tant que les gestes vivaient dans `SpectreWindows`, les mesurer aurait demandé
// une fenêtre, une souris, et une machine avec un écran. Depuis l'étape 6 du
// portage Linux ils sont dans `SpectreDessin`, et **ils ne touchent plus le système
// que par huit fonctions** — celles de `SurfaceDeGestes`. Une surface de papier
// suffit donc à les faire tourner, sans fenêtre et sans carte graphique.
//
// C'est le gain qu'on n'attendait pas du partage : ce qui devient portable devient
// mesurable.
//
// **Windows et Linux, et pas macOS** — parce que ce sont eux qui partagent `Gestes`,
// tandis que le Mac a les siens dans `TimelineView`, où SwiftUI les reçoit. Ce
// harnais est donc ce qui tient les deux portages d'accord ; le Mac l'est par la
// discipline dite en tête de `SpectreDessin/Gestes.swift`, où chaque ligne a son
// pendant exact. La divergence silencieuse est précisément ce qui a tué le premier
// portage.
//
// Ce qui n'est pas mesuré ici, et qui ne peut pas l'être : la traduction des
// évènements de chaque système. Qu'un `WM_MOUSEWHEEL` porte ses coordonnées en
// coordonnées d'écran, ou qu'un `SDL_EVENT_MOUSE_WHEEL` les porte en coordonnées de
// fenêtre, cela ne se voit qu'à l'usage.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0
func controle(_ intitule: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(intitule) — \(detail)")
    if !ok { echecs += 1 }
}

// MARK: - Une surface de papier

/// La surface que les gestes croient être un système.
///
/// Les touches mortes et la forme du curseur sont **posées depuis le harnais** :
/// c'est ce qui permet de vérifier qu'un glisser avec Ctrl relâche l'aimantation, et
/// que le curseur change au bord d'une boucle — deux choses qu'aucune image relue ne
/// dirait.
final class SurfaceDePapier: SurfaceDeGestes {
    var taillePoints: (largeur: Double, hauteur: Double) = (1200, 700)
    var majuscule = false
    var controle = false
    var delaiDuDoubleClic = 0.5
    var lignesParCranDeMolette = 3.0

    private(set) var forme: FormeDuCurseur = .fleche
    private(set) var capturee = false
    private(set) var menusDemandes = 0
    private(set) var ouverturesDemandees = 0

    func poserLeCurseur(_ forme: FormeDuCurseur) { self.forme = forme }
    func capturerLaSouris(_ capturer: Bool) { capturee = capturer }
    func menuContextuelDemande(a point: CGPoint) { menusDemandes += 1 }
    func ouvrirUnFichier() { ouverturesDemandees += 1 }
}

// MARK: - Un morceau, sans fichier

/// Trente secondes de synthèse, rendues sans toucher au disque.
///
/// Le décodeur du modèle est un protocole : le remplir ici évite de dépendre d'un
/// format, d'un fichier témoin, et du décodeur d'un système — dont ce harnais ne
/// mesure rien.
struct DecodeurDePapier: Décodeur {
    func charger(_ url: URL) throws -> AudioSource {
        let frequence = 44100.0
        let images = Int(frequence * 30)
        var mono = [Float](repeating: 0, count: images)
        for i in 0..<images {
            let t = Double(i) / frequence
            // Deux partiels et une pulsation : de quoi remplir la matrice de
            // quelque chose qui ne soit ni du silence ni du bruit blanc.
            let enveloppe = 0.5 + 0.5 * sin(2 * .pi * 2 * t)
            mono[i] = Float((sin(2 * .pi * 440 * t) + 0.5 * sin(2 * .pi * 1320 * t))
                            * 0.3 * enveloppe)
        }
        return AudioSource(url: url, sampleRate: frequence, frameCount: images,
                           mono: mono, fingerprint: "papier")
    }
}

final class LecteurDePapier: LecteurAudio {
    var isPlaying = false
    var duration = 30.0
    var message: String?
    var speed = 1.0
    var transpose = 0.0
    var isNeutral: Bool { speed == 1 && transpose == 0 }
    var volume = 1.0
    var currentTime = 0.0
    var loop: ClosedRange<Double>?
    func load(url: URL) {}
    func charger(_ banque: BanqueDePistes, gardant: Set<Stem>) {}
    func play(from time: Double?) { isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func toggle(at time: Double) { isPlaying.toggle() }
    func seek(to time: Double) { currentTime = time }
    func setLoop(_ range: ClosedRange<Double>?) { loop = range }
    func setBand(_ range: ClosedRange<Double>?) {}
}

final class SinusoideDePapier: Sinusoide {
    var voixMaximales = 6
    func play(_ frequency: Double?) {}
    func play(chord frequencies: [Double], waveform: ToneWaveform) {}
    func stop() {}
}

final class ReglagesDePapier: PreferencesGlobales {
    var reassignment = false
    var chords = ChordSettings()
    var hueOrigin = 0
}

struct DialogueDePapier: DialogueFichier {
    func choisirUnMorceau() -> URL? { nil }
}

struct RecentsDePapier: DocumentsRecents {
    func noter(_ url: URL) {}
    func effacer() {}
}

/// Rien n'est séparé, rien ne se sépare : les gestes de ce harnais ne touchent pas
/// aux pistes, et un service qui répond « non » à tout suffit à les faire tourner.
final class RangementDePapier: ServiceDeSeparation {
    var modeleDisponible = false
    var poidsPresents = false
    func tailleDuCache() -> Int { 0 }
    func viderLeCache() {}
    func estSepare(_ empreinte: String) -> Bool { false }
    func urlDeLaPiste(_ piste: Stem, empreinte: String) -> URL? { nil }
    func chargerLesPistes(empreinte: String, fin: @escaping (BanqueDePistes?) -> Void) {
        fin(nil)
    }
    func oublierLesPistes(empreinte: String) {}
    func marquerUtilise(_ empreinte: String) {}
    func separer(fichier: URL, empreinte: String,
                 avancement: @escaping (SeparationProgress) -> Void,
                 fin: @escaping (Result<BanqueDePistes, Error>) -> Void,
                 rangement: @escaping (Error?) -> Void) -> TravailAnnulable {
        final class Rien: TravailAnnulable {
            var isCancelled = false
            func cancel() { isCancelled = true }
        }
        return Rien()
    }
}

// MARK: - Le montage

let modele = AppModel<LecteurDePapier>(
    lecteur: LecteurDePapier(), décodeur: DecodeurDePapier(),
    sinusoide: SinusoideDePapier(), pistes: RangementDePapier(),
    dialogue: DialogueDePapier(), récentsDuSystème: RecentsDePapier(),
    préférences: ReglagesDePapier())

let surface = SurfaceDePapier()
let panneau = Panneau()
let flottant = Flottant()
let gestes = Gestes(modele: modele, surface: surface, panneau: panneau,
                    flottant: flottant)

/// Un tour de boucle d'application : la file principale, puis le calcul d'image.
func unTour() {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    modele.tick(viewSize: CGSize(width: surface.taillePoints.largeur,
                                 height: surface.taillePoints.hauteur - 60))
}

print("=== L'analyse ===")
modele.open(URL(fileURLWithPath: "/papier/temoin.wav"))
var tours = 0
while modele.spectrogram.columnCount == 0, tours < 2000 { unTour(); tours += 1 }
controle("le morceau est analysé", modele.spectrogram.columnCount > 0,
         "\(modele.spectrogram.columnCount) colonnes en \(tours) tours")
guard modele.spectrogram.columnCount > 0 else { exit(1) }
modele.clampViewport()
unTour()

// MARK: - Le zoom

print("\n=== La molette ===")

let ancre = CGPoint(x: 600, y: 300)
let instantSousLAncre = modele.time(atPoint: ancre.x)
let echelleAvant = modele.viewport.columnsPerPoint
surface.controle = true
for _ in 0..<5 { gestes.molette(a: ancre, crans: 1, horizontale: false) }
surface.controle = false
unTour()

controle("Ctrl + molette change l'échelle du temps",
         modele.viewport.columnsPerPoint != echelleAvant,
         String(format: "%.4f → %.4f colonne par point",
                echelleAvant, modele.viewport.columnsPerPoint))
// L'ancrage est ce qui fait qu'un zoom se sent juste : ce qu'on vise doit rester
// sous le curseur. Un demi-point de tolérance, parce que la colonne est discrète.
controle("le zoom reste ancré sous le curseur",
         abs(modele.point(ofTime: instantSousLAncre) - ancre.x) < 2,
         String(format: "l'instant visé est à %.2f pt, le curseur à %.0f pt",
                modele.point(ofTime: instantSousLAncre), ancre.x))

let hauteurAvant = modele.viewport.binsPerPoint
surface.majuscule = true
gestes.molette(a: ancre, crans: 1, horizontale: false)
surface.majuscule = false
unTour()
controle("⇧ + molette change l'échelle des fréquences",
         modele.viewport.binsPerPoint != hauteurAvant,
         String(format: "%.4f → %.4f case par point",
                hauteurAvant, modele.viewport.binsPerPoint))

let departAvant = modele.viewport.startColumn
gestes.molette(a: ancre, crans: -2, horizontale: true)
unTour()
controle("la molette horizontale déplace le temps",
         modele.viewport.startColumn != departAvant,
         String(format: "%.1f → %.1f", departAvant, modele.viewport.startColumn))

// MARK: - Le pincement

print("\n=== Le pincement ===")

// Ce que le pavé tactile envoie : une suite de petits facteurs, et non un seul
// grand. Les enchaîner est ce qui vérifie que le geste s'accumule au lieu de se
// remplacer.
let instantPince = modele.time(atPoint: ancre.x)
let echelleAvantPincement = modele.viewport.columnsPerPoint
for _ in 0..<10 { gestes.pincement(a: ancre, facteur: 1.05) }
unTour()
controle("écarter deux doigts resserre le temps",
         modele.viewport.columnsPerPoint < echelleAvantPincement,
         String(format: "%.4f → %.4f colonne par point",
                echelleAvantPincement, modele.viewport.columnsPerPoint))
controle("le pincement reste ancré sous les doigts",
         abs(modele.point(ofTime: instantPince) - ancre.x) < 2,
         String(format: "l'instant visé est à %.2f pt, les doigts à %.0f pt",
                modele.point(ofTime: instantPince), ancre.x))

let echelleRapprochee = modele.viewport.columnsPerPoint
for _ in 0..<10 { gestes.pincement(a: ancre, facteur: 1 / 1.05) }
unTour()
controle("les rapprocher élargit le temps",
         modele.viewport.columnsPerPoint > echelleRapprochee,
         String(format: "%.4f → %.4f colonne par point",
                echelleRapprochee, modele.viewport.columnsPerPoint))

let casesAvantPincement = modele.viewport.binsPerPoint
surface.majuscule = true
for _ in 0..<10 { gestes.pincement(a: ancre, facteur: 1.05) }
surface.majuscule = false
unTour()
controle("⇧ + pincement change l'échelle des fréquences",
         modele.viewport.binsPerPoint != casesAvantPincement,
         String(format: "%.4f → %.4f case par point",
                casesAvantPincement, modele.viewport.binsPerPoint))

// Le premier évènement d'un geste arrive parfois avec une échelle nulle, l'écart de
// référence n'étant pas encore établi. Le laisser passer donnerait un zoom infini,
// c'est-à-dire une image blanche dont on ne revient pas.
let echelleAvantZero = modele.viewport.columnsPerPoint
gestes.pincement(a: ancre, facteur: 0)
gestes.pincement(a: ancre, facteur: -1)
unTour()
controle("un facteur nul ou négatif ne fait rien",
         modele.viewport.columnsPerPoint == echelleAvantZero,
         String(format: "%.4f inchangé", echelleAvantZero))

// MARK: - La boucle

print("\n=== La boucle ===")

/// Un glisser complet, de `x0` à `x1`, dans la bande du haut.
func glisser(de x0: Double, a x1: Double, dans y: Double) {
    gestes.boutonEnfonce(a: CGPoint(x: x0, y: y))
    // Plusieurs pas plutôt qu'un seul : c'est le chemin que suit une vraie souris,
    // et un glisser qui ne se lit qu'à son point d'arrivée cacherait une borne qui
    // ne suit pas.
    for i in 1...8 {
        let x = x0 + (x1 - x0) * Double(i) / 8
        gestes.sourisDeplacee(a: CGPoint(x: x, y: y), boutonEnfonce: true)
    }
    gestes.boutonRelache(a: CGPoint(x: x1, y: y))
}

surface.controle = true   // sans aimantation : la mesure porte sur le geste
glisser(de: 200, a: 500, dans: 6)
surface.controle = false
unTour()

let attenduDebut = modele.time(atPoint: 200)
let attenduFin = modele.time(atPoint: 500)
if let boucle = modele.loop {
    controle("un glisser dans la réglette trace une boucle",
             abs(boucle.lowerBound - attenduDebut) < 0.05
             && abs(boucle.upperBound - attenduFin) < 0.05,
             String(format: "%.2f–%.2f s, attendu %.2f–%.2f s",
                    boucle.lowerBound, boucle.upperBound, attenduDebut, attenduFin))
} else {
    controle("un glisser dans la réglette trace une boucle", false, "aucune boucle")
}

controle("la souris est rendue à la fin du glisser", !surface.capturee,
         surface.capturee ? "encore capturée" : "relâchée")

// Le curseur au-dessus d'un bord : c'est ce qui laisse deviner qu'une boucle posée
// se rattrape, et rien d'autre ne le dit à l'utilisateur.
gestes.sourisDeplacee(a: CGPoint(x: 500, y: 6), boutonEnfonce: false)
controle("le curseur annonce le bord de la boucle", surface.forme == .largeur,
         "\(surface.forme)")
gestes.sourisDeplacee(a: CGPoint(x: 350, y: 6), boutonEnfonce: false)
controle("le curseur annonce qu'on peut la déplacer", surface.forme == .main,
         "\(surface.forme)")
gestes.sourisDeplacee(a: CGPoint(x: 900, y: 300), boutonEnfonce: false)
controle("et redevient une flèche ailleurs", surface.forme == .fleche,
         "\(surface.forme)")

// Le déplacement par le corps : la durée doit se conserver, sans quoi attraper une
// boucle pour la décaler la déformerait — ce qui ne se voit qu'après coup.
let dureeAvant = modele.loop.map { $0.upperBound - $0.lowerBound } ?? 0
surface.controle = true
glisser(de: 350, a: 450, dans: 6)
surface.controle = false
unTour()
let dureeApres = modele.loop.map { $0.upperBound - $0.lowerBound } ?? 0
controle("déplacer la boucle conserve sa durée", abs(dureeApres - dureeAvant) < 0.05,
         String(format: "%.3f s → %.3f s", dureeAvant, dureeApres))

// Le double-clic : deux appuis rapprochés au même endroit effacent la boucle.
gestes.boutonEnfonce(a: CGPoint(x: 400, y: 6))
gestes.boutonRelache(a: CGPoint(x: 400, y: 6))
gestes.boutonEnfonce(a: CGPoint(x: 400, y: 6))
unTour()
controle("un double-clic dans la réglette efface la boucle", modele.loop == nil,
         modele.loop == nil ? "effacée" : "toujours là")
gestes.boutonRelache(a: CGPoint(x: 400, y: 6))

// MARK: - L'aimantation

print("\n=== L'aimantation ===")

// Les bornes se posent au clavier, sur des instants qu'on choisit : c'est le même
// chemin que le glisser, sans le bruit de la souris.
modele.seek(to: 4.0)
gestes.touche(.crochetOuvrant)
modele.seek(to: 9.0)
gestes.touche(.crochetFermant)
unTour()
if let boucle = modele.loop {
    controle("« [ » et « ] » posent les bornes à la tête de lecture",
             abs(boucle.lowerBound - 4) < 0.5 && abs(boucle.upperBound - 9) < 0.5,
             String(format: "%.2f–%.2f s", boucle.lowerBound, boucle.upperBound))
} else {
    controle("« [ » et « ] » posent les bornes à la tête de lecture", false,
             "aucune boucle")
}

// Le même glisser, avec et sans Ctrl : les deux ne doivent **pas** donner la même
// chose, sinon l'aimantation n'existe pas — et c'est le genre de réglage qui se perd
// sans que rien ne le dise.
/// Le harnais joue les deux glissers en quelques microsecondes, au même endroit :
/// pour les gestes c'est un double-clic, et le second effacerait la boucle au lieu
/// de la tracer. Une vraie main ne peut pas produire cela — mais le laisser passer
/// ferait échouer un contrôle pour une raison qui n'est pas celle qu'il mesure.
func attendreQueLeDoubleClicExpire() { Thread.sleep(forTimeInterval: 0.6) }

modele.loop = nil
surface.controle = true
attendreQueLeDoubleClicExpire()
glisser(de: 210, a: 470, dans: 6)
let libre = modele.loop
modele.loop = nil
surface.controle = false
attendreQueLeDoubleClicExpire()
glisser(de: 210, a: 470, dans: 6)
let aimante = modele.loop
unTour()
if let libre, let aimante {
    controle("Ctrl pendant le glisser libère les bornes de la grille",
             libre != aimante,
             String(format: "libre %.3f–%.3f s, aimanté %.3f–%.3f s",
                    libre.lowerBound, libre.upperBound,
                    aimante.lowerBound, aimante.upperBound))
} else {
    controle("Ctrl pendant le glisser libère les bornes de la grille", false,
             "l'un des deux glissers n'a rien tracé")
}

// MARK: - Le clavier

print("\n=== Le clavier ===")

modele.loop = 2...5
gestes.touche(.echappement)
controle("Échap efface la boucle", modele.loop == nil, "effacée")

let boucleActive = modele.loopEnabled
gestes.touche(.l)
controle("« L » bascule la boucle", modele.loopEnabled != boucleActive,
         "\(boucleActive) → \(modele.loopEnabled)")

modele.seek(to: 10)
gestes.touche(.gauche)
controle("← recule d'une seconde", abs(modele.playhead - 9) < 0.01,
         String(format: "%.2f s", modele.playhead))
surface.majuscule = true
gestes.touche(.gauche)
surface.majuscule = false
controle("⇧ + ← recule de cinq", abs(modele.playhead - 4) < 0.01,
         String(format: "%.2f s", modele.playhead))

controle("« R » ouvre le panneau des réglages",
         { let avant = panneau.ouvert; _ = gestes.touche(.r); return panneau.ouvert != avant }(),
         panneau.ouvert ? "ouvert" : "refermé")

surface.controle = true
_ = gestes.touche(.o)
surface.controle = false
controle("Ctrl+O demande le sélecteur de fichiers",
         surface.ouverturesDemandees == 1, "\(surface.ouverturesDemandees) demande(s)")

controle("une touche qui n'est liée à rien est laissée au système",
         !gestes.touche(.o), "« O » nu")

// MARK: - Ce qui est posé sur l'image

print("\n=== Le panneau et la colonne ===")

// Le panneau est ouvert par « R » juste au-dessus. Un clic dedans ne doit pas
// déplacer la tête de lecture par-dessous : c'est la faute qui se voit le plus mal,
// parce qu'on croit avoir tourné un réglage et on a aussi perdu sa place.
if !panneau.ouvert { _ = gestes.touche(.r) }
unTour()
modele.seek(to: 12)
let teteAvant = modele.playhead
let dansLePanneau = CGPoint(x: surface.taillePoints.largeur - 60, y: 200)
gestes.boutonEnfonce(a: dansLePanneau)
gestes.boutonRelache(a: dansLePanneau)
unTour()
controle("un clic dans le panneau ne déplace pas la tête de lecture",
         abs(modele.playhead - teteAvant) < 0.01,
         String(format: "%.2f s", modele.playhead))

gestes.sourisDeplacee(a: dansLePanneau, boutonEnfonce: false)
controle("survoler le panneau met l'image en retrait",
         modele.pointerOverControls, "\(modele.pointerOverControls)")

gestes.clicDroit(a: CGPoint(x: 400, y: 300))
controle("le clic droit est passé à la plateforme",
         surface.menusDemandes == 1, "\(surface.menusDemandes) demande(s)")

gestes.sourisSortie()
controle("la souris qui sort efface ce qui était survolé",
         modele.hover == nil && surface.forme == .fleche, "rien de survolé")

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) vérification(s) en échec.")
    exit(1)
}
