import CStretch
import Foundation
import SpectreCore
import SpectreDSP

// Le ralenti et la transposition, mesurés.
//
// ─────────────────────────────────────────────────────────────────────────────
// « ÇA NE SE JUGE QU'À L'OREILLE »
//
// C'est vrai de la *qualité* : le grain d'un vocodeur de phase, ses artefacts
// métalliques sur les transitoires, la façon dont il tient une voix. Rien de
// tout cela ne se met en chiffres, et rien ici ne le prétend.
//
// Mais trois propriétés se mesurent, et ce sont celles dont les pannes coûtent
// cher parce qu'elles sont muettes :
//
//   — **la durée** : à ×0,5 on doit entendre deux fois plus longtemps ;
//   — **la hauteur** : +12 demi-tons doit doubler la fréquence, et ralentir ne
//     doit *pas* la changer — c'est toute la différence avec un simple
//     rééchantillonnage, et c'est exactement ce qu'on vient chercher ;
//   — **le silence à l'arrêt** : à ×1 et +0, l'effet est retiré du chemin, et ce
//     qui sort doit être le fichier tel quel.
//
// Le pendant macOS est `Tools/PlaybackCheck`, qui vérifie les mêmes propriétés
// sur `AVAudioUnitTimePitch`. Les deux moteurs n'ont rien en commun ; ce qu'on
// attend d'eux, si.
// ─────────────────────────────────────────────────────────────────────────────

var échecs = 0

func titre(_ t: String) { print("\n=== \(t) ===") }

func exige(_ condition: Bool, _ quoi: String) {
    print("  \(condition ? "✓" : "✗") \(quoi)")
    if !condition { échecs += 1 }
}

let fréquence = 44100.0

/// Une sinusoïde, avec un fondu aux deux bouts : une attaque nette étalerait le
/// spectre et brouillerait la mesure de hauteur.
func sinus(_ hz: Double, secondes: Double) -> [Float] {
    let n = Int(secondes * fréquence)
    let fondu = Int(0.02 * fréquence)
    return (0..<n).map { i in
        let enveloppe: Double
        if i < fondu { enveloppe = Double(i) / Double(fondu) }
        else if i > n - fondu { enveloppe = Double(n - i) / Double(fondu) }
        else { enveloppe = 1 }
        return Float(enveloppe * sin(2 * .pi * hz * Double(i) / fréquence))
    }
}

/// La fréquence dominante d'un signal, par interpolation parabolique autour du
/// maximum : sans elle, la résolution d'une transformée de 16 384 points ne
/// vaudrait que 2,7 Hz, trop grossier pour distinguer une octave juste d'une
/// octave presque juste.
func hauteur(_ signal: [Float]) -> Double {
    let n = 16384
    guard signal.count >= n else { return 0 }
    // Au milieu du signal : ni l'attaque, ni la queue du vocodeur.
    let début = (signal.count - n) / 2
    var fenêtré = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))   // Hann
        fenêtré[i] = signal[début + i] * Float(w)
    }
    guard let transformée = RealFourier(size: n) else { return 0 }
    var pairs = [Float](repeating: 0, count: n / 2)
    var impairs = [Float](repeating: 0, count: n / 2)
    fenêtré.withUnsafeBufferPointer { e in
        pairs.withUnsafeMutableBufferPointer { p in
            impairs.withUnsafeMutableBufferPointer { i in
                transformée.forward(e.baseAddress!, evens: p.baseAddress!, odds: i.baseAddress!)
            }
        }
    }
    // Le continu et le Nyquist sont empaquetés ensemble dans la première case —
    // convention de vDSP, reproduite par la version portable. Ni l'un ni l'autre
    // ne peut être la hauteur qu'on cherche, d'où la boucle qui commence à 2.
    let spectre = (0..<(n / 2)).map { pairs[$0] * pairs[$0] + impairs[$0] * impairs[$0] }
    var meilleur = 1
    for k in 2..<(spectre.count - 1) where spectre[k] > spectre[meilleur] { meilleur = k }
    // L'interpolation se fait sur les amplitudes, pas sur les puissances : c'est
    // la parabole des premières qui approche le sommet d'un lobe de Hann.
    let a = Double(spectre[meilleur - 1]).squareRoot()
    let b = Double(spectre[meilleur]).squareRoot()
    let c = Double(spectre[meilleur + 1]).squareRoot()
    let dénominateur = a - 2 * b + c
    let δ = abs(dénominateur) > 1e-12 ? 0.5 * (a - c) / dénominateur : 0
    return (Double(meilleur) + δ) * fréquence / Double(n)
}

