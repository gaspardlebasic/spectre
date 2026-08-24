// Le rendu du spectrogramme sous Linux, en OpenGL 3.3 — le jumeau de `d3d11.c`.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE MÊME CONTRAT, TREIZE FONCTIONS
//
// Ce fichier exporte exactement ce qu'exporte `d3d11.c`, avec les mêmes noms et
// les mêmes signatures. Le Swift qui appelle ne sait pas laquelle des deux il a
// devant lui, et n'a pas à le savoir : c'est ce qui permet à `Rendu.swift` d'être
// écrit une fois pour Windows et pour Linux.
//
// POURQUOI SDL EST DE CE CÔTÉ-CI DE LA FRONTIÈRE
//
// La fenêtre est créée par SDL, en Swift. Mais le **contexte** OpenGL, lui, est
// créé ici : sans cela `spectre_rendu_presenter` ne pourrait pas échanger les
// tampons, et le contrat cesserait d'être le même — Windows présente par sa chaîne
// d'échange, sans que l'appelant s'en mêle. Le pont reçoit donc le `SDL_Window *`
// et se débrouille avec, exactement comme il reçoit un `HWND` sous Windows.
//
// POURQUOI LIBEPOXY
//
// OpenGL, sous Linux, n'expose au lien que sa version 1.x : tout ce qui est
// postérieur se réclame à l'exécution, un pointeur de fonction à la fois. C'est
// une quarantaine de lignes de chargeur pour ce fichier, sans une décision
// dedans. `epoxy/gl.h` les écrit à notre place et se trouve sur toutes les
// distributions — GNOME en dépend. Ce n'est pas un rouage qu'on pourrait écrire
// mieux, c'est une table de pointeurs.
// ─────────────────────────────────────────────────────────────────────────────

#include <epoxy/gl.h>

#include <SDL3/SDL.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "interne.h"

static void noter(char *erreur, const char *format, ...) {
    if (!erreur) { return; }
    va_list args;
    va_start(args, format);
    vsnprintf(erreur, SPECTRE_ERREUR_MAX, format, args);
    va_end(args);
}

// ─────────────────────────────────────────────────────────── Les nuanceurs

/// Compile un étage à partir de la **même** source que l'autre.
///
/// Le fichier GLSL porte les deux étages, séparés par `#ifdef SPECTRE_SOMMETS` et
/// `#ifdef SPECTRE_FRAGMENTS`. On le compile donc deux fois, en changeant la macro
/// posée devant. C'est ce qui garde une seule écriture du nuanceur — comme le HLSL,
/// qui a lui aussi ses deux points d'entrée dans un seul texte.
///
/// `#version` doit être la première ligne d'un source GLSL : elle est posée ici, et
/// le texte donné n'en porte pas.
static GLuint compiler(GLenum etage, const char *source, const char *macro,
                       char *erreur) {
    const char *entete = "#version 330 core\n";
    char definition[64];
    snprintf(definition, sizeof definition, "#define %s 1\n", macro);
    const char *morceaux[3] = { entete, definition, source };

    GLuint nuanceur = glCreateShader(etage);
    glShaderSource(nuanceur, 3, morceaux, NULL);
    glCompileShader(nuanceur);

    GLint ok = 0;
    glGetShaderiv(nuanceur, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char journal[SPECTRE_ERREUR_MAX];
        GLsizei longueur = 0;
        glGetShaderInfoLog(nuanceur, sizeof journal, &longueur, journal);
        journal[longueur < (GLsizei)sizeof journal ? longueur : (GLsizei)sizeof journal - 1] = 0;
        noter(erreur, "nuanceur %s : %s", macro, journal);
        glDeleteShader(nuanceur);
        return 0;
    }
    return nuanceur;
}

