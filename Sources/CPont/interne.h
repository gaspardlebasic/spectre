// Ce que les fichiers du pont se partagent, et que Swift ne voit jamais.
//
// `SpectreRendu` est opaque de l'autre côté de la frontière — c'est tout l'intérêt
// du pont. Mais `d3d11.c` et `direct2d.c` dessinent tous deux dans la **même**
// chaîne d'échange : le spectrogramme d'abord, le texte et les traits par-dessus.
// Il leur faut donc une définition commune, et elle est ici plutôt que dupliquée.
//
// Ce fichier n'est pas dans `include/` : SwiftPM y expose ce qui est public, et
// tout ce qui inclut Direct3D doit rester hors de portée de Swift.

#ifndef SPECTRE_INTERNE_H
#define SPECTRE_INTERNE_H

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <d2d1_1.h>

// ─────────────────────────────────────────────────────────────────────────────
// DIRECTWRITE N'A PAS DE CHEMIN C, ET C'EST LE SEUL
//
// `d3d11.h`, `dxgi.h` et `d2d1.h` portent tous une version C de leurs interfaces,
// que `COBJMACROS` rend utilisable. **`dwrite.h` n'en a pas** : il déclare ses
// interfaces en C++ sans condition, avec des méthodes surchargées et des
// `static_cast`. L'inclure depuis un fichier C produit une centaine d'erreurs qui
// désignent l'en-tête de Microsoft, ce qui fait chercher du côté du SDK.
//
// D'où le partage : `direct2d.cpp` est compilé en C++ et voit le vrai en-tête ;
// `d3d11.c` reste en C et ne voit que des types déclarés, ce qui lui suffit — il
// ne fait que les porter dans la structure et les libérer par le pont.
// ─────────────────────────────────────────────────────────────────────────────
#ifdef __cplusplus
#include <dwrite.h>
#else
typedef struct IDWriteFactory IDWriteFactory;
typedef struct IDWriteTextFormat IDWriteTextFormat;
#endif

#include "pont.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Combien de polices le pont connaît. Voir `spectre_surimpression_texte`.
#define SPECTRE_POLICES 2

/// Combien de couples (police, taille) sont gardés sous la main.
///
/// Un seul format par police suffisait tant que la surimpression n'était faite que
/// de la réglette et de la barre. Le panneau des réglages emploie six tailles
/// mêlées — intitulés, valeurs, explications — et un format par police faisait alors
/// chercher une fonte à chaque changement de taille, soit des dizaines de fois par
/// image. Douze couples couvrent tout ce que l'interface demande.
#define SPECTRE_FORMATS 12

struct SpectreRendu {
    ID3D11Device *appareil;
    ID3D11DeviceContext *contexte;
    IDXGISwapChain2 *chaine;             // NULL hors écran
    HANDLE attente;                      // objet d'attente de la chaîne
    ID3D11RenderTargetView *cible;
    ID3D11Texture2D *cibleHorsEcran;     // NULL à l'écran
    ID3D11Texture2D *relecture;
    ID3D11VertexShader *sommets;
    ID3D11PixelShader *fragments;
    ID3D11Buffer *constantes;
    ID3D11RasterizerState *rasteriseur;
    ID3D11ShaderResourceView *tuiles;
    ID3D11ShaderResourceView *palette;
    int largeur, hauteur;
    /// Zone que le nuanceur occupe, en pixels. Zéro veut dire « toute la fenêtre ».
    /// La ligne de batterie prend la bande du dessous.
    int zoneLargeur, zoneHauteur;
    char carte[128];

    // La surimpression. Nulle tant que `spectre_surimpression_preparer` n'a pas
    // été appelé, et refaite à chaque redimensionnement.
    ID2D1Factory1 *fabriqueD2D;
    ID2D1Device *appareilD2D;
    ID2D1DeviceContext *contexteD2D;
    ID2D1Bitmap1 *surfaceD2D;
    ID2D1SolidColorBrush *pinceau;
    ID2D1StrokeStyle *pointille;
    IDWriteFactory *fabriqueTexte;
    IDWriteTextFormat *formats[SPECTRE_FORMATS];
    float tailleDesFormats[SPECTRE_FORMATS];
    int policeDesFormats[SPECTRE_FORMATS];
    int prochainFormat;
    float echelle;
    int dessinEnCours;
    /// Combien de découpes sont empilées, pour n'en dépiler que ce qui a été posé :
    /// Direct2D abandonne le dessin entier si les deux nombres ne s'accordent pas.
    int decoupes;
};

/// Défait la surface Direct2D avant que la chaîne se redimensionne, et la refait
/// après. Appelé par `d3d11.c`, écrit dans `direct2d.c`.
void spectre_surimpression_lacher(SpectreRendu *rendu);
void spectre_surimpression_reprendre(SpectreRendu *rendu);

/// Libère ce que la surimpression garde en propre. Appelé depuis `d3d11.c`, qui
/// n'a pas le droit de toucher aux interfaces DirectWrite — il ne les voit que
/// déclarées.
void spectre_surimpression_detruire(SpectreRendu *rendu);

#ifdef __cplusplus
}
#endif

#endif
