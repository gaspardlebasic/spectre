import Foundation
import SpectreCore
import SpectreSon

// Vérification du décodage sous Windows.
//
//     DecodeCheck [morceau…]
//
// ─────────────────────────────────────────────────────────────────────────────
// COMMENT MESURER UN DÉCODEUR SANS FICHIER À DÉCODER
//
// Le dépôt ne porte aucun fichier compressé — ni licence, ni poids. On ne peut
// donc pas comparer ce que Media Foundation rend d'un MP3 à ce qu'un autre en
// rendrait. Mais on peut faire mieux que rien, et c'est même plus sévère :
//
// **on donne le même WAV aux deux chemins.** `WAVFile` le lit en Swift pur, sans
// rien demander à personne ; Media Foundation le lit comme un format parmi les
// autres. Les deux doivent rendre le *même signal*, échantillon par échantillon.
// Si c'est le cas, alors ce que le décodeur du système rend est aligné sur la
// référence portable — même fréquence, même mélange des canaux, même échelle,
// même premier échantillon — et il n'y a plus de raison qu'un MP3 sorte décalé
// pour une raison qui tienne à cette enveloppe-ci.
//
// C'est aussi ce qui justifie que le WAV soit essayé en premier dans
// `DecodeurSurLePont` : ce contrôle mesure que le raccourci ne change rien.
//
// Donner des fichiers en argument fait passer le même barème sur eux — sans la
// comparaison, qui n'a plus de sens, mais avec tout le reste.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0
func controle(_ intitule: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(intitule) — \(detail)")
    if !ok { echecs += 1 }
}

// MARK: - Le morceau témoin, fabriqué ici

