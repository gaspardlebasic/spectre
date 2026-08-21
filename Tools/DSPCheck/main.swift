import Foundation
import SpectreDSP

// La transformée portable, mesurée contre Accelerate dans le même processus, sur
// les mêmes signaux.
//
// C'est la seule façon honnête de préparer un portage sans la machine cible : la
// couche numérique, elle, se prouve ici. Ce qui passe ce contrôle passera sous
// Windows pour les mêmes raisons — ce n'est plus une question de plateforme mais
// d'arithmétique.
//
// Les tailles éprouvées sont celles que l'application emploie réellement : 512
// pour le banc multi-résolution, 8192 pour le mode à fenêtre unique, 4096 pour la
// STFT de Demucs.

var echecs = 0

func titre(_ s: String) { print("\n=== \(s) ===") }

func verifie(_ condition: Bool, _ intitulé: String, _ détail: String = "") {
    let marque = condition ? "✓" : "✗"
    print("  \(marque) \(intitulé)\(détail.isEmpty ? "" : " — \(détail)")")
    if !condition { echecs += 1 }
}

/// Signaux de nature différente : la transformée ne doit pas être juste seulement
/// sur des sinusoïdes, qui tombent pile dans les cases.
func signaux(_ n: Int) -> [(String, [Float])] {
    var générateur = SystemRandomNumberGenerator()
    var bruit = [Float](repeating: 0, count: n)
    for i in 0..<n { bruit[i] = Float.random(in: -1...1, using: &générateur) }

    var impulsion = [Float](repeating: 0, count: n)
    impulsion[n / 3] = 1

    // Chaque type est écrit, et chaque signal construit à part. Laissé à
    // l'inférence, ce tableau de littéraux mêlant entiers, flottants et `.pi`
    // dépasse le temps que le compilateur s'accorde — sur une machine, pas sur
    // l'autre, ce qui est la pire façon de s'en apercevoir.
    func raie(_ fréquence: Double, amplitude: Double = 1, décalage: Double = 0) -> [Float] {
        var sortie = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let phase: Double = 2 * Double.pi * fréquence * Double(i) / Double(n)
            sortie[i] = Float(décalage + amplitude * sin(phase))
        }
        return sortie
    }

    var mélange = raie(11)
    for i in 0..<n {
        let phase: Double = 2 * Double.pi * 40.2 * Double(i) / Double(n)
        mélange[i] += Float(0.3 + 0.5 * cos(phase))
    }

    var signaux: [(String, [Float])] = []
    signaux.append(("une raie tombant dans une case", raie(5)))
    signaux.append(("une raie entre deux cases", raie(5.37)))
    signaux.append(("deux raies et une composante continue", mélange))
    signaux.append(("une impulsion", impulsion))
    signaux.append(("du bruit", bruit))
    signaux.append(("le silence", [Float](repeating: 0, count: n)))
    return signaux
}

// La transformée directe, calculée bêtement en N², en double précision. Elle est
// lente et elle a raison : c'est la définition même, sans astuce ni papillon.
//
// C'est la seule référence qui vaille **partout** — là où Accelerate existe comme
// là où il n'existe pas. Sans elle, ce contrôle n'aurait rien à dire sur la
// machine cible, qui est précisément celle dont on doute.
func dftDirecte(_ x: [Float]) -> (evens: [Float], odds: [Float]) {
    let n = x.count
    let demi = n / 2
    var evens = [Float](repeating: 0, count: demi)
    var odds = [Float](repeating: 0, count: demi)
    func raie(_ k: Int) -> (Double, Double) {
        var re = 0.0, im = 0.0
        for j in 0..<n {
            let a = -2 * Double.pi * Double(k) * Double(j) / Double(n)
            re += Double(x[j]) * cos(a)
            im += Double(x[j]) * sin(a)
        }
        return (re, im)
    }
    // Convention de `vDSP_fft_zrip` : tout vaut deux fois la transformée, et la
    // case 0 porte le continu et Nyquist ensemble.
    evens[0] = Float(2 * raie(0).0)
    odds[0] = Float(2 * raie(demi).0)
    for k in 1..<demi {
        let (re, im) = raie(k)
        evens[k] = Float(2 * re)
        odds[k] = Float(2 * im)
    }
    return (evens, odds)
}

