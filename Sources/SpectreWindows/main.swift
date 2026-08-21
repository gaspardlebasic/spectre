import Foundation
import SpectreCore
import SpectreModele
import SpectreWin
import WinSDK

// Spectre sous Windows.
//
//     SpectreWindows.exe morceau.wav                      ouvre la fenêtre
//     SpectreWindows.exe morceau.wav --rendu i.ppm        dessine hors écran
//     SpectreWindows.exe morceau.wav --photo i.ppm        ouvre, et photographie
//     SpectreWindows.exe morceau.wav --fluidite 10        fait défiler, et compte
//
// `--taille LARGEURxHAUTEUR` et `--gris` valent pour les deux rendus, et sont ceux
// de `SpectreCLI` : c'est ce qui permet de demander la même image aux deux et de
// les confronter par `ImageCheck`.
//
// L'application est assemblée ici, et nulle part ailleurs : le comportement vit
// dans `SpectreModele`, les pièces de Windows dans `SpectreWin`, et ce fichier ne
// fait que les brancher les unes aux autres, puis tourner.

/// Le modèle, muni de ce que Windows lui fournit.
///
/// Le `typealias` fait que tout ce qui écrit `AppModel` continue de l'écrire. Le
/// modèle est générique sur son lecteur — parce que l'interface observe
/// `model.player.speed` et qu'un protocole existentiel romprait ce suivi — mais
/// rien d'autre n'a de raison de porter ce détail.
typealias AppModel = SpectreModele.AppModel<LecteurWindows>

extension SpectreModele.AppModel where Lecteur == LecteurWindows {
    /// L'assemblage Windows : à chaque protocole du modèle, sa mise en œuvre.
    convenience init(fenetre: HWND?) {
        self.init(lecteur: LecteurWindows(),
                  décodeur: DecodeurWindows(),
                  sinusoide: SinusoideWindows(),
                  pistes: SeparationAbsente(),
                  dialogue: DialogueWindows(fenetre: fenetre),
                  récentsDuSystème: RecentsWindows(),
                  préférences: PreferencesWindows.partagees)
    }
}

// MARK: - Les arguments

var morceau: URL?
var rendreDans: String?
var photographierDans: String?
var mesurerPendant: Double?
var tailleVoulue = (largeur: 1200, hauteur: 700)
var arguments = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < arguments.count {
    let argument = arguments[i]
    if argument == "--rendu", i + 1 < arguments.count {
        rendreDans = arguments[i + 1]
        i += 2
    } else if argument == "--fluidite", i + 1 < arguments.count {
        mesurerPendant = Double(arguments[i + 1]) ?? 10
        i += 2
    } else if argument == "--photo", i + 1 < arguments.count {
        photographierDans = arguments[i + 1]
        i += 2
    } else if argument == "--taille", i + 1 < arguments.count {
        // Le même « 1200x700 » que `SpectreCLI --taille` : c'est ce qui permet de
        // demander aux deux rendus la même image, et donc de les comparer.
        let morceaux = arguments[i + 1].lowercased().split(separator: "x")
        if morceaux.count == 2, let l = Int(morceaux[0]), let h = Int(morceaux[1]),
           l > 0, h > 0 {
            tailleVoulue = (l, h)
        }
        i += 2
    } else if !argument.hasPrefix("--") {
        morceau = URL(fileURLWithPath: argument)
        i += 1
    } else {
        i += 1
    }
}

// MARK: - L'application

/// Ce qui tient la fenêtre, le rendu et le modèle ensemble, et les fait tourner.
///
/// Une classe plutôt que des variables globales : la procédure de fenêtre a besoin
/// de retrouver quelqu'un à qui parler, et un objet est ce qu'elle sait retrouver.
final class Application: EchosDeLaFenetre {
    let fenetre: Fenetre
    let rendu: RenduD3D11
    let modele: AppModel
    let gestes: Gestes
    /// Ne compte que si on l'a demandé : mesurer coûte une horloge par image, ce
    /// qui n'est rien, mais garder cent mille intervalles en mémoire pour personne
    /// n'a pas de sens.
    var mesures: Mesures?
    private var enMarche = true
    private var tailleAChanger: (largeur: Int, hauteur: Int)?

