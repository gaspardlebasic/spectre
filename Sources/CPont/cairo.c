// Ce qui se dessine par-dessus le spectrogramme, sous Linux — le jumeau de
// `direct2d.cpp`.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE MÊME CONTRAT, QUINZE FONCTIONS
//
// Ce fichier exporte exactement ce qu'exporte `direct2d.cpp`, avec les mêmes noms
// et les mêmes signatures. `Pinceau`, dans `SpectreToile`, ne sait pas laquelle des
// deux il appelle — et c'est ce qui permet à la frise, au panneau de réglages, à la
// batterie, à la barre et aux commandes d'être écrits une seule fois.
//
// Toutes les coordonnées et toutes les tailles arrivent en **points**, comme le
// modèle les compte. `cairo_scale` est le seul endroit où l'on passe aux pixels.
//
// POURQUOI CAIRO ET PANGO, ET PAS FREETYPE
//
// FreeType donne des glyphes. Il ne donne ni la composition d'une ligne, ni le
// choix d'une police de repli quand le caractère manque, ni la mesure — dont
// `largeur(_:taille:)` a besoin pour placer ce qui suit. Il aurait fallu écrire
// par-dessus lui une mise en page de texte et un moteur vectoriel, c'est-à-dire
// réécrire Pango et Cairo, en moins bien, pour cinq langues dont le polonais et
// l'allemand. Les deux sont sur toutes les distributions.
//
// CE QUE ÇA COÛTE, ET OÙ ÇA SE PAIERA
//
// Cairo dessine sur le **processeur**. L'image de la surimpression est donc
// composée dans une surface ARGB, téléversée en texture, et fondue par-dessus le
// spectrogramme — qui, lui, reste sur la carte et ne repasse jamais par là.
// Direct2D, à l'inverse, écrit directement dans le tampon de la chaîne d'échange.
//
// À la taille d'une fenêtre, cela fait quelques mégaoctets par image. C'est le
// premier suspect si la fluidité manque, et c'est l'étape 6 qui le dira. Le
// remède, le jour venu, est de ne téléverser que ce qui a changé — mais mesurer
// d'abord.
// ─────────────────────────────────────────────────────────────────────────────

#include <epoxy/gl.h>

#include <cairo/cairo.h>
#include <pango/pangocairo.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "interne.h"

// ─────────────────────────────────────────────────────────── Les couleurs

static void poserLaCouleur(cairo_t *cr, uint32_t rvba) {
    cairo_set_source_rgba(cr,
                          ((rvba >> 24) & 0xFF) / 255.0,
                          ((rvba >> 16) & 0xFF) / 255.0,
                          ((rvba >> 8) & 0xFF) / 255.0,
                          (rvba & 0xFF) / 255.0);
}

// ─────────────────────────────────────────────────────────── La composition

// Le nuanceur qui pose l'image de la surimpression sur celle du spectrogramme.
// Trois sommets, une texture, rien d'autre : c'est le seul dessin que ce fichier
// confie à la carte.
static const char *nuanceurComposition =
    "#version 330 core\n"
    "#ifdef SOMMETS\n"
    "out vec2 coord;\n"
    "void main() {\n"
    "    vec2 pos[3] = vec2[3](vec2(-1.0, -3.0), vec2(-1.0, 1.0), vec2(3.0, 1.0));\n"
    "    gl_Position = vec4(pos[gl_VertexID], 0.0, 1.0);\n"
    "    coord = (pos[gl_VertexID] + 1.0) * 0.5;\n"
    "}\n"
    "#endif\n"
    "#ifdef FRAGMENTS\n"
    "in vec2 coord;\n"
    "uniform sampler2D surimpression;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    // La surface de Cairo compte ses rangées depuis le haut, la texture depuis le
    // bas : c'est ici que les deux se rejoignent, et nulle part ailleurs.
    "    fragColor = texture(surimpression, vec2(coord.x, 1.0 - coord.y));\n"
    "}\n"
    "#endif\n";

