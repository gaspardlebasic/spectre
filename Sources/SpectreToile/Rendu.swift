// Le spectrogramme sur la carte graphique, des deux côtés à la fois.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CETTE CLASSE EST ICI ET NON DANS UNE COUCHE DE PLATEFORME
//
// Elle vivait dans `SpectreWin`, sous le nom de `RenduD3D11`. En regardant ce
// qu'elle fait vraiment : elle découpe la matrice en tuiles, convertit les dB en
// demi-flottants, calcule une quinzaine d'uniformes depuis le viewport et les
// réglages d'affichage, et renvoie la table des notes quand la saturation ou
// l'origine des teintes a changé. Pas une ligne de tout cela ne connaît Direct3D :
// tout passe par les treize fonctions du pont, que `d3d11.c` et `gl.c` exportent
// sous les mêmes noms.
//
// Ce qui reste de plateforme est en dehors : le nuanceur — HLSL dans
// `SpectreWin/Rendu.swift`, GLSL dans `SpectreLin/Rendu.swift` — et le journal où
// va ce qui rate. Les deux entrent par l'initialiseur.
// ─────────────────────────────────────────────────────────────────────────────

import CPont
import Foundation
import SpectreCore
import SpectreDSP
import SpectreModele

// MARK: - Le rendu

/// Rendu d'une fenêtre du spectrogramme, sur la carte graphique — Direct3D 11 sous
/// Windows, OpenGL 3.3 sous Linux, sans que cette classe le sache.
///
/// Elle ne fait que piloter les treize fonctions de `Sources/CPont`, dont
/// `d3d11.c` et `gl.c` exportent les mêmes noms avec les mêmes signatures. Tout ce
/// qui est ici — le découpage en tuiles, la conversion en demi-flottants, le calcul
/// des uniformes, la table des notes envoyée quand elle change — est le même
/// travail des deux côtés, et il n'y avait aucune raison de l'écrire deux fois.
///
/// La matrice ne défile pas : elle est envoyée une fois pour toutes sur le GPU et
/// c'est la *fenêtre* qui bouge. Comme une texture plafonne en hauteur et qu'une
/// heure de musique fait des centaines de milliers de colonnes, elle est découpée
/// en tuiles empilées dans un `Texture2DArray` — le nuanceur retrouve la sienne
/// par une division, il n'y a donc toujours qu'un seul appel de dessin.
public final class RenduSpectre: RenduSpectrogramme {

    /// Hauteur d'une tuile, en colonnes. Direct3D 11 garantit 2 048 tranches et
    /// 16 384 pixels de côté, OpenGL 3.3 au moins 256 et 1 024 ; 4 096 colonnes par
    /// tuile laisse de la marge partout et fait le même découpage que la version
    /// Metal.
    private static let hauteurTuile = 4096

    private let pont: OpaquePointer

    /// Le même pont, pour la surimpression : ce qui se dessine par-dessus le
    /// spectrogramme écrit dans le tampon de ce rendu-ci, et il lui faut donc la même
    /// poignée. Public parce que la couche de la plateforme est dans un autre module
    /// — Direct2D d'un côté, Cairo de l'autre — et que c'est elle qui attache le
    /// pinceau. Ce n'est pas une fuite d'abstraction : c'est la couture, et elle est
    /// nommée.
    public var pontBrut: OpaquePointer { pont }

    /// Zone où le nuanceur dessine, en points. `nil` veut dire toute la fenêtre.
    /// Posée par `zone(largeur:hauteur:echelle:)`, du côté de la plateforme.
    public var zoneEnPoints: (largeur: Double, hauteur: Double)?

    public private(set) var colonnes = 0
    public private(set) var lignes = 0
    public private(set) var generation = 0

    /// Géométrie de l'axe des fréquences, nécessaire aux couleurs de notes.
    public var layout = BinLayout()
    /// Transposition en cours, en demi-tons : elle décale la palette des notes, et
    /// rien d'autre. Voir `RenduSpectrogramme`.
    public var demiTons: Double = 0

    /// Ce que le rendu doit afficher, renseigné à chaque image par la fenêtre.
    public var viewport = Viewport()
    public var display = DisplaySettings()
    /// Note qui reçoit la première teinte du cycle des quintes.
    public var origineDesTeintes = 0
    /// Tête de lecture et boucle, **en colonnes**. `nil` les éteint.
    public var teteDeLecture: Double?
    public var boucle: ClosedRange<Double>?

