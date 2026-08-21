// La file principale, vidée à la main.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE PIÈGE QUI FAIT UNE FENÊTRE NOIRE
//
// Tout le modèle rend ses résultats par `DispatchQueue.main.async` : l'ouverture
// d'un fichier, l'avancement de l'analyse, le relevé des accords, la séparation.
// Sur macOS, la boucle d'évènements d'AppKit vide cette file à chaque tour, et
// personne n'a jamais à y penser.
//
// **Une boucle de messages Win32 ne la vide pas.** Le travail de fond se termine,
// dépose son bloc, et ce bloc n'est jamais exécuté : le fichier est décodé, la
// matrice est calculée, et la fenêtre reste noire — sans une erreur, sans un
// message, avec toute la mémoire consommée pour rien. C'est exactement la panne
// qu'on cherche pendant deux jours en accusant le nuanceur.
//
// libdispatch expose de quoi s'en sortir, sous les noms qu'il donne à son
// intégration avec CoreFoundation. Ils ne sont dans aucun en-tête public de la
// distribution Windows, mais ils sont bel et bien exportés par `dispatch.lib` —
// vérifié au `dumpbin`. On les déclare donc ici :
//
//   `_dispatch_get_main_queue_handle_4CF` rend un objet qui se signale quand la
//   file a du travail, ce dont on n'a pas besoin : la boucle de rendu tourne déjà
//   à la cadence de l'écran, et un bloc déposé est exécuté dans les seize
//   millisecondes qui suivent.
//
//   `_dispatch_main_queue_callback_4CF` l'exécute. C'est le seul appel dont ce
//   portage a besoin, et il tient dans la ligne ci-dessous.
// ─────────────────────────────────────────────────────────────────────────────

#include "pont.h"

extern void _dispatch_main_queue_callback_4CF(void *inutilise);

void spectre_vider_la_file_principale(void) {
    _dispatch_main_queue_callback_4CF(0);
}
