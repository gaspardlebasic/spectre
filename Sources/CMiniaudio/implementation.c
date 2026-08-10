// L'unique unité de compilation de miniaudio.
//
// La bibliothèque tient dans un seul en-tête : le code n'existe que si un
// fichier définit `MINIAUDIO_IMPLEMENTATION` avant de l'inclure. C'est ce
// fichier, et il ne doit y en avoir qu'un — deux définitions donneraient des
// symboles en double à l'édition de liens.
#define MINIAUDIO_IMPLEMENTATION
#include "shim.h"
