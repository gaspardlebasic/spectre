// Ce que Swift voit de miniaudio.
//
// `MA_NO_ENCODING` et compagnie : on ne veut ni décodeurs ni encodeurs — le
// décodage se fait ailleurs, en Swift, et laisser miniaudio les compiler
// ajouterait dr_wav, dr_mp3 et dr_flac à la construction pour rien.
#ifndef SPECTRE_MINIAUDIO_SHIM_H
#define SPECTRE_MINIAUDIO_SHIM_H

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#include "miniaudio.h"

#endif