    init?() {
        guard let fenetre = Fenetre(titre: "Spectre", largeur: 1200, hauteur: 700) else {
            return nil
        }
        guard let rendu = RenduD3D11(fenetre: UnsafeMutableRawPointer(fenetre.poignee!)) else {
            return nil
        }
        self.fenetre = fenetre
        self.rendu = rendu
        self.modele = AppModel(fenetre: fenetre.poignee)
        self.gestes = Gestes(modele: modele, fenetre: fenetre)
        modele.renderer = rendu
        rendu.origineDesTeintes = PreferencesWindows.partagees.hueOrigin
        fenetre.echos = self
        Journal.note("carte : \(rendu.nomDeLaCarte)")
    }

    func ouvrir(_ url: URL) {
        modele.open(url)
        fenetre.titre(modele.title)
    }

    /// Ouvre la fenêtre, la laisse tourner quelques images, et photographie ce
    /// qu'elle montre — depuis sa propre chaîne d'échange.
    ///
    /// C'est le pendant Windows de `build/essai/fenetre.png` sur le Mac, et il vaut
    /// mieux que lui : l'image ne vient pas de l'écran mais du tampon que la carte
    /// s'apprête à présenter, si bien que rien ne peut la recouvrir et qu'aucune
    /// autorisation n'est à demander. Surtout, elle passe par le chemin de la
    /// *fenêtre* — appareil, chaîne d'échange, présentation — et non par celui du
    /// rendu hors écran, qui n'en éprouve que la moitié.
    func photographier(dans chemin: String, attente: Double = 30) -> Bool {
        fenetre.montrer()
        // On tourne pour de bon jusqu'à ce que la matrice soit là : l'ouverture
        // d'un fichier part en tâche de fond et rend son résultat par la file
        // principale, donc photographier au bout de dix images ne montrerait
        // qu'une fenêtre noire — et ferait accuser le nuanceur.
        let echeance = Horloge.maintenant() + attente
        while Horloge.maintenant() < echeance {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            appliquerLaTaille()
            rendu.attendreLImageSuivante()
            uneImage()
            if modele.spectrogram.columnCount > 0, modele.progress == nil { break }
        }
        guard modele.spectrogram.columnCount > 0 else {
            Journal.erreur("Rien n'a été analysé en \(Int(attente)) s"
                           + (modele.status.map { " — \($0)" } ?? "") + ".")
            return false
        }

        // La dernière image est dessinée **sans être présentée** : la chaîne est en
        // modèle *flip*, et présenter abandonne le contenu du tampon zéro. Le relire
        // après coup ne rendrait que du noir — ce qui ressemble en tout point à un
        // nuanceur qui ne dessine rien.
        uneImageSansPresenter()
        guard let pixels = rendu.relire() else {
            Journal.erreur("La chaîne d'échange n'a rien rendu.")
            return false
        }
        do {
            try PPM.write(width: rendu.largeur, height: rendu.hauteur,
                          pixels: pixels, to: URL(fileURLWithPath: chemin))
        } catch {
            Journal.erreur("\(error)")
            return false
        }
        print("→ \(chemin) (\(rendu.largeur)×\(rendu.hauteur))")
        return true
    }

    // MARK: La boucle

    func tourner() {
        fenetre.montrer()
        while enMarche {
            viderLaFilePrincipale()
            if !fenetre.traiterLesMessages() { break }
            appliquerLaTaille()
            // On dort **avant** de dessiner : l'image montrée porte alors l'état le
            // plus frais possible, et c'est ce qui la garde collée au doigt. Dormir
            // après avoir présenté reviendrait à dessiner un état déjà vieux d'une
            // image.
            rendu.attendreLImageSuivante()
            uneImage()
        }
        modele.applicationVaSeFermer()
    }