titre("Contre la définition")
for n in [512] {
    guard let portable = PortableRealFourier(size: n) else {
        verifie(false, "la transformée se construit")
        break
    }
    let demi = n / 2
    for (nom, x) in signaux(n) {
        var pr = [Float](repeating: 0, count: demi), pi = [Float](repeating: 0, count: demi)
        x.withUnsafeBufferPointer { entrée in
            pr.withUnsafeMutableBufferPointer { r in
                pi.withUnsafeMutableBufferPointer { i in
                    portable.forward(entrée.baseAddress!, evens: r.baseAddress!, odds: i.baseAddress!)
                }
            }
        }
        let (er, ei) = dftDirecte(x)
        var écart: Float = 0, amplitude: Float = 0
        for k in 0..<demi {
            écart = max(écart, abs(er[k] - pr[k]), abs(ei[k] - pi[k]))
            amplitude = max(amplitude, abs(er[k]), abs(ei[k]))
        }
        verifie(écart <= max(amplitude, 1) * 5e-5, nom,
                String(format: "écart %.2e pour une amplitude %.2f", écart, amplitude))
    }
}

#if canImport(Accelerate)

for n in [512, 4096, 8192] {
    titre("Contre Accelerate, N = \(n)")
    guard let référence = AccelerateRealFourier(size: n),
          let portable = PortableRealFourier(size: n) else {
        verifie(false, "les deux transformées se construisent")
        break
    }
    let demi = n / 2

    for (nom, x) in signaux(n) {
        var ar = [Float](repeating: 0, count: demi), ai = [Float](repeating: 0, count: demi)
        var pr = [Float](repeating: 0, count: demi), pi = [Float](repeating: 0, count: demi)
        x.withUnsafeBufferPointer { entrée in
            ar.withUnsafeMutableBufferPointer { r in
                ai.withUnsafeMutableBufferPointer { i in
                    référence.forward(entrée.baseAddress!, evens: r.baseAddress!, odds: i.baseAddress!)
                }
            }
            pr.withUnsafeMutableBufferPointer { r in
                pi.withUnsafeMutableBufferPointer { i in
                    portable.forward(entrée.baseAddress!, evens: r.baseAddress!, odds: i.baseAddress!)
                }
            }
        }
        var écart: Float = 0
        var amplitude: Float = 0
        for k in 0..<demi {
            écart = max(écart, abs(ar[k] - pr[k]), abs(ai[k] - pi[k]))
            amplitude = max(amplitude, abs(ar[k]), abs(ai[k]))
        }
        // Tolérance relative : les deux additionnent N termes flottants dans un
        // ordre différent, l'égalité au bit près n'est pas exigible.
        let seuil = max(amplitude, 1) * 2e-5
        verifie(écart <= seuil, nom,
                String(format: "écart %.2e pour une amplitude %.2f", écart, amplitude))
    }
}