/// Les emplacements des uniformes, relevés une fois.
///
/// OpenGL désigne un uniforme par un nom, et le retrouver à chaque image coûterait
/// une comparaison de chaînes par uniforme et par image. Direct3D, lui, verse la
/// structure entière d'un coup dans un tampon de constantes ; c'est la seule
/// différence de forme entre les deux, et elle tient dans cette table.
static void relever(SpectreRendu *r) {
#define EMPLACEMENT(champ, nom) r->u_##champ = glGetUniformLocation(r->programme, nom)
    EMPLACEMENT(origine, "origine");
    EMPLACEMENT(parPixel, "parPixel");
    EMPLACEMENT(tailleVue, "tailleVue");
    EMPLACEMENT(colonnes, "colonnes");
    EMPLACEMENT(lignes, "lignes");
    EMPLACEMENT(hauteurTuile, "hauteurTuile");
    EMPLACEMENT(pas, "pas");
    EMPLACEMENT(palette, "palette");
    EMPLACEMENT(minDb, "minDb");
    EMPLACEMENT(maxDb, "maxDb");
    EMPLACEMENT(gammaValeur, "gammaValeur");
    EMPLACEMENT(penteParOctave, "penteParOctave");
    EMPLACEMENT(log2FminSur1k, "log2FminSur1k");
    EMPLACEMENT(lignesParOctave, "lignesParOctave");
    EMPLACEMENT(demiTonLigne0, "demiTonLigne0");
    EMPLACEMENT(teteDeLecture, "teteDeLecture");
    EMPLACEMENT(boucleDebut, "boucleDebut");
    EMPLACEMENT(boucleFin, "boucleFin");
#undef EMPLACEMENT
    r->u_tuiles = glGetUniformLocation(r->programme, "tuiles");
    r->u_tableDesNotes = glGetUniformLocation(r->programme, "couleursNote");
}

static int creerNuanceurs(SpectreRendu *r, const char *source, char *erreur) {
    GLuint sommets = compiler(GL_VERTEX_SHADER, source, "SPECTRE_SOMMETS", erreur);
    if (!sommets) { return 0; }
    GLuint fragments = compiler(GL_FRAGMENT_SHADER, source, "SPECTRE_FRAGMENTS", erreur);
    if (!fragments) { glDeleteShader(sommets); return 0; }

    r->programme = glCreateProgram();
    glAttachShader(r->programme, sommets);
    glAttachShader(r->programme, fragments);
    glLinkProgram(r->programme);
    glDeleteShader(sommets);
    glDeleteShader(fragments);

    GLint ok = 0;
    glGetProgramiv(r->programme, GL_LINK_STATUS, &ok);
    if (!ok) {
        char journal[SPECTRE_ERREUR_MAX];
        GLsizei longueur = 0;
        glGetProgramInfoLog(r->programme, sizeof journal, &longueur, journal);
        journal[longueur < (GLsizei)sizeof journal ? longueur : (GLsizei)sizeof journal - 1] = 0;
        noter(erreur, "edition de liens du nuanceur : %s", journal);
        glDeleteProgram(r->programme);
        r->programme = 0;
        return 0;
    }
    relever(r);

    // Aucun tampon de sommets — trois sommets naissent de `gl_VertexID` — mais le
    // profil **core** refuse de dessiner sans qu'un tableau de sommets soit lié,
    // même vide. Sans cette ligne : `GL_INVALID_OPERATION`, et un écran noir sans
    // un mot.
    glGenVertexArrays(1, &r->tableauDeSommets);
    return 1;
}

// ─────────────────────────────────────────────────────────── La vie de l'objet

static void liberer(SpectreRendu *r) {
    if (!r) { return; }
    if (r->contexte) {
        SDL_GL_MakeCurrent(r->fenetre, r->contexte);
        if (r->tuiles) { glDeleteTextures(1, &r->tuiles); }
        if (r->tableDesNotes) { glDeleteTextures(1, &r->tableDesNotes); }
        if (r->cibleTexture) { glDeleteTextures(1, &r->cibleTexture); }
        if (r->cadre) { glDeleteFramebuffers(1, &r->cadre); }
        if (r->tableauDeSommets) { glDeleteVertexArrays(1, &r->tableauDeSommets); }
        if (r->programme) { glDeleteProgram(r->programme); }
        SDL_GL_DestroyContext(r->contexte);
    }
    if (r->fenetreANous && r->fenetre) { SDL_DestroyWindow(r->fenetre); }
    free(r);
}

/// Demande un contexte 3.3 **core**, et pas moins.
///
/// Le profil de compatibilité accepterait le nuanceur et pardonnerait le tableau de
/// sommets manquant : ce qui marcherait ici cesserait de marcher chez qui a un
/// pilote strict. Autant se faire refuser tout de suite.
static void demanderUnProfil(void) {
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
}

static int demarrer(SpectreRendu *r, const char *source, char *erreur) {
    r->contexte = SDL_GL_CreateContext(r->fenetre);
    if (!r->contexte) {
        noter(erreur, "contexte OpenGL : %s", SDL_GetError());
        return 0;
    }
    if (!SDL_GL_MakeCurrent(r->fenetre, r->contexte)) {
        noter(erreur, "contexte courant : %s", SDL_GetError());
        return 0;
    }
    const GLubyte *carte = glGetString(GL_RENDERER);
    snprintf(r->carte, sizeof r->carte, "%s", carte ? (const char *)carte : "inconnue");
    return creerNuanceurs(r, source, erreur);
}