    private var saturationDeLaTable = Double.nan
    private var origineDeLaTable = Int.min
    private var tableEnvoyee = false

    /// Où va ce qui ne peut pas s'afficher dans la fenêtre. Posé par la plateforme :
    /// un module partagé n'a pas à savoir s'il existe une console, un débogueur, ou
    /// ni l'un ni l'autre.
    private let journal: (String) -> Void

    /// Le rendu attaché à une fenêtre — un `HWND` sous Windows, un `SDL_Window *`
    /// sous Linux. Le pont sait lequel il reçoit ; cette classe non.
    public init?(fenetre: UnsafeMutableRawPointer, nuanceur: String,
                 journal: @escaping (String) -> Void) {
        self.journal = journal
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        guard let p = nuanceur.withCString({ source in
            erreur.withUnsafeMutableBufferPointer { tampon in
                spectre_rendu_creer(fenetre, source, tampon.baseAddress)
            }
        }) else {
            journal(String(cString: erreur))
            return nil
        }
        pont = p
    }

    /// Le rendu sans fenêtre, vers une cible qu'on relit.
    ///
    /// C'est ce qui permet de mesurer le nuanceur là où personne ne peut regarder
    /// l'écran — la machine virtuelle de développement, au premier chef.
    public init?(largeur: Int, hauteur: Int, nuanceur: String,
                 journal: @escaping (String) -> Void) {
        self.journal = journal
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        guard let p = nuanceur.withCString({ source in
            erreur.withUnsafeMutableBufferPointer { tampon in
                spectre_rendu_creer_hors_ecran(Int32(largeur), Int32(hauteur),
                                               source, tampon.baseAddress)
            }
        }) else {
            journal(String(cString: erreur))
            return nil
        }
        pont = p
    }

    deinit { spectre_rendu_detruire(pont) }

    public var largeur: Int { Int(spectre_rendu_largeur(pont)) }
    public var hauteur: Int { Int(spectre_rendu_hauteur(pont)) }

    public var nomDeLaCarte: String {
        var nom = [CChar](repeating: 0, count: 128)
        nom.withUnsafeMutableBufferPointer {
            spectre_rendu_nom_de_la_carte(pont, $0.baseAddress, 128)
        }
        return String(cString: nom)
    }

    public func redimensionner(largeur: Int, hauteur: Int) {
        _ = spectre_rendu_redimensionner(pont,
                                         Int32(largeur), Int32(hauteur))
    }

    // MARK: Téléversement

    /// Envoie la matrice sur le GPU. Les dB sont convertis en demi-flottants : à ces
    /// niveaux le pas vaut 0,06 dB, très en dessous du visible, et la mémoire
    /// occupée est divisée par deux.
    public func upload(_ spectrogram: Spectrogram) {
        let lignes = spectrogram.binCount
        let colonnes = spectrogram.columnCount
        generation += 1
        guard lignes > 0, colonnes > 0 else {
            _ = spectre_rendu_televerser_tuiles(pont, 0, 0,
                                                Int32(Self.hauteurTuile), nil)
            self.colonnes = 0
            self.lignes = 0
            return
        }

        let total = colonnes * lignes
        var demi = [UInt16](repeating: 0, count: total)
        spectrogram.values.withUnsafeBufferPointer { source in
            demi.withUnsafeMutableBufferPointer { sortie in
                Vector.demiFlottants(source.baseAddress!, into: sortie.baseAddress!, count: total)
            }
        }

        let ok = demi.withUnsafeBufferPointer {
            spectre_rendu_televerser_tuiles(pont,
                                            Int32(lignes), Int32(colonnes),
                                            Int32(Self.hauteurTuile), $0.baseAddress)
        }
        guard ok != 0 else {
            journal("Matrice de \(colonnes) colonnes impossible à envoyer à la carte.")
            self.colonnes = 0
            self.lignes = 0
            return
        }
        self.colonnes = colonnes
        self.lignes = lignes
    }

    private func envoyerLaTableDesNotes() {
        let table = NotePalette.makeTable(saturation: display.noteSaturation,
                                          origin: origineDesTeintes)
        let ok = table.withUnsafeBytes { brut -> Int32 in
            spectre_rendu_televerser_palette(
                pont,
                Int32(NotePalette.steps), Int32(NotePalette.pitchClassCount),
                brut.baseAddress?.assumingMemoryBound(to: UInt8.self))
        }
        tableEnvoyee = ok != 0
        saturationDeLaTable = display.noteSaturation
        origineDeLaTable = origineDesTeintes
    }

    // MARK: Le dessin

