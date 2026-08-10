// Décodage des formats compressés sous Windows, par Media Foundation.
//
// Media Foundation est du COM : des interfaces, des tables de méthodes, des
// compteurs de références. Vu de Swift ce serait un chantier ; vu du C, avec
// `COBJMACROS`, ce sont des appels ordinaires. D'où cette enveloppe : elle prend
// un chemin, rend un signal mono en virgule flottante, et rien d'autre ne
// traverse la frontière.
//
// Le pendant macOS est `AVAudioFile` dans `SpectreMac/AudioFile.swift`, et le
// mono se calcule des deux côtés de la même façon — la moyenne des canaux —
// faute de quoi l'analyse ne donnerait pas la même image sur les deux systèmes.
#ifndef SPECTRE_MF_H
#define SPECTRE_MF_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /// Le signal mono. À rendre par `spectre_mf_liberer`. Nul en cas d'échec.
    float *echantillons;
    /// Nombre d'images, c'est-à-dire de valeurs dans `echantillons`.
    long long images;
    double frequence;
    /// Nombre de canaux du fichier, pour information — le signal est déjà mono.
    int canaux;
    /// 0 si tout va bien. Sinon, un code à passer à `spectre_mf_message`.
    int code;
    /// Le `HRESULT` brut, quand il y en a un : de quoi chercher la panne.
    long resultat;
} SpectreDecodage;

enum {
    SPECTRE_MF_OK = 0,
    SPECTRE_MF_DEMARRAGE = 1,      // Media Foundation n'a pas démarré
    SPECTRE_MF_CHEMIN = 2,         // le chemin n'a pas pu être converti
    SPECTRE_MF_OUVERTURE = 3,      // fichier absent, ou format inconnu du système
    SPECTRE_MF_FORMAT = 4,         // pas de piste audio décodable
    SPECTRE_MF_LECTURE = 5,        // panne en cours de décodage
    SPECTRE_MF_MEMOIRE = 6,
    SPECTRE_MF_VIDE = 7            // décodé, mais aucun échantillon
};

/// Ce qui sort n'est pas rogné : Media Foundation rend l'amorçage du codeur avec
/// le reste, et c'est `GaplessTrim` — côté Swift, portable, vérifiable — qui lit
/// ce que le conteneur en déclare. On a mesuré ici que ni la durée annoncée ni
/// l'horodatage des échantillons ne renseignent sur cet amorçage : le premier
/// instant est zéro et la durée annoncée compte l'amorçage avec le reste.
///
/// `chemin` est en UTF-8 ; la conversion en UTF-16 se fait ici.
SpectreDecodage spectre_mf_decoder(const char *chemin);

void spectre_mf_liberer(float *echantillons);

/// Un message en clair pour un code, en français, sans allocation.
const char *spectre_mf_message(int code);

#ifdef __cplusplus
}
#endif

#endif
