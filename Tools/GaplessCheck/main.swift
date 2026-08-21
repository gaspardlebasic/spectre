import Foundation
import SpectreCore

// Vérifie la lecture des métadonnées « sans blanc » — l'amorçage et le
// remplissage que les formats à trame ajoutent au signal.
//
//     GaplessCheck                 les cas construits à la main
//     GaplessCheck morceau.m4a     ce que ce fichier-là déclare
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI DES CONTENEURS FABRIQUÉS ICI
//
// Ce qui est fragile dans `GaplessTrim`, ce n'est pas l'arithmétique : c'est
// l'analyse des octets. Un MP4 fabriqué sur mesure met celle-ci à l'épreuve
// sans exiger qu'un fichier encodé dorme dans le dépôt — et permet d'écrire
// exprès les cas qu'aucun encodeur ordinaire ne produirait : boîte de 64 bits,
// première édition vide, piste sans table.
//
// Ce qu'un fichier fabriqué ne prouve pas, c'est que les nombres lus soient les
// bons. Cela se mesure une fois, sur de vrais fichiers, en comparant à ce que
// `AVAudioFile` rend sur macOS — les chiffres sont dans WINDOWS.md.
// ─────────────────────────────────────────────────────────────────────────────

var échecs = 0

func titre(_ t: String) { print("\n=== \(t) ===") }

func exige(_ condition: Bool, _ quoi: String) {
    print("  \(condition ? "✓" : "✗") \(quoi)")
    if !condition { échecs += 1 }
}

func écrit(_ url: URL, _ octets: [UInt8]) {
    try? Data(octets).write(to: url)
}

let dossier = FileManager.default.temporaryDirectory
    .appendingPathComponent("spectre-gapless-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dossier) }

// ═══════════════════════════════════════════════════════ construction d'un MP4

func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}

func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

/// Une boîte : taille, type, contenu.
func boîte(_ type: String, _ contenu: [UInt8]) -> [UInt8] {
    be32(UInt32(contenu.count + 8)) + [UInt8](type.utf8) + contenu
}

/// La même, en taille 64 bits — la forme rare que produisent les gros fichiers.
func boîteLongue(_ type: String, _ contenu: [UInt8]) -> [UInt8] {
    be32(1) + [UInt8](type.utf8) + be64(UInt64(contenu.count + 16)) + contenu
}

// Les octets s'accumulent avec `+=` sur une variable typée plutôt que par une
// longue chaîne de `+` entre littéraux : à cinq ou six termes, l'inférence de
// types de ce genre d'expression dépasse le temps imparti sur une machine
// lente — ce qui compile ici et échoue en intégration continue, pour une raison
// qui n'a rien à voir avec le code.

func mvhd(échelle: UInt32) -> [UInt8] {
    // version 0, drapeaux, création, modification, échelle, durée, puis le reste
    // dont rien ici ne dépend.
    var contenu: [UInt8] = [0, 0, 0, 0]
    contenu += be32(0)
    contenu += be32(0)
    contenu += be32(échelle)
    contenu += be32(0)
    contenu += [UInt8](repeating: 0, count: 80)
    return boîte("mvhd", contenu)
}

func mdhd(échelle: UInt32, durée: UInt32) -> [UInt8] {
    var contenu: [UInt8] = [0, 0, 0, 0]
    contenu += be32(0)
    contenu += be32(0)
    contenu += be32(échelle)
    contenu += be32(durée)
    contenu += [0, 0, 0, 0]
    return boîte("mdhd", contenu)
}

func elst(_ entrées: [(durée: UInt32, début: Int32)]) -> [UInt8] {
    var contenu: [UInt8] = [0, 0, 0, 0] + be32(UInt32(entrées.count))
    for e in entrées {
        contenu += be32(e.durée)
        contenu += be32(UInt32(bitPattern: e.début))
        contenu += be32(0x0001_0000)
    }
    return boîte("elst", contenu)
}

/// L'étiquette qu'écrivent les outils d'Apple, dans ses trois boîtes gigognes.
func iTunSMPB(amorce: Int, remplissage: Int, utiles: Int) -> [UInt8] {
    func hex(_ v: Int, _ n: Int) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(n - s.count, 0)) + s
    }
    let texte = " 00000000 \(hex(amorce, 8)) \(hex(remplissage, 8)) \(hex(utiles, 16))"
              + " 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000"
    var charge: [UInt8] = be32(1)
    charge += be32(0)
    charge += [UInt8](texte.utf8)

    var contenuItem: [UInt8] = boîte("mean", be32(0) + [UInt8]("com.apple.iTunes".utf8))
    contenuItem += boîte("name", be32(0) + [UInt8]("iTunSMPB".utf8))
    contenuItem += boîte("data", charge)

    var contenuMeta: [UInt8] = be32(0)
    contenuMeta += boîte("ilst", boîte("----", contenuItem))
    return boîte("udta", boîte("meta", contenuMeta))
}

