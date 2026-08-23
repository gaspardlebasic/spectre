// Ce que Swift ne peut pas dire lui-même.
//
// Quatre choses y tombent, et elles n'ont en commun que d'être hors de portée :
// le vocabulaire COM de Direct3D 11 et celui de Media Foundation, qui sont faits de
// macros (`d3d11.c`, `mediafoundation.c`) ; la file principale de libdispatch, dont
// l'appel qui la vide n'est dans aucun en-tête de la distribution Windows
// (`file.c`) ; et les flux de la bibliothèque C, que Swift ne nomme pas parce que
// `stdout` y est une macro (`console.c`).
//
// ─────────────────────────────────────────────────────────────────────────────
// POURQUOI LE PONT DIRECT3D EXISTE
//
// Direct3D 11 est une API COM. En C++ on appelle `appareil->CreateTexture2D(…)` ;
// en C, la même chose s'écrit `ID3D11Device_CreateTexture2D(appareil, …)`, et ce
// nom est une **macro** fournie par `d3d11.h` sous `COBJMACROS`. Swift importe les
// fonctions et les types d'un en-tête C, mais pas ses macros : il verrait donc
// des structures de pointeurs de fonctions nues, et chaque appel deviendrait un
// déréférencement de table virtuelle écrit à la main.
//
// D'où ce pont : le vocabulaire COM reste dans `pont.c`, et Swift ne voit qu'une
// dizaine de fonctions à paramètres simples. C'est aussi ce qui permet à ce même
// pont de servir au rendu hors écran de `RenduCheck` sans qu'une seule ligne
// change — la fenêtre n'est qu'un des deux endroits où l'image peut aller.
//
// Rien de Windows n'apparaît ici : `HWND` traverse en `void *`. Un en-tête public
// qui inclurait `windows.h` obligerait Swift à digérer tout le SDK à chaque
// compilation, pour un pointeur.
// ─────────────────────────────────────────────────────────────────────────────

#ifndef SPECTRE_PONT_D3D11_H
#define SPECTRE_PONT_D3D11_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Ce que le nuanceur reçoit à chaque image.
///
/// **Doit rester binairement identique au `cbuffer Uniformes` de
/// `Resources/spectrogramme.hlsl`.** Le tampon de constantes se compte par blocs
/// de seize octets, d'où le remplissage final : sans lui, Direct3D refuse la
/// création du tampon, ce qui est encore le meilleur cas — un champ ajouté d'un
/// seul côté, lui, décale tous les suivants et produit une image plausible.
typedef struct {
    float origineX, origineY;
    float parPixelX, parPixelY;
    float tailleVueX, tailleVueY;
    uint32_t colonnes;
    uint32_t lignes;
    uint32_t hauteurTuile;
    uint32_t pas;
    uint32_t palette;
    float minDb;
    float maxDb;
    float gammaValeur;
    float penteParOctave;
    float log2FminSur1k;
    float lignesParOctave;
    float demiTonLigne0;
    float teteDeLecture;
    float boucleDebut;
    float boucleFin;
    float remplissage[3];
} SpectreUniformes;

typedef struct SpectreRendu SpectreRendu;

/// Longueur du tampon à donner aux fonctions qui rendent un message d'erreur.
///
/// Les erreurs de compilation HLSL sont bavardes, et c'est tant mieux : c'est le
/// seul endroit du portage où le pilote explique ce qu'il n'a pas compris.
#define SPECTRE_ERREUR_MAX 2048

/// Crée le rendu attaché à une fenêtre, avec sa chaîne d'échange.
///
/// `hwnd` est un `HWND`. Rend `NULL` en cas d'échec, et remplit `erreur`.
SpectreRendu *spectre_rendu_creer(void *hwnd, const char *sourceHLSL, char *erreur);

/// Crée le rendu sans fenêtre, vers une cible qu'on relit.
///
/// C'est ce qui permet de mesurer le nuanceur là où personne ne peut regarder
/// l'écran — machine virtuelle comprise, et intégration continue si un jour elle
/// a une carte.
SpectreRendu *spectre_rendu_creer_hors_ecran(int largeur, int hauteur,
                                             const char *sourceHLSL, char *erreur);

