// Le nuanceur du spectrogramme, en GLSL 3.30 — traduction de la version MSL qui
// vit dans `Sources/SpectreMac/Renderer.swift`.
//
// Les deux doivent rester d'accord : ce sont deux écritures d'une même formule,
// et `Tools/RenderCheck` mesure la version Metal contre ce que la vue prévoit.
// La version processeur — `SpectreCore/SpectrogramImage` — applique la même
// formule une troisième fois, ce qui donne un arbitre commun aux deux.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE PIÈGE : L'AXE VERTICAL
//
// Metal donne au fragment une position dont l'origine est **en haut à gauche**,
// d'où le `viewSize.y - position.y` de la version MSL. OpenGL donne
// `gl_FragCoord` avec l'origine **en bas à gauche**, donc cette soustraction ne
// doit pas être reprise — la garder retourne l'image, graves en haut, et
// l'erreur est d'autant plus pénible qu'elle produit une image plausible.
//
// C'est la seule différence de fond entre les deux versions. Tout le reste est
// du vocabulaire : `texture2d_array<access::read>` devient `sampler2DArray` lu
// par `texelFetch`, `float3` devient `vec3`, `[[vertex_id]]` devient
// `gl_VertexID`.
// ─────────────────────────────────────────────────────────────────────────────

// ============================================================ ÉTAGE DE SOMMETS
#version 330 core

// Aucun tampon de sommets : trois sommets suffisent à couvrir l'écran, et un
// triangle unique plutôt que deux évite la couture diagonale où les deux se
// touchent.
void main() {
    vec2 pos[3] = vec2[3](vec2(-1.0, -3.0), vec2(-1.0, 1.0), vec2(3.0, 1.0));
    gl_Position = vec4(pos[gl_VertexID], 0.0, 1.0);
}

// ========================================================== ÉTAGE DE FRAGMENTS
#version 330 core

uniform sampler2DArray tiles;       // la matrice, découpée en tuiles
uniform sampler2D      noteColors;  // la table de la palette « notes »

uniform vec2  origin;
uniform vec2  perPixel;
uniform vec2  viewSize;
uniform int   columns;
uniform int   bins;
uniform int   tileRows;
uniform int   steps;
uniform int   colorMap;
uniform float minDb;
uniform float maxDb;
uniform float gammaValue;           // `gamma` est réservé dans certains pilotes
uniform float tiltPerOctave;
uniform float log2FminOver1k;
uniform float binsPerOctave;
uniform float semitoneAtBin0;

out vec4 fragColor;

vec3 palette(float t, int which) {
    if (which == 0) { return vec3(t); }

    vec3 c0, c1, c2, c3, c4, c5, c6;
    if (which == 1) {           // inferno
        c0 = vec3(0.00021894, 0.00165100, -0.01948090);
        c1 = vec3(0.10651342, 0.56395644, 3.93271239);
        c2 = vec3(11.6024931, -3.97285397, -15.9423941);
        c3 = vec3(-41.7039961, 17.4363989, 44.3541452);
        c4 = vec3(77.1629357, -33.4023589, -81.8073093);
        c5 = vec3(-71.3194282, 32.6260643, 73.2095199);
        c6 = vec3(25.1311262, -12.2426690, -23.0703250);
    } else if (which == 2) {    // magma
        c0 = vec3(-0.00213649, -0.00074966, -0.00538613);
        c1 = vec3(0.25166054, 0.67752324, 2.49402660);
        c2 = vec3(8.35371728, -3.57771951, 0.31446790);
        c3 = vec3(-27.6687331, 14.2647308, -13.6492132);
        c4 = vec3(52.1761398, -27.9436061, 12.9441694);
        c5 = vec3(-50.7685254, 29.0465828, 4.23415299);
        c6 = vec3(18.6557051, -11.4897735, -5.60196151);
    } else if (which == 3) {    // viridis
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
float readColumn(int column, int b0, int b1, float fr) {
    int slice = column / tileRows;
    int row   = column % tileRows;
    float a = texelFetch(tiles, ivec3(b0, row, slice), 0).r;
    float b = texelFetch(tiles, ivec3(b1, row, slice), 0).r;
    return mix(a, b, fr);
}

void main() {
    // `gl_FragCoord` est au centre du pixel, origine en bas à gauche — d'où
    // l'absence du retournement que fait la version Metal. Voir l'avertissement
    // en tête de fichier.
    float colCenter = origin.x + gl_FragCoord.x * perPixel.x;
    float binPos    = origin.y + gl_FragCoord.y * perPixel.y;

    float bf = binPos - 0.5;
    int i0 = int(floor(bf));
    float fr = bf - float(i0);
    int lastBin = bins - 1;
    int b0 = clamp(i0, 0, lastBin);
    int b1 = clamp(i0 + 1, 0, lastBin);
    int lastColumn = columns - 1;

    float db = -400.0;
    if (steps <= 1) {
        // Zoomé : interpolation entre les deux colonnes voisines, sinon l'image
        // devient un damier dès qu'une colonne dépasse le pixel.
        float cf = colCenter - 0.5;
        int c0 = int(floor(cf));
        float ft = cf - float(c0);
        if (c0 >= -1 && c0 <= lastColumn) {
            float a = readColumn(clamp(c0, 0, lastColumn), b0, b1, fr);
            float b = readColumn(clamp(c0 + 1, 0, lastColumn), b0, b1, fr);
            db = mix(a, b, ft);
        }
    } else {
        // Dézoomé : un pixel couvre plusieurs colonnes. On en prend le
        // **maximum**, pas la moyenne — sinon les attaques, brèves par nature,
        // s'effacent.
        float start = colCenter - 0.5 * perPixel.x;
        float pas = perPixel.x / float(steps);
        for (int k = 0; k < steps; ++k) {
            int c = int(floor(start + (float(k) + 0.5) * pas));
            if (c < 0 || c > lastColumn) { continue; }
            db = max(db, readColumn(c, b0, b1, fr));
        }
    }

    // Pente d'affichage, référencée à 1 kHz.
    float octave = log2FminOver1k + binPos / max(binsPerOctave, 1e-3);
    db += tiltPerOctave * octave;

    float t = clamp((db - minDb) / max(maxDb - minDb, 1e-3), 0.0, 1.0);
    t = pow(t, gammaValue);

    if (colorMap == 5) {
        float semitone = semitoneAtBin0 + binPos * 12.0 / max(binsPerOctave, 1e-3);
        int pitchClass = int(floor(semitone + 0.5));
        pitchClass = ((pitchClass % 12) + 12) % 12;
        int last = textureSize(noteColors, 0).x - 1;
        float ft = t * float(last);
        int t0 = clamp(int(floor(ft)), 0, last);
        int t1 = min(t0 + 1, last);
        vec3 ca = texelFetch(noteColors, ivec2(t0, pitchClass), 0).rgb;
        vec3 cb = texelFetch(noteColors, ivec2(t1, pitchClass), 0).rgb;
        fragColor = vec4(mix(ca, cb, ft - float(t0)), 1.0);
        return;
    }

    fragColor = vec4(palette(t, colorMap), 1.0);
}