static GLuint compilerEtage(GLenum etage, const char *macro) {
    const char *definition = (etage == GL_VERTEX_SHADER)
        ? "#define SOMMETS 1\n" : "#define FRAGMENTS 1\n";
    (void)macro;
    // `#version` doit rester la première ligne : la définition se glisse juste
    // après, et le préprocesseur de GLSL l'accepte là.
    char *source = malloc(strlen(nuanceurComposition) + 64);
    if (!source) { return 0; }
    const char *apresVersion = strchr(nuanceurComposition, '\n') + 1;
    size_t longueurVersion = (size_t)(apresVersion - nuanceurComposition);
    memcpy(source, nuanceurComposition, longueurVersion);
    source[longueurVersion] = 0;
    strcat(source, definition);
    strcat(source, apresVersion);

    GLuint n = glCreateShader(etage);
    glShaderSource(n, 1, (const char *const *)&source, NULL);
    glCompileShader(n);
    free(source);
    GLint ok = 0;
    glGetShaderiv(n, GL_COMPILE_STATUS, &ok);
    if (!ok) { glDeleteShader(n); return 0; }
    return n;
}

static int creerLaComposition(SpectreRendu *r) {
    GLuint s = compilerEtage(GL_VERTEX_SHADER, NULL);
    if (!s) { return 0; }
    GLuint f = compilerEtage(GL_FRAGMENT_SHADER, NULL);
    if (!f) { glDeleteShader(s); return 0; }
    r->programmeComposition = glCreateProgram();
    glAttachShader(r->programmeComposition, s);
    glAttachShader(r->programmeComposition, f);
    glLinkProgram(r->programmeComposition);
    glDeleteShader(s);
    glDeleteShader(f);
    GLint ok = 0;
    glGetProgramiv(r->programmeComposition, GL_LINK_STATUS, &ok);
    if (!ok) {
        glDeleteProgram(r->programmeComposition);
        r->programmeComposition = 0;
        return 0;
    }
    r->u_composition = glGetUniformLocation(r->programmeComposition, "surimpression");
    glGenVertexArrays(1, &r->tableauComposition);
    glGenTextures(1, &r->texteTexture);
    return 1;
}

// ─────────────────────────────────────────────────────────── La surface

static void lacherLaSurface(SpectreRendu *r) {
    if (r->miseEnPage) { g_object_unref(r->miseEnPage); r->miseEnPage = NULL; }
    if (r->pinceau) { cairo_destroy(r->pinceau); r->pinceau = NULL; }
    if (r->surface) { cairo_surface_destroy(r->surface); r->surface = NULL; }
}

/// Refait la surface à la taille du tampon, si elle a changé.
///
/// La fenêtre se redimensionne, et une surface plus petite que le tampon laisserait
/// une bande non dessinée sur deux côtés — sans que rien ne se plaigne.
static int accorderLaSurface(SpectreRendu *r) {
    if (r->surface && r->surfaceLargeur == r->largeur
        && r->surfaceHauteur == r->hauteur) {
        return 1;
    }
    lacherLaSurface(r);
    if (r->largeur <= 0 || r->hauteur <= 0) { return 0; }

    r->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, r->largeur, r->hauteur);
    if (cairo_surface_status(r->surface) != CAIRO_STATUS_SUCCESS) { return 0; }
    r->pinceau = cairo_create(r->surface);
    if (cairo_status(r->pinceau) != CAIRO_STATUS_SUCCESS) { return 0; }

    r->miseEnPage = pango_cairo_create_layout(r->pinceau);
    if (!r->miseEnPage) { return 0; }

    r->surfaceLargeur = r->largeur;
    r->surfaceHauteur = r->hauteur;
    return 1;
}

int spectre_surimpression_preparer(SpectreRendu *r, char *erreur) {
    if (!r) { return 0; }
    if (!creerLaComposition(r)) {
        if (erreur) {
            snprintf(erreur, SPECTRE_ERREUR_MAX,
                     "Le nuanceur de composition n'a pas pu etre cree.");
        }
        return 0;
    }
    r->echelle = 1;
    if (!accorderLaSurface(r)) {
        if (erreur) {
            snprintf(erreur, SPECTRE_ERREUR_MAX,
                     "La surface Cairo n'a pas pu etre creee.");
        }
        return 0;
    }
    return 1;
}

void spectre_surimpression_detruire(SpectreRendu *r) {
    if (!r) { return; }
    lacherLaSurface(r);
    if (r->texteTexture) { glDeleteTextures(1, &r->texteTexture); r->texteTexture = 0; }
    if (r->tableauComposition) {
        glDeleteVertexArrays(1, &r->tableauComposition);
        r->tableauComposition = 0;
    }
    if (r->programmeComposition) {
        glDeleteProgram(r->programmeComposition);
        r->programmeComposition = 0;
    }
}

