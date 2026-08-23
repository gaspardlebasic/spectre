// Retrouver le terminal qui nous a lancés.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUE L'ABSENCE DE CONSOLE COÛTE, ET COMMENT ON LA RÉCUPÈRE
//
// L'application est liée en sous-système « fenêtre » (`/SUBSYSTEM:WINDOWS`), sans
// quoi Windows lui ouvre une console noire à chaque lancement — un double-clic sur
// un morceau faisait donc apparaître un terminal vide à côté de la fenêtre, et le
// fermer fermait l'application. C'est le prix normal d'une application graphique,
// et il se paie une fois.
//
// Mais ce sous-système-là coupe aussi la sortie **quand on la voulait** : les
// instruments de ce dépôt — `--photo`, `--fluidite`, `--rendu` — écrivent leur
// relevé sur la sortie ordinaire, et `essai.ps1` le relit. Un programme « fenêtre »
// lancé depuis un terminal n'hérite d'aucune console : `GetStdHandle` rend zéro, et
// tout ce qu'on écrit s'en va nulle part.
//
// `AttachConsole(ATTACH_PARENT_PROCESS)` la récupère. Elle échoue exactement dans
// le cas qu'on veut — lancé par l'Explorateur, le parent n'a pas de console — et
// l'application se tait alors sans qu'aucune fenêtre noire n'apparaisse.
//
// Trois précautions, chacune payée d'un essai :
//
// 1. **Ne rien faire si un flux est déjà branché.** Sous tube ou redirection —
//    `& Spectre.exe … | Out-Null`, `2>$null` — Windows transmet bel et bien les
//    poignées, y compris à un programme « fenêtre ». S'attacher par-dessus
//    remplacerait le tube que le script lit par la console, et le script ne
//    lirait plus rien. Les deux flux sont regardés séparément : `2>$null` n'en
//    redirige qu'un.
// 2. **`freopen` ne suffit pas.** Il rebranche les flux de la bibliothèque C — ce
//    que `print` emploie — mais laisse les poignées du processus à zéro, et c'est
//    d'elles que Foundation tire `FileHandle.standardOutput`, donc `Journal`. Sans
//    le `SetStdHandle` qui suit, la moitié des messages manquerait.
// 3. **Rien de tout cela ne rend le terminal patient.** Un shell n'attend pas un
//    programme « fenêtre » : l'invite revient aussitôt et le relevé s'écrit
//    par-dessus. Les épreuves, elles, redirigent — et une redirection fait
//    attendre PowerShell.
// ─────────────────────────────────────────────────────────────────────────────

#include "pont.h"

#include <windows.h>
#include <stdio.h>
#include <io.h>

/// Rebranche un flux de la bibliothèque C sur la console, et la poignée du
/// processus avec lui.
static void rattacher(DWORD lequel, const char *peripherique, const char *mode,
                      FILE *flux)
{
    HANDLE deja = GetStdHandle(lequel);
    if (deja != NULL && deja != INVALID_HANDLE_VALUE) return;
    if (freopen(peripherique, mode, flux) == NULL) return;
    HANDLE neuve = (HANDLE)_get_osfhandle(_fileno(flux));
    if (neuve != INVALID_HANDLE_VALUE) SetStdHandle(lequel, neuve);
}

int spectre_console_rattacher(void)
{
    HANDLE sortie = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE erreur = GetStdHandle(STD_ERROR_HANDLE);
    int manque = (sortie == NULL || sortie == INVALID_HANDLE_VALUE)
              || (erreur == NULL || erreur == INVALID_HANDLE_VALUE);
    if (!manque) return 0;
    if (!AttachConsole(ATTACH_PARENT_PROCESS)) return 0;

    rattacher(STD_OUTPUT_HANDLE, "CONOUT$", "w", stdout);
    rattacher(STD_ERROR_HANDLE, "CONOUT$", "w", stderr);
    return 1;
}
