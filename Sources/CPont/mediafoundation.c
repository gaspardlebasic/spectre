// Media Foundation, vu du C.
//
// Ce fichier revient de l'historique — commit `e690019`, avant que le portage ne
// soit retiré. Il avait été mesuré à l'époque, y compris sur les deux pièges qu'il
// documente plus bas, et le récrire n'aurait fait que rejouer les mêmes
// découvertes. Une seule chose y a changé : un fichier absent et un format inconnu
// échouaient au même endroit et sous le même message, alors que le `HRESULT` les
// distingue et que ce n'est pas la même chose à corriger.
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI CE FICHIER EST EN C ET PAS EN SWIFT
//
// COM n'a pas de représentation naturelle en Swift : chaque interface est un
// pointeur vers une table de méthodes qu'il faudrait appeler à la main, avec les
// `AddRef`/`Release` qui vont avec. `COBJMACROS` donne au C la même chose sous
// forme d'appels ordinaires — `IMFSourceReader_ReadSample(lecteur, …)` — et
// laisse Swift ignorer entièrement que du COM se joue ici.
//
// Le principe de l'enveloppe : **tout ce qui est fragile reste de ce côté**. Une
// seule fonction, un seul aller-retour, un tableau de flottants au bout. Rien
// qui demande à Swift de tenir un compteur de références.
// ─────────────────────────────────────────────────────────────────────────────

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdlib.h>
#include <string.h>

#include "pont.h"

static SpectreDecodage echec(int code, HRESULT hr) {
    SpectreDecodage d;
    d.echantillons = NULL;
    d.images = 0;
    d.frequence = 0;
    d.canaux = 0;
    d.code = code;
    d.resultat = (long)hr;
    return d;
}

const char *spectre_mf_message(int code) {
    switch (code) {
    case SPECTRE_MF_OK:        return "aucune erreur";
    case SPECTRE_MF_DEMARRAGE: return "Media Foundation n'a pas pu démarrer";
    case SPECTRE_MF_CHEMIN:    return "le chemin du fichier est illisible";
    case SPECTRE_MF_OUVERTURE: return "Windows ne sait pas lire ce format";
    case SPECTRE_MF_ABSENT:    return "fichier introuvable";
    case SPECTRE_MF_FORMAT:    return "aucune piste audio décodable dans ce fichier";
    case SPECTRE_MF_LECTURE:   return "le décodage s'est interrompu";
    case SPECTRE_MF_MEMOIRE:   return "mémoire insuffisante";
    case SPECTRE_MF_VIDE:      return "le fichier ne contient aucun son";
    default:                   return "erreur inconnue";
    }
}

void spectre_mf_liberer(float *echantillons) {
    free(echantillons);
}