func mp4(échelleFilm: UInt32, échellePiste: UInt32,
         éditions: [(durée: UInt32, début: Int32)],
         longue: Bool = false, pisteMuette: Bool = false,
         smpb: (amorce: Int, remplissage: Int, utiles: Int)? = nil) -> [UInt8] {
    let mdia = boîte("mdia", mdhd(échelle: échellePiste, durée: 0))
    var trakContenu = mdia
    if !éditions.isEmpty { trakContenu += boîte("edts", elst(éditions)) }
    var moovContenu = mvhd(échelle: échelleFilm)
    // Une piste sans table d'édition avant la bonne : le lecteur doit passer à
    // la suivante plutôt que d'abandonner sur la première.
    if pisteMuette { moovContenu += boîte("trak", boîte("mdia", mdhd(échelle: 600, durée: 0))) }
    moovContenu += boîte("trak", trakContenu)
    if let smpb {
        moovContenu += iTunSMPB(amorce: smpb.amorce, remplissage: smpb.remplissage,
                                utiles: smpb.utiles)
    }
    let moov = longue ? boîteLongue("moov", moovContenu) : boîte("moov", moovContenu)
    var fichier: [UInt8] = boîte("ftyp", [UInt8]("M4A isom".utf8))
    fichier += boîte("free", [0, 0, 0, 0])
    fichier += moov
    return fichier
}

titre("MP4 : la table d'édition")

do {
    let url = dossier.appendingPathComponent("simple.m4a")
    écrit(url, mp4(échelleFilm: 44100, échellePiste: 44100,
                   éditions: [(durée: 264600, début: 2112)]))
    let info = GaplessTrim.read(at: url)
    exige(info?.priming == 2112, "l'amorçage vient de `media_time` — \(info?.priming ?? -1)")
    exige(info?.frames == 264600, "la longueur utile vient de la durée d'édition")
    let coupé = info?.apply(to: [Float](repeating: 0, count: 267264)).count
    exige(coupé == 264600, "267 264 échantillons décodés en donnent 264 600 — \(coupé ?? -1)")
}

do {
    // Ce que produit l'encodeur AAC du système : pas de table d'édition, mais
    // les trois nombres écrits en clair. Les valeurs sont celles mesurées sur un
    // vrai fichier de six secondes.
    let url = dossier.appendingPathComponent("smpb.m4a")
    écrit(url, mp4(échelleFilm: 44100, échellePiste: 44100, éditions: [],
                   smpb: (amorce: 2112, remplissage: 552, utiles: 264600)))
    let info = GaplessTrim.read(at: url)
    exige(info?.priming == 2112, "`iTunSMPB` donne l'amorçage — \(info?.priming ?? -1)")
    exige(info?.padding == 552, "et le remplissage — \(info?.padding ?? -1)")
    exige(info?.frames == 264600, "et la longueur utile — \(info?.frames ?? -1)")
    let coupé = info?.apply(to: [Float](repeating: 0, count: 267264)).count
    exige(coupé == 264600, "2 112 + 264 600 + 552 = 267 264, ce que Windows décode — \(coupé ?? -1)")
}

do {
    // L'étiquette l'emporte sur la table d'édition quand les deux sont là :
    // elle est en échantillons, sans conversion d'échelle qui puisse arrondir.
    let url = dossier.appendingPathComponent("lesdeux.m4a")
    écrit(url, mp4(échelleFilm: 600, échellePiste: 44100,
                   éditions: [(durée: 3600, début: 1024)],
                   smpb: (amorce: 2112, remplissage: 552, utiles: 264600)))
    exige(GaplessTrim.read(at: url)?.priming == 2112, "`iTunSMPB` passe avant `elst`")
}

do {
    // L'échelle du film et celle de la piste diffèrent presque toujours : la
    // durée d'édition se compte dans la première, l'amorçage dans la seconde.
    let url = dossier.appendingPathComponent("echelles.m4a")
    écrit(url, mp4(échelleFilm: 600, échellePiste: 44100,
                   éditions: [(durée: 3600, début: 1024)]))
    let info = GaplessTrim.read(at: url)
    exige(info?.priming == 1024, "l'amorçage se lit dans l'échelle de la piste")
    exige(info?.frames == 264600, "3 600/600 s à 44 100 Hz font 264 600 — \(info?.frames ?? -1)")
}

do {
    // Une édition à `-1` est un silence voulu, pas un amorçage : la suivante
    // porte l'information.
    let url = dossier.appendingPathComponent("vide.m4a")
    écrit(url, mp4(échelleFilm: 44100, échellePiste: 44100,
                   éditions: [(durée: 4410, début: -1), (durée: 264600, début: 2112)]))
    let info = GaplessTrim.read(at: url)
    exige(info?.priming == 2112, "une première édition vide est ignorée")
}

