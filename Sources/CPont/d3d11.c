// Direct3D 11, en C. Voir `include/pont.h` pour la raison d'être de ce fichier.

// `INITGUID` fait définir ici les `IID_…` que réclame `QueryInterface`, plutôt que
// de les faire chercher dans `dxguid.lib` : une bibliothèque de moins à lier, et
// une erreur de liaison de moins à diagnostiquer.
#include <initguid.h>
#include "interne.h"
#include <d3dcompiler.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static void noter(char *erreur, const char *format, ...) {
    if (!erreur) { return; }
    va_list args;
    va_start(args, format);
    vsnprintf(erreur, SPECTRE_ERREUR_MAX, format, args);
    va_end(args);
}

static void liberer(SpectreRendu *r) {
    if (!r) { return; }
    spectre_surimpression_detruire(r);
    if (r->tuiles) { ID3D11ShaderResourceView_Release(r->tuiles); }
    if (r->palette) { ID3D11ShaderResourceView_Release(r->palette); }
    if (r->rasteriseur) { ID3D11RasterizerState_Release(r->rasteriseur); }
    if (r->constantes) { ID3D11Buffer_Release(r->constantes); }
    if (r->fragments) { ID3D11PixelShader_Release(r->fragments); }
    if (r->sommets) { ID3D11VertexShader_Release(r->sommets); }
    if (r->relecture) { ID3D11Texture2D_Release(r->relecture); }
    if (r->cibleHorsEcran) { ID3D11Texture2D_Release(r->cibleHorsEcran); }
    if (r->cible) { ID3D11RenderTargetView_Release(r->cible); }
    if (r->chaine) { IDXGISwapChain2_Release(r->chaine); }
    if (r->contexte) { ID3D11DeviceContext_Release(r->contexte); }
    if (r->appareil) { ID3D11Device_Release(r->appareil); }
    free(r);
}

// ─────────────────────────────────────────────────────────── L'appareil

static int creerAppareil(SpectreRendu *r, char *erreur) {
    // 11_1 d'abord, 11_0 ensuite : le premier suffit partout où ce portage doit
    // tourner, la machine virtuelle de développement comprise, mais le second
    // évite de refuser une carte pour une différence qu'on n'utilise pas.
    D3D_FEATURE_LEVEL niveaux[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    UINT drapeaux = D3D11_CREATE_DEVICE_BGRA_SUPPORT;   // exigé par Direct2D, étape 7
#ifndef NDEBUG
    // La couche de mise au point n'est présente que si les outils graphiques de
    // Windows sont installés. On réessaie sans elle plutôt que d'échouer, faute de
    // quoi le portage exigerait une installation que rien n'annonce.
    drapeaux |= D3D11_CREATE_DEVICE_DEBUG;
#endif
    D3D_FEATURE_LEVEL obtenu;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, drapeaux,
                                   niveaux, 2, D3D11_SDK_VERSION,
                                   &r->appareil, &obtenu, &r->contexte);
    if (hr == DXGI_ERROR_SDK_COMPONENT_MISSING || hr == E_FAIL) {
        drapeaux &= ~(UINT)D3D11_CREATE_DEVICE_DEBUG;
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, drapeaux,
                               niveaux, 2, D3D11_SDK_VERSION,
                               &r->appareil, &obtenu, &r->contexte);
    }
    if (FAILED(hr)) {
        noter(erreur, "Direct3D 11 indisponible (0x%08lX).", (unsigned long)hr);
        return 0;
    }

    // Le nom de la carte, pour le rapport de mesure : une fluidité relevée sans
    // dire sur quoi ne veut rien dire, et la carte paravirtualisée d'une machine
    // virtuelle ne se devine pas au vu des nombres.
    // `snprintf` plutôt que `strcpy` : la chaîne de MSVC tient les fonctions
    // sans borne pour dépréciées, et le dépôt se compile sans un avertissement.
    snprintf(r->carte, sizeof(r->carte), "%s", "carte inconnue");
    IDXGIDevice *dxgi = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(r->appareil, &IID_IDXGIDevice, (void **)&dxgi))) {
        IDXGIAdapter *adaptateur = NULL;
        if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adaptateur))) {
            DXGI_ADAPTER_DESC description;
            if (SUCCEEDED(IDXGIAdapter_GetDesc(adaptateur, &description))) {
                WideCharToMultiByte(CP_UTF8, 0, description.Description, -1,
                                    r->carte, sizeof(r->carte) - 1, NULL, NULL);
            }
            IDXGIAdapter_Release(adaptateur);
        }
        IDXGIDevice_Release(dxgi);
    }
    return 1;
}