/// Le décodage, en un seul corps pour ses deux usages.
///
/// `canauxVoulus` à zéro : la fréquence du fichier, et les canaux mêlés par moyenne
/// — ce que l'analyse demande, et ce qui doit rendre exactement le même signal que
/// `AVAudioFile` sur le Mac. Non nul : Media Foundation insère elle-même son
/// rééchantillonneur et sa matrice de mixage, et le signal sort entrelacé à la
/// fréquence demandée — ce que le réseau de Demucs exige, lui qui n'a appris qu'à
/// 44,1 kHz en stéréo.
///
/// Un seul corps parce que les deux ne diffèrent que par deux attributs posés sur le
/// type demandé et par la boucle de recopie. Deux fonctions jumelles auraient
/// divergé sur l'un des pièges documentés ici — l'amorçage, le changement de format
/// en route, la panne en fin de course.
static SpectreDecodage decoder(const char *chemin, UINT32 frequenceVoulue,
                               UINT32 canauxVoulus) {
    // Le chemin arrive en UTF-8 parce que c'est ce que Swift a naturellement
    // sous la main ; Windows le veut en UTF-16.
    int taille = MultiByteToWideChar(CP_UTF8, 0, chemin, -1, NULL, 0);
    if (taille <= 0) { return echec(SPECTRE_MF_CHEMIN, 0); }
    wchar_t *large = (wchar_t *)malloc((size_t)taille * sizeof(wchar_t));
    if (!large) { return echec(SPECTRE_MF_MEMOIRE, 0); }
    MultiByteToWideChar(CP_UTF8, 0, chemin, -1, large, taille);

    // `RPC_E_CHANGED_MODE` veut dire que le fil est déjà initialisé dans l'autre
    // cloisonnement : ce n'est pas une panne, Media Foundation s'en accommode.
    HRESULT hrCo = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int fermerCom = SUCCEEDED(hrCo);

    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    if (FAILED(hr)) {
        free(large);
        if (fermerCom) { CoUninitialize(); }
        return echec(SPECTRE_MF_DEMARRAGE, hr);
    }

    IMFSourceReader *lecteur = NULL;
    hr = MFCreateSourceReaderFromURL(large, NULL, &lecteur);
    free(large);
    if (FAILED(hr)) {
        MFShutdown();
        if (fermerCom) { CoUninitialize(); }
        // Un fichier absent et un format inconnu échouent tous deux ici, et ce
        // n'est pas la même chose pour qui lit le message : l'un se corrige en
        // retrouvant le fichier, l'autre en le convertissant. Le `HRESULT` les
        // distingue, alors autant le dire.
        int quoi = (hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)
                    || hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND))
                 ? SPECTRE_MF_ABSENT : SPECTRE_MF_OUVERTURE;
        return echec(quoi, hr);
    }

    SpectreDecodage sortie = echec(SPECTRE_MF_LECTURE, 0);
    float *tampon = NULL;
    long long remplis = 0, capacite = 0;
    IMFMediaType *voulu = NULL, *obtenu = NULL;

    // On ne décode que l'audio, et on demande du flottant : Media Foundation
    // insère elle-même le convertisseur qu'il faut, ce qui évite d'avoir à
    // traiter ici les entiers 16 et 24 bits que chaque décodeur rend
    // différemment.
    hr = IMFSourceReader_SetStreamSelection(lecteur, (DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (SUCCEEDED(hr)) {
        hr = IMFSourceReader_SetStreamSelection(lecteur,
                (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
    }
    if (SUCCEEDED(hr)) { hr = MFCreateMediaType(&voulu); }
    if (SUCCEEDED(hr)) {
        hr = IMFMediaType_SetGUID(voulu, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    }
    if (SUCCEEDED(hr)) {
        hr = IMFMediaType_SetGUID(voulu, &MF_MT_SUBTYPE, &MFAudioFormat_Float);
    }
    // La forme imposée, quand on en veut une. Les cinq attributs vont ensemble :
    // Media Foundation refuse un type partiel où l'alignement de bloc ne s'accorde
    // pas au nombre de canaux, et le refus arrive sous un `HRESULT` qui ne désigne
    // rien de particulier.
    if (SUCCEEDED(hr) && canauxVoulus > 0) {
        hr = IMFMediaType_SetUINT32(voulu, &MF_MT_AUDIO_NUM_CHANNELS, canauxVoulus);
        if (SUCCEEDED(hr)) {
            hr = IMFMediaType_SetUINT32(voulu, &MF_MT_AUDIO_SAMPLES_PER_SECOND,
                                        frequenceVoulue);
        }
        if (SUCCEEDED(hr)) {
            hr = IMFMediaType_SetUINT32(voulu, &MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
        }
        if (SUCCEEDED(hr)) {
            hr = IMFMediaType_SetUINT32(voulu, &MF_MT_AUDIO_BLOCK_ALIGNMENT,
                                        4 * canauxVoulus);
        }
        if (SUCCEEDED(hr)) {
            hr = IMFMediaType_SetUINT32(voulu, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                        4 * canauxVoulus * frequenceVoulue);
        }
    }
    if (SUCCEEDED(hr)) {
        hr = IMFSourceReader_SetCurrentMediaType(lecteur,
                (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, voulu);
    }
    if (FAILED(hr)) {
        sortie = echec(SPECTRE_MF_FORMAT, hr);
        goto fin;
    }

    // Le format effectif : le fichier décide de sa fréquence et de son nombre de
    // canaux, on ne les impose pas. Rééchantillonner ici ferait perdre de la
    // matière avant même l'analyse.
    hr = IMFSourceReader_GetCurrentMediaType(lecteur,
            (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, &obtenu);
    UINT32 canaux = 0, frequence = 0;
    if (SUCCEEDED(hr)) {
        IMFMediaType_GetUINT32(obtenu, &MF_MT_AUDIO_NUM_CHANNELS, &canaux);
        IMFMediaType_GetUINT32(obtenu, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &frequence);
    }
    if (FAILED(hr) || canaux == 0 || frequence == 0) {
        sortie = echec(SPECTRE_MF_FORMAT, hr);
        goto fin;
    }
    // Ce qu'on a demandé n'est pas toujours ce qu'on obtient — un décodeur peut
    // refuser une conversion sans le dire par un `HRESULT`. Le vérifier ici évite de
    // séparer un morceau à la mauvaise fréquence, ce qui donnerait des pistes
    // transposées sans que rien ne signale pourquoi.
    if (canauxVoulus > 0 && (canaux != canauxVoulus || frequence != frequenceVoulue)) {
        sortie = echec(SPECTRE_MF_FORMAT, hr);
        goto fin;
    }

    // Une minute de son fait dix mégaoctets : on part sur trente secondes et on
    // double, plutôt que de se fier à la durée annoncée, qui n'est qu'une
    // estimation sur un fichier compressé.
    capacite = (long long)frequence * 30 * (canauxVoulus > 0 ? (long long)canaux : 1);
    tampon = (float *)malloc((size_t)capacite * sizeof(float));
    if (!tampon) { sortie = echec(SPECTRE_MF_MEMOIRE, 0); goto fin; }

    for (;;) {
        DWORD drapeaux = 0;
        IMFSample *echantillon = NULL;
        hr = IMFSourceReader_ReadSample(lecteur,
                (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, NULL, &drapeaux,
                NULL, &echantillon);
        if (FAILED(hr)) {
            if (remplis == 0) { sortie = echec(SPECTRE_MF_LECTURE, hr); goto fin; }
            break;                      // une panne en fin de course ne perd pas le reste
        }
        if (drapeaux & MF_SOURCE_READERF_ENDOFSTREAM) {
            if (echantillon) { IMFSample_Release(echantillon); }
            break;
        }
        // Un flux peut changer de format en route — rare, mais alors ce qui suit
        // ne se raccorde pas à ce qui précède : mieux vaut s'arrêter net que
        // rendre un signal recousu de travers.
        if (drapeaux & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
            if (echantillon) { IMFSample_Release(echantillon); }
            break;
        }
        if (!echantillon) { continue; } // écart de temps : pas de données, pas de fin

        IMFMediaBuffer *bloc = NULL;
        hr = IMFSample_ConvertToContiguousBuffer(echantillon, &bloc);
        if (SUCCEEDED(hr)) {
            BYTE *octets = NULL;
            DWORD longueur = 0;
            hr = IMFMediaBuffer_Lock(bloc, &octets, NULL, &longueur);
            if (SUCCEEDED(hr)) {
                const float *entrelace = (const float *)octets;
                long long images = (long long)longueur / (long long)(sizeof(float) * canaux);
                long long valeurs = canauxVoulus > 0 ? images * (long long)canaux : images;

                if (remplis + valeurs > capacite) {
                    long long neuve = capacite;
                    while (neuve < remplis + valeurs) { neuve *= 2; }
                    float *agrandi = (float *)realloc(tampon, (size_t)neuve * sizeof(float));
                    if (!agrandi) {
                        IMFMediaBuffer_Unlock(bloc);
                        IMFMediaBuffer_Release(bloc);
                        IMFSample_Release(echantillon);
                        sortie = echec(SPECTRE_MF_MEMOIRE, 0);
                        goto fin;
                    }
                    tampon = agrandi;
                    capacite = neuve;
                }

                if (canauxVoulus > 0) {
                    memcpy(tampon + remplis, entrelace,
                           (size_t)valeurs * sizeof(float));
                } else {
                    // La moyenne des canaux, comme du côté macOS. Le faire ici plutôt
                    // qu'après évite de garder le signal entrelacé en mémoire, qui
                    // est ce qu'il y a de plus gros dans toute l'application.
                    const float gain = 1.0f / (float)canaux;
                    for (long long i = 0; i < images; ++i) {
                        float somme = 0;
                        for (UINT32 c = 0; c < canaux; ++c) {
                            somme += entrelace[i * canaux + c];
                        }
                        tampon[remplis + i] = somme * gain;
                    }
                }
                remplis += valeurs;
                IMFMediaBuffer_Unlock(bloc);
            }
            IMFMediaBuffer_Release(bloc);
        }
        IMFSample_Release(echantillon);
    }

    if (remplis == 0) { sortie = echec(SPECTRE_MF_VIDE, 0); goto fin; }

    sortie.echantillons = tampon;
    sortie.images = canauxVoulus > 0 ? remplis / (long long)canaux : remplis;
    sortie.frequence = (double)frequence;
    sortie.canaux = (int)canaux;
    sortie.code = SPECTRE_MF_OK;
    sortie.resultat = 0;
    tampon = NULL;                      // rendu à l'appelant, pas libéré ici

fin:
    free(tampon);
    if (obtenu) { IMFMediaType_Release(obtenu); }
    if (voulu) { IMFMediaType_Release(voulu); }
    if (lecteur) { IMFSourceReader_Release(lecteur); }
    MFShutdown();
    if (fermerCom) { CoUninitialize(); }
    return sortie;
}

SpectreDecodage spectre_mf_decoder(const char *chemin) {
    return decoder(chemin, 0, 0);
}

SpectreDecodage spectre_mf_decoder_entrelace(const char *chemin, double frequence,
                                             int canaux) {
    if (frequence <= 0 || canaux <= 0) { return echec(SPECTRE_MF_FORMAT, 0); }
    return decoder(chemin, (UINT32)frequence, (UINT32)canaux);
}
