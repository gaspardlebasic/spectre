import Foundation
import SpectreModele
import WinSDK

// La fluidité, en nombres.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE FICHIER EXISTE
//
// C'est la seule chose du portage qu'aucune image relue ne peut dire. Une carte
// paravirtualisée dans une machine virtuelle ne saura jamais répondre à « est-ce
// que le défilement est doux » — mais elle peut répondre à « combien de temps
// entre deux images », « combien en ont pris plus du double », et « combien de
// temps entre le cran de molette et l'image qui le montre ».
//
// Ces nombres-là ne prouvent pas la fluidité. Ils donnent une **borne inférieure**
// et un point de comparaison : entre deux versions sur la même machine, entre la
// machine virtuelle et du matériel réel. C'est très exactement ce qu'on peut
// obtenir d'ici, et c'est mieux que de demander à quelqu'un si ça a l'air fluide.
//
// Ce qu'on regarde n'est pas la moyenne — elle est toujours bonne — mais **la
// queue** : le 99ᵉ centile et le pire. Une image sur cent qui prend trois fois
// trop de temps se voit, et se voit exactement là où on regarde, parce qu'elle
// arrive quand la charge monte, c'est-à-dire pendant qu'on fait un geste.
// ─────────────────────────────────────────────────────────────────────────────

/// Ce qui compte les images, et le temps qu'elles mettent.
final class Mesures {
    /// Intervalles entre images, en millisecondes.
    private var intervalles: [Double] = []
    /// Latences entre une entrée et l'image qui la montre, en millisecondes.
    private var latences: [Double] = []
    private var derniereImage: Double?
    /// Instant de la plus ancienne entrée pas encore montrée. `nil` quand on
    /// n'attend rien — une image rendue sans geste ne mesure aucune latence.
    private var entreeEnAttente: Double?

    /// Cadence de l'écran, telle que Windows la déclare. Sert à dire combien
    /// d'images ont manqué leur tour, et non à cadencer quoi que ce soit.
    let cadence: Double

    init() {
        var mode = DEVMODEW()
        mode.dmSize = WORD(MemoryLayout<DEVMODEW>.size)
        // `ENUM_CURRENT_SETTINGS` vaut −1, et c'est une macro : Swift ne l'importe
        // pas. Voir `Macros.swift` pour les autres.
        let obtenu = EnumDisplaySettingsW(nil, DWORD(bitPattern: -1), &mode)
        cadence = obtenu && mode.dmDisplayFrequency > 1 ? Double(mode.dmDisplayFrequency) : 60
        intervalles.reserveCapacity(100_000)
        latences.reserveCapacity(10_000)
    }

    /// Une entrée vient d'arriver. Seule la première d'une rafale compte : ce qu'on
    /// mesure est le retard entre le geste et ce qu'il montre, et un geste continu
    /// en fait arriver dix par image.
    func uneEntree() {
        if entreeEnAttente == nil { entreeEnAttente = Horloge.maintenant() }
    }

    /// Nombre d'images présentées alors que la fenêtre était cachée. Une seule
    /// suffit à rendre le relevé suspect ; toutes le rendent sans objet.
    private(set) var imagesCachees = 0

    func uneImageCachee() { imagesCachees += 1 }

    /// Une image vient d'être présentée.
    func uneImage() {
        let maintenant = Horloge.maintenant()
        if let precedente = derniereImage {
            intervalles.append((maintenant - precedente) * 1000)
        }
        derniereImage = maintenant
        if let attente = entreeEnAttente {
            latences.append((maintenant - attente) * 1000)
            entreeEnAttente = nil
        }
    }

    func recommencer() {
        intervalles.removeAll(keepingCapacity: true)
        latences.removeAll(keepingCapacity: true)
        derniereImage = nil
        entreeEnAttente = nil
        imagesCachees = 0
    }

    var nombreDImages: Int { intervalles.count + 1 }

    /// Le rapport, tel qu'on le lit et tel qu'on le compare d'une version à l'autre.
    func rapport(carte: String) -> String {
        guard intervalles.count > 1 else {
            return "Pas assez d'images pour mesurer quoi que ce soit."
        }
        let triees = intervalles.sorted()
        func centile(_ p: Double) -> Double {
            let i = min(max(Int(p * Double(triees.count - 1)), 0), triees.count - 1)
            return triees[i]
        }
        let moyenne = intervalles.reduce(0, +) / Double(intervalles.count)

        // La référence est la cadence **obtenue**, pas celle que l'écran annonce.
        //
        // Les deux ne sont pas la même chose, et la machine virtuelle le montre
        // crûment : Windows y annonce 120 Hz — c'est l'écran du Mac hôte — tandis
        // que la chaîne d'échange est cadencée à 60. Compter les images perdues
        // contre les 120 annoncés en donnerait les trois quarts, ce qui ne dit rien
        // de la fluidité et beaucoup sur la façon dont Parallels compose.
        //
        // La médiane, elle, est la période que la carte tient vraiment. Un
        // intervalle qui la dépasse de moitié est une image qui a manqué son tour,
        // et cela se voit — le seuil est à 1,5 et non à 2, parce qu'une image en
        // retard d'un demi-tour arrive au tour suivant et fait déjà un à-coup.
        let periodeObtenue = centile(0.5)
        let perdues = intervalles.filter { $0 > periodeObtenue * 1.5 }.count
        let part = 100 * Double(perdues) / Double(intervalles.count)
        let obtenue = periodeObtenue > 0 ? 1000 / periodeObtenue : 0

        var texte = """
        Fluidité — \(carte)
          écran annoncé à \(String(format: "%.0f", cadence)) Hz, \
        cadence obtenue \(String(format: "%.1f", obtenue)) Hz
          \(nombreDImages) images mesurées
          intervalle : moyen \(String(format: "%.2f", moyenne)) ms, \
        médian \(String(format: "%.2f", periodeObtenue)) ms
          la queue   : 95ᵉ \(String(format: "%.2f", centile(0.95))) ms, \
        99ᵉ \(String(format: "%.2f", centile(0.99))) ms, \
        pire \(String(format: "%.2f", triees.last ?? 0)) ms
          images qui ont manqué leur tour : \(perdues) \
        (\(String(format: "%.2f", part)) %)
        """

        if obtenue > 0, abs(obtenue - cadence) / cadence > 0.15 {
            texte += """

              note : l'écran annonce une cadence que la chaîne d'échange ne tient \
            pas. Les images perdues sont comptées contre la cadence obtenue, \
            qui est la seule que l'œil verrait.
            """
        }

        if imagesCachees > 0 {
            let part = 100 * Double(imagesCachees) / Double(nombreDImages)
            texte += """

              ⚠ \(imagesCachees) image(s) présentées fenêtre cachée \
            (\(String(format: "%.0f", part)) %) — la carte ne cadence plus, et \
            ces intervalles-là ne disent rien de la fluidité.
            """
        }

        if latences.count > 1 {
            let l = latences.sorted()
            func centileL(_ p: Double) -> Double {
                let i = min(max(Int(p * Double(l.count - 1)), 0), l.count - 1)
                return l[i]
            }
            texte += """

              molette → affichage : médian \(String(format: "%.2f", centileL(0.5))) ms, \
            95ᵉ \(String(format: "%.2f", centileL(0.95))) ms, \
            pire \(String(format: "%.2f", l.last ?? 0)) ms \
            (\(l.count) gestes)
            """
        }
        return texte
    }
}