// ─────────────────────────────────────────────────────────── Les nuanceurs

static ID3DBlob *compiler(const char *source, const char *entree,
                          const char *cible, char *erreur) {
    ID3DBlob *code = NULL, *journal = NULL;
    UINT drapeaux = D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
    HRESULT hr = D3DCompile(source, strlen(source), "spectrogramme.hlsl", NULL, NULL,
                            entree, cible, drapeaux, 0, &code, &journal);
    if (FAILED(hr)) {
        if (journal) {
            noter(erreur, "Compilation du nuanceur (%s) :\n%s",
                  entree, (const char *)ID3D10Blob_GetBufferPointer(journal));
            ID3D10Blob_Release(journal);
        } else {
            noter(erreur, "Compilation du nuanceur (%s) : 0x%08lX.",
                  entree, (unsigned long)hr);
        }
        return NULL;
    }
    if (journal) { ID3D10Blob_Release(journal); }
    return code;
}

static int creerNuanceurs(SpectreRendu *r, const char *source, char *erreur) {
    ID3DBlob *vs = compiler(source, "sommets", "vs_5_0", erreur);
    if (!vs) { return 0; }
    ID3DBlob *ps = compiler(source, "fragments", "ps_5_0", erreur);
    if (!ps) { ID3D10Blob_Release(vs); return 0; }

    HRESULT hr = ID3D11Device_CreateVertexShader(r->appareil,
        ID3D10Blob_GetBufferPointer(vs), ID3D10Blob_GetBufferSize(vs), NULL, &r->sommets);
    if (SUCCEEDED(hr)) {
        hr = ID3D11Device_CreatePixelShader(r->appareil,
            ID3D10Blob_GetBufferPointer(ps), ID3D10Blob_GetBufferSize(ps), NULL, &r->fragments);
    }
    ID3D10Blob_Release(vs);
    ID3D10Blob_Release(ps);
    if (FAILED(hr)) {
        noter(erreur, "Nuanceur refusé par le pilote (0x%08lX).", (unsigned long)hr);
        return 0;
    }

    D3D11_BUFFER_DESC bd = {0};
    bd.ByteWidth = sizeof(SpectreUniformes);
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = ID3D11Device_CreateBuffer(r->appareil, &bd, NULL, &r->constantes);
    if (FAILED(hr)) {
        noter(erreur, "Tampon de constantes refusé (0x%08lX) — la structure doit "
                      "faire un multiple de seize octets.", (unsigned long)hr);
        return 0;
    }

    // Le triangle est décrit dans un espace où Y monte, et l'écran compte Y vers
    // le bas : son enroulement s'inverse donc au passage, et le découpage des
    // faces arrière l'effacerait entièrement. On ne découpe rien — il n'y a qu'un
    // triangle, et aucune face à cacher.
    D3D11_RASTERIZER_DESC rd = {0};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    hr = ID3D11Device_CreateRasterizerState(r->appareil, &rd, &r->rasteriseur);
    if (FAILED(hr)) {
        noter(erreur, "Rastériseur refusé (0x%08lX).", (unsigned long)hr);
        return 0;
    }
    return 1;
}

// ─────────────────────────────────────────────────────────── Les cibles

static void lacherCible(SpectreRendu *r) {
    if (r->cible) { ID3D11RenderTargetView_Release(r->cible); r->cible = NULL; }
}

