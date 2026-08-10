import Foundation
import SpectreCore

// La chaîne de lecture, en rendu hors ligne : aucun périphérique, donc
// reproductible partout — y compris sur la machine où elle devra tourner.
//
// Ce qui s'y vérifie est ce qu'`AVAudioPlayerNode` rendait jusqu'ici comme
// service : la position exacte, la boucle qui repart sans trou au milieu d'un
// bloc, et la transparence quand rien n'est demandé. Ce qui ne s'y vérifie pas,
// et ne le peut pas, c'est la ponctualité : un rendu hors ligne n'a pas
// d'échéance.

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    print("  \(condition ? "✓" : "✗") \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

let fs = 48000.0
let durée = 4.0
let total = Int(fs * durée)

/// Une rampe : chaque échantillon dit d'où il vient, ce qui rend un saut ou une
/// répétition immédiatement lisible.
let source = (0..<total).map { Float($0) / Float(total) }

/// Rend `frames` images et rend la voie gauche.
func rendre(_ chaîne: inout PlaybackChain, frames: Int, bloc: Int = 512) -> [Float] {
    var sortie = [Float]()
    var tampon = [Float](repeating: 0, count: bloc * 2)
    while sortie.count < frames {
        let voulu = min(bloc, frames - sortie.count)
        let rendues = tampon.withUnsafeMutableBufferPointer {
            chaîne.render(into: $0, frames: voulu, outputChannels: 2)
        }
        for i in 0..<voulu { sortie.append(tampon[i * 2]) }
        if rendues < voulu { break }
    }
    return sortie
}

titre("Lecture simple")
var simple = PlaybackChain(samples: source, sampleRate: fs)
verifie(abs(simple.duration - durée) < 1e-9, "la durée est celle du fichier",
        String(format: "%.3f s", simple.duration))
let début = rendre(&simple, frames: 1000)
var écart: Float = 0
for i in 0..<1000 { écart = max(écart, abs(début[i] - source[i])) }
verifie(écart == 0, "sans filtre ni boucle, les échantillons sortent tels quels",
        String(format: "écart %.1e", écart))
verifie(abs(simple.currentTime - 1000 / fs) < 1e-9, "la position suit les images rendues",
        String(format: "%.5f s", simple.currentTime))

titre("Fin du morceau")
var jusquAuBout = PlaybackChain(samples: source, sampleRate: fs)
jusquAuBout.seek(to: durée - 0.01)
var tampon = [Float](repeating: 9, count: 2048 * 2)
let rendues = tampon.withUnsafeMutableBufferPointer {
    jusquAuBout.render(into: $0, frames: 2048, outputChannels: 2)
}
verifie(rendues == 480, "on s'arrête au dernier échantillon, pas après",
        "\(rendues) images pour 2048 demandées")
// Un périphérique à qui l'on rend moins que demandé rejoue le bloc précédent si
// le reste n'est pas mis à zéro : cela s'entend comme un hoquet.
verifie(tampon[(rendues * 2)...].allSatisfy { $0 == 0 }, "le reste du tampon est mis à zéro")

titre("Boucle")
var bouclée = PlaybackChain(samples: source, sampleRate: fs)
bouclée.setLoop(1.0...1.5)
verifie(bouclée.loop == 1.0...1.5, "la boucle est posée")
verifie(abs(bouclée.currentTime - 1.0) < 1e-9, "poser une boucle depuis dehors y fait entrer",
        String(format: "%.3f s", bouclée.currentTime))

// Deux tours et demi, avec une taille de bloc qui ne tombe pas sur la fin de la
// boucle : c'est le cas qui compte, celui où le repli se fait en plein bloc.
let deuxTours = rendre(&bouclée, frames: 60_000, bloc: 777)
verifie(deuxTours.count == 60_000, "la boucle ne s'arrête jamais",
        "\(deuxTours.count) images rendues")

let longueur = Int(0.5 * fs)                 // 24 000 images par tour
let premier = Array(source[Int(1.0 * fs)..<Int(1.5 * fs)])
var pire: Float = 0
for i in 0..<60_000 {
    pire = max(pire, abs(deuxTours[i] - premier[i % longueur]))
}
verifie(pire == 0, "chaque tour redonne exactement le même passage",
        String(format: "écart %.1e sur 2,5 tours", pire))

// Le trou serait ici : à la jonction, l'échantillon suivant doit être celui du
// début de la boucle, pas un zéro ni une répétition.
let jonction = longueur
verifie(deuxTours[jonction - 1] == premier[longueur - 1] && deuxTours[jonction] == premier[0],
        "la reprise est sans trou", "jonction à l'image \(jonction)")

titre("Boucle retirée")
bouclée.setLoop(nil)
verifie(bouclée.loop == nil, "la boucle se retire")
var trop = PlaybackChain(samples: source, sampleRate: fs)
trop.setLoop(1.0...1.01)
verifie(trop.loop == nil, "une boucle plus courte que 50 ms n'en est pas une")

titre("Bande écoutée")
var filtrée = PlaybackChain(samples: source, sampleRate: fs)
filtrée.setBand(200...2000)
let filtré = rendre(&filtrée, frames: 4096)
var identique = true
for i in 0..<4096 where filtré[i] != source[i] { identique = false; break }
verifie(!identique, "une bande demandée change bien ce qui sort")

var entière = PlaybackChain(samples: source, sampleRate: fs)
entière.setBand(nil)
let brut = rendre(&entière, frames: 4096)
var écartBrut: Float = 0
for i in 0..<4096 { écartBrut = max(écartBrut, abs(brut[i] - source[i])) }
verifie(écartBrut == 0, "aucune bande demandée, aucun échantillon touché",
        String(format: "écart %.1e", écartBrut))

titre("Saut")
var sauteuse = PlaybackChain(samples: source, sampleRate: fs)
sauteuse.setBand(200...2000)
_ = rendre(&sauteuse, frames: 4096)
sauteuse.seek(to: 2.0)
verifie(abs(sauteuse.currentTime - 2.0) < 1e-9, "la tête se pose où on l'a mise",
        String(format: "%.3f s", sauteuse.currentTime))
// Sans remise à zéro, les mémoires du biquad portent encore le signal d'avant :
// on l'entendrait claquer.
let après = rendre(&sauteuse, frames: 4)
verifie(abs(après[0]) < 0.01, "le filtre repart de zéro, sans claquement",
        String(format: "premier échantillon %.5f", après[0]))

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