void spectre_rendu_detruire(SpectreRendu *rendu);

/// Redimensionne la chaîne d'échange. Sans effet hors écran.
int spectre_rendu_redimensionner(SpectreRendu *rendu, int largeur, int hauteur);

int spectre_rendu_largeur(const SpectreRendu *rendu);
int spectre_rendu_hauteur(const SpectreRendu *rendu);

/// Envoie la matrice, découpée en tuiles empilées.
///
/// Les valeurs sont des **demi-flottants** — `Vector.demiFlottants` les produit —
/// rangés ligne par ligne, une colonne après l'autre.
int spectre_rendu_televerser_tuiles(SpectreRendu *rendu, int lignes, int colonnes,
                                    int hauteurTuile, const uint16_t *valeurs);

/// Envoie la table de la palette « notes », en RGBA huit bits.
int spectre_rendu_televerser_palette(SpectreRendu *rendu, int largeur, int hauteur,
                                     const uint8_t *rgba);

/// Restreint le spectrogramme à une zone, en pixels, depuis le coin haut-gauche.
///
/// La ligne de batterie occupe une bande en bas de la fenêtre — sur le Mac, c'est
/// une vue à part sous le spectrogramme. Zéro rend toute la fenêtre au nuanceur.
void spectre_rendu_zone(SpectreRendu *rendu, int largeur, int hauteur);

/// Dessine une image. Efface d'abord : une cible jamais écrite s'affiche en blanc
/// sur certains pilotes et en noir sur d'autres, ce qui fait douter du nuanceur.
void spectre_rendu_dessiner(SpectreRendu *rendu, const SpectreUniformes *u);

/// Présente l'image. Sans effet hors écran.
///
/// La chaîne est en modèle *flip* sans attente du balayage : c'est
/// `spectre_rendu_attendre` qui cadence, et lui seul.
///
/// - Returns: 0 en cas d'échec, 1 si l'image est partie, **2 si la fenêtre est
///   cachée** — auquel cas la carte cesse de cadencer, et un relevé de fluidité
///   pris à ce moment-là compte des images que personne ne voit.
int spectre_rendu_presenter(SpectreRendu *rendu);

/// Attend que la carte réclame l'image suivante.
///
/// C'est l'objet d'attente de la chaîne d'échange, et c'est le mécanisme qui garde
/// l'image collée au doigt : on dort **avant** de dessiner plutôt qu'après avoir
/// présenté, si bien que l'image montrée porte l'état le plus frais possible.
void spectre_rendu_attendre(SpectreRendu *rendu);

/// Relit la dernière image dessinée, en RGB huit bits, rangée par rangée depuis le
/// **haut**. `octets` doit tenir largeur × hauteur × 3.
int spectre_rendu_relire(SpectreRendu *rendu, uint8_t *octets);

/// Le nom de la carte, tel que le pilote le donne. Utile au rapport de mesure :
/// une fluidité relevée sans dire sur quoi ne veut rien dire.
void spectre_rendu_nom_de_la_carte(SpectreRendu *rendu, char *nom, int taille);

// ───────────────────────────────────────────────────── La surimpression, en Direct2D
//
// La réglette, la grille, les noms d'accords, la boucle : tout ce qui se dessine
// **par-dessus** le spectrogramme. Direct2D écrit dans le tampon de la même chaîne
// d'échange que le nuanceur, si bien qu'une seule présentation part.
//
// Toutes les coordonnées et toutes les tailles sont en **points**, comme le modèle
// les compte ; `spectre_surimpression_echelle` pose la densité de l'écran, et
// c'est le seul endroit où l'on passe aux pixels.
//
// Les couleurs sont en `0xRRVVBBAA`.

/// Crée l'appareil Direct2D et DirectWrite. À appeler une fois, après le rendu.
int spectre_surimpression_preparer(SpectreRendu *rendu, char *erreur);

/// Points par pixel : 1 sur un écran ordinaire, 2 sur un écran dense.
void spectre_surimpression_echelle(SpectreRendu *rendu, float echelle);

