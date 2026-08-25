// La sortie audio sous Linux — le jumeau de `wasapi.c`.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE MÊME CONTRAT, SEPT FONCTIONS
//
// Ce fichier exporte exactement ce qu'exporte `wasapi.c`, avec les mêmes noms et
// les mêmes signatures. `SpectreSon/Lecteur.swift` ne sait pas lequel des deux il
// appelle — et c'est ce qui permet au lecteur d'être écrit une seule fois.
//
// POURQUOI ALSA ET PAS PIPEWIRE
//
// PipeWire *et* PulseAudio exposent tous deux un périphérique ALSA nommé
// `default` : une seule écriture couvre donc tout le monde, y compris les machines
// qui n'ont ni l'un ni l'autre. Le jour où la latence de ce chemin gênerait,
// PipeWire se glisse derrière les mêmes huit fonctions sans que rien d'autre bouge
// — c'est tout l'intérêt de les avoir.
//
// CE QUI DIFFÈRE DE WASAPI, ET QU'IL FAUT SAVOIR
//
// WASAPI est cadencé par évènement : le périphérique réveille le fil quand il veut
// des échantillons. ALSA, en mode bloquant, cadence par l'écriture elle-même :
// `snd_pcm_writei` rend la main quand la place est faite. Le fil tourne donc sur
// une boucle d'écriture plutôt que sur une attente, ce qui revient au même du
// point de vue du lecteur — il ne voit que `remplir` appelée à temps.
//
// **Et il n'y a pas de rééchantillonneur offert.** WASAPI en insère un quand le
// périphérique ne tourne pas à la fréquence demandée ; ALSA, par son greffon
// `plug`, en a un aussi — c'est pourquoi le périphérique est ouvert par son nom
// `default` et non par un `hw:` direct. Sans cela, un fichier en 44,1 kHz sur une
// carte figée à 48 kHz sonnerait un demi-ton trop haut.
//
// CE QUE CE RÉÉCHANTILLONNEUR EXIGE EN RETOUR, ET QUI A COÛTÉ UNE ENQUÊTE
//
// Il faut lui laisser de la place. Un serveur de son travaille par blocs — PipeWire
// les appelle « quanta », et le sien fait 1024 images, soit 21 ms à 48 kHz. Tant
// qu'il n'a rien à convertir, il sert des périodes plus courtes que son bloc sans
// broncher. Dès qu'il convertit — un fichier en 44,1 kHz sur un graphe à 48 kHz,
// c'est-à-dire le cas le plus ordinaire qui soit — une période plus courte que son
// bloc l'affame, et le flux part en cascade de sous-alimentations.
//
// Ce que ça donne, mesuré au débit réel d'une sortie sur cinq secondes, sur cinq
// essais, en demandant 44 100 Hz :
//
// | période | tampon  | résultat                                          |
// |---------|---------|---------------------------------------------------|
// | 10 ms   |  40 ms  | ×0,20 à ×1,01 — trois essais sur cinq s'effondrent |
// | 20 ms   | 100 ms  | ×0,92 à ×1,02 — un essai sur cinq trébuche        |
// | 25 ms   | 100 ms  | ×1,01 — cinq essais sur cinq, zéro sous-alimentation |
//
// À 48 kHz, où rien n'est converti, les trois lignes se valent : c'est bien la
// conversion qui réclame la place, et non la machine qui serait lente. D'où la
// période de 25 ms ci-dessous, choisie juste au-dessus du bloc du serveur.
//
// Le prix est 100 ms de tampon au lieu de 40. La tête de lecture ne s'en aperçoit
// pas — elle retranche déjà ce que `snd_pcm_delay` annonce — mais un saut laisse
// entendre jusqu'à un dixième de seconde de l'endroit qu'on vient de quitter. C'est
// le prix d'un son juste, et il se paie.
// ─────────────────────────────────────────────────────────────────────────────

#include <alsa/asoundlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/pont.h"

struct SpectreSortie {
    snd_pcm_t *peripherique;
    SpectreRemplir remplir;
    void *contexte;

