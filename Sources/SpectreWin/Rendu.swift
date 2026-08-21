import CPont
import Foundation
import SpectreCore
import SpectreDSP
import SpectreModele

// Le rendu du spectrogramme sous Windows.
//
// Le nuanceur est écrit ici, en toutes lettres, exactement comme la version MSL
// est écrite dans `Sources/SpectreMac/Renderer.swift` : le pilote le compile au
// démarrage, il n'y a donc pas de fichier à trouver ni à distribuer. La version
// GLSL, elle, vit dans `Resources/spectrogramme.glsl` — elle appartient au portage
// Linux, qui viendra après.
//
// Le vocabulaire COM de Direct3D reste dans `Sources/CPont` ; ce fichier ne
// voit qu'une dizaine de fonctions C.

// MARK: - Le nuanceur

let nuanceurSpectrogramme = """
// ─────────────────────────────────────────────────────────────────────────────
// LE PIÈGE : L'AXE VERTICAL — ET IL EST L'INVERSE DE CELUI DE LA VERSION GLSL
//
// `SV_Position` a son origine **en haut à gauche**, exactement comme la
// `[[position]]` de Metal. Le `viewSize.y - position.y` de la version MSL est
// donc **conservé ici**, alors que la version GLSL devait le retirer parce que
// `gl_FragCoord` compte depuis le bas.
//
// L'avertissement est écrit à l'envers de celui du fichier GLSL, et c'est
// volontaire : qui vient de lire l'autre fichier a en tête « OpenGL n'a pas
// besoin du retournement » et retirerait celui-ci par prudence. L'image resterait
// plausible — graves en haut, aigus en bas — et l'erreur se paierait longtemps.
//
// Le reste n'est que du vocabulaire : `texture2d_array<access::read>` devient
// `Texture2DArray` lue par `Load`, `mix` devient `lerp`, `[[vertex_id]]` devient
// `SV_VertexID`.
// ─────────────────────────────────────────────────────────────────────────────

// Le tampon de constantes se compte par blocs de seize octets, et la structure C
// qui le remplit — `SpectreUniformes`, dans `pont.h` — porte le remplissage qui
// l'y amène. Les deux doivent rester binairement identiques : un champ ajouté
// d'un seul côté décale tous les suivants, et ce qui sort alors est une image
// plausible plutôt qu'une erreur.
cbuffer Uniformes : register(b0) {
    float2 origine;
    float2 parPixel;
    float2 tailleVue;
    uint   colonnes;
    uint   lignes;
    uint   hauteurTuile;
    uint   pas;
    uint   palette;
    float  minDb;
    float  maxDb;
    float  gammaValeur;
    float  penteParOctave;
    float  log2FminSur1k;
    float  lignesParOctave;
    float  demiTonLigne0;
    // Colonne de la tête de lecture, et de la boucle. Une valeur négative les
    // éteint. Les tracer ici plutôt qu'en second passage évite un pipeline
    // entier pour trois traits verticaux.
    float  teteDeLecture;
    float  boucleDebut;
    float  boucleFin;
    float3 remplissage;
};

Texture2DArray<float> tuiles       : register(t0);
Texture2D<float4>     couleursNote : register(t1);

// Aucun tampon de sommets : trois sommets suffisent à couvrir l'écran, et un
// triangle unique plutôt que deux évite la couture diagonale où les deux se
// touchent.
float4 sommets(uint identifiant : SV_VertexID) : SV_Position {
    float2 coins[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    return float4(coins[identifiant], 0.0, 1.0);
}

float3 couleurDeRampe(float t, uint laquelle) {
    if (laquelle == 0u) { return float3(t, t, t); }

    float3 c0, c1, c2, c3, c4, c5, c6;
    if (laquelle == 1u) {           // inferno
        c0 = float3(0.00021894, 0.00165100, -0.01948090);
        c1 = float3(0.10651342, 0.56395644, 3.93271239);
        c2 = float3(11.6024931, -3.97285397, -15.9423941);
        c3 = float3(-41.7039961, 17.4363989, 44.3541452);
        c4 = float3(77.1629357, -33.4023589, -81.8073093);
        c5 = float3(-71.3194282, 32.6260643, 73.2095199);
        c6 = float3(25.1311262, -12.2426690, -23.0703250);
    } else if (laquelle == 2u) {    // magma
        c0 = float3(-0.00213649, -0.00074966, -0.00538613);
        c1 = float3(0.25166054, 0.67752324, 2.49402660);
        c2 = float3(8.35371728, -3.57771951, 0.31446790);
        c3 = float3(-27.6687331, 14.2647308, -13.6492132);
        c4 = float3(52.1761398, -27.9436061, 12.9441694);
        c5 = float3(-50.7685254, 29.0465828, 4.23415299);
        c6 = float3(18.6557051, -11.4897735, -5.60196151);
    } else if (laquelle == 3u) {    // viridis
        c0 = float3(0.27772733, 0.00540734, 0.33409981);
        c1 = float3(0.10509304, 1.40461353, 1.38459016);
        c2 = float3(-0.33086183, 0.21484756, 0.09509516);
        c3 = float3(-4.63423050, -5.79910097, -19.3324410);
        c4 = float3(6.22826994, 14.1799334, 56.6905526);
        c5 = float3(4.77638500, -13.7451454, -65.3530326);
        c6 = float3(-5.43545586, 4.64585261, 26.3124352);
    } else {                        // turbo
        c0 = float3(0.11408901, 0.06288341, 0.22483372);
        c1 = float3(6.71641950, 3.18228675, 7.57158159);
        c2 = float3(-66.0940236, -4.92798270, -10.0943937);
        c3 = float3(228.766079, 25.0498670, -91.5410533);
        c4 = float3(-334.835157, -69.3174971, 288.585885);
        c5 = float3(218.763722, 67.5215057, -305.204577);
        c6 = float3(-52.8890348, -21.5452736, 110.517465);
    }
    float3 v = c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6)))));
    return clamp(v, 0.0, 1.0);
}

// Lecture d'une colonne, interpolée entre deux lignes voisines.
float lireColonne(int colonne, int l0, int l1, float fraction) {
    int tranche = colonne / int(hauteurTuile);
    int rangee  = colonne % int(hauteurTuile);
    float a = tuiles.Load(int4(l0, rangee, tranche, 0));
    float b = tuiles.Load(int4(l1, rangee, tranche, 0));
    return lerp(a, b, fraction);
}

// La tête de lecture, et le passage mis en boucle.
//
// La boucle est **assombrie au-dehors** plutôt qu'éclaircie au-dedans : ce qu'on
// regarde reste rendu tel qu'il est, et c'est le reste qui s'efface.
float3 marques(float3 couleur, float colonne) {
    if (boucleFin > boucleDebut && (colonne < boucleDebut || colonne > boucleFin)) {
        couleur *= 0.45;
    }
    float largeur = max(parPixel.x, 1e-6);
    if (boucleFin > boucleDebut) {
        if (abs(colonne - boucleDebut) < largeur || abs(colonne - boucleFin) < largeur) {
            couleur = lerp(couleur, float3(0.9, 0.7, 0.2), 0.85);
        }
    }
    if (teteDeLecture >= 0.0 && abs(colonne - teteDeLecture) < largeur) {
        couleur = lerp(couleur, float3(1.0, 1.0, 1.0), 0.9);
    }
    return couleur;
}

float4 fragments(float4 position : SV_Position) : SV_Target {
    // `SV_Position` est au centre du pixel, origine **en haut à gauche** — d'où
    // le retournement, qui est celui de la version Metal et non celui de la
    // version GLSL. Voir l'avertissement en tête de nuanceur.
    float colonneCentre = origine.x + position.x * parPixel.x;
    float ligneCentre   = origine.y + (tailleVue.y - position.y) * parPixel.y;

    float lf = ligneCentre - 0.5;
    int i0 = int(floor(lf));
    float fraction = lf - float(i0);
    int derniereLigne = int(lignes) - 1;
    int l0 = clamp(i0, 0, derniereLigne);
    int l1 = clamp(i0 + 1, 0, derniereLigne);
    int derniereColonne = int(colonnes) - 1;

    float db = -400.0;
    if (pas <= 1u) {
        // Zoomé : interpolation entre les deux colonnes voisines, sinon l'image
        // devient un damier dès qu'une colonne dépasse le pixel.
        float cf = colonneCentre - 0.5;
        int c0 = int(floor(cf));
        float ft = cf - float(c0);
        if (c0 >= -1 && c0 <= derniereColonne) {
            float a = lireColonne(clamp(c0, 0, derniereColonne), l0, l1, fraction);
            float b = lireColonne(clamp(c0 + 1, 0, derniereColonne), l0, l1, fraction);
            db = lerp(a, b, ft);
        }
    } else {
        // Dézoomé : un pixel couvre plusieurs colonnes. On en prend le
        // **maximum**, pas la moyenne — sinon les attaques, brèves par nature,
        // s'effacent.
        float debut = colonneCentre - 0.5 * parPixel.x;
        float saut = parPixel.x / float(pas);
        for (uint k = 0u; k < pas; ++k) {
            int c = int(floor(debut + (float(k) + 0.5) * saut));
            if (c < 0 || c > derniereColonne) { continue; }
            db = max(db, lireColonne(c, l0, l1, fraction));
        }
    }

    // Pente d'affichage, référencée à 1 kHz.
    float octave = log2FminSur1k + ligneCentre / max(lignesParOctave, 1e-3);
    db += penteParOctave * octave;

    float t = clamp((db - minDb) / max(maxDb - minDb, 1e-3), 0.0, 1.0);
    t = pow(t, gammaValeur);

    if (palette == 5u) {
        float demiTon = demiTonLigne0 + ligneCentre * 12.0 / max(lignesParOctave, 1e-3);
        int classe = int(floor(demiTon + 0.5));
        classe = ((classe % 12) + 12) % 12;
        uint largeurTable, hauteurTable, niveaux;
        couleursNote.GetDimensions(0, largeurTable, hauteurTable, niveaux);
        int dernier = int(largeurTable) - 1;
        float ft = t * float(dernier);
        int t0 = clamp(int(floor(ft)), 0, dernier);
        int t1 = min(t0 + 1, dernier);
        float3 ca = couleursNote.Load(int3(t0, classe, 0)).rgb;
        float3 cb = couleursNote.Load(int3(t1, classe, 0)).rgb;
        return float4(marques(lerp(ca, cb, ft - float(t0)), colonneCentre), 1.0);
    }

    return float4(marques(couleurDeRampe(t, palette), colonneCentre), 1.0);
}
"""