static int cibleDepuisLaChaine(SpectreRendu *r, char *erreur) {
    ID3D11Texture2D *tampon = NULL;
    HRESULT hr = IDXGISwapChain2_GetBuffer(r->chaine, 0, &IID_ID3D11Texture2D, (void **)&tampon);
    if (FAILED(hr)) {
        noter(erreur, "Tampon de la chaîne d'échange illisible (0x%08lX).", (unsigned long)hr);
        return 0;
    }
    hr = ID3D11Device_CreateRenderTargetView(r->appareil, (ID3D11Resource *)tampon, NULL, &r->cible);
    ID3D11Texture2D_Release(tampon);
    if (FAILED(hr)) {
        noter(erreur, "Vue de cible impossible (0x%08lX).", (unsigned long)hr);
        return 0;
    }
    return 1;
}

SpectreRendu *spectre_rendu_creer(void *hwnd, const char *sourceHLSL, char *erreur) {
    SpectreRendu *r = calloc(1, sizeof(SpectreRendu));
    if (!r) { noter(erreur, "Mémoire insuffisante."); return NULL; }
    if (!creerAppareil(r, erreur)) { liberer(r); return NULL; }
    if (!creerNuanceurs(r, sourceHLSL, erreur)) { liberer(r); return NULL; }

    RECT zone;
    GetClientRect((HWND)hwnd, &zone);
    r->largeur = zone.right - zone.left;
    r->hauteur = zone.bottom - zone.top;
    if (r->largeur < 1) { r->largeur = 1; }
    if (r->hauteur < 1) { r->hauteur = 1; }

    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adaptateur = NULL;
    IDXGIFactory2 *fabrique = NULL;
    HRESULT hr = ID3D11Device_QueryInterface(r->appareil, &IID_IDXGIDevice, (void **)&dxgi);
    if (SUCCEEDED(hr)) { hr = IDXGIDevice_GetAdapter(dxgi, &adaptateur); }
    if (SUCCEEDED(hr)) {
        hr = IDXGIAdapter_GetParent(adaptateur, &IID_IDXGIFactory2, (void **)&fabrique);
    }
    if (FAILED(hr)) {
        noter(erreur, "Fabrique DXGI introuvable (0x%08lX).", (unsigned long)hr);
        if (adaptateur) { IDXGIAdapter_Release(adaptateur); }
        if (dxgi) { IDXGIDevice_Release(dxgi); }
        liberer(r);
        return NULL;
    }

    // Modèle *flip*, deux tampons, et l'objet d'attente. C'est ce trio qui donne
    // l'image collée au doigt : le modèle *bitblt* d'avant recopiait à travers le
    // gestionnaire de fenêtres, ce qui coûtait une image entière de retard.
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = (UINT)r->largeur;
    sd.Height = (UINT)r->hauteur;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

    IDXGISwapChain1 *chaine1 = NULL;
    hr = IDXGIFactory2_CreateSwapChainForHwnd(fabrique, (IUnknown *)r->appareil,
                                              (HWND)hwnd, &sd, NULL, NULL, &chaine1);
    if (SUCCEEDED(hr)) {
        // Alt+Entrée est le plein écran de DXGI, qui change la résolution de
        // l'écran. Ce n'est pas ce que fait une application de bureau, et le
        // laisser actif fait perdre la fenêtre à qui frappe ce raccourci par
        // habitude.
        IDXGIFactory2_MakeWindowAssociation(fabrique, (HWND)hwnd, DXGI_MWA_NO_ALT_ENTER);
        hr = IDXGISwapChain1_QueryInterface(chaine1, &IID_IDXGISwapChain2, (void **)&r->chaine);
        IDXGISwapChain1_Release(chaine1);
    }
    IDXGIFactory2_Release(fabrique);
    IDXGIAdapter_Release(adaptateur);
    IDXGIDevice_Release(dxgi);
    if (FAILED(hr)) {
        noter(erreur, "Chaîne d'échange impossible (0x%08lX).", (unsigned long)hr);
        liberer(r);
        return NULL;
    }

    // Une seule image en vol : deux donnent un débit à peine meilleur et un
    // dixième de seconde de retard supplémentaire, qui se sent au défilement.
    IDXGISwapChain2_SetMaximumFrameLatency(r->chaine, 1);
    r->attente = IDXGISwapChain2_GetFrameLatencyWaitableObject(r->chaine);

    if (!cibleDepuisLaChaine(r, erreur)) { liberer(r); return NULL; }
    return r;
}

