import Accelerate
import Foundation

// Confronte les transformées Swift à une référence produite par PyTorch, avec les
// conventions exactes de Demucs. Ce qu'on vérifie n'est pas « une STFT » mais
// celle-là : fenêtre, saut, normalisation, réflexions, rognage.

var failures = 0

func check(_ passed: Bool, _ what: String, _ detail: String = "") {
    print("  \(passed ? "✓" : "✗") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !passed { failures += 1 }
}

let folder = URL(fileURLWithPath: "build/fourier")

func read(_ name: String) -> [Float] {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else {
        print("Référence absente : \(name). Lancer Tools/Fourier/reference.py.")
        exit(2)
    }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// Écart relatif à l'amplitude de la référence : c'est la seule mesure qui ait un
/// sens ici, les valeurs brutes n'ayant pas la même échelle d'un tableau à l'autre.
func compare(_ mine: [Float], _ reference: [Float], _ what: String, tolerance: Float = 2e-4) {
    guard mine.count == reference.count else {
        check(false, what, "\(mine.count) valeurs contre \(reference.count)")
        return
    }
    let scale = reference.map(abs).max() ?? 1
    let worst = zip(mine, reference).map { abs($0 - $1) }.max() ?? 0
    let relative = worst / max(scale, 1e-9)
    check(relative < tolerance, what,
          String(format: "écart %.2e pour une amplitude %.2f (%.4f %%)",
                 worst, scale, 100 * relative))
}

guard let fourier = DemucsFourier() else {
    print("Impossible de préparer la FFT.")
    exit(2)
}

// MARK: - Rembourrage par réflexion

print("=== Réflexion ===")
let petit: [Float] = [1, 2, 3, 4]
check(DemucsFourier.reflect(petit, left: 2, right: 0) == [3, 2, 1, 2, 3, 4],
      "réflexion à gauche sans répéter le bord",
      "\(DemucsFourier.reflect(petit, left: 2, right: 0))")
check(DemucsFourier.reflect(petit, left: 0, right: 2) == [1, 2, 3, 4, 3, 2],
      "réflexion à droite sans répéter le bord",
      "\(DemucsFourier.reflect(petit, left: 0, right: 2))")

// MARK: - Aller

print()
print("=== Spectre ===")
let signal = read("signal.f32")
let attenduReel = read("spectre-reel.f32")
let attenduImag = read("spectre-imag.f32")
let (reel, imaginaire) = fourier.spectrogram(of: signal)
check(reel.count == attenduReel.count, "le spectre a la taille attendue",
      "\(reel.count) contre \(attenduReel.count)")
compare(reel, attenduReel, "partie réelle")
compare(imaginaire, attenduImag, "partie imaginaire")

// MARK: - Retour

print()
print("=== Inverse ===")
let inverseReel = read("inverse-reel.f32")
let inverseImag = read("inverse-imag.f32")
let attenduSignal = read("inverse-signal.f32")
let rendu = fourier.signal(real: inverseReel, imaginary: inverseImag,
                           length: attenduSignal.count)
compare(rendu, attenduSignal, "signal reconstruit")

// MARK: - Aller-retour

print()
print("=== Aller-retour ===")
let boucle = fourier.signal(real: reel, imaginary: imaginaire, length: signal.count)
compare(boucle, read("aller-retour.f32"), "même chemin que PyTorch")
// Le tour complet ne rend **pas** exactement le signal, et ce n'est pas un défaut :
// Demucs jette la raie de Nyquist à l'aller et la remet à zéro au retour. Sur du
// bruit blanc, qui en porte autant que partout ailleurs, cela coûte moins d'un
// pour cent. Aux bords, le rembourrage n'est pas inversible non plus : on les écarte.
let interieur = 4096
let coeurA = Array(boucle[interieur..<boucle.count - interieur])
let coeurB = Array(signal[interieur..<signal.count - interieur])
compare(coeurA, coeurB, "le tour complet rend le signal, à Nyquist près",
        tolerance: 2e-2)

print()
print(failures == 0 ? "Tout est bon." : "\(failures) vérification(s) en échec.")
exit(failures == 0 ? 0 : 1)
