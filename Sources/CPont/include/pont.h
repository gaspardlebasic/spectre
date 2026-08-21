// Ce que Swift ne peut pas dire lui-même.
//
// Deux choses y tombent, et elles n'ont en commun que d'être hors de portée : le
// vocabulaire COM de Direct3D 11, qui est fait de macros (`d3d11.c`), et la file
// principale de libdispatch, dont l'appel qui la vide n'est dans aucun en-tête de
// la distribution Windows (`file.c`).
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI LE PONT DIRECT3D EXISTE
//
// Direct3D 11 est une API COM. En C++ on appelle `appareil->CreateTexture2D(…)` ;
// en C, la même chose s'écrit `ID3D11Device_CreateTexture2D(appareil, …)`, et ce
// nom est une **macro** fournie par `d3d11.h` sous `COBJMACROS`. Swift importe les
// fonctions et les types d'un en-tête C, mais pas ses macros : il verrait donc
// des structures de pointeurs de fonctions nues, et chaque appel deviendrait un
// déréférencement de table virtuelle écrit à la main.
//
// D'où ce pont : le vocabulaire COM reste dans `pont.c`, et Swift ne voit qu'une
// dizaine de fonctions à paramètres simples. C'est aussi ce qui permet à ce même
// pont de servir au rendu hors écran de `RenduCheck` sans qu'une seule ligne
// change — la fenêtre n'est qu'un des deux endroits où l'image peut aller.
//
// Rien de Windows n'apparaît ici : `HWND` traverse en `void *`. Un en-tête public
// qui inclurait `windows.h` obligerait Swift à digérer tout le SDK à chaque
// compilation, pour un pointeur.
// ─────────────────────────────────────────────────────────────────────────────

#ifndef SPECTRE_PONT_D3D11_H
#define SPECTRE_PONT_D3D11_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Ce que le nuanceur reçoit à chaque image.
///
/// **Doit rester binairement identique au `cbuffer Uniformes` de
/// `Resources/spectrogramme.hlsl`.** Le tampon de constantes se compte par blocs
/// de seize octets, d'où le remplissage final : sans lui, Direct3D refuse la
/// création du tampon, ce qui est encore le meilleur cas — un champ ajouté d'un
/// seul côté, lui, décale tous les suivants et produit une image plausible.
typedef struct {
    float origineX, origineY;
    float parPixelX, parPixelY;
    float tailleVueX, tailleVueY;
    uint32_t colonnes;
    uint32_t lignes;
    uint32_t hauteurTuile;
    uint32_t pas;
    uint32_t palette;
    float minDb;
    float maxDb;
    float gammaValeur;
    float penteParOctave;
    float log2FminSur1k;
    float lignesParOctave;
    float demiTonLigne0;
    float teteDeLecture;
    float boucleDebut;
    float boucleFin;
    float remplissage[3];
} SpectreUniformes;

typedef struct SpectreRendu SpectreRendu;

/// Longueur du tampon à donner aux fonctions qui rendent un message d'erreur.
///
/// Les erreurs de compilation HLSL sont bavardes, et c'est tant mieux : c'est le
/// seul endroit du portage où le pilote explique ce qu'il n'a pas compris.
#define SPECTRE_ERREUR_MAX 2048

/// Crée le rendu attaché à une fenêtre, avec sa chaîne d'échange.
///
/// `hwnd` est un `HWND`. Rend `NULL` en cas d'échec, et remplit `erreur`.
SpectreRendu *spectre_rendu_creer(void *hwnd, const char *sourceHLSL, char *erreur);

/// Crée le rendu sans fenêtre, vers une cible qu'on relit.
///
/// C'est ce qui permet de mesurer le nuanceur là où personne ne peut regarder
/// l'écran — machine virtuelle comprise, et intégration continue si un jour elle
/// a une carte.
SpectreRendu *spectre_rendu_creer_hors_ecran(int largeur, int hauteur,
                                             const char *sourceHLSL, char *erreur);

void spectre_rendu_detruire(SpectreRendu *rendu);

/// Redimensionne la chaîne d'échange. Sans effet hors écran.
int spectre_rendu_redimensionner(SpectreRendu *rendu, int largeur, int hauteur);

int spectre_rendu_largeur(const SpectreRendu *rendu);
int spectre_rendu_hauteur(const SpectreRendu *rendu);

/// Envoie la matrice, découpée en tuiles empilées.
///
/// Les valeurs sont des **demi-flottants** — `Vector.demiFlottants` les produit —
/// rangés ligne par ligne, une colonne après l'autre.
int spectre_rendu_televerser_tuiles(SpectreRendu *rendu, int lignes, int colonnes,
                                    int hauteurTuile, const uint16_t *valeurs);

/// Envoie la table de la palette « notes », en RGBA huit bits.
int spectre_rendu_televerser_palette(SpectreRendu *rendu, int largeur, int hauteur,
                                     const uint8_t *rgba);

/// Dessine une image. Efface d'abord : une cible jamais écrite s'affiche en blanc
/// sur certains pilotes et en noir sur d'autres, ce qui fait douter du nuanceur.
void spectre_rendu_dessiner(SpectreRendu *rendu, const SpectreUniformes *u);

/// Présente l'image. Sans effet hors écran.
///
/// La chaîne est en modèle *flip* sans attente du balayage : c'est
/// `spectre_rendu_attendre` qui cadence, et lui seul.
int spectre_rendu_presenter(SpectreRendu *rendu);

/// Attend que la carte réclame l'image suivante.
///
/// C'est l'objet d'attente de la chaîne d'échange, et c'est le mécanisme qui garde
/// l'image collée au doigt : on dort **avant** de dessiner plutôt qu'après avoir
/// présenté, si bien que l'image montrée porte l'état le plus frais possible.
void spectre_rendu_attendre(SpectreRendu *rendu);

/// Relit la dernière image dessinée, en RGB huit bits, rangée par rangée depuis le
/// **haut**. `octets` doit tenir largeur × hauteur × 3.
int spectre_rendu_relire(SpectreRendu *rendu, uint8_t *octets);

/// Le nom de la carte, tel que le pilote le donne. Utile au rapport de mesure :
/// une fluidité relevée sans dire sur quoi ne veut rien dire.
void spectre_rendu_nom_de_la_carte(SpectreRendu *rendu, char *nom, int taille);

/// Exécute ce que le travail de fond a déposé sur `DispatchQueue.main`.
///
/// À appeler une fois par tour de boucle. Voir `file.c` : sans cet appel, une
/// boucle de messages Win32 ne vide jamais la file principale, et tout ce que le
/// modèle rend par elle — le fichier ouvert, la matrice analysée, les accords
/// relevés — n'arrive jamais.
void spectre_vider_la_file_principale(void);

#ifdef __cplusplus
}
#endif

#endif