    double frequence;
    int canaux;
    snd_pcm_uframes_t periode;
    float *tampon;

    pthread_t fil;
    atomic_int tourne;
    atomic_int joue;
    /// Posé par le fil principal quand la tête saute, relevé par le fil audio.
    atomic_int vider;
    /// Images remises au périphérique et pas encore entendues, relevées par le fil
    /// audio et lues par le fil principal. Atomique parce que les deux la touchent,
    /// et parce qu'un verrou n'a rien à faire sur ce chemin-là.
    atomic_int enVol;
};

static void noter(char *erreur, const char *format, ...) {
    if (!erreur) { return; }
    va_list args;
    va_start(args, format);
    vsnprintf(erreur, SPECTRE_ERREUR_MAX, format, args);
    va_end(args);
}

// ─────────────────────────────────────────────────────────── Le fil audio

/// Le fil qui donne des échantillons au périphérique, et rien d'autre.
///
/// **Il n'alloue pas.** Le tampon est fait à l'ouverture ; tout ce qui se passe ici
/// est un appel à `remplir` et une écriture. C'est la règle de tous les fils audio,
/// et elle vaut ici autant qu'ailleurs : une allocation peut attendre le noyau, et
/// le noyau ne rend pas la main à temps.
static void *tourner(void *brut) {
    SpectreSortie *s = (SpectreSortie *)brut;
    const snd_pcm_uframes_t images = s->periode;
    const size_t valeurs = (size_t)images * (size_t)s->canaux;

    while (atomic_load(&s->tourne)) {
        if (atomic_exchange(&s->vider, 0)) {
            // `drop` jette ce qui est en attente, `prepare` remet le flux prêt à
            // repartir. Le seuil de départ posé à l'ouverture fait qu'il ne
            // redémarrera qu'une fois le tampon refait, c'est-à-dire plein — ce qui
            // est exactement ce qu'on veut après un saut.
            snd_pcm_drop(s->peripherique);
            snd_pcm_prepare(s->peripherique);
            atomic_store(&s->enVol, 0);
        }

        if (atomic_load(&s->joue)) {
            int rendues = s->remplir(s->tampon, (int)images, s->canaux, s->contexte);
            if (rendues < 0) { rendues = 0; }
            if ((size_t)rendues < images) {
                // Rendre moins que demandé fait compléter de silence : c'est la fin
                // du morceau, ou une chaîne qui n'a rien à donner cette fois-ci.
                memset(s->tampon + (size_t)rendues * (size_t)s->canaux, 0,
                       (valeurs - (size_t)rendues * (size_t)s->canaux) * sizeof(float));
            }
        } else {
            // En pause, on continue d'écrire du silence plutôt que d'arrêter le
            // flux. Reprendre est alors immédiat, là où une réouverture coûte
            // quelques dizaines de millisecondes qui s'entendent comme un retard à
            // la barre d'espace.
            memset(s->tampon, 0, valeurs * sizeof(float));
        }

        snd_pcm_sframes_t ecrites = snd_pcm_writei(s->peripherique, s->tampon, images);
        if (ecrites < 0) {
            // Un sous-alimentation — la machine a été trop lente une fois — se
            // rattrape en repréparant le flux. Ne pas le faire laisse le
            // périphérique muet pour toujours, ce qui se diagnostique très mal.
            ecrites = snd_pcm_recover(s->peripherique, (int)ecrites, 1);
            if (ecrites < 0) { break; }
            continue;
        }

        snd_pcm_sframes_t retard = 0;
        if (snd_pcm_delay(s->peripherique, &retard) == 0 && retard > 0) {
            atomic_store(&s->enVol, (int)retard);
        } else {
            atomic_store(&s->enVol, 0);
        }
    }
    return NULL;
}

