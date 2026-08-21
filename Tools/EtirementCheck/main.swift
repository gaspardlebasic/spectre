import Foundation
import SpectreCore
import SpectreDSP

// Vérification du ralenti et de la transposition.
//
// Le point de la mesure : **vitesse et hauteur doivent être indépendantes.** Un
// étireur qui se contente de relire plus lentement descend d'une octave en même
// temps, et c'est précisément ce qu'un outil de transcription ne peut pas faire.
// On mesure donc les deux séparément :
//
//   - la **durée** se mesure en comptant les images rendues pour une source
//     donnée ;
//   - la **hauteur** se mesure par une transformée : on envoie une sinusoïde pure,
//     on regarde où sa raie ressort.
//
// Et le neutre se mesure au bit près, parce que c'est le cas le plus fréquent et
// que le court-circuit qui le garantit est facile à casser sans s'en apercevoir.

var echecs = 0
func controle(_ intitule: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(intitule) — \(detail)")
    if !ok { echecs += 1 }
}

let frequence = 44100.0

/// Fait rendre `images` images à l'étireur, en le nourrissant de `source`.
func rendre(_ etireur: inout Etireur, source: [Float], images: Int) -> [Float] {
    var lu = 0
    var sortie = [Float](repeating: 0, count: images)
    let blocs = 512
    var faites = 0
    while faites < images {
        let n = min(blocs, images - faites)
        sortie.withUnsafeMutableBufferPointer { tampon in
            let vue = UnsafeMutableBufferPointer(rebasing: tampon[faites..<(faites + n)])
            _ = etireur.rendre(into: vue, images: n) { entree, demandees in
                let dispo = min(demandees, source.count - lu)
                for i in 0..<max(dispo, 0) { entree[i] = source[lu + i] }
                lu += max(dispo, 0)
                return max(dispo, 0)
            }
        }
        faites += n
    }
    return sortie
}

/// Combien d'images l'étireur consomme pour en rendre `images`.
func consommees(_ etireur: inout Etireur, source: [Float], images: Int) -> Int {
    var lu = 0
    var poubelle = [Float](repeating: 0, count: 512)
    var faites = 0
    while faites < images {
        let n = min(512, images - faites)
        poubelle.withUnsafeMutableBufferPointer { tampon in
            let vue = UnsafeMutableBufferPointer(rebasing: tampon[0..<n])
            _ = etireur.rendre(into: vue, images: n) { entree, demandees in
                let dispo = min(demandees, source.count - lu)
                for i in 0..<max(dispo, 0) { entree[i] = source[lu + i] }
                lu += max(dispo, 0)
                return max(dispo, 0)
            }
        }
        faites += n
    }
    // Ce qui a été tiré, moins ce qui n'est pas encore sorti.
    return lu - etireur.enAttente
}

func sinusoide(_ f: Double, images: Int) -> [Float] {
    (0..<images).map { Float(sin(2 * .pi * f * Double($0) / frequence)) }
}

/// La fréquence de la raie la plus forte, par transformée sur une fenêtre de Hann.
func raieDominante(_ signal: [Float]) -> Double {
    let n = 16384
    guard signal.count >= n else { return 0 }
    // Le milieu du signal : le début porte la montée de l'étireur, la fin sa
    // descente, et ni l'une ni l'autre ne dit la hauteur.
    let debut = (signal.count - n) / 2
    var reel = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
        reel[i] = Double(signal[debut + i]) * w
    }

    // Une transformée bête en N² serait ici de vingt secondes : on cherche donc le
    // maximum par corrélation directe sur une grille fine autour de l'attendu, ce
    // qui suffit à distinguer deux demi-tons.
    var meilleure = 0.0
    var meilleurNiveau = -1.0
    var f = 100.0
    while f < 2000 {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * f / frequence
        for i in 0..<n {
            re += reel[i] * cos(w * Double(i))
            im += reel[i] * sin(w * Double(i))
        }
        let niveau = re * re + im * im
        if niveau > meilleurNiveau { meilleurNiveau = niveau; meilleure = f }
        f *= pow(2, 1.0 / 480)          // un quarantième de demi-ton
    }
    return meilleure
}

// MARK: - Le neutre est le fichier

print("=== Le neutre ===")
do {
    var etireur = Etireur(sampleRate: frequence)
    let source = sinusoide(440, images: 40000)
    let sortie = rendre(&etireur, source: source, images: 30000)
    var pire = Float(0)
    for i in 0..<30000 { pire = max(pire, abs(sortie[i] - source[i])) }
    controle("à ×1 et +0, les échantillons passent au bit près", pire == 0,
             "écart max \(pire)")
    controle("et rien n'est mis en réserve", etireur.enAttente == 0,
             "\(etireur.enAttente) image(s) en attente")
}

// MARK: - La durée

