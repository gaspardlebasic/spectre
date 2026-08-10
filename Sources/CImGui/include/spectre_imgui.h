// L'interface de Spectre sous Windows, vue de Swift.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI UNE PASSERELLE ÉCRITE À LA MAIN
//
// Dear ImGui est du C++, que Swift ne sait pas importer. Le pont habituel est
// `cimgui` : vingt mille lignes engendrées qui exposent l'API entière. Ici on
// prend l'autre parti — une trentaine de fonctions écrites à la main, celles
// dont Spectre se sert et pas une de plus.
//
// Ce que cela coûte : ajouter un réglage demande de toucher ce fichier et son
// pendant en C++. Ce que cela rapporte : un en-tête qu'on lit d'un trait, pas de
// générateur dans la chaîne de construction, pas de version à faire coïncider
// entre trois dépôts, et des noms qui parlent du logiciel plutôt que de la
// bibliothèque — `spectre_ui_reglette` plutôt que `igSliderFloatEx`.
//
// La règle du pont : **rien de C++ ne traverse**. Pas de pointeur d'objet, pas
// de structure d'ImGui, pas de chaîne à libérer. Des `float`, des `int`, des
// `const char *` et des booléens en `int`.
// ─────────────────────────────────────────────────────────────────────────────
#ifndef SPECTRE_IMGUI_H
#define SPECTRE_IMGUI_H

#ifdef __cplusplus
extern "C" {
#endif

/// `fenetre` et `contexte` sont un `SDL_Window *` et un `SDL_GLContext` ; ils
/// traversent en `void *` pour que cet en-tête n'ait pas à connaître SDL.
int  spectre_ui_demarrer(void *fenetre, void *contexte, float echelle);
void spectre_ui_arreter(void);

/// À appeler pour chaque évènement SDL, avant de le traiter soi-même. Rend 1 si
/// l'interface l'a consommé — auquel cas le spectrogramme doit l'ignorer, sinon
/// un clic sur un bouton déplacerait aussi la tête de lecture.
int  spectre_ui_evenement(const void *evenement);

void spectre_ui_nouvelle_image(void);
void spectre_ui_dessiner(void);

/// Vrai quand la souris ou le clavier appartiennent à l'interface.
int  spectre_ui_veut_souris(void);
int  spectre_ui_veut_clavier(void);

// ─────────────────────────────────────────────────────────────── les éléments

/// Une barre ancrée en haut de la fenêtre, sur toute sa largeur.
int  spectre_ui_barre_debut(const char *titre, float largeur, float hauteur);
void spectre_ui_barre_fin(void);

/// Un panneau ordinaire, que l'on peut déplacer et replier.
int  spectre_ui_panneau_debut(const char *titre, float x, float y, float largeur);
void spectre_ui_panneau_fin(void);

void spectre_ui_texte(const char *texte);
/// Texte grisé : ce qui informe sans appeler l'action.
void spectre_ui_texte_faible(const char *texte);
void spectre_ui_meme_ligne(void);
void spectre_ui_separateur(void);
void spectre_ui_espace(void);

int  spectre_ui_bouton(const char *titre, float largeur);
/// Un bouton qui reste enfoncé : `actif` dit s'il l'est, le retour dit s'il
/// vient d'être cliqué.
int  spectre_ui_bouton_bascule(const char *titre, int actif, float largeur);
int  spectre_ui_case(const char *titre, int *actif);

/// Rend 1 quand la valeur a changé. `format` est un format d'affichage à la
/// `printf`, par exemple « %.1f dB ».
int  spectre_ui_reglette(const char *titre, float *valeur, float mini, float maxi,
                         const char *format, float largeur);
/// Une liste déroulante. `articles` sont séparés par des `\0`, terminés par deux.
int  spectre_ui_liste(const char *titre, int *choix, const char *articles, float largeur);

/// Hauteur qu'occupe la barre dessinée à la dernière image, pour que le
/// spectrogramme sache où commencer.
float spectre_ui_hauteur_barre(void);

/// Sommets dessinés à la dernière image.
///
/// C'est un instrument de vérification, pas une commodité : le portage se fait
/// depuis un Mac, et la machine qui compile n'a pas de bureau. Ce nombre, écrit
/// dans le journal, dit qu'une interface a été *réellement* produite — pas
/// seulement qu'aucune fonction n'a échoué.
int spectre_ui_sommets(void);

#ifdef __cplusplus
}
#endif

#endif