void spectre_surimpression_echelle(SpectreRendu *r, float echelle) {
    if (r) { r->echelle = echelle > 0 ? echelle : 1; }
}

void spectre_surimpression_debuter(SpectreRendu *r) {
    if (!r || r->dessinEnCours) { return; }
    if (!accorderLaSurface(r)) { return; }

    // Tout effacer en transparent : ce qui n'est pas redessiné cette image-ci doit
    // disparaître, et non rester de l'image d'avant.
    cairo_save(r->pinceau);
    cairo_set_operator(r->pinceau, CAIRO_OPERATOR_CLEAR);
    cairo_paint(r->pinceau);
    cairo_restore(r->pinceau);

    cairo_identity_matrix(r->pinceau);
    // Le seul endroit de la surimpression où l'on passe des points aux pixels.
    cairo_scale(r->pinceau, r->echelle, r->echelle);
    r->dessinEnCours = 1;
    r->decoupes = 0;
}

void spectre_surimpression_finir(SpectreRendu *r) {
    if (!r || !r->dessinEnCours) { return; }
    // Une découpe oubliée laisserait le reste du dessin enfermé dedans à l'image
    // suivante. On dépile ici ce qui traîne plutôt que de faire dépendre l'image
    // d'un appel apparié quelque part dans le dessin — même règle que sous Windows,
    // où l'oubli faisait disparaître l'image entière.
    while (r->decoupes > 0) { spectre_surimpression_recoller(r); }
    r->dessinEnCours = 0;

    cairo_surface_flush(r->surface);
    const unsigned char *octets = cairo_image_surface_get_data(r->surface);
    if (!octets || !r->programmeComposition) { return; }

    glBindTexture(GL_TEXTURE_2D, r->texteTexture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    // Cairo range ses pixels en ARGB32 **dans l'ordre du processeur**, ce qui donne
    // BGRA en mémoire sur une machine petit-boutienne — d'où `GL_BGRA`. Et ils sont
    // **prémultipliés**, d'où le mélange en `ONE, ONE_MINUS_SRC_ALPHA` plus bas.
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, r->surfaceLargeur, r->surfaceHauteur, 0,
                 GL_BGRA, GL_UNSIGNED_BYTE, octets);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);

    // Sur toute la cible, et non sur la zone du spectrogramme : la ligne de batterie
    // et la barre d'état sont dessinées **hors** de cette zone, et c'est tout
    // l'intérêt.
    glViewport(0, 0, r->largeur, r->hauteur);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(r->programmeComposition);
    glBindVertexArray(r->tableauComposition);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, r->texteTexture);
    glUniform1i(r->u_composition, 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
    glDisable(GL_BLEND);
}

// ─────────────────────────────────────────────────────────── Les traits

void spectre_surimpression_rectangle(SpectreRendu *r, float x, float y,
                                     float largeur, float hauteur, uint32_t rvba) {
    if (!r || !r->dessinEnCours || largeur <= 0 || hauteur <= 0) { return; }
    poserLaCouleur(r->pinceau, rvba);
    cairo_rectangle(r->pinceau, x, y, largeur, hauteur);
    cairo_fill(r->pinceau);
}

void spectre_surimpression_ligne(SpectreRendu *r, float x0, float y0,
                                 float x1, float y1, uint32_t rvba,
                                 float epaisseur, int pointille) {
    if (!r || !r->dessinEnCours) { return; }
    poserLaCouleur(r->pinceau, rvba);
    cairo_set_line_width(r->pinceau, epaisseur);
    if (pointille) {
        // Direct2D compte ses tirets en multiples de l'épaisseur du trait ; Cairo les
        // compte en unités du dessin. Le motif { 2, 3 } de là-bas s'écrit donc ainsi.
        double motif[2] = { 2.0 * epaisseur, 3.0 * epaisseur };
        cairo_set_dash(r->pinceau, motif, 2, 0);
    } else {
        cairo_set_dash(r->pinceau, NULL, 0, 0);
    }
    cairo_move_to(r->pinceau, x0, y0);
    cairo_line_to(r->pinceau, x1, y1);
    cairo_stroke(r->pinceau);
    cairo_set_dash(r->pinceau, NULL, 0, 0);
}

