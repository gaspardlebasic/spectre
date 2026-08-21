// La sortie audio, par WASAPI en mode partagé.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI PAS MINIAUDIO
//
// La pile annonçait miniaudio, et c'était un choix raisonnable : une seule
// bibliothèque pour Windows et pour Linux. Elle se paie en un en-tête de deux
// mégaoctets à verser dans le dépôt, à construire et à distribuer.
//
// Or ce dépôt a déjà tranché cette question deux fois dans l'autre sens — la FFT
// écrite à la main plutôt que PFFFT, les demi-flottants écrits à la main plutôt
// que `Float16` — et une troisième fois pour la fenêtre, où SDL3 a été écarté au
// motif qu'un intermédiaire coûte ce qui fait le portage. Le chemin de rendu de
// WASAPI en mode partagé tient dans ce fichier, sans dépendance, et la décision
// pour Linux reste entière : ALSA ou miniaudio, le jour venu, derrière la même
// poignée de fonctions.
//
// ─────────────────────────────────────────────────────────────────────────────
// CADENCÉ PAR ÉVÈNEMENT, ET SUR UN FIL À SOI
//
// WASAPI se pilote de deux façons. Par sondage — on regarde régulièrement s'il
// reste de la place — ce qui oblige à choisir une période d'attente, toujours trop
// longue ou trop courte. Ou par évènement : le périphérique signale lui-même
// quand il veut la suite, et le fil dort le reste du temps. C'est le second, et
// c'est ce qui donne une latence basse sans brûler un cœur.
//
// Le fil est monté en priorité par le service MMCSS, sous la tâche « Pro Audio » :
// sans cela, un ramassage de mémoire ou une compilation en tâche de fond suffit à
// faire craquer le son.
// ─────────────────────────────────────────────────────────────────────────────

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pont.h"

// Les identifiants de WASAPI, posés ici.
//
// Les en-têtes du SDK les *déclarent* — `EXTERN_C const IID IID_IAudioClient;` —
// mais rien ne les définit du côté C : ni `uuid.lib`, ni `ole32.lib`. En C++ le
// compilateur les tire de `__uuidof`, qui n'existe pas ici. Les écrire à la main
// est la façon dont tout programme C qui touche à WASAPI s'en sort, et elle ne
// risque rien : un identifiant faux ne compile pas de travers, il fait échouer
// l'ouverture avec `E_NOINTERFACE`, ce qui se voit au premier essai.
//
// C'est aussi pourquoi `INITGUID` est là : sans lui, `DEFINE_GUID` déclarerait au
// lieu de définir, et l'on n'aurait rien réglé.
DEFINE_GUID(CLSID_MMDeviceEnumerator,
            0xBCDE0395, 0xE52F, 0x467C, 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E);
DEFINE_GUID(IID_IMMDeviceEnumerator,
            0xA95664D2, 0x9614, 0x4F35, 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6);
DEFINE_GUID(IID_IAudioClient,
            0x1CB9AD4C, 0xDBFA, 0x4C32, 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2);
DEFINE_GUID(IID_IAudioRenderClient,
            0xF294ACFC, 0x3146, 0x4483, 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2);
DEFINE_GUID(KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
            0x00000003, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71);

struct SpectreSortie {
    IMMDeviceEnumerator *enumerateur;
    IMMDevice *peripherique;
    IAudioClient *client;
    IAudioRenderClient *rendu;
    HANDLE evenement;
    HANDLE fil;
    WAVEFORMATEX *format;

    SpectreRemplir remplir;
    void *contexte;

    double frequence;
    int canaux;
    UINT32 tampon;                  // taille du tampon du périphérique, en images

    volatile LONG joue;
    volatile LONG arret;
    volatile LONG enVol;            // images remises et pas encore entendues
};

static void noter(char *erreur, const char *format, ...) {
    if (!erreur) { return; }
    va_list args;
    va_start(args, format);
    vsnprintf(erreur, SPECTRE_ERREUR_MAX, format, args);
    va_end(args);
}

// ─────────────────────────────────────────────────────────── Le fil de rendu

