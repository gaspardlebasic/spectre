import CPont
import Foundation
import SpectreToile

// MARK: - Le nuanceur

/// Le nuanceur du spectrogramme, en GLSL 3.30.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// TROIS ÉCRITURES D'UNE MÊME FORMULE
///
/// Celle-ci, le HLSL de `SpectreWin/Rendu.swift`, et le MSL de
/// `SpectreMac/Renderer.swift`. Elles doivent rester d'accord, et l'arbitre commun
/// est `SpectreCore/SpectrogramImage`, qui applique la même formule sur le
/// processeur — c'est ce que mesurent `RenduCheck` et son jumeau.
///
/// Le nuanceur vit **en toutes lettres ici**, comme les deux autres vivent dans
/// leur fichier : le pilote le compile au démarrage, il n'y a donc pas de fichier à
/// trouver ni à distribuer. `Resources/spectrogramme.glsl` portait cette version-là
/// en attendant Linux ; Linux est arrivé, et l'a prise.
///
/// UN SEUL TEXTE, DEUX ÉTAGES
///
/// OpenGL compile chaque étage séparément, là où HLSL et MSL prennent un texte à
/// deux points d'entrée. Plutôt que deux chaînes qui dériveraient l'une de l'autre,
/// c'est **le même texte compilé deux fois**, avec `SPECTRE_SOMMETS` ou
/// `SPECTRE_FRAGMENTS` posé devant par `gl.c`.
let nuanceurSpectrogramme = """
#ifdef SPECTRE_SOMMETS

void main() {
    vec2 pos[3] = vec2[3](vec2(-1.0, -3.0), vec2(-1.0, 1.0), vec2(3.0, 1.0));
    gl_Position = vec4(pos[gl_VertexID], 0.0, 1.0);
}

#endif

#ifdef SPECTRE_FRAGMENTS

uniform sampler2DArray tuiles;       // la matrice, découpée en tuiles
uniform sampler2D      couleursNote;  // la table de la palette « notes »

uniform vec2  origine;
uniform vec2  parPixel;
uniform vec2  tailleVue;
uniform int   colonnes;
uniform int   lignes;
uniform int   hauteurTuile;
uniform int   pas;
uniform int   palette;
uniform float minDb;
uniform float maxDb;
uniform float gammaValeur;           // `gamma` est réservé dans certains pilotes
uniform float penteParOctave;
uniform float log2FminSur1k;
uniform float lignesParOctave;
uniform float demiTonLigne0;
// Colonne de la tête de lecture, et de la boucle. Une valeur négative les
// éteint. Les tracer ici plutôt qu'en second passage évite un pipeline entier
// pour trois traits verticaux.
uniform float teteDeLecture;
uniform float boucleDebut;
uniform float boucleFin;

out vec4 fragColor;

// ── L'ORIGINE EN HAUT, COMME METAL ET DIRECT3D ──────────────────────────────
//
// Par défaut `gl_FragCoord` compte depuis le **bas** de la cible, là où
// `SV_Position` et la `[[position]]` de Metal comptent depuis le haut. Cette
// déclaration — dans GLSL depuis la 1.50, donc acquise en 3.30 — le fait compter
// depuis le haut lui aussi.
//
// Elle n'est pas un confort. Le spectrogramme n'occupe que la bande haute de la
// fenêtre, la batterie prenant celle du bas : la fenêtre de vue est donc posée en
// haut, et OpenGL la place par son coin bas-gauche. Sans cette déclaration, il
// faudrait retrancher ici l'ordonnée de ce coin, c'est-à-dire porter dans le
// nuanceur une notion que les deux autres n'ont pas.
//
// Ce qu'elle rend en échange : **les trois nuanceurs redeviennent la même
// formule**, au vocabulaire près. La version qui précédait celle-ci retirait le
// retournement, avec un long avertissement pour dire pourquoi ; l'avertissement
// n'a plus lieu d'être, et le retournement est revenu.
layout(origin_upper_left) in vec4 gl_FragCoord;

vec3 couleurDeRampe(float t, int laquelle) {
    if (laquelle == 0) { return vec3(t); }

    vec3 c0, c1, c2, c3, c4, c5, c6;
    if (laquelle == 1) {           // inferno
        c0 = vec3(0.00021894, 0.00165100, -0.01948090);
        c1 = vec3(0.10651342, 0.56395644, 3.93271239);
        c2 = vec3(11.6024931, -3.97285397, -15.9423941);
        c3 = vec3(-41.7039961, 17.4363989, 44.3541452);
        c4 = vec3(77.1629357, -33.4023589, -81.8073093);
        c5 = vec3(-71.3194282, 32.6260643, 73.2095199);
        c6 = vec3(25.1311262, -12.2426690, -23.0703250);
    } else if (laquelle == 2) {    // magma
        c0 = vec3(-0.00213649, -0.00074966, -0.00538613);
        c1 = vec3(0.25166054, 0.67752324, 2.49402660);
        c2 = vec3(8.35371728, -3.57771951, 0.31446790);
        c3 = vec3(-27.6687331, 14.2647308, -13.6492132);
        c4 = vec3(52.1761398, -27.9436061, 12.9441694);
        c5 = vec3(-50.7685254, 29.0465828, 4.23415299);
        c6 = vec3(18.6557051, -11.4897735, -5.60196151);
    } else if (laquelle == 3) {    // viridis
        c0 = vec3(0.27772733, 0.00540734, 0.33409981);
        c1 = vec3(0.10509304, 1.40461353, 1.38459016);
        c2 = vec3(-0.33086183, 0.21484756, 0.09509516);
        c3 = vec3(-4.63423050, -5.79910097, -19.3324410);
        c4 = vec3(6.22826994, 14.1799334, 56.6905526);
        c5 = vec3(4.77638500, -13.7451454, -65.3530326);
        c6 = vec3(-5.43545586, 4.64585261, 26.3124352);
    } else {                    // turbo
        c0 = vec3(0.11408901, 0.06288341, 0.22483372);
        c1 = vec3(6.71641950, 3.18228675, 7.57158159);
        c2 = vec3(-66.0940236, -4.92798270, -10.0943937);
        c3 = vec3(228.766079, 25.0498670, -91.5410533);
        c4 = vec3(-334.835157, -69.3174971, 288.585885);
        c5 = vec3(218.763722, 67.5215057, -305.204577);
        c6 = vec3(-52.8890348, -21.5452736, 110.517465);
    }
    vec3 v = c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6)))));
    return clamp(v, 0.0, 1.0);
}

// Lecture d'une colonne, interpolée entre deux lignes voisines.
float lireColonne(int colonne, int l0, int l1, float fraction) {
    int tranche = colonne / hauteurTuile;
    int rangee   = colonne % hauteurTuile;
    float a = texelFetch(tuiles, ivec3(l0, rangee, tranche), 0).r;
    float b = texelFetch(tuiles, ivec3(l1, rangee, tranche), 0).r;
    return mix(a, b, fraction);
}

// La tête de lecture, et le passage mis en boucle.
//
// La boucle est **assombrie au-dehors** plutôt qu'éclaircie au-dedans : ce qu'on
// regarde reste rendu tel qu'il est, et c'est le reste qui s'efface.
vec3 marques(vec3 couleur, float colonne) {
    if (boucleFin > boucleDebut && (colonne < boucleDebut || colonne > boucleFin)) {
        couleur *= 0.45;
    }
    float largeur = max(parPixel.x, 1e-6);
    if (boucleFin > boucleDebut) {
        if (abs(colonne - boucleDebut) < largeur || abs(colonne - boucleFin) < largeur) {
            couleur = mix(couleur, vec3(0.9, 0.7, 0.2), 0.85);
        }
    }
    if (teteDeLecture >= 0.0 && abs(colonne - teteDeLecture) < largeur) {
        couleur = mix(couleur, vec3(1.0), 0.9);
    }
    return couleur;
}

void main() {
    // `gl_FragCoord` est au centre du pixel, origine **en haut à gauche** — voir
    // la déclaration plus haut. Le retournement est donc celui du HLSL et du MSL.
    float colonneCentre = origine.x + gl_FragCoord.x * parPixel.x;
    float ligneCentre   = origine.y + (tailleVue.y - gl_FragCoord.y) * parPixel.y;

    float bf = ligneCentre - 0.5;
    int i0 = int(floor(bf));
    float fraction = bf - float(i0);
    int derniereLigne = lignes - 1;
    int l0 = clamp(i0, 0, derniereLigne);
    int l1 = clamp(i0 + 1, 0, derniereLigne);
    int derniereColonne = colonnes - 1;

    float db = -400.0;
    if (pas <= 1) {
        // Zoomé : interpolation entre les deux colonnes voisines, sinon l'image
        // devient un damier dès qu'une colonne dépasse le pixel.
        float cf = colonneCentre - 0.5;
        int c0 = int(floor(cf));
        float ft = cf - float(c0);
        if (c0 >= -1 && c0 <= derniereColonne) {
            float a = lireColonne(clamp(c0, 0, derniereColonne), l0, l1, fraction);
            float b = lireColonne(clamp(c0 + 1, 0, derniereColonne), l0, l1, fraction);
            db = mix(a, b, ft);
        }
    } else {
        // Dézoomé : un pixel couvre plusieurs colonnes. On en prend le
        // **maximum**, pas la moyenne — sinon les attaques, brèves par nature,
        // s'effacent.
        float debut = colonneCentre - 0.5 * parPixel.x;
        float saut = parPixel.x / float(pas);
        for (int k = 0; k < pas; ++k) {
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

    if (palette == 5) {
        float demiTon = demiTonLigne0 + ligneCentre * 12.0 / max(lignesParOctave, 1e-3);
        int classe = int(floor(demiTon + 0.5));
        classe = ((classe % 12) + 12) % 12;
        int last = textureSize(couleursNote, 0).x - 1;
        float ft = t * float(last);
        int t0 = clamp(int(floor(ft)), 0, last);
        int t1 = min(t0 + 1, last);
        vec3 ca = texelFetch(couleursNote, ivec2(t0, classe), 0).rgb;
        vec3 cb = texelFetch(couleursNote, ivec2(t1, classe), 0).rgb;
        fragColor = vec4(marques(mix(ca, cb, ft - float(t0)), colonneCentre), 1.0);
        return;
    }

    vec3 couleur = couleurDeRampe(t, palette);
    fragColor = vec4(marques(couleur, colonneCentre), 1.0);
}

#endif
"""