SpectreRendu *spectre_rendu_creer_hors_ecran(int largeur, int hauteur,
                                             const char *sourceHLSL, char *erreur) {
    SpectreRendu *r = calloc(1, sizeof(SpectreRendu));
    if (!r) { noter(erreur, "Mémoire insuffisante."); return NULL; }
    if (!creerAppareil(r, erreur)) { liberer(r); return NULL; }
    if (!creerNuanceurs(r, sourceHLSL, erreur)) { liberer(r); return NULL; }
    r->largeur = largeur < 1 ? 1 : largeur;
    r->hauteur = hauteur < 1 ? 1 : hauteur;

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = (UINT)r->largeur;
    td.Height = (UINT)r->hauteur;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    HRESULT hr = ID3D11Device_CreateTexture2D(r->appareil, &td, NULL, &r->cibleHorsEcran);
    if (SUCCEEDED(hr)) {
        hr = ID3D11Device_CreateRenderTargetView(r->appareil,
            (ID3D11Resource *)r->cibleHorsEcran, NULL, &r->cible);
    }
    if (FAILED(hr)) {
        noter(erreur, "Cible hors écran impossible (0x%08lX).", (unsigned long)hr);
        liberer(r);
        return NULL;
    }
    return r;
}

void spectre_rendu_detruire(SpectreRendu *rendu) { liberer(rendu); }

void spectre_rendu_zone(SpectreRendu *rendu, int largeur, int hauteur) {
    if (!rendu) { return; }
    rendu->zoneLargeur = largeur;
    rendu->zoneHauteur = hauteur;
}

int spectre_rendu_largeur(const SpectreRendu *rendu) { return rendu ? rendu->largeur : 0; }
int spectre_rendu_hauteur(const SpectreRendu *rendu) { return rendu ? rendu->hauteur : 0; }