SpectreRendu *spectre_rendu_creer(void *fenetre, const char *sourceGLSL, char *erreur) {
    if (!fenetre) { noter(erreur, "aucune fenetre"); return NULL; }
    SpectreRendu *r = calloc(1, sizeof *r);
    if (!r) { noter(erreur, "memoire"); return NULL; }
    r->fenetre = (SDL_Window *)fenetre;
    r->fenetreANous = 0;
    if (!demarrer(r, sourceGLSL, erreur)) { liberer(r); return NULL; }

    // Intervalle **un** : l'échange attend le balayage. C'est ce qui cadence la
    // boucle, et c'est aussi ce qui rend `spectre_rendu_attendre` sans objet ici —
    // voir la note qui y est écrite.
    SDL_GL_SetSwapInterval(1);

    int l = 0, h = 0;
    SDL_GetWindowSizeInPixels(r->fenetre, &l, &h);
    r->largeur = l;
    r->hauteur = h;
    return r;
}

SpectreRendu *spectre_rendu_creer_hors_ecran(int largeur, int hauteur,
                                             const char *sourceGLSL, char *erreur) {
    if (largeur <= 0 || hauteur <= 0) { noter(erreur, "taille nulle"); return NULL; }
    if (!SDL_InitSubSystem(SDL_INIT_VIDEO)) {
        noter(erreur, "SDL video : %s", SDL_GetError());
        return NULL;
    }
    SpectreRendu *r = calloc(1, sizeof *r);
    if (!r) { noter(erreur, "memoire"); return NULL; }

    // Une fenêtre cachée plutôt qu'un contexte EGL sans surface : quarante lignes de
    // moins, le même résultat, et surtout **le même chemin** que la fenêtre visible
    // — un harnais qui éprouverait une autre pile ne dirait rien de celle qui sert.
    demanderUnProfil();
    r->fenetre = SDL_CreateWindow("spectre", largeur, hauteur,
                                  SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    if (!r->fenetre) {
        noter(erreur, "fenetre cachee : %s", SDL_GetError());
        free(r);
        return NULL;
    }
    r->fenetreANous = 1;
    r->largeur = largeur;
    r->hauteur = hauteur;
    if (!demarrer(r, sourceGLSL, erreur)) { liberer(r); return NULL; }

    // Une cible à nous, et non le tampon de la fenêtre : celui d'une fenêtre cachée
    // n'est pas garanti d'exister, et le relire rendrait du noir sur certains
    // pilotes sans que rien ne se plaigne.
    glGenTextures(1, &r->cibleTexture);
    glBindTexture(GL_TEXTURE_2D, r->cibleTexture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, largeur, hauteur, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    glGenFramebuffers(1, &r->cadre);
    glBindFramebuffer(GL_FRAMEBUFFER, r->cadre);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           r->cibleTexture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        noter(erreur, "cible hors ecran incomplete");
        liberer(r);
        return NULL;
    }
    return r;
}

void spectre_rendu_detruire(SpectreRendu *rendu) { liberer(rendu); }

// ─────────────────────────────────────────────────────────── La géométrie

void spectre_rendu_zone(SpectreRendu *rendu, int largeur, int hauteur) {
    if (!rendu) { return; }
    rendu->zoneLargeur = largeur;
    rendu->zoneHauteur = hauteur;
}

int spectre_rendu_largeur(const SpectreRendu *rendu) { return rendu ? rendu->largeur : 0; }
int spectre_rendu_hauteur(const SpectreRendu *rendu) { return rendu ? rendu->hauteur : 0; }

int spectre_rendu_redimensionner(SpectreRendu *rendu, int largeur, int hauteur) {
    if (!rendu || largeur <= 0 || hauteur <= 0) { return 0; }
    // Rien à refaire : OpenGL n'a pas de chaîne d'échange à recréer, le tampon de la
    // fenêtre suit tout seul. Il n'y a que la taille à retenir, parce que c'est elle
    // qui place la fenêtre de vue et la relecture.
    if (rendu->cadre) { return 1; }          // hors écran : taille figée
    rendu->largeur = largeur;
    rendu->hauteur = hauteur;
    return 1;
}

// ─────────────────────────────────────────────────────────── Ce qu'on téléverse

int spectre_rendu_televerser_tuiles(SpectreRendu *rendu, int lignes, int colonnes,
                                    int hauteurTuile, const uint16_t *valeurs) {
    if (!rendu) { return 0; }
    SDL_GL_MakeCurrent(rendu->fenetre, rendu->contexte);
    if (rendu->tuiles) {
        glDeleteTextures(1, &rendu->tuiles);
        rendu->tuiles = 0;
    }
    if (lignes <= 0 || colonnes <= 0) { return 1; }

    int tranches = (colonnes + hauteurTuile - 1) / hauteurTuile;

    // La dernière tranche est incomplète, et le tableau source ne la remplit pas :
    // on recopie dans un tampon à la bonne taille plutôt que de laisser OpenGL lire
    // au-delà. Même raison que du côté Direct3D, et même disposition — chaque rangée
    // de la texture porte une colonne du spectrogramme, `lignes` valeurs de large.
    size_t parTranche = (size_t)hauteurTuile * (size_t)lignes;
    uint16_t *tampon = calloc((size_t)tranches * parTranche, sizeof(uint16_t));
    if (!tampon) { return 0; }
    for (int t = 0; t < tranches; ++t) {
        int premiere = t * hauteurTuile;
        int nombre = colonnes - premiere;
        if (nombre > hauteurTuile) { nombre = hauteurTuile; }
        memcpy(tampon + (size_t)t * parTranche,
               valeurs + (size_t)premiere * (size_t)lignes,
               (size_t)nombre * (size_t)lignes * sizeof(uint16_t));
    }

    glGenTextures(1, &rendu->tuiles);
    glBindTexture(GL_TEXTURE_2D_ARRAY, rendu->tuiles);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 2);
    glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_R16F, lignes, hauteurTuile, tranches, 0,
                 GL_RED, GL_HALF_FLOAT, tampon);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    // `texelFetch` ne filtre pas, mais une texture sans niveaux de détail déclarés
    // est **incomplète** pour OpenGL, et une texture incomplète rend du noir.
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, 0);
    free(tampon);
    return glGetError() == GL_NO_ERROR;
}

