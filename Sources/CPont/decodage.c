// Le décodage sous Linux — le jumeau de `mediafoundation.c`.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE MÊME CONTRAT, QUATRE FONCTIONS
//
// Ce fichier exporte exactement ce qu'exporte `mediafoundation.c`, avec les mêmes
// noms et les mêmes signatures. `SpectreSon/Decodeur.swift` ne sait pas lequel des
// deux il appelle — et c'est ce qui permet au décodeur d'être écrit une seule fois.
//
// DEUX BIBLIOTHÈQUES, ET POURQUOI PAS UNE SEULE
//
// **libsndfile** lit le WAV, l'AIFF, le FLAC, l'OGG et l'Opus. Elle ne lit pas le
// MP3 avant sa version 1.1, et la 24.04 en livre une qui le fait — mais on ne peut
// pas le supposer chez celui qui reçoit. **libmpg123** s'en charge donc, et c'est
// elle qui décide pour les fichiers que la première refuse.
//
// L'ordre compte : libsndfile d'abord, parce qu'elle reconnaît par le contenu et
// non par l'extension. Un `.mp3` qui est en réalité un WAV — cela arrive plus
// souvent qu'on ne croit avec les fichiers qui ont traversé trois outils — passe
// alors par le bon chemin.
//
// CE QUE CE FICHIER NE FAIT PAS
//
// Il ne rogne pas l'amorçage du codeur. Le décodeur du système rend cet amorçage
// avec le reste, et c'est `GaplessTrim` — côté Swift, portable, vérifiable — qui
// lit ce que le conteneur en déclare. Même règle que sous Windows, et pour la même
// raison : ce qui se mesure doit vivre là où trois plateformes le mesurent.
// ─────────────────────────────────────────────────────────────────────────────

#include <sndfile.h>
#include <mpg123.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/pont.h"

static SpectreDecodage echec(int code) {
    SpectreDecodage d = {0};
    d.code = code;
    return d;
}

// ─────────────────────────────────────────────────────────── libsndfile

/// Lit tout le fichier en flottants entrelacés. Rend `NULL` si le format n'est pas
/// de son ressort.
static float *parSndfile(const char *chemin, int *canaux, double *frequence,
                         int64_t *images, int *code) {
    SF_INFO info;
    memset(&info, 0, sizeof info);
    SNDFILE *fichier = sf_open(chemin, SFM_READ, &info);
    if (!fichier) { return NULL; }
    if (info.frames <= 0 || info.channels <= 0) {
        sf_close(fichier);
        *code = SPECTRE_DECODAGE_VIDE;
        return NULL;
    }

    size_t total = (size_t)info.frames * (size_t)info.channels;
    float *tampon = malloc(total * sizeof(float));
    if (!tampon) {
        sf_close(fichier);
        *code = SPECTRE_DECODAGE_MEMOIRE;
        return NULL;
    }
    // `sf_readf_float` normalise en −1…1 pour les formats entiers, ce qui est
    // exactement la convention du reste de la chaîne.
    sf_count_t lues = sf_readf_float(fichier, tampon, info.frames);
    sf_close(fichier);
    if (lues <= 0) {
        free(tampon);
        *code = SPECTRE_DECODAGE_LECTURE;
        return NULL;
    }
    *canaux = info.channels;
    *frequence = (double)info.samplerate;
    *images = (int64_t)lues;
    *code = SPECTRE_DECODAGE_OK;
    return tampon;
}

// ─────────────────────────────────────────────────────────── libmpg123