titre("Retour")
for n in [512, 4096] {
    guard let référence = AccelerateRealFourier(size: n),
          let portable = PortableRealFourier(size: n) else { continue }
    let demi = n / 2
    let x = signaux(n)[4].1        // du bruit : tout le spectre est occupé

    // On part d'un spectre calculé, plutôt que d'un spectre inventé : c'est celui
    // que l'inverse rencontre réellement.
    var er = [Float](repeating: 0, count: demi), ei = [Float](repeating: 0, count: demi)
    x.withUnsafeBufferPointer { entrée in
        er.withUnsafeMutableBufferPointer { r in
            ei.withUnsafeMutableBufferPointer { i in
                référence.forward(entrée.baseAddress!, evens: r.baseAddress!, odds: i.baseAddress!)
            }
        }
    }

    var sortieRéférence = [Float](repeating: 0, count: n)
    var sortiePortable = [Float](repeating: 0, count: n)
    var a = er, b = ei                    // l'inverse d'Accelerate détruit son entrée
    var c = er, d = ei
    a.withUnsafeMutableBufferPointer { r in
        b.withUnsafeMutableBufferPointer { i in
            sortieRéférence.withUnsafeMutableBufferPointer { o in
                référence.inverse(evens: r.baseAddress!, odds: i.baseAddress!,
                                  into: o.baseAddress!)
            }
        }
    }
    c.withUnsafeMutableBufferPointer { r in
        d.withUnsafeMutableBufferPointer { i in
            sortiePortable.withUnsafeMutableBufferPointer { o in
                portable.inverse(evens: r.baseAddress!, odds: i.baseAddress!,
                                 into: o.baseAddress!)
            }
        }
    }

    var écart: Float = 0, amplitude: Float = 0
    for i in 0..<n {
        écart = max(écart, abs(sortieRéférence[i] - sortiePortable[i]))
        amplitude = max(amplitude, abs(sortieRéférence[i]))
    }
    verifie(écart <= max(amplitude, 1) * 2e-5, "l'inverse rend la même chose, N = \(n)",
            String(format: "écart %.2e pour une amplitude %.2f", écart, amplitude))

    // Et le tour complet doit rendre le signal, au facteur 2N que les deux
    // partagent par construction.
    var maxRelatif: Float = 0
    for i in 0..<n {
        let attendu = x[i] * Float(2 * n)
        maxRelatif = max(maxRelatif, abs(sortiePortable[i] - attendu))
    }
    let crête = (x.map(abs).max() ?? 1) * Float(2 * n)
    verifie(maxRelatif <= crête * 2e-5, "l'aller-retour rend le signal, N = \(n)",
            String(format: "écart %.2e pour une amplitude %.2f", maxRelatif, crête))
}

titre("Coût")
if let référence = AccelerateRealFourier(size: 512),
   let portable = PortableRealFourier(size: 512) {
    let n = 512, demi = 256, tours = 20_000
    let x = signaux(n)[4].1
    var r = [Float](repeating: 0, count: demi), i2 = [Float](repeating: 0, count: demi)

    func mesure(_ corps: (UnsafePointer<Float>, UnsafeMutablePointer<Float>,
                          UnsafeMutablePointer<Float>) -> Void) -> Double {
        let début = Date()
        x.withUnsafeBufferPointer { entrée in
            r.withUnsafeMutableBufferPointer { a in
                i2.withUnsafeMutableBufferPointer { b in
                    for _ in 0..<tours {
                        corps(entrée.baseAddress!, a.baseAddress!, b.baseAddress!)
                    }
                }
            }
        }
        return Date().timeIntervalSince(début)
    }

    let tA = mesure { référence.forward($0, evens: $1, odds: $2) }
    let tP = mesure { portable.forward($0, evens: $1, odds: $2) }
    print(String(format: "  Accelerate %.0f ns par transformée, portable %.0f ns (×%.1f)",
                 tA / Double(tours) * 1e9, tP / Double(tours) * 1e9, tP / tA))
    print("  (indicatif : l'analyse est hors ligne, ce coût ne pèse qu'au chargement)")
}

#else

// Sans Accelerate, l'aller a été mesuré contre la définition ci-dessus. Reste à
// éprouver le retour, qu'on ne peut confronter qu'à lui-même : l'aller-retour
// doit rendre le signal, au facteur 2N que la convention impose.
titre("Aller-retour")
for n in [512, 4096] {
    guard let portable = PortableRealFourier(size: n) else { continue }
    let demi = n / 2
    let x = signaux(n)[4].1
    var er = [Float](repeating: 0, count: demi), ei = [Float](repeating: 0, count: demi)
    var sortie = [Float](repeating: 0, count: n)
    x.withUnsafeBufferPointer { entrée in
        er.withUnsafeMutableBufferPointer { r in
            ei.withUnsafeMutableBufferPointer { i in
                portable.forward(entrée.baseAddress!, evens: r.baseAddress!, odds: i.baseAddress!)
                sortie.withUnsafeMutableBufferPointer { o in
                    portable.inverse(evens: r.baseAddress!, odds: i.baseAddress!,
                                     into: o.baseAddress!)
                }
            }
        }
    }
    var écart: Float = 0
    for i in 0..<n { écart = max(écart, abs(sortie[i] - x[i] * Float(2 * n))) }
    let crête = (x.map(abs).max() ?? 1) * Float(2 * n)
    verifie(écart <= crête * 2e-5, "l'aller-retour rend le signal, N = \(n)",
            String(format: "écart %.2e pour une amplitude %.2f", écart, crête))
}