int spectre_rendu_redimensionner(SpectreRendu *rendu, int largeur, int hauteur) {
    if (!rendu || !rendu->chaine) { return 0; }
    if (largeur < 1) { largeur = 1; }
    if (hauteur < 1) { hauteur = 1; }
    if (largeur == rendu->largeur && hauteur == rendu->hauteur) { return 1; }

    // La cible doit être lâchée **et détachée du contexte** avant que la chaîne se
    // redimensionne : le contexte garde une référence, et une seule suffit à faire
    // échouer `ResizeBuffers` avec une erreur qui parle de tampons occupés.
    // La surface Direct2D tient une référence sur le tampon de la chaîne, tout
    // comme la vue de cible : les deux doivent être lâchées, faute de quoi
    // `ResizeBuffers` échoue en parlant de tampons occupés sans dire lequel.
    spectre_surimpression_lacher(rendu);
    ID3D11DeviceContext_OMSetRenderTargets(rendu->contexte, 0, NULL, NULL);
    lacherCible(rendu);
    if (rendu->relecture) {
        ID3D11Texture2D_Release(rendu->relecture);
        rendu->relecture = NULL;
    }

    HRESULT hr = IDXGISwapChain2_ResizeBuffers(rendu->chaine, 0, (UINT)largeur, (UINT)hauteur,
                                               DXGI_FORMAT_UNKNOWN,
                                               DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
    if (FAILED(hr)) { return 0; }
    rendu->largeur = largeur;
    rendu->hauteur = hauteur;
    if (!cibleDepuisLaChaine(rendu, NULL)) { return 0; }
    spectre_surimpression_reprendre(rendu);
    return 1;
}

// ─────────────────────────────────────────────────────────── Le téléversement

int spectre_rendu_televerser_tuiles(SpectreRendu *rendu, int lignes, int colonnes,
                                    int hauteurTuile, const uint16_t *valeurs) {
    if (!rendu) { return 0; }
    if (rendu->tuiles) {
        ID3D11ShaderResourceView_Release(rendu->tuiles);
        rendu->tuiles = NULL;
    }
    if (lignes <= 0 || colonnes <= 0) { return 1; }

    int tranches = (colonnes + hauteurTuile - 1) / hauteurTuile;

    // Une texture immuable, remplie à la création : la matrice ne change plus
    // ensuite — zoomer, défiler, changer de palette ne fait que relire ce qui est
    // déjà là. C'est le parti pris de la version Metal, et c'est ce qui rend la
    // navigation instantanée.
    //
    // La dernière tranche est incomplète et le tableau source ne la remplit pas :
    // on donne malgré tout à Direct3D un pas de tranche qui la fait déborder du
    // tableau, d'où la copie dans un tampon à la bonne taille plutôt qu'un pointeur
    // sur les données d'origine.
    size_t parTranche = (size_t)hauteurTuile * (size_t)lignes;
    uint16_t *tampon = calloc((size_t)tranches * parTranche, sizeof(uint16_t));
    if (!tampon) { return 0; }
    for (int t = 0; t < tranches; ++t) {
        int premiere = t * hauteurTuile;
        int nombre = colonnes - premiere;
        if (nombre > hauteurTuile) { nombre = hauteurTuile; }
        memcpy(tampon + (size_t)t * parTranche,
               valeurs + (size_t)premiere * (size_t)lignes,
               (size_t)nombre * (size_t)lignes * sizeof(uint16_t));
    }

    D3D11_SUBRESOURCE_DATA *donnees = calloc((size_t)tranches, sizeof(D3D11_SUBRESOURCE_DATA));
    if (!donnees) { free(tampon); return 0; }
    for (int t = 0; t < tranches; ++t) {
        donnees[t].pSysMem = tampon + (size_t)t * parTranche;
        donnees[t].SysMemPitch = (UINT)((size_t)lignes * sizeof(uint16_t));
        donnees[t].SysMemSlicePitch = (UINT)(parTranche * sizeof(uint16_t));
    }

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = (UINT)lignes;
    td.Height = (UINT)hauteurTuile;
    td.MipLevels = 1;
    td.ArraySize = (UINT)tranches;
    td.Format = DXGI_FORMAT_R16_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    ID3D11Texture2D *texture = NULL;
    HRESULT hr = ID3D11Device_CreateTexture2D(rendu->appareil, &td, donnees, &texture);
    free(donnees);
    free(tampon);
    if (FAILED(hr)) { return 0; }

    D3D11_SHADER_RESOURCE_VIEW_DESC vd = {0};
    vd.Format = DXGI_FORMAT_R16_FLOAT;
    vd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
    vd.Texture2DArray.MipLevels = 1;
    vd.Texture2DArray.ArraySize = (UINT)tranches;
    hr = ID3D11Device_CreateShaderResourceView(rendu->appareil, (ID3D11Resource *)texture,
                                               &vd, &rendu->tuiles);
    ID3D11Texture2D_Release(texture);
    return SUCCEEDED(hr);
}

int spectre_rendu_televerser_palette(SpectreRendu *rendu, int largeur, int hauteur,
                                     const uint8_t *rgba) {
    if (!rendu || largeur <= 0 || hauteur <= 0) { return 0; }
    if (rendu->palette) {
        ID3D11ShaderResourceView_Release(rendu->palette);
        rendu->palette = NULL;
    }

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = (UINT)largeur;
    td.Height = (UINT)hauteur;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA donnees = {0};
    donnees.pSysMem = rgba;
    donnees.SysMemPitch = (UINT)(largeur * 4);

    ID3D11Texture2D *texture = NULL;
    HRESULT hr = ID3D11Device_CreateTexture2D(rendu->appareil, &td, &donnees, &texture);
    if (FAILED(hr)) { return 0; }
    hr = ID3D11Device_CreateShaderResourceView(rendu->appareil, (ID3D11Resource *)texture,
                                               NULL, &rendu->palette);
    ID3D11Texture2D_Release(texture);
    return SUCCEEDED(hr);
}

// ─────────────────────────────────────────────────────────── Le dessin

void spectre_rendu_dessiner(SpectreRendu *rendu, const SpectreUniformes *u) {
    if (!rendu || !rendu->cible) { return; }

    const float noir[4] = { 0, 0, 0, 1 };
    ID3D11DeviceContext_ClearRenderTargetView(rendu->contexte, rendu->cible, noir);
    ID3D11DeviceContext_OMSetRenderTargets(rendu->contexte, 1, &rendu->cible, NULL);

    // Le spectrogramme n'occupe pas forcément toute la fenêtre : la ligne de
    // batterie prend une bande en bas, comme sur le Mac où elle est une vue à part.
    // Ce qui reste au-dessous garde la couleur d'effacement, et la surimpression y
    // dessine.
    D3D11_VIEWPORT vue = {0};
    vue.Width = (FLOAT)(rendu->zoneLargeur > 0 ? rendu->zoneLargeur : rendu->largeur);
    vue.Height = (FLOAT)(rendu->zoneHauteur > 0 ? rendu->zoneHauteur : rendu->hauteur);
    vue.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports(rendu->contexte, 1, &vue);
    ID3D11DeviceContext_RSSetState(rendu->contexte, rendu->rasteriseur);

    // Sans matrice il n'y a rien à dessiner, mais l'effacement ci-dessus a bien eu
    // lieu : une fenêtre vide est noire, et non le contenu de ce qui la précédait.
    if (!rendu->tuiles) { return; }

    D3D11_MAPPED_SUBRESOURCE zone;
    if (SUCCEEDED(ID3D11DeviceContext_Map(rendu->contexte, (ID3D11Resource *)rendu->constantes,
                                          0, D3D11_MAP_WRITE_DISCARD, 0, &zone))) {
        memcpy(zone.pData, u, sizeof(SpectreUniformes));
        ID3D11DeviceContext_Unmap(rendu->contexte, (ID3D11Resource *)rendu->constantes, 0);
    }

    ID3D11ShaderResourceView *vues[2] = { rendu->tuiles, rendu->palette };
    ID3D11DeviceContext_IASetPrimitiveTopology(rendu->contexte,
                                               D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(rendu->contexte, NULL);
    ID3D11DeviceContext_VSSetShader(rendu->contexte, rendu->sommets, NULL, 0);
    ID3D11DeviceContext_PSSetShader(rendu->contexte, rendu->fragments, NULL, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(rendu->contexte, 0, 1, &rendu->constantes);
    ID3D11DeviceContext_PSSetShaderResources(rendu->contexte, 0, 2, vues);
    ID3D11DeviceContext_Draw(rendu->contexte, 3, 0);
}

int spectre_rendu_presenter(SpectreRendu *rendu) {
    if (!rendu || !rendu->chaine) { return 0; }
    // Intervalle **un**, et non zéro.
    //
    // C'est le contraire de ce qu'on croit en lisant « objet d'attente » : l'objet
    // ne compte pas les balayages, il compte les images *en file*. À l'intervalle
    // zéro, la carte présente sans attendre le balayage, la file ne se remplit
    // jamais, et l'objet est signalé en permanence — la boucle tourne alors à deux
    // mille images par seconde, brûle un cœur, et n'en montre que cent vingt.
    //
    // La mesure de fluidité a trouvé ce défaut au premier essai, et c'est
    // exactement pour cela qu'elle existe : à l'œil, une boucle qui tourne trop
    // vite est indiscernable d'une boucle qui tourne juste.
    //
    // Avec l'intervalle à un et une seule image en vol, on obtient les deux à la
    // fois : le balayage cadence, et l'attente a lieu **avant** de dessiner, si
    // bien que l'image montrée porte l'état le plus frais possible.
    HRESULT hr = IDXGISwapChain2_Present(rendu->chaine, 1, 0);
    // `DXGI_STATUS_OCCLUDED` n'est pas une erreur : la fenêtre est cachée, et la
    // carte cesse alors de cadencer. C'est **ce qu'il faut savoir** avant de lire un
    // relevé de fluidité — sans cette réponse, on prend des dizaines de milliers
    // d'images par seconde pour une bonne nouvelle, alors qu'elles veulent dire
    // qu'aucune n'est montrée.
    if (hr == DXGI_STATUS_OCCLUDED) { return 2; }
    return SUCCEEDED(hr) ? 1 : 0;
}

void spectre_rendu_attendre(SpectreRendu *rendu) {
    if (rendu && rendu->attente) {
        // Une seconde de patience au plus : un pilote qui ne réclame plus rien —
        // la fenêtre réduite, l'écran endormi — ne doit pas figer l'application.
        WaitForSingleObjectEx(rendu->attente, 1000, TRUE);
    }
}

int spectre_rendu_relire(SpectreRendu *rendu, uint8_t *octets) {
    if (!rendu) { return 0; }

    ID3D11Texture2D *source = rendu->cibleHorsEcran;
    if (!source && rendu->chaine) {
        if (FAILED(IDXGISwapChain2_GetBuffer(rendu->chaine, 0, &IID_ID3D11Texture2D,
                                             (void **)&source))) {
            return 0;
        }
    } else if (source) {
        ID3D11Texture2D_AddRef(source);
    }
    if (!source) { return 0; }

    if (!rendu->relecture) {
        D3D11_TEXTURE2D_DESC td;
        ID3D11Texture2D_GetDesc(source, &td);
        td.Usage = D3D11_USAGE_STAGING;
        td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        td.MiscFlags = 0;
        if (FAILED(ID3D11Device_CreateTexture2D(rendu->appareil, &td, NULL, &rendu->relecture))) {
            ID3D11Texture2D_Release(source);
            return 0;
        }
    }

    ID3D11DeviceContext_CopyResource(rendu->contexte, (ID3D11Resource *)rendu->relecture,
                                     (ID3D11Resource *)source);
    ID3D11Texture2D_Release(source);

    D3D11_MAPPED_SUBRESOURCE zone;
    if (FAILED(ID3D11DeviceContext_Map(rendu->contexte, (ID3D11Resource *)rendu->relecture,
                                       0, D3D11_MAP_READ, 0, &zone))) {
        return 0;
    }
    // La cible est en BGRA, et l'on rend du RGB : c'est le format que le PPM
    // attend, donc celui que `ImageCheck` compare.
    for (int y = 0; y < rendu->hauteur; ++y) {
        const uint8_t *ligne = (const uint8_t *)zone.pData + (size_t)y * zone.RowPitch;
        uint8_t *sortie = octets + (size_t)y * (size_t)rendu->largeur * 3;
        for (int x = 0; x < rendu->largeur; ++x) {
            sortie[x * 3 + 0] = ligne[x * 4 + 2];
            sortie[x * 3 + 1] = ligne[x * 4 + 1];
            sortie[x * 3 + 2] = ligne[x * 4 + 0];
        }
    }
    ID3D11DeviceContext_Unmap(rendu->contexte, (ID3D11Resource *)rendu->relecture, 0);
    return 1;
}

void spectre_rendu_nom_de_la_carte(SpectreRendu *rendu, char *nom, int taille) {
    if (!rendu || !nom || taille < 1) { return; }
    snprintf(nom, (size_t)taille, "%s", rendu->carte);
}