    private func appliquerLaTaille() {
        guard let taille = tailleAChanger else { return }
        tailleAChanger = nil
        rendu.redimensionner(largeur: taille.largeur, hauteur: taille.hauteur)
    }

    private func uneImage() {
        uneImageSansPresenter()
        rendu.presenter()
        mesures?.uneImage()
        if rendu.fenetreCachee { mesures?.uneImageCachee() }
    }

    private func uneImageSansPresenter() {
        let points = fenetre.taillePoints
        modele.tick(viewSize: CGSize(width: points.largeur, height: points.hauteur))
        rendu.viewport = modele.viewport
        rendu.display = modele.display
        rendu.origineDesTeintes = PreferencesWindows.partagees.hueOrigin
        rendu.teteDeLecture = colonne(deLInstant: modele.playhead)
        rendu.boucle = modele.loop.flatMap { plage in
            guard let debut = colonne(deLInstant: plage.lowerBound),
                  let fin = colonne(deLInstant: plage.upperBound), fin > debut
            else { return nil }
            return debut...fin
        }
        rendu.dessiner(echelle: fenetre.echelle)
    }

    /// Le nuanceur raisonne en colonnes, comme tout le reste du rendu : la
    /// conversion se fait ici, une fois, plutôt que dans le nuanceur qui n'a que
    /// faire des secondes.
    private func colonne(deLInstant t: Double) -> Double? {
        let matrice = modele.spectrogram
        guard matrice.columnCount > 0, matrice.secondsPerColumn > 0 else { return nil }
        return matrice.column(atTime: t)
    }

    // MARK: Ce que la fenêtre fait savoir

    func fenetreRedimensionnee(largeur: Int, hauteur: Int) {
        tailleAChanger = (largeur, hauteur)
    }

    func fenetreChangeDEchelle(_ echelle: Double) {
        let pixels = fenetre.taillePixels
        tailleAChanger = (pixels.largeur, pixels.hauteur)
    }

    func fenetreDemandeUneImage() {
        // Windows tourne dans sa propre boucle pendant qu'on tire un bord de la
        // fenêtre, et la nôtre ne reprend qu'au relâchement. Redessiner d'ici est ce
        // qui empêche l'image de rester figée pendant tout ce temps — ce qui se lit
        // comme un plantage.
        appliquerLaTaille()
        uneImage()
    }

    func fenetrePeutSeFermer() -> Bool {
        enMarche = false
        return true
    }

    func fenetreRecoitUneEntree(_ message: UINT, _ w: WPARAM, _ l: LPARAM) -> Bool {
        gestes.mesures = mesures
        return gestes.repondre(message, w, l)
    }

    // MARK: La fluidité

    /// Fait défiler l'image pendant `secondes`, et rend le compte de ce que cela a
    /// coûté.
    ///
    /// Le défilement est **posté à notre propre fenêtre** en vrais messages de
    /// molette : le geste traverse donc exactement le même chemin qu'un doigt sur
    /// le pavé — procédure de fenêtre, traduction, modèle, recadrage, nuanceur,
    /// présentation. Piloter le viewport directement mesurerait le rendu, pas
    /// l'application.
    func mesurerLaFluidite(secondes: Double) -> String {
        let compteur = Mesures()
        mesures = compteur
        fenetre.montrer()

        // On laisse d'abord l'analyse finir : mesurer pendant qu'un cœur calcule la
        // matrice donnerait le coût de l'analyse, pas celui du défilement.
        let limite = Horloge.maintenant() + 30
        while modele.spectrogram.columnCount == 0, Horloge.maintenant() < limite {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            rendu.attendreLImageSuivante()
            uneImage()
        }
        // Une seconde de chauffe, jetée. La chaîne d'échange met quelques images à
        // se caler sur le balayage, et la première image après l'analyse porte
        // encore le téléversement de la matrice — des centaines de mégaoctets vers
        // la carte, qui n'ont rien à voir avec le défilement qu'on mesure.
        let chauffe = Horloge.maintenant() + 1
        while Horloge.maintenant() < chauffe {
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            rendu.attendreLImageSuivante()
            uneImage()
        }
        compteur.recommencer()

        let echeance = Horloge.maintenant() + secondes
        var sens = 1
        var tours = 0
        while Horloge.maintenant() < echeance {
            // Un cran de molette à chaque image, et l'on change de sens de temps en
            // temps pour rester dans la matrice plutôt que de buter contre son bord.
            tours += 1
            if tours % 120 == 0 { sens = -sens }
            if let poignee = fenetre.poignee {
                let cran = WPARAM(UInt32(bitPattern: Int32(sens * 120) << 16))
                PostMessageW(poignee, UINT(WM_MOUSEHWHEEL), cran, 0)
            }
            viderLaFilePrincipale()
            _ = fenetre.traiterLesMessages()
            appliquerLaTaille()
            rendu.attendreLImageSuivante()
            uneImage()
        }
        mesures = nil
        return compteur.rapport(carte: rendu.nomDeLaCarte)
    }
}