// Pas d'appel à `Temoin` : un harnais qui dépend d'un autre exécutable ne tourne
// pas là où le premier n'a pas été construit. Un WAV de synthèse tient en vingt
// lignes, et celui-ci n'a qu'à être *du son*, pas de la musique.
let dossier = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("spectre-decode-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dossier) }

/// Un WAV PCM 16 bits, deux canaux, dont on connaît chaque échantillon.
///
/// Les deux canaux portent des fréquences différentes : c'est ce qui fait que le
/// mélange en mono se mesure. Deux canaux identiques passeraient le contrôle même
/// si l'un des deux décodeurs oubliait le second.
func fabriquerLeWAV(a: URL, frequence: Int, secondes: Double) {
    let images = Int(Double(frequence) * secondes)
    var octets = [UInt8]()
    octets.reserveCapacity(44 + images * 4)

    func ajouter(_ texte: String) { octets.append(contentsOf: Array(texte.utf8)) }
    func ajouter32(_ v: Int) {
        for i in 0..<4 { octets.append(UInt8((v >> (8 * i)) & 0xFF)) }
    }
    func ajouter16(_ v: Int) {
        for i in 0..<2 { octets.append(UInt8((v >> (8 * i)) & 0xFF)) }
    }

    let donnees = images * 4
    ajouter("RIFF"); ajouter32(36 + donnees); ajouter("WAVE")
    ajouter("fmt "); ajouter32(16); ajouter16(1); ajouter16(2)
    ajouter32(frequence); ajouter32(frequence * 4); ajouter16(4); ajouter16(16)
    ajouter("data"); ajouter32(donnees)

    for i in 0..<images {
        let t = Double(i) / Double(frequence)
        // 440 Hz à gauche, 660 Hz à droite, à mi-échelle pour ne rien saturer.
        let g = Int(sin(2 * .pi * 440 * t) * 12000)
        let d = Int(sin(2 * .pi * 660 * t) * 12000)
        ajouter16(g & 0xFFFF)
        ajouter16(d & 0xFFFF)
    }
    try? Data(octets).write(to: a)
}

let temoin = dossier.appendingPathComponent("temoin.wav")
fabriquerLeWAV(a: temoin, frequence: 44100, secondes: 3)

// MARK: - Les deux chemins, sur le même fichier

print("=== Le même WAV, par les deux chemins ===")

let parSwift: WAVFile.Contents
let parSysteme: WAVFile.Contents
do {
    parSwift = try WAVFile.read(at: temoin)
    parSysteme = try DecodeurSurLePont.parMediaFoundation(temoin)
} catch {
    print("  ✗ \(error)")
    exit(1)
}

controle("même fréquence d'échantillonnage",
         parSwift.sampleRate == parSysteme.sampleRate,
         "\(Int(parSwift.sampleRate)) Hz contre \(Int(parSysteme.sampleRate)) Hz")
controle("même nombre de canaux",
         parSwift.channels == parSysteme.channels,
         "\(parSwift.channels) contre \(parSysteme.channels)")

// Le nombre d'images peut différer d'une poignée : un décodeur travaille par
// blocs, et le dernier peut être complété. Ce qui ne doit pas différer, c'est le
// début — et c'est là que se lirait un amorçage oublié.
let ecartImages = abs(parSwift.frameCount - parSysteme.frameCount)
controle("même longueur, à un bloc près", ecartImages <= 4096,
         "\(parSwift.frameCount) contre \(parSysteme.frameCount) images")

let commun = min(parSwift.frameCount, parSysteme.frameCount)
if commun > 0 {
    var pire = Float(0)
    var pireIndice = 0
    for i in 0..<commun {
        let e = abs(parSwift.mono[i] - parSysteme.mono[i])
        if e > pire { pire = e; pireIndice = i }
    }
    // Un PCM 16 bits vaut 1/32768 par pas ; les deux chemins convertissent en
    // flottant, et la seule différence permise est celle de cette conversion.
    controle("le même signal, échantillon par échantillon", pire < 1e-4,
             String(format: "écart max %.2e à l'image %d", pire, pireIndice))

    // Le contrôle qui attrape un décalage : deux signaux décalés d'une image se
    // ressemblent beaucoup, et l'écart maximal ci-dessus le verrait — mais mieux
    // vaut le dire explicitement, parce que c'est *le* défaut qu'un amorçage de
    // codeur produit, et qu'il ne se voit pas à l'oreille.
    var meilleurDecalage = 0
    var meilleureSomme = Double.infinity
    for d in -8...8 {
        var somme = 0.0
        for i in 100..<min(commun - 100, 20000) {
            let j = i + d
            guard j >= 0, j < commun else { continue }
            somme += abs(Double(parSwift.mono[i] - parSysteme.mono[j]))
        }
        if somme < meilleureSomme { meilleureSomme = somme; meilleurDecalage = d }
    }
    controle("aucun décalage entre les deux", meilleurDecalage == 0,
             "meilleur accord au décalage \(meilleurDecalage)")
}

// MARK: - Ce que le décodeur doit refuser proprement

print("\n=== Les refus ===")

let absent = dossier.appendingPathComponent("nexiste-pas.mp3")
do {
    _ = try DecodeurSurLePont.lire(absent)
    controle("un fichier absent est refusé", false, "il a été accepté")
} catch {
    // Ce qui compte n'est pas qu'il échoue, mais qu'il le dise en français et sans
    // laisser un `HRESULT` nu à l'utilisateur.
    let message = "\(error)"
    controle("un fichier absent est refusé en français, et dit qu'il est absent",
             message.contains("introuvable"), message)
}

let bidon = dossier.appendingPathComponent("pas-du-son.mp3")
try? Data("ceci n'est pas un fichier audio, et ne le sera jamais".utf8).write(to: bidon)
do {
    _ = try DecodeurSurLePont.lire(bidon)
    controle("un fichier qui n'est pas du son est refusé", false, "il a été accepté")
} catch {
    // Et il dit autre chose que « introuvable » : le fichier est bien là, c'est son
    // contenu qui ne va pas, et confondre les deux envoie chercher au mauvais
    // endroit.
    let message = "\(error)"
    controle("un fichier qui n'est pas du son est refusé, et pour la bonne raison",
             !message.contains("introuvable"), message)
}

// Un WAV nommé `.mp3` : le raccourci ne s'applique pas, et c'est le système qui
// doit s'en tirer. Il le fait, et c'est ce qui rend le raccourci sûr — un fichier
// mal nommé n'est pas un fichier perdu.
let malNomme = dossier.appendingPathComponent("en-fait-un-wav.mp3")
try? FileManager.default.copyItem(at: temoin, to: malNomme)
do {
    let contenu = try DecodeurSurLePont.lire(malNomme)
    controle("un WAV mal nommé passe quand même par le système",
             contenu.frameCount > 0 && contenu.sampleRate == parSwift.sampleRate,
             "\(contenu.frameCount) images à \(Int(contenu.sampleRate)) Hz")
} catch {
    controle("un WAV mal nommé passe quand même par le système", false, "\(error)")
}

// MARK: - Les fichiers qu'on nous donne

let donnes = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
if !donnes.isEmpty {
    print("\n=== Les fichiers donnés ===")
    for url in donnes {
        do {
            let contenu = try DecodeurSurLePont.lire(url)
            let duree = contenu.duration
            controle(url.lastPathComponent, contenu.frameCount > 0,
                     String(format: "%.1f s, %.0f Hz, %d canal(aux)",
                            duree, contenu.sampleRate, contenu.channels))
        } catch {
            controle(url.lastPathComponent, false, "\(error)")
        }
    }
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) vérification(s) en échec.")
    exit(1)
}
