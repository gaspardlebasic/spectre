// ONNX Runtime, vu de Swift : ouvrir un réseau, lui donner une tranche, la reprendre.
//
// ─────────────────────────────────────────────────────────────────────────────
// LA BIBLIOTHÈQUE EST CHARGÉE À L'EXÉCUTION, ET C'EST LE POINT
//
// `onnxruntime.lib` est une bibliothèque d'importation : s'y lier ferait refuser le
// démarrage de l'exécutable quand la DLL n'est pas là — pas « la séparation est
// absente », mais « SpectreWindows.exe ne s'ouvre pas », avec le code 0xC0000135 et
// sans un mot. Or seize mégaoctets de moteur d'inférence n'ont rien à faire dans un
// dépôt, et l'intégration continue compile sans les avoir téléchargés.
//
// `LoadLibraryW` puis un seul `GetProcAddress` règlent les deux d'un coup : rien à
// l'édition de liens, l'application s'ouvre toujours, et la séparation s'annonce
// absente exactement comme elle le fait sur un Mac dont les poids ne sont pas
// installés — un chemin déjà éprouvé.
//
// L'en-tête, lui, est nécessaire à la compilation : `OrtApi` est une structure d'une
// centaine de pointeurs de fonction dont l'ordre fait tout, et la redéclarer à la
// main serait se lier à une version d'ONNX Runtime sans le dire. Sans en-tête, ce
// fichier se réduit donc aux souches ci-dessous, et l'application dit que la
// séparation n'est pas installée.
// ─────────────────────────────────────────────────────────────────────────────

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "pont.h"

#ifdef SPECTRE_ONNX

#include <onnxruntime_c_api.h>

struct SpectreReseau {
    HMODULE bibliotheque;
    const OrtApi *api;
    OrtEnv *environnement;
    OrtSession *session;
    OrtMemoryInfo *memoire;
};

static void dire(char *erreur, const char *quoi) {
    if (erreur) { snprintf(erreur, SPECTRE_ERREUR_MAX, "%s", quoi); }
}

/// Reprend le message d'ONNX Runtime **et libère son objet d'erreur**.
///
/// Chaque `OrtStatus` non nul est une allocation dont l'appelant hérite : les
/// oublier laisse fuir un message par tranche, soit une par 5,8 secondes de musique.
static int echoue(struct SpectreReseau *r, OrtStatus *statut, char *erreur,
                  const char *contexte) {
    if (!statut) { return 0; }
    if (erreur) {
        snprintf(erreur, SPECTRE_ERREUR_MAX, "%s : %s", contexte,
                 r->api->GetErrorMessage(statut));
    }
    r->api->ReleaseStatus(statut);
    return 1;
}