/// Monte le fil audio en priorité, si le système le permet.
///
/// Sans droits particuliers, `SCHED_FIFO` est refusé et l'on continue en priorité
/// ordinaire : c'est le cas d'une session de bureau qui n'a pas de limite `rtprio`.
/// L'échec n'est donc pas une erreur — il coûte quelques craquements sous forte
/// charge, et rien d'autre.
static void monterEnPriorite(pthread_t fil) {
    struct sched_param parametres;
    memset(&parametres, 0, sizeof parametres);
    int politique = SCHED_FIFO;
    int minimum = sched_get_priority_min(politique);
    int maximum = sched_get_priority_max(politique);
    if (minimum < 0 || maximum < 0) { return; }
    // Haut, mais pas au sommet : au-dessus il y a les fils du noyau, et un fil audio
    // qui les précède peut figer la machine entière quand il boucle.
    parametres.sched_priority = minimum + (maximum - minimum) * 3 / 4;
    (void)pthread_setschedparam(fil, politique, &parametres);
}

// ─────────────────────────────────────────────────────────── Le contrat

SpectreSortie *spectre_sortie_ouvrir(double frequence, SpectreRemplir remplir,
                                     void *contexte, char *erreur) {
    if (!remplir) { noter(erreur, "aucune fonction de remplissage"); return NULL; }
    SpectreSortie *s = calloc(1, sizeof *s);
    if (!s) { noter(erreur, "memoire"); return NULL; }

    s->remplir = remplir;
    s->contexte = contexte;
    s->canaux = 2;

    // `default` et non `hw:0` : c'est le nom qui passe par le greffon `plug`, donc
    // par le rééchantillonneur et le mixeur. PipeWire et PulseAudio le fournissent
    // aussi, et c'est ce qui rend cette écriture bonne partout.
    int r = snd_pcm_open(&s->peripherique, "default", SND_PCM_STREAM_PLAYBACK, 0);
    if (r < 0) {
        noter(erreur, "peripherique audio : %s", snd_strerror(r));
        free(s);
        return NULL;
    }

    unsigned int taux = (unsigned int)(frequence > 0 ? frequence : 44100);
    // ── La cadence, et pourquoi elle se demande en microsecondes ───────────────
    //
    // Une période courte pour que la tête de lecture colle à ce qu'on entend, et
    // quatre périodes de tampon pour que la machine ait le droit d'être en retard
    // une fois. C'est le compromis de WASAPI en mode partagé.
    //
    // **En temps et non en images**, parce que le périphérique `default` passe par
    // les greffons `plug` et `dmix`, qui n'ont pas les contraintes de la carte : à
    // qui demande une taille en images, ils répondent volontiers trois secondes.
    // Le lecteur remplit alors ce qu'il peut d'un bloc pareil et l'on complète le
    // reste de silence — la lecture avance à un tiers du temps réel, sans qu'une
    // seule erreur soit dite. C'est le piège de l'étape 5.
    unsigned int periodeMicrosecondes = 25000;      // 25 ms — voir l'en-tête
    unsigned int tamponMicrosecondes = 100000;      // quatre périodes
    snd_pcm_uframes_t periode = 0;

    snd_pcm_hw_params_t *materiel = NULL;
    snd_pcm_hw_params_alloca(&materiel);
    snd_pcm_hw_params_any(s->peripherique, materiel);
    snd_pcm_hw_params_set_access(s->peripherique, materiel,
                                 SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(s->peripherique, materiel, SND_PCM_FORMAT_FLOAT_LE);
    snd_pcm_hw_params_set_channels_near(s->peripherique, materiel,
                                        (unsigned int *)&s->canaux);
    snd_pcm_hw_params_set_rate_near(s->peripherique, materiel, &taux, NULL);
    snd_pcm_hw_params_set_buffer_time_near(s->peripherique, materiel,
                                           &tamponMicrosecondes, NULL);
    snd_pcm_hw_params_set_period_time_near(s->peripherique, materiel,
                                           &periodeMicrosecondes, NULL);
    r = snd_pcm_hw_params(s->peripherique, materiel);
    if (r < 0) {
        noter(erreur, "format audio refuse : %s", snd_strerror(r));
        snd_pcm_close(s->peripherique);
        free(s);
        return NULL;
    }
    snd_pcm_hw_params_get_period_size(materiel, &periode, NULL);
    snd_pcm_hw_params_get_rate(materiel, &taux, NULL);
    // Une dernière borne, au cas où le greffon aurait tout de même imposé un bloc
    // démesuré : mieux vaut écrire plusieurs fois une petite période que remplir de
    // silence les trois quarts d'une grande.
    //
    // Généreuse, et elle doit l'être : 25 ms font 4 800 images à 192 kHz, et rogner
    // une période légitime remettrait justement les écritures sous le bloc du
    // serveur — c'est-à-dire recréerait la panne que l'en-tête raconte.
    snd_pcm_uframes_t plafond = (snd_pcm_uframes_t)(taux / 10);   // un dixième de seconde
    if (periode == 0 || periode > plafond) { periode = (snd_pcm_uframes_t)(taux / 40); }

    // ── Le seuil de départ ────────────────────────────────────────────────────
    //
    // Sans ces lignes, ALSA prend un seuil de 1 : le flux démarre à la première
    // image écrite, c'est-à-dire sur un tampon vide, et se retrouve en retard avant
    // d'avoir commencé. Le faire partir plein lui donne le tampon entier d'avance,
    // qui est exactement ce à quoi il sert.
    snd_pcm_uframes_t tampon = 0;
    snd_pcm_hw_params_get_buffer_size(materiel, &tampon);
    snd_pcm_sw_params_t *logiciel = NULL;
    snd_pcm_sw_params_alloca(&logiciel);
    if (snd_pcm_sw_params_current(s->peripherique, logiciel) == 0) {
        snd_pcm_sw_params_set_start_threshold(s->peripherique, logiciel,
                                              tampon > 0 ? tampon : periode);
        snd_pcm_sw_params_set_avail_min(s->peripherique, logiciel, periode);
        // L'échec ne se dit pas : le flux marche sans, simplement moins bien, et il
        // n'y a rien que l'utilisateur puisse faire de la nouvelle.
        (void)snd_pcm_sw_params(s->peripherique, logiciel);
    }

    s->frequence = (double)taux;
    s->periode = periode;
    s->tampon = calloc((size_t)periode * (size_t)s->canaux, sizeof(float));
    if (!s->tampon) {
        noter(erreur, "memoire");
        snd_pcm_close(s->peripherique);
        free(s);
        return NULL;
    }

    atomic_store(&s->tourne, 1);
    atomic_store(&s->joue, 0);
    atomic_store(&s->vider, 0);
    atomic_store(&s->enVol, 0);
    if (pthread_create(&s->fil, NULL, tourner, s) != 0) {
        noter(erreur, "le fil audio n'a pas demarre");
        free(s->tampon);
        snd_pcm_close(s->peripherique);
        free(s);
        return NULL;
    }
    monterEnPriorite(s->fil);
    return s;
}

void spectre_sortie_fermer(SpectreSortie *sortie) {
    if (!sortie) { return; }
    atomic_store(&sortie->tourne, 0);
    pthread_join(sortie->fil, NULL);
    snd_pcm_drop(sortie->peripherique);
    snd_pcm_close(sortie->peripherique);
    free(sortie->tampon);
    free(sortie);
}

double spectre_sortie_frequence(const SpectreSortie *sortie) {
    return sortie ? sortie->frequence : 0;
}

int spectre_sortie_canaux(const SpectreSortie *sortie) {
    return sortie ? sortie->canaux : 0;
}

void spectre_sortie_jouer(SpectreSortie *sortie) {
    if (sortie) { atomic_store(&sortie->joue, 1); }
}

void spectre_sortie_pause(SpectreSortie *sortie) {
    if (sortie) { atomic_store(&sortie->joue, 0); }
}

void spectre_sortie_vider(SpectreSortie *sortie) {
    if (sortie) { atomic_store(&sortie->vider, 1); }
}

int spectre_sortie_joue(const SpectreSortie *sortie) {
    return sortie ? atomic_load((atomic_int *)&sortie->joue) : 0;
}

int spectre_sortie_en_vol(const SpectreSortie *sortie) {
    return sortie ? atomic_load((atomic_int *)&sortie->enVol) : 0;
}