/// Encadrent tout dessin. Entre les deux, et **après** `spectre_rendu_dessiner` :
/// le nuanceur remplit, la surimpression écrit par-dessus.
void spectre_surimpression_debuter(SpectreRendu *rendu);
void spectre_surimpression_finir(SpectreRendu *rendu);

void spectre_surimpression_rectangle(SpectreRendu *rendu, float x, float y,
                                     float largeur, float hauteur, uint32_t rvba);
void spectre_surimpression_ligne(SpectreRendu *rendu, float x0, float y0,
                                 float x1, float y1, uint32_t rvba,
                                 float epaisseur, int pointille);
void spectre_surimpression_cercle(SpectreRendu *rendu, float x, float y, float rayon,
                                  uint32_t rvba, float epaisseur);

/// Remplit une aire fermée, donnée par `nombre` couples `x, y` consécutifs.
///
/// Le contour se referme tout seul du dernier point au premier. C'est ce qui dessine
/// la courbe de niveau de la ligne de batterie — et ce n'est pas une commodité :
/// la même surface tracée en colonnes d'un point de large faisait deux mille cinq
/// cents appels par image, et a coûté quarante images par seconde le jour où la
/// batterie est arrivée. Une aire, c'est **un** appel.
void spectre_surimpression_aire(SpectreRendu *rendu, const float *points,
                                int nombre, uint32_t rvba);

/// Écrit du texte UTF-16 terminé par un zéro.
///
/// - `y` est le **milieu** de la ligne, comme `context.draw(Text, at:)` de SwiftUI :
///   les ordonnées de la vue macOS se reprennent donc telles quelles.
/// - `police` : 0 pour Segoe UI Variable, 1 pour Cascadia Mono — celle de la
///   réglette, dont les chiffres doivent avoir la même largeur d'un instant à
///   l'autre, faute de quoi le temps affiché tremble en défilant.
/// - `alignement` : 0 à gauche, 1 centré, 2 à droite, dans `largeur`.
void spectre_surimpression_texte(SpectreRendu *rendu, const uint16_t *texte,
                                 float x, float y, float largeur, float taille,
                                 uint32_t rvba, int police, int alignement);

/// La largeur qu'occuperait ce texte. Sert à poser une étiquette sans qu'elle
/// déborde de ce qu'elle décrit.
float spectre_surimpression_largeur_texte(SpectreRendu *rendu, const uint16_t *texte,
                                          float taille, int police);

/// Un paragraphe qui se replie dans `largeur`, et rend la hauteur qu'il occupe.
///
/// `y` est ici le **haut** du bloc, et non le milieu d'une ligne : un texte dont on
/// ignore combien de lignes il fera ne peut pas se centrer sur une ordonnée choisie
/// avant de l'avoir mesuré.
///
/// `dessiner` à zéro se contente de mesurer. Le panneau des réglages s'en sert pour
/// savoir, avant d'écrire quoi que ce soit, de quelle hauteur avancer.
float spectre_surimpression_paragraphe(SpectreRendu *rendu, const uint16_t *texte,
                                       float x, float y, float largeur, float taille,
                                       uint32_t rvba, int police, int dessiner);

/// Un rectangle aux coins arrondis. `epaisseur` à zéro le remplit, sinon le cerne.
///
/// Quatre traits suffisaient tant que la surimpression n'était faite que de
/// réglettes et de cadres. Le panneau des réglages, lui, est une surface posée sur
/// l'image, et Windows 11 arrondit tout ce qui flotte : des coins carrés s'y
/// reconnaissent aussitôt comme une pièce rapportée.
void spectre_surimpression_arrondi(SpectreRendu *rendu, float x, float y,
                                   float largeur, float hauteur, float rayon,
                                   uint32_t rvba, float epaisseur);

/// Restreint le dessin à un rectangle, jusqu'à `spectre_surimpression_recoller`.
///
/// C'est ce qui permet à un panneau de défiler : son contenu est dessiné à sa place
/// réelle, et ce qui sort du cadre est coupé — plutôt que d'avoir à être écarté
/// commande par commande, ce qui reviendrait à écrire deux fois la mise en page.
void spectre_surimpression_decouper(SpectreRendu *rendu, float x, float y,
                                    float largeur, float hauteur);
