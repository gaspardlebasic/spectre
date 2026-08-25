import Foundation
import SpectreCore

// Le même harnais sur deux cartes graphiques. Ce qui change tient en un nom de
// module et un nom de classe : la chaîne mesurée — téléversement, nuanceur,
// relecture — est écrite une seule fois, dans `SpectreToile`.
#if os(Windows)
import SpectreWin
typealias RenduMesure = RenduD3D11
#else
import SpectreLin
typealias RenduMesure = RenduGL
#endif

// Vérification du rendu sur carte graphique : on fabrique une matrice de synthèse, on la
// fait passer par la vraie chaîne — téléversement, nuanceur, relecture — et on
// mesure ce qui sort. Aucune fenêtre : tout se fait hors écran.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE PROGRAMME EXISTE
//
// Les nuanceurs HLSL puis GLSL ont été traduits du MSL sans qu'aucune machine ne
// puisse les afficher pendant l'écriture. Or « ça a l'air bien » ne distingue pas
// une image juste d'une image retournée, décalée d'un pixel, ou dont le contraste a
// glissé — toutes plausibles. Le retournement de l'axe vertical est le piège même
// du portage, et se tromper produit une image parfaitement crédible.
//
// Les trois scènes sont celles de `Tools/RenderCheck`, qui mesure la version
// Metal. **Trois cartes graphiques tenues au même barème**, avec les mêmes
// nombres : c'est la seule façon de savoir que les trois écritures disent la même
// chose.
// ─────────────────────────────────────────────────────────────────────────────

var echecs = 0
func controle(_ intitule: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "✓" : "✗") \(intitule) — \(detail)")
    if !ok { echecs += 1 }
}

let sortie = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "rendu.ppm"

let largeur = 600, hauteur = 300
guard let rendu = RenduMesure(largeur: largeur, hauteur: hauteur) else {
    print("  ✗ Direct3D 11 indisponible")
    exit(1)
}
print("Carte : \(rendu.nomDeLaCarte)")

let lignes = 180
let colonnes = 3000

func geometrie() -> BinLayout {
    var l = BinLayout()
    l.binCount = lignes
    l.minFrequency = 27.5
    l.maxFrequency = 27.5 * pow(2, Double(lignes) / 36)
    l.binsPerOctave = 36
    l.sampleRate = 48000
    return l
}

/// Rend une image et renvoie sa clarté (0…1), rangée par rangée depuis le **haut**.
func dessiner(_ spectrogramme: Spectrogram, viewport: Viewport) -> [Float] {
    rendu.layout = spectrogramme.layout
    rendu.upload(spectrogramme)
    rendu.viewport = viewport
    rendu.display.colorMap = .gray
    rendu.display.gamma = 1
    rendu.display.tiltDbPerOctave = 0
    rendu.display.floorDb = -100
    rendu.display.ceilingDb = 0
    rendu.teteDeLecture = nil
    rendu.boucle = nil
    rendu.dessiner(echelle: 1)
    guard let pixels = rendu.relire() else { return [] }
    return (0..<(largeur * hauteur)).map { Float(pixels[$0 * 3]) / 255 }
}

func rangeeLaPlusClaire(_ pixels: [Float], colonne x: Int) -> (rangee: Int, valeur: Float) {
    var meilleure = 0
    var valeur = Float(0)
    for y in 0..<hauteur where pixels[y * largeur + x] > valeur {
        valeur = pixels[y * largeur + x]
        meilleure = y
    }
    return (meilleure, valeur)
}

// MARK: - Scène 1 : une rampe fréquence/temps

// Une raie qui monte régulièrement : elle dit d'un coup si le temps va bien vers
// la droite, les graves vers le bas, et si la fenêtre visible est respectée.
print("\n=== Cadrage complet ===")
var rampe = [Float](repeating: -200, count: colonnes * lignes)
func ligneDeLaRampe(_ c: Int) -> Int { 10 + c * 150 / colonnes }
for c in 0..<colonnes {
    rampe[c * lignes + ligneDeLaRampe(c)] = 0
}
let sceneRampe = Spectrogram(layout: geometrie(), columnCount: colonnes,
                             secondsPerColumn: 0.01, values: rampe)

var viewport = Viewport.fitting(columns: colonnes, bins: lignes,
                                size: (Double(largeur), Double(hauteur)))
let complet = dessiner(sceneRampe, viewport: viewport)
guard complet.count == largeur * hauteur else {
    print("  ✗ la carte n'a rien rendu")
    exit(1)
}

var ecartMax = 0.0
for x in stride(from: 20, to: largeur - 20, by: 60) {
    let trouvee = rangeeLaPlusClaire(complet, colonne: x)
    let colonne = Int(viewport.column(atPoint: Double(x) + 0.5))
    let attendue = viewport.point(ofBin: Double(ligneDeLaRampe(colonne)) + 0.5,
                                  height: Double(hauteur))
    ecartMax = max(ecartMax, abs(Double(trouvee.rangee) + 0.5 - attendue))
}
controle("la raie tombe où la fenêtre le prévoit", ecartMax < 2.5,
         String(format: "écart max %.1f px", ecartMax))

// Le contrôle qui attrape le piège de l'axe vertical. Une image retournée passe
// tous les autres — elle est lisse, contrastée, et sa raie est bien droite.
let basGauche = rangeeLaPlusClaire(complet, colonne: 5)
let hautDroite = rangeeLaPlusClaire(complet, colonne: largeur - 5)
controle("les graves sont en bas, le temps va vers la droite",
         basGauche.rangee > hauteur * 2 / 3 && hautDroite.rangee < hauteur / 3,
         "début à la rangée \(basGauche.rangee), fin à la rangée \(hautDroite.rangee)")