    /// Remplit les uniformes et dessine. `echelle` est la densité de l'écran : tout
    /// le modèle raisonne en points, et c'est ici seulement qu'on passe aux pixels.
    public func dessiner(echelle: Double) {
        if display.colorMap == .notes,
           !tableEnvoyee || saturationDeLaTable != display.noteSaturation
            || origineDeLaTable != origineDesTeintes {
            envoyerLaTableDesNotes()
        }

        // La zone si elle est posée, la fenêtre sinon. C'est **cette taille-là** que
        // le nuanceur doit connaître : il s'en sert pour retourner l'axe vertical, et
        // celle de la fenêtre décalerait l'image de toute la hauteur qui ne lui
        // revient pas.
        let largeurPixels = zoneEnPoints.map { $0.largeur * echelle } ?? Double(largeur)
        let hauteurPixels = zoneEnPoints.map { $0.hauteur * echelle } ?? Double(hauteur)
        let colonnesParPixel = viewport.columnsPerPoint / echelle

        var u = SpectreUniformes()
        u.origineX = Float(viewport.startColumn)
        u.origineY = Float(viewport.bottomBin)
        u.parPixelX = Float(colonnesParPixel)
        u.parPixelY = Float(viewport.binsPerPoint / echelle)
        u.tailleVueX = Float(largeurPixels)
        u.tailleVueY = Float(hauteurPixels)
        u.colonnes = UInt32(colonnes)
        u.lignes = UInt32(lignes)
        u.hauteurTuile = UInt32(Self.hauteurTuile)
        // Assez d'échantillons pour ne pas rater d'attaque, pas assez pour coûter
        // cher : au-delà d'une trentaine, l'œil ne fait plus la différence.
        u.pas = UInt32(min(max(Int(colonnesParPixel.rounded(.up)), 1), 32))
        let carte = (display.colorMap == .notes && !tableEnvoyee) ? .gray : display.colorMap
        u.palette = UInt32(carte.rawValue)
        u.minDb = Float(display.floorDb)
        u.maxDb = Float(display.ceilingDb)
        u.gammaValeur = Float(display.gamma)
        u.penteParOctave = Float(display.tiltDbPerOctave)
        u.log2FminSur1k = Float(log2(layout.minFrequency / 1000))
        u.lignesParOctave = Float(layout.binsPerOctave)
        u.demiTonLigne0 = Float(Pitch.midi(from: layout.minFrequency,
                                           referenceA: display.referenceA) + demiTons)
        u.teteDeLecture = Float(teteDeLecture ?? -1)
        u.boucleDebut = Float(boucle?.lowerBound ?? 0)
        u.boucleFin = Float(boucle?.upperBound ?? -1)

        withUnsafePointer(to: &u) { spectre_rendu_dessiner(pont, $0) }
    }

    /// Vrai quand la fenêtre est cachée : la carte cesse alors de cadencer, et tout
    /// relevé de fluidité pris pendant ce temps compte des images que personne ne
    /// voit. Il faut le dire, sinon on lit dix mille images par seconde comme une
    /// bonne nouvelle.
    public private(set) var fenetreCachee = false

    public func presenter() {
        fenetreCachee = spectre_rendu_presenter(pont) == 2
    }

    /// Redemande à la carte si la fenêtre est cachée, **sans dessiner ni
    /// présenter**.
    ///
    /// C'est ce qui permet à la boucle de s'arrêter tout à fait quand personne ne
    /// regarde : une fenêtre réduite ou recouverte redevient visible sans qu'aucun
    /// message ne le dise, et sans cette question elle ne se rouvrirait jamais.
    /// Voir `SpectreDessin/Cadence.swift`.
    public func releverSiCachee() {
        fenetreCachee = spectre_rendu_cachee(pont) != 0
    }

    /// Attend que la carte réclame l'image suivante.
    ///
    /// On dort **avant** de dessiner plutôt qu'après avoir présenté : l'image
    /// montrée porte alors l'état le plus frais possible, et c'est ce qui la garde
    /// collée au doigt.
    public func attendreLImageSuivante() { spectre_rendu_attendre(pont) }

    /// Relit la dernière image, en RVB, ligne du haut en premier — le rangement du
    /// PPM, donc celui que `ImageCheck` compare.
    public func relire() -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: largeur * hauteur * 3)
        let ok = pixels.withUnsafeMutableBufferPointer {
            spectre_rendu_relire(pont, $0.baseAddress)
        }
        return ok != 0 ? pixels : nil
    }
}