void spectre_surimpression_cercle(SpectreRendu *r, float x, float y, float rayon,
                                  uint32_t rvba, float epaisseur) {
    if (!r || !r->dessinEnCours || rayon <= 0) { return; }
    poserLaCouleur(r->pinceau, rvba);
    cairo_set_line_width(r->pinceau, epaisseur);
    cairo_new_path(r->pinceau);
    cairo_arc(r->pinceau, x, y, rayon, 0, 2 * G_PI);
    cairo_stroke(r->pinceau);
}

void spectre_surimpression_aire(SpectreRendu *r, const float *points,
                                int nombre, uint32_t rvba) {
    if (!r || !r->dessinEnCours || !points || nombre < 3) { return; }
    poserLaCouleur(r->pinceau, rvba);
    cairo_new_path(r->pinceau);
    cairo_move_to(r->pinceau, points[0], points[1]);
    for (int i = 1; i < nombre; ++i) {
        cairo_line_to(r->pinceau, points[2 * i], points[2 * i + 1]);
    }
    cairo_close_path(r->pinceau);
    cairo_fill(r->pinceau);
}

void spectre_surimpression_arrondi(SpectreRendu *r, float x, float y,
                                   float largeur, float hauteur, float rayon,
                                   uint32_t rvba, float epaisseur) {
    if (!r || !r->dessinEnCours || largeur <= 0 || hauteur <= 0) { return; }
    double limite = (largeur < hauteur ? largeur : hauteur) / 2.0;
    double rr = rayon < 0 ? 0 : (rayon > limite ? limite : rayon);

    // Cairo n'a pas de rectangle arrondi : quatre arcs et trois lignes le font, et
    // `cairo_arc` referme le chemin tout seul d'un arc au suivant.
    cairo_new_path(r->pinceau);
    cairo_arc(r->pinceau, x + largeur - rr, y + rr, rr, -G_PI / 2, 0);
    cairo_arc(r->pinceau, x + largeur - rr, y + hauteur - rr, rr, 0, G_PI / 2);
    cairo_arc(r->pinceau, x + rr, y + hauteur - rr, rr, G_PI / 2, G_PI);
    cairo_arc(r->pinceau, x + rr, y + rr, rr, G_PI, 3 * G_PI / 2);
    cairo_close_path(r->pinceau);

    poserLaCouleur(r->pinceau, rvba);
    if (epaisseur > 0) {
        cairo_set_line_width(r->pinceau, epaisseur);
        cairo_stroke(r->pinceau);
    } else {
        cairo_fill(r->pinceau);
    }
}

void spectre_surimpression_decouper(SpectreRendu *r, float x, float y,
                                    float largeur, float hauteur) {
    if (!r || !r->dessinEnCours) { return; }
    cairo_save(r->pinceau);
    cairo_rectangle(r->pinceau, x, y, largeur, hauteur);
    cairo_clip(r->pinceau);
    r->decoupes += 1;
}

void spectre_surimpression_recoller(SpectreRendu *r) {
    if (!r || r->decoupes <= 0) { return; }
    cairo_restore(r->pinceau);
    r->decoupes -= 1;
}

// ─────────────────────────────────────────────────────────── Le texte