int spectre_rendu_televerser_palette(SpectreRendu *rendu, int largeur, int hauteur,
                                     const uint8_t *rgba) {
    if (!rendu || largeur <= 0 || hauteur <= 0) { return 0; }
    SDL_GL_MakeCurrent(rendu->fenetre, rendu->contexte);
    if (rendu->tableDesNotes) {
        glDeleteTextures(1, &rendu->tableDesNotes);
        rendu->tableDesNotes = 0;
    }
    glGenTextures(1, &rendu->tableDesNotes);
    glBindTexture(GL_TEXTURE_2D, rendu->tableDesNotes);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, largeur, hauteur, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    return glGetError() == GL_NO_ERROR;
}

// ─────────────────────────────────────────────────────────── Le dessin

void spectre_rendu_dessiner(SpectreRendu *rendu, const SpectreUniformes *u) {
    if (!rendu || !rendu->programme) { return; }
    SDL_GL_MakeCurrent(rendu->fenetre, rendu->contexte);
    glBindFramebuffer(GL_FRAMEBUFFER, rendu->cadre);

    // Effacer d'abord, et sur toute la cible : une fenêtre sans matrice est noire, et
    // non le contenu de ce qui la précédait.
    glViewport(0, 0, rendu->largeur, rendu->hauteur);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (!rendu->tuiles) { return; }

    int zl = rendu->zoneLargeur > 0 ? rendu->zoneLargeur : rendu->largeur;
    int zh = rendu->zoneHauteur > 0 ? rendu->zoneHauteur : rendu->hauteur;

    // ── La fenêtre de vue, et le seul endroit où OpenGL compte à l'envers ────────
    //
    // Direct3D et Metal posent la leur depuis le coin **haut**-gauche ; OpenGL
    // depuis le coin bas-gauche. Le spectrogramme occupant la bande du haut — la
    // batterie prend celle du bas — l'ordonnée n'est donc pas zéro mais ce qui
    // reste au-dessous.
    //
    // Le nuanceur, lui, ne s'en aperçoit pas : il déclare `origin_upper_left`, ce
    // qui lui rend un `gl_FragCoord` compté depuis le haut, exactement comme le
    // `SV_Position` du HLSL et la `[[position]]` du MSL. C'est ce qui permet aux
    // trois écritures d'être la même formule, au vocabulaire près.
    glViewport(0, rendu->hauteur - zh, zl, zh);

    glUseProgram(rendu->programme);
    glBindVertexArray(rendu->tableauDeSommets);

    glUniform2f(rendu->u_origine, u->origineX, u->origineY);
    glUniform2f(rendu->u_parPixel, u->parPixelX, u->parPixelY);
    glUniform2f(rendu->u_tailleVue, u->tailleVueX, u->tailleVueY);
    glUniform1i(rendu->u_colonnes, u->colonnes);
    glUniform1i(rendu->u_lignes, u->lignes);
    glUniform1i(rendu->u_hauteurTuile, u->hauteurTuile);
    glUniform1i(rendu->u_pas, u->pas);
    glUniform1i(rendu->u_palette, u->palette);
    glUniform1f(rendu->u_minDb, u->minDb);
    glUniform1f(rendu->u_maxDb, u->maxDb);
    glUniform1f(rendu->u_gammaValeur, u->gammaValeur);
    glUniform1f(rendu->u_penteParOctave, u->penteParOctave);
    glUniform1f(rendu->u_log2FminSur1k, u->log2FminSur1k);
    glUniform1f(rendu->u_lignesParOctave, u->lignesParOctave);
    glUniform1f(rendu->u_demiTonLigne0, u->demiTonLigne0);
    glUniform1f(rendu->u_teteDeLecture, u->teteDeLecture);
    glUniform1f(rendu->u_boucleDebut, u->boucleDebut);
    glUniform1f(rendu->u_boucleFin, u->boucleFin);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D_ARRAY, rendu->tuiles);
    glUniform1i(rendu->u_tuiles, 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, rendu->tableDesNotes);
    glUniform1i(rendu->u_tableDesNotes, 1);

    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
}