/// Le bloc de traitement, en échantillons de sortie. La longueur produite est
/// forcément un multiple : les vérifications de durée en tiennent compte plutôt
/// que de raisonner en pourcentage, qui serait sévère sur un signal court et
/// laxiste sur un long.
let bloc = 1024

/// Fait passer un signal par le moteur, à la vitesse et la hauteur demandées.
func traite(_ entrée: [Float], vitesse: Double, demiTons: Double) -> [Float] {
    guard let moteur = spectre_stretch_creer(1, fréquence) else { return [] }
    defer { spectre_stretch_detruire(moteur) }
    spectre_stretch_transposer(moteur, demiTons)

    let bloc = 1024
    var sortie = [Float]()
    var lu = 0
    // On pousse jusqu'à ce que l'entrée soit épuisée, puis du silence pour vider
    // la queue du vocodeur — sinon la fin du signal reste dedans.
    let àProduire = Int(Double(entrée.count) / vitesse)
    sortie.reserveCapacity(àProduire)

    var tampon = [Float](repeating: 0, count: bloc)
    while sortie.count < àProduire {
        let besoin = Int((Double(bloc) * vitesse).rounded())
        var morceau = [Float](repeating: 0, count: max(besoin, 1))
        for i in 0..<besoin where lu + i < entrée.count { morceau[i] = entrée[lu + i] }
        lu += besoin
        morceau.withUnsafeBufferPointer { e in
            tampon.withUnsafeMutableBufferPointer { s in
                spectre_stretch_traiter(moteur, e.baseAddress, Int32(besoin),
                                        s.baseAddress, Int32(bloc))
            }
        }
        sortie.append(contentsOf: tampon)
    }
    return sortie
}

titre("Le moteur existe")

do {
    guard let moteur = spectre_stretch_creer(1, fréquence) else {
        print("  ✗ le moteur n'a pas pu être créé")
        exit(1)
    }
    let latence = spectre_stretch_latence(moteur)
    exige(latence > 0, "il annonce une latence — \(latence) échantillons "
        + String(format: "(%.0f ms)", Double(latence) * 1000 / fréquence))
    exige(latence < Int(0.2 * fréquence), "et elle reste sous 200 ms")
    spectre_stretch_detruire(moteur)
    exige(spectre_stretch_creer(0, fréquence) == nil, "zéro canal est refusé")
    exige(spectre_stretch_creer(1, 0) == nil, "une fréquence nulle aussi")
}

titre("La hauteur ne bouge pas quand on ralentit")

do {
    let source = sinus(440, secondes: 3)
    exige(abs(hauteur(source) - 440) < 1, "la mesure elle-même est juste — "
        + String(format: "%.2f Hz", hauteur(source)))

    for vitesse in [0.5, 0.75, 2.0] {
        let sortie = traite(source, vitesse: vitesse, demiTons: 0)
        let h = hauteur(sortie)
        // Un rééchantillonnage donnerait 440 × vitesse : à ×0,5 on entendrait
        // 220 Hz, une octave plus bas. C'est précisément ce qu'on ne veut pas.
        exige(abs(h - 440) < 3,
              String(format: "à ×%.2f, le la reste un la — %.1f Hz", vitesse, h))
    }
}

titre("La durée suit la vitesse")

do {
    let source = sinus(440, secondes: 2)
    for vitesse in [0.5, 0.8, 2.0] {
        let sortie = traite(source, vitesse: vitesse, demiTons: 0)
        let attendu = Double(source.count) / vitesse
        exige(abs(Double(sortie.count) - attendu) <= Double(bloc),
              String(format: "à ×%.2f, %.2f s deviennent %.2f s (attendu %.2f)",
                     vitesse, Double(source.count) / fréquence,
                     Double(sortie.count) / fréquence, attendu / fréquence))
    }
}

