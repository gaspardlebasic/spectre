// Ce que Swift a besoin de voir de SDL3.
//
// SDL n'a pas de module Swift : cet en-tête d'une ligne, plus la carte de module
// qui l'accompagne, suffisent à le rendre importable. Rien de plus n'est
// nécessaire — SDL3 est une API C ordinaire, sans macro qui compte.
#include <SDL3/SDL.h>

// ─────────────────────────────────────────────────────────────────────────────
// LES DRAPEAUX DE FENÊTRE, RENDUS VISIBLES À SWIFT
//
// SDL3 les déclare par des macros — `#define SDL_WINDOW_OPENGL SDL_UINT64_C(2)` —
// et Swift n'importe pas les macros qui portent une conversion. Les redéclarer en
// constantes typées les rend visibles sans rien recopier : c'est la macro de SDL
// qui donne la valeur, et une version future qui la changerait la changerait ici
// aussi.
// ─────────────────────────────────────────────────────────────────────────────
static const SDL_WindowFlags SpectreFenetreOpenGL = SDL_WINDOW_OPENGL;
static const SDL_WindowFlags SpectreFenetreRedimensionnable = SDL_WINDOW_RESIZABLE;
static const SDL_WindowFlags SpectreFenetreDense = SDL_WINDOW_HIGH_PIXEL_DENSITY;