/// L'UTF-16 que le pont reçoit, en UTF-8 que Pango attend.
///
/// Le Swift envoie de l'UTF-16 parce que c'est ce que DirectWrite demande, et
/// changer la frontière pour Linux seul obligerait `Pinceau` à savoir sur quoi il
/// tourne. La conversion tient en vingt lignes ; c'est le prix d'une frontière qui
/// reste la même des deux côtés.
static char *enUTF8(const uint16_t *texte) {
    size_t n = 0;
    while (texte[n]) { n += 1; }
    char *sortie = malloc(n * 4 + 1);
    if (!sortie) { return NULL; }
    size_t o = 0;
    for (size_t i = 0; i < n; ++i) {
        uint32_t c = texte[i];
        // Les paires de substitution : au-delà du plan multilingue de base, un
        // caractère s'écrit sur deux unités. Les émoji des intitulés en font partie.
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n
            && texte[i + 1] >= 0xDC00 && texte[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (texte[i + 1] - 0xDC00);
            i += 1;
        }
        if (c < 0x80) {
            sortie[o++] = (char)c;
        } else if (c < 0x800) {
            sortie[o++] = (char)(0xC0 | (c >> 6));
            sortie[o++] = (char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            sortie[o++] = (char)(0xE0 | (c >> 12));
            sortie[o++] = (char)(0x80 | ((c >> 6) & 0x3F));
            sortie[o++] = (char)(0x80 | (c & 0x3F));
        } else {
            sortie[o++] = (char)(0xF0 | (c >> 18));
            sortie[o++] = (char)(0x80 | ((c >> 12) & 0x3F));
            sortie[o++] = (char)(0x80 | ((c >> 6) & 0x3F));
            sortie[o++] = (char)(0x80 | (c & 0x3F));
        }
    }
    sortie[o] = 0;
    return sortie;
}

/// La police, à la taille demandée.
///
/// « Sans » et « Monospace » plutôt que des noms de fontes : c'est fontconfig qui
/// décide ce que la distribution a, et il le fait mieux qu'une liste écrite ici.
/// Le pendant Windows nomme Segoe UI et Cascadia Mono parce que Windows les a
/// toujours ; aucune distribution n'a « toujours » quoi que ce soit.
///
/// La taille est posée en unités **absolues** : sans cela Pango la multiplierait par
/// la résolution supposée de l'écran, et un onze deviendrait un quinze.
static void poserLaPolice(SpectreRendu *r, int police, float taille) {
    PangoFontDescription *desc = pango_font_description_from_string(
        police == 1 ? "Monospace" : "Sans");
    pango_font_description_set_absolute_size(desc, taille * PANGO_SCALE);
    pango_layout_set_font_description(r->miseEnPage, desc);
    pango_font_description_free(desc);
}

/// Mesure la ligne, sans la dessiner.
static void mesurer(SpectreRendu *r, double *largeur, double *hauteur) {
    int l = 0, h = 0;
    pango_layout_get_pixel_size(r->miseEnPage, &l, &h);
    if (largeur) { *largeur = l; }
    if (hauteur) { *hauteur = h; }
}

void spectre_surimpression_texte(SpectreRendu *r, const uint16_t *texte,
                                 float x, float y, float largeur, float taille,
                                 uint32_t rvba, int police, int alignement) {
    if (!r || !r->dessinEnCours || !texte) { return; }
    char *utf8 = enUTF8(texte);
    if (!utf8) { return; }

    poserLaPolice(r, police, taille);
    // Pas de largeur posée sur la mise en page : Pango replierait le texte, là où
    // Direct2D le laisse sur une ligne et le coupe. L'alignement se fait donc à la
    // main, et la coupe par une découpe.
    pango_layout_set_width(r->miseEnPage, -1);
    pango_layout_set_text(r->miseEnPage, utf8, -1);
    free(utf8);

    double l = 0, h = 0;
    mesurer(r, &l, &h);
    double gauche = x;
    if (alignement == 1) { gauche = x + (largeur - l) / 2; }
    else if (alignement == 2) { gauche = x + largeur - l; }

    cairo_save(r->pinceau);
    cairo_rectangle(r->pinceau, x, y - taille * 2, largeur, taille * 4);
    cairo_clip(r->pinceau);
    poserLaCouleur(r->pinceau, rvba);
    // `y` est le **milieu** de la ligne, comme `context.draw(Text, at:)` de SwiftUI
    // et comme le centrage vertical que Direct2D pose sur son format.
    cairo_move_to(r->pinceau, gauche, y - h / 2);
    pango_cairo_show_layout(r->pinceau, r->miseEnPage);
    cairo_restore(r->pinceau);
}

float spectre_surimpression_largeur_texte(SpectreRendu *r, const uint16_t *texte,
                                          float taille, int police) {
    if (!r || !r->miseEnPage || !texte) { return 0; }
    char *utf8 = enUTF8(texte);
    if (!utf8) { return 0; }
    poserLaPolice(r, police, taille);
    pango_layout_set_width(r->miseEnPage, -1);
    pango_layout_set_text(r->miseEnPage, utf8, -1);
    free(utf8);
    double l = 0;
    mesurer(r, &l, NULL);
    return (float)l;
}

float spectre_surimpression_paragraphe(SpectreRendu *r, const uint16_t *texte,
                                       float x, float y, float largeur, float taille,
                                       uint32_t rvba, int police, int dessiner) {
    if (!r || !r->miseEnPage || !texte || largeur <= 0) { return 0; }
    char *utf8 = enUTF8(texte);
    if (!utf8) { return 0; }

    poserLaPolice(r, police, taille);
    pango_layout_set_width(r->miseEnPage, (int)(largeur * PANGO_SCALE));
    pango_layout_set_wrap(r->miseEnPage, PANGO_WRAP_WORD_CHAR);
    pango_layout_set_alignment(r->miseEnPage, PANGO_ALIGN_LEFT);
    pango_layout_set_text(r->miseEnPage, utf8, -1);
    free(utf8);

    double l = 0, h = 0;
    mesurer(r, &l, &h);
    if (dessiner && r->dessinEnCours) {
        poserLaCouleur(r->pinceau, rvba);
        // `y` est ici le **haut** du bloc, et non le milieu d'une ligne : un texte
        // dont on ignore le nombre de lignes ne peut pas se centrer sur une ordonnée
        // choisie d'avance.
        cairo_move_to(r->pinceau, x, y);
        pango_cairo_show_layout(r->pinceau, r->miseEnPage);
    }
    // Reposé pour l'appel suivant, qui sera peut-être une ligne simple.
    pango_layout_set_width(r->miseEnPage, -1);
    return (float)h;
}

// ─────────────────────────────────────────────────────────── Les images

// Les captures du diaporama du premier lancement, et rien d'autre pour l'instant.
//
// **Gardées après la première lecture**, échec compris. Le diaporama est redessiné
// à chaque image comme tout le reste de la surimpression : décoder deux mégapixels
// de PNG cent vingt fois par seconde ferait de la présentation de l'application la
// seule chose qui rame, et rechercher cent vingt fois par seconde un fichier absent
// coûterait autant pour ne rien montrer.
//
// Quatre entrées : le diaporama en montre deux, et l'on ne veut pas d'un cache qui
// grandit sans borne dans un fichier de dessin. Au-delà, l'image n'est simplement
// pas dessinée — c'est le même sort qu'un fichier absent, et le texte reste.
#define SPECTRE_IMAGES 4

static struct {
    char *chemin;
    cairo_surface_t *surface;      // NULL quand la lecture a échoué
} imagesGardees[SPECTRE_IMAGES];
static int imagesConnues = 0;

static cairo_surface_t *imagePour(const char *chemin) {
    for (int i = 0; i < imagesConnues; ++i) {
        if (strcmp(imagesGardees[i].chemin, chemin) == 0) {
            return imagesGardees[i].surface;
        }
    }
    if (imagesConnues >= SPECTRE_IMAGES) { return NULL; }

    cairo_surface_t *surface = cairo_image_surface_create_from_png(chemin);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        surface = NULL;
    }
    char *garde = strdup(chemin);
    if (!garde) {
        if (surface) { cairo_surface_destroy(surface); }
        return NULL;
    }
    imagesGardees[imagesConnues].chemin = garde;
    imagesGardees[imagesConnues].surface = surface;
    imagesConnues += 1;
    return surface;
}