titre("La transposition")

do {
    let source = sinus(440, secondes: 3)
    for (demiTons, attendu) in [(12.0, 880.0), (-12.0, 220.0), (7.0, 440 * pow(2, 7.0 / 12))] {
        let sortie = traite(source, vitesse: 1, demiTons: demiTons)
        let h = hauteur(sortie)
        // Un demi-tonaudible se joue à quelques dixièmes de pour cent : la marge
        // est en cents, pas en hertz, sans quoi elle serait bien plus lâche dans
        // l'aigu que dans le grave.
        let cents = 1200 * log2(h / attendu)
        exige(abs(cents) < 15,
              String(format: "%+.0f demi-tons : %.1f Hz pour %.1f attendus (%.0f cents d'écart)",
                     demiTons, h, attendu, cents))
    }
}

do {
    // Ralentir *et* transposer en même temps : les deux réglages doivent être
    // indépendants, sinon l'un corrigerait l'autre sans qu'on s'en aperçoive.
    let source = sinus(440, secondes: 3)
    let sortie = traite(source, vitesse: 0.5, demiTons: 12)
    let h = hauteur(sortie)
    exige(abs(1200 * log2(h / 880)) < 15,
          String(format: "à ×0,50 et +12, on entend %.1f Hz pour 880", h))
    let attendu = Double(source.count) / 0.5
    exige(abs(Double(sortie.count) - attendu) <= Double(bloc),
          "et deux fois plus longtemps")
}

titre("Ce qui sort ressemble à ce qui entre")

do {
    let source = sinus(440, secondes: 2)
    let sortie = traite(source, vitesse: 0.5, demiTons: 0)
    let crête = sortie.map(abs).max() ?? 0
    exige(crête > 0.5 && crête < 1.5, String(format: "le niveau est tenu — crête %.2f", crête))
    exige(!sortie.contains(where: { !$0.isFinite }), "aucune valeur infinie ni indéfinie")

    // Le début du signal est du silence — la latence du vocodeur —, puis le son
    // arrive. S'il n'arrivait jamais, tout le reste ci-dessus passerait quand
    // même : une mesure de hauteur sur du silence rend n'importe quoi de stable.
    let premierSon = sortie.firstIndex(where: { abs($0) > 0.05 }) ?? sortie.count
    exige(premierSon < sortie.count / 4,
          "le son arrive tôt — au bout de \(premierSon) échantillons")
}

titre("La remise à zéro")

do {
    // Après un saut dans le morceau, l'état interne doit être vidé : sans cela
    // le vocodeur recolle deux passages qui ne se suivent pas, et l'on entend
    // une seconde de l'endroit d'où l'on vient.
    guard let moteur = spectre_stretch_creer(1, fréquence) else { exit(1) }
    defer { spectre_stretch_detruire(moteur) }

    let bruit = (0..<8192).map { _ in Float.random(in: -1...1) }
    var poubelle = [Float](repeating: 0, count: 4096)
    bruit.withUnsafeBufferPointer { e in
        poubelle.withUnsafeMutableBufferPointer { s in
            spectre_stretch_traiter(moteur, e.baseAddress, 8192, s.baseAddress, 4096)
        }
    }
    spectre_stretch_reinitialiser(moteur)

    // Après remise à zéro, du silence en entrée doit donner du silence.
    let silence = [Float](repeating: 0, count: 8192)
    var après = [Float](repeating: 0, count: 4096)
    silence.withUnsafeBufferPointer { e in
        après.withUnsafeMutableBufferPointer { s in
            spectre_stretch_traiter(moteur, e.baseAddress, 8192, s.baseAddress, 4096)
        }
    }
    let reste = après.map(abs).max() ?? 0
    exige(reste < 0.01, String(format: "rien du passage précédent ne subsiste — crête %.4f", reste))
}

print("")
if échecs == 0 {
    print("Tout est bon.")
} else {
    print("\(échecs) vérification(s) en échec.")
    exit(1)
}