print("\n=== La vitesse, sans toucher à la hauteur ===")
for vitesse in [0.5, 0.75, 1.5, 2.0] {
    var etireur = Etireur(sampleRate: frequence)
    etireur.vitesse = vitesse
    let source = sinusoide(440, images: 400_000)
    let images = 100_000
    let lues = consommees(&etireur, source: source, images: images)
    let mesuree = Double(lues) / Double(images)
    // 2 % de tolérance : la recherche de raccord déplace chaque grain de quelques
    // images, et ces déplacements ne se compensent pas exactement.
    controle(String(format: "×%.2f consomme ce qu'il faut", vitesse),
             abs(mesuree - vitesse) / vitesse < 0.02,
             String(format: "mesuré ×%.4f", mesuree))
}

for vitesse in [0.5, 2.0] {
    var etireur = Etireur(sampleRate: frequence)
    etireur.vitesse = vitesse
    let sortie = rendre(&etireur, source: sinusoide(440, images: 400_000), images: 120_000)
    let raie = raieDominante(sortie)
    controle(String(format: "×%.2f ne change pas la hauteur", vitesse),
             abs(1200 * log2(raie / 440)) < 20,
             String(format: "%.1f Hz au lieu de 440, soit %+.0f cents",
                    raie, 1200 * log2(raie / 440)))
}

// MARK: - La hauteur

print("\n=== La transposition, sans toucher à la durée ===")
for demiTons in [-12.0, -5.0, 3.0, 7.0, 12.0] {
    var etireur = Etireur(sampleRate: frequence)
    etireur.demiTons = demiTons
    let sortie = rendre(&etireur, source: sinusoide(440, images: 400_000), images: 120_000)
    let attendue = 440 * pow(2, demiTons / 12)
    let raie = raieDominante(sortie)
    let cents = 1200 * log2(raie / attendue)
    // Vingt cents : un cinquième de demi-ton, très en dessous de ce qui s'entend
    // comme faux, et bien au-dessus de la finesse de la mesure.
    controle(String(format: "%+.0f demi-tons donne %.1f Hz", demiTons, attendue),
             abs(cents) < 20, String(format: "%.1f Hz, soit %+.0f cents", raie, cents))
}

for demiTons in [-12.0, 7.0] {
    var etireur = Etireur(sampleRate: frequence)
    etireur.demiTons = demiTons
    let source = sinusoide(440, images: 400_000)
    let images = 100_000
    let lues = consommees(&etireur, source: source, images: images)
    let mesuree = Double(lues) / Double(images)
    controle(String(format: "%+.0f demi-tons ne change pas la durée", demiTons),
             abs(mesuree - 1) < 0.02, String(format: "mesuré ×%.4f", mesuree))
}

// MARK: - Les deux ensemble

print("\n=== Les deux à la fois ===")
do {
    var etireur = Etireur(sampleRate: frequence)
    etireur.vitesse = 0.5
    etireur.demiTons = 7
    let source = sinusoide(440, images: 400_000)
    let sortie = rendre(&etireur, source: source, images: 120_000)
    let attendue = 440 * pow(2, 7.0 / 12)
    let raie = raieDominante(sortie)
    controle("moitié moins vite et une quinte plus haut : la hauteur",
             abs(1200 * log2(raie / attendue)) < 20,
             String(format: "%.1f Hz au lieu de %.1f", raie, attendue))

    var second = Etireur(sampleRate: frequence)
    second.vitesse = 0.5
    second.demiTons = 7
    let lues = consommees(&second, source: source, images: 100_000)
    let mesuree = Double(lues) / 100_000
    controle("moitié moins vite et une quinte plus haut : la vitesse",
             abs(mesuree - 0.5) / 0.5 < 0.02, String(format: "mesuré ×%.4f", mesuree))
}

// MARK: - Ce que le son doit rester

print("\n=== Ce qui ne doit pas arriver ===")
do {
    var etireur = Etireur(sampleRate: frequence)
    etireur.vitesse = 0.5
    let sortie = rendre(&etireur, source: sinusoide(440, images: 400_000), images: 200_000)

    // Aucun silence au milieu : un grain mal enchaîné laisse un trou, et c'est ce
    // qui s'entend le plus vite.
    var pireCreux = 0
    var creux = 0
    for i in 10000..<190_000 {
        if abs(sortie[i]) < 1e-4 { creux += 1; pireCreux = max(pireCreux, creux) }
        else { creux = 0 }
    }
    // Une sinusoïde passe par zéro deux fois par période ; à 440 Hz cela fait un
    // creux de quelques images. Cent images, c'est 2 ms — un trou.
    controle("aucun trou dans le son", pireCreux < 100, "\(pireCreux) images de suite sous 1e-4")

    // Et le niveau ne bat pas : c'est le défaut d'un recouvrement mal fenêtré.
    var minimum = Float.infinity
    var maximum = Float(0)
    var i = 10000
    while i + 2048 < 190_000 {
        var sommet = Float(0)
        for j in i..<(i + 2048) { sommet = max(sommet, abs(sortie[j])) }
        minimum = min(minimum, sommet)
        maximum = max(maximum, sommet)
        i += 2048
    }
    let battement = 20 * log10(Double(maximum / max(minimum, 1e-9)))
    controle("le niveau ne bat pas", battement < 3,
             String(format: "%.1f dB entre le plus faible et le plus fort", battement))
}

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) vérification(s) en échec.")
    exit(1)
}
