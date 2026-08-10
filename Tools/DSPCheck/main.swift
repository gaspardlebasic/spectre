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

    return [
        ("une raie tombant dans une case",
         (0..<n).map { sin(2 * .pi * 5 * Float($0) / Float(n)) }),
        ("une raie entre deux cases",
         (0..<n).map { sin(2 * .pi * 5.37 * Float($0) / Float(n)) }),
        ("deux raies et une composante continue",
         (0..<n).map { 0.3 + sin(2 * .pi * 11 * Float($0) / Float(n))
                           + 0.5 * cos(2 * .pi * 40.2 * Float($0) / Float(n)) }),
        ("une impulsion", impulsion),
        ("du bruit", bruit),
        ("le silence", [Float](repeating: 0, count: n)),
    ]
}

#if canImport(Accelerate)

for n in [512, 4096, 8192] {
    titre("Aller, N = \(n)")
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

titre("Comparaison")
print("  (Accelerate absent : il n'y a rien à comparer, la version portable est seule)")

#endif

print("")
if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) contrôle(s) en échec.")
    exit(1)
}