// MARK: - Le rendu

/// Rendu d'une fenêtre du spectrogramme, en Direct3D 11.
///
/// La matrice ne défile pas : elle est envoyée une fois pour toutes sur le GPU et
/// c'est la *fenêtre* qui bouge. Comme une texture plafonne en hauteur et qu'une
/// heure de musique fait des centaines de milliers de colonnes, elle est découpée
/// en tuiles empilées dans un `Texture2DArray` — le nuanceur retrouve la sienne
/// par une division, il n'y a donc toujours qu'un seul appel de dessin.
public final class RenduD3D11: RenduSpectrogramme {

    /// Hauteur d'une tuile, en colonnes. Direct3D 11 garantit 2 048 tranches et
    /// 16 384 pixels de côté ; 4 096 colonnes par tuile laisse de la marge des deux
    /// côtés et fait le même découpage que la version Metal.
    private static let hauteurTuile = 4096

    private let pont: OpaquePointer

    public private(set) var colonnes = 0
    public private(set) var lignes = 0
    public private(set) var generation = 0

    /// Géométrie de l'axe des fréquences, nécessaire aux couleurs de notes.
    public var layout = BinLayout()

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

    /// Le rendu attaché à une fenêtre.
    public init?(fenetre: UnsafeMutableRawPointer) {
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        guard let p = nuanceurSpectrogramme.withCString({ source in
            erreur.withUnsafeMutableBufferPointer { tampon in
                spectre_rendu_creer(fenetre, source, tampon.baseAddress)
            }
        }) else {
            Journal.erreur(String(cString: erreur))
            return nil
        }
        pont = p
    }

    /// Le rendu sans fenêtre, vers une cible qu'on relit.
    ///
    /// C'est ce qui permet de mesurer le nuanceur là où personne ne peut regarder
    /// l'écran — la machine virtuelle de développement, au premier chef.
    public init?(largeur: Int, hauteur: Int) {
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        guard let p = nuanceurSpectrogramme.withCString({ source in
            erreur.withUnsafeMutableBufferPointer { tampon in
                spectre_rendu_creer_hors_ecran(Int32(largeur), Int32(hauteur),
                                               source, tampon.baseAddress)
            }
        }) else {
            Journal.erreur(String(cString: erreur))
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
            Journal.erreur("Matrice de \(colonnes) colonnes impossible à envoyer à la carte.")
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

        let largeurPixels = Double(largeur)
        let hauteurPixels = Double(hauteur)
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
                                           referenceA: display.referenceA))
        u.teteDeLecture = Float(teteDeLecture ?? -1)
        u.boucleDebut = Float(boucle?.lowerBound ?? 0)
        u.boucleFin = Float(boucle?.upperBound ?? -1)

        withUnsafePointer(to: &u) { spectre_rendu_dessiner(pont, $0) }
    }

    public func presenter() { _ = spectre_rendu_presenter(pont) }

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