// MARK: - Le rendu, vu de Linux

// La classe est dans `SpectreToile`, où Windows la partage : elle ne fait que
// piloter les treize fonctions du pont, dont les deux dos exportent les mêmes noms.
// Ce qui reste ici est ce qui est vraiment de Linux — le nuanceur ci-dessus, et le
// journal où va ce qui rate.
public typealias RenduGL = RenduSpectre

extension RenduSpectre {
    /// Le rendu attaché à une fenêtre SDL, muni de son nuanceur GLSL.
    ///
    /// C'est le pont qui crée le contexte OpenGL sur cette fenêtre : sans cela il ne
    /// pourrait pas échanger les tampons, et le contrat cesserait d'être celui que
    /// Windows remplit.
    public convenience init?(fenetreSDL: UnsafeMutableRawPointer) {
        self.init(fenetre: fenetreSDL, nuanceur: nuanceurSpectrogramme,
                  journal: Journal.erreur)
    }

    /// Le rendu sans fenêtre, vers une cible qu'on relit — ce par quoi le nuanceur
    /// se mesure là où personne ne peut regarder l'écran.
    public convenience init?(largeur: Int, hauteur: Int) {
        self.init(largeur: largeur, hauteur: hauteur,
                  nuanceur: nuanceurSpectrogramme, journal: Journal.erreur)
    }
}