int spectre_rendu_presenter(SpectreRendu *rendu) {
    if (!rendu || rendu->cadre) { return 0; }       // hors écran : rien à présenter
    // Une fenêtre cachée cesse d'être cadencée par le balayage, et un relevé de
    // fluidité pris à ce moment-là compterait des images que personne ne voit.
    SDL_WindowFlags drapeaux = SDL_GetWindowFlags(rendu->fenetre);
    if (drapeaux & (SDL_WINDOW_HIDDEN | SDL_WINDOW_MINIMIZED)) { return 2; }
    return SDL_GL_SwapWindow(rendu->fenetre) ? 1 : 0;
}

void spectre_rendu_attendre(SpectreRendu *rendu) {
    (void)rendu;
    // ── Rien à faire ici, et il faut dire pourquoi ──────────────────────────────
    //
    // Sous Windows, la chaîne d'échange donne un objet d'attente : on dort **avant**
    // de dessiner, si bien que l'image montrée porte l'état le plus frais possible.
    // OpenGL n'a pas d'équivalent — l'attente y est dans `SwapWindow`, donc *après*
    // avoir dessiné.
    //
    // La conséquence est une image de latence de plus dans le pire des cas. Elle est
    // laissée telle quelle : la mesurer demande l'étape 6, et corriger ce qu'on n'a
    // pas mesuré est le meilleur moyen de le rendre pire.
}

int spectre_rendu_relire(SpectreRendu *rendu, uint8_t *octets) {
    if (!rendu || !octets) { return 0; }
    SDL_GL_MakeCurrent(rendu->fenetre, rendu->contexte);
    glBindFramebuffer(GL_FRAMEBUFFER, rendu->cadre);
    glFinish();

    int l = rendu->largeur, h = rendu->hauteur;
    uint8_t *ligne = malloc((size_t)l * 3);
    if (!ligne) { return 0; }

    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, l, h, GL_RGB, GL_UNSIGNED_BYTE, octets);

    // OpenGL rend les rangées **depuis le bas** ; le contrat dit depuis le haut,
    // parce que c'est ainsi qu'une image se lit et que Direct3D la donne. On les
    // retourne donc, une rangée contre son opposée.
    for (int y = 0; y < h / 2; ++y) {
        uint8_t *haut = octets + (size_t)y * l * 3;
        uint8_t *bas = octets + (size_t)(h - 1 - y) * l * 3;
        memcpy(ligne, haut, (size_t)l * 3);
        memcpy(haut, bas, (size_t)l * 3);
        memcpy(bas, ligne, (size_t)l * 3);
    }
    free(ligne);
    return glGetError() == GL_NO_ERROR;
}

void spectre_rendu_nom_de_la_carte(SpectreRendu *rendu, char *nom, int taille) {
    if (!nom || taille <= 0) { return; }
    snprintf(nom, (size_t)taille, "%s", rendu ? rendu->carte : "");
}