/// Le MP3, quand libsndfile n'en a pas voulu.
///
/// `mpg123_init` est comptée : l'appeler à chaque fichier serait sans effet après
/// la première fois, mais l'appeler zéro fois laisse la bibliothèque sans ses
/// tables. Elle est donc posée ici, une fois, et jamais défaite — l'application
/// décode jusqu'à sa fermeture.
static float *parMpg123(const char *chemin, int *canaux, double *frequence,
                        int64_t *images, int *code) {
    static int demarree = 0;
    if (!demarree) {
        if (mpg123_init() != MPG123_OK) { *code = SPECTRE_DECODAGE_DEMARRAGE; return NULL; }
        demarree = 1;
    }

    int erreur = MPG123_OK;
    mpg123_handle *poignee = mpg123_new(NULL, &erreur);
    if (!poignee) { *code = SPECTRE_DECODAGE_DEMARRAGE; return NULL; }

    // Flottants, et la fréquence du fichier : ni rééchantillonnage ni mixage ici.
    // L'analyse garde la fréquence du fichier — rééchantillonner avant d'analyser
    // perdrait de la matière.
    mpg123_param(poignee, MPG123_ADD_FLAGS, MPG123_FORCE_FLOAT, 0);
    if (mpg123_open(poignee, chemin) != MPG123_OK) {
        mpg123_delete(poignee);
        *code = SPECTRE_DECODAGE_OUVERTURE;
        return NULL;
    }

    long taux = 0;
    int voies = 0, encodage = 0;
    if (mpg123_getformat(poignee, &taux, &voies, &encodage) != MPG123_OK
        || taux <= 0 || voies <= 0) {
        mpg123_close(poignee);
        mpg123_delete(poignee);
        *code = SPECTRE_DECODAGE_FORMAT;
        return NULL;
    }
    // Le format est figé : sans cela mpg123 accepterait d'en changer en cours de
    // route — un MP3 dont la seconde moitié est en mono existe — et le tampon
    // deviendrait faux à mi-course sans un mot.
    mpg123_format_none(poignee);
    mpg123_format(poignee, taux, voies, MPG123_ENC_FLOAT_32);

    size_t capacite = 0;
    off_t annonce = mpg123_length(poignee);
    if (annonce > 0) { capacite = (size_t)annonce * (size_t)voies; }
    if (capacite == 0) { capacite = (size_t)taux * (size_t)voies * 60; }
    float *tampon = malloc(capacite * sizeof(float));
    if (!tampon) {
        mpg123_close(poignee);
        mpg123_delete(poignee);
        *code = SPECTRE_DECODAGE_MEMOIRE;
        return NULL;
    }

    size_t ecrits = 0;
    unsigned char *bloc = NULL;
    size_t taille = 0;
    int etat;
    // `mpg123_length` n'est qu'une annonce : un fichier dont l'entête ment, ou dont
    // le débit varie, en rend une autre. Le tampon grandit donc plutôt que de faire
    // confiance.
    while ((etat = mpg123_decode_frame(poignee, NULL, &bloc, &taille)) == MPG123_OK
           || etat == MPG123_NEW_FORMAT) {
        if (etat == MPG123_NEW_FORMAT) { continue; }
        size_t nombre = taille / sizeof(float);
        if (ecrits + nombre > capacite) {
            size_t neuve = (capacite ? capacite * 2 : nombre) + nombre;
            float *agrandi = realloc(tampon, neuve * sizeof(float));
            if (!agrandi) {
                free(tampon);
                mpg123_close(poignee);
                mpg123_delete(poignee);
                *code = SPECTRE_DECODAGE_MEMOIRE;
                return NULL;
            }
            tampon = agrandi;
            capacite = neuve;
        }
        memcpy(tampon + ecrits, bloc, nombre * sizeof(float));
        ecrits += nombre;
    }
    mpg123_close(poignee);
    mpg123_delete(poignee);

    if (etat != MPG123_DONE && ecrits == 0) {
        free(tampon);
        *code = SPECTRE_DECODAGE_LECTURE;
        return NULL;
    }
    if (ecrits == 0) {
        free(tampon);
        *code = SPECTRE_DECODAGE_VIDE;
        return NULL;
    }
    *canaux = voies;
    *frequence = (double)taux;
    *images = (int64_t)(ecrits / (size_t)voies);
    *code = SPECTRE_DECODAGE_OK;
    return tampon;
}

// ─────────────────────────────────────────────────────────── Le contrat

static SpectreDecodage lire(const char *chemin) {
    if (!chemin) { return echec(SPECTRE_DECODAGE_CHEMIN); }
    FILE *epreuve = fopen(chemin, "rb");
    if (!epreuve) { return echec(SPECTRE_DECODAGE_ABSENT); }
    fclose(epreuve);

    int canaux = 0, code = SPECTRE_DECODAGE_OUVERTURE;
    double frequence = 0;
    int64_t images = 0;

    float *echantillons = parSndfile(chemin, &canaux, &frequence, &images, &code);
    if (!echantillons && code != SPECTRE_DECODAGE_MEMOIRE
        && code != SPECTRE_DECODAGE_VIDE) {
        code = SPECTRE_DECODAGE_OUVERTURE;
        echantillons = parMpg123(chemin, &canaux, &frequence, &images, &code);
    }
    if (!echantillons) { return echec(code); }

    SpectreDecodage d = {0};
    d.code = SPECTRE_DECODAGE_OK;
    d.echantillons = echantillons;
    d.canaux = canaux;
    d.frequence = frequence;
    d.images = images;
    return d;
}

SpectreDecodage spectre_decodage_decoder(const char *chemin) {
    SpectreDecodage d = lire(chemin);
    if (d.code != SPECTRE_DECODAGE_OK) { return d; }
    if (d.canaux <= 1) { return d; }

    // ── Le mono, et il se calcule ici ──────────────────────────────────────────
    //
    // Ce que ce contrat rend est **déjà mono** : `images` compte les valeurs, et
    // `canaux` n'est là que pour information. Le faire ici plutôt qu'après évite de
    // garder le signal entrelacé en mémoire, qui est ce qu'il y a de plus gros dans
    // toute l'application.
    //
    // La **moyenne** des canaux, et non leur somme — comme le fait Media Foundation
    // de son côté et `AVAudioFile` sur le Mac. Une somme rendrait un signal deux
    // fois plus fort sur un fichier stéréo dont les deux voies sont identiques, et
    // l'analyse ne donnerait pas la même image sur les trois systèmes.
    const float gain = 1.0f / (float)d.canaux;
    for (int64_t i = 0; i < d.images; ++i) {
        float somme = 0;
        for (int c = 0; c < d.canaux; ++c) {
            somme += d.echantillons[i * d.canaux + c];
        }
        d.echantillons[i] = somme * gain;
    }
    return d;
}