do {
    let url = dossier.appendingPathComponent("longue.m4a")
    écrit(url, mp4(échelleFilm: 44100, échellePiste: 44100,
                   éditions: [(durée: 264600, début: 2112)], longue: true))
    exige(GaplessTrim.read(at: url)?.priming == 2112, "une boîte de 64 bits se traverse")
}

do {
    let url = dossier.appendingPathComponent("deuxpistes.m4a")
    écrit(url, mp4(échelleFilm: 44100, échellePiste: 44100,
                   éditions: [(durée: 264600, début: 2112)], pisteMuette: true))
    exige(GaplessTrim.read(at: url)?.priming == 2112,
          "une piste sans table n'arrête pas la recherche")
}

do {
    let url = dossier.appendingPathComponent("sansedts.m4a")
    écrit(url, mp4(échelleFilm: 44100, échellePiste: 44100, éditions: []))
    exige(GaplessTrim.read(at: url) == nil, "sans table d'édition, il n'y a rien à couper")
}

do {
    // Un fichier tronqué au milieu d'une boîte ne doit pas faire sortir des
    // clous : le lecteur travaille sur des octets qu'il n'a pas écrits.
    let complet = mp4(échelleFilm: 44100, échellePiste: 44100,
                      éditions: [(durée: 264600, début: 2112)])
    for coupe in stride(from: 8, to: complet.count, by: 7) {
        let url = dossier.appendingPathComponent("tronque.m4a")
        écrit(url, Array(complet.prefix(coupe)))
        _ = GaplessTrim.read(at: url)
    }
    exige(true, "un fichier tronqué n'importe où ne fait pas tomber le lecteur")
}

// ═══════════════════════════════════════════════════════════════════ MP3 / LAME

titre("MP3 : la balise LAME")

/// Une trame MP3 factice : en-tête MPEG-1, en-tête de flux `Xing` à la place
/// exacte que la version et le mode imposent, puis la balise du codeur.
func mp3(trames: Int, amorce: Int, remplissage: Int, id3: Int = 0,
         codeur: String = "LAME3.100", sansBalise: Bool = false) -> [UInt8] {
    var octets = [UInt8]()
    if id3 > 0 {
        // La taille d'une étiquette ID3v2 s'écrit sur sept bits par octet.
        let t = UInt32(id3)
        octets += [0x49, 0x44, 0x33, 4, 0, 0] as [UInt8]
        let taille: [UInt8] = [UInt8((t >> 21) & 0x7F), UInt8((t >> 14) & 0x7F),
                               UInt8((t >> 7) & 0x7F), UInt8(t & 0x7F)]
        octets += taille
        // Ce que ffmpeg met là : le nom du codeur, qui ressemble à s'y méprendre
        // au début d'une balise LAME. Le chercher plutôt que le calculer y
        // tomberait droit dedans.
        octets += [UInt8]("TSSE\0\0\0\rLavf58.76.100\0".utf8)
        octets += [UInt8](repeating: 0, count: max(id3 - 22, 0))
    }
    // 0xFB : MPEG-1 couche III ; 0x64 : stéréo joint, d'où 32 octets latéraux.
    var trame: [UInt8] = [0xFF, 0xFB, 0x90, 0x64]
    trame += [UInt8](repeating: 0, count: 32)
    trame += [UInt8]("Xing".utf8)
    trame += be32(0x1 | 0x2 | 0x4)                       // trames, octets, table
    trame += be32(UInt32(trames))
    trame += be32(0)
    trame += [UInt8](repeating: 0, count: 100)
    if !sansBalise {
        trame += [UInt8](codeur.utf8)                     // 0x00 : neuf octets
        trame += [UInt8](repeating: 0, count: 0x15 - codeur.utf8.count)
        let champ: [UInt8] = [UInt8(amorce >> 4),
                              UInt8(((amorce & 0x0F) << 4) | (remplissage >> 8)),
                              UInt8(remplissage & 0xFF)]
        trame += champ
        trame += [UInt8](repeating: 0, count: 12)
    }
    return octets + trame
}

