// L'enveloppe autour de signalsmith-stretch. Voir `include/spectre_stretch.h`.

#include "signalsmith/signalsmith-stretch.h"

#include <algorithm>
#include <vector>

#include "include/spectre_stretch.h"

namespace {

/// Le plus gros bloc qu'on accepte de traiter d'un coup.
///
/// Les tampons de désentrelacement sont alloués une fois pour toutes : le
/// traitement est appelé depuis le fil audio, où une allocation est un défaut,
/// pas une lenteur. Un périphérique WASAPI demande quelques centaines
/// d'échantillons à la fois ; seize mille laissent de la marge sans peser.
constexpr int maxImages = 16384;

}  // namespace

struct SpectreStretch {
    signalsmith::stretch::SignalsmithStretch<float> moteur;
    int canaux = 1;

    // Désentrelacé, parce que c'est ce que le moteur veut.
    std::vector<std::vector<float>> entree, sortie;
    std::vector<float *> pointeursEntree, pointeursSortie;
};

SpectreStretch *spectre_stretch_creer(int canaux, double frequence) {
    if (canaux < 1 || frequence <= 0) { return nullptr; }
    SpectreStretch *s = new (std::nothrow) SpectreStretch();
    if (!s) { return nullptr; }

    s->canaux = canaux;
    s->moteur.presetDefault(canaux, (float)frequence);

    // Le tampon d'entrée est plus grand que celui de sortie : à vitesse ×4 il
    // faut quatre fois plus d'échantillons qu'on n'en rend.
    s->entree.resize((size_t)canaux, std::vector<float>((size_t)maxImages * 4, 0.0f));
    s->sortie.resize((size_t)canaux, std::vector<float>((size_t)maxImages, 0.0f));
    s->pointeursEntree.resize((size_t)canaux);
    s->pointeursSortie.resize((size_t)canaux);
    for (int c = 0; c < canaux; ++c) {
        s->pointeursEntree[(size_t)c] = s->entree[(size_t)c].data();
        s->pointeursSortie[(size_t)c] = s->sortie[(size_t)c].data();
    }
    return s;
}

void spectre_stretch_detruire(SpectreStretch *s) { delete s; }

void spectre_stretch_transposer(SpectreStretch *s, double demiTons) {
    if (s) { s->moteur.setTransposeSemitones((float)demiTons); }
}

void spectre_stretch_reinitialiser(SpectreStretch *s) {
    if (s) { s->moteur.reset(); }
}

int spectre_stretch_latence(const SpectreStretch *s) {
    if (!s) { return 0; }
    // `const` de notre côté, pas du sien : interroger le moteur ne le modifie
    // pas, mais sa méthode n'est pas marquée telle quelle.
    SpectreStretch *m = const_cast<SpectreStretch *>(s);
    return m->moteur.inputLatency() + m->moteur.outputLatency();
}

void spectre_stretch_traiter(SpectreStretch *s,
                             const float *entree, int imagesEntree,
                             float *sortie, int imagesSortie) {
    if (!s || !sortie || imagesSortie <= 0) { return; }
    imagesSortie = std::min(imagesSortie, maxImages);
    imagesEntree = std::max(std::min(imagesEntree, maxImages * 4), 0);

    const int canaux = s->canaux;
    for (int c = 0; c < canaux; ++c) {
        float *dst = s->entree[(size_t)c].data();
        if (entree) {
            for (int i = 0; i < imagesEntree; ++i) { dst[i] = entree[(size_t)i * canaux + c]; }
        } else {
            // Pas d'entrée : la fin du morceau. On continue à pousser du silence
            // pour vider la queue du vocodeur, plutôt que de couper net.
            std::fill(dst, dst + imagesEntree, 0.0f);
        }
    }

    s->moteur.process(s->pointeursEntree, imagesEntree, s->pointeursSortie, imagesSortie);

    for (int c = 0; c < canaux; ++c) {
        const float *src = s->sortie[(size_t)c].data();
        for (int i = 0; i < imagesSortie; ++i) { sortie[(size_t)i * canaux + c] = src[i]; }
    }
}