SpectreDecodage spectre_decodage_decoder_entrelace(const char *chemin, double frequence,
                                                   int canaux) {
    SpectreDecodage d = lire(chemin);
    if (d.code != SPECTRE_DECODAGE_OK) { return d; }
    if (canaux <= 0) { canaux = 2; }

    // ── Le rééchantillonnage et le mixage, écrits ici ──────────────────────────
    //
    // Media Foundation les fait tout seul, en insérant son rééchantillonneur. Sous
    // Linux il n'y a rien de tel à demander, et le seul appelant est la séparation :
    // le réseau de Demucs n'a appris qu'à 44,1 kHz en stéréo, et lui donner du
    // 48 kHz reviendrait à lui présenter une musique transposée d'un demi-ton et
    // jouée trop vite.
    //
    // L'interpolation est linéaire, et c'est assez : ce qui entre dans le réseau
    // sort en quatre pistes qu'on réécoute à la même fréquence, et le repliement
    // qu'une interpolation linéaire laisse passer est très en dessous de ce que la
    // séparation elle-même invente. Un rééchantillonneur digne de ce nom aurait sa
    // place dans le noyau, mesuré, et non ici.
    if (d.frequence == frequence && d.canaux == canaux) { return d; }

    double rapport = frequence / d.frequence;
    int64_t imagesSortie = (int64_t)((double)d.images * rapport);
    if (imagesSortie <= 0) {
        free(d.echantillons);
        return echec(SPECTRE_DECODAGE_VIDE);
    }
    float *sortie = malloc((size_t)imagesSortie * (size_t)canaux * sizeof(float));
    if (!sortie) {
        free(d.echantillons);
        return echec(SPECTRE_DECODAGE_MEMOIRE);
    }

    for (int64_t i = 0; i < imagesSortie; ++i) {
        double position = (double)i / rapport;
        int64_t i0 = (int64_t)position;
        int64_t i1 = i0 + 1 < d.images ? i0 + 1 : i0;
        float fraction = (float)(position - (double)i0);
        for (int c = 0; c < canaux; ++c) {
            float valeur;
            if (d.canaux == 1) {
                // Mono vers stéréo : la même chose des deux côtés.
                float a = d.echantillons[i0];
                float b = d.echantillons[i1];
                valeur = a + (b - a) * fraction;
            } else if (canaux == 1) {
                // Vers mono : la moyenne, et non la somme, sinon deux canaux
                // identiques saturent.
                float a = 0, b = 0;
                for (int k = 0; k < d.canaux; ++k) {
                    a += d.echantillons[i0 * d.canaux + k];
                    b += d.echantillons[i1 * d.canaux + k];
                }
                a /= (float)d.canaux;
                b /= (float)d.canaux;
                valeur = a + (b - a) * fraction;
            } else {
                int source = c < d.canaux ? c : d.canaux - 1;
                float a = d.echantillons[i0 * d.canaux + source];
                float b = d.echantillons[i1 * d.canaux + source];
                valeur = a + (b - a) * fraction;
            }
            sortie[i * canaux + c] = valeur;
        }
    }
    free(d.echantillons);

    SpectreDecodage r = {0};
    r.code = SPECTRE_DECODAGE_OK;
    r.echantillons = sortie;
    r.canaux = canaux;
    r.frequence = frequence;
    r.images = imagesSortie;
    return r;
}

void spectre_decodage_liberer(float *echantillons) { free(echantillons); }

const char *spectre_decodage_message(int code) {
    switch (code) {
    case SPECTRE_DECODAGE_OK: return "";
    case SPECTRE_DECODAGE_DEMARRAGE: return "Le décodeur n'a pas démarré.";
    case SPECTRE_DECODAGE_CHEMIN: return "Le chemin du fichier est illisible.";
    case SPECTRE_DECODAGE_OUVERTURE: return "Ce format n'est pas reconnu.";
    case SPECTRE_DECODAGE_FORMAT: return "Le fichier n'a pas de piste audio lisible.";
    case SPECTRE_DECODAGE_LECTURE: return "Le décodage s'est arrêté en chemin.";
    case SPECTRE_DECODAGE_MEMOIRE: return "Mémoire insuffisante pour ce fichier.";
    case SPECTRE_DECODAGE_VIDE: return "Le fichier ne contient aucun son.";
    case SPECTRE_DECODAGE_ABSENT: return "Le fichier est introuvable.";
    default: return "Le décodage a échoué.";
    }
}
