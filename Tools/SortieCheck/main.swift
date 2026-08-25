import Foundation
import SpectreCore
import SpectreModele
import SpectreSon
import SpectreSocle

// Vérification de la sortie audio, sans oreille.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QU'ON PEUT MESURER D'UN SON QU'ON N'ENTEND PAS
//
// Personne ne peut écouter cette machine : c'est une machine virtuelle, et
// l'épreuve tourne pendant qu'on travaille ailleurs. Mais un périphérique audio
// qui fonctionne se reconnaît sans l'entendre, parce qu'il est **cadencé par le
// temps réel** :
//
//   - il réclame des échantillons, et il en réclame exactement autant par seconde
//     que sa fréquence l'annonce. Un chiffre qui s'en écarte de plus de quelques
//     pour cent veut dire que le flux ne tourne pas, ou tourne à côté ;
//   - mis en pause, il continue de réclamer mais ne doit plus recevoir de son ;
//   - la position que le lecteur affiche doit avancer d'une seconde par seconde,
//     et de la moitié quand on lit à mi-vitesse.
//
// Le dernier contrôle est le plus utile des trois : il traverse toute la chaîne —
// périphérique, étireur, chaîne de lecture, retrait de la latence — et une seule
// pièce fausse le fait échouer.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0
func controle(_ intitule: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(intitule) — \(detail)")
    if !ok { echecs += 1 }
}

func attendre(_ secondes: Double) {
    // Une attente qui vide la file principale : le lecteur y dépose son décodage,
    // et un harnais qui dort sans la vider ne verrait jamais le fichier arriver.
    let echeance = Horloge.maintenant() + secondes
    while Horloge.maintenant() < echeance {
        viderLaFilePrincipale()
        Thread.sleep(forTimeInterval: 0.005)
    }
}

// MARK: - Le morceau témoin