#endif

// ═══════════════════════════════════════════════════════ Les demi-flottants
//
// La matrice part sur la carte graphique en demi-flottants. La conversion est
// donc une frontière numérique de plus, et elle se mesure comme les autres :
// contre la définition d'abord — partout —, contre vImage ensuite, là où vImage
// existe.

/// Un demi-flottant vers un double, sans arrondi possible : 11 bits de mantisse
/// entrent sans reste dans 53. Rend `nil` pour un NaN, qui ne se compare pas.
func versDouble(_ h: UInt16) -> Double? {
    let signe: Double = (h & 0x8000) != 0 ? -1 : 1
    let exposant = Int((h >> 10) & 0x1F)
    let mantisse = Double(h & 0x03FF)
    if exposant == 0x1F { return mantisse == 0 ? signe * Double.infinity : nil }
    if exposant == 0 { return signe * mantisse * exp2(-24.0) }
    return signe * (1 + mantisse / 1024) * exp2(Double(exposant - 15))
}

/// Le demi-flottant le plus proche d'une valeur, trouvé en les essayant **tous**.
///
/// 65 536 candidats, décodés en double et comparés : c'est lent et c'est la
/// définition même de « arrondi au plus proche », sans astuce dont on pourrait
/// hériter le défaut. La même méthode que la DFT bête en N² plus haut, et pour la
/// même raison — une référence n'a de valeur que si elle ne partage aucun rouage
/// avec ce qu'elle juge.
func plusProcheDemi(_ f: Float) -> UInt16 {
    // La recherche porte sur la **magnitude**, et le signe se rajoute à la fin.
    // Autrement les deux zéros sont à distance nulle de la même cible et rien ne
    // peut les départager, alors qu'IEEE-754 est formel : le signe se conserve,
    // y compris quand une valeur minuscule s'écrase sur zéro.
    let signe: UInt16 = f.sign == .minus ? 0x8000 : 0
    let cible = Double(abs(f))

    // Le débordement ne se trouve pas non plus par une recherche du plus proche :
    // l'infini est à distance infinie de tout. La règle est que l'arrondi le
    // choisit dès la moitié entre le plus grand fini (65504) et le motif qui
    // suivrait (65536) — et à égalité exacte c'est encore lui, sa mantisse étant
    // paire.
    if cible >= 65520 { return signe | 0x7C00 }

    var meilleur: UInt16 = 0
    var meilleurÉcart = Double.infinity
    for motif in UInt16(0)...UInt16(0x7BFF) {
        guard let valeur = versDouble(motif) else { continue }
        let écart = abs(valeur - cible)
        if écart < meilleurÉcart {
            meilleurÉcart = écart
            meilleur = motif
        } else if écart == meilleurÉcart && meilleur & 1 == 1 && motif & 1 == 0 {
            // À égalité, la mantisse paire l'emporte — c'est là que se cachent
            // les erreurs d'un bit.
            meilleur = motif
        }
    }
    return signe | meilleur
}

titre("Demi-flottants, contre la définition")