void spectre_surimpression_image(SpectreRendu *r, const uint16_t *chemin,
                                 float x, float y, float largeur, float hauteur) {
    if (!r || !r->dessinEnCours || !chemin || largeur <= 0 || hauteur <= 0) { return; }
    char *utf8 = enUTF8(chemin);
    if (!utf8) { return; }
    cairo_surface_t *image = imagePour(utf8);
    free(utf8);
    if (!image) { return; }

    double l = cairo_image_surface_get_width(image);
    double h = cairo_image_surface_get_height(image);
    if (l <= 0 || h <= 0) { return; }

    // À ses proportions, et centrée : les deux captures n'ont pas la même forme —
    // l'une est une fenêtre entière, l'autre une bande de vingt points de haut — et
    // les étirer toutes deux dans le même cadre mentirait sur ce que l'application
    // montre, ce qui est très exactement ce qu'un diaporama ne doit pas faire.
    double facteur = (largeur / l < hauteur / h) ? largeur / l : hauteur / h;
    cairo_save(r->pinceau);
    cairo_translate(r->pinceau,
                    x + (largeur - l * facteur) / 2,
                    y + (hauteur - h * facteur) / 2);
    cairo_scale(r->pinceau, facteur, facteur);
    cairo_set_source_surface(r->pinceau, image, 0, 0);
    // La capture est réduite d'un facteur trois : sans filtre, les traits d'un point
    // du spectrogramme disparaissent un sur trois et l'image devient une grille.
    cairo_pattern_set_filter(cairo_get_source(r->pinceau), CAIRO_FILTER_GOOD);
    cairo_paint(r->pinceau);
    cairo_restore(r->pinceau);
}