// MARK: - Scène 2 : un transitoire d'une seule colonne

// Dézoomé, un pixel couvre cinq colonnes : une attaque isolée doit survivre, parce
// que le nuanceur prend le maximum et non la moyenne.
print("\n=== Transitoire au dézoom ===")
var clic = [Float](repeating: -200, count: colonnes * lignes)
let colonneDuClic = 1500
for i in 0..<lignes { clic[colonneDuClic * lignes + i] = 0 }
let sceneClic = Spectrogram(layout: geometrie(), columnCount: colonnes,
                            secondsPerColumn: 0.01, values: clic)
let dezoome = dessiner(sceneClic, viewport: viewport)
let xAttendu = Int(viewport.point(ofColumn: Double(colonneDuClic)))
var sommetDuClic = Float(0)
for x in max(0, xAttendu - 2)...min(largeur - 1, xAttendu + 2) {
    sommetDuClic = max(sommetDuClic, dezoome[(hauteur / 2) * largeur + x])
}
controle("une colonne isolée reste visible à "
         + String(format: "%.0f", viewport.columnsPerPoint) + " colonnes par pixel",
         sommetDuClic > 0.9, String(format: "%.2f de clarté à x≈%d", sommetDuClic, xAttendu))

// MARK: - Scène 3 : zoom et défilement

print("\n=== Zoom ancré ===")
let ancre = 137.0
let avant = viewport.column(atPoint: ancre)
viewport.zoomTime(factor: 20, anchorX: ancre)
let apres = viewport.column(atPoint: ancre)
controle("la colonne sous le curseur ne bouge pas", abs(avant - apres) < 1e-9,
         String(format: "%.6f contre %.6f", avant, apres))

let zoome = dessiner(sceneRampe, viewport: viewport)
var ecartZoom = 0.0
for x in stride(from: 20, to: largeur - 20, by: 60) {
    let trouvee = rangeeLaPlusClaire(zoome, colonne: x)
    let colonne = Int(viewport.column(atPoint: Double(x) + 0.5))
    let attendue = viewport.point(ofBin: Double(ligneDeLaRampe(colonne)) + 0.5,
                                  height: Double(hauteur))
    ecartZoom = max(ecartZoom, abs(Double(trouvee.rangee) + 0.5 - attendue))
}
controle("la raie suit toujours après zoom", ecartZoom < 2.5,
         String(format: "écart max %.1f px", ecartZoom))

// MARK: - Scène 4 : les marques

// La tête de lecture et la boucle sont tracées par le nuanceur, et non par un
// second passage. Elles se mesurent donc ici, et nulle part ailleurs.
print("\n=== Tête de lecture et boucle ===")
viewport = Viewport.fitting(columns: colonnes, bins: lignes,
                            size: (Double(largeur), Double(hauteur)))
rendu.viewport = viewport
rendu.teteDeLecture = Double(colonnes) / 2
rendu.boucle = (Double(colonnes) * 0.25)...(Double(colonnes) * 0.75)
rendu.dessiner(echelle: 1)
let marquees = rendu.relire().map { pixels in
    (0..<(largeur * hauteur)).map { Float(pixels[$0 * 3]) / 255 }
} ?? []

if marquees.count == largeur * hauteur {
    let y = hauteur / 2
    let xTete = Int(viewport.point(ofColumn: Double(colonnes) / 2))
    var clarteTete = Float(0)
    for x in max(0, xTete - 1)...min(largeur - 1, xTete + 1) {
        clarteTete = max(clarteTete, marquees[y * largeur + x])
    }
    controle("la tête de lecture est tracée où on la demande", clarteTete > 0.85,
             String(format: "%.2f de clarté à x≈%d", clarteTete, xTete))

    // Hors boucle, le fond est assombri : sur une matrice à −200 dB il reste noir,
    // et c'est justement la raie de la rampe qui sert de témoin. On la cherche donc
    // des deux côtés du bord gauche de la boucle.
    let xBord = Int(viewport.point(ofColumn: Double(colonnes) * 0.25))
    var clarteBord = Float(0)
    for x in max(0, xBord - 1)...min(largeur - 1, xBord + 1) {
        for yy in 0..<hauteur { clarteBord = max(clarteBord, marquees[yy * largeur + x]) }
    }
    controle("le bord de la boucle est tracé", clarteBord > 0.5,
             String(format: "%.2f de clarté à x≈%d", clarteBord, xBord))
} else {
    controle("les marques se relisent", false, "la carte n'a rien rendu")
}

// MARK: - L'image, pour l'œil qui viendra

// Rendue en couleurs et à la palette par défaut : c'est ce qu'on regarde quand on
// veut juger, et ce que `ImageCheck` compare au rendu processeur.
rendu.teteDeLecture = nil
rendu.boucle = nil
rendu.display = DisplaySettings()
rendu.viewport = Viewport.fitting(columns: colonnes, bins: lignes,
                                  size: (Double(largeur), Double(hauteur)))
rendu.upload(sceneRampe)
rendu.dessiner(echelle: 1)
if let pixels = rendu.relire() {
    try? PPM.write(width: largeur, height: hauteur, pixels: pixels,
                   to: URL(fileURLWithPath: sortie))
    print("\n→ \(sortie)")
}

if echecs == 0 {
    print("Tout est bon.")
} else {
    print("\(echecs) vérification(s) en échec.")
    exit(1)
}