var épreuves: [(String, Float)] = [
    ("zéro", 0), ("zéro négatif", -0.0), ("un", 1), ("moins un", -1),
    // La plage réellement employée : des dB, entre le plancher et le plafond de
    // l'affichage, plus la valeur de silence que le nuanceur reçoit.
    ("un dB courant", -37.5), ("le plancher", -95), ("le plafond", -25),
    ("le silence du nuanceur", -400),
    // Les bords, où les implémentations se séparent.
    ("le plus grand demi-flottant", 65504),
    ("juste au-delà — infini attendu", 65520),
    ("largement au-delà", 1e30),
    ("le plus petit normal", 6.103515625e-05),
    ("un sous-normal", 3.0517578125e-05),
    ("le plus petit sous-normal", 5.9604645e-08),
    ("la moitié du plus petit — zéro attendu", 2.9802322e-08),
    ("juste au-dessus de la moitié", 3.5e-08),
]
// Et de quoi ne pas se contenter des cas qu'on a su imaginer.
var germe = SystemRandomNumberGenerator()
for _ in 0..<400 {
    épreuves.append(("au hasard", Float.random(in: -500...500, using: &germe)))
}
for _ in 0..<200 {
    épreuves.append(("au hasard, petit", Float.random(in: -1e-4...1e-4, using: &germe)))
}

var désaccords = 0
var premierDésaccord = ""
for (nom, valeur) in épreuves {
    let obtenu = Vector.demiFlottant(valeur)
    let attendu = plusProcheDemi(valeur)
    if obtenu != attendu {
        désaccords += 1
        if premierDésaccord.isEmpty {
            premierDésaccord = String(format: "%@ (%g) : 0x%04X au lieu de 0x%04X",
                                      nom, valeur, obtenu, attendu)
        }
    }
}
verifie(désaccords == 0, "chaque valeur tombe sur le demi-flottant le plus proche",
        désaccords == 0 ? "\(épreuves.count) valeurs" : premierDésaccord)

// Le signe du zéro se perd facilement, et il ne se voit pas dans un écart.
verifie(Vector.demiFlottant(-0.0) == 0x8000, "le zéro négatif garde son signe",
        String(format: "0x%04X", Vector.demiFlottant(-0.0)))
verifie(Vector.demiFlottant(Float.infinity) == 0x7C00, "l'infini reste l'infini")
let nan = Vector.demiFlottant(Float.nan)
verifie(nan & 0x7C00 == 0x7C00 && nan & 0x03FF != 0,
        "un NaN reste un NaN, mantisse non nulle",
        String(format: "0x%04X", nan))

// Et le vecteur, pas seulement la valeur seule : c'est lui que le rendu appelle.
let plage: [Float] = (0..<1024).map { -400 + Float($0) * 400 / 1023 }
var vecteur = [UInt16](repeating: 0, count: plage.count)
plage.withUnsafeBufferPointer { src in
    vecteur.withUnsafeMutableBufferPointer { dst in
        Vector.demiFlottants(src.baseAddress!, into: dst.baseAddress!, count: plage.count)
    }
}
var écartsVecteur = 0
for i in 0..<plage.count where vecteur[i] != plusProcheDemi(plage[i]) { écartsVecteur += 1 }
verifie(écartsVecteur == 0, "la conversion vectorielle donne la même chose",
        "\(plage.count) valeurs sur toute la plage d'affichage")

#if !SPECTRE_PORTABLE && canImport(Accelerate)
// Là où vImage existe, les deux chemins doivent rendre le même motif binaire. Une
// frontière qu'on ne peut pas comparer des deux côtés n'est qu'une promesse.
titre("Demi-flottants, contre vImage")
var désaccordsVImage = 0
for (_, valeur) in épreuves where valeur.isFinite {
    var entrée = valeur
    var obtenu: UInt16 = 0
    withUnsafePointer(to: &entrée) { src in
        withUnsafeMutablePointer(to: &obtenu) { dst in
            Vector.demiFlottants(src, into: dst, count: 1)
        }
    }
    if obtenu != Vector.demiFlottant(valeur) { désaccordsVImage += 1 }
}
verifie(désaccordsVImage == 0, "le chemin portable et vImage donnent le même motif",
        "\(épreuves.count) valeurs")
#endif

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