void spectre_surimpression_recoller(SpectreRendu *rendu);

/// Exécute ce que le travail de fond a déposé sur `DispatchQueue.main`.
///
/// À appeler une fois par tour de boucle. Voir `file.c` : sans cet appel, une
/// boucle de messages Win32 ne vide jamais la file principale, et tout ce que le
/// modèle rend par elle — le fichier ouvert, la matrice analysée, les accords
/// relevés — n'arrive jamais.
void spectre_vider_la_file_principale(void);

/// Récupère la console du terminal qui nous a lancés, quand il y en a une.
///
/// L'application est liée en sous-système « fenêtre » pour qu'aucun terminal noir
/// n'apparaisse au double-clic ; ce qui se paie par une sortie muette quand on la
/// lance à la main. Voir `console.c`. Rend faux quand il n'y avait pas de console à
/// prendre — un lancement depuis l'Explorateur — ou qu'un tube tenait déjà les
/// flux, cas où il n'y a précisément rien à faire.
int spectre_console_rattacher(void);

// ───────────────────────────────────────────────── Le décodage, par Media Foundation
//
// Le pendant macOS est `AVAudioFile` dans `SpectreMac/AudioFile.swift`, et le mono
// se calcule des deux côtés de la même façon — la moyenne des canaux — faute de
// quoi l'analyse ne donnerait pas la même image sur les deux systèmes.

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
    SPECTRE_MF_OUVERTURE = 3,      // format que le système ne sait pas lire
    SPECTRE_MF_FORMAT = 4,         // pas de piste audio décodable
    SPECTRE_MF_LECTURE = 5,        // panne en cours de décodage
    SPECTRE_MF_MEMOIRE = 6,
    SPECTRE_MF_VIDE = 7,           // décodé, mais aucun échantillon
    SPECTRE_MF_ABSENT = 8          // le fichier n'est pas là
};

/// Ce qui sort n'est pas rogné : Media Foundation rend l'amorçage du codeur avec
/// le reste, et c'est `GaplessTrim` — côté Swift, portable, vérifiable — qui lit
/// ce que le conteneur en déclare. On a mesuré ici que ni la durée annoncée ni
/// l'horodatage des échantillons ne renseignent sur cet amorçage : le premier
/// instant est zéro et la durée annoncée compte l'amorçage avec le reste.
///
/// `chemin` est en UTF-8 ; la conversion en UTF-16 se fait de l'autre côté.
SpectreDecodage spectre_mf_decoder(const char *chemin);

/// Le même fichier, **entrelacé à la forme demandée** : Media Foundation insère son
/// rééchantillonneur et sa matrice de mixage.
///
/// C'est ce que la séparation exige, et elle seule : le réseau de Demucs n'a appris
/// qu'à 44,1 kHz en stéréo, et lui donner du 48 kHz reviendrait à lui présenter une
/// musique transposée d'un demi-ton et jouée trop vite. L'analyse, elle, garde la
/// fréquence du fichier — rééchantillonner avant d'analyser perdrait de la matière.
///
/// `images` compte les images ; le tampon en porte donc `images × canaux`.
SpectreDecodage spectre_mf_decoder_entrelace(const char *chemin, double frequence,
                                             int canaux);

void spectre_mf_liberer(float *echantillons);

/// Un message en clair pour un code, en français, sans allocation.
const char *spectre_mf_message(int code);

// ─────────────────────────────────────────────────────────── La sortie audio
//
// WASAPI en mode partagé, cadencé par évènement. Le pendant macOS est
// `AVAudioEngine` ; ici il n'y a pas de moteur, seulement un périphérique qui
// réclame des échantillons et un fil qui les lui donne.

typedef struct SpectreSortie SpectreSortie;

/// Ce que le périphérique réclame : `images` images entrelacées sur `canaux`
/// canaux, à écrire dans `sortie`. Rendre moins que demandé fait compléter de
/// silence.
///
/// **Appelée sur un fil à priorité temps réel**, et pas sur le fil principal :
/// tout ce qu'elle touche doit être à elle, ou protégé. Elle ne doit ni allouer,
/// ni prendre un verrou que le fil principal garde longtemps.
typedef int (*SpectreRemplir)(float *sortie, int images, int canaux, void *contexte);