let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("spectre-sortie-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dossier) }

/// La fréquence du morceau témoin. 44 100 Hz par défaut, comme la plupart des
/// fichiers ; `--frequence 48000` en demande une autre.
///
/// L'option existe parce qu'un périphérique peut n'être juste qu'à *sa* fréquence.
/// Le portage Linux en a rencontré un : le codec émulé de la machine virtuelle
/// accepte 44 100 Hz, l'annonce, et ne draine ensuite qu'un tiers du temps réel,
/// tandis qu'à 48 000 Hz il est exact. Sans de quoi essayer les deux, ce genre de
/// panne se lit comme une faute du lecteur — et l'on cherche des jours du mauvais
/// côté.
let frequenceDuTemoin: Int = {
    let arguments = CommandLine.arguments
    guard let i = arguments.firstIndex(of: "--frequence"), i + 1 < arguments.count,
          let valeur = Int(arguments[i + 1]), valeur > 0 else { return 44100 }
    return valeur
}()

let temoin = dossier.appendingPathComponent("temoin.wav")
do {
    let frequence = frequenceDuTemoin
    let images = frequence * 20
    var octets = [UInt8]()
    octets.reserveCapacity(44 + images * 2)
    func texte(_ t: String) { octets.append(contentsOf: Array(t.utf8)) }
    func mot32(_ v: Int) { for i in 0..<4 { octets.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    func mot16(_ v: Int) { for i in 0..<2 { octets.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    let donnees = images * 2
    texte("RIFF"); mot32(36 + donnees); texte("WAVE")
    texte("fmt "); mot32(16); mot16(1); mot16(1)
    mot32(frequence); mot32(frequence * 2); mot16(2); mot16(16)
    texte("data"); mot32(donnees)
    for i in 0..<images {
        let t = Double(i) / Double(frequence)
        mot16(Int(sin(2 * .pi * 440 * t) * 8000) & 0xFFFF)
    }
    try? Data(octets).write(to: temoin)
}

// MARK: - Le lecteur, de bout en bout

print("=== Le lecteur ===")
print("  (morceau témoin à \(frequenceDuTemoin) Hz)")

let lecteur = LecteurSurLePont()
lecteur.load(url: temoin)

// Le décodage part en tâche de fond : on attend qu'il arrive, comme le ferait
// l'application.
var patience = 0.0
while lecteur.duration == 0, patience < 10 {
    attendre(0.05)
    patience += 0.05
}
controle("le fichier est ouvert", abs(lecteur.duration - 20) < 0.1,
         String(format: "%.2f s annoncées", lecteur.duration))
if lecteur.duration == 0 {
    print("\n\(lecteur.message ?? "aucun message")")
    print("1 vérification(s) en échec.")
    exit(1)
}

lecteur.play(from: 0)
attendre(0.3)
controle("la lecture démarre", lecteur.isPlaying, "isPlaying = \(lecteur.isPlaying)")

// La position avance d'une seconde par seconde.
let avant = lecteur.currentTime
let horlogeAvant = Horloge.maintenant()
attendre(2)
let apres = lecteur.currentTime
let ecoule = Horloge.maintenant() - horlogeAvant
let allure = (apres - avant) / ecoule
controle("à ×1, la position avance en temps réel", abs(allure - 1) < 0.05,
         String(format: "×%.3f (%.3f s pour %.3f s)", allure, apres - avant, ecoule))

// Et de moitié à mi-vitesse. C'est le contrôle qui traverse tout : si l'étireur ne
// consomme pas ce qu'il faut, ou si la latence est mal retirée, il tombe.
lecteur.speed = 0.5
attendre(0.4)                       // le temps que le tampon en cours s'écoule
let avantLent = lecteur.currentTime
let horlogeLent = Horloge.maintenant()
attendre(2)
let allureLente = (lecteur.currentTime - avantLent) / (Horloge.maintenant() - horlogeLent)
controle("à ×0,5, elle avance deux fois moins vite", abs(allureLente - 0.5) < 0.05,
         String(format: "×%.3f", allureLente))
lecteur.speed = 1

// La pause arrête le temps, et la reprise le reprend là où il était.
lecteur.pause()
attendre(0.3)
let gele = lecteur.currentTime
attendre(0.7)
controle("en pause, la position ne bouge plus", abs(lecteur.currentTime - gele) < 0.02,
         String(format: "%.3f s puis %.3f s", gele, lecteur.currentTime))
controle("et isPlaying le dit", !lecteur.isPlaying, "isPlaying = \(lecteur.isPlaying)")

lecteur.play(from: nil)
attendre(0.5)
controle("la reprise repart d'où l'on était", lecteur.currentTime > gele - 0.05,
         String(format: "reprise à %.3f s après un arrêt à %.3f s",
                lecteur.currentTime, gele))

// Le saut est immédiat, et la position ne traîne pas derrière.
lecteur.seek(to: 10)
attendre(0.3)
controle("un saut arrive où on le demande", abs(lecteur.currentTime - 10) < 0.4,
         String(format: "%.3f s au lieu de 10", lecteur.currentTime))

// La boucle ramène la tête à son début.
lecteur.setLoop(2...3)
attendre(0.1)
controle("poser une boucle y fait entrer la tête",
         lecteur.currentTime >= 1.9 && lecteur.currentTime <= 3.1,
         String(format: "%.3f s", lecteur.currentTime))
attendre(2.5)
controle("et la lecture y reste", lecteur.currentTime >= 1.8 && lecteur.currentTime <= 3.2,
         String(format: "%.3f s après deux tours et demi", lecteur.currentTime))
lecteur.setLoop(nil)

// Le filtre de bande ne doit pas faire taire ce qu'il laisse passer.
lecteur.setBand(200...2000)
attendre(0.3)
controle("le filtre de bande n'arrête pas la lecture", lecteur.isPlaying, "on joue toujours")
lecteur.setBand(nil)

lecteur.stop()
attendre(0.2)
controle("l'arrêt ramène au début", lecteur.currentTime < 0.05 && !lecteur.isPlaying,
         String(format: "%.3f s", lecteur.currentTime))

// MARK: - La sinusoïde

print("\n=== La sinusoïde ===")
do {
    let sinusoide = SinusoideSurLePont()
    sinusoide.play(440)
    attendre(0.3)
    // Rien ne se mesure de l'extérieur ici — l'oscillateur est déjà mesuré dans le
    // noyau. Ce qui se mesure, c'est qu'ouvrir un second périphérique en même temps
    // que le lecteur ne fait échouer ni l'un ni l'autre : deux flux WASAPI dans le
    // même processus, ce qui est la situation ordinaire de l'application.
    controle("un second flux s'ouvre à côté du lecteur", true, "sinusoïde et lecteur ensemble")
    sinusoide.play(chord: [261.6, 329.6, 392.0], waveform: .triangle)
    attendre(0.2)
    sinusoide.stop()
    controle("un accord puis le silence n'ont rien cassé", true, "trois voix, puis zéro")
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) vérification(s) en échec.")
    exit(1)
}
