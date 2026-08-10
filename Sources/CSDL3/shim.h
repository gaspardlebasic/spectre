// Un seul en-tête à inclure, plutôt que la liste des modules de SDL.
//
// `SDL_MAIN_HANDLED` est indispensable : sans lui SDL redéfinit `main` par une
// macro, ce qui n'a aucun sens depuis Swift et casse l'édition de liens sur un
// symbole que rien n'explique.
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
// `SDL.h` n'apporte pas `SDL_SetMainReady` quand on prend `main` en charge
// soi-même : il faut demander cet en-tête explicitement.
#include <SDL3/SDL_main.h>

// Les drapeaux de fenêtre de SDL3 sont des macros `SDL_UINT64_C(...)`, que Swift
// ne sait pas importer — il les voit « unavailable: structure not supported ».
// On les réexpose en constantes, ce qui est précisément ce à quoi sert un shim :
// ce qui ne traverse pas, on le retranscrit à la main, une fois.
static const Uint64 SPECTRE_WINDOW_OPENGL    = SDL_WINDOW_OPENGL;
static const Uint64 SPECTRE_WINDOW_RESIZABLE = SDL_WINDOW_RESIZABLE;
static const Uint64 SPECTRE_WINDOW_HIDDEN    = SDL_WINDOW_HIDDEN;