SpectreReseau *spectre_reseau_ouvrir(const uint16_t *chemin,
                                     const uint16_t *bibliotheque, char *erreur) {
    if (!chemin || !bibliotheque) { dire(erreur, "chemin manquant."); return NULL; }

    // `LOAD_WITH_ALTERED_SEARCH_PATH` : la DLL est désignée par un chemin absolu, et
    // ce drapeau fait chercher ses propres dépendances **à côté d'elle** plutôt que
    // dans le dossier de l'exécutable. Sans lui, `onnxruntime_providers_shared.dll`
    // n'est pas trouvée quand le moteur est rangé ailleurs que l'application.
    HMODULE module = LoadLibraryExW((LPCWSTR)bibliotheque, NULL,
                                    LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module) {
        snprintf(erreur, SPECTRE_ERREUR_MAX,
                 "onnxruntime.dll n'a pas pu être chargée (erreur %lu).",
                 (unsigned long)GetLastError());
        return NULL;
    }

    typedef const OrtApiBase *(ORT_API_CALL *Base)(void);
    Base base = (Base)(void *)GetProcAddress(module, "OrtGetApiBase");
    if (!base) {
        FreeLibrary(module);
        dire(erreur, "cette onnxruntime.dll n'expose pas OrtGetApiBase.");
        return NULL;
    }
    const OrtApi *api = base()->GetApi(ORT_API_VERSION);
    if (!api) {
        FreeLibrary(module);
        // Le seul cas où cela arrive : une DLL plus ancienne que l'en-tête avec
        // lequel on a compilé. Le dire ainsi évite de chercher du côté du modèle.
        snprintf(erreur, SPECTRE_ERREUR_MAX,
                 "onnxruntime.dll est trop ancienne (API %d demandée).", ORT_API_VERSION);
        return NULL;
    }

    struct SpectreReseau *r = (struct SpectreReseau *)calloc(1, sizeof(struct SpectreReseau));
    if (!r) { FreeLibrary(module); dire(erreur, "mémoire insuffisante."); return NULL; }
    r->bibliotheque = module;
    r->api = api;

    OrtSessionOptions *options = NULL;
    if (echoue(r, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "spectre", &r->environnement),
               erreur, "environnement")
        || echoue(r, api->CreateSessionOptions(&options), erreur, "options")) {
        spectre_reseau_fermer(r);
        return NULL;
    }
    // Le graphe est figé et ne change pas d'une tranche à l'autre : toutes les
    // optimisations valent la peine d'être faites une fois.
    api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL);

    OrtStatus *statut = api->CreateSession(r->environnement, (const ORTCHAR_T *)chemin,
                                           options, &r->session);
    api->ReleaseSessionOptions(options);
    if (echoue(r, statut, erreur, "ouverture du réseau")) {
        spectre_reseau_fermer(r);
        return NULL;
    }
    if (echoue(r, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &r->memoire),
               erreur, "mémoire")) {
        spectre_reseau_fermer(r);
        return NULL;
    }
    return r;
}

void spectre_reseau_fermer(SpectreReseau *r) {
    if (!r) { return; }
    if (r->api) {
        if (r->memoire) { r->api->ReleaseMemoryInfo(r->memoire); }
        if (r->session) { r->api->ReleaseSession(r->session); }
        if (r->environnement) { r->api->ReleaseEnv(r->environnement); }
    }
    if (r->bibliotheque) { FreeLibrary(r->bibliotheque); }
    free(r);
}

/// Recopie un tenseur de sortie, après avoir vérifié qu'il a la taille attendue.
///
/// La vérification n'est pas une politesse : un modèle qui n'est pas celui qu'on
/// croit rend des tenseurs plus petits, et recopier sans compter lirait au-delà —
/// ce qui, en release, ne se voit qu'à l'endroit où l'on ne cherche pas.
static int reprendre(struct SpectreReseau *r, OrtValue *valeur, float *sortie,
                     size_t attendus, char *erreur, const char *nom) {
    OrtTensorTypeAndShapeInfo *forme = NULL;
    if (echoue(r, r->api->GetTensorTypeAndShape(valeur, &forme), erreur, nom)) { return 0; }
    size_t nombre = 0;
    OrtStatus *statut = r->api->GetTensorShapeElementCount(forme, &nombre);
    r->api->ReleaseTensorTypeAndShapeInfo(forme);
    if (echoue(r, statut, erreur, nom)) { return 0; }
    if (nombre < attendus) {
        snprintf(erreur, SPECTRE_ERREUR_MAX,
                 "« %s » rend %zu valeurs, %zu attendues.", nom, nombre, attendus);
        return 0;
    }
    float *donnees = NULL;
    if (echoue(r, r->api->GetTensorMutableData(valeur, (void **)&donnees), erreur, nom)) {
        return 0;
    }
    memcpy(sortie, donnees, attendus * sizeof(float));
    return 1;
}