// MARK: - Le rendu hors écran

// `--rendu` fait le travail d'une fenêtre sans en ouvrir une : c'est ce qui permet
// de mesurer l'image là où il n'y a pas de bureau, et de la comparer au rendu
// processeur par `ImageCheck`.
if let sortie = rendreDans {
    guard let morceau else {
        Journal.erreur("« --rendu » demande un fichier à rendre.")
        exit(2)
    }
    guard let rendu = RenduD3D11(largeur: tailleVoulue.largeur,
                                hauteur: tailleVoulue.hauteur) else { exit(1) }
    let source: AudioSource
    do {
        source = try DecodeurWindows().charger(morceau)
    } catch {
        Journal.erreur("\(error)")
        exit(1)
    }
    let reglages = AnalysisSettings(reassignment: PreferencesWindows.partagees.reassignment)
    let matrice = OfflineAnalysis.run(samples: source.mono,
                                      sampleRate: source.sampleRate,
                                      settings: reglages)
    rendu.layout = matrice.layout
    rendu.upload(matrice)
    rendu.viewport = Viewport.fitting(columns: matrice.columnCount, bins: matrice.binCount,
                                      size: (Double(tailleVoulue.largeur),
                                             Double(tailleVoulue.hauteur)))
    // Le même réglage automatique que dans l'application, et que dans `SpectreCLI`.
    // Sans lui les deux rendus ne comparent plus la même chose : l'image du GPU
    // sort avec le contraste d'origine et celle du processeur avec le contraste
    // réglé, ce qui se lit comme un désaccord de nuanceur alors que la formule est
    // la même des deux côtés.
    if let regle = AutoContrast.settings(basedOn: rendu.display, in: matrice) {
        rendu.display = regle
    }
    // `--gris`, comme `SpectreCLI --gris` : voir là-bas pourquoi la palette des
    // notes empêche de comparer deux rendus sur leur géométrie.
    if arguments.contains("--gris") { rendu.display.colorMap = .gray }
    rendu.dessiner(echelle: 1)
    guard let pixels = rendu.relire() else {
        Journal.erreur("La carte n'a rien rendu.")
        exit(1)
    }
    do {
        try PPM.write(width: tailleVoulue.largeur, height: tailleVoulue.hauteur, pixels: pixels,
                      to: URL(fileURLWithPath: sortie))
    } catch {
        Journal.erreur("\(error)")
        exit(1)
    }
    print("→ \(sortie)")
    exit(0)
}

// MARK: - La fenêtre

guard let application = Application() else { exit(1) }
if let morceau { application.ouvrir(morceau) }
if let photographierDans {
    exit(application.photographier(dans: photographierDans) ? 0 : 1)
}
if let mesurerPendant {
    print(application.mesurerLaFluidite(secondes: mesurerPendant))
    exit(0)
}
application.tourner()