do {
    // Les valeurs de LAME sur un fichier de six secondes : 231 trames pleines,
    // 576 d'amorçage, 936 de remplissage.
    let url = dossier.appendingPathComponent("lame.mp3")
    écrit(url, mp3(trames: 231, amorce: 576, remplissage: 936))
    let info = GaplessTrim.read(at: url)
    exige(info?.frames == 264600, "la longueur utile se déduit du compte de trames — \(info?.frames ?? -1)")
    exige(info?.priming == 2257, "amorçage = trame d'en-tête + codeur + 529 — \(info?.priming ?? -1)")
    exige(info?.padding == 407, "remplissage = fin − 529 — \(info?.padding ?? -1)")

    // Un décodeur qui ne rogne rien rend 232 trames pleines.
    let naïf = info?.apply(to: [Float](repeating: 0, count: 267264)).count
    exige(naïf == 264600, "un décodeur qui ne rogne rien — \(naïf ?? -1)")

    // Media Foundation en ôte déjà 528, le retard du banc de filtres. La
    // réconciliation doit s'en apercevoir seule.
    let mf = info?.apply(to: [Float](repeating: 0, count: 266736)).count
    exige(mf == 264600, "un décodeur qui a déjà ôté 528 — \(mf ?? -1)")

    // Et un décodeur qui a tout fait ne doit rien perdre de plus.
    let complet = info?.apply(to: [Float](repeating: 0, count: 264600)).count
    exige(complet == 264600, "un décodeur qui a déjà tout fait — \(complet ?? -1)")
}

do {
    let url = dossier.appendingPathComponent("id3.mp3")
    écrit(url, mp3(trames: 231, amorce: 576, remplissage: 936, id3: 900))
    let info = GaplessTrim.read(at: url)
    exige(info?.priming == 2257, "une étiquette ID3v2 se saute — \(info?.priming ?? -1)")
}

do {
    // ffmpeg n'écrit pas de retard dans sa balise : il reste la trame d'en-tête
    // à ôter, et rien d'autre. C'est ce que rend `AVAudioFile` sur le même
    // fichier — 266 112 échantillons, soit 231 trames pleines.
    let url = dossier.appendingPathComponent("lavf.mp3")
    écrit(url, mp3(trames: 231, amorce: 0, remplissage: 0, id3: 900,
                   codeur: "Lavf58.76"))
    let info = GaplessTrim.read(at: url)
    exige(info?.frames == 266112, "sans retard déclaré, tout compte — \(info?.frames ?? -1)")
    let mf = info?.apply(to: [Float](repeating: 0, count: 266736)).count
    exige(mf == 266112, "266 736 décodés en donnent 266 112 — \(mf ?? -1)")
}

do {
    let url = dossier.appendingPathComponent("sansxing.mp3")
    var octets = mp3(trames: 231, amorce: 576, remplissage: 936)
    octets[4 + 32] = 0x41                                // « Aing » : plus rien à lire
    écrit(url, octets)
    exige(GaplessTrim.read(at: url) == nil, "sans en-tête de flux, on ne coupe rien")
}

// ══════════════════════════════════════════════════════════ ce qu'on ne coupe pas

titre("Ce qui ne déclare rien")

do {
    let url = dossier.appendingPathComponent("bruit.bin")
    écrit(url, (0..<4096).map { UInt8($0 % 251) })
    exige(GaplessTrim.read(at: url) == nil, "des octets quelconques ne déclarent rien")

    let vide = dossier.appendingPathComponent("vide.bin")
    écrit(vide, [])
    exige(GaplessTrim.read(at: vide) == nil, "un fichier vide non plus")
}

titre("La coupe elle-même")

do {
    let signal = (0..<1000).map { Float($0) }
    let info = GaplessTrim.Info(priming: 100, padding: 50, frames: 850)
    let coupé = info.apply(to: signal)
    exige(coupé.count == 850, "la longueur déclarée fait foi")
    exige(coupé.first == 100, "la coupe part du bon échantillon")

    // Ce qui est déclaré peut dépasser ce qui a été décodé — un décodeur peut
    // avoir déjà rogné, ou s'être arrêté tôt. Mieux vaut rendre le signal entier
    // qu'un tableau vide.
    let trop = GaplessTrim.Info(priming: 5000, padding: 0, frames: nil)
    exige(trop.apply(to: signal).count == 1000, "on ne coupe pas plus qu'on n'a")

    let sansLongueur = GaplessTrim.Info(priming: 100, padding: 50, frames: nil)
    exige(sansLongueur.apply(to: signal).count == 850, "sans longueur, les deux bouts suffisent")
}

// ══════════════════════════════════════════ un vrai fichier, quand on en donne un

if CommandLine.arguments.count >= 2 {
    titre("Fichiers donnés")
    for chemin in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: chemin)
        if let info = GaplessTrim.read(at: url) {
            print("  \(url.lastPathComponent) : amorçage \(info.priming), "
                + "fin \(info.padding), utiles \(info.frames.map(String.init) ?? "—")")
        } else {
            print("  \(url.lastPathComponent) : rien de déclaré")
        }
    }
}

print("")
if échecs == 0 {
    print("Tout est bon.")
} else {
    print("\(échecs) vérification(s) en échec.")
    exit(1)
}