int spectre_reseau_appliquer(SpectreReseau *r, const float *mix, const float *spec,
                             int canaux, int segment, int raies, int trames,
                             float *zout, float *xt, char *erreur) {
    if (!r || !r->session) { dire(erreur, "réseau non ouvert."); return 0; }

    const int64_t formeMix[3] = { 1, canaux, segment };
    const int64_t formeSpec[5] = { 1, canaux, raies, trames, 2 };
    const size_t nMix = (size_t)canaux * (size_t)segment;
    const size_t nSpec = nMix ? (size_t)canaux * (size_t)raies * (size_t)trames * 2 : 0;
    // Quatre sources, deux canaux : les huit voies que le réseau rend d'un coup.
    const size_t voies = 4 * (size_t)canaux;
    const size_t nZ = voies * (size_t)raies * (size_t)trames * 2;
    const size_t nX = voies * (size_t)segment;

    OrtValue *entrees[2] = { NULL, NULL };
    OrtValue *sorties[2] = { NULL, NULL };
    const char *nomsEntrees[2] = { "mix", "spec" };
    const char *nomsSorties[2] = { "zout", "xt" };
    int bon = 0;

    // `CreateTensorWithDataAsOrtValue` **ne recopie pas** : les tampons doivent
    // rester valides jusqu'après `Run`. Ils le sont — ils appartiennent à l'appelant
    // Swift, qui les tient le temps de l'appel.
    if (echoue(r, r->api->CreateTensorWithDataAsOrtValue(
                   r->memoire, (void *)mix, nMix * sizeof(float), formeMix, 3,
                   ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &entrees[0]), erreur, "mix")) {
        goto fin;
    }
    if (echoue(r, r->api->CreateTensorWithDataAsOrtValue(
                   r->memoire, (void *)spec, nSpec * sizeof(float), formeSpec, 5,
                   ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &entrees[1]), erreur, "spec")) {
        goto fin;
    }
    if (echoue(r, r->api->Run(r->session, NULL, nomsEntrees,
                              (const OrtValue *const *)entrees, 2,
                              nomsSorties, 2, sorties), erreur, "exécution")) {
        goto fin;
    }
    if (!sorties[0] || !sorties[1]) { dire(erreur, "le réseau n'a rien rendu."); goto fin; }

    bon = reprendre(r, sorties[0], zout, nZ, erreur, "zout")
       && reprendre(r, sorties[1], xt, nX, erreur, "xt");

fin:
    for (int i = 0; i < 2; ++i) {
        if (sorties[i]) { r->api->ReleaseValue(sorties[i]); }
        if (entrees[i]) { r->api->ReleaseValue(entrees[i]); }
    }
    return bon;
}

int spectre_reseau_disponible(void) { return 1; }

#else   // SPECTRE_ONNX

// Sans les en-têtes d'ONNX Runtime, la séparation n'est pas compilée. Les souches
// restent, et disent la même chose que sur un Mac dont les poids ne sont pas
// installés : la fonction est absente, pas cassée.

SpectreReseau *spectre_reseau_ouvrir(const uint16_t *chemin,
                                     const uint16_t *bibliotheque, char *erreur) {
    (void)chemin; (void)bibliotheque;
    if (erreur) {
        snprintf(erreur, SPECTRE_ERREUR_MAX,
                 "Cette version a été compilée sans ONNX Runtime — lancer .\\onnx.ps1.");
    }
    return NULL;
}

void spectre_reseau_fermer(SpectreReseau *r) { (void)r; }

int spectre_reseau_appliquer(SpectreReseau *r, const float *mix, const float *spec,
                             int canaux, int segment, int raies, int trames,
                             float *zout, float *xt, char *erreur) {
    (void)r; (void)mix; (void)spec; (void)canaux; (void)segment;
    (void)raies; (void)trames; (void)zout; (void)xt;
    if (erreur) { snprintf(erreur, SPECTRE_ERREUR_MAX, "ONNX Runtime absent."); }
    return 0;
}

int spectre_reseau_disponible(void) { return 0; }

#endif  // SPECTRE_ONNX