static DWORD WINAPI filDeRendu(LPVOID parametre) {
    SpectreSortie *s = (SpectreSortie *)parametre;

    // Le fil audio a son propre cloisonnement COM : les interfaces sont utilisées
    // ici, elles doivent donc y être valides. `RPC_E_CHANGED_MODE` n'est pas une
    // panne — le fil est déjà initialisé autrement, et WASAPI s'en accommode.
    HRESULT hrCo = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int fermerCom = SUCCEEDED(hrCo);

    DWORD tache = 0;
    HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &tache);

    const int canaux = s->canaux;

    while (!InterlockedCompareExchange(&s->arret, 0, 0)) {
        // Deux fois la durée du tampon : au-delà, le périphérique a disparu — carte
        // débranchée, session audio reprise — et mieux vaut rendre la main que
        // dormir pour toujours.
        DWORD attendu = WaitForSingleObject(s->evenement, 2000);
        if (attendu != WAIT_OBJECT_0) { continue; }
        if (InterlockedCompareExchange(&s->arret, 0, 0)) { break; }

        UINT32 occupe = 0;
        if (FAILED(IAudioClient_GetCurrentPadding(s->client, &occupe))) { continue; }
        UINT32 libre = s->tampon - occupe;
        if (libre == 0) { continue; }

        BYTE *octets = NULL;
        if (FAILED(IAudioRenderClient_GetBuffer(s->rendu, libre, &octets))) { continue; }

        int produites = 0;
        if (InterlockedCompareExchange(&s->joue, 0, 0)) {
            produites = s->remplir((float *)octets, (int)libre, canaux, s->contexte);
            if (produites < 0) { produites = 0; }
            if (produites > (int)libre) { produites = (int)libre; }
        }
        // Ce qui n'a pas été rempli est mis à zéro plutôt que laissé tel quel : un
        // tampon rendu par WASAPI porte encore ce qu'on y avait écrit au tour
        // précédent, et le rejouer s'entend comme un bégaiement.
        if (produites < (int)libre) {
            memset((float *)octets + (size_t)produites * (size_t)canaux, 0,
                   (size_t)((int)libre - produites) * (size_t)canaux * sizeof(float));
        }
        IAudioRenderClient_ReleaseBuffer(s->rendu, libre, 0);

        InterlockedExchange(&s->enVol, (LONG)(occupe + libre));
    }

    if (mmcss) { AvRevertMmThreadCharacteristics(mmcss); }
    if (fermerCom) { CoUninitialize(); }
    return 0;
}

// ─────────────────────────────────────────────────────────── L'ouverture

SpectreSortie *spectre_sortie_ouvrir(double frequence, SpectreRemplir remplir,
                                     void *contexte, char *erreur) {
    if (!remplir || frequence < 1) {
        noter(erreur, "Sortie audio : paramètres absurdes.");
        return NULL;
    }

    SpectreSortie *s = calloc(1, sizeof(SpectreSortie));
    if (!s) { noter(erreur, "Mémoire insuffisante."); return NULL; }
    s->remplir = remplir;
    s->contexte = contexte;

    HRESULT hrCo = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int fermerCom = SUCCEEDED(hrCo);

    HRESULT hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                  &IID_IMMDeviceEnumerator, (void **)&s->enumerateur);
    if (SUCCEEDED(hr)) {
        // `eConsole` et non `eMultimedia` : c'est le périphérique que Windows
        // considère comme celui de l'utilisateur, celui que le mélangeur montre.
        hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(s->enumerateur, eRender,
                                                         eConsole, &s->peripherique);
    }
    if (FAILED(hr)) {
        noter(erreur, "Aucun périphérique de sortie (0x%08lX).", (unsigned long)hr);
        goto echec;
    }

    hr = IMMDevice_Activate(s->peripherique, &IID_IAudioClient, CLSCTX_ALL, NULL,
                            (void **)&s->client);
    if (FAILED(hr)) {
        noter(erreur, "Le périphérique de sortie a refusé de s'ouvrir (0x%08lX).",
              (unsigned long)hr);
        goto echec;
    }

    WAVEFORMATEX *melange = NULL;
    hr = IAudioClient_GetMixFormat(s->client, &melange);
    if (FAILED(hr) || !melange) {
        noter(erreur, "Format du périphérique illisible (0x%08lX).", (unsigned long)hr);
        goto echec;
    }

    // On demande le format du périphérique, mais à **la fréquence du fichier**.
    // `AUTOCONVERTPCM` fait insérer par Windows son propre rééchantillonneur : de
    // qualité, entretenu, et surtout il évite de faire porter à la chaîne de
    // lecture une fréquence qui n'est pas celle du fichier — toute la position de
    // lecture est comptée en images du fichier, et un rééchantillonnage en amont
    // la décalerait.
    melange->nSamplesPerSec = (DWORD)(frequence + 0.5);
    melange->nBlockAlign = (WORD)(melange->nChannels * melange->wBitsPerSample / 8);
    melange->nAvgBytesPerSec = melange->nSamplesPerSec * melange->nBlockAlign;
    if (melange->wFormatTag == WAVE_FORMAT_EXTENSIBLE && melange->cbSize >= 22) {
        WAVEFORMATEXTENSIBLE *etendu = (WAVEFORMATEXTENSIBLE *)melange;
        etendu->Samples.wValidBitsPerSample = melange->wBitsPerSample;
    }
    s->format = melange;

    // Trente millisecondes : assez pour qu'un pic de charge ne s'entende pas, assez
    // peu pour que la barre d'espace paraisse immédiate. En mode partagé cadencé
    // par évènement, Windows arrondit de toute façon à sa propre période.
    const REFERENCE_TIME duree = 30 * 10000;
    DWORD drapeaux = AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                   | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                   | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    hr = IAudioClient_Initialize(s->client, AUDCLNT_SHAREMODE_SHARED, drapeaux,
                                 duree, 0, s->format, NULL);
    if (FAILED(hr)) {
        noter(erreur, "Flux de sortie refusé à %.0f Hz (0x%08lX).",
              frequence, (unsigned long)hr);
        goto echec;
    }

    // Le format est flottant sur toute installation de Windows moderne, et le mode
    // partagé n'en sort pas. On le dit tout de même : un format entier rendrait un
    // bruit blanc, et chercher pourquoi coûterait une soirée.
    int estFlottant = 0;
    if (s->format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        estFlottant = 1;
    } else if (s->format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        WAVEFORMATEXTENSIBLE *etendu = (WAVEFORMATEXTENSIBLE *)s->format;
        estFlottant = IsEqualGUID(&etendu->SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    if (!estFlottant || s->format->wBitsPerSample != 32) {
        noter(erreur, "Le périphérique ne veut pas de flottant 32 bits "
                      "(%d bits) — ce chemin ne sait pas convertir.",
              (int)s->format->wBitsPerSample);
        goto echec;
    }

    s->frequence = (double)s->format->nSamplesPerSec;
    s->canaux = (int)s->format->nChannels;

    hr = IAudioClient_GetBufferSize(s->client, &s->tampon);
    if (SUCCEEDED(hr)) {
        hr = IAudioClient_GetService(s->client, &IID_IAudioRenderClient,
                                     (void **)&s->rendu);
    }
    if (FAILED(hr)) {
        noter(erreur, "Service de rendu indisponible (0x%08lX).", (unsigned long)hr);
        goto echec;
    }

    s->evenement = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!s->evenement) {
        noter(erreur, "Évènement de cadencement impossible.");
        goto echec;
    }
    hr = IAudioClient_SetEventHandle(s->client, s->evenement);
    if (FAILED(hr)) {
        noter(erreur, "Cadencement par évènement refusé (0x%08lX).", (unsigned long)hr);
        goto echec;
    }

    // Le flux tourne dès maintenant, et rend du silence tant que `joue` est faux.
    // Démarrer et arrêter le client à chaque pause coûterait une réamorce que l'on
    // entend, et ferait perdre le premier tampon après chaque reprise.
    hr = IAudioClient_Start(s->client);
    if (FAILED(hr)) {
        noter(erreur, "Le flux n'a pas démarré (0x%08lX).", (unsigned long)hr);
        goto echec;
    }

    s->fil = CreateThread(NULL, 0, filDeRendu, s, 0, NULL);
    if (!s->fil) {
        noter(erreur, "Fil de rendu impossible à lancer.");
        goto echec;
    }

    if (fermerCom) { CoUninitialize(); }
    return s;

echec:
    if (fermerCom) { CoUninitialize(); }
    spectre_sortie_fermer(s);
    return NULL;
}

