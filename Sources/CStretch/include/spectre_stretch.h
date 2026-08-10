// Ralentir sans transposer, transposer sans ralentir.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QUE ÇA REMPLACE
//
// Sur macOS, `AVAudioUnitTimePitch` fait ce travail dans le moteur audio du
// système. Ailleurs il faut l'apporter : c'est signalsmith-stretch, un vocodeur
// de phase en C++ sous licence MIT, enveloppé ici dans une poignée de fonctions
// C. Rien de C++ ne traverse — un pointeur opaque, des flottants, des entiers.
//
// **Le découplage entrée/sortie est le cœur de l'affaire.** Un effet ordinaire
// rend autant d'échantillons qu'il en reçoit ; celui-ci non. Pour produire `n`
// échantillons à la vitesse `v`, il faut lui en donner `n × v` : c'est
// l'appelant qui décide du rapport, à chaque bloc, en choisissant combien il
// fournit et combien il demande. La vitesse n'est donc pas un réglage de cet
// objet — elle n'existe que dans ce rapport.
//
// La transposition, elle, en est un : elle ne change pas le débit.
// ─────────────────────────────────────────────────────────────────────────────
#ifndef SPECTRE_STRETCH_H
#define SPECTRE_STRETCH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpectreStretch SpectreStretch;

/// Rend NULL si la mémoire manque. `canaux` vaut 1 dans Spectre : l'analyse est
/// mono, et la lecture aussi.
SpectreStretch *spectre_stretch_creer(int canaux, double frequence);
void spectre_stretch_detruire(SpectreStretch *s);

/// En demi-tons, positif vers l'aigu. Zéro laisse la hauteur intacte.
void spectre_stretch_transposer(SpectreStretch *s, double demiTons);

/// Vide l'état interne : à appeler après un saut dans le morceau, faute de quoi
/// le vocodeur recolle deux passages qui ne se suivent pas.
void spectre_stretch_reinitialiser(SpectreStretch *s);

/// Retard, en échantillons, entre ce qu'on donne et ce qui en ressort. C'est
/// une propriété du procédé, pas un défaut : il faut une fenêtre d'analyse
/// entière avant de pouvoir en resynthétiser le début.
int spectre_stretch_latence(const SpectreStretch *s);

/// `imagesEntree` échantillons entrent, `imagesSortie` en sortent. Le rapport
/// des deux est la vitesse. Les deux tampons sont entrelacés s'il y a plusieurs
/// canaux.
void spectre_stretch_traiter(SpectreStretch *s,
                             const float *entree, int imagesEntree,
                             float *sortie, int imagesSortie);

#ifdef __cplusplus
}
#endif

#endif