/// Ouvre le périphérique de sortie par défaut.
///
/// `frequence` est celle qu'on voudrait — celle du fichier. WASAPI rééchantillonne
/// lui-même si le périphérique tourne à une autre : c'est le seul rééchantillonneur
/// de qualité qu'on obtient sans en écrire un, et il évite surtout de faire porter
/// à la chaîne de lecture une fréquence qui n'est pas celle du fichier.
///
/// Rend `NULL` en cas d'échec, et remplit `erreur` (`SPECTRE_ERREUR_MAX` octets).
SpectreSortie *spectre_sortie_ouvrir(double frequence, SpectreRemplir remplir,
                                     void *contexte, char *erreur);

void spectre_sortie_fermer(SpectreSortie *sortie);

/// La fréquence réellement obtenue. Égale à celle demandée quand tout va bien.
double spectre_sortie_frequence(const SpectreSortie *sortie);
int spectre_sortie_canaux(const SpectreSortie *sortie);

/// Démarre ou arrête le flux. Arrêter ne ferme pas le périphérique : reprendre est
/// immédiat, là qu'une réouverture coûte quelques dizaines de millisecondes qui
/// s'entendent comme un retard à la barre d'espace.
void spectre_sortie_jouer(SpectreSortie *sortie);
void spectre_sortie_pause(SpectreSortie *sortie);
int spectre_sortie_joue(const SpectreSortie *sortie);

/// Images déjà remises au périphérique et pas encore entendues.
///
/// C'est ce qu'il faut retirer de la position de lecture pour que la tête montre
/// **ce qui s'entend** plutôt que ce qui est déjà parti. Sans ce retrait, la tête
/// prend l'avance d'un tampon — une trentaine de millisecondes, ce qui se voit dès
/// qu'on cale une boucle sur un temps.
int spectre_sortie_en_vol(const SpectreSortie *sortie);

// ─────────────────────────────────────────── La séparation, par ONNX Runtime
//
// Le pendant macOS passe par le paquet Swift de Microsoft, qui ne connaît qu'Apple.
// Ailleurs, ONNX Runtime se distribue en DLL, et c'est **`LoadLibraryW` qui la
// charge** — pas l'éditeur de liens. Voir la longue note en tête d'`onnx.c` : c'est
// ce qui permet à l'application de s'ouvrir quand le moteur n'est pas installé, et
// à l'intégration continue de compiler sans télécharger seize mégaoctets.
//
// Le pont ne connaît qu'un réseau, celui de Demucs : deux entrées nommées « mix » et
// « spec », deux sorties nommées « zout » et « xt ». Un pont générique sur les
// tenseurs coûterait trois fois ces lignes pour un second modèle qui n'existe pas.

typedef struct SpectreReseau SpectreReseau;

/// Faux quand cette compilation n'a pas vu les en-têtes d'ONNX Runtime.
int spectre_reseau_disponible(void);

/// Ouvre un réseau. `chemin` et `bibliotheque` sont de l'UTF-16 terminé par un zéro
/// — le fichier `.onnx`, et l'`onnxruntime.dll` à charger.
///
/// Rend `NULL` en cas d'échec, et remplit `erreur` (`SPECTRE_ERREUR_MAX` octets).
SpectreReseau *spectre_reseau_ouvrir(const uint16_t *chemin,
                                     const uint16_t *bibliotheque, char *erreur);
void spectre_reseau_fermer(SpectreReseau *reseau);

/// Applique le réseau à une tranche.
///
/// `mix` fait `canaux × segment`, `spec` fait `canaux × raies × trames × 2`.
/// `zout` et `xt` sont fournis par l'appelant, aux tailles que le réseau rend :
/// `4 × canaux × raies × trames × 2` et `4 × canaux × segment`.
int spectre_reseau_appliquer(SpectreReseau *reseau, const float *mix, const float *spec,
                             int canaux, int segment, int raies, int trames,
                             float *zout, float *xt, char *erreur);

#ifdef __cplusplus
}
#endif

#endif