void spectre_sortie_fermer(SpectreSortie *s) {
    if (!s) { return; }
    if (s->fil) {
        InterlockedExchange(&s->arret, 1);
        // On réveille le fil plutôt que d'attendre son échéance : sans cela, fermer
        // coûterait jusqu'à deux secondes, ce qui se voit à la fermeture de la
        // fenêtre.
        if (s->evenement) { SetEvent(s->evenement); }
        WaitForSingleObject(s->fil, 3000);
        CloseHandle(s->fil);
    }
    if (s->client) { IAudioClient_Stop(s->client); }
    if (s->rendu) { IAudioRenderClient_Release(s->rendu); }
    if (s->client) { IAudioClient_Release(s->client); }
    if (s->peripherique) { IMMDevice_Release(s->peripherique); }
    if (s->enumerateur) { IMMDeviceEnumerator_Release(s->enumerateur); }
    if (s->evenement) { CloseHandle(s->evenement); }
    if (s->format) { CoTaskMemFree(s->format); }
    free(s);
}

double spectre_sortie_frequence(const SpectreSortie *s) { return s ? s->frequence : 0; }
int spectre_sortie_canaux(const SpectreSortie *s) { return s ? s->canaux : 0; }

void spectre_sortie_jouer(SpectreSortie *s) {
    if (s) { InterlockedExchange(&s->joue, 1); }
}

void spectre_sortie_pause(SpectreSortie *s) {
    if (s) { InterlockedExchange(&s->joue, 0); }
}

int spectre_sortie_joue(const SpectreSortie *s) {
    return s ? (int)InterlockedCompareExchange((volatile LONG *)&s->joue, 0, 0) : 0;
}

int spectre_sortie_en_vol(const SpectreSortie *s) {
    return s ? (int)InterlockedCompareExchange((volatile LONG *)&s->enVol, 0, 0) : 0;
}
